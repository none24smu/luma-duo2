#!/usr/bin/env bash
# Pack the Luma rootfs into the Duo 2's userdata image.
#
# The same layout as Luma's Fairphone 6 image: userdata holds a small
# partition table with pmOS_boot and pmOS_root, and postmarketOS's initramfs
# finds and mounts those subpartitions by label. pmOS_root is sized to the
# rootfs plus headroom; the initramfs grows it into the rest of the 222 GB
# partition on first boot. The result is an Android sparse image for fastboot.
#
# Runs in a native (x86_64) Fedora container as root, so the rootfs's owners,
# modes and xattrs go into the filesystem exactly as composed. Also installs
# the kernel modules and an fstab into the rootfs, and sets SELinux
# permissive (experimental tier).
#
# Usage: duo2-mkuserdata.sh      writes build/duo2-userdata/userdata.sparse

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

BUILD="$(cd "$LUMA_DUO2_ROOT/.." && pwd)/build"
ROOTFS="${LUMA_DUO2_ROOTFS_OUT:-$BUILD/duo2-rootfs}/rootfs"
MODULES="${LUMA_DUO2_MODULES_OUT:-$BUILD/duo2-modules}"
INITRAMFS="${LUMA_DUO2_INITRAMFS_OUT:-$BUILD/duo2-initramfs}/initramfs"
KERNEL="$BUILD/../reference/msm-5.4/out/target/product/duo2/obj/kernel/msm-5.4/arch/arm64/boot/Image"
OUT="$BUILD/duo2-userdata"
IMAGE="${LUMA_DUO2_FEDORA_HOST_IMAGE:-registry.fedoraproject.org/fedora:44}"

for f in "$ROOTFS/etc/os-release" "$INITRAMFS" "$KERNEL"; do
    [ -e "$f" ] || die "missing input: $f"
done
[ -d "$MODULES/lib/modules" ] || die "no staged modules -- run duo2-stage-modules.sh"
mkdir -p "$OUT"; rm -f "$OUT"/*.img "$OUT"/*.sparse
KERNEL="$(cd "$(dirname "$KERNEL")" && pwd)/Image"

docker run --rm -v "$ROOTFS:/rootfs" -v "$MODULES:/modules:ro" \
    -v "$INITRAMFS:/in/initramfs:ro" -v "$KERNEL:/in/Image:ro" -v "$OUT:/out" \
    "$IMAGE" bash -euo pipefail -c '
dnf -q install -y e2fsprogs util-linux android-tools >/dev/null

# Kernel modules and the mounts the booted system expects.
cp -a /modules/lib/modules/. /rootfs/usr/lib/modules/
# Bring-up: SELinux permissive, which Luma allows for experimental-tier
# devices. Whether the Fedora policy loads on this Android kernel is untested,
# and a policy that fails to load under enforcing stops systemd outright.
sed -i "s/^SELINUX=.*/SELINUX=permissive/" /rootfs/etc/selinux/config
# "bootloader" sends the phone to fastboot from the booted system: the same
# command the bring-up init and the initramfs answer to.
printf "%s\n" "#!/bin/sh" "# Luma Duo 2 bring-up: reboot into fastboot." \
    "exec systemctl reboot --reboot-argument=bootloader" \
    > /rootfs/usr/local/sbin/bootloader
chmod 0755 /rootfs/usr/local/sbin/bootloader
cat > /rootfs/etc/fstab <<EOF
LABEL=pmOS_root  /      ext4  defaults  0 1
LABEL=pmOS_boot  /boot  ext4  defaults  0 2
EOF

stage=$(mktemp -d)
mkdir -p "$stage/boot"
cp /in/Image /in/initramfs "$stage/boot/"

boot_mb=256
root_mb=$(( $(du -sm /rootfs | cut -f1) * 13 / 10 + 512 ))
mkfs.ext4 -q -L pmOS_boot -d "$stage/boot" /out/boot.img "${boot_mb}M"
mkfs.ext4 -q -L pmOS_root -d /rootfs      /out/root.img "${root_mb}M"

# Partition table: 1 MiB alignment, boot then root.
total_mb=$(( 1 + boot_mb + root_mb + 1 ))
truncate -s "${total_mb}M" /out/userdata.img
sfdisk -q /out/userdata.img <<EOF
label: dos
start=1MiB, size=${boot_mb}MiB, type=83
size=${root_mb}MiB, type=83
EOF
dd if=/out/boot.img of=/out/userdata.img bs=1M seek=1 conv=notrunc status=none
dd if=/out/root.img of=/out/userdata.img bs=1M seek=$((1 + boot_mb)) conv=notrunc status=none
img2simg /out/userdata.img /out/userdata.sparse
rm -f /out/boot.img /out/root.img /out/userdata.img
echo "pmOS_boot ${boot_mb} MiB, pmOS_root ${root_mb} MiB"
'
ls -la "$OUT"
