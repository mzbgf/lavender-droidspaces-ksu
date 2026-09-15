# lavender 内核：Droidspaces + reSukiSU（Android 16 / 4.19）

给 Xiaomi Redmi Note 7 / 7S（**lavender**，高通 SDM660）的 Android 16 内核，
在 recovery 里直刷的 AnyKernel3 包：

- **Droidspaces**：按 `ravindu644/Droidspaces-OSS` 官方的非 GKI 清单补齐内核配置
  （PID/UTS/IPC/NET/USER namespace、cgroup v1 全套、seccomp、overlayfs、
  veth/bridge/netfilter NAT 等），并打上官方与社区验证过的配套补丁，
  可以在手机上跑完整 Linux 发行版（systemd/OpenRC 作 PID 1、Podman/Docker 嵌套）。
- **reSukiSU**（KernelSU 系）：4.19 非 GKI 只能走 **manual hook**，已按官方文档
  挂好 stat/execve/faccessat/sys_reboot 四组 hook 并导出 SELinux 符号。
- **不启用 SUSFS**：`CONFIG_KSU_SUSFS` 显式关闭，`check-configs.sh` 会强制断言。

产物：`AnyKernel3-lavender-4.19.325-<版本串>-<日期>.zip`

---

## 为什么是 4.19 而不是 4.4

lavender 出厂内核是 4.4，但 **Android 16 在 lavender 上没有 4.4 生态**：

- LineageOS 官方早已停止支持 lavender（最后是 18.1 / Android 11）；
  它在 Android 16 发布说明里给出的 SoC↔内核↔Android 对照表明确写着
  「SDM660 → 4.19 → 支持到 Android 16」，而 4.4 的 MSM8998/MSM8996 一栏止步 Android 15。
- lavender 现存所有 Android 16 ROM（Lunaris、Matrixx、DerpFest、PixelOS、
  Infinity-X、crDroid、Axion…）内核都是 `4.19.325` 这条线。本机这台 ROM 上，
  实际刷的是 San-Kernel（版本串 `4.19.325-st19-San-Kernel-Aegis-R1.1.108`），
  它也正是本配方选择的基座源码线（见下一节）。
- 要在 4.4 上跑 A16，需要把 4.14~5.4 的 eBPF 特性整套 backport 回来
  （唯一公开成功案例是三星 Exynos 8895 的 S8，做这事的开发者花了数月），
  lavender 圈没人做过，也没有对应 ROM。

所以本方案建立在 **Linux 4.19.325** 上。

## 用哪个源码

| 项 | 值 |
|---|---|
| 仓库 | `user-why-red/android_kernel_xiaomi_sdm660_419`（San-Kernel，GPL） |
| 分支 | `back`（该仓默认分支） |
| 固定 commit | `6d41c71e301a3c3394167dc5ef03cbc846ae6772` |
| 内核版本 | 4.19.325，`CONFIG_LOCALVERSION="-San-Kernel-Aegis-R1.1.108"` |
| 基座 defconfig | `arch/arm64/configs/vendor/lavender-perf_defconfig`（设备专属） |
| 为什么是它 | **它是本机真机实测唯一能开机的那条源码线** —— 见下一节 |

### 为什么换掉了 pix106/SouthWest-NG（根因记录）

最初用的是 `pix106/android_kernel_xiaomi_sdm660_southwest-ng` @ `b2ee0c8`（0.19.4），
理由是「版本串与 ROM 一致」。但那个内核在真机上**必定**在开机约 8 秒时崩：

```
Internal error: Oops: 96000005 [#1] PREEMPT SMP
Process kworker/u17:0        Workqueue: devfreq_wq devfreq_monitor
pc : try_to_wake_up+0x504/0xafc     lr : default_wake_function+0x14/0x1c
Call trace（中断侧）:
  complete <- mmc_wait_done <- mmc_request_done <- sdhci_request_done <- sdhci_tasklet_finish
而同一个工作线程当时正停在（任务侧）:
  mmc_clk_update_freq <- mmc_devfreq_set_target <- update_devfreq <- devfreq_monitor
Kernel panic - not syncing: Fatal exception in interrupt
```

逐个假设都用真机实验打掉了：

| 假设 | 结论 | 依据 |
|---|---|---|
| 重打包流程有问题 | ✗ 排除 | `fastboot --cmdline` 注入标记，镜像起来后 `/proc/cmdline` 带标记，确认跑的就是我们这份 |
| 打包时混入多机型 dtb | ✗ 排除 | 单 lavender dtb 的版本照样崩 |
| dtb 来源不对 | ✗ 排除 | 两棵树的 `sdhci@c0c4000` 节点逐属性一致，`qcom,devfreq,freq-table` 两边都有 |
| reSukiSU 引入 | ✗ 排除 | 关掉 KSU 的构建照样崩 |
| `FAIR_GROUP_SCHED` / `DEVFREQ_BOOST` | ✗ 排除 | 各自单独关掉后仍崩 |
| **基座源码线** | ✅ **根因** | 换成本仓库这棵树后，**同一套工具链（clang 12.0.5）、同一套打包流程**，`fastboot boot` 一次成功 |

关键对照数据：两棵树的 mmc 代码几乎逐字相同（`drivers/mmc/core/core.c` 差 47 行且全是
SD-Express/日志噪音，`sdhci-msm.c` 差 20 行全是 `pr_info` 格式与返回值检查，
`sdhci.c` 差 7 行，`completion.c`/`host.c`/`queue.c` 零差异）。真正有差异的是
`sched/core.c`（886 行）、`rcu/tree_plugin.h`（2609 行）以及 1115 条配置项。
所以崩在 mmc devfreq 只是「内存先被弄坏、这里第一个撞上」，不必继续往下猜 ——
能开机的那棵树就是依据。

**版本串（`uname -r`）**：树根带 `localversion-st`（`-st20`），kbuild 会把它接在
`CONFIG_LOCALVERSION` 之前，所以本配方构建出的版本串是：

```
4.19.325-st20-San-Kernel-Aegis-R1.1.108
```

（设备上那个已刷入的 San-Kernel 是 `-st19-`，因为它来自该仓更早的一次发布构建；
本配方固定在 `back` 分支 2026-09-14 的 commit 上。）

**这个版本串对刷机是硬要求吗？不是。** 本树 defconfig（以及本配方产出的 `.config`）
里 `MODULES` 是关闭的——内核**完全没有模块支持**，因此没有任何东西会去校验版本串：
刷一个 `uname -r` 与 ROM 原内核不同的内核完全可以正常开机。同 SoC 的 Android 16 ROM
也都是这种单体内核（例如 Project Infinity X 的原厂内核 config 同样是 MODULES 关闭）。

唯一会出问题的情形是：你 ROM 的 `/vendor`（或 `/system`）里真的带着需要加载的 `.ko`。
那种情况下内核必须是 `MODULES=y`，而且版本串要与那些 `.ko` 一致，才谈得上加载。
设备上 10 秒就能查清：

```sh
su -c 'ls /vendor/lib/modules /system/lib/modules 2>/dev/null'   # 空 = 没有模块，版本串无关
su -c lsmod
```

有输出再处理（按 `configs/00-rom-align.config` 里的说明，换 `KERNEL_PIN` 到对应
`0.x.x` 分支，或用 workflow_dispatch 的 `localversion` 输入项覆盖）。本配方仍然沿用
基座 defconfig 的 LOCALVERSION，只是因为那是 ROM 这条源码线的原值、保持一致零成本；
`check-configs.sh` 里的 LOCALVERSION 断言是用来防止合并过程把它悄悄改掉（真发生过），
并不是要求它与 ROM 必须相等。

---

## 构建

### 云端（推荐，零环境依赖）

前提：一个 GitHub 仓库（public 免费且 runner 是 4 vCPU/16 GB；private 只有 2 vCPU，构建时间约翻倍）。

```bash
gh repo create <你的账号>/lavender-droidspaces-ksu --public
git remote add origin https://github.com/<你的账号>/lavender-droidspaces-ksu
git push -u origin main
```

- push 到 `main` 或手动触发 `workflow_dispatch` 即开始构建（约 20~40 分钟；ccache 命中后 5~10 分钟）。
- 打 tag（`git tag v1 && git push --tags`）会额外发一个 Release，附件就是刷机包。
- 需要临时改版本串时，`workflow_dispatch` 有个 `localversion` 输入项。

> 为什么不在 macOS 上直接编：4.19 时代 AOSP 预编译 clang 只有 **linux-x86_64** 版，
> 在 macOS 上根本执行不了；此外内核源码里有仅大小写不同的文件，需要区分大小写的卷，
> 还要另配 GNU make/sed/grep。宿主机架构不影响产物（内核是交叉编译成 arm64 的），
> 影响的只是「能不能跑工具链」和速度。

### 本地 / 容器（离线兜底）

任意 Linux x86_64 环境（或本机 OrbStack 跑 `--platform linux/amd64` 容器）里：

```bash
bash scripts/build-local.sh    # 拉源码（按固定 commit）→ 装工具链 → 全流程构建
```

注意：**不要把内核源码直接 bind-mount 到 macOS 的大小写不敏感卷上**，
请在容器内 clone。构建需要约 30 GB 磁盘。

---

## 构建状态：已验证 / 未验证

> **2026-09-16 补充：CI 产物 60~90 秒崩溃的根因已查明并修复，但修复后的 CI 产物
> 尚未在真机上复验（见本行下方「本次事故」）。在复验通过之前，请以本地构建的
> 产物为交付依据。**

### 本次事故：CI 与本地构建「同源不同配置」的静默分叉（已修）

- **现象**：CI 产物（GitHub Actions，AOSP clang r416183b）在真机上开机约 54 秒时
  `kswapd0` 在回收路径空指针 oops（`pc : buffer_check_dirty_writeback+0x70/0xa0`），
  之后整机僵死/重启；本地产物稳定。
- **根因**：`scripts/merge-configs.sh` 解析配置时没有把工具链参数传给 `make`，
  kbuild 于是用宿主机的 `gcc` 去做 Kconfig 的编译器能力探测。CI runner 的 GCC 11
  不认识 `-ftrivial-auto-var-init`，本机容器的 GCC 12 认识 —— 三选一 `INIT_STACK`
  因此静默分叉：**CI=`NONE`（不做栈变量初始化）、本地=`ZERO`**。
  两份产物的编译、断言、打包全部照常通过，只有真机行为不同。
- **证据**：同一棵树、同一份片段，配置阶段用「不认识该选项的编译器」跑 →
  `INIT_STACK_NONE=y`；带上工具链参数（真 clang）跑 → `INIT_STACK_ALL_ZERO=y`。
  两份产物的 `.config` 差异只有 12 行：4 行编译器版本串 + 这两项。
- **修复**：① `merge-configs.sh` 解析配置时传齐 `LLVM=1`/`CC`/交叉前缀（治根）；
  ② `configs/30-boot-compat.config` 显式钉住 `INIT_STACK_ALL_ZERO` **和 `LTO_NONE`**
  （同一个 bug 还让基座 defconfig 想开的 ThinLTO 被静默降级成了 NONE，而真机验证过的
  基线正是 NONE，所以这里明确钉住以保持一致；要启用 ThinLTO 属于独立的代码生成变更，
  须单独真机 A/B 验证）；
  ③ `check-configs.sh` + `verify-artifacts.sh` 断言（漂移即构建失败）。
- **状态**：修复后的配置解析结果与真机验证过的基线 `.config` **逐字节一致**；
  CI 重建 + 真机复验待做。

**已验证（真机 `fastboot boot` 实测，逐项有证据）**

内核侧（构建产物中直接核验）：

- 内核编译通过，`Image.gz-dtb` 12.8 MiB，产物 `uname -r` 为
  `4.19.325-st20-San-Kernel-Aegis-R1.1.108`；
- 镜像里含 lavender 的 dtb（型号串 `… SDM 660 PM660 + PM660L MTP, Lavender`，1 个 dtb）；
- reSukiSU 确实编入内核：`drivers/kernelsu/*.o` 有编译、构建日志 `using Manual Hook`、
  内核侧版本号 35144、镜像里能搜到 `@ReSukiSU` 版本串；
- `CONFIG_KSU_SUSFS` 未启用，构建日志里没有任何 susfs 的编译；
- Droidspaces 核心项、网络隔离项、KernelSU 项、开机关键项全部由 `check-configs.sh`
  逐项断言，任一失败即构建失败。

真机侧（`fastboot boot` 临时启动 + `scripts/verify-on-device.sh` 自动检查 15 项全过，
并由使用者实际使用确认）：

- `uname -r` 与产物一致；`/proc/cmdline` 带本次注入的临时标记，确认跑的就是这份镜像；
- **稳定性**：连续在线约 20 分钟（uptime 1188s）无 oops / panic，`kshrinkd0` 线程存活，
  `dmesg` 里 0 条 `Unable to handle` / `Kernel panic`。对照：修 `buildfix/0004` 之前，
  同一台机器稳定在开机 **53 秒**时因 `shrink_slab_memcg` 空指针 oops 而 panic 重启；
- **root 可用**：装与内核同版本的 reSukiSU 管理器（`v4.2.0-rc2` / 35144）后
  `su -c id` 返回 `uid=0(root) … context=u:r:ksu:s0`，`/system/bin/su` 由 KSU 挂载出来；
  （版本错配会失败：管理器版本必须 ≥ 内核侧 KSU 版本，这一点写进了排错表）
- **Droidspaces 依赖的运行时能力全部就绪**：cgroup 控制器 `devices`/`pids`/`memory`/
  `freezer`/`net_prio` 都在 `/proc/cgroups` 里；`overlay` 文件系统可用；
  `ipc`/`mnt`/`net`/`pid`/`user`/`uts` 六个 namespace 都在 `/proc/self/ns` 里；
- **Droidspaces 实际可用**：能创建 `Alpine minimal` 容器并通过 NAT 联网；
- 日常功能正常：Wi-Fi、蓝牙、移动信号、触摸、相机。

作为对照：设备上原先那个内核（San-Kernel 官方发布版）不带本配方的 KSU 与管理器匹配版本，
`cgroup devices/pids/net_prio` 与 `ipc/pid/user/uts` namespace 也不可见。

**未验证（需要你自己确认）**

- **实际刷入 boot 分区**后的表现（目前全部验证都走 `fastboot boot` 临时启动，从未写入分区）。
  临时启动与真实刷入共用同一份内核与同一个 ramdisk，但刷入后还牵涉 recovery 的
  AnyKernel3 流程；
- Droidspaces 的「高级硬件功能」（GPU / 直接硬件访问等）尚未测试；
- 长时间（数天）使用与待机功耗表现。

刷机前请务必读完下一节的备份与回滚步骤。

---

## 先临时验证：`fastboot boot`（不写分区）

想先确认内核能不能起来、又不想动 boot 分区，可以做成一个 boot.img 直接 `fastboot boot`：
镜像只加载进内存启动一次，重启就回到原内核。

**第 1 步：拿到 ROM 原厂的 boot.img**（ramdisk 必须用 ROM 自己那份）

```sh
# 从 ROM 安装包里取
unzip -o <ROM>-lavender-*.zip boot.img -d /tmp/rom/

# 或者从设备上拉（recovery 里执行，再 adb pull）
dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/stock-boot.img
```

如果你这台机器现在刷的已经是第三方内核，dd 出来的是那份内核 + 同一份 ramdisk，
拿来做验证也没问题。

**第 2 步：重打包**（用 magiskboot —— 就是 AnyKernel3 在设备端用的那个工具；
macOS 上脚本会自动用 OrbStack/Docker 跑 Linux 版 magiskboot，arm64 原生速度）

```sh
bash scripts/make-boot-img.sh --stock stock-boot.img \
     --kernel AnyKernel3-lavender-*.zip -o new-boot.img
```

脚本会自校验：新镜像里的 ramdisk 与原厂**逐字节一致**、kernel 确实换成了我们的产物，
并把原厂的 `HEADER_VER` / `PAGESIZE` / `CMDLINE` 打印出来。想验证工具的打包逻辑本身，
可以跑 `bash scripts/tests/selftest-boot-img.sh`（造一个合成原厂镜像走完整流程，CI 里也会跑）。

**第 3 步：临时启动**

```sh
adb reboot bootloader
fastboot boot new-boot.img
```

起来后按下一节的「刷完怎么验」自检；确认没问题再刷 AnyKernel3 包落盘。

> 两个注意点：① 某些机型的 bootloader 会拒绝 `fastboot boot`（报
> `FAILED (remote: ...)` 之类），那就只能走 recovery 刷包；② `fastboot boot` 虽然不写
> 分区，但系统仍会正常挂载 `/data` 启动，所以**不是零风险**——坏镜像一样会影响数据，
> 重要数据先备份。

---

## 刷机

1. **先备份 boot 分区**（recovery 里执行，或 OrangeFox/TWRP 的备份功能）：
   ```sh
   dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot-stock.img
   ```
   备好 fastboot 回退通路（`fastboot flash boot boot-stock.img`）。
2. recovery 里刷 `AnyKernel3-lavender-*.zip`。
3. 重启，检查 `uname -r` 是否与预期一致，以及 wlan/蓝牙是否正常。

> 本包只替换 boot 分区里的内核，复用 ROM 现有 ramdisk；**不动 dtbo、不动 vbmeta**。
> lavender 是 A-only 设备，所以包里的 anykernel.sh 用 `BLOCK=auto; IS_SLOT_DEVICE=auto;`。

## 刷完怎么验

```sh
uname -r                          # 与 CI 打印的 kernelrelease 一致
su -c id                          # 应返回 uid=0（先装好管理器 APK）
su -c 'droidspaces check'         # 等价于 App 里的 Requirements Check
```

- **reSukiSU 管理器**：从 ReSukiSU 的 release 页面单独下载 APK 安装
  （内核与管理器版本号必须同档，否则依赖 sepolicy 的模块会失效）。
  首次进入 App 会提示授权。
- **Droidspaces**：装官方 App 后，`Settings → Requirements → Check Requirements`
  应无红叉；建议先起一个 Debian 13 容器验证 PID 1 与 NAT 网络。

## 已知限制（来自同 SoC 机型的真机记录）

- 4.19 CAF 树**没有 `/dev/dri` render node**（只有 `/dev/kgsl-3d0`），
  所以容器里只能 llvmpipe 软件渲染；`enable_virgl` 会崩。
- Droidspaces 的 `enable_hw_access=1` 在这些机器上会导致整机假死，
  保持 `0` 并只做 `/dev` 隔离。
- systemd ≥ v258 的发行版（Arch/Fedora/openSUSE）在 4.4~4.19 上会硬失败
  （缺 `clone3`/`openat2`），请用 Debian 12/13、Ubuntu 22.04~24.04 或 Alpine。
- 4.19 上跑容器时，Android 自身的 seccomp/SELinux 会更严；本方案用内核态的
  KernelSU，不受 root-domain seccomp 影响（Magisk/APatch 才需要开 Daemon Mode）。

## 排错

| 现象 | 排查方向 |
|---|---|
| 刷完卡开机 logo | ramdisk 解压配置：确认产物 `.config` 里 `CONFIG_RD_LZ4=y` |
| 刷完能开机但 wlan/蓝牙坏 | 先确认 ROM 是否带 `.ko`（`su -c 'ls /vendor/lib/modules'`）。若带，多半是内核与那些 `.ko` 的版本串/配置不一致：比对 `uname -r`，必要时换 `KERNEL_PIN`。若不带（本机型 A16 ROM 的常态），去查驱动内置项是否被改动 |
| 开机极慢 / lmkd 报错 | 确认 `CONFIG_PSI=y`（脚本已断言） |
| `droidspaces check` 有红叉 | 看 CI 里 `check-configs.sh` 的输出；容器网络不通多半是 NAT 相关项缺失 |
| 进不去 root / KSU safe mode | 本树 `CONFIG_KPROBES` 已关闭；若仍进 safe mode，检查 hook 是否被上游改动影响 |
| 刷完屏幕只剩背光、一直卡着 | 本基座 defconfig 里 `PANIC_ON_OOPS` 是开的、`PANIC_TIMEOUT` 是 `-1`：任何 oops 都会立刻 panic 且永不自动重启。已由 `configs/30-boot-compat.config` 改成「oops 只杀任务 + panic 后 5 秒重启」。真正的 panic 日志去 recovery 里读 `/sys/fs/pstore/console-ramoops-0` |
| 装好管理器后 `su` 仍不可用 / 管理器报「版本过低」 | 管理器版本必须 **≥ 内核侧 KSU 版本**（本产物为 35144，对应 reSukiSU `v4.2.0-rc2`）。升级管理器后**必须再重启一次**：KSU 的 `su`/`ksud` 用户态是在开机 `post-fs-data` 阶段建立的，只在当前这次启动中升级 APK 不会生效。成功判据：`su -c id` 返回 `uid=0 … context=u:r:ksu:s0`，且 `/system/bin/su` 出现 |
| 开机约 30~55 秒后卡死并自动重启 | 本树有个私有的 `kshrinkd` 线程（上游 4.19 没有），它循环的第一次迭代传 `memcg = NULL`，而 `shrink_slab()` → `shrink_slab_memcg()` 会直接解引用这个 NULL → oops；设备上 `panic_on_oops=1`，于是立刻 panic 重启。已由 `patches/buildfix/0004-kshrinkd-null-memcg.patch` 修掉。判据：pstore 里出现 `Process kshrinkd0` + `pc : shrink_slab_memcg+0x80` + `NULL pointer dereference at ...007c` |
| 设备配置与我编的对不上：`/proc/config.gz` 里 `KSU`/`CGROUP_*` 全是关的 | **本基座树把 `IKCONFIG` 的数据源硬编码成了厂家的完整 defconfig**（`kernel/Makefile` 里 `config_data.gz` 的依赖写死为 `arch/arm64/configs/vendor/sdm660-perf-full_defconfig`），所以 `/proc/config.gz` 报的是厂家那份配置，**与当前运行内核的真实配置无关**，不能用它做断言。要判断真实配置请看运行时能力（`/proc/cgroups`、`/proc/self/ns`、`/proc/filesystems`）或构建时的 `out/.config` |
| 本地构建报「预检失败，补丁与源码树不匹配」 | 十有八九不是补丁的问题，而是容器里**缺 `patch` 命令**（旧版镜像就缺，缺命令被报成了补丁不匹配）。现在的镜像已补齐，且 `apply-patches.sh` 会打印补丁的真实错误 |
| 构建日志里出现 `Error in reading or end of file.` | **别再当噪音忽略**（上一版这里就是这么写的，后来查出一整次事故）。`make` 在解析配置时会跑一次交互式提问，读到 EOF 就取**默认值**；而 Kconfig 里有一批符号的默认值来自编译器能力探测，于是同一份片段在不同宿主机上会合出不同结果。2026-09-16 查实的一次：配置阶段没传工具链参数，探测落到宿主机 `gcc`（CI runner 是 GCC 11、本地容器是 GCC 12），`INIT_STACK` 三选一因此分叉成 CI=`NONE` / 本地=`ZERO`，而 `NONE` 那份真机开机约 54 秒必崩（见下一行）。现已在 `scripts/merge-configs.sh` 里把工具链参数传齐，并把这一项显式钉住 + 断言 |
| 开机约 54 秒、`kswapd0` 在回收路径空指针 oops，随后整机僵死（或重启） | 内核没做栈变量初始化（`INIT_STACK_NONE`）。本基座树 backport 的 MGLRU 回收路径 `lru_gen_shrink_lruvec` → `evict_pages` → `shrink_page_list` → `buffer_check_dirty_writeback` 会在某种页状态下解引用空指针，栈变量零初始化（`ALL_ZERO`）时不会走到那里。判据：dmesg 里 `Process kswapd0` + `pc : buffer_check_dirty_writeback+0x70/0xa0` + `lr : shrink_page_list+0x4e0`，之后 `dumpsys`/`adb shell` 全部无响应。已由 `configs/30-boot-compat.config` 钉住 `INIT_STACK_ALL_ZERO` + `check-configs.sh`、`verify-artifacts.sh` 两道断言守住 |
| 本地改了 `Dockerfile` 却不生效 | 镜像是按需构建的，判据是 `docker/.build-state` 里记的那份 Dockerfile mtime：不一致就会自动重建。只有状态文件缺失时（新机器/首次运行）才不重建，那时用 `FORCE_IMAGE=1` |
| 改了 `Dockerfile` 但**不想**重建（重建要重下整个工具链） | 把新 mtime 直接写进记录，让它看起来一致——此时记录里的 mtime 并不代表镜像真的来自这份 Dockerfile：`printf 'lavender-builder-native:4.19 %s\n' "$(stat -f %m docker/Dockerfile.native)" > docker/.build-state` |
| 本地 arm64 镜像（1.77 GB 单层）比 `Dockerfile.native` 里写的构建过程「小」很多 | 它是把旧镜像 `docker export` / `docker import` 压成单层后的裁剪版：去掉了 apt 的 clang-14（350 MB，从未用上）和 LLVM 官方包里内核用不到的部分（静态库 615 MB、C++ 头文件、lldb/clangd/IR 工具等），`/opt/clang` 从 2.9 GB 降到 1.2 GB。`Dockerfile.native` 现在带同样的裁剪，重建得到等价镜像。已实测：用它和用旧镜像各编一次，`vmlinux` 只差 25 字节（构建时间戳），3131 个目标文件里只有 `init/version.o`、`usr/initramfs_data.o`、`vmlinux.o` 三个不同 |

## 目录结构

```
.github/workflows/build.yml   CI：拉源码 → 打补丁 → 合配置 → 校验 → 编译 → 打包
configs/                      内核配置片段（按顺序合并，后者覆盖前者）
  00-rom-align.config         与目标 ROM stock config 的对齐（默认空）
  10-droidspaces.config       Droidspaces 非 GKI 必选+推荐（4.19 符号名已校正）
  20-resukisu.config          CONFIG_KSU + manual hook，SUSFS 关闭
  30-boot-compat.config       开机关键项钉住（RD_LZ4/PSI/VENDOR_HOOKS/MODULES/KPROBES/panic 行为）
patches/                      全部补丁（来源与必要性见 patches/README.md）
scripts/                      构建脚本（CI 与本地共用同一套）
  build.sh                    完整构建流程（CI 与本地都走它）
  check-configs.sh            配置逐项断言（任一失败即构建失败）
  make-boot-img.sh            用 magiskboot 把产物重打包成可 fastboot boot 的 boot.img
  verify-artifacts.sh         产物侧断言（dtb / KSU / 版本串）
  verify-on-device.sh         真机侧验证（标记 / KSU 线索 / Droidspaces 运行时能力）
  local-docker-build.sh       本地容器构建入口（两种环境见下）
docker/
  Dockerfile                  amd64 + AOSP clang r416183b（与 CI 同构，走 Rosetta）
  Dockerfile.native           arm64 原生 + LLVM 12.0.1（非转译路线，快）
  .build-state                本地记录：<镜像名> <构建时那份 Dockerfile 的 mtime>（不进 git）
anykernel/anykernel.sh        适配 lavender 的 AnyKernel3 脚本模板
```

## 本地构建：两种容器环境

CI 之外想要本地快速迭代时，用「固定镜像 + 三个 volume」搭一次环境，之后长期复用：

```sh
# 路线 A：与 CI 完全同构（amd64 + AOSP clang r416183b），结论可直接外推
bash scripts/local-docker-build.sh

# 路线 B：非转译的原生 arm64（LLVM 12.0.1），用于快速迭代
IMAGE=lavender-builder-native:4.19 PLATFORM=linux/arm64 \
DOCKERFILE=$PWD/docker/Dockerfile.native TOOLCHAIN_DIR=/opt \
SRC_VOL=lavender-san-src OUT_VOL=lavender-san-out-native JOBS=10 \
bash scripts/local-docker-build.sh
```

镜像**按需构建**：`docker/.build-state` 里记着上次构建时那份 `Dockerfile` 的 mtime，
每次构建前比一次，不一致就重建，构建成功后把新 mtime 记回去；一致就直接复用镜像。
这样正常迭代不会白跑 `docker build`——构建缓存一旦被 `docker builder prune` 清过，
白跑一遍就要重新下载整个工具链层（amd64 1.4 GB / arm64 3.0 GB）。要强制重建用
`FORCE_IMAGE=1`。

两个 `Dockerfile` 的层都按「最不易变 → 最易变」排：`base → 最小 apt（下载解包工具链要用）
→ 工具链 → 完整 apt 依赖 → ENV`。工具链那层最大、也最少变，排在 apt 依赖之前，
所以以后改依赖列表只会重跑后面那层 apt，不会连累工具链重新下载。

两边的量级差别（同一棵树、同一台机器、全量冷构建）：

| 路线 | 工具链 | 全量构建 |
|---|---|---|
| A：amd64 + Rosetta | AOSP clang 12.0.5 | **17 分 42 秒**（8 job） |
| B：arm64 原生 | LLVM 12.0.1 | **4 分 18 秒**（10 job） |

同一棵树、同一台机器、都是冷 ccache 的全量构建，B 比 A 快约 **4.1 倍** —— 上面
「Rosetta 大约慢 30%」的旧估计是错的：对 clang 这种大体积、翻译缓存不友好的程序，
Rosetta 的代价远不止 30%。所以日常改代码迭代走 B，出正式包走 A/CI（与 CI 同构）。

注意：两种环境的产物目录必须分开（`OUT_VOL` 不同），否则 amd64 的 `.o` 会串进 arm64 的链接。

## 改配置时的一条硬约束（踩过的坑）

`scripts/kconfig/merge_config.sh` 的合并方式是：从片段里解析出**带前缀的符号名**，
对每个符号执行「删掉基座 defconfig 里的同名行」，再把片段整段追加。所以——

> **片段里任何位置出现带 `CONFIG_` 前缀的符号名（哪怕在注释里、哪怕是被 `#` 注释掉的赋值行），都会让基座里那一项被删掉**；如果片段里没有同名真配置行补回来，该项就会悄悄退回 Kconfig 默认值。

本仓库第一次云编译就被这个坑清掉了 `CONFIG_LOCALVERSION`，导致 `uname -r` 少了版本后缀
（日志里表现为 `Value of CONFIG_LOCALVERSION is redefined ...`）。现在的防线有两道，
改配置时请遵守：

1. **注释里只写符号名本身**（写 `LOCALVERSION`、`MEMCG`），需要示范完整写法时用占位符 `CONFIG_<符号>`；合法的真配置行只有 `CONFIG_<符号>=y` 和 `# CONFIG_<符号> is not set` 两种。`scripts/merge-configs.sh` 里的 `lint_fragments` 会硬校验，违规直接构建失败。
2. `scripts/check-configs.sh` 会从基座 defconfig 读出应有的 `LOCALVERSION` 并与合并结果逐字比对，值被改动就立刻报错。

## 许可与致谢

本仓库是构建配方（配置片段 + 补丁 + 脚本），以 GPL-2.0 发布，
与上游内核保持一致；补丁中引用的第三方内容保持其原始署名与许可：

- 内核源码：[`pix106/android_kernel_xiaomi_sdm660_southwest-ng`](https://github.com/pix106/android_kernel_xiaomi_sdm660_southwest-ng)（GPL-2.0）
- Droidspaces 与其官方 non-GKI 补丁：[`ravindu644/Droidspaces-OSS`](https://github.com/ravindu644/Droidspaces-OSS)（GPL-3.0）
- 4.19 符号名校正与三个构建修正，参考 [`Oh-Zhou/platina-droidspace-ksu`](https://github.com/Oh-Zhou/platina-droidspace-ksu)（同 SoC 的 SDM660 真机验证配方）
- root 方案：[`ReSukiSU/ReSukiSU`](https://github.com/ReSukiSU/ReSukiSU)
- 刷机包框架：[`osm0sis/AnyKernel3`](https://github.com/osm0sis/AnyKernel3)
