#!/usr/bin/env bash
# Build Mesa's Turnip Vulkan driver with the KGSL backend for the Duo 2.
#
# Microsoft's 5.4 kernel drives the Adreno 660 through Qualcomm's KGSL, not
# drm/msm. Fedora builds Turnip for drm/msm only, so this builds Turnip alone,
# with both backends, from Fedora's own Mesa source RPM at the exact version
# the rootfs carries (from Koji, digest-checked), into a private prefix,
# /opt/mesa-kgsl, so it never replaces Fedora's Mesa. Output: an installed
# tree in build/mesa-kgsl/ for duo2-mkuserdata.sh.
#
# Usage: duo2-build-turnip.sh [VERSION-RELEASE]   (default 26.2.4-1)

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

VR="${1:-26.2.4-1}"
V="${VR%-*}"; R="${VR#*-}"
NAME="${LUMA_DUO2_BUILDER_NAME:-luma-duo2-builder}"
BUILD="$(cd "$LUMA_DUO2_ROOT/.." && pwd)/build"
SRPM="mesa-$V-$R.fc44.src.rpm"
mkdir -p "$BUILD/mesa"

[ -f "$BUILD/mesa/$SRPM" ] || curl -fsSL -o "$BUILD/mesa/$SRPM" \
    "https://kojipkgs.fedoraproject.org/packages/mesa/$V/$R.fc44/src/$SRPM"

docker cp "$BUILD/mesa/$SRPM" "$NAME:/root/"
docker exec -w /root "$NAME" bash -euo pipefail -c '
srpm=$1 v=$2
rpm -K --nosignature "$srpm" >/dev/null
dnf -y -q install cpio meson ninja-build gcc g++ python3-mako python3-pyyaml \
    python3-packaging glslang libdrm-devel wayland-devel wayland-protocols-devel \
    libxshmfence-devel expat-devel zlib-devel bison flex libdisplay-info-devel \
    elfutils-libelf-devel >/dev/null
rm -rf mesa-srpm "mesa-$v" mesa-kgsl-root
mkdir mesa-srpm && (cd mesa-srpm && rpm2cpio "../$srpm" | cpio -idm --quiet)
tar -xf "mesa-srpm/mesa-$v.tar.xz"
cd "mesa-$v"
meson setup build --prefix=/opt/mesa-kgsl --buildtype=release \
    -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl,msm -Dgallium-drivers= \
    -Dplatforms=wayland -Dglx=disabled -Degl=disabled -Dgbm=disabled \
    -Dllvm=disabled -Dvideo-codecs= -Dvulkan-layers= >/dev/null
ninja -C build -j"$(nproc)" >/dev/null
DESTDIR=/root/mesa-kgsl-root ninja -C build install >/dev/null
' _ "$SRPM" "$V"

rm -rf "$BUILD/mesa-kgsl"; mkdir -p "$BUILD/mesa-kgsl"
docker exec "$NAME" tar -C /root/mesa-kgsl-root -cf - opt/mesa-kgsl | tar -C "$BUILD/mesa-kgsl" -xf -
info "Turnip (KGSL + msm) $V installed tree: $BUILD/mesa-kgsl/opt/mesa-kgsl"
