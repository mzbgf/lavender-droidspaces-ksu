# 4.19 内核本地编译环境（与 CI 同构：x86_64 + AOSP 预编译 clang r416183b）
#
# 为什么是 x86_64 而不是 arm64：
#   AOSP 预编译 clang 只有 linux-x86_64 版。用它能保证「本地构建」与
#   「GitHub Actions 构建」用完全相同的工具链，产物可比、结论可信。
#   OrbStack 在 Apple Silicon 上用 Rosetta 跑 amd64 容器（实测约 2.25x 开销，
#   且是 shell 循环的最坏情况；编译器这类计算型负载通常 1.3~1.6x）。
#
# 对比 arm64 原生 + 发行版 clang（如 bookworm 的 clang-14）：
#   快一些，但 clang 版本与 CI 不同 → 排查启动问题时结论会被工具链差异干扰。
#   两者都留着：这个镜像做主力，发行版 clang 可作为快速旁证。
FROM --platform=linux/amd64 debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      bc bison flex libssl-dev libelf-dev lz4 xz-utils zip unzip \
      ccache python3 git ca-certificates curl rsync make gcc \
    && rm -rf /var/lib/apt/lists/*

# 只取「单个 clang 版本」的压缩包，不 clone 整个 prebuilts 仓库（那是几十 GB）
ARG CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android12-release/clang-r416183b.tar.gz"
RUN mkdir -p /opt/clang \
    && curl -fL --retry 5 --retry-delay 5 "$CLANG_URL" -o /tmp/clang.tar.gz \
    && tar xzf /tmp/clang.tar.gz -C /opt/clang \
    && rm -f /tmp/clang.tar.gz \
    && /opt/clang/bin/clang --version | head -1

# 补丁/打包必需、但基础层漏掉的命令。单开一层而不是并进上面那层 apt：
# clang 层的下载要几分钟，并进去会让每次改依赖都重下一次 clang。
# patch 缺失时 apply-patches.sh 会报「补丁与源码树不匹配」，指向完全错误的方向。
RUN apt-get update && apt-get install -y --no-install-recommends \
      patch cpio device-tree-compiler \
    && rm -rf /var/lib/apt/lists/* \
    && patch --version | head -1

ENV PATH=/opt/clang/bin:$PATH
ENV CLANG_DIR=/opt/clang

# ccache 是复用场景的关键：首次全量 ~12min，之后改一个 .c 只需 1~3min；
# 这几个 sloppiness 项避免 mtime 变化导致整库 miss
ENV CCACHE_DIR=/ccache
ENV CCACHE_MAXSIZE=10G
ENV CCACHE_SLOPPINESS=file_stat_matches,time_macros,include_file_ctime

# 通过 ccache 调 clang（与 CI 一致）
ENV CC_CMD="ccache clang"

WORKDIR /recipe
SHELL ["/bin/bash", "-lc"]
