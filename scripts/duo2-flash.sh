#!/usr/bin/env bash
# Flash a Luma boot set to the Surface Duo 2's current slot.
#
# Flashing, not RAM-booting, is the working path on this phone. `fastboot
# boot` cannot carry a vendor_boot, and under boot v3 the DTB lives there, so
# a RAM boot can only be done by repacking as legacy v1/v2 -- which the ABL
# accepts and then fails to hand off. Flashing uses the device's own v3 flow
# instead: boot_b for the kernel and ramdisk, vendor_boot_b for the DTB and
# command line, dtbo_b blanked so Microsoft's overlays are not applied on top
# of a device tree that has none of their target nodes.
#
# Writes only the slot the phone is already on, and never the partitions that
# hold the radio identity.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

OUT="${LUMA_DUO2_OUT:-$LUMA_DUO2_ROOT/build}"

# Never written, under any circumstances. modemst1/modemst2 hold the phone's
# IMEI; fsg/fsc and persist hold calibration this port cannot regenerate.
FORBIDDEN="modemst1 modemst2 fsg fsc persist vbmeta vbmeta_a vbmeta_b"

duo2_assert_identity
SLOT="$(duo2_current_slot)"
[ -n "$SLOT" ] || die "could not read current-slot from the device"
info "flashing slot '$SLOT' only; slot other than '$SLOT' is not touched"

for p in $FORBIDDEN; do
    case " ${*:-} " in *" $p "*) die "refusing to write $p" ;; esac
done

BOOT="$OUT/boot.img"
VENDOR_BOOT="$OUT/vendor_boot.img"
DTBO_BLANK="$OUT/dtbo-blank.img"

[ -f "$BOOT" ] || die "no $BOOT -- run duo2-mkboot.sh"
[ -f "$VENDOR_BOOT" ] || die "no $VENDOR_BOOT -- run duo2-mkboot.sh"

# dtbo blanked to the real partition size, as boot.toml's dtbo.policy says.
if [ ! -f "$DTBO_BLANK" ]; then
    info "creating blank dtbo (25165824 bytes)"
    head -c 25165824 /dev/zero > "$DTBO_BLANK"
fi

info "boot_$SLOT        <- $(basename "$BOOT") ($(stat -c%s "$BOOT") bytes)"
duo2_fastboot flash "boot_$SLOT" "$BOOT"

info "vendor_boot_$SLOT <- $(basename "$VENDOR_BOOT") ($(stat -c%s "$VENDOR_BOOT") bytes)"
duo2_fastboot flash "vendor_boot_$SLOT" "$VENDOR_BOOT"

info "dtbo_$SLOT        <- blank"
duo2_fastboot flash "dtbo_$SLOT" "$DTBO_BLANK"

info "flashed. Start the collector, then reboot:"
printf '    %s/scripts/duo2-logd.sh &\n' "$LUMA_DUO2_ROOT"
printf '    fastboot -s <serial> reboot\n'
