#!/usr/bin/env bash
# Boot a kernel on the Duo 2 out of RAM, writing nothing to flash.
#
# This is the iteration loop for the whole port. 'fastboot boot' loads the
# image into memory and jumps to it, so a kernel that hangs or panics is gone
# the moment the phone is power-cycled, and the boot partition is never at
# risk. Flashing is for images that have already booted this way.
#
# Usage: duo2-ramboot.sh <boot.img> [vendor_boot.img]
#
# The Duo 2 uses Android boot header v3, where the DTB lives in vendor_boot
# rather than in the boot image, so most useful invocations pass both.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

BOOT_IMG="${1:-}"
VENDOR_BOOT_IMG="${2:-}"

[ -n "$BOOT_IMG" ] || die "usage: $(basename "$0") <boot.img> [vendor_boot.img]"
[ -f "$BOOT_IMG" ] || die "no such file: $BOOT_IMG"
[ -z "$VENDOR_BOOT_IMG" ] || [ -f "$VENDOR_BOOT_IMG" ] || die "no such file: $VENDOR_BOOT_IMG"

# Confirm the target is the Duo 2 before anything is sent to it.
duo2_assert_identity
info "target: $DUO2_EXPECTED_PRODUCT on slot $(duo2_current_slot) (nothing will be written)"

printf '%s\n' "$BOOT_IMG" "${VENDOR_BOOT_IMG:-}" | while read -r f; do
    [ -n "$f" ] && printf '    %-40s %s bytes\n' "$(basename "$f")" "$(stat -c%s "$f")"
done

info "start the console reader first if it is not already running:"
printf '    %s/scripts/duo2-console.sh\n\n' "$LUMA_DUO2_ROOT"

if [ -n "$VENDOR_BOOT_IMG" ]; then
    info "fastboot boot <boot> <vendor_boot>"
    duo2_fastboot boot "$BOOT_IMG" "$VENDOR_BOOT_IMG"
else
    warn "no vendor_boot given: the phone will use whatever DTB is already in"
    warn "its vendor_boot partition, which is Microsoft's Android device tree."
    info "fastboot boot <boot>"
    duo2_fastboot boot "$BOOT_IMG"
fi

info "image handed to the bootloader; watch the console for output"
