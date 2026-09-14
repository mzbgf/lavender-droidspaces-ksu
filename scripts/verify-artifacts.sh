#!/usr/bin/env bash
# 校验编译产物：内核镜像、dtb、KSU 符号、config 断言
source "$(dirname "$0")/lib.sh"

BOOT="$OUT_DIR/arch/arm64/boot"
IMG="$BOOT/Image.gz-dtb"
require_file "$IMG"

size=$(wc -c <"$IMG" | tr -d ' ')
log "Image.gz-dtb: $IMG ($((size / 1024)) KiB)"
if [ "$size" -lt $((6 * 1024 * 1024)) ] || [ "$size" -gt $((48 * 1024 * 1024)) ]; then
  die "镜像体积异常（期望 6-48 MiB）：$size 字节"
fi

# dtb 必须真的是 lavender 的（dts 里的 model / compatible 字符串在未压缩的 dtb 段里可直接 grep）
LAV_MODEL="Qualcomm Technologies, Inc. SDM 660 PM660 + PM660L MTP F7A"
if ! grep -qa "$LAV_MODEL" "$IMG"; then
  die "镜像里找不到 lavender 的 dtb（$LAV_MODEL）——设备不会启动"
fi
log "含 lavender dtb ✔  ($LAV_MODEL)"

models="$(grep -ao "Qualcomm Technologies, Inc\. [A-Za-z0-9 +]*MTP[A-Za-z0-9 ]*" "$IMG" | sort -u || true)"
n_models="$(printf '%s\n' "$models" | grep -c . || true)"
if [ "$n_models" -gt 1 ]; then
  warn "镜像里含多个机型的 dtb，请注意是否误打包："
  printf '%s\n' "$models" | sed 's/^/        /'
fi

# config 断言（与 check-configs.sh 呼应，但针对产物对应的 out/.config）
require_file "$OUT_DIR/.config"
grep -q '^CONFIG_KSU=y' "$OUT_DIR/.config" || die "CONFIG_KSU 未启用"
grep -q '^CONFIG_KSU_MANUAL_HOOK=y' "$OUT_DIR/.config" || die "CONFIG_KSU_MANUAL_HOOK 未启用（4.19 非 GKI 必须）"
grep -q '^CONFIG_KSU_SUSFS=y' "$OUT_DIR/.config" && die "CONFIG_KSU_SUSFS 被启用了（要求不使用 SUSFS）"
log "config 断言通过 ✔"

# 构建日志里不应出现 susfs 的编译
if [ -f "$OUT_DIR/build.log" ] && grep -q "susfs" "$OUT_DIR/build.log"; then
  die "构建日志里出现了 susfs（要求完全不编译 SUSFS）"
fi

# KSU 符号（vmlinux 存在时）
NM=""
command -v llvm-nm >/dev/null 2>&1 && NM=llvm-nm
[ -z "$NM" ] && command -v nm >/dev/null 2>&1 && NM=nm
if [ -n "$NM" ] && [ -f "$OUT_DIR/vmlinux" ]; then
  if "$NM" "$OUT_DIR/vmlinux" 2>/dev/null | grep -qi " ksu_"; then
    log "vmlinux 里存在 KSU 符号 ✔"
  else
    die "vmlinux 里找不到 KSU 符号（root 不会生效）"
  fi
fi

# 版本串（模块 vermagic 的依据）
if [ -f "$KERNEL_DIR/include/config/kernel.release" ]; then
  log "kernelrelease = $(cat "$KERNEL_DIR/include/config/kernel.release")"
fi
