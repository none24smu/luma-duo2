#!/usr/bin/env bash
# Build Microsoft's Surface Duo 2 kernel (msm-5.4, lahaina QGKI) with the
# bring-up patches in kernel/patches/msm-5.4/.
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

for p in "$PATCHES"/*.patch; do
    name="$(basename "$p")"
    if git -C "$KSRC" apply --check -R "$p" 2>/dev/null; then
        info "already applied: $name"
    elif git -C "$KSRC" apply --check "$p" 2>/dev/null; then
        info "applying: $name"
        git -C "$KSRC" apply "$p"
    else
        die "$name neither applies nor is already applied"
    fi
done

export KBUILD_BUILD_USER=luma KBUILD_BUILD_HOST=duo2-bringup
info "building lahaina-qgki_defconfig (incremental)"
( cd "$TREE" && ./device_build/kernel/kernel-build.sh \
    -c lahaina-qgki_defconfig -p "$TREE" -ib )

[ -f "$IMAGE" ] || die "build finished but $IMAGE is missing"
printf '    %s  %s bytes\n' "$IMAGE" "$(stat -c%s "$IMAGE")"
