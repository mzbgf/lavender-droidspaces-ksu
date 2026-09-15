#!/usr/bin/env bash
# 完整构建流程（供 CI 与本地/容器共用）
#
# 前置：内核源码已 checkout 到 $KERNEL_DIR（commit = $KERNEL_PIN）；
#       工具链可用（scripts/setup-toolchain.sh 或环境里已有 clang）。
# 产物：$OUT_DIR/arch/arm64/boot/Image.gz-dtb + 根目录下的 AnyKernel3 zip
source "$(dirname "$0")/lib.sh"

TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$REPO_ROOT/toolchains}"

use_toolchain() {
  [ -n "${CLANG_DIR:-}" ] && PATH="$CLANG_DIR/bin:$PATH"
  [ -x "$TOOLCHAIN_DIR/clang/bin/clang" ] && PATH="$TOOLCHAIN_DIR/clang/bin:$PATH"
  export PATH
  command -v clang >/dev/null 2>&1 || die "找不到 clang：请先执行 scripts/setup-toolchain.sh 或设置 CLANG_DIR"
}

require_dir "$KERNEL_DIR"
use_toolchain
log "工具链: $(command -v clang) -> $(clang --version | head -1)"

MAKE_ARGS=(
  -C "$KERNEL_DIR"
  O="$OUT_DIR"
  ARCH="$ARCH"
  LLVM=1
  LLVM_IAS=1
  CLANG_TRIPLE=aarch64-linux-gnu-
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_ARM32=arm-linux-gnueabi-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  KBUILD_BUILD_USER=droidspaces
  KBUILD_BUILD_HOST=lavender
)
# 需要 ccache 时传 CC_CMD="ccache clang"
[ -n "${CC_CMD:-}" ] && MAKE_ARGS+=(CC="$CC_CMD")

bash "$REPO_ROOT/scripts/lint-scripts.sh"
bash "$REPO_ROOT/scripts/setup-resukisu.sh"
bash "$REPO_ROOT/scripts/apply-patches.sh"
bash "$REPO_ROOT/scripts/merge-configs.sh"
bash "$REPO_ROOT/scripts/check-configs.sh"

log "开始编译（-j${JOBS}）"
{
  # 先单独构建 dtbs：Image.gz-dtb 的依赖 DTB_OBJS 是在 Makefile 解析期用 find
  # 计算的，第一次调用时 out/ 里还没有 .dtb，会拼出不含 dtb 的镜像
  make "${MAKE_ARGS[@]}" -j"$JOBS" KCFLAGS="${KCFLAGS:-}" dtbs
  make "${MAKE_ARGS[@]}" -j"$JOBS" KCFLAGS="${KCFLAGS:-}" Image.gz-dtb
} 2>&1 | tee "$OUT_DIR/build.log"

bash "$REPO_ROOT/scripts/verify-artifacts.sh"
bash "$REPO_ROOT/scripts/package-anykernel3.sh"

log "全部完成"
