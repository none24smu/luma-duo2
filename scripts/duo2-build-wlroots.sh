#!/usr/bin/env bash
# Rebuild Fedora's wlroots with the Duo 2 patches (packaging/wlroots/).
#
# Fedora's own source RPM, at the exact version the rootfs carries, fetched
# from Koji and checked, with packaging/wlroots/*.patch added to its patch
# list and a ".duo2" release so it sorts above Fedora's build. Built in the
# aarch64 builder (luma-duo2-builder); the RPMs land in build/wlroots/RPMS.
#
# Usage: duo2-build-wlroots.sh [VERSION-RELEASE]   (default 0.20.2-1)

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

VR="${1:-0.20.2-1}"
V="${VR%-*}"; R="${VR#*-}"
NAME="${LUMA_DUO2_BUILDER_NAME:-luma-duo2-builder}"
OUT="$(cd "$LUMA_DUO2_ROOT/.." && pwd)/build/wlroots"
SRPM="wlroots-$V-$R.fc44.src.rpm"
mkdir -p "$OUT"

[ -f "$OUT/$SRPM" ] || curl -fsSL -o "$OUT/$SRPM" \
    "https://kojipkgs.fedoraproject.org/packages/wlroots/$V/$R.fc44/src/$SRPM"

docker exec "$NAME" rm -rf /root/wlroots-build
docker exec "$NAME" mkdir -p /root/wlroots-build/patches
docker cp "$OUT/$SRPM" "$NAME:/root/wlroots-build/"
for p in "$LUMA_DUO2_ROOT"/packaging/wlroots/*.patch; do
    docker cp "$p" "$NAME:/root/wlroots-build/patches/"
done

docker exec -w /root/wlroots-build "$NAME" bash -euo pipefail -c '
srpm=$1
rpm -K --nosignature "$srpm" >/dev/null
top=$PWD/rpmbuild
rpm -i --define "_topdir $top" "$srpm"
spec=$top/SPECS/wlroots.spec
# Our patches after Fedora'"'"'s, in the unconditional range %autopatch applies.
n=50
for p in patches/*.patch; do
    cp "$p" "$top/SOURCES/"
    sed -i "/^Patch:.*\.patch/a Patch$n:        $(basename "$p")" "$spec"
    n=$((n + 1))
done
sed -i "s/^Release:\( *\)\([0-9.]*\)%{?dist}/Release:\1\2.1.duo2%{?dist}/" "$spec"
grep -E "^(Release|Patch[0-9]*):" "$spec"
dnf -y -q builddep --setopt=install_weak_deps=False "$spec" >/dev/null
rpmbuild -bb --define "_topdir $top" --nocheck --without gpgverify "$spec" 2>&1 | tail -5
' _ "$SRPM"

rm -rf "$OUT/RPMS"; mkdir -p "$OUT/RPMS"
docker exec "$NAME" bash -c 'find /root/wlroots-build/rpmbuild/RPMS -name "*.rpm" ! -name "*debug*"' | while read -r f; do
    docker cp "$NAME:$f" "$OUT/RPMS/"
done
ls "$OUT/RPMS"
