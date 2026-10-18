#!/usr/bin/env bash
# Build the bring-up initramfs for the Surface Duo 2.
#
# Built with the kernel's own gen_init_cpio rather than find|cpio, because the
# archive has to contain real device nodes and creating those with mknod would
# need root. gen_init_cpio writes them straight into the archive from a text
# manifest.
#
# Device nodes are not optional here. The vendor kernel is built with
# CONFIG_DEVTMPFS unset, so nothing populates /dev at runtime: an initramfs
# without a /dev/console entry leaves the kernel unable to give init a
# console, and init unable to open one. An earlier version of this script
# packed an empty /dev directory, which meant a perfectly booting kernel would
# have been completely silent -- indistinguishable from one that never
# started.
#
# Usage: duo2-mkinitramfs.sh [-p]     -p builds the reboot probe instead

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

OUT="${LUMA_DUO2_OUT:-$LUMA_DUO2_ROOT/build}"
SRC="$LUMA_DUO2_ROOT/kernel/initramfs"
CC="${CROSS_COMPILE:-aarch64-linux-gnu-}gcc"
STRIP="${CROSS_COMPILE:-aarch64-linux-gnu-}strip"
# gen_init_cpio is a single C file in every kernel tree; build it once into
# build/host/ rather than depending on a copy living somewhere outside the
# project.
GEN_INIT_CPIO_SRC="${LUMA_DUO2_GEN_INIT_CPIO_SRC:-$LUMA_DUO2_ROOT/../linux-mainline/linux/usr/gen_init_cpio.c}"
GEN_INIT_CPIO="$OUT/host/gen_init_cpio"

PROBE=0
[ "${1:-}" = "-p" ] && PROBE=1

command -v "$CC" >/dev/null || die "no aarch64 compiler ($CC)"
mkdir -p "$OUT/host"
if [ ! -x "$GEN_INIT_CPIO" ] || [ "$GEN_INIT_CPIO_SRC" -nt "$GEN_INIT_CPIO" ]; then
    [ -f "$GEN_INIT_CPIO_SRC" ] || die "no gen_init_cpio.c at $GEN_INIT_CPIO_SRC"
    info "building host gen_init_cpio"
    cc -O2 -o "$GEN_INIT_CPIO" "$GEN_INIT_CPIO_SRC"
fi

if [ "$PROBE" -eq 1 ]; then
    SOURCE="$SRC/init-reboot-probe.c"; NAME="initramfs-probe.cpio.gz"
else
    SOURCE="$SRC/init.c"; NAME="initramfs.cpio.gz"
fi

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
info "compiling $(basename "$SOURCE") (static: the phone has no libc)"
"$CC" -static -Os -o "$STAGE/init" "$SOURCE"
"$STRIP" "$STAGE/init"

# Major/minor numbers are the standard Linux assignments: console is 5:1,
# ttyGS0 (the USB gadget serial port) is 240:0 on this kernel, and null is
# 1:3. ttyGS0 is included so init can write to the gadget directly even if it
# is not the kernel console.
cat > "$STAGE/cpio_list" <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/ttyGS0 0600 0 0 c 240 0
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /tmp 0755 0 0
file /init $STAGE/init 0755 0 0
EOF

info "packing initramfs with device nodes"
"$GEN_INIT_CPIO" "$STAGE/cpio_list" | gzip -9 > "$OUT/$NAME"
printf '    %s  %s bytes\n' "$OUT/$NAME" "$(stat -c%s "$OUT/$NAME")"
