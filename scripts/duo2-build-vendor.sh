#!/usr/bin/env bash
# Build Microsoft's Surface Duo 2 kernel (msm-5.4, lahaina QGKI) with the
# bring-up patches in kernel/patches/msm-5.4/, applied in order.
#
# This is the first-console kernel: Microsoft's own tree is known to reach
# userspace on this bootloader, so the USB console is proved here before the
# mainline port has to carry it.
#
# Microsoft's kernel-build.sh does the actual work with the prebuilt clang it
# ships; this wrapper only applies our patches (idempotently) and keeps the
# build identity neutral, since the user and host otherwise end up in
# /proc/version and from there in every boot log we record.
#
# Usage: duo2-build-vendor.sh

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

TREE="${LUMA_DUO2_VENDOR_TREE:-$LUMA_DUO2_ROOT/../reference/msm-5.4}"
KSRC="$TREE/kernel/msm-5.4"
PATCHES="$LUMA_DUO2_ROOT/kernel/patches/msm-5.4"
IMAGE="$TREE/out/target/product/duo2/obj/kernel/msm-5.4/arch/arm64/boot/Image"

[ -d "$KSRC/.git" ] || die "no msm-5.4 git tree at $KSRC"

# Restore every file the patches touch to Microsoft's version, then apply the
# whole series in order. Checking each patch for "already applied" on its own
# breaks as soon as two patches touch the same file.
mapfile -t touched < <(for p in "$PATCHES"/*.patch; do
    git -C "$KSRC" apply --numstat "$p" | cut -f3; done | sort -u)
# Restore each file from whichever repository owns it: techpack/display is a
# separate git repository inside the kernel tree.
for f in "${touched[@]}"; do
    git -C "$KSRC/$(dirname "$f")" checkout -- "$(basename "$f")"
done
for p in "$PATCHES"/*.patch; do
    info "applying: $(basename "$p")"
    git -C "$KSRC" apply "$p" || die "$(basename "$p") does not apply"
done

export KBUILD_BUILD_USER=luma KBUILD_BUILD_HOST=duo2-bringup
info "building lahaina-qgki_defconfig (incremental)"
( cd "$TREE" && ./device_build/kernel/kernel-build.sh \
    -c lahaina-qgki_defconfig -p "$TREE" -ib )

[ -f "$IMAGE" ] || die "build finished but $IMAGE is missing"
printf '    %s  %s bytes\n' "$IMAGE" "$(stat -c%s "$IMAGE")"
