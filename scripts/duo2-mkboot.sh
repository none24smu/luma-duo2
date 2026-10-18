#!/usr/bin/env bash
# Assemble Android boot v3 + vendor_boot v3 images for the Surface Duo 2.
#
# The Duo 2 is boot header v3, verified against the device rather than only
# against a firmware dump (see docs/hardware.md). Under v3 the boot image
# carries nothing but a kernel and a ramdisk: the DTB and the real command
# line both live in vendor_boot. So a usable test image is always a pair, and
# building only a boot image silently leaves Microsoft's Android device tree
# in play.
#
# Usage: duo2-mkboot.sh [-k KERNEL_BUILD_DIR] [-o OUT_DIR]

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

KBUILD="${LUMA_DUO2_KBUILD:-$HOME/LumaOS/build/duo2-kernel}"
OUT="${LUMA_DUO2_OUT:-$LUMA_DUO2_ROOT/build}"
MKBOOTIMG="${LUMA_DUO2_MKBOOTIMG:-$HOME/LumaOS/tools/mkbootimg/mkbootimg.py}"

while getopts ":k:o:h" opt; do
    case "$opt" in
        k) KBUILD="$OPTARG" ;;
        o) OUT="$OPTARG" ;;
        h) sed -n '2,14p' "$0"; exit 0 ;;
        *) die "unknown option -$OPTARG" ;;
    esac
done

KERNEL="$KBUILD/arch/arm64/boot/Image.gz"
DTB="$KBUILD/arch/arm64/boot/dts/qcom/sm8350-microsoft-surface-duo2.dtb"

[ -f "$KERNEL" ] || die "no kernel at $KERNEL -- build it first"
[ -f "$DTB" ]    || die "no DTB at $DTB -- build it first"
[ -f "$MKBOOTIMG" ] || die "no mkbootimg at $MKBOOTIMG"

mkdir -p "$OUT"

# --- Load offsets, read from the stock vendor_boot header -----------------
PAGESIZE=4096
BASE=0x00000000
KERNEL_OFFSET=0x00008000
RAMDISK_OFFSET=0x01000000
TAGS_OFFSET=0x00000100
DTB_OFFSET=0x01f00000

# Matched to the stock image so the bootloader sees nothing unexpected.
OS_VERSION=11.0.0
OS_PATCH_LEVEL=2024-10

# --- Command line ---------------------------------------------------------
# Kept in the vendor cmdline, where the stock image also keeps it. The
# bootloader concatenates the boot and vendor_boot command lines, so putting
# console= in both would register the same console twice.
#
# No earlycon: with no debug-UART cable there is nothing to read it on, and
# pointing it at an unclocked UART is a way to hang before the real console
# exists. ttyGS0 is the CDC-ACM gadget; see docs/usb-logging.md.
VENDOR_CMDLINE="console=ttyGS0,115200n8 printk.devkmsg=on rootwait"

# --- Ramdisks -------------------------------------------------------------
# The bring-up initramfs, if one was staged. vendor_boot v3 requires a vendor
# ramdisk entry, so an empty cpio is supplied when there is nothing to put in
# it.
BOOT_RAMDISK="$OUT/initramfs.cpio.gz"
[ -f "$BOOT_RAMDISK" ] || die "no initramfs at $BOOT_RAMDISK -- run duo2-mkinitramfs.sh first"

EMPTY_RAMDISK="$OUT/vendor_ramdisk.empty.cpio.gz"
: | cpio -o -H newc 2>/dev/null | gzip -9 > "$EMPTY_RAMDISK"

# --- boot.img (v3): kernel + ramdisk, nothing else ------------------------
info "building boot.img (header v3)"
python3 "$MKBOOTIMG" \
    --header_version 3 \
    --kernel "$KERNEL" \
    --ramdisk "$BOOT_RAMDISK" \
    --os_version "$OS_VERSION" \
    --os_patch_level "$OS_PATCH_LEVEL" \
    -o "$OUT/boot.img"

# --- vendor_boot.img (v3): DTB + cmdline + vendor ramdisk -----------------
info "building vendor_boot.img (header v3)"
python3 "$MKBOOTIMG" \
    --header_version 3 \
    --vendor_boot "$OUT/vendor_boot.img" \
    --vendor_ramdisk "$EMPTY_RAMDISK" \
    --dtb "$DTB" \
    --vendor_cmdline "$VENDOR_CMDLINE" \
    --pagesize "$PAGESIZE" \
    --base "$BASE" \
    --kernel_offset "$KERNEL_OFFSET" \
    --ramdisk_offset "$RAMDISK_OFFSET" \
    --tags_offset "$TAGS_OFFSET" \
    --dtb_offset "$DTB_OFFSET"

# --- Size check against the real partitions -------------------------------
# boot_b is 128 MiB and vendor_boot_b is 96 MiB on this device. RAM-booting
# does not care, but flashing would, and an oversized image is worth catching
# here rather than at the point of writing to the phone.
check_size() {
    local f="$1" limit="$2" name="$3" sz
    sz="$(stat -c%s "$f")"
    printf '    %-20s %10s bytes  (partition %s)\n' "$name" "$sz" "$limit"
    [ "$sz" -le "$limit" ] || die "$name is larger than the $name partition"
}
info "built:"
check_size "$OUT/boot.img" 134217728 boot.img
check_size "$OUT/vendor_boot.img" 100663296 vendor_boot.img

info "RAM-boot them with:"
printf '    %s/scripts/duo2-ramboot.sh %s %s\n' \
    "$LUMA_DUO2_ROOT" "$OUT/boot.img" "$OUT/vendor_boot.img"
