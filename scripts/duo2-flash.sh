#!/usr/bin/env bash
# Flash a Luma boot set to the Surface Duo 2's current slot.
#
# Flashing, not RAM-booting, is the working path on this phone. `fastboot
# boot` cannot carry a vendor_boot, and under boot v3 the DTB lives there, so
# a RAM boot can only be done by repacking as legacy v1/v2 -- which the ABL
# accepts and then fails to hand off. Flashing uses the device's own v3 flow
# instead: boot_b for the kernel and ramdisk, vendor_boot_b for the DTB and
# command line, and dtbo_b chosen to match the kernel:
#
#   (default)      blank: Microsoft's overlays target nodes that the mainline
#                  device tree does not have.
#   --stock-dtbo   Microsoft's own dtbo_b, for Microsoft's kernel. The base
#                  DTB in vendor_boot is only the SoC; the PMIC power-on and
#                  reboot-reason nodes, the board regulators and the Duo's
#                  own hardware all live in the overlay. Without it the
#                  kernel cannot even record a reboot reason, so "reboot to
#                  bootloader" -- and with it every hands-off recovery path --
#                  silently becomes a plain reboot.
#
# Writes only the slot the phone is already on, and never the partitions that
# hold the radio identity.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

OUT="${LUMA_DUO2_OUT:-$LUMA_DUO2_ROOT/build}"
STOCK="${LUMA_DUO2_STOCK:-$LUMA_DUO2_ROOT/../SD2Firmware}"

STOCK_DTBO=0
if [ "${1:-}" = "--stock-dtbo" ]; then STOCK_DTBO=1; shift; fi

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
if [ "$STOCK_DTBO" -eq 0 ] && [ ! -f "$DTBO_BLANK" ]; then
    info "creating blank dtbo (25165824 bytes)"
    head -c 25165824 /dev/zero > "$DTBO_BLANK"
fi

info "boot_$SLOT        <- $(basename "$BOOT") ($(stat -c%s "$BOOT") bytes)"
duo2_fastboot flash "boot_$SLOT" "$BOOT"

info "vendor_boot_$SLOT <- $(basename "$VENDOR_BOOT") ($(stat -c%s "$VENDOR_BOOT") bytes)"
duo2_fastboot flash "vendor_boot_$SLOT" "$VENDOR_BOOT"

if [ "$STOCK_DTBO" -eq 1 ]; then
    [ -f "$STOCK/dtbo_$SLOT.img" ] || die "no $STOCK/dtbo_$SLOT.img"
    info "dtbo_$SLOT        <- stock dtbo_$SLOT.img"
    duo2_fastboot flash "dtbo_$SLOT" "$STOCK/dtbo_$SLOT.img"
else
    info "dtbo_$SLOT        <- blank"
    duo2_fastboot flash "dtbo_$SLOT" "$DTBO_BLANK"
fi

info "flashed. Start the collector, then reboot:"
printf '    %s/scripts/duo2-logd.sh &\n' "$LUMA_DUO2_ROOT"
printf '    fastboot -s <serial> reboot\n'
