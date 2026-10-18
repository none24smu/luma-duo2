#!/usr/bin/env bash
# Copy a file to the booted Duo 2 over the USB console.
#
# There is no network on the phone yet, only the root shell on ttyGS0. This
# sends the file as base64 into a heredoc with terminal echo off (so the
# collector log does not fill with it), decodes it on the phone, and checks
# the SHA-256 on both ends.
#
# Usage: duo2-push.sh LOCAL_FILE REMOTE_PATH [MODE]

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

SRC="${1:?usage: duo2-push.sh LOCAL REMOTE [MODE]}"
DST="${2:?usage: duo2-push.sh LOCAL REMOTE [MODE]}"
MODE="${3:-0644}"
PORT="${DUO2_SHELL_PORT:-/dev/ttyACM0}"
SHELL_RUN="$(dirname "${BASH_SOURCE[0]}")/duo2-shell.sh"

[ -f "$SRC" ] || die "no $SRC"
[ -e "$PORT" ] || die "no $PORT -- is the phone booted?"
want="$(sha256sum "$SRC" | cut -d' ' -f1)"

{
    printf '\r\nstty -echo; base64 -d > %q.part <<"DUO2EOF"\r\n' "$DST"
    base64 -w 76 "$SRC" | sed 's/$/\r/'
    printf 'DUO2EOF\r\nstty echo\r\n'
} > "$PORT"

got="$("$SHELL_RUN" "mv $(printf %q "$DST").part $(printf %q "$DST") && chmod $MODE $(printf %q "$DST") && sha256sum $(printf %q "$DST")" | cut -d' ' -f1)"
[ "$got" = "$want" ] || die "checksum mismatch on the phone (got '$got')"
info "pushed $(basename "$SRC") -> $DST ($(stat -c%s "$SRC") bytes, sha256 ok)"
