#!/usr/bin/env bash
# Stage the msm-5.4 kernel modules as a normal /lib/modules/<release> tree.
#
# Microsoft's build leaves its 154 modules flat, Android-style, with no
# modules.dep. A Fedora rootfs and postmarketOS's mkinitfs both expect the
# standard layout, so the modules go under kernel/vendor/, the build's
# modules.builtin lists are copied next to them, and depmod (which does not
# care about the target architecture) writes the dependency files.
#
# Usage: duo2-stage-modules.sh      writes build/duo2-modules/lib/modules/<release>

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

VTREE="${LUMA_DUO2_VENDOR_TREE:-$LUMA_DUO2_ROOT/../reference/msm-5.4}"
KOBJ="$VTREE/out/target/product/duo2/obj/kernel/msm-5.4"
KMOD="$VTREE/out/target/product/duo2/dlkm/lib/modules"
STAGE="${LUMA_DUO2_MODULES_OUT:-$LUMA_DUO2_ROOT/../build/duo2-modules}"

command -v depmod >/dev/null || die "no depmod (kmod)"
RELEASE="$(cat "$KOBJ/include/config/kernel.release")"
[ -n "$RELEASE" ] || die "no kernel.release in $KOBJ"

rm -rf "$STAGE"
DEST="$STAGE/lib/modules/$RELEASE"
mkdir -p "$DEST/kernel/vendor"
cp "$KMOD"/*.ko "$DEST/kernel/vendor/"
for f in modules.builtin modules.builtin.modinfo modules.order; do
    [ -f "$KOBJ/$f" ] && cp "$KOBJ/$f" "$DEST/"
done
depmod -b "$STAGE" "$RELEASE"

info "$RELEASE: $(find "$DEST" -name '*.ko' | wc -l) modules staged in $DEST"
