# wlroots 0.18.2 anland backend — 移植说明

给 stock sway 用的第三个 anland producer：`backend/anland/`，通过
`WLR_BACKENDS=anland`（或 `ANLAND=1`）选中，把桌面渲染进 Android consumer
预分配的共享 dmabuf，并把 daemon 的输入流转成 wlr 事件。

## 改了哪些文件

全部内容也可用 `anland-wlroots-0.18.2.patch` 在干净的 wlroots-0.18.2 上重放
（`patch -p1 < anland-wlroots-0.18.2.patch`，已在原始 tarball 解包树上验证）。

**新文件（11）**

| 文件 | 作用 |
|---|---|
| `backend/anland/protocol.h` | vendor，协议定义（原样未改） |
| `backend/anland/socket_utils.{c,h}` | vendor，SCM_RIGHTS 收发（原样未改） |
| `backend/anland/display_producer.{c,h}` | vendor，producer 状态机（原样未改） |
| `backend/anland/anland.h` | 内部结构体：`wlr_anland_backend` / `wlr_anland_output` / `wlr_anland_buffer` |
| `backend/anland/backend.c` | backend 生命周期、fallback 回调、200ms 重连定时器、buffer_ready / input fd 处理 |
| `backend/anland/output.c` | `wlr_output` 实现 + dma-buf→`wlr_buffer` 包装 + 呈现/拷贝 |
| `backend/anland/input.c` | `struct InputEvent` → wlr keyboard/pointer/touch 事件 |
| `backend/anland/meson.build` | 把以上编进 `wlr_files`（vendor 的 4 个 .c 中 2 个源文件） |
| `include/wlr/backend/anland.h` | 公开 API：`wlr_anland_backend_create` / `wlr_backend_is_anland` / `wlr_output_is_anland` |

**改动文件（2）**

| 文件 | 改动 |
|---|---|
| `backend/meson.build` | 末尾加 `subdir('anland')` |
| `backend/backend.c` | `wlr_backend_autocreate`：`WLR_BACKENDS` 认 `anland`；`ANLAND=1` 时优先于 WAYLAND_DISPLAY/DISPLAY/DRM 启发式；socket 路径取 `ANLAND_SOCKET`（默认 `/opt/anland/display_daemon.sock`） |

vendor 的 5 个文件是从 `/private/tmp/wlr-build/anland-lib/` **拷贝**（非软链）进来
的，内容一字未动。

## 怎么构建

容器：Debian 13 (trixie) arm64，原生编译。依赖（缺什么 apt 装什么）：

```
meson ninja-build pkg-config build-essential
libwayland-dev libdrm-dev libgbm-dev libinput-dev libxkbcommon-dev
libudev-dev libpixman-1-dev wayland-protocols libegl-dev libgles-dev
libvulkan-dev liblcms2-dev libseat-dev hwdata libdisplay-info-dev
libxcb1-dev libxcb-composite0-dev libxcb-dri3-dev libxcb-present-dev
libxcb-render0-dev libxcb-render-util0-dev libxcb-shm0-dev libxcb-xfixes0-dev
libxcb-xinput-dev libxcb-icccm4-dev libxcb-ewmh-dev libxcb-res0-dev
xwayland glslang-tools python3
```

一个环境侧的坑：wlroots 0.18 的 xwayland 探测要 `pkg-config xwayland`（上游
xserver 构建时安装的 .pc），Debian 只给 `/usr/bin/Xwayland` 二进制、不带 .pc，
而 `fallback: 'xserver'` 又没有 wrap 文件。解决办法是**装 `xwayland` 包并补一个
`xwayland.pc`**（本容器放在 `/usr/local/lib/pkgconfig/xwayland.pc`，指向
`/usr/bin/Xwayland`，四个 `have_*` 特性对 24.1 均为 true——选项
`-listenfd`/`-terminate [delay]`/`-noTouchPointerEmulation`/`-force-xrandr-emulation`
都存在）。这是构建环境的事，不动 wlroots 源码。

```
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
meson setup build --prefix=/usr -Dexamples=false -Dxwayland=enabled
ninja -C build
```

产出：`build/libwlroots-0.18.so`（已验证全量重编与补丁重放编译均通过）。
特性面板：drm/x11/libinput/xwayland/gles2/vulkan/gbm/session/color-management 全 YES。

## 怎么跑 stock sway

```
# daemon 已在跑、consumer app 已就位的前提下：
export ANLAND_SOCKET=/opt/anland/display_daemon.sock   # 默认值，可省
export WLR_BACKENDS=anland
# 或者只设 ANLAND=1（等效，优先于 WAYLAND_DISPLAY/DISPLAY 自动探测）
sway -c /etc/sway/config
```

日志里应依次看到：`Creating anland backend` → `daemon at ... screen WxH` →
`Starting anland backend` → `anland: consumer connected` →
`imported buf[i] ... fmt=0x34324241`（ABGR8888）→ `new_output ANLAND-1`。
consumer 掉线会打 `consumer disconnected, entering fallback`，然后每 200ms 重试
`try_exit_fallback()`，回来后自动重新 import。

## 渲染路径（关键设计，以及为什么这么选）

wlroots 0.18 的分工是：**合成器**（sway/wlr_scene）自己用 allocator 拿
`wlr_buffer`、用 `wlr_renderer_begin_buffer_pass` 画完、再
`wlr_output_state_set_buffer` + commit 交给 backend；backend 只负责 present。
backend **没有** scene graph，也没有 renderer 所有权（`wlr_output.renderer` 是
合成器通过 `wlr_output_init_render()` 挂上来的）。所以「像 weston 那样
`create_renderbuffer_dmabuf` 直接把场景画进 consumer 的 dmabuf」在 wlroots 里
走不通——合成器渲染目标的选择权不在 backend 手里。

因此采用 **copy 路径**（同 `backend/drm/renderer.c` 的 `drm_surface_blit`）：

1. consumer 的每个 dma-buf 包成 `struct wlr_anland_buffer`（`wlr_buffer` 子类，
   实现 `get_dmabuf` + `begin_data_ptr_access`）。`get_dmabuf` 让 GLES2 renderer
   把它当 EGLImage + FBO 渲染目标，这正是任务里说的「把 consumer 预先分配的
   dmabuf 变成可渲染的 wlr_buffer」；wayland backend 的
   `wlr_buffer_get_dmabuf` 用法是同一套属性结构（`wlr_dmabuf_attributes`）。
2. `output_commit` 收到合成器的帧后：`idx = get_selected_idx()` →
   `wlr_texture_from_buffer(renderer, state->buffer)` →
   `wlr_renderer_begin_buffer_pass(renderer, consumer_buf[idx])` →
   `wlr_render_pass_add_texture`（`clip` = 该 buffer 的累计 damage）→ submit →
   `trigger_refresh()`。
3. damage 记账照抄 weston：consumer 自己轮转 buffer，所以每个 buffer 维护
   `accum_damage[i]`（自它上次被更新以来的全部 damage），本次帧 damage 加进
   所有 buffer 的欠账，呈现 `idx` 时按 `accum_damage[idx]` 拷、拷完清零。
   新 import 的 dma-buf 内容未定义，初始化为全额欠账。
4. **帧节奏是 consumer 驱动**（同 KWin 的做法）：`buffer_ready` eventfd 表示
   「已选中某 buffer，请画」→ 先同步 `wlr_output_send_frame()`（sway 的 frame
   handler 若有 damage 会当场 commit，走第 2 步）；若合成器无新帧可交（桌面
   静止），再用 `last_frame`（最近一次 commit 的锁定副本）把欠账拷进选中的
   buffer 并 `trigger_refresh()`。这样**每次 buffer_ready 恰好应答一次
   `trigger_refresh()`**，consumer 的 5 秒 watchdog 不会误触发 fallback；同时也
   满足「每帧渲染完成后必须 trigger_refresh」——有新帧就在 commit 里 trigger，
   无新帧就用最近帧补交，不会让 consumer 空等。
5. `INPUT_TYPE_DISPLAY_REFRESH`（consumer 上报实时刷新率，mHz）会更新
   `wlr_output.refresh` 与 `current_mode->refresh`。帧节奏本身由 buffer_ready
   驱动、不依赖定时器，所以只更新广告值。

## 验证情况

**已验证（Debian 13 arm64 容器，mock daemon + 测试宿主）**

- `ninja -C build` 全量通过，产出 `libwlroots-0.18.so`；补丁在干净 tarball 解包树
  上 `patch -p1` 后重新 meson+ninja 也通过。
- mock daemon（unix socket + SCM_RIGHTS，memfd 冒充 dma-buf）端到端：
  `connect_to_deamon` 握手拿 screen_info → `try_exit_fallback` 拿 4 fd +
  dmabuf 集合 → import（日志 `fmt=0x34324241` = ABGR8888，format 1 映射正确）→
  `new_output ANLAND-1 WxH refresh` → 3 个 `new_input`（keyboard/pointer/touch）→
  输入事件注入 → `buffer_ready` → **`trigger_refresh` 被 mock 收到** →
  consumer 掉线进 fallback。
- **像素拷贝正确**：用 pixman renderer 画满屏 `(r=0.25, g=0.5, b=0.75)` 并 commit 后，
  consumer buffer 首像素 = `3f7fbfff`，即 ABGR8888 内存序的
  `(R=0x3F, G=0x7F, B=0xBF, A=0xFF)`，通道与 alpha 都对。
- `wlr_backend_autocreate` 两个入口都认：`WLR_BACKENDS=anland` 与 `ANLAND=1`
  （无 WLR_BACKENDS）均产出 `ANLAND-1` 并正常走完握手/import。

**未验证 / 已知边界（诚实标注）**

- **GLES2 实拷贝路径未在真 GPU 上跑过**。容器没有 kgsl/EGL 环境，像素验证走的是
  pixman renderer（同一套 `wlr_renderer_begin_buffer_pass` API）。GLES2 路径的代码
  与 `backend/drm/renderer.c:drm_surface_blit` 逐行同构，但 **consumer dma-buf 在
  Adreno/kgsl 上是否被 EGL 标成 external-only（external-only 会导致 FBO 创建失败），
  只能在真机验证**。失败时自动落 CPU 拷贝（`mmap` 双方 dma-buf + 逐行拷贝/通道
  swizzle），功能不丢、性能差。真机若日志出现 `Failed to create FBO` / 拷贝走
  fallback，就是这个原因。
- 输入坐标按 weston 的 `weston_coord_global_from_output_point` 用法解释为
  **屏幕物理像素**，再除以 `get_screen_info()` 的宽高得到 wlr 要的 0..1。KWin
  侧 `/ scale` 的写法与「物理像素」一致（scale=1 时恒等）。若 consumer 实际发的
  是已归一化坐标，触摸/指针会全部缩到屏幕左上角——真机首测要看一眼。
- `INPUT_TYPE_DISPLAY_REFRESH` 只更新 mode/refresh 字段，没有发
  `wlr_output_send_request_state`（合成器不会重配 mode）。对 sway 无影响，
  presentation-time 上报的 refresh 值可能滞后。
- 软件光标未测（未实现 `set_cursor`，sway 会走软件光标合成进帧，应该自然可用）。
- 跑真机 sway 未测（容器里没有 daemon/consumer）。
- 一处协议取舍：`trigger_refresh` 采用 weston 的「每个 buffer_ready 至多一次」
  门控，而不是「每次 commit 无条件 trigger」。这样不会在 consumer 取走 buffer
  的窗口里二次写同一块 buffer（撕裂风险），代价是 commit 与 buffer_ready 竞争时
  新帧内容最多晚一个 consumer 周期才上屏。

## 环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `ANLAND_SOCKET` | daemon 的 unix socket 路径 | `/opt/anland/display_daemon.sock` |
| `ANLAND` | `=1` 时 autocreate 优先选 anland | 未设 |
| `WLR_BACKENDS` | 显式写 `anland` 也可（可与其它 backend 并列） | 自动探测 |

---

## 真机首测补上的两处（补丁已含，本节是事后追记）

### A. 自带 allocator：gles2 只吃 DMABUF，本机三条路全死

`render/gles2/renderer.c` 里 `wlr_renderer_init(..., WLR_BUFFER_CAP_DMABUF)` ——
gles2 **只**认 dmabuf。而 `wlr_allocator_autocreate` 的候选在本机全部走不通：

| allocator | 死因 |
|---|---|
| gbm | 要 PRIME fd 导出；`/dev/dri/renderD128` 是 vkms，报 `PRIME export not supported` |
| shm | 要 `WLR_BUFFER_CAP_SHM\|DATA_PTR`，gles2 不给 |
| drm dumb | 要 `drmIsMaster()`，渲染节点不是 |

→ `Failed to create allocator`。新增 `backend/anland/allocator.c`：一个
`wlr_allocator`，把 consumer 的 dmabuf 当 buffer 池发出去（weston/KWin 的直渲路径），
并在 `render/allocator/allocator.c` 的 `wlr_allocator_autocreate` 开头挂钩。

⚠️ **钩子不能用 `wlr_backend_is_anland(backend)`**：sway 传进来的是 **multi backend**
（anland + 它自带的 headless 输出），那个判断恒为 false，会静默落到 GBM 然后失败。
用全局 `wlr_anland_current` 认实例（`backend/anland/backend.c` 里 create/destroy 维护）。

判据：日志出现 `anland: created dmabuf allocator over the consumer pool`。
注意 sway 默认只打 `WLR_ERROR`，上面这条是 `WLR_INFO` —— 要 `sway -d` 或
`WLR_LOG_LEVEL=debug` 才看得见。

### B. `new_output` 必须等 dmabuf import 完成再发

sway 一看到 output 就去建 swapchain；此时池子可能还空着（consumer 未必已连上），
`create_buffer` 只能返回 NULL → `render/swapchain.c: Failed to allocate buffer`
→ 输出被判无效（`Requested backend configuration failed`）。

解法：`wlr_anland_output` 上挂 `announced` 标志。`wlr_anland_output_create()` 里
**不** emit `new_output`；等 `try_exit_fallback()` 成功、`import_buffers()` 拿到
`buf_count > 0` 之后，由 `consumer_connected()` emit 一次。

### C. 真机实测结果

```
EGL vendor: Mesa Project
GL vendor: freedreno
GL renderer: FD512                    ← Adreno 512 真 GPU
anland: created dmabuf allocator over the consumer pool
```

`wayland-info`：`wl_shm` v2、`zwp_linux_dmabuf_v1` v4、`zwlr_export_dmabuf_manager_v1` v1
（client 侧 EGL 可用）。sway + swaybg + swaybar 真机出画（workspace / 负载 / 内存 / 时钟 /
蓝色壁纸 / 鼠标指针）。
