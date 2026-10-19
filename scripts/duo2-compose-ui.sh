#!/usr/bin/env bash
# Add Luma Mobile's UI to the Duo 2 rootfs, as Luma's FP6 compose does.
#
# Step two on top of duo2-compose-base-rootfs.sh. Following
# scripts/mobile/compose-fp6-rootfs.sh in the Luma tree:
#   - Luma's handheld UI package list (config/mobile/ui-packages.txt), at the
#     exact Fedora versions it pins, with the Duo 2 overrides in
#     config/mobile/duo2-ui-pin-overrides.txt;
#   - every Luma package built so far (luma/build/packages/, from
#     duo2-luma-builder.sh);
#   - the Phosh session launcher, Luma's desktop and handheld dconf, and the
#     handheld environment;
#   - the Duo 2 physical overlay (config/mobile/duo2-physical/overlay), the
#     Duo 2's counterpart of the FP6 one: greetd's Luma flow on VT 7,
#     the splash release before greetd, and software rendering for Phoc;
#   - greetd enabled, the bring-up Weston service retired.
#
# A pinned version that has left Fedora's repos is fetched from Koji by its
# exact NEVRA, together with its build's sibling subpackages. Runs in the
# same Fedora 44 arm64 container as the base compose.
#
# Usage: duo2-compose-ui.sh

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

LUMA="$(cd "${LUMA_DUO2_LUMA_TREE:-$LUMA_DUO2_ROOT/../luma}" && pwd)"
OUTDIR="$(cd "${LUMA_DUO2_ROOTFS_OUT:-$LUMA_DUO2_ROOT/../build/duo2-rootfs}" && pwd)"
IMAGE="${LUMA_DUO2_FEDORA_IMAGE:-registry.fedoraproject.org/fedora:44}"
OVERLAY="$LUMA_DUO2_ROOT/config/mobile/duo2-physical/overlay"
OVERRIDES="$LUMA_DUO2_ROOT/config/mobile/duo2-ui-pin-overrides.txt"
# Fedora packages rebuilt with Duo 2 patches (duo2-build-wlroots.sh).
DUO2_RPMS="$(cd "$LUMA_DUO2_ROOT/.." && pwd)/build/wlroots/RPMS"
ls "$DUO2_RPMS"/wlroots-[0-9]*.duo2.*.rpm >/dev/null || die "no Duo 2 wlroots in $DUO2_RPMS -- run duo2-build-wlroots.sh"
[ -d "$OUTDIR/rootfs/etc" ] || die "no base rootfs -- run duo2-compose-base-rootfs.sh"

docker run --rm --platform linux/arm64 -v "$LUMA:/luma:ro" -v "$OVERLAY:/overlay:ro" \
    -v "$OVERRIDES:/overrides.txt:ro" -v "$DUO2_RPMS:/duo2-rpms:ro" \
    -v "$OUTDIR:/out" "$IMAGE" bash -euo pipefail -c '
rootfs=/out/rootfs
koji=https://kojipkgs.fedoraproject.org/packages
dnf -q makecache >/dev/null
dnf -y -q install dconf systemd >/dev/null

# --- Luma UI packages at their pinned versions ----------------------------
mapfile -t pins < <(sed -e "/^[[:space:]]*#/d" -e "/^[[:space:]]*\$/d" \
    /luma/config/mobile/ui-packages.txt)
pkgs=()
mkdir -p /tmp/koji
declare -A override=()
while read -r from to; do override[$from]=$to
done < <(sed -e "/^[[:space:]]*#/d" -e "/^[[:space:]]*\$/d" /overrides.txt)
for pin in "${pins[@]}"; do
    if [ -n "${override[$pin]:-}" ]; then
        echo "pin override: $pin -> ${override[$pin]}"
        [ "${override[$pin]}" = - ] && continue
        pin=${override[$pin]}
    fi
    pkgs+=("$pin")
    dnf -q repoquery --available "$pin" 2>/dev/null | grep -q . && continue
    # Gone from the repos: fetch that exact build from Koji. Koji files
    # subpackages under their source package, and a pinned subpackage needs
    # its siblings at the same release (pipewire-pulseaudio needs that
    # pipewire-libs), so the whole build goes into a local repo for dnf.
    rel=${pin##*-}; nv=${pin%-*}; ver=${nv##*-}; name=${nv%-*}; ver=${ver#*:}
    src=$(dnf -q repoquery --available --qf "%{source_name}\n" "$name" 2>/dev/null | head -1)
    src=${src:-$name}
    got=0
    for arch in aarch64 noarch; do
        base="$koji/$src/$ver/$rel/$arch"
        for f in $(curl -sfL "$base/" | grep -oE "href=\"[^\"]+\.rpm\"" | cut -d\" -f2); do
            case "$f" in *-debuginfo-*|*-debugsource-*) continue ;; esac
            [ -f "/tmp/koji/$f" ] || curl -sfL -o "/tmp/koji/$f" "$base/$f"
            got=1
        done
    done
    [ "$got" = 1 ] || { echo "pinned $pin is neither in the repos nor on Koji" >&2; exit 1; }
    echo "from Koji: $pin (build $src-$ver-$rel)"
done
koji_repo=()
if ls /tmp/koji/*.rpm >/dev/null 2>&1; then
    dnf -y -q install createrepo_c >/dev/null
    createrepo_c -q /tmp/koji
    koji_repo=(--repofrompath=koji-pins,/tmp/koji --setopt=koji-pins.gpgcheck=0)
fi

# --- Luma packages built so far -------------------------------------------
# Only what each builder collected: the work.* scratch trees hold
# leftovers from earlier attempts, and -devel packages stay on the builder.
mapfile -t luma_rpms < <(find /luma/build/packages -name "work.*" -prune -o -name "*.work.*" -prune \
    -o -name "*.rpm" ! -name "*.src.rpm" ! -name "*-debuginfo-*" ! -name "*-debugsource-*" \
    ! -name "*-devel-*" \( -name "*.aarch64.rpm" -o -name "*.noarch.rpm" \) -print 2>/dev/null | sort)
# The Duo 2 rebuilds of Fedora packages, without their -devel parts.
mapfile -t duo2_rpms < <(find /duo2-rpms -name "*.duo2.*.rpm" ! -name "*-devel-*" | sort)
luma_rpms+=("${duo2_rpms[@]}")
echo "Luma packages: ${#luma_rpms[@]}"
printf "    %s\n" "${luma_rpms[@]##*/}"

dnf install -y --installroot="$rootfs" --releasever=44 --use-host-config \
    --setopt=install_weak_deps=False --allowerasing "${koji_repo[@]}" \
    "${pkgs[@]}" "${luma_rpms[@]}"
dnf clean all --installroot="$rootfs" --releasever=44 --use-host-config

# --- Session, settings and the Duo 2 overlay, as compose-fp6-rootfs.sh -----
install -D -m 0755 /luma/scripts/mobile/luma-phosh-session "$rootfs/usr/local/bin/luma-phosh-session"
install -D -m 0644 /luma/config/desktop/dconf/profile/user "$rootfs/etc/dconf/profile/user"
install -D -m 0644 /luma/config/desktop/dconf/db/luma.d/00-luma-desktop \
    "$rootfs/etc/dconf/db/luma.d/00-luma-desktop"
install -D -m 0644 /luma/config/mobile/luma-shell-handheld.dconf \
    "$rootfs/etc/dconf/db/luma.d/90-luma-handheld"
dconf compile "$rootfs/etc/dconf/db/luma" "$rootfs/etc/dconf/db/luma.d"
# Files as the overlay has them, owned by root; directories that already
# exist (/etc, /usr, ...) keep the owner and mode the rootfs gave them,
tar -C /overlay -cf - . | tar -C "$rootfs" -xf - --no-same-owner --no-overwrite-dir
# and none of it group- or world-writable, whatever the umask of the checkout.
(cd /overlay && find . -mindepth 1 -print0) | (cd "$rootfs" && xargs -0 chmod go-w)

# greetd owns the panels now; the bring-up Weston service is retired.
rm -f "$rootfs/etc/systemd/system/multi-user.target.wants/luma-duo2-weston.service"
systemctl --root="$rootfs" enable greetd.service
systemctl --root="$rootfs" set-default graphical.target

chmod 0644 "$rootfs/etc/passwd" "$rootfs/etc/group"
chmod 0600 "$rootfs/etc/shadow" "$rootfs/etc/gshadow"
rpm --root "$rootfs" -qa | sort > /out/packages-ui.txt
echo "rootfs now $(du -sh "$rootfs" | cut -f1), $(wc -l < /out/packages-ui.txt) packages"
'
