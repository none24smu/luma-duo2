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
mkdir -p "$OUT" "$BUILD/tools"; rm -f "$OUT"/*.img "$OUT"/*.sparse
# Bring-up tools that live on the phone (tools/).
"${CROSS_COMPILE:-aarch64-linux-gnu-}gcc" -O2 -Wall -o "$BUILD/tools/duo2-kmstest" \
    "$LUMA_DUO2_ROOT/tools/duo2-kmstest.c"
KERNEL="$(cd "$(dirname "$KERNEL")" && pwd)/Image"
# Touch: duo2-touchd and the stock runtime it hosts (duo2-touch-bundle.sh),
# assembled from the user's firmware; not part of any committed file.
TOUCH="$BUILD/duo2-touch"
[ -x "$TOUCH/duo2-touchd" ] || die "no $TOUCH/duo2-touchd -- run duo2-touch-bundle.sh"
# Adreno 660 firmware (SQE microcode, GMU, zap shader), which KGSL loads from
# /lib/firmware, from the stock vendor image (docs/gpu.md).
# Mesa Turnip with the KGSL backend, in its own prefix (duo2-build-turnip.sh).
TURNIP="$BUILD/mesa-kgsl/opt/mesa-kgsl"
[ -f "$TURNIP/lib64/libvulkan_freedreno.so" ] || die "no Turnip-KGSL in $TURNIP -- run duo2-build-turnip.sh"
GPUFW="$BUILD/stock-vendor/firmware"
ls "$GPUFW"/a660_sqe.fw "$GPUFW"/a660_gmu.bin "$GPUFW"/a660_zap.mdt >/dev/null || \
    die "no Adreno 660 firmware in $GPUFW -- extract the stock vendor image"

# The luma account's passcode, from the gitignored .duo2.local
# (DUO2_LUMA_PASSCODE=), as Luma's FP6 assembler takes it: supplied by
# whoever builds the image, never a repository default. Only the hash goes
# into the image.
passcode="$(sed -n 's/^DUO2_LUMA_PASSCODE=//p' "$DUO2_LOCAL_CONFIG" 2>/dev/null | tail -1)"
[ -n "$passcode" ] || die "no DUO2_LUMA_PASSCODE= in $DUO2_LOCAL_CONFIG"
LUMA_PASSWORD_HASH="$(printf '%s' "$passcode" | openssl passwd -6 -stdin)"
unset passcode
export LUMA_PASSWORD_HASH

docker run --rm --platform linux/amd64 -e LUMA_PASSWORD_HASH \
    -v "$ROOTFS:/rootfs" -v "$MODULES:/modules:ro" \
    -v "$INITRAMFS:/in/initramfs:ro" -v "$KERNEL:/in/Image:ro" -v "$OUT:/out" \
    -v "$BUILD/tools:/tools:ro" -v "$BUILD/ssh/duo2_ed25519.pub:/in/ssh.pub:ro" \
    -v "$TOUCH:/touch:ro" -v "$GPUFW:/gpufw:ro" -v "$TURNIP:/turnip:ro" \
    "$IMAGE" bash -euo pipefail -c '
dnf -q install -y e2fsprogs util-linux android-tools >/dev/null

# Kernel modules and the mounts the booted system expects.
# Owned by root, not by whoever staged them: uid 1000 on the workstation is
# the luma user on the phone. The rootfs directory itself was made on the
# workstation too, and becomes the filesystem root.
cp -a --no-preserve=ownership /modules/lib/modules/. /rootfs/usr/lib/modules/
chown root:root /rootfs
usermod --root /rootfs --password "$LUMA_PASSWORD_HASH" luma
# Turnip-KGSL (docs/gpu.md); /etc/environment points phoc and Vulkan at it.
rm -rf /rootfs/opt/mesa-kgsl
cp -a --no-preserve=ownership /turnip /rootfs/opt/mesa-kgsl
# Adreno 660 firmware for KGSL.
install -d /rootfs/usr/lib/firmware
install -m 0644 /gpufw/a660_sqe.fw /gpufw/a660_gmu.bin /gpufw/a660_zap.* /rootfs/usr/lib/firmware/
# Touch runtime (see docs/touch.md); the unit comes with the Duo 2 overlay.
rm -rf /rootfs/opt/duo2-touch
cp -a --no-preserve=ownership /touch /rootfs/opt/duo2-touch
[ -f /rootfs/usr/lib/systemd/system/luma-duo2-touchd.service ] && \
    ln -sf /usr/lib/systemd/system/luma-duo2-touchd.service \
        /rootfs/etc/systemd/system/multi-user.target.wants/luma-duo2-touchd.service
install -m 0755 /tools/duo2-kmstest /rootfs/usr/local/bin/duo2-kmstest
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
# The marker duo2-home waits for: without it 300 s into boot (duo2.booted=),
# the phone goes back to fastboot by itself.
printf "%s\n" "[Unit]" \
    "Description=Luma Duo 2 bring-up: mark the boot as reaching multi-user" \
    "After=multi-user.target" "" "[Service]" "Type=oneshot" \
    "ExecStart=/usr/bin/touch /run/luma-duo2-booted" "" \
    "[Install]" "WantedBy=multi-user.target" \
    > /rootfs/etc/systemd/system/luma-duo2-booted.service
# The Microsoft kernel registers an hvc0 console with no hypervisor behind it
# (hvc_open fails with -22); the systemd getty generator still starts a getty
# on it, which fails and leaves the system "degraded". Mask it.
ln -sf /dev/null /rootfs/etc/systemd/system/serial-getty@hvc0.service
mkdir -p /rootfs/etc/systemd/system/multi-user.target.wants
ln -sf ../luma-duo2-booted.service \
    /rootfs/etc/systemd/system/multi-user.target.wants/luma-duo2-booted.service
# USB network (the ECM half of g_cdc): the phone is 172.16.42.1 on usb0 and
# hands the workstation 172.16.42.2 by DHCP, with no router or DNS on offer
# so the workstation never sends its own traffic this way.
install -d -m 0700 /rootfs/etc/NetworkManager/system-connections
printf "%s\n" "[connection]" "id=duo2-usb" "type=ethernet" "interface-name=usb0" \
    "autoconnect=true" "" "[ipv4]" "method=manual" "address1=172.16.42.1/24" \
    "" "[ipv6]" "method=disabled" \
    > /rootfs/etc/NetworkManager/system-connections/duo2-usb.nmconnection
chmod 0600 /rootfs/etc/NetworkManager/system-connections/duo2-usb.nmconnection
printf "%s\n" "[Unit]" "Description=Luma Duo 2 bring-up: DHCP for the USB network link" \
    "After=NetworkManager.service sys-subsystem-net-devices-usb0.device" \
    "BindsTo=sys-subsystem-net-devices-usb0.device" "" "[Service]" \
    "ExecStartPre=/bin/sh -c \"until ip -4 addr show usb0 | grep -q 172.16.42.1; do sleep 1; done\"" \
    "ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --port=0 --interface=usb0 --bind-interfaces --dhcp-range=172.16.42.2,172.16.42.2,255.255.255.0,1h --dhcp-option=3 --dhcp-option=6 --dhcp-authoritative --log-dhcp" \
    "Restart=always" "RestartSec=3" "" "[Install]" "WantedBy=multi-user.target" \
    > /rootfs/etc/systemd/system/luma-duo2-usb-dhcp.service
ln -sf ../luma-duo2-usb-dhcp.service \
    /rootfs/etc/systemd/system/multi-user.target.wants/luma-duo2-usb-dhcp.service

# SSH over that link, root by key only (the bring-up key in build/ssh/, which
# never leaves the workstation). Interactive access does not depend on the
# serial console, whose receive side stops ~300 s into boot.
install -d -m 0700 /rootfs/root/.ssh
install -m 0600 /in/ssh.pub /rootfs/root/.ssh/authorized_keys
ln -sf /usr/lib/systemd/system/sshd.service \
    /rootfs/etc/systemd/system/multi-user.target.wants/sshd.service
# Bring-up GUI: Weston with the software renderer on both panels, started at
# boot. Not Luma UI -- the first proof that a compositor drives the Duo 2.
# The virtual (writeback) output is left off, and the screens never blank.
# Only for a base rootfs: once duo2-compose-ui.sh has made greetd the display
# manager, the Luma session owns the panels. (-L: the link is absolute, so
# -e would follow it into this container rather than the rootfs.)
if [ ! -L /rootfs/etc/systemd/system/display-manager.service ]; then
install -d /rootfs/etc/xdg/weston
printf "%s\n" "[core]" "idle-time=0" "" "[output]" "name=Virtual-1" "mode=off" \
    > /rootfs/etc/xdg/weston/weston.ini
# ExecStartPre: the ABL splash keeps one display pipe reserved until a mode
# set releases it, and a compositor that picks that pipe has its first
# commit refused. A one-second legacy mode set from duo2-kmstest frees it.
# Workaround until the splash handoff is fixed in the kernel.
printf "%s\n" "[Unit]" "Description=Luma Duo 2 bring-up: Weston on both panels" \
    "After=systemd-user-sessions.service" "" "[Service]" \
    "Environment=LIBSEAT_BACKEND=noop XDG_RUNTIME_DIR=/run/user/0" \
    "ExecStartPre=/usr/bin/install -d -m 0700 /run/user/0" \
    "ExecStartPre=-/usr/bin/timeout 10 /usr/local/bin/duo2-kmstest 1" \
    "ExecStart=/usr/bin/weston --backend=drm --renderer=pixman --shell=desktop --continue-without-input --log=/run/weston.log" \
    "Restart=on-failure" "RestartSec=3" "" "[Install]" "WantedBy=multi-user.target" \
    > /rootfs/etc/systemd/system/luma-duo2-weston.service
ln -sf ../luma-duo2-weston.service \
    /rootfs/etc/systemd/system/multi-user.target.wants/luma-duo2-weston.service
else
rm -f /rootfs/etc/systemd/system/luma-duo2-weston.service \
    /rootfs/etc/systemd/system/multi-user.target.wants/luma-duo2-weston.service
fi

cat > /rootfs/etc/fstab <<EOF
LABEL=pmOS_root  /      ext4  defaults  0 1
LABEL=pmOS_boot  /boot  ext4  defaults  0 2
EOF

stage=$(mktemp -d)
mkdir -p "$stage/boot"
cp /in/Image /in/initramfs "$stage/boot/"

boot_mb=256
root_mb=$(( $(du -sm /rootfs | cut -f1) * 13 / 10 + 512 ))
# 4 KiB blocks on both: the phone reads them through 4 KiB sectors, and
# mkfs would otherwise give the small boot filesystem 1 KiB blocks.
mkfs.ext4 -q -b 4096 -L pmOS_boot -d "$stage/boot" /out/boot.img "${boot_mb}M"
mkfs.ext4 -q -b 4096 -L pmOS_root -d /rootfs      /out/root.img "${root_mb}M"

# Partition table: 1 MiB alignment, boot then root, in 4096-byte sectors --
# the UFS logical block size, and what the initramfs attaches the image with
# (deviceinfo_rootfs_image_sector_size).
total_mb=$(( 1 + boot_mb + root_mb + 1 ))
truncate -s "${total_mb}M" /out/userdata.img
sfdisk -q --sector-size 4096 /out/userdata.img <<EOF
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
