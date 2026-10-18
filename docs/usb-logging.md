# Getting logs off the Duo 2 over USB

**Verified on the phone, 2026-10-18.** The phone boots, a USB serial console
appears on the workstation as `/dev/ttyACM0`, the kernel log streams over it,
and the phone is sent back to fastboot from the workstation. Nobody touches
the phone.

This is bring-up tooling, not Luma Mobile. Luma is not on the phone. What
runs is Microsoft's own 5.4 kernel with three small patches and a single
static test program as `/init`. Its only purpose is to make every later step
of the port observable.

## What runs on the phone

| Piece | Source | Why |
|---|---|---|
| Kernel | Microsoft msm-5.4 (lahaina QGKI) + `kernel/patches/msm-5.4/` | the stock kernel is known to start on this bootloader |
| DTB (vendor_boot) | stock, patched by `duo2-mkdtb-usb.sh` | forces the USB port into device mode |
| dtbo | **stock**, unmodified | holds the PMIC, `reboot_reason` and board regulators; without it nothing below works |
| vendor ramdisk | empty | |
| boot ramdisk | `kernel/initramfs/init.c` + `screen.c` | console, commands and the way home |

### Kernel patches

- **0001:** built-in `g_serial` with `U_SERIAL_CONSOLE`, and **`dummy_hcd`
  removed**. Microsoft's config builds in `dummy_hcd`, a software loopback
  controller. It registers before the real one, and `g_serial` bound to it, so
  the console gadget was attached to the phone itself and never reached the
  port. That was the last thing between us and a working console.
- **0002:** `qcom_reboot_reason.panic_reason=` parameter, so a panic writes the
  "bootloader" reason and lands in fastboot.
- **0003:** `/dev/mem` with strict mode off, for the on-screen status
  (bring-up only).

### DTB changes (`ssusb@a600000`, all three silicon-revision DTBs)

- `extcon` removed. The cable event comes from a PMIC charger driver that is
  not running.
- `usb-role-switch` removed. With it present, dwc3-msm waits for the Type-C
  firmware on the ADSP to pick a role, which never happens here.
- `dr_mode = "peripheral"`, `maximum-speed = "high-speed"`.

### Command line additions

```
console=ttyGS0,115200n8
qcom_reboot_reason.panic_reason=bootloader
qcom_dload_mode.download_mode=0 msm_poweroff.download_mode=0
```

## The loop

```sh
DUO2_GADGET_ANY=1 ./scripts/duo2-logd.sh &   # collector: one file per boot under logs/
./scripts/duo2-build-vendor.sh               # kernel (incremental)
./scripts/duo2-mkinitramfs.sh                # init
./scripts/duo2-mkboot.sh --vendor            # boot.img + vendor_boot.img
./scripts/duo2-flash.sh --stock-dtbo         # current slot only; never vbmeta
fastboot -s <serial> reboot                  # or the duo2_fastboot wrapper
# ... /dev/ttyACM0 appears ~16-18 s later ...
./scripts/duo2-bootloader.sh                 # back to fastboot in ~5-7 s
```

Commands on the port, one per line: `dmesg` (the whole kernel log), `help`,
`reboot`, `bootloader`.

## How the phone gets home without a person

Every path out of the bring-up init ends in a reboot with the "bootloader"
reason:

| Situation | What happens |
|---|---|
| host sends `bootloader` | fastboot immediately |
| no `ttyGS0`, or the host never enumerates the gadget | fastboot after 60 s (90 s when the status screen is up) |
| nothing from the host for `duo2.idle=` seconds | fastboot after 120 s by default; `0` disables |
| kernel panic, or a watchdog bark that panics | fastboot via `panic_reason=bootloader` |

The one case not covered is a hang before the kernel's watchdog is running.
That still needs the 20-second Power hold.

## When USB does not come up: the status screen

No display driver is loaded, so the display controller keeps scanning out
the boot logo from the splash buffer at `0xe1000000`. The init reads the
display pipes' registers (address, size, stride, bytes per pixel), finds the
pipes fetching from the splash, and draws white-on-black status text there:
- the current stage and a countdown,
- `ttyGS0`, the UDC name and its state,
- the dwc3-msm mode, driver binding and deferred probes,
- the USB-related tail of the kernel log.

A photo of the screen is how the `dummy_hcd` problem was found.

## Pitfalls already paid for

- **Blocking writes wedge the init.** A gadget tty with no host reading it
  fills up and blocks the writer forever. All output is non-blocking.
- **`ttyGS0` existing proves nothing.** It appears as soon as the gadget
  function does, working USB or not. Only the UDC state `configured` means
  the host enumerated it.
- **Echo on open.** The host's tty can bounce some of the phone's output back
  before it is switched to raw. Commands are matched at the end of the line,
  and the host sends a line break first.
- **Never blank dtbo with Microsoft's kernel.** See `boot-attempts.md`.
