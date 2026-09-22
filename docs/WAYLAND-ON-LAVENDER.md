# 在 lavender（Adreno 512 / KGSL / 4.19）上跑 GPU 加速 Wayland 的实现路径

目标：让 wlroots 系（sway/hyprland）、KDE（KWin）、niri 都能**真机工作**，且**不使用软件渲染。

本文记录**实测验证过的**路径与判据，以及踩过的每一个坑。所有标 ✅ 的项都有真机证据。

## 一、设备的图形栈现状（实测）

| 项 | 状态 |
|---|---|
| 显示 | CAF 传统 fbdev：`FB_MSM` + `FB_MSM_MDSS`（无 DRM） |
| GPU | KGSL：`QCOM_KGSL`，节点 `/dev/kgsl-3d0`，**Adreno 512**（a5xx） |
| 用户态 | Android 的 adreno 栈（`ro.hardware.egl=adreno`） |

**关键约束**：原生内核**没有 DRM 子系统**（无 `/dev/dri`、无 `/sys/class/drm`），而 wlroots/Aquamarine/niri 的渲染器**硬性要求一个 DRM fd**（`drmGetDevices2` → `no DRM FD available`）。这是三家合成器在本机的共同阻塞点。

## 二、内核侧改动（6 个补丁，全部真机验证 ✅）

基座：`user-why-red/android_kernel_xiaomi_sdm660_419`（San-Kernel），配方仓库 `mzbgf/lavender-droidspaces-ksu`。

| 改动 | 作用 | 判据 |
|---|---|---|
| 配置 `CONFIG_DRM=y` + `CONFIG_DRM_VKMS=y` | 提供虚拟 KMS 显示卡 | `/dev/dri/card0` 出现 ✅ |
| `buildfix/0005` vkms gem fault 返回 `vm_fault_t` | 4.17 起签名变化，否则编译不过 | 编译通过 ✅ |
| `buildfix/0006` `DRIVER_RENDER` | 产生渲染节点 | `/dev/dri/renderD128` 出现 ✅ |
| `buildfix/0007` `unique = "platform:vkms"` | libdrm 需要带总线前缀的 busid | `drmGetBusid` → `platform:vkms` ✅ |
| `buildfix/0008` 挂 `drm.dev` | （被 0009 取代，保留无害） | — |
| `buildfix/0009` minor 的 `kdev->parent` 指向平台设备 | `drm_sysfs_minor_alloc` 在 `drm_dev_init` 时就固定 parent，事后赋值无效；补挂后 sysfs 出现 `device → bus/platform` | `drmGetDevice2` 返回 0 ✅ |
| `buildfix/0010` `drm_getunique` 在 master 未初始化时回退到 `dev->unique` | `GET_UNIQUE` 在 `SET_VERSION` 前故意返回空（drm 1.0 约定）；虚拟设备的 busid 只能从这里拿 | 不调 `SET_VERSION` 也能读到 busid ✅ |

**Android 侧零影响**：kgsl、fbdev、root 全部正常（`su -c id` → `uid=0 … context=u:r:ksu:s0`）。

**实刷方式**（已验证）：`fastboot flash boot`。两个坑：
1. 镜像必须 ≤ boot 分区（lavender 是 64 MiB；ROM 自带 boot.img 比分区大 90 字节，直刷报 `Volume Full`）→ `scripts/make-boot-img.sh` 已自动补齐/截断；
2. 分区里的 AVB footer 是原厂遗留、与当前内核早已不匹配 → **AVB 不拦未签名镜像**，无需动 vbmeta。

回滚：`adb shell su -c 'dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot-backup.img'`，然后 `fastboot flash boot boot-backup.img`。

## 三、容器侧接线（已验证 ✅）

Droidspaces 容器（Debian 13）需要：

| 接线 | 说明 |
|---|---|
| `--gpu` | 映射 `/dev/kgsl-3d0`（属组 `droidspaces-gpu`） |
| `--bind /dev/dri:/dev/dri` | **`--gpu` 只映射 kgsl，不含 DRM 节点**，必须手动绑 |
| `--bind /dev/input:/dev/input` | libinput（KMS 合成器要用） |
| `--bind /sys/devices:/sys/devices --bind /sys/dev:/sys/dev` | libdrm 要读 `device/subsystem` |
| udev（`systemd-udevd`）+ udev 规则 | libdrm 用 udev 枚举设备 |
| seatd + libseat | KMS 合成器的会话（`Seat opened with backend 'seatd'` ✅） |
| `MESA_LOADER_DRIVER_OVERRIDE=kgsl` | Mesa 的 freedreno 走 kgsl 后端 → **FD512** |

**udev 规则**（虚拟 DRM 设备的 drm minor 不带 `MODALIAS`，libdrm 判不出总线类型会拒收）：

```
# /etc/udev/rules.d/70-drm-modalias.rules
SUBSYSTEM=="drm", ENV{DEVTYPE}=="drm_minor", ENV{MODALIAS}="platform:vkms"
```

注意：udev 规则的匹配键必须写 `ENV{DEVTYPE}` 而不是 `DEVTYPE`（后者报 `Invalid key` 整条规则被丢弃）。

## 四、用户态（Mesa）的两个必要修复

**已验证**：`EGL driver name: kgsl`、`GL renderer: FD512`（Adreno 512）、`OpenGL ES 3.1 Mesa 26.3.0` —— **真 GPU 渲染，无软件渲染** ✅。

| 修复 | 位置 | 原因 |
|---|---|---|
| 上报 PRIME 能力位 | `src/gallium/drivers/freedreno/freedreno_screen.c`：`pscreen->caps.dmabuf = DRM_PRIME_CAP_IMPORT \| DRM_PRIME_CAP_EXPORT;` | kgsl winsys 的 `fd_bo_from_dmabuf`/`fd_bo_dmabuf` **早已实现**，但没上报能力位 → `EGL_EXT_image_dma_buf_import` 被关闭 → wlroots 的 GLES2 渲染器在 `renderer.c:505` 失败 |
| 驱动名查找尊重 override | `src/loader/loader.c` 的 `loader_get_driver_for_fd` | 该函数按 **PCI ID** 映射驱动名，vkms 是 PLATFORM 设备拿不到 → 建 screen 失败 |

注意 `pscreen->caps` 是 **const**，不能直接赋值（`assignment of member 'dmabuf' in read-only object`），要用指针写入。

## 五、排障判据（避免重走弯路）

| 症状 | 真因 | 备注 |
|---|---|---|
| `MESA-LOADER: failed to retrieve device information` | **良性**：`drm_get_pci_id_for_fd` 只服务 PCI 路径，PLATFORM 设备必然返回 false | 不是根因 |
| `EGL_PLATFORM=surfaceless` 下 segfault / `fd -1` | surfaceless 平台**不挂 DRM 设备**，fd 无效 | **判据无效**，必须用 wlroots 的 device 路径测 |
| `GET_UNIQUE` 返回空 | drm 1.0 约定：`SET_VERSION` 之前故意为空 | 已由 0010 修掉 |
| `failed to create dri2 screen` | 驱动名查找（PCI-only）或 `libdril` 垫片与 `libgallium` ABI 不匹配 | 见下 |

## 六、当前唯一未闭合项（下一步）

**Mesa 的 EGL/GBM 在 vkms 上建 screen 失败**（`DRI2: failed to create screen`）。已排除：文件缺失、依赖缺失、PCI 假设（两处都已修）、surfaceless 误判、垫片/libgallium 版本不匹配（已改用同源构建）。

**正确的 Mesa 构建路线**（实测，务必照此）：
- 用 lfdevs 的 **`adreno-debian-trixie` 分支**（Debian 打包布局，含 `debian/`）；
  `adreno-main` 与发布 tag **都没有 `debian/`**，`gbp buildpackage` 会直接失败
- 依赖用 `mk-build-deps -i debian/control`（**不要**把 `mk-build-deps` 写进 apt 包名——
  它不是独立包，会让整个 apt 事务失败）
- 构建：`origtargz` + `dpkg-buildpackage -us -uc -b`
- 产物的**正确包名**：`libgl1-mesa-dri`（DRI 驱动 + `libdril` 垫片）、`mesa-libgallium`、
  `libegl-mesa0`、`libgbm1`、`libglx-mesa0`、`libosmesa6`、`mesa-va-drivers`、
  `mesa-vdpau-drivers`、`mesa-vulkan-drivers` —— 其中前两个是关键，缺了就会
  `failed to create dri2 screen`
- 带上本文第四节的两个修复再构建

## 七、渲染链路的完整判据（通过即为达成）

```
[wlr] Opening DRM render node '/dev/dri/renderD128'
[wlr] Using EGL device /dev/dri/card0
[wlr] EGL driver name: kgsl
[wlr] DMA-BUF import extension ... present          ← 目标
[wlr] Creating GLES2 renderer
[wlr] GL vendor: freedreno
[wlr] GL renderer: FD512                            ← 目标（真 GPU）
（sway 保持运行、不再 exit=1）                      ← 目标
```

达成后依次验证 hyprland（Aquamarine，同一渲染路径）、niri 与 KWin（需 KMS 会话激活；seatd 已就绪，容器缺活动 VT 时会报 `Timeout waiting session to become active`）。
