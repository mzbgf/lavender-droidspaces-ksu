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

**由此修正一条旧判据**：`EGL_PLATFORM=surfaceless` 在未打补丁的 Mesa 上 fd 为 -1，
但在打了 #81/#85 的 Mesa 上**正是 anland 的主路径**。旧文档把它判为「判据无效」是
以偏概全 —— 它只对未打补丁的 Mesa 成立。

**发行版原生 Mesa 一律不够用**，必须用 lfdevs 的构建（Release 里有 `debian_trixie_arm64`
等按发行版分的包）。不要自编 Debian Mesa 25.0.7 —— 那是死路里的一步，且缺上述三个补丁。

## 四、硬件上的冷门区（唯一真正的不确定项）

lfdevs 的实测支持表只有 **Adreno 660 / 710–750 / 810–840**（全 a6xx+）。
[Issue #32](https://github.com/lfdevs/mesa-for-android-container/issues/32) 里维护者明说
**「Freedreno (KGSL) 在比 Adreno 660 更老的 GPU 上不工作」**，老卡的建议是改用 unpatched
Turnip + Zink。但 Turnip 只支持 a6xx+，我们的 Adreno 512 是 **a5xx**，Turnip 直接不可用
（实测 `unknown UBWC version 0x0`）。

有利的一面：`freedreno_devices.py` 里**有 `GPUId(510)/GPUId(512)` 的 A5XX 完整定义**，
且我们已实测跑出 `GL renderer: FD512`。所以 **a5xx 在这条生态里是「有定义、无人实测」**，
我们是第一台。这是当前最大的未知。

第二个未知：4.19 内核**没有 dma-heap**（5.6+ 才有），只有 ION。#85 的实现里有
「dma-heap 失败则回退 ION」，但 ION 回退在 4.19 上是否真的可用**未验证**。

## 五、容器侧仍需的接线（已验证 ✅，与架构无关的部分）

| 接线 | 说明 |
|---|---|
| `--gpu` | 映射 `/dev/kgsl-3d0` |
| `--bind /dev/dri:/dev/dri` | 仅当走 `ANLAND_DRM_DEVICE` 路径时需要（`--gpu` 不含 DRM 节点） |
| `MESA_LOADER_DRIVER_OVERRIDE=kgsl` | freedreno 走 kgsl 后端 → FD512 |
| 网络补丁 | `ip route add default via 172.28.0.1 dev eth0 onlink` + `echo nameserver 223.5.5.5 > /etc/resolv.conf`（容器重启会丢） |

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

**渲染**（三条合成器都必须满足）：

```
GL renderer: FD512                    ← 真 GPU，无 llvmpipe/softpipe
DMA-BUF import extension ... present
```

**上屏**：合成器保持运行、画面出现在 Android 显示端（Anland 的 APK / Droidspaces 显示面），触摸可交互。

**三家**：

| 合成器 | 现成程度 | 做法 |
|---|---|---|
| KDE/KWin Wayland | anland 有现成 `backend-anland`（`producers/kde/`） | 直接用，**先打通这条**（一次性验证 a5xx + ION 的 dmabuf 上屏） |
| Weston | 现成，参考实现 | 作对照组 |
| wlroots 系（sway / hyprland） | 无现成 port | 按 anland 的 producer 移植指南：vendor `display_producer` 库 + 实现 `backend-anland` |
| niri（smithay，非 wlroots） | 无现成 port | 同上 |

## 八、实刷与回滚（已验证 ✅）

`fastboot flash boot`。两个坑：
1. 镜像必须 ≤ boot 分区（lavender 是 64 MiB；ROM 自带 boot.img 比分区大 90 字节，直刷报 `Volume Full`）→ `scripts/make-boot-img.sh` 已自动补齐/截断；
2. 分区里的 AVB footer 是原厂遗留、与当前内核早已不匹配 → **AVB 不拦未签名镜像**，无需动 vbmeta。

临时验证用 `fastboot boot new-boot.img`。回滚：`adb shell su -c 'dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot-backup.img'`，然后 `fastboot flash boot boot-backup.img`。

**Android 侧零影响**：kgsl、fbdev、root 全部正常（`su -c id` → `uid=0 … context=u:r:ksu:s0`）。
