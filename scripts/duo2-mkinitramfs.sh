#!/usr/bin/env bash
# Build the bring-up initramfs for the Surface Duo 2.
#
# This is not the shipping initramfs. Luma's real one is postmarketOS's plus an
# OSTree overlay; this is a single static binary whose only job is to prove the
# USB CDC-ACM console works end to end and then stay alive so the port can be
# watched rather than guessed at. A kernel with no init does print its panic,
# but it tears the gadget down immediately and proves very little.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

OUT="${LUMA_DUO2_OUT:-$LUMA_DUO2_ROOT/build}"
SRC="$LUMA_DUO2_ROOT/kernel/initramfs"
CC="${CROSS_COMPILE:-aarch64-linux-gnu-}gcc"

command -v "$CC" >/dev/null || die "no aarch64 compiler ($CC)"
mkdir -p "$OUT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE"/{proc,sys,dev}
info "compiling bring-up init (static, no libc on the device)"
"$CC" -static -Os -o "$STAGE/init" "$SRC/init.c"
"${CROSS_COMPILE:-aarch64-linux-gnu-}strip" "$STAGE/init"

info "packing initramfs"
( cd "$STAGE" && find . -print0 | cpio --null -o -H newc --quiet ) | gzip -9 \
    > "$OUT/initramfs.cpio.gz"

printf '    %s  %s bytes\n' "$OUT/initramfs.cpio.gz" "$(stat -c%s "$OUT/initramfs.cpio.gz")"
