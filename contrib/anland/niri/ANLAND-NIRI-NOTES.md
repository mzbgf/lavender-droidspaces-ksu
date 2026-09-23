# niri (smithay) anland backend — 移植说明

给 niri v26.04 加的第四个（weston / KWin / wlroots-sway 之后）anland producer：
`src/backend/anland.rs`，通过 `ANLAND=1` 选中，把 niri 桌面渲染进 Android consumer
预分配的共享 dmabuf，并把 daemon 的输入流转成 smithay 输入事件。

## 改了哪些文件

树：`/private/tmp/wlr-build/niri`（干净的 `v26.04` clone，未 commit，`git status` 可看全部改动）。

**新文件（3 组）**

| 文件 | 作用 |
|---|---|
| `src/backend/anland/protocol.h` | vendor，协议定义（原样未改） |
| `src/backend/anland/socket_utils.{c,h}` | vendor，SCM_RIGHTS 收发（原样未改） |
| `src/backend/anland/display_producer.{c,h}` | vendor，producer 状态机（原样未改） |
| `src/backend/anland/ffi.rs` | 手写 FFI 绑定（`display_ctx` + 15 个函数 + `buf_info`/`InputEvent` 的 `#[repr(C, packed)]` 镜像） |
| `src/backend/anland/input.rs` | smithay `InputBackend` 实现：`AnlandInput` + 虚拟设备 + 事件类型（其余事件用 smithay 的 `UnusedEvent`） |
| `src/backend/anland.rs` | `struct Anland`：连接/重连状态机、dmabuf import、渲染、输入派发 |

vendor 的 5 个 C/H 文件从 `/private/tmp/wlr-build/anland-lib/` **拷贝**（非软链），
内容一字未动（`diff -q` 验证过）。

**改动文件（6）**

| 文件 | 改动 |
|---|---|
| `Cargo.toml` | `[build-dependencies]` 加 `cc = "1.2"` |
| `build.rs` | `cc::Build` 编译 `socket_utils.c` + `display_producer.c` 进 `libanland_display_producer.a` |
| `src/backend/mod.rs` | `Backend::Anland(Anland)` variant + 每个分派方法的 match arm + `anland()` 访问器 |
| `src/niri.rs` | **backend 选择点**（`State::new`）：`ANLAND=1` 时优先构造 `Backend::Anland`；import `Anland` |
| `src/input/backend_ext.rs` | `impl NiriInputDevice for AnlandInputDevice`（绝对坐标映射到唯一输出） |
| `Cargo.lock` | 自动 |

注意：任务书说 backend 选择在 `src/main.rs`，但 v26.04 的选择逻辑实际在
`src/niri.rs:State::new`（`main.rs` 只传 `cli.session`）。分支加在 `State::new`
的 `if headless { ... } else if has_display { ... } else { Tty }` **之前**，
`ANLAND=1` 优先级最高，与要求一致。

## 怎么构建

容器：`wlr-anland-build`（Debian 13 triixie arm64，bind-mount `/private/tmp/wlr-build`）。
工具链：发行版 `cargo`/`rustc` 1.85.1（niri 声明 `rust-version = "1.85"`，正好够）。
依赖（缺什么 apt 装什么）：

```
build-essential pkg-config cargo rustc
libwayland-dev libxkbcommon-dev libudev-dev libinput-dev libdbus-1-dev
libseat-dev libegl-dev libgles-dev libgbm-dev libdrm-dev
libpipewire-0.3-dev libpango1.0-dev libcairo2-dev libdisplay-info-dev
libpixman-1-dev libclang-dev clang
```

```
cd /wlr-build/niri   # 容器内；宿主机是 /private/tmp/wlr-build/niri
cargo build
```

`cargo build` 通过（EXIT=0，产出 `target/debug/niri`）。唯一 warning 是上游
`niri-config` 的 `std::env::home_dir` deprecation，与本次改动无关。smithay 是 git
依赖（niri 锁的 rev `ff5fa7df`），构建需要能访问网络拉 crate / git。

## 怎么跑

```
# daemon 已在跑、consumer app 已就位的前提下：
export ANLAND_SOCKET=/opt/anland/display_daemon.sock   # 默认值，可省
ANLAND=1 niri
```

日志里应依次看到：`anland: connected to daemon at ...` → `anland: screen WxH,
refresh R mHz` →（consumer 起来后，≤200ms）`anland: consumer connected` →
`anland: importing buf[i] Abgr8888|Xrgb8888 WxH stride=... mod=Linear`。
consumer 掉线打 `anland: consumer disconnected, entering fallback`，然后每 200ms
重试 `try_exit_fallback()`，回来后自动重新 import。

其它环境变量：无。输出名固定 `anland-1`（在 `config.kdl` 的 `output "anland-1"`
块里配 scale 等）；seat 名 `anland`。

## 渲染路径（关键取舍，以及为什么这么选）

**怎么把 consumer 的 dmabuf 塞给 smithay：`Bind<Dmabuf>`，不自己拼 FBO。**

1. `try_exit_fallback()` 成功后，把每个 `get_dmabuf_fd_at()` + `get_dmabuf_info_at()`
   包成 smithay 的 `Dmabuf`（`Dmabuf::builder(w, h, fourcc, modifier, flags)` +
   `add_plane(fd, 0, offset, stride)`）。fd 用 `BorrowedFd::try_clone_to_owned()`
   **dup 一份**给 `Dmabuf`：C 库在 fallback 时会 close 它自己的那份，dup 让
   `Dmabuf` 的生命周期与之解耦（同 KWin 补丁里 `dup(fd)` 的理由）。
   `buf_info.format == 1` → `Fourcc::Abgr8888`，否则 `Xrgb8888`（与 weston 的
   `protocol_format_to_drm` 一致）；`modifier` 直接进 `Modifier`（目前恒 0 =
   `Linear`）。
2. 每帧：`idx = get_selected_idx()` → **`renderer.bind(&mut dmabufs[idx])`** →
   `OutputDamageTracker::render_output(renderer, &mut target, age, &elements,
   clear)` → `trigger_refresh()`。
   smithay 的 `impl Bind<Dmabuf> for GlesRenderer` 内部就是「EGLImage
   (`create_image_from_dmabuf`) + RBO (`EGLImageTargetRenderbufferStorageOES`) +
   FBO」，与 Tty/DRM 后端渲染 GBM buffer 是**同一条代码路径**。不手写
   `glFramebufferTexture2D` 是因为这条路已经过 smithay 在真实 DRM scanout 上的
   验证，且 KWin 参考实现（`GLTexture` + `GLFramebuffer`）本质同构。
3. **不做 y 翻转**。这是本移植最不确定、但有代码考古依据的一点：
   - weston `gl-renderer.c:4042`：`y_flip = surface == EGL_NO_SURFACE ? 1.0 :
     -1.0` —— 即 weston 渲染**窗口 surface** 和 **FBO** 用相反的 y 方向，anland
     走 `output_fbo_create`（EGL_NO_SURFACE）即 **FBO 不翻转**，真机已验证方向
     正确。
   - smithay/niri 的 TTY 路径用 `Bind<Dmabuf>` FBO + `Transform::Normal` 直接
     DRM scanout（buffer 行 0 = 屏幕顶），几千用户天天在用 —— 同一路径方向正确。
   - niri `add_output` 只对 connector `"winit"` 强制 `Transform::Flipped180`
     （`niri.rs` 里 "fix winit damage" 那段），正是因为 **窗口** 路径才需要翻转。
   - KWin 补丁里的 `contentTransform(FlipY)` 是修 **KWin 自己场景管线** 的方向
     （其 RenderTarget 约定与 weston/smithay 相反），不代表 GL FBO 需要翻转。
   结论：anland 与 TTY 同构（`Transform::Normal`，无翻转）。**若真机首测发现
   上下颠倒**，修法是在 `add_output` 前给 output 设 `Transform::Flipped180`
   （或 damage tracker 用 `Flipped180` 的 static mode source），一处即可。
4. **damage 记账用 smithay 自己的 buffer-age，不手维护 accum_damage**。consumer
   自己轮转 buffer，所以 weston/KWin/wlroots 都给每个 buffer 维护累计 damage。
   smithay 的 `OutputDamageTracker::render_output(.., age, ..)` 就是 buffer-age
   协议：`age = 本 buffer 上次渲染距今的帧数`（0 = 内容未知 → 全量重绘，正好覆盖
   "新 import 的 dmabuf 内容未定义"）。tracker 内部把每帧 damage 入历史，按 age
   合并漏掉的帧；历史长度不足时自动退化为全量重绘（保守、正确）。8 buffer 上限
   超过 tracker 的 `MAX_AGE=4` 时同样退化为全量 —— consumer 通常 2-3 buffer，
   实际无感。
5. **帧节奏完全 consumer 驱动**（同 wlroots 移植的结论）：`buffer_ready` eventfd
   → 清 eventfd → `consumer_ready = true` → `niri.queue_redraw()`；render 完成后
   **`trigger_refresh()` 且每个 buffer_ready 至多一次**（weston 的
   `consumer_ready` 门控），consumer 的 5 秒 watchdog 不会误触发。场景自身有
   damage（窗口动画等）触发的 render 不额外 trigger —— 没有 pending 的
   buffer_ready，consumer 不在等，写进去反而可能撕裂它正在读的 buffer。
6. 输入：`get_data_fd()` 进 calloop（`Generic<FdWrapper<RawFd>>`——fd 归 C 库所有，
   `FdWrapper` 保证 event loop 不会 close 它），`poll_input_event(…, 0)` 排空后转
   成 smithay 事件进 `State::process_input_event`（完整走 niri 的绑定/焦点/grab）。
   key 按 weston/KWin 语义当 Linux evdev code，转 xkb 时 +8；指针/触摸坐标按
   **屏幕物理像素**（同 wlroots 移植记录的约定），`x_transformed` 除以
   `get_screen_info()` 宽高再乘逻辑宽高；axis 0=Vertical / 1=Horizontal，
   `discrete != 0` 时 source=Wheel 且 `amount_v120 = discrete * 120`（同 KWin）。
   `INPUT_TYPE_DISPLAY_REFRESH` 更新 `Output` 的 mode refresh 与 IPC；**niri 的
   `FrameClock` 没有 interval setter，动画步进仍按启动时的 refresh**（已知小缺陷）。
   consumer 连上时发 `DeviceAdded`（niri 会 `seat.add_touch()`），断开发
   `TouchCancel` + `DeviceRemoved`。
7. fallback 处理：C 的 `set_fallback_callback` 只 set 一个 `AtomicBool`（回调发生在
   `poll_input_event` 内部，不能在里面碰 Rust 侧状态）；data fd 的 handler 收完
   事件后看到 flag 就拆掉两个 fd source（calloop 明确支持在回调里 remove 自己，
   见其 `kill_source` 测试与 "removed from within its callback" 注释）、丢
   `Dmabuf`、清 `consumer_ready`，然后 200ms 定时器自动进入下一轮
   `try_exit_fallback()`。

EGL/GlesRenderer 初始化照抄 headless：`EGLSurfacelessDisplay` + `EGLContext` +
`GlesRenderer::new` + `resources::init` + `shaders::init`（weston 也是
`EGL_PLATFORM_SURFACELESS_MESA`）。`create_dmabuf_global` 照抄 winit（kgsl 没有
DRM render node，`EGLDevice::try_get_render_node` 失败会自动退 v3 feedback）。

## 验证情况

**已验证**

- `cargo build` 通过（Debian 13 arm64 容器，rustc 1.85.1，EXIT=0，产出
  `target/debug/niri`）；vendor 的 5 个 C/H 与 `anland-lib/` 逐字节一致。
- 选择逻辑静态复核：`ANLAND=1` 优先于 headless/winit/tty 分支；未设时三个旧
  backend 的代码路径一行未动（`mod.rs` 只加了 arm）。

**未验证 / 已知边界（诚实标注）**

- **全链路（daemon + consumer + 真机 GPU）没有跑过**。容器里没有 daemon /
  consumer / kgsl/EGL，渲染、输入、重连都只做了编译级验证与三方参考实现
  （weston 真机已跑通的 `anland.c`、KWin 补丁）的逻辑比对。真机首测重点看：
  1. `importing buf[...]` 后画面**方向**是否正确（见上文取舍 3，错了改一处）；
  2. ABGR8888 / XRGB8888 通道是否正确（consumer 的 format=1 → `Abgr8888`）；
  3. 触摸/指针坐标是否全屏跟手（若缩在左上角，说明 consumer 发的是 0..1
     归一化坐标而非物理像素——wlroots 移植记录里也标了这个不确定性）；
  4. key 按 evdev 解释是否与 consumer 实际发送的编码一致。
- `Bind<Dmabuf>` 在 Adreno/kgsl 的 Mesa 上是否接受 consumer 的 ION dmabuf
  （external-only modifier 会导致 FBO 创建失败）——wlroots 移植把这条列为
  GPU 真机风险，此处同样**只能真机验证**。失败时日志是
  `error binding dmabuf N: FramebufferBindingError`，帧被 skip。
- `INPUT_TYPE_DISPLAY_REFRESH` 不更新 `FrameClock`（无 setter），动画步进率固定
  为启动时的 refresh；mode/IPC 广告值会更新。presentation-time 的 refresh 用
  `Refresh::Unknown`（同 winit）。
- 桌面静止 + consumer 轮转 buffer 时依赖 damage tracker 的 age 合并；若 tracker
  判定 "no damage" 会跳过绘制但仍 `trigger_refresh`（buffer 内容本来就最新）。
  逻辑自洽但未在真机压过三缓冲旋转的边界。
- 动画期间渲染节奏等于 consumer 的 buffer_ready 节奏（不自驱补帧）；consumer 若
  只在有内容时才 signal，动画可能掉到那个频率。
- 软件光标、session-lock、截图 UI 等 niri 上层功能走通用路径，未逐项测。
- `monitors_active == false`（DPMS/idle 熄屏）时 niri 不调 `render()`；buffer_ready
  handler 会直接 `queue_redraw`，若仍不渲染，watchdog 5s 后 consumer 进 fallback
  再自动重连（自愈，但不优雅）。真机若常见此场景再补一条 "熄屏也应答
  trigger_refresh"。

## 环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `ANLAND_SOCKET` | daemon 的 unix socket 路径 | `/opt/anland/display_daemon.sock` |
| `ANLAND` | `=1` 时优先选 anland backend | 未设 |
