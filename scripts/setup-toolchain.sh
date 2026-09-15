#!/usr/bin/env bash
# 下载并解包 AOSP 预编译 clang 到 toolchains/clang（CI 与本地通用）
#
# 默认 clang-r416183b（clang 12.0.5，android12-release 分支）：
# 这是 sdm660 4.19 CAF 内核同代、已被同类设备构建验证过的版本。
# 需要换版本时设置 CLANG_URL 覆盖。
source "$(dirname "$0")/lib.sh"

TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$REPO_ROOT/toolchains}"
CLANG_URL="${CLANG_URL:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android12-release/clang-r416183b.tar.gz}"

if [ -x "$TOOLCHAIN_DIR/clang/bin/clang" ]; then
  # 必须确认它真的能跑：AOSP 预编译 clang 只有 x86_64 版，仓库里那份一旦被
  # arm64 原生构建拿到，会以 exec format error 收场，而报错完全看不出原因。
  if ! ver="$("$TOOLCHAIN_DIR/clang/bin/clang" --version 2>/dev/null | head -1)"; then
    die "已有的 clang 跑不起来（宿主架构不匹配？）: ${TOOLCHAIN_DIR}/clang/bin/clang
    原生 arm64 构建请改用镜像自带的工具链：TOOLCHAIN_DIR=/opt（见 docker/Dockerfile.native）"
  fi
  log "已存在: $TOOLCHAIN_DIR/clang/bin/clang"
  printf '%s\n' "$ver"
  exit 0
fi

mkdir -p "$TOOLCHAIN_DIR/clang"
log "下载 clang: $CLANG_URL"
curl -fL --retry 5 --retry-delay 5 -o "$TOOLCHAIN_DIR/clang.tar.gz" "$CLANG_URL"
tar xzf "$TOOLCHAIN_DIR/clang.tar.gz" -C "$TOOLCHAIN_DIR/clang"
rm -f "$TOOLCHAIN_DIR/clang.tar.gz"

# gitiles 的 archive 可能带也可能不带子目录前缀，两种都兼容
if [ ! -x "$TOOLCHAIN_DIR/clang/bin/clang" ]; then
  inner="$(find "$TOOLCHAIN_DIR/clang" -maxdepth 3 -type f -path '*/bin/clang' | head -1 || true)"
  [ -n "$inner" ] || die "解包后找不到 bin/clang"
  mv "$TOOLCHAIN_DIR/clang" "$TOOLCHAIN_DIR/clang.tmp"
  mv "$(dirname "$(dirname "$inner")")" "$TOOLCHAIN_DIR/clang"
  rm -rf "$TOOLCHAIN_DIR/clang.tmp"
fi

"$TOOLCHAIN_DIR/clang/bin/clang" --version | head -1
log "clang 就绪: $TOOLCHAIN_DIR/clang/bin"
