#!/usr/bin/env bash
# 公用变量与函数 —— 其余脚本 source 本文件
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 上游内核源码固定点（San-Kernel / user-why-red，back 分支的 commit）。
#
# 为什么是这棵树、而不是 pix106 的 SouthWest-NG：两者在 mmc 驱动、sdhci、DT 的
# sdhci 节点上几乎逐字相同，但 pix106 0.19.4 在本机（Redmi Note 7 + AOSP 16）
# 实测必定在开机约 8 秒时于 mmc devfreq 路径 Oops（野指针 + Fatal exception in
# interrupt）；而本树用完全相同的工具链与打包流程，真机 fastboot boot 一次成功。
KERNEL_REPO="${KERNEL_REPO:-https://github.com/user-why-red/android_kernel_xiaomi_sdm660_419}"
KERNEL_PIN="${KERNEL_PIN:-6d41c71e301a3c3394167dc5ef03cbc846ae6772}"

# 基座 defconfig，必须与上面那棵树对应（两处必须一起改，否则会合错配置）：
#   pix106/SouthWest-NG -> vendor/xiaomi/sdm660_defconfig + vendor/xiaomi/lavender.config
#   San-Kernel          -> vendor/lavender-perf_defconfig（设备专属，一份就够）
KERNEL_BASE_DEFCONFIG="${KERNEL_BASE_DEFCONFIG:-arch/arm64/configs/vendor/lavender-perf_defconfig}"

KERNEL_DIR="${KERNEL_DIR:-$REPO_ROOT/kernel}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"

# root 方案固定点
RESUKISU_REPO="${RESUKISU_REPO:-https://github.com/ReSukiSU/ReSukiSU}"
RESUKISU_TAG="${RESUKISU_TAG:-v4.2.0-rc2}"

# 打包
ANY_KERNEL_REPO="${ANY_KERNEL_REPO:-https://github.com/osm0sis/AnyKernel3}"
ANY_KERNEL_DIR="${ANY_KERNEL_DIR:-$REPO_ROOT/AnyKernel3}"

# 可选：覆盖 CONFIG_LOCALVERSION（用于与目标 ROM 的 uname -r 对齐）
LOCALVERSION_OVERRIDE="${LOCALVERSION_OVERRIDE:-}"

ARCH="${ARCH:-arm64}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_dir()  { [ -d "$1" ] || die "目录不存在: $1"; }
require_file() { [ -f "$1" ] || die "文件不存在: $1"; }

# 缺命令时要报「缺命令」，不能让它伪装成别的失败（曾经把缺 patch 报成「补丁不匹配」）
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令: ${c}（请先安装，容器镜像见 docker/Dockerfile）"
  done
}

# 把仓库里的 config 片段拷进内核树（merge_config.sh 需要树内路径）
install_fragments() {
  local dest="$KERNEL_DIR/arch/arm64/configs/vendor/local"
  mkdir -p "$dest"
  cp "$REPO_ROOT"/configs/*.config "$dest"/
  echo "$dest"
}

# 内核版本串（uname -r）。O=out 构建时权威文件在 $OUT_DIR/include/config/ 下，
# 读源码树里的同名文件会拿到空值（曾导致刷机包名与 kernel.string 退化成 "4.19.325"）。
kernel_release() {
  local f
  for f in "$OUT_DIR/include/config/kernel.release" "$KERNEL_DIR/include/config/kernel.release"; do
    if [ -s "$f" ]; then cat "$f"; return 0; fi
  done
  return 1
}
