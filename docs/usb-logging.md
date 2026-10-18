# Getting logs off the Duo 2 over USB

This phone has no debug-UART cable attached, so the only console is a USB
gadget the kernel raises itself. That single fact shapes the whole bring-up
loop, and it is worth being blunt about what it costs: **nothing is visible
until the dwc3 controller probes and the gadget enumerates.** A kernel that
dies before that point says nothing at all.

## The console

Mainline's Duo 2 device tree already sets `usb_1_dwc3 { dr_mode = "peripheral" }`,
so the controller at `a600000` comes up as a gadget without any patching.
Microsoft's own Android command line names the same controller
(`androidboot.usbcontroller=a600000.dwc3`), which is a useful confirmation.

The kernel is configured with the legacy `g_serial` gadget built in, rather
than driving configfs from userspace:

```
CONFIG_USB_GADGET=y
CONFIG_USB_G_SERIAL=y
CONFIG_U_SERIAL_CONSOLE=y
```

and the command line carries `console=ttyGS0,115200n8`.

This is deliberate. A configfs gadget needs userspace to assemble it, which
means an initramfs that works — exactly the thing we are trying to debug. The
legacy gadget binds to the first available UDC on its own, with no userspace at
all, so it produces a console on a kernel that has nothing else. Printk output
from before the console registers is not lost: it is replayed out of the ring
buffer the moment `ttyGS0` comes up.

On the workstation the gadget appears as `/dev/ttyACM0`.

## The loop

Three scripts, in `scripts/`. All of them refuse to act on any phone whose
`fastboot getvar product` is not `surfaceduo2`, because this workstation has
more than one phone attached and picking "the first device" is how the wrong
one gets written.

**1. Start the reader first.** It waits for the port rather than failing when
it is not there, so start it before booting anything:

```sh
./scripts/duo2-console.sh
```

It matches the gadget by USB vendor:product, not by lowest port number, and
records a timestamped log to `logs/console-<UTC>.log`. `tio` reconnects by
itself when the gadget drops at reboot, so one invocation survives a whole
cycle. Quit with Ctrl-t then q.

**2. RAM-boot the image.** Never flash during iteration:

```sh
./scripts/duo2-ramboot.sh build/boot.img build/vendor_boot.img
```

`fastboot boot` loads into memory and jumps. Nothing is written, so a kernel
that hangs is gone on the next power cycle and the boot partition is never at
risk. Because the Duo 2 is boot v3, the DTB is in `vendor_boot`, so both images
are passed — handing over only a boot image leaves the phone using Microsoft's
Android device tree, which is not what we are testing.

**3. Get back to the bootloader.**

```sh
./scripts/duo2-bootloader.sh
```

If the phone is already in fastboot it says so and reports the current slot.
If a kernel is up with a shell, `reboot bootloader` on the console is the clean
path. If it is wedged, hold Power for about 20 seconds, then Volume Down and
tap Power — the Duo 2 has no reset pin, so that is the only recovery.

## When the console stays silent

This is the expected failure during early bring-up, and guessing is a waste of
a flash cycle. In rough order:

1. **Did the gadget enumerate at all?** Watch `dmesg -w` on the workstation
   while booting. A USB device appearing and then dropping means the kernel got
   as far as dwc3 and died after; nothing appearing at all means it died
   before.
2. **pstore/ramoops.** The reliable answer to "what happened before the console
   existed" is to capture the previous boot's dmesg across a reboot. This needs
   a reserved-memory region in the device tree; mainline's Duo 2 DTS does not
   declare one yet, and the downstream 5.4 tree in `reference/msm-5.4/` is
   where to find the address Microsoft uses. This is the highest-value next
   step for debuggability and is not done yet.
3. **A debug UART cable.** A Qualcomm USB-C debug cable puts UART2 on the SBU
   pins and gives bootloader-level output, which neither of the above can. If
   bring-up stalls on a silent early hang, this stops being optional.

## What this does not give us

- No bootloader output. `fastboot` is the only visibility before the kernel.
- No output from a kernel that panics before dwc3 probes.
- No second console if the gadget itself is what is broken.
