#!/usr/bin/env bash
# 合并 config：基础 defconfig + 机型片段 + 本仓库片段，并做 olddefconfig 解析
#
# 合并顺序（后面覆盖前面）：
#   vendor/xiaomi/sdm660_defconfig        <- ROM 实际使用的基础 defconfig（含 LOCALVERSION）
#   vendor/xiaomi/lavender.config         <- 机型片段（MACH_XIAOMI_LAVENDER / 触摸屏 / 音频）
#   00-rom-align.config                   <- 与目标 ROM stock config 的差异对齐（默认留空）
#   10-droidspaces.config                 <- Droidspaces 非 GKI 必选+推荐
#   20-resukisu.config                    <- KernelSU（manual hook，SUSFS 关闭）
#   30-boot-compat.config                 <- 开机关键项钉住（防止上游漂移）
#   99-localversion.config                <- 可选，仅当设置了 LOCALVERSION_OVERRIDE
source "$(dirname "$0")/lib.sh"

require_dir "$KERNEL_DIR"
cd "$KERNEL_DIR"

DEST="$(install_fragments)"
log "片段已拷入: $DEST"

# ------------------------------------------------------------
# 片段硬校验：merge_config.sh 会把片段里「带完整前缀的符号名」当成配置项，
# 据此删掉基座 defconfig 里的同名行——注释里出现同样会触发，结果是该项悄悄
# 退回 Kconfig 默认值（本仓库的 LOCALVERSION 就这样被清空过一次，导致
# kernelrelease 丢掉了 -SouthWest-NG-0.19.4）。
# 因此规定：片段里只允许两种带前缀的真配置行，其余情况一律报错。
# ------------------------------------------------------------
lint_fragments() {
  local f line ln bad=0
  for f in "$DEST"/*.config; do
    ln=0
    while IFS= read -r line || [ -n "$line" ]; do
      ln=$((ln + 1))
      case "$line" in
        "") continue ;;
        CONFIG_*=*) continue ;;
        "# CONFIG_"*" is not set") continue ;;
      esac
      if printf '%s\n' "$line" | grep -qE 'CONFIG_[A-Za-z0-9_]+'; then
        warn "${f##*/}:${ln} 非配置行里出现带前缀的符号名（会删掉基座同名项）：$line"
        bad=$((bad + 1))
      fi
    done <"$f"
  done
  [ "$bad" -eq 0 ] || die "config 片段里有 $bad 处违规：注释只写符号名本身，或用 CONFIG_<符号> 占位形式"
  log "config 片段校验通过 ✔"
}
lint_fragments

# 基座 defconfig 由 lib.sh 的 KERNEL_BASE_DEFCONFIG 给出（与 KERNEL_REPO/PIN 那棵树
# 一一对应；换树时必须一起改，否则会把配置合到另一棵树的 defconfig 上）
BASE=(
  "$KERNEL_BASE_DEFCONFIG"
)
FRAGS=(
  arch/arm64/configs/vendor/local/00-rom-align.config
  arch/arm64/configs/vendor/local/10-droidspaces.config
  arch/arm64/configs/vendor/local/20-resukisu.config
  arch/arm64/configs/vendor/local/30-boot-compat.config
)

if [ -n "$LOCALVERSION_OVERRIDE" ]; then
  warn "覆盖 CONFIG_LOCALVERSION 为 \"$LOCALVERSION_OVERRIDE\"（务必与目标 ROM 的 uname -r 一致）"
  printf 'CONFIG_LOCALVERSION="%s"\n' "$LOCALVERSION_OVERRIDE" \
    > arch/arm64/configs/vendor/local/99-localversion.config
  FRAGS+=(arch/arm64/configs/vendor/local/99-localversion.config)
fi

mkdir -p "$OUT_DIR"
export ARCH

log "merge_config.sh -m -O $OUT_DIR"
scripts/kconfig/merge_config.sh -m -O "$OUT_DIR" "${BASE[@]}" "${FRAGS[@]}"

# 解析配置时必须带上与编译阶段一致的工具链参数。
#
# Kconfig 里有一批符号的默认值来自「编译器能力探测」（cc-option），探测用的是
# make 变量 CC——不传的话 kbuild 退到 $(CROSS_COMPILE)gcc，也就是宿主机的 gcc。
# 于是同一份片段在不同宿主机上会合出不同结果：CI runner（Ubuntu 22.04）的
# GCC 11 不认识 -ftrivial-auto-var-init，本机容器的 GCC 12 认识，三选一
# INIT_STACK 就分叉成了 CI=NONE / 本地=ZERO（NONE 那份真机开机约 54 秒必崩）。
# 这里把 CC/LLVM/交叉前缀一次性传齐，让两边评出的默认值一致。
CONF_MAKE=(
  O="$OUT_DIR" ARCH="$ARCH"
  LLVM=1 LLVM_IAS=1
  CLANG_TRIPLE=aarch64-linux-gnu-
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_ARM32=arm-linux-gnueabi-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
)
# CC_CMD 形如 "ccache clang"；没有它时交给 LLVM=1 让 kbuild 自己选 clang
[ -n "${CC_CMD:-}" ] && CONF_MAKE+=(CC="$CC_CMD")
[ -n "${CC:-}" ] && [ -z "${CC_CMD:-}" ] && CONF_MAKE+=(CC="$CC")

log "olddefconfig 解析依赖"
make "${CONF_MAKE[@]}" olddefconfig

log "kernelrelease = $(make O="$OUT_DIR" ARCH="$ARCH" -s kernelrelease)"
