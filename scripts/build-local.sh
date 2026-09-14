#!/usr/bin/env bash
# 本地/容器内离线构建入口：
#   1) 按固定 commit 拉取上游内核源码到 $KERNEL_DIR
#   2) 准备工具链
#   3) 跑完整构建
#
# 用法（在 Linux 环境或 OrbStack x86_64/arm64 容器内）：
#   bash scripts/build-local.sh
# 注意：源码必须落在 Linux 可见的文件系统里；不要在 macOS 大小写不敏感卷上
#       直接 bind-mount 内核源码（git/内核树里有仅大小写不同的文件）。
source "$(dirname "$0")/lib.sh"

if [ ! -d "$KERNEL_DIR/.git" ]; then
  log "拉取上游内核源码: $KERNEL_REPO @ $KERNEL_PIN"
  rm -rf "$KERNEL_DIR"
  mkdir -p "$KERNEL_DIR"
  git -C "$KERNEL_DIR" init -q
  git -C "$KERNEL_DIR" remote add origin "$KERNEL_REPO"
  git -C "$KERNEL_DIR" fetch --depth 1 origin "$KERNEL_PIN"
  git -C "$KERNEL_DIR" checkout -q FETCH_HEAD
else
  log "复用已有源码树: $KERNEL_DIR"
fi

head_sha="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
[ "$head_sha" = "$KERNEL_PIN" ] || die "源码 commit 不匹配：期望 ${KERNEL_PIN}，实际 ${head_sha}"
log "源码 commit 校验通过: $head_sha"

bash "$REPO_ROOT/scripts/setup-toolchain.sh"
bash "$REPO_ROOT/scripts/build.sh"
