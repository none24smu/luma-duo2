# Surface Duo 2 — what the hardware actually reports

Everything here was read off the phone or out of its stock firmware. Nothing is
inferred from other Qualcomm devices. Where a value is still unknown it says so
rather than carrying a plausible guess.

## Identity

Read over fastboot:

| Variable | Value |
|---|---|
| `product` | `surfaceduo2` |
| `current-slot` | `b` |
| `slot-count` | `2` |
| `unlocked` | `yes` |
| `version-bootloader` | `2023.501.53` |
| `max-download-size` | `0x30000000` (768 MiB) |

The bootloader is from the same `2023.501` train as the last public kernel
release Microsoft shipped (`2023.501.541`).

The USB fastboot interface enumerates as `045e:0c2f` *Microsoft Corp. Surface
Duo Fastboot*. The serial number is deliberately absent from this repository.

**This port only ever uses slot `b`, the slot the phone is already on.** Slot
`a` is left as Microsoft shipped it, so Android remains intact there.

## Partitions (slot b)

| Partition | Size | Notes |
|---|---|---|
| `boot_b` | 128 MiB (`0x8000000`) | Android boot header v3 |
| `dtbo_b` | 24 MiB (`0x1800000`) | flashed blank; Luma brings its own DTB |
| `vbmeta_b` | 64 KiB | never written |
| `super` | 14 GiB | Android dynamic partitions; unused by Luma |
| `userdata` | ~221 GiB | where Luma lives |
| `metadata` | 16 MiB | |

## Boot image format

The Duo 2 differs from the Fairphone 6 here, and it changes how images are
built.

`boot_b.img` is `ANDROID!` **header version 3**:

- kernel 42.1 MiB, ramdisk 12.2 MiB, header size 1580
- **command line empty** — boot v3 carries a cmdline field but Microsoft leaves
  it blank
- no DTB section at all; boot v3 does not have one

`vendor_boot_b.img` is `VNDRBOOT` **version 3** and carries the rest:

- vendor ramdisk 683 KiB
- **DTB 1.38 MiB**
- page size 4096
- load offsets: kernel `0x00008000`, ramdisk `0x01000000`, tags `0x00000100`,
  DTB `0x01f00000`
- the real command line:

```
console=ttyMSM0,115200n8 androidboot.console=ttyMSM0 androidboot.memcg=1
lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000
msm_rtb.filter=0x237 service_locator.enable=1
androidboot.usbcontroller=a600000.dwc3 swiotlb=0 loop.max_part=7
cgroup.memory=nokmem,nosocket pcie_ports=compat
```

Two things worth keeping from that line:

- `androidboot.usbcontroller=a600000.dwc3` names the USB controller. In
  mainline that same address is `usb_1`, which is the one the CDC-ACM console
  gadget binds to.
- `console=ttyMSM0` shows Android expects a real UART console. We have no
  debug cable for it, so this port uses the USB gadget instead.

**Consequence:** shipping a Luma device tree means building a `vendor_boot`
image, not just a boot image. A boot v3 image alone cannot carry a DTB.

### Confirming v3 against the device, not just the dump

The header versions above were first read out of the files in `SD2Firmware/`.
A dump can be stale or from another build, so the claim was checked against the
hardware separately. In order of strength:

1. **The device's own partition table contains `vendor_boot_a` and
   `vendor_boot_b`** (96 MiB each, from `fastboot getvar all`). A `vendor_boot`
   partition exists only for boot header v3 and later; a v2 device does not
   have one at all. This is device-side evidence and does not depend on the
   dump being correct.
2. **43 of the 44 dump images match the device's partition sizes exactly**,
   including the asymmetric pair `vbmeta_system_a` at 64 KiB against
   `vbmeta_system_b` at 3,988 KiB — a coincidence that is not plausible. The
   single mismatch is `super`, where the dump is a shrunk 13.45 GB against a
   15.03 GB partition, which is normal for a super image.
3. AOSP's own `unpack_bootimg` reports `boot image header version: 3` and
   `vendor boot image header version: 3`, agreeing with the hand parse.
4. The boot header records `os version: 11.0.0`. Devices launching on
   Android 11 are required by GKI to use boot v3 with vendor_boot, and
   Microsoft's kernel branch for this phone is `surfaceduo2/11/...`.
5. Microsoft's own build script metadata
   (`reference/msm-5.4/device_build/kernel/kernel.json`) lists
   `vendor_ramdisk_kernel_modules`, which is a vendor_boot v3 concept.

What this does **not** establish is that the bootloader would reject a v4
image; v4 was never offered to it. Images are built as v3 because that is what
is proven. The boot partition cannot be read back to settle it directly --
`fastboot` 34.0.4 has no `fetch` command.

## Mainline kernel support

`arch/arm64/boot/dts/qcom/sm8350-microsoft-surface-duo2.dts` is already in
mainline — 380 lines, `compatible = "microsoft,surface-duo2", "qcom,sm8350"`.
It was added as *"arm64: dts: qcom: add minimal DTS for Microsoft Surface
Duo 2"* and has since gained a battery charger and a USB dual-role fix.

What it enables:

- RPMh regulators (pm8350, pm8350c)
- **UFS** — storage works
- **USB1 and USB2** with HS and QMP PHYs; `usb_1_dwc3 { dr_mode = "peripheral" }`
- UART2, with `stdout-path = "serial0:115200n8"`
- I²C 10 and 11, tlmm
- adsp, cdsp, mpss, slpi remoteprocs; IPA

What it does **not** have — a grep for `mdss|gpu|panel|display|touch|dsi`
returns **zero** matches:

- no display, no GPU, no panel, no DSI
- no touch
- no camera
- no usable modem

So a mainline kernel on this phone boots to storage and a console, with both
screens dark. That is the correct starting point, but it means display bring-up
is real work, not configuration.

## Why the vendor 5.4 tree is still here

`reference/msm-5.4/` holds Microsoft's `surface-duo-oss` kernel at
`surfaceduo2/11/2023.501.541` (Linux 5.4.233). It is **not** the kernel this
port ships. It is the reference for hardware mainline does not describe yet —
`arch/arm64/boot/dts/surface/duo2/` has the panel, touch, audio and
connectivity device trees that a mainline port has to be written against.
