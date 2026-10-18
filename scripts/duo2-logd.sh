#!/usr/bin/env bash
# Persistent USB console collector.
#
# Runs in the background for a whole session and survives the phone rebooting.
# Whenever the CDC-ACM gadget enumerates it opens it, appends everything to a
# per-boot file under logs/, and goes back to waiting when the phone drops.
# Nothing here needs a terminal, so it can be left running while other
# commands drive the phone.
#
# Usage: duo2-logd.sh [-d SECONDS]   (0 = run until killed, the default)

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

DURATION=0
while getopts ":d:h" opt; do
    case "$opt" in
        d) DURATION="$OPTARG" ;;
        h) sed -n '2,11p' "$0"; exit 0 ;;
        *) die "unknown option -$OPTARG" ;;
    esac
done

LOGDIR="$LUMA_DUO2_ROOT/logs"
mkdir -p "$LOGDIR"
SESSION="$LOGDIR/session-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$SESSION"
STATUS="$SESSION/collector.log"

note() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$STATUS"; }

note "collector started; watching for USB gadget $DUO2_GADGET_USB_ID"
note "writing to $SESSION"

START=$SECONDS
boot=0
while true; do
    [ "$DURATION" -ne 0 ] && [ $((SECONDS-START)) -ge "$DURATION" ] && break

    port=""
    for tty in /dev/ttyACM*; do
        [ -e "$tty" ] || continue
        vid="$(udevadm info -q property -n "$tty" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')"
        pid="$(udevadm info -q property -n "$tty" 2>/dev/null | sed -n 's/^ID_MODEL_ID=//p')"
        [ "$vid:$pid" = "$DUO2_GADGET_USB_ID" ] && { port="$tty"; break; }
    done

    if [ -z "$port" ]; then
        sleep 1
        continue
    fi

    boot=$((boot+1))
    out="$SESSION/boot-$(printf '%03d' "$boot").log"
    note "gadget up on $port -> $(basename "$out")"
    stty -F "$port" 115200 raw -echo 2>/dev/null
    # Reads until the phone drops the port, then loops back to waiting.
    cat "$port" >> "$out" 2>/dev/null
    note "gadget dropped after $(stat -c%s "$out" 2>/dev/null || echo 0) bytes"
done
note "collector stopped"
