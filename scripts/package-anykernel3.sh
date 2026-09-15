#!/usr/bin/env bash
# 把内核镜像打成 AnyKernel3 刷机包（recovery 直刷）
#
# 只替换 boot 分区里的内核，复用 ROM 现有 ramdisk；不触碰 dtbo / vbmeta。
source "$(dirname "$0")/lib.sh"

BOOT="$OUT_DIR/arch/arm64/boot"
IMG="$BOOT/Image.gz-dtb"
GZ="$BOOT/Image.gz"
DTB="$BOOT/dts/vendor/qcom/sdm660-mtp-lavender.dtb"
# dtb 型号串：不同基座树对同一台机器的 model 不完全一样（pix106 树是「…MTP F7A」，
# San-Kernel 树是「…MTP, Lavender」），这里只认公共前缀；要卡整串时用 LAV_MODEL 覆盖。
LAV_MODEL="${LAV_MODEL:-Qualcomm Technologies, Inc. SDM 660 PM660 + PM660L MTP}"

# 1) 准备内核镜像：优先用内核自建的 Image.gz-dtb；若其中没有 dtb（该树的
#    DTB_OBJS 用 parse-time find 计算，首次构建可能拿到空列表），则手工拼接。
if [ ! -f "$IMG" ] || ! grep -qa "$LAV_MODEL" "$IMG"; then
  warn "Image.gz-dtb 缺失或不含 lavender dtb，改为手工拼接 Image.gz + lavender.dtb"
  require_file "$GZ"
  require_file "$DTB"
  cat "$GZ" "$DTB" >"$IMG"
fi
grep -qa "$LAV_MODEL" "$IMG" || die "拼接后仍找不到 lavender dtb"

KREL="${KERNEL_RELEASE:-$(kernel_release || echo 4.19.325)}"

# 2) 准备 AnyKernel3
if [ ! -d "$ANY_KERNEL_DIR/.git" ]; then
  log "clone AnyKernel3: $ANY_KERNEL_REPO"
  rm -rf "$ANY_KERNEL_DIR"
  git clone --depth 1 "$ANY_KERNEL_REPO" "$ANY_KERNEL_DIR"
fi

# 3) 写入适配 lavender 的 anykernel.sh（模板里的 @KERNEL_VERSION@ 换成实际版本串）
require_file "$REPO_ROOT/anykernel/anykernel.sh"
sed "s/@KERNEL_VERSION@/$KREL/g" "$REPO_ROOT/anykernel/anykernel.sh" >"$ANY_KERNEL_DIR/anykernel.sh"
bash -n "$ANY_KERNEL_DIR/anykernel.sh" || die "anykernel.sh 语法检查失败"

# 4) 放入内核镜像并打包
cp -f "$IMG" "$ANY_KERNEL_DIR/Image.gz-dtb"
rm -rf "$ANY_KERNEL_DIR/.git" "$ANY_KERNEL_DIR/modules"

# 防呆：ak3-core.sh 按 zImage → Image → Image.gz → Image.gz-dtb … 的固定顺序挑
# 第一个存在的内核镜像文件，一旦目录里混进别的同名占位文件，刷进去的就不是我们的
# 内核（且不会有任何报错）。这里显式清掉除 Image.gz-dtb 之外的所有候选名。
for name in zImage zImage-dtb Image Image-dtb Image.gz Image.bz2 Image.bz2-dtb \
            Image.lzo Image.lzo-dtb Image.lzma Image.lzma-dtb Image.xz Image.xz-dtb \
            Image.lz4 Image.lz4-dtb Image.fit; do
  [ "$name" = "Image.gz-dtb" ] && continue
  if [ -e "$ANY_KERNEL_DIR/$name" ]; then
    warn "删除 AnyKernel3 里多余的镜像占位文件: $name"
    rm -f "$ANY_KERNEL_DIR/$name"
  fi
done
[ -f "$ANY_KERNEL_DIR/Image.gz-dtb" ] || die "AnyKernel3 目录里没有 Image.gz-dtb"

ZIP="$REPO_ROOT/AnyKernel3-lavender-${KREL}-$(date +%Y%m%d).zip"
rm -f "$ZIP"
# 命令与 AnyKernel3 官方 README 一致（排除 README 与所有 *placeholder 占位文件）
(
  cd "$ANY_KERNEL_DIR"
  zip -r9 "$ZIP" * -x README.md '*placeholder' >/dev/null
)

# 5) 校验 zip 结构
# 产物 zip 直接写在 bind mount（macOS 侧）上时，容器紧接着把它读回来偶尔会读不到
# （virtiofs 可见性延迟，表现为「zip 里缺少 anykernel.sh」这种假阴性），所以带重试。
verify_zip() {
  local want
  for want in anykernel.sh tools/magiskboot tools/ak3-core.sh Image.gz-dtb META-INF/com/google/android/update-binary; do
    unzip -l "$ZIP" 2>/dev/null | grep -q "$want" || return 1
  done
  return 0
}
zip_ok=""
for i in 1 2 3 4 5; do
  if verify_zip; then zip_ok=1; break; fi
  warn "第 ${i} 次校验 zip 结构未通过（bind mount 可见性延迟？）"
  sleep 1
done
[ -n "$zip_ok" ] || die "zip 结构校验失败（已重试 5 次）"
log "刷机包: $ZIP ($(( $(wc -c <"$ZIP") / 1024 / 1024 )) MiB)"
unzip -l "$ZIP" | sed 's/^/    /'
