### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## 针对 Xiaomi Redmi Note 7 / 7S (lavender, sdm660, 非 A/B) 配置
## 本包只替换内核镜像（Image.gz-dtb），复用 ROM 现有 ramdisk

### AnyKernel setup
# global properties
properties() { '
kernel.string=lavender 4.19.325 + Droidspaces + ReSukiSU @KERNEL_VERSION@
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=lavender
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
# lavender 是 A-only 设备, boot 分区为 /dev/block/bootdevice/by-name/boot;
# auto 让 AK3 自行探测, 避免个别 recovery 下 by-name 路径差异
BLOCK=auto;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot; # 解包 boot.img 并保留原 ramdisk

write_boot; # 用新内核 + 原 ramdisk 回包
## end boot install
