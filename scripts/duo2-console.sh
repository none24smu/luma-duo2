#!/usr/bin/env bash
# Stream the Duo 2's kernel console over USB CDC-ACM and record it.
#
# The phone has no debug UART cable, so the only console we get is the CDC-ACM
# gadget the kernel raises once dwc3 is up. Nothing is visible before that, so
# this script waits for the port to appear rather than failing when it is not
# there yet: start it first, then RAM-boot the phone, and catch the log from
# the moment the gadget enumerates.
#
# Usage: duo2-console.sh [-t SECONDS] [-d /dev/ttyACMn]
#   -t  how long to wait for the port to appear (default 120, 0 waits forever)
#   -d  skip autodetection and use this port

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

BAUD=115200
TIMEOUT=120
FORCED_PORT=""

while getopts ":t:d:h" opt; do
    case "$opt" in
        t) TIMEOUT="$OPTARG" ;;
        d) FORCED_PORT="$OPTARG" ;;
        h) sed -n '2,12p' "$0"; exit 0 ;;
        *) die "unknown option -$OPTARG" ;;
    esac
done

# Find the ACM port that belongs to our gadget. Other phones on this machine
# can also present CDC-ACM, so match on USB vendor:product and never just
# grab the lowest-numbered port.
find_acm_port() {
    local want_vid want_pid tty vid pid
    want_vid="${DUO2_GADGET_USB_ID%%:*}"
    want_pid="${DUO2_GADGET_USB_ID##*:}"
    for tty in /dev/ttyACM*; do
        [ -e "$tty" ] || continue
        vid="$(udevadm info -q property -n "$tty" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')"
        pid="$(udevadm info -q property -n "$tty" 2>/dev/null | sed -n 's/^ID_MODEL_ID=//p')"
        if [ "$vid" = "$want_vid" ] && [ "$pid" = "$want_pid" ]; then
            printf '%s\n' "$tty"
            return 0
        fi
    done
    return 1
}

wait_for_port() {
    local waited=0 port
    while true; do
        if port="$(find_acm_port)"; then
            printf '%s\n' "$port"
            return 0
        fi
        if [ "$TIMEOUT" -ne 0 ] && [ "$waited" -ge "$TIMEOUT" ]; then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
        if [ $((waited % 10)) -eq 0 ]; then
            info "still waiting for the console gadget ($DUO2_GADGET_USB_ID), ${waited}s" >&2
        fi
    done
}

if [ -n "$FORCED_PORT" ]; then
    PORT="$FORCED_PORT"
    [ -e "$PORT" ] || die "$PORT does not exist"
else
    info "waiting for the Duo 2 console gadget ($DUO2_GADGET_USB_ID) ..."
    PORT="$(wait_for_port)" || die \
"no CDC-ACM console appeared within ${TIMEOUT}s.

The kernel either did not reach USB gadget setup or panicked before it. With no
debug-UART cable there is nothing to read directly, so the next move is to pull
the previous boot's log out of pstore/ramoops after returning to the bootloader,
rather than guessing. See docs/usb-logging.md."
fi

mkdir -p "$LUMA_DUO2_ROOT/logs"
LOGFILE="$LUMA_DUO2_ROOT/logs/console-$(date -u +%Y%m%dT%H%M%SZ).log"

info "console on $PORT at ${BAUD} baud"
info "recording to $LOGFILE"
info "press Ctrl-t then q to quit (tio)"

# tio auto-reconnects by default, and the gadget drops on every reboot, so a
# single invocation survives a whole flash-boot-read cycle. Timestamps are on
# because the interesting question during bring-up is almost always "how long
# until it died", not just "what did it say".
exec tio --baudrate "$BAUD" --timestamp --log --log-file "$LOGFILE" "$PORT"
