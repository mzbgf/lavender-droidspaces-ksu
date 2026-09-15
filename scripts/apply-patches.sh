#!/usr/bin/env bash
# 顺序应用本仓库的全部补丁到内核源码树。
#
# 幂等：每个补丁指定「已应用标志」（在特定文件里 grep 一个只可能由该补丁引入的字符串）。
#       标志已存在 -> 跳过；不存在 -> 先 --dry-run 预检，通过后才真正打；预检失败即退出。
# 补丁均为针对 $KERNEL_PIN 这一棵树重新生成/校验过的版本，见 patches/README.md。
source "$(dirname "$0")/lib.sh"

require_dir "$KERNEL_DIR"
require_cmd patch
cd "$KERNEL_DIR"

PATCHES_DIR="$REPO_ROOT/patches"

# 表：补丁文件 | 用于判重的文件 | 判重 grep 模式（ERE）| 人类可读名字 | 应用条件
#   条件 always   = 总是应用
#   条件 openssl3 = 仅当构建机的 openssl 需要它时应用（拿不到 <openssl/engine.h>）
TABLE=(
  "buildfix/0001-cgroup-noprefix-compat-links.patch|kernel/cgroup/cgroup.c|kernfs_create_link\(cgrp->kn, name, kn\)|Droidspaces: cgroup noprefix 前缀别名|always"
  "buildfix/0002-write-once-expression.patch|include/linux/compiler.h|typeof\(x\) __val = \(val\);|构建修正: WRITE_ONCE 恢复表达式语义|always"
  "buildfix/0003-extract-cert-openssl3-compat.patch|scripts/extract-cert.c|OPENSSL_VERSION_NUMBER >= 0x30000000L|构建修正: extract-cert 适配 OpenSSL 3|openssl3"
  "buildfix/0004-kshrinkd-null-memcg.patch|mm/vmscan.c|memcg && !mem_cgroup_disabled\(\)|构建修正: kshrinkd 传 NULL memcg 导致空指针|always"
  "resukisu/0001-manual-hooks.patch|fs/stat.c|ksu_handle_stat|reSukiSU: manual hook（stat/exec/faccessat/reboot）|always"
  "resukisu/0002-selinux-symbol-exports.patch|security/selinux/selinuxfs.c|^ssize_t \(\*const write_op\[\]\)|reSukiSU: SELinux 静态符号导出|always"
)

# 构建机上 <openssl/engine.h> 是否可用（OpenSSL >= 3.5 已移除该头文件）
has_openssl_engine_h() {
  echo '#include <openssl/engine.h>' | "${CC:-cc}" -E - >/dev/null 2>&1
}

applied=0
skipped=0

for row in "${TABLE[@]}"; do
  IFS='|' read -r rel target marker name cond <<<"$row"
  pfile="$PATCHES_DIR/$rel"
  [ -f "$pfile" ] || die "缺少补丁文件: $pfile"
  [ -f "$target" ] || die "目标文件不存在: ${target}（补丁与源码树不匹配）"

  if [ "$cond" = "openssl3" ] && has_openssl_engine_h; then
    log "跳过（本机 OpenSSL 仍提供 engine.h，无需该修正）: $name"
    skipped=$((skipped + 1))
    continue
  fi

  if grep -qE "$marker" "$target"; then
    log "跳过（已应用）: $name"
    skipped=$((skipped + 1))
    continue
  fi

  log "应用: $name"
  dr_out=""
  if ! dr_out="$(patch -p1 --forward --dry-run <"$pfile" 2>&1)"; then
    printf '%s\n' "$dr_out" | sed 's/^/    /' >&2
    die "预检失败，补丁与源码树不匹配: $rel"
  fi
  patch -p1 --forward --silent <"$pfile"
  grep -qE "$marker" "$target" || die "打完补丁但判重标志仍未出现: $rel"
  applied=$((applied + 1))
done

log "补丁完成：新应用 $applied 个，跳过 $skipped 个"
