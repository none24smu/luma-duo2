#!/usr/bin/env bash
# Return the Duo 2 to its bootloader, from whatever state it is in.
#
# This is the other half of the bring-up loop. A RAM-booted kernel that hangs
# has to be recoverable without touching flash, and the recovery has to be
# unambiguous about which phone it acts on.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

duo2_load_config

# Already sitting in fastboot: nothing to do.
if fastboot devices | awk '{print $1}' | grep -qx "$DUO2_SERIAL"; then
    info "the Duo 2 is already in fastboot"
    duo2_assert_identity
    info "current slot: $(duo2_current_slot)"
    exit 0
fi

# Booted far enough to give us a console? Then ask the bring-up init, which
# reboots with the "bootloader" reason. This is the hands-off path.
if port="$(
    for tty in /dev/ttyACM*; do
        [ -e "$tty" ] || continue
        vid="$(udevadm info -q property -n "$tty" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')"
        pid="$(udevadm info -q property -n "$tty" 2>/dev/null | sed -n 's/^ID_MODEL_ID=//p')"
        [ "$vid:$pid" = "$DUO2_GADGET_USB_ID" ] && { printf '%s' "$tty"; break; }
    done
    )" && [ -n "$port" ]; then
    info "console on $port: sending 'bootloader'"
    stty -F "$port" 115200 raw -echo 2>/dev/null || true
    # Leading CR/LF flushes any stray bytes already in the init's line buffer.
    printf '\r\nbootloader\r\n' > "$port"
    for _ in $(seq 60); do
        if fastboot devices | awk '{print $1}' | grep -qx "$DUO2_SERIAL"; then
            info "the Duo 2 is back in fastboot"
            duo2_assert_identity
            info "current slot: $(duo2_current_slot)"
            exit 0
        fi
        sleep 1
    done
    warn "sent 'bootloader' but the phone did not reach fastboot within 60 s"
fi

cat <<'MSG'

Hardware route back to the bootloader:

No console to ask. The bring-up images also return to fastboot on their own
(after duo2.idle seconds, or on a panic), so waiting is the first option.
If the kernel hung before any of that could run:

  1. Hold Power for about 20 seconds until the screens go dark. On a hung
     kernel this is the only thing that works; the Duo 2 has no reset pin.
  2. Release, then hold Volume Down and tap Power.
  3. Keep Volume Down held until the bootloader screen appears.

Nothing was flashed, so a RAM-booted kernel is already gone: the phone comes
back on whatever is in its boot partition.
MSG

info "waiting for the Duo 2 to reappear in fastboot (Ctrl-C to stop) ..."
while ! fastboot devices | awk '{print $1}' | grep -qx "$DUO2_SERIAL"; do
    sleep 2
done
info "the Duo 2 is back in fastboot"
duo2_assert_identity
info "current slot: $(duo2_current_slot)"
