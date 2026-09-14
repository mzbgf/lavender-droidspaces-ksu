#!/usr/bin/env bash
# 接入 reSukiSU 内核驱动（非 GKI / manual hook 路径）
#
# 为什么不调用上游 kernel/setup.sh：那个脚本会执行 `git stash` + `git pull` +
# `git checkout main`，在 CI 的浅克隆/detached tag 上必然失败（浅克隆没有 main 分支）。
# 这里按它的等价行为自己接线，每一步都幂等，失败即退出。
#
# 克隆策略：**不能浅克隆**。ReSukiSU 的 kernel/Kbuild 用
#   KSU_VERSION = 30000 + $(git rev-list --count HEAD) + 700
# 计算内核侧版本号，浅克隆会让它变成 30701 之类的小值，管理器会判定「内核版本过低」
# 而拒绝连接。所以这里做 --single-branch（不带 --depth）克隆，保留到该 tag 的完整历史。
source "$(dirname "$0")/lib.sh"

require_dir "$KERNEL_DIR"
cd "$KERNEL_DIR"

log "reSukiSU: $RESUKISU_REPO @ $RESUKISU_TAG"

if [ ! -d KernelSU/.git ]; then
  rm -rf KernelSU
  git clone --single-branch --branch "$RESUKISU_TAG" "$RESUKISU_REPO" KernelSU
else
  git -C KernelSU fetch --tags origin
  git -C KernelSU checkout -f "$RESUKISU_TAG"
fi

require_file KernelSU/kernel/Kconfig
require_file KernelSU/kernel/Kbuild

ksu_commits="$(git -C KernelSU rev-list --count HEAD)"
log "reSukiSU 提交数 = ${ksu_commits}（内核侧 KSU_VERSION 将约为 $((30000 + ksu_commits + 700))）"
if [ "$ksu_commits" -lt 100 ]; then
  die "KernelSU 历史不完整（commit 数 $ksu_commits 太少），版本号会算错；请用完整克隆"
fi

# ---- 1) drivers/kernelsu -> ../KernelSU/kernel（与上游 setup.sh 相同的相对软链）----
ln -sfn ../KernelSU/kernel drivers/kernelsu
[ -L drivers/kernelsu ] && [ -d drivers/kernelsu/ ] || die "drivers/kernelsu 软链无效"

# ---- 2) drivers/Makefile 接线 ----
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile \
  || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >>drivers/Makefile
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile || die "drivers/Makefile 接线失败"

# ---- 3) drivers/Kconfig 接线（插在 drivers 菜单的 endmenu 之前，本树只有一个 endmenu）----
if ! grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
  awk '
    /^endmenu$/ && !done { print "source \"drivers/kernelsu/Kconfig\""; done = 1 }
    { print }
  ' drivers/Kconfig >drivers/Kconfig.tmp && mv drivers/Kconfig.tmp drivers/Kconfig
fi
grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig || die "drivers/Kconfig 接线失败"

# ---- 4) Kconfig 能力校验：4.19 非 GKI 必须支持 manual hook，否则熔断 ----
grep -q 'config KSU_MANUAL_HOOK' drivers/kernelsu/Kconfig \
  || die "该 reSukiSU 版本没有 KSU_MANUAL_HOOK；请改用 KernelSU-Next legacy 方案"
grep -q 'config KSU_MANUAL_HOOK_AUTO_SETUID_HOOK' drivers/kernelsu/Kconfig \
  || warn "Kconfig 里没有 AUTO_SETUID_HOOK：可能需要手改 kernel/sys.c"

log "reSukiSU 接线完成：drivers/kernelsu -> KernelSU/kernel"
