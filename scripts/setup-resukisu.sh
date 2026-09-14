#!/usr/bin/env bash
# 接入 reSukiSU 内核驱动（非 GKI / manual hook 路径）
#
# 做法：把上游仓库 clone 到 <kernel>/KernelSU，再执行其 kernel/setup.sh，
# 由它建立 drivers/kernelsu 软链并写入 drivers/{Makefile,Kconfig} 的接线。
# 完成后逐项校验接线，任何一项不对就失败退出（不做静默降级）。
source "$(dirname "$0")/lib.sh"

require_dir "$KERNEL_DIR"
cd "$KERNEL_DIR"

log "reSukiSU: $RESUKISU_REPO @ $RESUKISU_TAG"

if [ ! -d KernelSU/.git ]; then
  rm -rf KernelSU
  git clone --depth 1 --branch "$RESUKISU_TAG" "$RESUKISU_REPO" KernelSU
else
  git -C KernelSU fetch --depth 1 origin "refs/tags/$RESUKISU_TAG:refs/tags/$RESUKISU_TAG"
  git -C KernelSU checkout -f "$RESUKISU_TAG"
fi

require_file KernelSU/kernel/setup.sh
# setup.sh 会在 drivers/ 下建 kernelsu 软链；重复执行时先清理旧接线以保证幂等
if [ -e drivers/kernelsu ] || [ -L drivers/kernelsu ]; then
  rm -f drivers/kernelsu
  sed -i '\#obj-$(CONFIG_KSU) += kernelsu/#d' drivers/Makefile
  sed -i '\#source "drivers/kernelsu/Kconfig"#d' drivers/Kconfig
fi

log "执行 reSukiSU kernel/setup.sh"
sh KernelSU/kernel/setup.sh

# ---- 接线校验（任一失败即退出）----
[ -L drivers/kernelsu ] || die "drivers/kernelsu 软链未创建"
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile || die "drivers/Makefile 未接线"
grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig || die "drivers/Kconfig 未接线"
require_file drivers/kernelsu/Kconfig

# ---- Kconfig 能力校验：4.19 非 GKI 必须支持 manual hook，否则熔断 ----
if ! grep -q 'config KSU_MANUAL_HOOK' drivers/kernelsu/Kconfig; then
  die "该 reSukiSU 版本没有 KSU_MANUAL_HOOK（上游出现过文档/代码漂移）；请改为 KernelSU-Next legacy 方案"
fi
grep -q 'config KSU_MANUAL_HOOK_AUTO_SETUID_HOOK' drivers/kernelsu/Kconfig \
  || warn "Kconfig 里没有 AUTO_SETUID_HOOK，可能需要手改 kernel/sys.c"

log "reSukiSU 接线校验通过（$(git -C KernelSU describe --tags --always 2>/dev/null || echo "$RESUKISU_TAG")）"
