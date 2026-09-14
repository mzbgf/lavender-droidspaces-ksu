#!/usr/bin/env bash
# 公用变量与函数 —— 其余脚本 source 本文件
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 上游内核源码固定点（main == refs/heads/0.19.4 == b2ee0c8）
KERNEL_REPO="${KERNEL_REPO:-https://github.com/pix106/android_kernel_xiaomi_sdm660_southwest-ng}"
KERNEL_PIN="${KERNEL_PIN:-b2ee0c8f4cd75fbb2097b9bcd8dc3306166f241c}"
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
