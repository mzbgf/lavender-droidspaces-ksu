#!/usr/bin/env bash
# 用 OrbStack 里的 x86_64 编译环境在本机构建内核（与 CI 同构），用于快速迭代。
#
# 设计（沿用固定镜像 + 三个 volume，一次搭好后永不再动）：
#   镜像 lavender-builder:4.19     debian bookworm amd64 + AOSP clang r416183b
#   volume lavender-src   /src     内核源码（--depth=1，约 1.5GB）
#   volume lavender-out   /out     make O=/out 的产物（源码目录始终干净）
#   volume lavender-ccache /ccache ccache（10G 上限，复用核心）
#
# 用法：
#   bash scripts/local-docker-build.sh              # 补丁→合配置→校验→编译→打包
#   bash scripts/local-docker-build.sh shell        # 进容器手动折腾
#   FRESH=1 bash scripts/local-docker-build.sh      # 删掉源码树重新克隆
#   SKIP_KSU=1 bash scripts/local-docker-build.sh    # 变量会透传进容器
#
# 注意：源码与产物放在 volume 里，不走 macOS bind mount（内核构建有几万次
# stat/read，跨文件系统会慢好几倍）。配方仓库本身是 bind mount（要小文件读写）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${IMAGE:-lavender-builder:4.19}"
SRC_VOL="${SRC_VOL:-lavender-src}"
OUT_VOL="${OUT_VOL:-lavender-out}"
CCACHE_VOL="${CCACHE_VOL:-lavender-ccache}"
# 编译环境有两种（镜像不同、架构不同、产物目录也必须分开，否则 .o 会串架构）：
#   默认        amd64 + AOSP clang r416183b，与 CI 同构（走 Rosetta）
#   非转译路线  arm64 原生 + LLVM 12.0.1        见 docker/Dockerfile.native
PLATFORM="${PLATFORM:-linux/amd64}"
DOCKERFILE="${DOCKERFILE:-$REPO_ROOT/docker/Dockerfile}"
MODE="${1:-build}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# 总是过一遍 docker build：全缓存命中时约 1 秒，而改了 Dockerfile 也能立刻生效
# （之前是「镜像存在就跳过」，导致改完 Dockerfile 什么都不会发生）。
log "构建/复用镜像: ${IMAGE}（平台 ${PLATFORM}，源 ${DOCKERFILE}）"
docker build --platform "$PLATFORM" -t "$IMAGE" -f "$DOCKERFILE" "$(dirname "$DOCKERFILE")"

# 只准备镜像（非转译路线先单独把环境搭好，之后再跑内核编译）
if [ "$MODE" = "image" ]; then
  log "镜像就绪: ${IMAGE}（平台 ${PLATFORM}）"
  exit 0
fi

# 变量透传（lib.sh 里的 KERNEL_REPO/KERNEL_PIN/OUT_DIR 等都用 :- 默认值，环境变量优先）
PASSTHRU=()
for v in KERNEL_REPO KERNEL_PIN KERNEL_DIR OUT_DIR LOCALVERSION_OVERRIDE SKIP_KSU TOOLCHAIN_DIR JOBS CC_CMD; do
  [ -n "${!v:-}" ] && PASSTHRU+=(-e "$v=${!v}")
done

TTY=(); [ -t 0 ] && [ -t 1 ] && TTY=(-t)

RUN=(
  docker run --rm -i "${TTY[@]}"
  --platform "$PLATFORM"
  -v "$SRC_VOL":/src -v "$OUT_VOL":/out -v "$CCACHE_VOL":/ccache
  -v "$REPO_ROOT":/recipe -w /recipe
  -e KERNEL_DIR="${KERNEL_DIR:-/src/kernel}" -e OUT_DIR="${OUT_DIR:-/out}"
  -e CC_CMD="${CC_CMD:-ccache clang}"
  "${PASSTHRU[@]}"
  "$IMAGE"
)

case "$MODE" in
  shell)
    log "进入容器（源码在 /src，产物在 /out，配方在 /recipe）"
    exec "${RUN[@]}" bash
    ;;
  *)
    log "开始本地构建（源码 /src/kernel，产物 /out，ccache /ccache）"
    exec "${RUN[@]}" bash -lc "
      if [ -n \"\${FRESH:-}\" ]; then rm -rf \"\${KERNEL_DIR:-/src/kernel}\"; fi
      bash /recipe/scripts/build-local.sh
    "
    ;;
esac
