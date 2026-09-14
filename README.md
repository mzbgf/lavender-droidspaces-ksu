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
  Infinity-X、crDroid、Axion…）内核版本串统一是 `4.19.325-SouthWest-NG-*`。
- 要在 4.4 上跑 A16，需要把 4.14~5.4 的 eBPF 特性整套 backport 回来
  （唯一公开成功案例是三星 Exynos 8895 的 S8，做这事的开发者花了数月），
  lavender 圈没人做过，也没有对应 ROM。

所以本方案建立在 **Linux 4.19.325** 上。

## 用哪个源码

| 项 | 值 |
|---|---|
| 仓库 | `pix106/android_kernel_xiaomi_sdm660_southwest-ng` |
| 分支 | `main`（与 `refs/heads/0.19.4` 同一提交） |
| 固定 commit | `b2ee0c8f4cd75fbb2097b9bcd8dc3306166f241c` |
| 内核版本 | 4.19.325，`CONFIG_LOCALVERSION="-SouthWest-NG-0.19.4"` |
| 为什么是它 | 它就是 lavender 的 A16 ROM 实际使用的内核线；ROM 设备树声明的 `vendor/xiaomi/sdm660_defconfig` + `vendor/xiaomi/lavender.config` + `Image.gz-dtb` 与本仓库布局逐项吻合；全树没有任何 KernelSU/SUSFS 代码，基座干净 |

**版本串（`uname -r`）**：树根本身带 `localversion-cip`（`-cip135`）与
`localversion-st`（`-st19`）两个文件，kbuild 会把它们接在 `CONFIG_LOCALVERSION`
之前，所以本配方构建出的版本串是：

```
4.19.325-cip135-st19-SouthWest-NG-0.19.4
```

本树 defconfig 是 `# CONFIG_MODULES is not set`（驱动全部内建），所以正常情况下
ROM 侧没有需要匹配 vermagic 的 `.ko`，版本串只影响 `uname -r` 的显示。但如果你
的 ROM 确实带着内核对侧模块（或你换了别的基础树），就必须让它与 ROM 完全一致：
构建时 CI 会打印 `kernelrelease`，请与手机的 `uname -r`（设置 → 关于手机 →
内核版本）逐字比对，不一致时按 `configs/00-rom-align.config` 里的两种办法处理。

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
| 刷完能开机但 wlan/蓝牙坏 | 版本串不一致导致模块 vermagic 不匹配：比对 `uname -r`，必要时换 `KERNEL_PIN` 到对应 `0.x.x` 分支 |
| 开机极慢 / lmkd 报错 | 确认 `CONFIG_PSI=y`（脚本已断言） |
| `droidspaces check` 有红叉 | 看 CI 里 `check-configs.sh` 的输出；容器网络不通多半是 NAT 相关项缺失 |
| 进不去 root / KSU safe mode | 本树 `CONFIG_KPROBES` 已关闭；若仍进 safe mode，检查 hook 是否被上游改动影响 |

## 目录结构

```
.github/workflows/build.yml   CI：拉源码 → 打补丁 → 合配置 → 校验 → 编译 → 打包
configs/                      内核配置片段（按顺序合并，后者覆盖前者）
  00-rom-align.config         与目标 ROM stock config 的对齐（默认空）
  10-droidspaces.config       Droidspaces 非 GKI 必选+推荐（4.19 符号名已校正）
  20-resukisu.config          CONFIG_KSU + manual hook，SUSFS 关闭
  30-boot-compat.config       开机关键项钉住（RD_LZ4/PSI/VENDOR_HOOKS/MODULES/KPROBES）
patches/                      全部补丁（来源与必要性见 patches/README.md）
scripts/                      构建脚本（CI 与本地共用同一套）
anykernel/anykernel.sh        适配 lavender 的 AnyKernel3 脚本模板
```

## 改配置时的一条硬约束（踩过的坑）

`scripts/kconfig/merge_config.sh` 的合并方式是：从片段里解析出**带前缀的符号名**，
对每个符号执行「删掉基座 defconfig 里的同名行」，再把片段整段追加。所以——

> **片段里任何位置出现带 `CONFIG_` 前缀的符号名（哪怕在注释里、哪怕是被 `#` 注释掉的赋值行），都会让基座里那一项被删掉**；如果片段里没有同名真配置行补回来，该项就会悄悄退回 Kconfig 默认值。

本仓库第一次云编译就被这个坑清掉了 `CONFIG_LOCALVERSION`，导致 `uname -r` 少了
`-SouthWest-NG-0.19.4`（日志里表现为 `Value of CONFIG_LOCALVERSION is redefined ...`）。
现在的防线有两道，改配置时请遵守：

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
