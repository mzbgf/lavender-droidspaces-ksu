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

BASE=(
  arch/arm64/configs/vendor/xiaomi/sdm660_defconfig
  arch/arm64/configs/vendor/xiaomi/lavender.config
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

log "olddefconfig 解析依赖"
make O="$OUT_DIR" ARCH="$ARCH" olddefconfig

log "kernelrelease = $(make O="$OUT_DIR" ARCH="$ARCH" -s kernelrelease)"
