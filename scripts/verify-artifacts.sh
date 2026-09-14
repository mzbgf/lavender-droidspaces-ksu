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
  die "镜像里找不到 lavender 的 dtb（${LAV_MODEL}）——设备不会启动"
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

# KSU 必须真的编进了内核。这里刻意**不用 nm 查符号**：本树开着 LTO + CFI，
# 局部符号会被内联/内部化而消失（CI 第一次就是这样误报的）。改为查两条硬证据：
#   1) 构建日志里 reSukiSU 明确走了 manual hook，且算出了版本号；
#   2) vmlinux 里能搜到 KSU 的版本串（KSU_VERSION_FULL 里带 @ReSukiSU）。
require_file "$OUT_DIR/build.log"
grep -qF -- "-- ReSukiSU: using Manual Hook" "$OUT_DIR/build.log" \
  || die "构建日志里没有 'using Manual Hook'：hook 方式不对（4.19 非 GKI 必须 manual hook）"
grep -qE -- "-- ReSukiSU version code: [0-9]+" "$OUT_DIR/build.log" \
  || die "构建日志里没有 reSukiSU 版本号：驱动可能没接进构建"
ksu_objs="$(grep -cE 'CC +drivers/kernelsu/' "$OUT_DIR/build.log" || true)"
[ "${ksu_objs:-0}" -gt 0 ] || die "构建日志里没有编译任何 drivers/kernelsu/*.o"
log "reSukiSU 已编入内核：${ksu_objs} 个目标文件，hook 方式 = manual"

if [ -f "$OUT_DIR/vmlinux" ]; then
  if grep -qa "@ReSukiSU" "$OUT_DIR/vmlinux" || { [ -f "$BOOT/Image" ] && grep -qa "@ReSukiSU" "$BOOT/Image"; }; then
    log "内核镜像含 reSukiSU 版本串 ✔"
  else
    die "vmlinux / Image 里搜不到 reSukiSU 版本串"
  fi
fi

# 版本串（模块 vermagic 的依据，也是 uname -r 会显示的值）
if rel="$(kernel_release)"; then
  log "kernelrelease = $rel"
  expect_lv="$(grep -E '^CONFIG_LOCALVERSION=' "$OUT_DIR/.config" 2>/dev/null | tail -1 | cut -d'"' -f2 || true)"
  case "$rel" in
    *"$expect_lv"*) log "版本串里含 LOCALVERSION=«$expect_lv» ✔" ;;
    *) die "kernelrelease 里不含 LOCALVERSION（$expect_lv）——版本串不对" ;;
  esac
fi
