# 在 lavender（Adreno 512 / KGSL / 4.19）上跑 GPU 加速 Wayland 的实现路径

目标：让 wlroots 系（sway/hyprland）、KDE（KWin）、niri 都能**真机工作**，且**不使用软件渲染**。

本文记录**实测验证过的**事实、**已证伪的死路**、以及当前的正确架构。标 ✅ 的项都有真机证据。

## 一、设备的图形栈现状（实测）

| 项 | 状态 |
|---|---|
| 显示 | CAF 传统 fbdev：`FB_MSM` + `FB_MSM_MDSS`（无 DRM） |
| GPU | KGSL：`QCOM_KGSL`，节点 `/dev/kgsl-3d0`，**Adreno 512**（a5xx） |
| 用户态 | Android 的 adreno 栈（`ro.hardware.egl=adreno`） |

原生内核**没有 DRM 子系统**（无 `/dev/dri`、无 `/sys/class/drm`）。

**GPU 渲染已实证 ✅**（wlroots 的 device 路径、真实 fd）：

```
EGL driver name: kgsl
GL renderer: FD512          ← Adreno 512 真 GPU，GLES 3.1
```

即 **freedreno + kgsl 后端在 a5xx 上可用**，渲染端不是死路。这条结论在后面的架构选择里是基石。

## 二、死路（已证伪，不要再走）：让 Linux DRM/KMS 在 Android 上当显示栈

曾经的做法是给内核加 `CONFIG_DRM_VKMS` 造一个虚拟 KMS 显示卡，再把 Mesa 的 dri2/GBM
接到这个虚拟 DRM 设备上，让 wlroots/KWin/niri 走标准 KMS 上屏。

**结论：此路不通。** 核心症状是

```
libEGL warning: egl: failed to create dri2 screen
DRI2: failed to load driver
→ sway: Failed to create a GLES2 renderer
```

已排除的分支（每个都修过或证伪过，**不要重走**）：

| 排除项 | 结论 |
|---|---|
| 文件 / 依赖缺失 | 9 个 Mesa 相关包全装齐，无效 |
| PCI 中心假设（`loader_get_driver_for_fd` 按 PCI ID 查驱动名） | 已放宽为尊重 `MESA_LOADER_DRIVER_OVERRIDE`，**仍然失败** |
| `drmGetDevice2` 拿不到设备 | 已修（补 `kdev->parent` / `unique` / `unique_len`）→ 返回 0、`bustype=PLATFORM`、`busid=platform:vkms`，**仍然失败** |
| libdril 垫片与 libgallium ABI 不匹配 | 已改用**同源 Debian 打包构建**（`adreno-debian-trixie` + `mk-build-deps` + `origtargz` + `dpkg-buildpackage`，9 个 deb 全装）→ **仍然失败** |
| `EGL_PLATFORM=surfaceless` 的测试结论 | 在**未打补丁的 Mesa** 上 fd 为 -1，结论作废；见下文第四节 |

也就是说：即便 libdrm 能正常枚举 vkms、即便 Mesa 是同源构建、即便包一个不缺，
`dri2_initialize_*` 内部仍会拒绝这个虚拟设备。**继续在 Mesa 的 dri2 路径上打补丁是投入产出比最差的选择。**

同时记下一条设计教训：Droidspaces 的 `--gpu` 扫描 GPU 设备时**显式跳过 `/dev/dri/card*`**，
理由是防止 host kernel panic。手动 bind `/dev/dri` 并造 card0，本身就走在官方明确避开的方向上。

### 死路留下的残留（刻意保留，理由见下）

| 残留 | 保留理由 |
|---|---|
| `configs/40-gpu-drm.config`（`CONFIG_DRM=y` + `CONFIG_DRM_VKMS=y`） | 只为产生 `renderD128` |
| `buildfix/0005` vkms gem fault 返回 `vm_fault_t` | 4.17 起签名变化，编 vkms 必须 |
| `buildfix/0006` `DRIVER_RENDER` | 产生 `renderD128` |

理由：anland 的 **Chroot/LXC 启动路径写死了 `ANLAND_DRM_DEVICE=/dev/dri/renderD128`**，
该 fd 只作 freedreno 的 `control_fd`（fd 身份 / 屏幕缓存键），GPU 命令仍走 `/dev/kgsl-3d0`。
Droidspaces 属于这类容器。若最终改走 anland 的 PRoot 路径（`ANLAND_NO_DRM_DEVICE=1` +
`EGL_PLATFORM=surfaceless`），这三个残留可以整体删除。

已删除的死路产物（不要恢复）：`buildfix/0007–0010`（`unique` / `kdev->parent` /
`unique_len`，纯为让 libdrm 认 vkms）、容器内 `70-drm-modalias.rules`（udev 伪造
`MODALIAS=platform:vkms`）、全部 `drmprobe*` / gbm / shim / 自编 Mesa 试验物。

## 三、正确架构：anland —— 渲染与呈现彻底分离

Android 的显示是 SurfaceFlinger + gralloc，不是 KMS。Linux 容器里的 Wayland 桌面要出画面，
正确做法**不是**让 Linux DRM 接管显示，而是：

```
┌─ Android 端（consumer）────────────────┐
│ 分配 dmabuf、上屏到 SurfaceFlinger、送输入 │
└──────────────┬─────────────────────────┘
               │ Unix socket 传 fd（anland daemon 撮合）
┌──────────────▼─────────────────────────┐
│ Linux 容器（producer：KWin / Weston …）  │
│ 只负责渲染进 consumer 提供的共享 buffer   │
│ 渲染走 kgsl → freedreno → FD512         │
└────────────────────────────────────────┘
```

帧循环走 shm 索引页 + `buf_ready` eventfd + fence socketpair（GPU fence 经 `SCM_RIGHTS`，
避免 `glFinish()` 卡 CPU）。参考实现：[superturtlee/anland](https://github.com/superturtlee/anland)；
Termux/容器发行版打包：[lfdevs/anland-termux](https://github.com/lfdevs/anland-termux)。
已在 **Adreno 750 / 830 / 840** 上实跑 KDE Plasma Wayland。

### 渲染端的必需环境变量（官方实跑命令）

```
ANLAND_NO_DRM_DEVICE=1 EGL_PLATFORM=surfaceless        # PRoot 路径
ANLAND_DRM_DEVICE=/dev/dri/renderD128                  # Chroot/LXC 路径（Droidspaces 用这条）
MESA_LOADER_DRIVER_OVERRIDE=kgsl GALLIUM_DRIVER=freedreno
FD_FORCE_KGSL=1 XWAYLAND_FORCE_KGSL_SURFACELESS=1
```

### Mesa 必须是 lfdevs 打过这三个补丁的构建

| 补丁 | 内容 | 对应我们的症状 |
|---|---|---|
| [#81](https://github.com/lfdevs/mesa-for-android-container/pull/81) | `egl/dri2: fix KGSL initialization for surfaceless and Wayland` | 正是 `failed to create dri2 screen` |
| [#76](https://github.com/lfdevs/mesa-for-android-container/pull/76) | compositor 不 advertise wl_drm 时回退开 `/dev/kgsl-3d0`；`FD_FORCE_KGSL` 拆分 `control_fd` / GPU fd | `MESA-LOADER: failed to retrieve device information` 告警链 |
| [#85](https://github.com/lfdevs/mesa-for-android-container/pull/85) | KGSL 的 linear dma-buf import/export（`FD_KGSL_ENABLE_DMABUF=1`），**opt-in** | dmabuf 呈现路径 |

**由此修正两条旧判据**：

1. `EGL_PLATFORM=surfaceless` 在未打补丁的 Mesa 上 fd 为 -1，但在打了 #81/#85 的
   Mesa 上**正是 anland 的主路径**。旧文档把它判为「判据无效」是以偏概全。
2. **旧的 `failed to create dri2 screen` 有一个被长期忽略的污染源**：死路实验把自编
   Mesa 装在了 `/usr/local/lib/aarch64-linux-gnu/`（meson 默认前缀），而
   `ld.so.conf.d/aarch64-linux-gnu.conf` 里 `/usr/local/...` **排在 `/usr/lib/...` 之前**。
   于是所有测试实际加载的都是那套自编 26.1.0，lfdevs 的 26.3.0 被完全屏蔽，
   `ldd` 一看便知。**清掉该目录后，surfaceless + kgsl 立即建 screen 成功**。
   以后凡是「装了新 Mesa 却症状不变」，先 `ldd` 查是不是被 `/usr/local/lib` 截胡。

**发行版原生 Mesa 一律不够用**，必须用 lfdevs 的构建（Release 里有 `debian_trixie_arm64`
等按发行版分的包）。不要自编 Mesa —— 那是死路里的一步，缺上述三个补丁，而且自编的
meson 前缀极易变成这种「看不见的污染源」。

## 四、硬件上的冷门区（已实测通过 ✅）

lfdevs 的实测支持表只有 **Adreno 660 / 710–750 / 810–840**（全 a6xx+）。
[Issue #32](https://github.com/lfdevs/mesa-for-android-container/issues/32) 里维护者明说
**「Freedreno (KGSL) 在比 Adreno 660 更老的 GPU 上不工作」**，老卡的建议是改用 unpatched
Turnip + Zink。但 Turnip 只支持 a6xx+，我们的 Adreno 512 是 **a5xx**，Turnip 直接不可用
（实测 `unknown UBWC version 0x0`）。

`freedreno_devices.py` 里有 `GPUId(510)/GPUId(512)` 的 A5XX 完整定义 —— **实测这条冷门区是通的**：

| 未知项 | 结论 | 证据 |
|---|---|---|
| a5xx 能否走 anland 的 surfaceless/kgsl 路径 | **能** | `GL_RENDERER=FD512`、`EGL 1.5`、`dma_buf_import=YES`、`dma_buf_import_modifiers=YES`、Mesa 26.3.0-devel |
| 4.19 无 dma-heap 只有 ION，consumer 能否拿到 dmabuf | **能** | `collected 4 dma-bufs`（AHardwareBuffer→gralloc→ION，1080x2340，`modifier=0` LINEAR） |

结论：**a5xx 不是这条生态的死区**，只是没人实测过。我们现在是第一台有完整记录的。

## 五、Droidspaces 上的实际接线（已落地，真机出画 ✅）

**判据已达成**：Weston + `backend-anland` 在本机完整跑通并出画 ——
`GL renderer: FD512`、`dmabuf support: modifiers`、桌面/面板/指针/Wayland Terminal
窗口均实机可见。下面三个坑是这条链路上真正的拦路石。

### 5.1 三端组件

| 端 | 组件 | 来源 | 部署位置 |
|---|---|---|---|
| Android | 显示 app（consumer） | [anland-termux](https://github.com/lfdevs/anland-termux) 的 `AnlandTermux-5.13.3.apk` | 包名 `com.anland.termux`，与 Termux 共享 UID |
| Android | `display_daemon`（撮合守护） | [anland-Y700-Droidspaces](https://github.com/SeamusCheng/anland-Y700-Droidspaces) 的 `magisk_module/display_daemon`（预编译，bionic，42 KB） | `/data/local/tmp/display_daemon` |
| 容器 | KWin 6.3.6-95 / Weston 14.0.2-92（均含 `backend-anland`） | anland-termux 5.13.3 的 `kwin_anland-5.13-debian-4_6.3.6-95.zip` / `weston_anland-5.13-debian-14.0.2-92.zip` | Debian 13 容器 |
| 容器 | XWayland 24.1.6-91（anland 版） | `xwayland_24.1.6-91_arm64.deb` | 同上 |
| 容器 | Mesa（含 lfdevs #76/#81/#85） | `mesa-for-android-container_26.3.0-devel-20260824_debian_trixie_arm64.tar.gz` | `tar -zxf … -C /` + `ldconfig` |

### 5.2 socket 接线（踩过坑，照此）

**坑 1：容器的 `/tmp` 是独立 tmpfs**，不是 rootfs 的 `/tmp`。往
`rootfs/tmp/` 写的东西容器里看不见（`droidspaces run cat /tmp/.hostmark` 证实）。
所以 socket 不能放 `/tmp/anland/`。

**坑 2：APK 的默认 socket 路径写死在 dex 里**：

```
DEFAULT_SOCKET_PATH = /data/data/com.termux/files/usr/tmp/anland/display_daemon.sock
```

（`KEY_SOCKET_PATH` 可在 app 设置里改，但默认路径可以零配置。）

**解法**：daemon 监听在 rootfs 的 `/opt/anland/`（容器内即 `/opt/anland/`），
再在 app 默认路径放一个**符号链接**指过去：

```sh
R=/data/local/Droidspaces/Containers/debian/rootfs
setsid /data/local/tmp/display_daemon $R/opt/anland/display_daemon.sock &
ln -s $R/opt/anland/display_daemon.sock \
      /data/data/com.termux/files/usr/tmp/anland/display_daemon.sock
```

Unix 域套接字**跟随符号链接**，两端零配置：app 走默认路径、合成器走
`ANLAND_SOCKET=/opt/anland/display_daemon.sock`。
（`/data/local` 是 `drwxr-x--x`，共享 UID `com.termux` 可穿越。）

### 5.3 四个拦路石（不修必黑屏/必崩/必画不出）

**坑 6：client 侧 `zwp_linux_dmabuf_v1` 取决于 `ANLAND_DRM_DEVICE` 指向谁。**
这是让 **Plasma / Qt Quick / 任何 EGL client** 画得出来的开关：

| 配置 | `wayland-info` 里的 client 缓冲协议 | 结果 |
|---|---|---|
| `ANLAND_DRM_DEVICE=/dev/dri/renderD128`（本机=**vkms 假渲染节点**） | 只有 `wl_shm`，**无** `zwp_linux_dmabuf_v1` / `wl_drm` / syncobj | Qt Quick 建不出 EGL surface：`qt.qpa.wayland: eglSwapBuffers failed with 0x300d (EGL_BAD_SURFACE), surface: 0x0` → `plasmashell` 画不出来 |
| `ANLAND_NO_DRM_DEVICE=1 EGL_PLATFORM=surfaceless` | **`zwp_linux_dmabuf_v1` v4 出现** | Plasma 桌面/面板/QML 全部正常渲染 |

原因：KWin 的 anland 后端要把一个 **能用的** DrmDevice 交给 KWin 的 client 侧 dmabuf
反馈探测（`wp_linux_drm_syncobj` / `zwp_linux_dmabuf_feedback`）。我们那个 `renderD128`
是 vkms —— 有 DRM 节点但不是 GPU 节点，KWin 一探测就放弃、根本不告 `zwp_linux_dmabuf_v1`。
改成 `ANLAND_NO_DRM_DEVICE=1` 让它走 surfaceless 后，client 侧 dmabuf 反而正常建立。

判据（一条命令）：

```sh
wayland-info | grep -E 'dmabuf|wl_drm|syncobj'
# 必须看到 zwp_linux_dmabuf_v1；只有 wl_shm 就是配错了
```

**因此本机（Droidspaces/LXC）一律用 PRoot 那条配置，不要用 `ANLAND_DRM_DEVICE`**：

```sh
unset ANLAND_DRM_DEVICE
export ANLAND_NO_DRM_DEVICE=1 EGL_PLATFORM=surfaceless
```

（anland 文档把这条标成 "For PRoot container"、把 `ANLAND_DRM_DEVICE=/dev/dri/renderD128`
标成 "For Chroot/LXC"。在**有真 DRM 渲染节点**的机器上那条才是对的；我们只有 vkms 假节点，
用那条会把 client 侧 dmabuf 弄没。）

**坑 7：`startplasma-wayland` 起来会先弹 `kscreenlocker_greet` 锁屏**，桌面被挡在后面，
看起来像「黑屏/没画出来」。判据：日志有 `kscreenlocker_greet: Failed to load lockscreen QML`、
屏上是「Unlocking session」。禁掉：

```sh
mkdir -p ~/.config
printf '[Daemon]\nAutolock=false\nLockOnResume=false\n' > ~/.config/kscreenlockerrc
pkill -x kscreenlocker_greet      # 已经弹出来的
```

**坑 4：daemon 必须与 APK 同版本，fd 槽位数会变。**
Y700 fork 的 `display_daemon` 走 **4 fd**（`buf_ready / refresh_done / data / shm`），
lfdevs 5.13.3 的 consumer 走 **5 fd**（`buf_ready / fence / data / shm / audio`）。
错位后 `sv[1]` 到不了 producer，`data_fd` 是断的 → `push_dmabufs_internal` 必失败 →
`enter_fallback` → producer 的 `RECONNECT_INTERVAL_MS=200` 定时器反复握手，
表现为 daemon 日志疯狂刷 `fds delivered` ↔ `consumer re-deposited`，
consumer 日志每 200ms 一对 `exit fallback triggered` / `fallback triggered`。

判据：daemon 打 `consumer connected, N fds`，**N 必须是 5**（4 就是错版本）。
正确的 daemon 在 `anland_5.13.3_aarch64.deb` 里（`ar x` + `tar -xf data.tar.xz`，
路径 `data/data/com.termux/files/usr/bin/anland`）；Y700 的 `magisk_module/display_daemon`
**不要用**。

**坑 5：producer 送来的 fence fd 会让 SurfaceFlinger 直接 abort。**
`refresh_done()` 把 producer 经 SCM_RIGHTS 送来的 kgsl sync_file 原样交给
`ANativeWindow_queueBuffer`，本机这套 4.19/CAF 的 SF 不认这个 fence：

```
F BLASTBufferQueue: acquireNextBufferLocked failed to apply transaction. status=-2147483646
F libc: Fatal signal 6 (SIGABRT)          ← LOG_ALWAYS_FATAL，app 渲染线程必崩
```

判据：`collect_dmabufs` 里的 `queueBuffer(win, anb, -1)` 一直没事，
渲染循环里 `queueBuffer(window, anb, rfence)` 一进首帧就崩 —— 差异只有这个 fence。
（weston 随后还会因为 consumer 已死、它还在画已释放的 dmabuf 而 SIGSEGV，那是连锁反应。）

**当前处置**（二进制补丁，未重编 APK）：把 `libanland_consumer.so` 里
`refresh_done` 提取 fence fd 的那条 `ldr w0, [x8, #0x10]` 换成 `mov w0, #-1`。
等待语义完整保留（仍阻塞等 producer 的 render-done 消息），只是**不再把 fd 下传给 SF**，
退化为 `queueBuffer(..., -1)` 即 "ready now"。实测出画正常、零崩溃。

```sh
# VMA 0xecd8 → 文件偏移 0xecd8-0x4000 = 0xacd8（.text 的 LOAD 段 vaddr-off 差 0x4000）
# 原指令 ldr w0,[x8,#0x10] = 0xb9401100 → 改 mov w0,#-1 = 0x12800000
python3 - <<'PY'
import struct
p = "libanland_consumer.so"
d = bytearray(open(p, "rb").read())
off = 0xecd8 - 0x4000
assert d[off:off+4] == bytes.fromhex("001140b9")
d[off:off+4] = struct.pack("<I", 0x12800000)
open(p, "wb").write(d)
PY
# 放回 /data/app/~~*~~/com.anland.termux-*/lib/arm64/libanland_consumer.so，force-stop app
```

正路是改 `native_consumer.c` 里 `refresh_done()` 的返回值处理（拿到 fence 后
`close()` 掉并返回 -1）再用 NDK 重编 APK；二进制补丁是省掉 NDK 的等效近路。

### 5.4 合成器启动环境（容器内）

`/usr/local/bin/start-anland-weston` 与 `start-anland-plasma` 已写入容器，核心是：

```sh
export ANLAND_SOCKET=/opt/anland/display_daemon.sock ANLAND=1
# 本机只有 vkms 假渲染节点，必须走 surfaceless（见坑 6）
unset ANLAND_DRM_DEVICE
export ANLAND_NO_DRM_DEVICE=1 EGL_PLATFORM=surfaceless
export MESA_LOADER_DRIVER_OVERRIDE=kgsl TURNIP_KMD=kgsl GALLIUM_DRIVER=freedreno
export FD_FORCE_KGSL=1 XWAYLAND_FORCE_KGSL_SURFACELESS=1 FD_KGSL_ENABLE_DMABUF=1
export QT_QPA_PLATFORM=wayland XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE

weston --backend=anland --renderer=gl --disp-sock=$ANLAND_SOCKET --socket=wayland-anland
# 或
dbus-run-session -- startplasma-wayland
# 或裸 KWin 冒烟（不等 plasma-workspace）
kwin_wayland --no-lockscreen --no-global-shortcuts --socket wayland-0
```

启动后用 `wayland-info | grep dmabuf` 自检（必须看到 `zwp_linux_dmabuf_v1`）。

### 5.5 其余接线

| 接线 | 说明 |
|---|---|
| `--gpu` | 映射 `/dev/kgsl-3d0` |
| `--bind /dev/dri:/dev/dri` | `ANLAND_DRM_DEVICE` 路径需要（`--gpu` 不含 DRM 节点） |
| 网络补丁 | `ip route add default via 172.28.0.1 dev eth0 onlink` + `resolv.conf` 写 223.5.5.5（容器重启会丢） |

**坑 3：apt 会把 Mesa 盖回去。** `apt-get install` 任何拉 `libgl1-mesa-dri` /
`mesa-libgallium` 的包都会把 `dri/libdril_dri.so` 覆盖回 Debian 自带的 25.0.7，
lfdevs 的补丁驱动就没了。**装完任何 apt 包后必须重解一次 lfdevs 的 tar**，
并 `apt-mark hold`：

```sh
apt-mark hold xwayland kwin-common kwin-data kwin-wayland libkwin6 weston \
  libweston-14-0 libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 \
  mesa-libgallium mesa-vulkan-drivers
```

不再需要：seatd / libseat（KMS 会话用）、活动 VT、udev 的 `MODALIAS` 伪造。
anland 不经 KMS，没有 `Timeout waiting session to become active` 这类问题。

## 六、排障判据（避免重走弯路）

| 症状 | 真因 | 备注 |
|---|---|---|
| `MESA-LOADER: failed to retrieve device information` | **良性**：`drm_get_pci_id_for_fd` 只服务 PCI 路径 | 不是根因 |
| `failed to create dri2 screen`（发行版 Mesa / 自编 Mesa） | 缺 lfdevs 的 #81/#76/#85 补丁 | 换 lfdevs 构建，不要改 Mesa |
| `unknown UBWC version 0x0` | Turnip 不支持 a5xx | 只能走 freedreno GL，不能用 Turnip/Vulkan |
| 软件渲染出画面 | 环境变量没生效（`MESA_LOADER_DRIVER_OVERRIDE` 等） | 判据要求 `GL renderer: FD512` |

## 七、达成判据

**渲染**（每条合成器都必须满足）：

```
GL renderer: FD512                    ← 真 GPU，无 llvmpipe/softpipe
DMA-BUF import extension ... present
```

**上屏**：合成器保持运行、画面实机可见、触摸可交互。

**进度**：

| 合成器 | 现成程度 | 状态 |
|---|---|---|
| Weston（参考实现） | anland 官方 `backend-anland` | ✅ **真机出画**（壁纸/面板/指针/Wayland Terminal 窗口可见） |
| KDE/KWin Wayland | anland 现成 `backend-anland`（`producers/kde/`） | ✅ **完整 Plasma 桌面真机出画**，`OpenGL ES profile renderer: FD512` |
| **wlroots 系（sway）** | 自写 `backend/anland/`（见第八节） | ✅ **真机出画 + 三条判据全过**：`GL renderer: FD512`、`zwp_linux_dmabuf_v1` v4、swaybar/壁纸/指针可见 |
| niri（smithay） | 待写 `backend/anland/` | 进行中 |
| hyprland | 已迁移到 **Aquamarine**（不再是 wlroots） | 需单独的 Aquamarine backend，与 wlroots 那份不同源 |

Weston / KWin / sway 三条通了，说明 **渲染（a5xx/kgsl）→ dmabuf 导入 → 上屏（SurfaceFlinger）→ client 侧 EGL**
整条链在本机是活的。

KWin 冒烟用法（裸合成器，不等 plasma-workspace）：

```sh
kwin_wayland --no-lockscreen --no-global-shortcuts --socket wayland-0
# 然后任意 Wayland client 即可：WAYLAND_DISPLAY=wayland-0 weston-terminal
```

裸 KWin 没有 `org.kde.breeze` 装饰插件，窗口会缺标题栏（`kwin_decorations: Could not locate
decoration plugin "org.kde.breeze"`）——那只是美观问题，装 `plasma-workspace` 后消失。
完整 Plasma 会话用 `dbus-run-session startplasma-wayland`。

## 八、wlroots / niri 的 `backend-anland` 移植指南

Weston 与 KWin 已有现成 producer。wlroots 系（sway / hyprland）和 niri 需要各写一个
前端。**这不是「赌硬件」了** —— 渲染（a5xx/kgsl）、dmabuf 导入、client 侧
`zwp_linux_dmabuf_v1`（坑 6）全部已趟平，剩下是纯软件接线。两者的共性照抄
anland 的 producer 移植指南（协议 README §10）：**vendor `display_producer` 库（拷贝，
不要软链接），再实现一个 backend。**

### 8.1 必须 vendor 的 5 个文件（5-fd 版，与 lfdevs 5.13.3 同源）

来源：lfdevs KWin 补丁里的 `src/backends/anland/`（`display_producer.{c,h}`、
`protocol.h`、`socket_utils.{c,h}`）。**不要**用 Y700 fork 的 4-fd 版（见坑 4）。

producer 的调用契约（详见 `display_producer.h`）：

| 调用 | 时机 |
|---|---|
| `connect_to_deamon(&ctx, socket)` | 启动时。**只握手，保持 fallback 态** |
| `try_exit_fallback(ctx)` | 200ms 定时器里轮询。返回 0 = 拿到 consumer 的 fd + dmabuf，**必须立刻 import** |
| `get_screen_info` / `get_buf_count` / `get_selected_idx` | 每帧：`idx` 是 consumer 当前选中的缓冲 |
| `get_dmabuf_fd_at(i)` / `get_dmabuf_info_at(i, &buf_info)` | import 阶段 |
| `get_buffer_ready_fd(ctx)` | eventfd，consumer 说「画这个 buffer」→ 触发 repaint |
| `get_data_fd(ctx)` + `poll_input_event(ctx, &ev, ms)` | 输入回传 |
| **`trigger_refresh(ctx)`** | **每帧画完后必须调**，否则 consumer 5 秒超时进 fallback |
| `set_fallback_callback` / `is_fallback` / `disconnect` | consumer 掉线时丢弃渲染目标、回到重连循环 |

`buf_info.format` 的 1 = Android `RGBA_8888` = DRM 的 `ABGR8888`，其它按 `XRGB8888`；
`buf_info.modifier` 恒为 0（LINEAR，见 #85）。

### 8.2 wlroots（sway / hyprland 共用）

**已实现并真机跑通（sway 1.10.1 + libwlroots-0.18）**，产物与补丁：
`backend/anland/`（11 个新文件，其中 5 个是 vendor 的 producer 库）+
`include/wlr/backend/anland.h` + `backend/backend.c` / `backend/meson.build` 的注册。
用 `WLR_BACKENDS=anland WLR_RENDERER=gles2 sway` 启动。

真机首测暴露了两个**必须修**的点，照抄代码前先看这里：

**A. gles2 只吃 DMABUF，而本机没有能 PRIME 导出的 DRM 节点。**
`render/gles2/renderer.c` 里 `wlr_renderer_init(..., WLR_BUFFER_CAP_DMABUF)` —— gles2
**只**认 dmabuf。而 `wlr_allocator_autocreate` 的三条路在本机全部死路：

| allocator | 为什么不行 |
|---|---|
| gbm | 要 PRIME fd 导出；`/dev/dri/renderD128` 是 vkms，报 `PRIME export not supported` |
| shm | 要 `WLR_BUFFER_CAP_SHM\|DATA_PTR`，gles2 不给 |
| drm dumb | 要 `drmIsMaster()`，渲染节点不是 |

→ `Failed to create allocator`。**解法：anland 自带一个 `wlr_allocator`，把 consumer 的
dmabuf 当 buffer 池发出去**（也就是 weston/KWin 那条直渲路径）。判据：日志出现
`anland: created dmabuf allocator over the consumer pool`。

⚠️ 钩子不能用 `wlr_backend_is_anland(backend)`：**sway 传进来的是 multi backend**
（anland + 它自带的 headless 输出），那个判断恒为 false。用全局 `wlr_anland_current` 认实例。

**B. `new_output` 必须等 dmabuf import 完成再发。**
sway 一看到 output 就去建 swapchain；此时池子还是空的（consumer 可能还没连上），
`create_buffer` 只能返回 NULL → `Failed to allocate buffer` → 输出被判无效。
解法：`wlr_anland_output` 上挂 `announced` 标志，`try_exit_fallback()` 成功、
`import_buffers()` 拿到 `buf_count > 0` 之后才 `wl_signal_emit_mutable(new_output)`。

构建（容器内，缺包装上即可）：

| 改动 | 说明 |
|---|---|
| 新增 `backend/anland/{backend.c,output.c,meson.build}` + vendor 的 5 个文件 | 模板抄 `backend/headless/`（88+147 行，最简） |
| `backend/backend.c` 的 `wlr_backend_autocreate` | 认 `WLR_BACKENDS=anland`；`ANLAND=1` 时也优先选它 |
| `backend/meson.build` | 把 `anland` 编进 `libwlroots` |

`struct wlr_anland_output` 的呈现路径（照 weston 的 `anland_output_repaint`）：
`idx = get_selected_idx()` → 把 `get_dmabuf_fd_at(idx)` 那块 dmabuf 当渲染目标
（wlroots 0.18 需要把它包成 `wlr_buffer`，参考 `backend/wayland/output.c` 的做法）→
按累计 damage 重绘 → `trigger_refresh()`。

构建（容器内，缺包装上即可）：

```sh
meson setup build --prefix=/usr -Dexamples=false -Dxwayland=enabled
ninja -C build                      # 产出 libwlroots-0.18.so
# 覆盖装上后：
WLR_BACKENDS=anland sway
```

自检：`wayland-info | grep dmabuf` 必须看到 `zwp_linux_dmabuf_v1`（坑 6），
`GL renderer: FD512`。

### 8.3 niri（smithay）

niri v26.04 的 backend 是 `src/backend/` 下的 **`enum Backend { Tty, Winit, Headless }`**
+ 分派方法（`init` / `seat_name` / `with_primary_renderer` / `primary_render_node` /
`render` / `change_vt` / `suspend`…）。**不是 trait，是枚举分派**，所以加一个 variant 即可。

| 改动 | 说明 |
|---|---|
| 新增 `src/backend/anland.rs`（`struct Anland`） | 模板抄 `src/backend/headless.rs`（174 行） |
| `src/backend/mod.rs` | 加 `Anland(Anland)` variant + 每个分派方法一个 match arm |
| backend 选择处（`main.rs`） | `ANLAND=1` 时构造 `Backend::Anland` |

`Headless` 用的正是 **smithay 的 `GlesRenderer`** —— 和 anland 需要的完全一致，
所以渲染那层可以照抄 `headless.rs` 的 `add_renderer()`（`GlesRenderer::new(context)` +
`resources::init` / `shaders::init`）。差异只在「渲染目标」：headless 不上屏，
anland 要把 consumer 的 dmabuf 塞给 smithay 的 buffer 抽象再 `trigger_refresh()`。

### 8.4 三家共用的验收判据

```
GL renderer: FD512                                     ← 真 GPU，无 llvmpipe
wayland-info | grep dmabuf   → zwp_linux_dmabuf_v1     ← client 侧 EGL 能用
合成器保持运行、画面实机可见、触摸可交互
```

## 九、实刷与回滚（已验证 ✅）

`fastboot flash boot`。两个坑：
1. 镜像必须 ≤ boot 分区（lavender 是 64 MiB；ROM 自带 boot.img 比分区大 90 字节，直刷报 `Volume Full`）→ `scripts/make-boot-img.sh` 已自动补齐/截断；
2. 分区里的 AVB footer 是原厂遗留、与当前内核早已不匹配 → **AVB 不拦未签名镜像**，无需动 vbmeta。

临时验证用 `fastboot boot new-boot.img`。回滚：`adb shell su -c 'dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot-backup.img'`，然后 `fastboot flash boot boot-backup.img`。

**Android 侧零影响**：kgsl、fbdev、root 全部正常（`su -c id` → `uid=0 … context=u:r:ksu:s0`）。
