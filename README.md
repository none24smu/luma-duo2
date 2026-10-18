# Luma Mobile on the Microsoft Surface Duo 2

Bring-up of [Luma Mobile](https://github.com/SimplyLuma/luma) — a Fedora-based
Linux system — on the Microsoft Surface Duo 2 (`surfaceduo2`, Qualcomm SM8350).

**Status: Luma's base system boots.** Microsoft's 5.4 kernel, postmarketOS's
initramfs and a Fedora 44 rootfs built from Luma's own mobile package lists
boot to a root shell over USB (`/dev/ttyACM0`), from `userdata`, in Luma's
Fairphone 6 layout. Luma's own packages and UI are not on it yet. Every stage
returns to fastboot without a person.

## What this is

Luma Mobile ships one device today, the Fairphone 6, on a Qualcomm SM7635
(`milos`). The Duo 2 is a different SoC family (SM8350, `lahaina`), so this
port creates a new `socs/qcom/sm8350/` family rather than inheriting anything
from the Fairphone. What carries over is the *shape* of a Luma device — the
manifest layout, the postmarketOS-initramfs plus OSTree boot model, the AVB and
dtbo policy — not its hardware configuration.

The Duo 2 is also a dual-screen foldable, which is unlike anything Luma
currently supports.

## Where it stands

| | |
|---|---|
| Device talks over fastboot | yes, unlocked, slot `b` |
| Boot image format understood | yes — Android boot v3 + vendor_boot v3 |
| Microsoft's 5.4 kernel builds and boots | yes, with our bring-up patches |
| postmarketOS initramfs mounts Luma's root | **yes** |
| Fedora 44 base with systemd boots to a shell | **yes** — over ttyACM0 |
| Luma's own packages and UI | not yet |
| USB console reaches the workstation | **yes** — `/dev/ttyACM0`, verified |
| Returns to fastboot without a person | **yes** — on command, timeout or panic |
| Mainline device tree exists | yes, minimal: storage, USB, UART, regulators |
| Mainline kernel boots | no — parked; the ABL refuses it before handoff |
| Display / GPU / touch / camera in mainline | **no** |

See [docs/hardware.md](docs/hardware.md) for everything the hardware actually
reports, and [docs/usb-logging.md](docs/usb-logging.md) for the debug workflow.

## Layout

```
devices/microsoft/surface-duo2/   device manifests, in Luma's schema
socs/qcom/sm8350/                 shared SM8350 family configuration
kernel/config/                    defconfig fragments
kernel/patches/                   patches against mainline
kernel/patches/msm-5.4/           bring-up patches for Microsoft's 5.4 kernel
kernel/initramfs/                 bring-up init, duo2-home (the way home)
config/mobile/                    postmarketOS deviceinfo for the Duo 2
scripts/                          bring-up tooling
docs/                             findings and workflow
```

## Working on it

The scripts need the phone's serial, which is never committed. Create
`.duo2.local` at the repo root:

```sh
echo 'DUO2_SERIAL=XXXXXXXXXXXX' > .duo2.local
```

Find it with `fastboot devices` while only the Duo 2 is attached, or match the
entry whose USB ID is `045e:0c2f`.

Then follow the loop in [docs/usb-logging.md](docs/usb-logging.md): build
Microsoft's kernel with our patches, flash the current slot (never vbmeta),
reboot, read `/dev/ttyACM0`, and send the phone back with
`./scripts/duo2-bootloader.sh`.

## Rules this repository follows

Luma's device tree forbids several things outright, and this repository is held
to the same standard even though it sits outside that tree:

- **No firmware, bootloaders or vendor binaries.** Not one blob.
- **No signing keys, tokens or secrets.**
- **Nothing identifying a particular phone or person** — no serial numbers, no
  IMEI, no ICCID.
- **The phone's radio identity is never written**, only preserved.
- Only the slot the phone is already on is touched, and never vbmeta.

## Licensing

Manifests, scripts and documentation here are Apache-2.0. Kernel patches under
`kernel/patches/` are GPL-2.0-only, inheriting from Linux.
