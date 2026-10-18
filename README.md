# Luma Mobile on the Microsoft Surface Duo 2

Bring-up of [Luma Mobile](https://github.com/SimplyLuma/luma) — a Fedora-based
Linux system — on the Microsoft Surface Duo 2 (`surfaceduo2`, Qualcomm SM8350).

**Status: pre-boot.** The phone does not run Luma. It does not run any
mainline kernel yet. This repository is the working record of getting there.

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
| Mainline device tree exists | yes, minimal: storage, USB, UART, regulators |
| Display / GPU / touch / camera in mainline | **no** |
| Kernel builds | not yet |
| USB console reaches the workstation | not yet |
| Boots | no |

See [docs/hardware.md](docs/hardware.md) for everything the hardware actually
reports, and [docs/usb-logging.md](docs/usb-logging.md) for the debug workflow.

## Layout

```
devices/microsoft/surface-duo2/   device manifests, in Luma's schema
socs/qcom/sm8350/                 shared SM8350 family configuration
kernel/config/                    defconfig fragments
kernel/patches/                   patches against mainline
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

Then, in two terminals:

```sh
./scripts/duo2-console.sh                              # reader, start first
./scripts/duo2-ramboot.sh build/boot.img build/vendor_boot.img
./scripts/duo2-bootloader.sh                           # get back
```

Iteration is `fastboot boot` only. Nothing is flashed until an image has
already booted from RAM.

## Rules this repository follows

Luma's device tree forbids several things outright, and this repository is held
to the same standard even though it sits outside that tree:

- **No firmware, bootloaders or vendor binaries.** Not one blob.
- **No signing keys, tokens or secrets.**
- **Nothing identifying a particular phone or person** — no serial numbers, no
  IMEI, no ICCID.
- **The phone's radio identity is never written**, only preserved.
- Only slot `b` is ever touched. Slot `a` stays as Microsoft shipped it.

## Licensing

Manifests, scripts and documentation here are Apache-2.0. Kernel patches under
`kernel/patches/` are GPL-2.0-only, inheriting from Linux.
