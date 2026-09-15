#!/usr/bin/env bash
# 校验合并后的 .config：Droidspaces 必需项 / KernelSU / 开机关键项 / 禁止项
# 用法: bash scripts/check-configs.sh [out/.config]
# 退出码: 0 全部满足; 1 有 FAIL
#
# 符号名映射（官方文档写的是 5.x 名字，4.19 树里的实际名字不同）：
#   NETFILTER_XT_TARGET_MASQUERADE -> IP_NF_TARGET_MASQUERADE
#   NETFILTER_XT_TARGET_REJECT     -> IP_NF_TARGET_REJECT
#   NF_CONNTRACK_NETLINK           -> NF_CT_NETLINK
#   NF_NAT_REDIRECT                -> NETFILTER_XT_TARGET_REDIRECT
#   NF_CONNTRACK_IPV4 / FW_LOADER_COMPRESS / IP_NF_TARGET_ULOG -> 本树无此符号
source "$(dirname "$0")/lib.sh"

CFG="${1:-$OUT_DIR/.config}"
require_file "$CFG"

get() {
  # 注意：lib.sh 开了 pipefail，config 里不存在的符号会让 grep 返回 1；
  # 必须吞掉这个状态，否则 set -e 会让整个校验脚本在这里中止
  local v
  v="$(grep -E "^CONFIG_$1=" "$CFG" 2>/dev/null | tail -1 | cut -d= -f2)" || v=""
  printf '%s' "$v"
}
isset() { grep -qE "^CONFIG_$1=" "$CFG" 2>/dev/null; }

rc=0
pass() { echo "  OK    $*"; }
fail() { echo "  FAIL  $*"; rc=1; }
warn_() { echo "  WARN  $*"; }

# 条目格式: SYMBOL 或 SYMBOL,替代符号 或 SYMBOL,M(=本树无此符号)
check_y() {
  local entry="$1" name alt v av
  name="${entry%%,*}"; alt=""
  if [ "$entry" != "$name" ]; then alt="${entry#*,}"; fi
  v="$(get "$name")"
  if [ "$v" = "y" ]; then pass "$name=y"; return 0; fi
  if [ "$alt" = "M" ]; then pass "$name 本树无此符号（放行）"; return 0; fi
  if [ -n "$alt" ]; then
    av="$(get "$alt")"
    if [ "$av" = "y" ]; then pass "$name (由 $alt=y 提供)"; return 0; fi
  fi
  fail "$name -> '${v:-未设置}' (期望 y)"
}

echo "=== [1/4] Droidspaces 核心（官方 non-GKI 必选） ==="
for e in SYSCTL SYSVIPC POSIX_MQUEUE NAMESPACES PID_NS UTS_NS IPC_NS NET_NS \
         SECCOMP SECCOMP_FILTER CGROUPS CGROUP_DEVICE CGROUP_PIDS MEMCG \
         CGROUP_SCHED FAIR_GROUP_SCHED CGROUP_FREEZER CGROUP_NET_PRIO DEVTMPFS \
         OVERLAY_FS TMPFS_POSIX_ACL TMPFS_XATTR FW_LOADER FW_LOADER_USER_HELPER; do
  check_y "$e"
done

echo "=== [2/4] Droidspaces 网络隔离（NAT 模式） ==="
for e in VETH BRIDGE NETFILTER BRIDGE_NETFILTER NETFILTER_ADVANCED NF_CONNTRACK \
         IP_NF_IPTABLES IP_NF_FILTER NF_NAT NF_TABLES IP_NF_TARGET_MASQUERADE \
         NETFILTER_XT_TARGET_MASQUERADE,IP_NF_TARGET_MASQUERADE \
         NETFILTER_XT_TARGET_TCPMSS NETFILTER_XT_MATCH_ADDRTYPE \
         NF_CONNTRACK_NETLINK,NF_CT_NETLINK NF_NAT_REDIRECT,NETFILTER_XT_TARGET_REDIRECT \
         IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES NF_NAT_IPV4 IP_NF_NAT IP6_NF_IPTABLES \
         USER_NS BLK_DEV_LOOP EXT4_FS; do
  check_y "$e"
done

echo "=== [3/4] KernelSU / reSukiSU（必须 manual hook，且不得启用 SUSFS） ==="
check_y KSU
check_y KSU_MANUAL_HOOK
if grep -qE '^CONFIG_KSU_SUSFS=y' "$CFG"; then
  fail "CONFIG_KSU_SUSFS=y（要求不使用 SUSFS）"
else
  pass "CONFIG_KSU_SUSFS 未启用"
fi
for s in KSU_MANUAL_HOOK_AUTO_SETUID_HOOK KSU_MANUAL_HOOK_AUTO_INITRC_HOOK KSU_MANUAL_HOOK_AUTO_INPUT_HOOK; do
  if ! isset "$s"; then warn_ "$s 未出现（若该版本无此选项可忽略）"; fi
done

echo "=== [4/4] 开机关键项（必须与目标 ROM 的 stock 内核一致，不得漂移） ==="
for e in RD_LZ4 PSI; do check_y "$e"; done
# 下面两项是「树相关」的，不同源码线处理方式不同，所以只提示不强制：
#   - ANDROID_VENDOR_HOOKS：有的树 fs/open.c 根本不调用 trace_android_vh_check_file_open()，
#     也就不需要这个符号；
#   - ANDROID_PARANOID_NETWORK：有的树本身就保留着这套老逻辑。
v="$(get ANDROID_VENDOR_HOOKS)"
if [ "$v" = "y" ]; then pass "ANDROID_VENDOR_HOOKS=y"; else warn_ "ANDROID_VENDOR_HOOKS=${v:-未设置}（本树若不需要该符号可忽略）"; fi
for s in MODULES KPROBES; do
  v="$(get "$s")"
  if [ "$v" = "y" ]; then fail "$s=y（目标 ROM 的 stock 内核为 n）"; else pass "$s 未启用"; fi
done

# 栈变量初始化必须显式钉在 ZERO：这一项是「编译器能力探测决定默认值」的三选一，
# 不钉就会随工具链静默分叉。CI 曾落到 NONE，真机表现是开机约 54 秒时在回收路径
# buffer_check_dirty_writeback 空指针 oops，kswapd 被杀、整机随后僵死。
v="$(get INIT_STACK_ALL_ZERO)"
if [ "$v" = "y" ]; then
  pass "INIT_STACK_ALL_ZERO=y"
else
  fail "INIT_STACK_ALL_ZERO -> '${v:-未设置}'（期望 y；落到 NONE 的构建在真机上会崩）"
fi

# LTO 三选一同样由编译器能力探测决定（基座 defconfig 想开 ThinLTO，但探测失败会
# 静默退回 NONE）。与已验证基线保持一致钉在 NONE；要用 ThinLTO 属于独立的代码
# 生成变更，必须单独真机 A/B 验证后再同时改这里与片段。
v="$(get LTO_NONE)"
if [ "$v" = "y" ]; then
  pass "LTO_NONE=y"
else
  fail "LTO_NONE -> '${v:-未设置}'（期望 y；与已验证基线不一致的代码生成变更需单独验证）"
fi
v="$(get ANDROID_PARANOID_NETWORK)"
if [ -z "$v" ] || [ "$v" = "n" ]; then pass "ANDROID_PARANOID_NETWORK 未启用"; else warn_ "ANDROID_PARANOID_NETWORK=${v}（该树保留了老逻辑，仅提示）"; fi

# 版本串必须与基座 defconfig 保持一致：merge_config.sh 曾把基座里的
# LOCALVERSION 行删掉（因为片段注释里出现了带前缀的符号名），这里做兜底断言。
BASE_DEFCONFIG="$KERNEL_DIR/$KERNEL_BASE_DEFCONFIG"
if [ -f "$BASE_DEFCONFIG" ]; then
  expect_lv="$(grep -E '^CONFIG_LOCALVERSION=' "$BASE_DEFCONFIG" | tail -1 | cut -d'"' -f2)"
  [ -n "${LOCALVERSION_OVERRIDE:-}" ] && expect_lv="$LOCALVERSION_OVERRIDE"
  got_lv="$(grep -E '^CONFIG_LOCALVERSION=' "$CFG" | tail -1 | cut -d'"' -f2)"
  if [ "$got_lv" = "$expect_lv" ]; then
    pass "LOCALVERSION=\"${got_lv}\""
  else
    fail "LOCALVERSION=\"${got_lv}\"（期望 \"${expect_lv}\"）——版本串被改动，uname -r 会与 ROM 不一致"
  fi
fi

echo "=== 防火墙/UFW 支持（告警级） ==="
for e in NETFILTER_XT_MATCH_COMMENT NETFILTER_XT_MATCH_STATE NETFILTER_XT_MATCH_CONNTRACK \
         NETFILTER_XT_MATCH_MULTIPORT NETFILTER_XT_MATCH_HL \
         NETFILTER_XT_TARGET_REJECT,IP_NF_TARGET_REJECT IP_NF_TARGET_REJECT \
         NETFILTER_XT_TARGET_LOG NETFILTER_XT_MATCH_RECENT NETFILTER_XT_MATCH_LIMIT \
         NETFILTER_XT_MATCH_HASHLIMIT NETFILTER_XT_MATCH_OWNER NETFILTER_XT_MATCH_PKTTYPE \
         NETFILTER_XT_MATCH_MARK NETFILTER_XT_TARGET_MARK IP_SET IP_SET_HASH_IP \
         IP_SET_HASH_NET NETFILTER_XT_SET NETFILTER_NETLINK_QUEUE \
         NETFILTER_NETLINK_LOG NETFILTER_XT_TARGET_NFLOG; do
  v="$(get "${e%%,*}")"
  [ "$v" = "y" ] || warn_ "${e%%,*} -> '${v:-未设置}'"
done

echo
if [ "$rc" -eq 0 ]; then
  log "config 校验通过 ✔  ($CFG)"
else
  die "config 校验失败 ✘（见上方 FAIL）"
fi
