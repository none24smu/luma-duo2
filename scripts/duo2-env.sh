#!/usr/bin/env bash
# Shared configuration and safety guards for Surface Duo 2 bring-up.
#
# Every other script sources this. It exists for one reason above all: this
# workstation has more than one phone attached, and a stray fastboot command
# that picks "the first device" can write to the wrong one. Nothing here ever
# runs fastboot without an explicit -s serial.

LUMA_DUO2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The serial identifies one physical handset, so it stays out of git. Create
# .duo2.local at the repo root containing:  DUO2_SERIAL=XXXXXXXXXXXX
DUO2_LOCAL_CONFIG="$LUMA_DUO2_ROOT/.duo2.local"

# Guard values. A write is refused unless the target reports this product.
DUO2_EXPECTED_PRODUCT="surfaceduo2"

# USB IDs. Fastboot is Microsoft's; the gadget IDs are whatever the kernel's
# g_serial defaults to until we set our own in the Luma gadget config.
DUO2_FASTBOOT_USB_ID="045e:0c2f"
DUO2_GADGET_USB_ID="${DUO2_GADGET_USB_ID:-0525:a4a7}"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

duo2_load_config() {
    if [ -n "${DUO2_SERIAL:-}" ]; then
        return 0
    fi
    [ -f "$DUO2_LOCAL_CONFIG" ] || die \
"no device serial configured.

Create $DUO2_LOCAL_CONFIG with the Duo 2's serial:

    DUO2_SERIAL=XXXXXXXXXXXX

Find it with 'fastboot devices' while only the Duo 2 is attached, or match the
entry whose USB ID is $DUO2_FASTBOOT_USB_ID. This file is gitignored; the
serial must never be committed."
    # shellcheck disable=SC1090
    . "$DUO2_LOCAL_CONFIG"
    [ -n "${DUO2_SERIAL:-}" ] || die "DUO2_SERIAL is not set in $DUO2_LOCAL_CONFIG"
}

# fastboot, always pinned to our serial. Use this and never bare fastboot.
duo2_fastboot() {
    duo2_load_config
    fastboot -s "$DUO2_SERIAL" "$@"
}

duo2_require_fastboot() {
    duo2_load_config
    fastboot devices | awk '{print $1}' | grep -qx "$DUO2_SERIAL" || die \
"the Duo 2 ($DUO2_SERIAL) is not in fastboot.

Attached right now:
$(fastboot devices | sed 's/^/    /')

Power the phone off, then hold Volume Down and press Power until the bootloader
screen appears, and plug it in."
}

# Refuse to continue unless the pinned serial really is the Duo 2. Cheap, and
# it is the last thing standing between a typo and the wrong phone.
duo2_assert_identity() {
    duo2_require_fastboot
    local product
    product="$(duo2_fastboot getvar product 2>&1 | head -1 | sed 's/^product: *//')"
    [ "$product" = "$DUO2_EXPECTED_PRODUCT" ] || die \
"refusing to continue: serial $DUO2_SERIAL reports product '$product', expected '$DUO2_EXPECTED_PRODUCT'.

That is a different phone. Check DUO2_SERIAL in $DUO2_LOCAL_CONFIG."
}

# The slot we work on. Read from the device rather than assumed: this port
# targets whichever slot the phone is already on, and never switches slots.
duo2_current_slot() {
    duo2_fastboot getvar current-slot 2>&1 | head -1 | sed 's/^current-slot: *//'
}
