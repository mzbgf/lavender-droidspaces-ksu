#!/usr/bin/env bash
# 用 magiskboot 把「原厂 boot.img 的 ramdisk/header」与「本仓库编译出的内核」重打包成
# 可直接 `fastboot boot` 的镜像（仅 RAM 内临时启动验证，不写分区）。
#
# 为什么用 magiskboot：它就是这个用途的专用工具（AnyKernel3 在设备端用的也是它），
# header v0~v4、AVB/AVBf、ramdisk 压缩（gzip/lz4/lz4_legacy/xz…）、追加 dtb 的拆分与
# 重组、recovery_dtbo 等细节它都处理过，自己写解析器属于重复劳动且容易漏格式。
#
# 用法：
#   bash scripts/make-boot-img.sh --stock stock-boot.img --kernel AnyKernel3-lavender-*.zip -o new-boot.img
#   --stock：ROM 原厂 boot.img（ramdisk 必须是 ROM 自己那份）
#   --kernel：刷机包 zip，或裸的 Image.gz-dtb
#
# 平台：Linux 直接跑；macOS 自动改用容器跑 Linux 版 magiskboot（arm64 原生速度）。
source "$(dirname "$0")/lib.sh"

MAGISK_VERSION="${MAGISK_VERSION:-v30.7}"
WORKDIR="${WORKDIR:-$REPO_ROOT/.makeboot}"

STOCK=""; KERNEL=""; OUTPUT="new-boot.img"
while [ $# -gt 0 ]; do
  case "$1" in
    --stock) STOCK="$2"; shift 2 ;;
    --kernel) KERNEL="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done
[ -n "$STOCK" ]  || die "缺少 --stock <原厂 boot.img>"
[ -n "$KERNEL" ] || die "缺少 --kernel <Image.gz-dtb|AnyKernel3 zip>"
require_file "$STOCK"; require_file "$KERNEL"

mkdir -p "$WORKDIR"
STOCK="$(cd "$(dirname "$STOCK")" && pwd)/$(basename "$STOCK")"
KERNEL="$(cd "$(dirname "$KERNEL")" && pwd)/$(basename "$KERNEL")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"

# ---------------------------------------------------------------- magiskboot
NEED_CONTAINER=0
if [ "$(uname -s)" = "Darwin" ]; then
  NEED_CONTAINER=1
  command -v docker >/dev/null 2>&1 || die "macOS 上需要 docker（OrbStack 即可）来跑 Linux 版 magiskboot"
  MB_IMAGE="${MB_IMAGE:-ubuntu:22.04}"
  log "macOS：用容器 ${MB_IMAGE} 运行 magiskboot（arm64 原生）"
fi

fetch_magiskboot() {
  local arch dest apk
  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    aarch64|arm64) arch=arm64-v8a ;;
    *) die "不支持的宿主架构 $(uname -m)" ;;
  esac
  dest="$WORKDIR/magiskboot-$arch"
  [ -x "$dest" ] && { echo "$dest"; return; }
  apk="$(ls "$WORKDIR"/Magisk-*.apk 2>/dev/null | head -1 || true)"
  if [ -z "$apk" ]; then
    # 注意：这里必须输出到 stderr——函数的 stdout 会被上层用 $(...) 捕获成路径
    log "从 Magisk ${MAGISK_VERSION} 的 APK 里取 ${arch} 版 magiskboot" >&2
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh release download "$MAGISK_VERSION" --repo topjohnwu/Magisk \
        --pattern "Magisk-${MAGISK_VERSION}.apk" --dir "$WORKDIR" --clobber >/dev/null 2>&1 || true
    fi
    apk="$(ls "$WORKDIR"/Magisk-*.apk 2>/dev/null | head -1 || true)"
    if [ -z "$apk" ]; then
      # 公开 release 资产，不需要登录；gh 没登录时走这条路
      local url="https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_VERSION}/Magisk-${MAGISK_VERSION}.apk"
      curl -fL --retry 3 -o "$WORKDIR/Magisk-${MAGISK_VERSION}.apk" "$url" >/dev/null 2>&1 || true
      apk="$(ls "$WORKDIR"/Magisk-*.apk 2>/dev/null | head -1 || true)"
    fi
  fi
  [ -n "$apk" ] || die "拿不到 Magisk APK：请手动下载 ${MAGISK_VERSION} 的 APK 放到 ${WORKDIR}/ 再重试"
  unzip -o -q "$apk" "lib/$arch/libmagiskboot.so" -d "$WORKDIR/apk"
  cp -f "$WORKDIR/apk/lib/$arch/libmagiskboot.so" "$dest"
  chmod +x "$dest"
  echo "$dest"
}
MB="$(fetch_magiskboot | tail -n1)"
log "magiskboot: $MB"

# 在指定目录里执行 magiskboot（容器模式挂两个点：/mb 放二进制，/w 放工作目录）
mb() {
  local dir="$1"; shift
  if [ "$NEED_CONTAINER" = "1" ]; then
    docker run --rm --platform linux/arm64 -v "$WORKDIR":/mb -v "$dir":/w -w /w \
      "$MB_IMAGE" "/mb/$(basename "$MB")" "$@"
  else
    (cd "$dir" && "$MB" "$@")
  fi
}

# ---------------------------------------------------------------- 工具函数
if command -v sha1sum >/dev/null 2>&1; then _SHA="sha1sum"; else _SHA="shasum -a 1"; fi
hash_file()  { $_SHA "$1" | cut -d' ' -f1; }
hash_stdin() { $_SHA | cut -d' ' -f1; }

# 内核 blob 的「有效载荷」sha1：magiskboot 解包时会把 gzip 内核解压、并把追加的 dtb
# 拆成独立的 kernel_dtb；重打包时再压回去。所以字节比对没有意义，要比解压后的内容。
payload_sha() {
  if [ "$(od -An -tx1 -N2 "$1" | tr -d ' \n')" = "1f8b" ]; then
    gzip -dc "$1" 2>/dev/null | hash_stdin || true
  else
    hash_file "$1"
  fi
}

# 内核文件里是否自带追加的 dtb（FDT magic d00dfeed）
has_dtb() {
  LC_ALL=C grep -qa "$(printf '\xd0\x0d\xfe\xed')" "$1" 2>/dev/null
}

# 解包日志里的字段（magiskboot 输出到 stderr 且带 ANSI 颜色码）
mb_info() {
  sed 's/\x1b\[[0-9;]*m//g' "$1" | grep -a "^$2" | tail -1 | sed "s/^$2 *//"
}

# ---------------------------------------------------------------- 解包原厂
STAGE="$WORKDIR/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp "$STOCK" "$STAGE/stock.img"
log "解包原厂 boot.img"
mb "$STAGE" unpack stock.img >"$WORKDIR/unpack.log" 2>&1 || die "magiskboot 解包失败，见 ${WORKDIR}/unpack.log"
cat "$WORKDIR/unpack.log" | sed 's/^/    /'
require_file "$STAGE/kernel"
require_file "$STAGE/ramdisk.cpio"

STOCK_RD_SHA="$(hash_file "$STAGE/ramdisk.cpio")"
STOCK_K_PAYLOAD="$(payload_sha "$STAGE/kernel")"
log "原厂 ramdisk.cpio sha1 = ${STOCK_RD_SHA}"
log "原厂 内核载荷  sha1 = ${STOCK_K_PAYLOAD}"

# ---------------------------------------------------------------- 换内核 + repack
if unzip -l "$KERNEL" >/dev/null 2>&1; then
  log "从刷机包 zip 里取内核镜像"
  (cd "$STAGE" && unzip -o -q "$KERNEL" Image.gz-dtb && mv -f Image.gz-dtb kernel)
else
  log "用裸内核镜像替换"
  cp -f "$KERNEL" "$STAGE/kernel"
fi

# 原厂镜像若自带独立的 kernel_dtb，而我们给的内核已经内含 dtb，就丢掉那份旧的，
# 避免重打包后出现两份 dtb（本仓库的 dtb 与原厂同源，但保持唯一更可控）
if [ -f "$STAGE/kernel_dtb" ] && has_dtb "$STAGE/kernel"; then
  log "内核对侧已自带 dtb：丢弃原厂解出的 kernel_dtb（避免重复）"
  rm -f "$STAGE/kernel_dtb"
fi

NEW_K_SHA="$(hash_file "$STAGE/kernel")"
NEW_K_PAYLOAD="$(payload_sha "$STAGE/kernel")"
NEW_K_SIZE="$(wc -c <"$STAGE/kernel" | tr -d ' ')"
log "新内核文件 sha1 = ${NEW_K_SHA}（${NEW_K_SIZE} 字节）"
log "新内核载荷 sha1 = ${NEW_K_PAYLOAD}"

log "repack"
mb "$STAGE" repack stock.img new-boot.img >"$WORKDIR/repack.log" 2>&1 || die "magiskboot 重打包失败，见 ${WORKDIR}/repack.log"
require_file "$STAGE/new-boot.img"
cp -f "$STAGE/new-boot.img" "$OUTPUT"
OUT_SIZE="$(wc -c <"$OUTPUT" | tr -d ' ')"
log "写出 ${OUTPUT}（${OUT_SIZE} 字节）"

# ---------------------------------------------------------------- 自校验
VER="$WORKDIR/verify"; rm -rf "$VER"; mkdir -p "$VER"
cp "$OUTPUT" "$VER/new-boot.img"
mb "$VER" unpack new-boot.img >"$WORKDIR/verify.log" 2>&1 || die "校验失败：新镜像无法解包（见 ${WORKDIR}/verify.log）"
require_file "$VER/ramdisk.cpio"

NEW_RD_SHA="$(hash_file "$VER/ramdisk.cpio")"
[ "$NEW_RD_SHA" = "$STOCK_RD_SHA" ] || die "校验失败：新镜像的 ramdisk 与原厂不一致（${NEW_RD_SHA} != ${STOCK_RD_SHA}）"

CHK_K_PAYLOAD="$(payload_sha "$VER/kernel")"
[ "$CHK_K_PAYLOAD" = "$NEW_K_PAYLOAD" ] || die "校验失败：新镜像里的内核载荷与我们的产物不一致"
[ "$CHK_K_PAYLOAD" != "$STOCK_K_PAYLOAD" ] || die "校验失败：新镜像里的内核还是原厂那个，没换成功"

if has_dtb "$STAGE/kernel"; then
  if grep -qa "PM660L MTP" "$VER/kernel" 2>/dev/null || grep -qa "PM660L MTP" "$VER/kernel_dtb" 2>/dev/null; then
    log "新镜像里含 lavender dtb ✔"
  else
    warn "新镜像里没搜到 lavender dtb 串（换了机型请忽略）"
  fi
fi

log "自校验通过 ✔"
log "  ramdisk 与原厂逐字节一致（sha1 ${NEW_RD_SHA}）"
log "  内核载荷已换成本仓库产物（sha1 ${NEW_K_PAYLOAD}，原厂为 ${STOCK_K_PAYLOAD}）"
for k in HEADER_VER PAGESIZE RAMDISK_FMT KERNEL_FMT; do
  printf '    新镜像 %-12s %s\n' "$k" "$(mb_info "$WORKDIR/verify.log" "$k" || true)"
done
echo
log "临时启动（只进内存，不写分区，重启即恢复原内核）："
log "  adb reboot bootloader"
log "  fastboot boot ${OUTPUT}"
