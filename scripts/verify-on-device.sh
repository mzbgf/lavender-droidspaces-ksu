#!/usr/bin/env bash
# 真机侧验证：确认设备当前跑的是本仓库产出的内核，并逐项检查 Droidspaces / KSU 依赖。
#
# 用法：
#   bash scripts/verify-on-device.sh                      # 基础检查（需要 adb 连着一台设备）
#   bash scripts/verify-on-device.sh --marker repacktest=san1
#
# 为什么不拿设备的 /proc/config.gz 做断言：本基座树把 IKCONFIG 的数据源硬编码成厂家的
# 完整 defconfig（kernel/Makefile 里 config_data.gz 的依赖），那份配置与当前运行内核
# 无关。所以这里只检查「运行时的真实能力」，那才是证据。
source "$(dirname "$0")/lib.sh"

MARKER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --marker) MARKER="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

require_cmd adb

ok=0; bad=0
pass() { printf '  \033[1;32mOK\033[0m    %s\n' "$*"; ok=$((ok + 1)); }
fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; bad=$((bad + 1)); }
warn_() { printf '  \033[1;33mWARN\033[0m  %s\n' "$*"; }

sh_() { adb shell "$1" 2>/dev/null | tr -d '\r'; }

n="$(adb devices | sed -n '2,$p' | grep -c 'device$' || true)"
[ "$n" = "1" ] || die "需要恰好 1 台 adb 设备在线（当前 ${n} 台）"

echo "=== [1/5] 跑的是哪份内核 ==="
REL="$(sh_ 'uname -r')"
VER="$(sh_ 'cat /proc/version')"
log "uname -r    : $REL"
log "proc/version: $VER"
[ -n "$REL" ] || die "读不到 uname -r"

CMD_DEV="$(sh_ 'cat /proc/cmdline')"
if [ -n "$MARKER" ]; then
  case "$CMD_DEV" in
    *"$MARKER"*) pass "cmdline 里出现临时标记 ${MARKER}（确认是我们 fastboot boot 的那份镜像）" ;;
    *) fail "cmdline 里没有 ${MARKER}：设备跑的不是我们这次的镜像（可能已回落）" ;;
  esac
fi

echo "=== [2/5] KernelSU 运行时线索 ==="
# 注意：本基座树把 IKCONFIG 的数据源硬编码成厂家的完整 defconfig
#   kernel/Makefile: $(obj)/config_data.gz: arch/arm64/configs/vendor/sdm660-perf-full_defconfig
# 所以 /proc/config.gz 报的是「厂家那份配置」，**不代表当前运行内核的真实配置**，
# 不能拿它来断言本内核的 KSU / cgroup / namespace 等选项。
# 真正能证明「跑的是我们这份、且功能齐备」的是下面的运行时检查。
if adb shell 'ls /proc/config.gz' >/dev/null 2>&1; then
  warn_ "/proc/config.gz 存在，但本树它是厂家 defconfig 的副本，仅作参照，不做断言"
fi
if [ -n "$(sh_ 'ls /data/adb/ksu 2>/dev/null')" ]; then
  pass "/data/adb/ksu 存在（KernelSU 管理器已初始化过）"
elif [ -n "$(sh_ 'ls /sys/module/kernelsu 2>/dev/null')" ]; then
  pass "内核里有 kernelsu 模块目录"
else
  warn_ "看不到 KSU 的运行时痕迹：需装 reSukiSU/KernelSU 管理器并打开一次才能确认（见第 5 步）"
fi
if [ -n "$(sh_ 'ls /data/adb/modules 2>/dev/null')" ]; then
  pass "KSU 模块目录 /data/adb/modules 可读"
fi

echo "=== [3/5] Droidspaces 需要的运行时内核能力 ==="
cg="$(sh_ 'cat /proc/cgroups' | awk 'NR>1 {print $1}')"
for c in devices pids memory freezer net_prio; do
  case "$cg" in *"$c"*) pass "cgroup 控制器: $c" ;; *) fail "缺少 cgroup 控制器: $c" ;; esac
done
case "$(sh_ 'cat /proc/filesystems')" in
  *overlay*) pass "overlay 文件系统可用" ;;
  *) fail "overlay 文件系统不可用" ;;
esac
ns="$(sh_ 'ls /proc/self/ns' | tr '\n' ' ')"
for x in ipc mnt net pid user uts; do
  case "$ns" in *"$x"*) pass "namespace: $x" ;; *) fail "缺少 namespace: $x" ;; esac
done

echo "=== [4/5] 开机与运行状态 ==="
log "uptime: $(sh_ 'uptime' | sed 's/^ *//')"
if [ -n "$(sh_ 'ls /sys/class/net 2>/dev/null | head -1')" ]; then
  pass "网络接口已就绪: $(sh_ 'ls /sys/class/net' | tr '\n' ' ')"
else
  warn_ "看不到网络接口（可能仍在启动中）"
fi
if [ -n "$(sh_ 'ls /dev/block/by-name/boot 2>/dev/null')" ]; then
  pass "能读到 boot 分区节点（回滚时用）"
fi

echo "=== [5/5] 仍需你在手机上确认的项（脚本无法代替） ==="
cat <<'EOF'
  - Wi-Fi / 蓝牙 / 移动信号是否正常
  - 装 ReSukiSU 或 KernelSU 管理器，执行 su -c id 是否为 root
  - Droidspaces 应用内的自检（容器能否创建、能否联网）
  - 屏幕触摸、通话、相机等日常功能
EOF

echo
if [ "$bad" -eq 0 ]; then
  log "设备侧检查通过：${ok} 项 OK，0 项失败 ✔"
else
  die "设备侧检查不通过：${ok} 项 OK，${bad} 项失败 ✘（见上方 FAIL）"
fi
