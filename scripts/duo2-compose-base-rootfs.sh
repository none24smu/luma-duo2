#!/usr/bin/env bash
# Compose the base Fedora 44 rootfs for Luma on the Surface Duo 2.
#
# Step one of two. This installs Luma's own mobile package lists -- the ones
# that come straight from the Fedora repos -- and applies Luma's user and
# system setup, so the phone can boot a real Luma base through the
# postmarketOS initramfs before any of Luma's own packages are built. The
# luma-*/prairie-* packages, the patched GTK stack and the UI come in step
# two, from scripts/packages/ in the Luma tree.
#
# Luma's compose scripts run natively as root on Fedora 44 AArch64. Here that
# builder is a Fedora 44 arm64 container under qemu-user emulation; the
# rootfs is written to build/duo2-rootfs/ at the project root.
#
# Bring-up only: a root shell is put on the USB serial console (ttyGS0), so
# a booted system can be inspected from the workstation. The luma user stays
# locked, as on the Fairphone 6.
#
# Usage: duo2-compose-base-rootfs.sh

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

LUMA="${LUMA_DUO2_LUMA_TREE:-$LUMA_DUO2_ROOT/../luma}"
OUTDIR="${LUMA_DUO2_ROOTFS_OUT:-$LUMA_DUO2_ROOT/../build/duo2-rootfs}"
IMAGE="${LUMA_DUO2_FEDORA_IMAGE:-registry.fedoraproject.org/fedora:44}"

[ -f "$LUMA/config/mobile/packages.txt" ] || die "no Luma tree at $LUMA"
command -v docker >/dev/null || die "no docker"
[ ! -e "$OUTDIR/rootfs" ] || die "refusing to replace $OUTDIR/rootfs"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"; LUMA="$(cd "$LUMA" && pwd)"

info "composing in $IMAGE (arm64, emulated) -> $OUTDIR/rootfs"
docker run --rm --platform linux/arm64 \
    -v "$LUMA:/luma:ro" -v "$OUTDIR:/out" "$IMAGE" bash -euo pipefail -c '
rootfs=/out/rootfs
lists="/luma/config/mobile/packages.txt /luma/config/mobile/phone-capability-packages.txt"
mapfile -t packages < <(sed -e "/^[[:space:]]*#/d" -e "/^[[:space:]]*\$/d" $lists | sort -u)

# Report, rather than silently skip, anything Fedora 44 does not carry.
dnf -q makecache >/dev/null
missing=()
for p in "${packages[@]}"; do
    dnf -q repoquery --available --latest-limit 1 "$p" | grep -q . || missing+=("$p")
done
[ ${#missing[@]} -eq 0 ] || { echo "not in Fedora 44: ${missing[*]}" >&2; exit 1; }

mkdir -p "$rootfs"
dnf install -y --installroot="$rootfs" --releasever=44 --use-host-config \
    --setopt=install_weak_deps=False "${packages[@]}"
dnf clean all --installroot="$rootfs" --releasever=44 --use-host-config

# Luma user and system setup, as compose-fp6-rootfs.sh does it.
groupadd --root "$rootfs" --gid 1000 luma
getent --service=files group luma-display >/dev/null 2>&1 || \
    grep -q "^luma-display:" "$rootfs/etc/group" || groupadd --root "$rootfs" --system luma-display
useradd --root "$rootfs" --uid 1000 --gid luma --groups wheel,luma-display,audio \
    --create-home --shell /bin/bash --comment "Project Luma diagnostic user" luma
usermod --root "$rootfs" --lock luma
printf "handheld\n" >"$rootfs/etc/luma-device-class"
install -D -m 0644 /luma/config/mobile/plymouthd.conf "$rootfs/etc/plymouth/plymouthd.conf"
install -D -m 0644 /luma/config/mobile/environment.d/90-luma-handheld.conf \
    "$rootfs/etc/environment.d/90-luma-handheld.conf"
echo surfaceduo2 >"$rootfs/etc/hostname"

# Bring-up only: root shell on the USB serial console.
install -d "$rootfs/etc/systemd/system/serial-getty@ttyGS0.service.d"
cat >"$rootfs/etc/systemd/system/serial-getty@ttyGS0.service.d/10-duo2-bringup.conf" <<EOF
# Bring-up only. Remove before anything is offered to anyone.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200 %I \$TERM
EOF
ln -sf /usr/lib/systemd/system/serial-getty@.service \
    "$rootfs/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service" 2>/dev/null || {
    install -d "$rootfs/etc/systemd/system/getty.target.wants"
    ln -sf /usr/lib/systemd/system/serial-getty@.service \
        "$rootfs/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"; }

rpm --root "$rootfs" -qa | sort >/out/packages.txt
du -sh "$rootfs" | tee /out/size.txt
'
info "done: $(cat "$OUTDIR/size.txt"), $(wc -l < "$OUTDIR/packages.txt") packages"
