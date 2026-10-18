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

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

KBUILD="${LUMA_DUO2_KBUILD:-$HOME/LumaOS/build/duo2-kernel}"
OUT="${LUMA_DUO2_OUT:-$LUMA_DUO2_ROOT/build}"
STOCK="${LUMA_DUO2_STOCK:-$HOME/LumaOS/SD2Firmware}"
MKBOOTIMG="${LUMA_DUO2_MKBOOTIMG:-$HOME/LumaOS/tools/mkbootimg/mkbootimg.py}"
UNPACK="${LUMA_DUO2_UNPACK:-$HOME/LumaOS/tools/mkbootimg/unpack_bootimg.py}"
AVBTOOL="${LUMA_DUO2_AVBTOOL:-$HOME/LumaOS/tools/avb/avbtool.py}"

# Real partition sizes, read from the device with `fastboot getvar`.
BOOT_PART_SIZE=134217728
VENDOR_BOOT_PART_SIZE=100663296

STOCK_BOOT="$STOCK/boot_b.img"
STOCK_VENDOR_BOOT="$STOCK/vendor_boot_b.img"

KERNEL="$KBUILD/arch/arm64/boot/Image"      # raw, not Image.gz: stock is raw
RAMDISK="$OUT/initramfs.cpio.gz"
DTB="$OUT/duo2-qcom.dtb"                    # mainline DTB + qcom,msm-id

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
repack boot "$STOCK_BOOT" --output "$OUT/boot.img" \
    "$KERNEL:kernel" "$RAMDISK:ramdisk"

# --- vendor_boot: swap the DTB, and add our console to the command line ---
# The stock command line is kept verbatim and ttyGS0 appended, rather than
# rewritten. Linux accepts several console= arguments, and leaving the stock
# ones in place keeps this image as close to the known-good one as possible.
repack vendor_boot "$STOCK_VENDOR_BOOT" --vendor_boot "$OUT/vendor_boot.img" \
    "$DTB:dtb"

info "appending console=ttyGS0 to the vendor command line"
python3 - "$WORK/vendor_boot/args0" <<'PY'
import sys
p = sys.argv[1]
args = open(p, "rb").read().split(b"\0")
for i, a in enumerate(args):
    if a == b"--vendor_cmdline":
        args[i+1] = args[i+1] + b" console=ttyGS0,115200n8"
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
