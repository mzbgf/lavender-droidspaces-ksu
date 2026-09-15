#!/usr/bin/env bash
# make-boot-img.sh 的自测：造一个格式合法的合成原厂 boot.img（真 newc cpio ramdisk +
# gzip 内核 + 真实 lavender cmdline），用仓库编译出的内核替换，再独立复核产物。
#
# 目的：让「fastboot boot 那条路」有可重复的验证，而不是只在某台机器上手试过。
# CI（x86_64 Linux）与本地都能跑；本地 macOS 会自动走容器。
#
# 用法: bash scripts/tests/selftest-boot-img.sh [Image.gz-dtb 路径]
source "$(dirname "$0")/../lib.sh"

WORK="${WORKDIR_OVERRIDE:-$REPO_ROOT/.makeboot-selftest}"
rm -rf "$WORK"; mkdir -p "$WORK"

KERNEL_IMG="${1:-$OUT_DIR/arch/arm64/boot/Image.gz-dtb}"
require_file "$KERNEL_IMG"

log "1/4 造合成原厂 boot.img（newc cpio ramdisk + gzip 假内核 + 真实 cmdline）"
python3 - "$WORK/stock.img" <<'PY'
import gzip, hashlib, struct, sys

def newc(name, data, mode=0o100755, ino=1):
    namez = name.encode() + b"\x00"
    hdr = b"070701" + b"".join(f"{v:08x}".encode() for v in (
        ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(namez), 0))
    body = hdr + namez
    body += b"\x00" * ((4 - len(body) % 4) % 4)
    body += data
    body += b"\x00" * ((4 - len(data) % 4) % 4)
    return body

cpio = newc("init", b"#!/system/bin/sh\necho stock ramdisk\n", ino=1)
cpio += newc("init.rc", b"on early-init\n    write /proc/sys/kernel/panic 0\n", ino=2)
cpio += newc("TRAILER!!!", b"", mode=0, ino=0)

PAGE = 4096
kernel = gzip.compress(b"STOCK-KERNEL-BLOB " * 60000)
cmdline = (b"androidboot.hardware=qcom user_debug=31 msm_rtb.filter=0x37 ehci-hcd.park=3 "
           b"lpm_levels.sleep_disabled=1 service_locator.enable=1 androidboot.configfs=true "
           b"androidboot.usbcontroller=a800000.dwc3 loop.max_part=7 printk.devkmsg=on "
           b"usbcore.autosuspend=7 kpti=off androidboot.boot_devices=soc/c0c4000.sdhci")
hdr = bytearray(PAGE)
hdr[0:8] = b"ANDROID!"
struct.pack_into("<10I", hdr, 8, len(kernel), 0x00008000, len(cpio), 0x01000000,
                 0, 0, 0x00000100, PAGE, 1, 0x0c000000)
hdr[64:64 + 512] = cmdline.ljust(512, b"\x00")
hdr[576:584] = hashlib.sha1(kernel).digest()[:8]

def pad(d):
    return d + b"\x00" * ((PAGE - len(d) % PAGE) % PAGE) if len(d) % PAGE else d

open(sys.argv[1], "wb").write(bytes(hdr) + pad(kernel) + pad(cpio))
PY

log "2/4 用编译产物替换内核并重打包"
bash "$REPO_ROOT/scripts/make-boot-img.sh" \
  --stock "$WORK/stock.img" --kernel "$KERNEL_IMG" -o "$WORK/new-boot.img" \
  >"$WORK/make-boot-img.log" 2>&1 || { cat "$WORK/make-boot-img.log"; die "make-boot-img.sh 失败"; }
tail -6 "$WORK/make-boot-img.log" | sed 's/^/    /'

log "3/4 独立复核产物（不看 make-boot-img.sh 自己的结论）"
python3 - "$WORK/stock.img" "$WORK/new-boot.img" "$KERNEL_IMG" <<'PY'
import gzip, hashlib, struct, sys

stock = open(sys.argv[1], "rb").read()
new = open(sys.argv[2], "rb").read()
ours = open(sys.argv[3], "rb").read()
FDT = b"\xd0\x0d\xfe\xed"

# --- header 字段 ---
assert new[:8] == b"ANDROID!", "magic 不对"
ks, rs = struct.unpack_from("<I", new, 8)[0], struct.unpack_from("<I", new, 16)[0]
page, hdr_ver = struct.unpack_from("<I", new, 36)[0], struct.unpack_from("<I", new, 40)[0]
s_ks, s_rs = struct.unpack_from("<I", stock, 8)[0], struct.unpack_from("<I", stock, 16)[0]
assert (page, hdr_ver) == (struct.unpack_from("<I", stock, 36)[0], 1), "page/header_version 变了"
assert rs == s_rs, f"ramdisk_size 变了: {s_rs} -> {rs}"
assert ks != s_ks, "kernel_size 没变，内核没换进去"
assert new[64:64 + 200] == stock[64:64 + 200], "cmdline 前 200 字节变了"

def align(n, p):
    return ((n + p - 1) // p) * p

# --- ramdisk 必须与原厂逐字节一致 ---
ro, ro_s = page + align(ks, page), 4096 + align(s_ks, 4096)
assert hashlib.sha256(new[ro:ro + rs]).hexdigest() == hashlib.sha256(stock[ro_s:ro_s + s_rs]).hexdigest(), "ramdisk 变了"

# --- 内核载荷（magiskboot 会重压 + 重排 dtb，所以比解压后的内容与 dtb 段）---
kblob = new[page:page + ks]
i = kblob.find(FDT)
j = ours.find(FDT)
assert i != -1 and j != -1, "输出或我们的内核里找不到 FDT(dtb)"
assert kblob[i:] == ours[j:], "dtb 段与原产物不一致"
assert gzip.decompress(kblob[:i]) == gzip.decompress(ours[:j]), "内核有效载荷与原产物不一致"

assert len(new) == page + align(ks, page) + align(rs, page), "输出总大小不符合 page 对齐规则"
print(f"    独立复核通过：page={page} header_ver={hdr_ver} kernel={s_ks}->{ks} "
      f"ramdisk={rs}(逐字节一致) 内核载荷一致 dtb一致 总大小={len(new)}")
PY

log "4/4 自测通过 ✔（合成原厂镜像 → 换内核 → 产物结构/ramdisk/内核载荷 全部核对）"
