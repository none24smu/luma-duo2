#!/usr/bin/env bash
# Build Duo 2 boot and vendor_boot images by repacking the stock ones.
#
# Earlier versions of this script hand-wrote mkbootimg invocations and got the
# header version, the kernel compression and the DTB placement wrong in turn,
# because each of those is a property of what this particular bootloader
# accepts and none of them is discoverable from the outside.
#
# This follows the method Luma already uses for its other phones
# (scripts/mobile/prepare-fp6-*-boot-candidate.sh): unpack the stock image
# with `--format=mkbootimg`, which recovers the exact argument list that
# produced it, prove that rebuilding from those arguments reproduces the stock
# image byte for byte, and only then substitute the pieces being changed.
# Every field we are not deliberately changing -- header version, page size,
# load offsets, os_version, os_patch_level, board name -- is then correct by
# construction rather than by guesswork.
#
# The round-trip check is the whole point. If it ever fails, the arguments are
# not a faithful description of the stock image and nothing built from them
# should be trusted, so the script stops.
#
# Usage: duo2-mkboot.sh [--vendor [--stock-kernel]]
#   default         mainline kernel + mainline DTB
#   --vendor        Microsoft's msm-5.4 kernel (duo2-build-vendor.sh) + the
#                   stock DTBs patched for a USB console (duo2-mkdtb-usb.sh)
#   --stock-kernel  as --vendor, but keep the kernel binary from stock boot_b.
#                   Same source and compiler as our build, so it separates
#                   "our kernel build is wrong" from "everything around it is".

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

KBUILD="${LUMA_DUO2_KBUILD:-$LUMA_DUO2_ROOT/../build/duo2-kernel}"
OUT="${LUMA_DUO2_OUT:-$LUMA_DUO2_ROOT/build}"
STOCK="${LUMA_DUO2_STOCK:-$LUMA_DUO2_ROOT/../SD2Firmware}"
MKBOOTIMG="${LUMA_DUO2_MKBOOTIMG:-$LUMA_DUO2_ROOT/../tools/mkbootimg/mkbootimg.py}"
UNPACK="${LUMA_DUO2_UNPACK:-$LUMA_DUO2_ROOT/../tools/mkbootimg/unpack_bootimg.py}"
AVBTOOL="${LUMA_DUO2_AVBTOOL:-$LUMA_DUO2_ROOT/../tools/avb/avbtool.py}"

# Real partition sizes, read from the device with `fastboot getvar`.
BOOT_PART_SIZE=134217728
VENDOR_BOOT_PART_SIZE=100663296

STOCK_BOOT="$STOCK/boot_b.img"
STOCK_VENDOR_BOOT="$STOCK/vendor_boot_b.img"

VENDOR=0 STOCK_KERNEL=0
[ "${1:-}" = "--vendor" ] && VENDOR=1
[ "$VENDOR" -eq 1 ] && [ "${2:-}" = "--stock-kernel" ] && STOCK_KERNEL=1

RAMDISK="$OUT/initramfs.cpio.gz"
if [ "$VENDOR" -eq 1 ]; then
    VTREE="${LUMA_DUO2_VENDOR_TREE:-$LUMA_DUO2_ROOT/../reference/msm-5.4}"
    KERNEL="$VTREE/out/target/product/duo2/obj/kernel/msm-5.4/arch/arm64/boot/Image"
    DTB="$OUT/duo2-usb.dtb"                 # stock DTBs, USB forced to device
else
    KERNEL="$KBUILD/arch/arm64/boot/Image"  # raw, not Image.gz: stock is raw
    DTB="$OUT/duo2-qcom.dtb"                # mainline DTB + qcom,msm-id
fi

# Appended to the stock vendor command line. console=ttyGS0 makes the USB
# gadget the kernel console. The rest only matter for Microsoft's kernel, and
# they are what makes every crash come back to fastboot instead of hanging:
# a panic (or a watchdog bark, which becomes one) writes the "bootloader"
# reboot reason, and download mode is off so the reset does not stop in
# Qualcomm's crash-dump mode first.
EXTRA_CMDLINE="console=ttyGS0,115200n8"
[ "$VENDOR" -eq 1 ] && EXTRA_CMDLINE="$EXTRA_CMDLINE \
qcom_reboot_reason.panic_reason=bootloader \
qcom_dload_mode.download_mode=0 msm_poweroff.download_mode=0"
EXTRA_CMDLINE="$(printf '%s' "$EXTRA_CMDLINE" | tr -s ' \\\n' ' ')"

for f in "$STOCK_BOOT" "$STOCK_VENDOR_BOOT" "$KERNEL" "$RAMDISK" "$DTB"; do
    [ -f "$f" ] || die "missing input: $f"
done
mkdir -p "$OUT"
WORK="$OUT/repack"; rm -rf "$WORK"; mkdir -p "$WORK"

# Stock images carry an AVB footer and are padded to the full partition, so
# the image proper is only the first N bytes. avbtool reports where it ends.
original_size() {
    python3 "$AVBTOOL" info_image --image "$1" 2>/dev/null \
        | sed -n 's/^Original image size: *\([0-9]*\) bytes/\1/p' | head -1
}

# Rebuild from a recovered argument list. boot images are written with
# --output, vendor_boot images with --vendor_boot.
rebuild() {
    local args_file=$1 out_flag=$2 output=$3
    python3 - "$args_file" "$out_flag" "$output" "$MKBOOTIMG" <<'PY'
import os, subprocess, sys
args_file, out_flag, output, mkbootimg = sys.argv[1:5]
args = open(args_file, "rb").read().split(b"\0")
if args and args[-1] == b"":
    args.pop()
subprocess.run(["python3", mkbootimg, out_flag, output,
                *(os.fsdecode(a) for a in args)], check=True)
PY
}

# Unpack stock, prove the round trip, then swap components and rebuild.
repack() {
    local name=$1 stock=$2 out_flag=$3 candidate=$4; shift 4
    local dir="$WORK/$name"; mkdir -p "$dir/base"
    local orig; orig="$(original_size "$stock")"
    [ -n "$orig" ] || die "$name: no AVB footer on $stock, cannot find image size"

    head -c "$orig" "$stock" > "$dir/stock.img"
    python3 "$UNPACK" --boot_img "$dir/stock.img" --out "$dir/base" \
        --format=mkbootimg -0 > "$dir/args0" 2>/dev/null

    rebuild "$dir/args0" "$out_flag" "$dir/roundtrip.img"
    cmp -s "$dir/stock.img" "$dir/roundtrip.img" \
        || die "$name: round-trip is not byte-identical to stock; the recovered
mkbootimg arguments do not faithfully describe it, so a candidate built from
them cannot be trusted"
    info "$name: round-trip byte-identical to stock ($orig bytes)"

    # Component substitutions, given as src:dstname pairs.
    local pair src dst
    for pair in "$@"; do
        src="${pair%%:*}"; dst="${pair##*:}"
        [ -f "$dir/base/$dst" ] || die "$name: stock image has no '$dst' to replace"
        install -m 0644 "$src" "$dir/base/$dst"
        info "$name: replaced $dst with $(basename "$src") ($(stat -c%s "$src") bytes)"
    done

    rebuild "$dir/args0" "$out_flag" "$candidate"
}

# --- boot: swap the kernel and the ramdisk --------------------------------
BOOT_SWAPS=("$RAMDISK:ramdisk")
[ "$STOCK_KERNEL" -eq 1 ] || BOOT_SWAPS+=("$KERNEL:kernel")
[ "$STOCK_KERNEL" -eq 1 ] && info "boot: keeping the stock kernel"
repack boot "$STOCK_BOOT" --output "$OUT/boot.img" "${BOOT_SWAPS[@]}"

# --- vendor_boot: swap the DTB, and add our console to the command line ---
# The stock command line is kept verbatim and ttyGS0 appended, rather than
# rewritten. Linux accepts several console= arguments, and leaving the stock
# ones in place keeps this image as close to the known-good one as possible.
#
# The stock vendor ramdisk is Android's first stage, including its own /init.
# Ramdisks are unpacked vendor first and boot second, but a later archive
# only replaces files it contains, and Android's first-stage pieces would
# still be there around ours. For the vendor kernel it is replaced with an
# empty archive so the boot ramdisk is the whole root filesystem.
VB_SWAPS=("$DTB:dtb")
if [ "$VENDOR" -eq 1 ]; then
    EMPTY_LIST="$(mktemp)"; : > "$EMPTY_LIST"
    "$OUT/host/gen_init_cpio" "$EMPTY_LIST" | gzip -9 > "$OUT/vendor_ramdisk-empty.cpio.gz"
    rm -f "$EMPTY_LIST"
    VB_SWAPS+=("$OUT/vendor_ramdisk-empty.cpio.gz:vendor_ramdisk")
fi
repack vendor_boot "$STOCK_VENDOR_BOOT" --vendor_boot "$OUT/vendor_boot.img" \
    "${VB_SWAPS[@]}"

info "appending to the vendor command line: $EXTRA_CMDLINE"
python3 - "$WORK/vendor_boot/args0" "$EXTRA_CMDLINE" <<'PY'
import os, sys
p = sys.argv[1]
args = open(p, "rb").read().split(b"\0")
for i, a in enumerate(args):
    if a == b"--vendor_cmdline":
        args[i+1] = args[i+1] + b" " + os.fsencode(sys.argv[2])
        break
open(p, "wb").write(b"\0".join(args))
PY
rebuild "$WORK/vendor_boot/args0" --vendor_boot "$OUT/vendor_boot.img"

# --- AVB footers, padded to the exact partition size ----------------------
# Stock boot, vendor_boot and dtbo all carry an unsigned footer (Algorithm
# NONE). Luma's own Pixel 9 diagnostic requires a candidate to equal the stock
# partition size exactly and to end in an AVBf footer, so both are enforced.
info "adding unsigned AVB hash footers"
python3 "$AVBTOOL" add_hash_footer --image "$OUT/boot.img" \
    --partition_name boot --partition_size "$BOOT_PART_SIZE" --algorithm NONE
python3 "$AVBTOOL" add_hash_footer --image "$OUT/vendor_boot.img" \
    --partition_name vendor_boot --partition_size "$VENDOR_BOOT_PART_SIZE" --algorithm NONE

for f in "$OUT/boot.img" "$OUT/vendor_boot.img"; do
    [ "$(tail -c 64 "$f" | head -c 4)" = "AVBf" ] || die "$f has no AVBf footer"
done
info "built:"
printf '    %-18s %10s bytes (partition %s)\n' \
    boot.img "$(stat -c%s "$OUT/boot.img")" "$BOOT_PART_SIZE" \
    vendor_boot.img "$(stat -c%s "$OUT/vendor_boot.img")" "$VENDOR_BOOT_PART_SIZE"
