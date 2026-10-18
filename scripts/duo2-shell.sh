#!/usr/bin/env bash
# Run one shell command on the booted Duo 2 over the USB console and print
# its output.
#
# The phone's root shell is on ttyGS0 (/dev/ttyACM0 here), and duo2-logd.sh
# is already reading that port into logs/. Rather than open it a second time,
# this writes the command to the port wrapped in unique markers and reads the
# result back out of the collector's current log.
#
# Usage: duo2-shell.sh 'command ...'     [DUO2_SHELL_TIMEOUT=60]

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

CMD="${1:?usage: duo2-shell.sh 'command'}"
TIMEOUT="${DUO2_SHELL_TIMEOUT:-60}"
PORT="${DUO2_SHELL_PORT:-/dev/ttyACM0}"

[ -e "$PORT" ] || die "no $PORT -- is the phone booted?"
SESSION="$(ls -td "$LUMA_DUO2_ROOT"/logs/session-*/ 2>/dev/null | head -1)"
LOG="$(ls -t "$SESSION"boot-*.log 2>/dev/null | head -1)"
[ -n "$LOG" ] || die "no collector log -- start duo2-logd.sh"

tag="duo2-$$-$RANDOM"
start=$(stat -c%s "$LOG")
# Leading CR/LF flushes anything half-typed; the markers are built at run
# time so the echoed command line itself never matches them.
printf '\r\nT=%s; echo "<$T>"; ( %s ) 2>&1; echo "</$T:$?>"\r\n' "$tag" "$CMD" > "$PORT"

for _ in $(seq "$TIMEOUT"); do
    tail -c +"$((start + 1))" "$LOG" | tr -d '\r' | grep -aq "^</$tag:" && break
    sleep 1
done
tail -c +"$((start + 1))" "$LOG" | tr -d '\r' | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\][^\\]*\\//g' \
    | awk -v opentag="<$tag>" -v closetag="</$tag:" '
        index($0, closetag) == 1 { split($0, a, ":"); sub(">", "", a[2]); rc = a[2]; done = 1; exit }
        on { print }
        $0 == opentag { on = 1 }
        END { if (!done) { print "(no reply within timeout)"; exit 124 } exit rc }'
