#!/usr/bin/env bash
# Arm the phone to come back to the bootloader on its next boot.
#
# Once a kernel is being flashed rather than RAM-booted, a kernel that hangs
# is a trap: the phone retries it on every power cycle and there is no console
# to interrupt it from. Android's own answer is the Bootloader Control Block,
# a struct at the start of the `misc` partition. Writing the command
# "bootonce-bootloader" into it makes the bootloader enter fastboot exactly
# once on the next boot and then clear the flag itself.
#
# So the recovery for a wedged phone becomes: hold Power ~20s to kill it, then
# power on normally -- and it arrives in fastboot instead of rebooting into
# the broken kernel.
#
# Arm this BEFORE flashing anything, not after.
#
# Usage: duo2-force-bootloader.sh [--clear]

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

CLEAR=0
[ "${1:-}" = "--clear" ] && CLEAR=1

duo2_assert_identity

BCB="$(mktemp)"
trap 'rm -f "$BCB"' EXIT

# struct bootloader_message: command[32] status[32] recovery[768] stage[32]
# reserved[1184]. Only `command` matters here; the rest stays zeroed.
if [ "$CLEAR" -eq 1 ]; then
    info "clearing the BCB (normal boot next time)"
    head -c 2048 /dev/zero > "$BCB"
else
    info "arming BCB: bootonce-bootloader"
    python3 - "$BCB" <<'PY'
import sys
buf = bytearray(2048)
cmd = b"bootonce-bootloader"
buf[0:len(cmd)] = cmd
open(sys.argv[1], "wb").write(buf)
PY
fi

# misc is a scratch partition by design -- this is the same mechanism Android
# itself uses for "adb reboot bootloader" -- but it is still a write, so it is
# gated on the identity check above and never touches a slot.
duo2_fastboot flash misc "$BCB"

if [ "$CLEAR" -eq 1 ]; then
    info "BCB cleared; the phone will boot normally"
else
    info "armed. The next boot lands in fastboot, once."
    info "if the phone is wedged: hold Power ~20s, then power on normally."
fi
