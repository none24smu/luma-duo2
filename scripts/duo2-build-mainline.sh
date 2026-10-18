#!/usr/bin/env bash
# Build the mainline kernel and Duo 2 device tree for bring-up.
#
# arm64 defconfig, then kernel/config/duo2-bringup.config (everything the USB
# console and the way back to fastboot need, built in) and duo2-slim.config
# (other vendors' SoCs dropped, so the Image stays near the size of the stock
# kernel the ABL is known to start). Patches in kernel/patches/mainline/ are
# applied to a clean base first, as the vendor build does.
#
# Output goes to build/duo2-mainline/ at the project root, outside the tree.
#
# Usage: duo2-build-mainline.sh

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

KSRC="${LUMA_DUO2_MAINLINE_TREE:-$LUMA_DUO2_ROOT/../linux-mainline/linux}"
KOUT="${LUMA_DUO2_KBUILD:-$LUMA_DUO2_ROOT/../build/duo2-mainline}"
PATCHES="$LUMA_DUO2_ROOT/kernel/patches/mainline"
FRAGMENTS=("$LUMA_DUO2_ROOT/kernel/config/duo2-bringup.config"
           "$LUMA_DUO2_ROOT/kernel/config/duo2-slim.config")
DTB=arch/arm64/boot/dts/qcom/sm8350-microsoft-surface-duo2.dtb

[ -d "$KSRC/.git" ] || die "no mainline git tree at $KSRC"
command -v aarch64-linux-gnu-gcc >/dev/null || die "no aarch64-linux-gnu-gcc"

mapfile -t touched < <(for p in "$PATCHES"/*.patch; do
    git -C "$KSRC" apply --numstat "$p" | cut -f3; done | sort -u)
git -C "$KSRC" checkout -- "${touched[@]}"
for p in "$PATCHES"/*.patch; do
    info "applying: $(basename "$p")"
    git -C "$KSRC" apply "$p" || die "$(basename "$p") does not apply"
done

export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
export KBUILD_BUILD_USER=luma KBUILD_BUILD_HOST=duo2-bringup
mkdir -p "$KOUT"
info "configuring: defconfig + $(printf '%s ' "${FRAGMENTS[@]##*/}")"
make -s -C "$KSRC" O="$KOUT" defconfig
"$KSRC/scripts/kconfig/merge_config.sh" -m -O "$KOUT" \
    "$KOUT/.config" "${FRAGMENTS[@]}" >/dev/null
make -s -C "$KSRC" O="$KOUT" olddefconfig

# A fragment line that did not survive olddefconfig (wrong name, unmet
# dependency) silently does nothing, so check every one.
for f in "${FRAGMENTS[@]}"; do
    grep -E '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set)' "$f" | while read -r want; do
        grep -qxF "$want" "$KOUT/.config" || warn "not in final .config: $want"
    done
done

info "building Image and $(basename "$DTB")"
make -s -C "$KSRC" O="$KOUT" -j"$(nproc)" Image "qcom/$(basename "$DTB")"

printf '    %s  %s bytes\n' "$KOUT/arch/arm64/boot/Image" \
    "$(stat -c%s "$KOUT/arch/arm64/boot/Image")"
printf '    %s\n' "$KOUT/$DTB"
