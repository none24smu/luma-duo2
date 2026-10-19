#!/usr/bin/env bash
# Assemble the Duo 2 touch runtime from the stock firmware.
#
# duo2-touchd hosts Microsoft's heat processor, libsurfacetouch_c1.so, which
# is an Android library. This collects it and everything it links against,
# resolved the way Android's linker resolves a vendor library: the vendor
# image first, then the VNDK apex, then the system image, with bionic from
# its bootstrap copies (no apex mounts here). Plus the stock linker64 to run
# it all. Nothing here is redistributable; it is assembled on the build host
# from the user's own firmware into build/duo2-touch/, never committed.
#
# Usage: duo2-touch-bundle.sh     (needs build/stock-{vendor,system,vndk}/,
#                                   extracted by docs/touch.md's steps)

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

BUILD="$(cd "$LUMA_DUO2_ROOT/.." && pwd)/build"
VENDOR="$BUILD/stock-vendor"
SYSTEM="$BUILD/stock-system/system"
VNDK="$BUILD/stock-vndk/payload"
OUT="$BUILD/duo2-touch"
for d in "$VENDOR/lib64" "$SYSTEM/lib64" "$VNDK/lib64"; do
    [ -d "$d" ] || die "missing $d -- extract the stock images first"
done

rm -rf "$OUT"; mkdir -p "$OUT/lib64"
install -m 0755 "$SYSTEM/bin/bootstrap/linker64" "$OUT/linker64"
install -m 0644 "$VENDOR/lib64/c1/libsurfacetouch_c1.so" "$OUT/lib64/"

find_lib() {
    local n=$1 d
    for d in "$SYSTEM/lib64/bootstrap" "$VENDOR/lib64" "$VNDK/lib64" "$SYSTEM/lib64"; do
        [ -f "$d/$n" ] && { printf '%s' "$d/$n"; return 0; }
    done
    return 1
}

# Dependency closure, to a fixed point.
while :; do
    added=0
    for f in "$OUT"/lib64/*.so "$BUILD/tools/duo2-touchd"; do
        [ -f "$f" ] || continue
        for n in $(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
            [ -f "$OUT/lib64/$n" ] && continue
            src="$(find_lib "$n")" || die "no $n in the stock images (needed by $(basename "$f"))"
            install -m 0644 "$src" "$OUT/lib64/"
            added=1
        done
    done
    [ "$added" = 0 ] && break
done
[ -f "$BUILD/tools/duo2-touchd" ] && install -m 0755 "$BUILD/tools/duo2-touchd" "$OUT/duo2-touchd"
info "touch runtime: $(ls "$OUT/lib64" | wc -l) libraries, $(du -sh "$OUT" | cut -f1) in $OUT"
