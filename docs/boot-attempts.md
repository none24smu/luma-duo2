# RAM-boot attempts: what the bootloader accepts

Every row below was run against the real phone with `fastboot boot`, which
writes nothing. The point of recording them is that the ABL's two failure
modes look nothing alike and mean very different things, and that is not
obvious from a single attempt.

| # | Header | Kernel | Ramdisk | DTB via | Size | Footer | Result |
|---|---|---|---|---|---|---|---|
| 1 | v3 | Image.gz | yes | separate vendor_boot | 16.1 MB | none | `Load Error` |
| 2 | v2 | Image.gz | yes | `fastboot --dtb` | 16.5 MB | none | **`OKAY`, 10.21 s** |
| 3 | v2 | Image (raw) | yes | `fastboot --dtb` | 54.8 MB | none | `Load Error` |
| 4 | v1 | Image.gz+dtb | yes | appended to kernel | 16.5 MB | none | **`OKAY`, 10.21 s** |
| 5 | v1 | Image.gz+dtb | yes | appended | 128 MB (padded) | AVB hash, NONE | `Load Error` |
| 6 | v1 | Image.gz+dtb | **no** | appended | 15.9 MB | none | `Load Error` |

## What that rules in and out

**`Load Error` is rejection before execution.** It is returned for a boot v3
image (1), for an oversized image (3, 5) and for an image with no ramdisk (6).
So the ABL wants a legacy v1/v2 header, a ramdisk present, and something under
a size limit that lies between 16.5 MB (accepted) and 54.8 MB (rejected).

**`OKAY` is not success.** Rows 2 and 4 both return `OKAY` after *exactly*
10.21 s, which looks like a fixed timeout rather than work. No console appears
and the phone stays in fastboot.

**`fastboot boot` itself works on this bootloader.** WOA-Project boots the
Duo 2 with `fastboot boot uefi.img`, so the mechanism is sound and the fault is
in our image or in what happens after handoff.

## Things that were believed and then disproved

- *"The DTB goes in vendor_boot, so build v3."* True of how the phone is
  flashed, false for `fastboot boot`: the ABL does not consult the flashed
  vendor_boot for a RAM boot, so a v3 image, which structurally cannot carry a
  DTB, is unloadable. The device's own format is still v3; v2/v1 is a
  transport for RAM booting only.
- *"No USB disconnect proves the kernel never ran."* Wrong. A hung device does
  not actively disconnect; the host only notices on the next transaction, and
  none are being made. Absence of a disconnect is not evidence either way.
- *"`Image.gz` may not be self-extracting on arm64, so send raw `Image`."* The
  premise is correct — arm64 has no self-decompressor — but the ABL does
  handle gzip, and the raw image is rejected for being too large (3).
- *"The missing AVB footer is why it is rejected."* The stock `boot_b` really
  does carry one (`Algorithm: NONE`, unsigned, partition `boot`), and Luma's
  own boot.toml asks for it. But adding it (5) made things worse, because
  avbtool pads the image to the 128 MB partition size and oversized images are
  rejected. Untested at a smaller partition size, so unresolved rather than
  disproved.

## Reference point: the same SoC in postmarketOS

postmarketOS has no Surface Duo 2 port. It does support the Sony Xperia 1 III
(`sony-pdx215`), which is also SM8350, and its deviceinfo is the closest known
working recipe:

```
deviceinfo_header_version="1"
deviceinfo_append_dtb="true"
deviceinfo_flash_pagesize="4096"
deviceinfo_flash_offset_base="0x00000000"
deviceinfo_flash_offset_kernel="0x00008000"
deviceinfo_flash_offset_ramdisk="0x01000000"
deviceinfo_flash_offset_tags="0x00000100"
deviceinfo_flash_offset_dtb="0x01f00000"
```

Every offset matches what was read from the Duo 2's stock vendor_boot header.
Row 4 above is that recipe applied exactly, and it is one of the two that the
ABL accepts.

## Open question

Rows 2 and 4 are accepted and then nothing observable happens. With no debug
UART there is no way to tell from the host whether the kernel is running and
hanging early, or never starts. The next useful evidence is not another
variation of the image: it is either an account of what the phone's screens do
during those 10 seconds, or a debug-UART cable.


## Flashed attempts (after boot_b became ours)

Every attempt below flashed `boot_b` + `vendor_boot_b` + a blank `dtbo_b` and
rebooted.

> **Correction.** This section originally said a failed image "falls back to
> fastboot after ~15 s". It does not. Watching the phone shows the Microsoft
> logo stays on screen indefinitely, and every return to fastboot in this table
> was a person forcing it by hand. The ~15 s figure was the gap before that
> intervention, not anything the phone did. Nothing here was ever "rejected" in
> a way the host observed; the kernel's fate is unknown.

| # | Kernel in boot.img | DTB in vendor_boot | vbmeta | Result |
|---|---|---|---|---|
| 7 | `Image.gz` | mainline, no `qcom,msm-id` | untouched | logo, hung; returned by hand |
| 8 | `Image.gz` | + `qcom,msm-id`/`board-id` | untouched | logo, hung; returned by hand |
| 9 | `Image.gz` | + `qcom,msm-id`/`board-id` | `--disable-verification` | logo, hung; returned by hand |
| 10 | **raw `Image`** | + `qcom,msm-id`/`board-id` | `--disable-verification` | logo, hung; returned by hand |

### The kernel format was wrong in every earlier attempt

The stock `boot_b` kernel is an **uncompressed** arm64 `Image`: it begins
`4d5a` (`MZ`) with the ARM64 `ARMd` magic at offset 0x38, and `file` calls it
"Linux kernel ARM64 boot executable Image, little-endian, 4K pages". Attempts
1 through 9 all shipped `Image.gz` (`1f8b`). arm64 has no self-decompressing
kernel, so compression is entirely the bootloader's business and this one
wants none.

Fixing it did not make the phone boot, so it was not the only problem — but
it was definitely *a* problem, and every result gathered before attempt 10 was
taken with a kernel the bootloader could not have executed.

### Where this stands

Every attempt ends the same way: the logo stays up and the phone does nothing
observable until it is forced back to fastboot. With no console and no
display driver there is still no way to distinguish "the ABL never handed
off" from "the kernel started and hung", and that ambiguity has been the
limiting factor throughout. It also means every attempt costs a person's
hands, which the bring-up images now have to remove.


## Do not probe unknown `oem` commands on this bootloader

`fastboot oem help` returns `unknown command`, but most other unknown `oem`
subcommands do not return anything at all: the ABL stops responding. Probing a
list of plausible names (`oem log`, `oem dmesg`, `oem uart-on` and so on) left
the bootloader wedged -- it still enumerated over USB and still appeared in
`fastboot devices`, but every command including `getvar product` and
`reboot-bootloader` timed out. Recovery was a 20-second Power hold.

Only two `oem` commands are known to work here:

| Command | Result |
|---|---|
| `oem help` | `FAILED (remote: 'unknown command')` |
| `oem device-info` | `Verity mode: true` / `Device unlocked: true` |

**`Verity mode: true` is the important one.** AVB verification is still
enabled on this phone despite the bootloader being unlocked, and flashing
`vbmeta_b` with only `--disable-verification` did not clear it. The next step
is `--disable-verity --disable-verification` together, confirmed by
`oem device-info` reporting the mode as false, rather than assumed.


## Microsoft's 5.4 kernel, and the first hands-off round trip (2026-10-18)

| # | Kernel | DTB / cmdline | dtbo | Init | Result |
|---|---|---|---|---|---|
| 11 | ours (msm-5.4 + g_serial) | USB-patched, panic→bootloader | stock | blocking writes | static logo; recovered by hand at 4.5 min |
| 12 | **stock** binary | same | stock | + configfs ACM | static logo; recovered by hand at 3.5 min |
| 13 | stock binary | **stock vendor_boot** | stock | same | static logo; recovered by hand at 2.5 min |
| 14 | ours | USB-patched | stock | non-blocking, 60 s enumeration check | **returned to fastboot by itself, 2:23** |
| 15 | ours | + `usb-role-switch` removed | stock | + sysfs `mode=peripheral` | returned by itself, 2:24; no USB device on the host |

**Attempt 14 is the first time the phone came home without a person.** That
proves, in one go: the ABL hands off to a kernel we built, the kernel reaches
our init, and `reboot("bootloader")` writes a reason the ABL honours.

### 11-13 were misread at the time

They were recorded live as "the kernel never reaches init". That does not
follow. The init then waited only for `/dev/ttyGS0` to *exist*, and the
gadget tty exists as soon as the function does, whether or not USB works --
so a broken-USB boot fell through to the 5-minute idle timer, and each
attempt was recovered by hand before it could fire. 13 was worse: with no
`console=ttyGS0` the init dumped dmesg to the port with blocking writes,
which wedge forever once the gadget's buffer fills with no host reading.
All three are consistent with the init running.

### What the stock tree's USB node actually needs

`ssusb@a600000` carries `usb-role-switch` as well as `extcon`. With a role
switch registered, dwc3-msm skips its own "start in dr_mode" branch and
waits for a role from the Type-C stack on the ADSP, which bring-up does not
run. Attempt 15 removed it and also forced `mode=peripheral` through sysfs;
the host still saw nothing, so something else is also missing.

### The dtbo is not optional for Microsoft's kernel

The base DTB in vendor_boot describes only the SoC. PMIC power-on,
`reboot_reason`, the board regulators and the Duo's own hardware are in
dtbo. Attempts 7-10 ran with it blanked; from 11 on it is stock.


## Mainline, and what this ABL demands of dtbo (2026-10-18)

Mainline v7.3-rc7 with `kernel/patches/mainline/` (ABL identity and splash
reservation in the DTS, panic → bootloader in reboot-mode) and the bring-up
config. Every image below that the ABL refused came back to fastboot about
15 s after the unlocked warning, **without the Microsoft logo**: the ABL
never handed off.

| # | Kernel / DTB | dtbo | Result |
|---|---|---|---|
| 16-17 | mainline | blank (zeros) | refused |
| 18 | **Microsoft's** | blank | **refused** — so blank dtbo alone is fatal |
| 19 | mainline | empty overlays (stock IDs, mainline compatible) | refused |
| 20 | Microsoft's | same | refused |
| 21 | Microsoft's | same + AVB footer | refused |
| 22 | Microsoft's | **stock** (control) | boots, ttyACM0 |
| 23 | mainline | empty overlays, stock compatible, footer | refused |
| 24 | Microsoft's | same | refused |
| 25 | Microsoft's | **stock with 12 bytes changed** | **boots**, ttyACM0 |
| 26 | mainline | one fragment per overlay (`target-path = "/"`) | refused |

What is established:

- **A blank dtbo is fatal on this phone.** Luma's FP6 policy of blanking dtbo
  does not carry over.
- **The dtbo hash in vbmeta is not enforced** (25), so a dtbo of our own is
  allowed. vbmeta stays untouched.
- **Overlays with no fragments are refused** (20, 21, 24) even with the stock
  identifiers, compatible and footer.

What is not: whether 26 failed on the dtbo or on the mainline DTB/kernel.
Mainline was parked here in favour of Microsoft's kernel for now; the next
mainline step is 26's dtbo under Microsoft's kernel, which separates the two.
`duo2-mkdtbo.sh` builds that dtbo.


## Luma's base system boots (2026-10-18)

Microsoft's 5.4 kernel with patches 0001-0005, postmarketOS's initramfs
(3.12.5) plus the Duo 2 overlay, and a Fedora 44 rootfs built from Luma's
mobile package lists, in `userdata` as `pmOS_boot` + `pmOS_root` -- the same
layout as Luma's Fairphone 6.

| # | Change | Result |
|---|---|---|
| L1 | first Luma image | initramfs finds and grows `pmOS_root`, then `unable to read superblock`; debug shell; **duo2-home returns it to fastboot at 120 s, unattended** |
| L2 | 4 KiB sectors in deviceinfo and the image | root mounts, `switch_root`, **systemd 259 starts** -- but every service fails `Failed to close unwanted file descriptors: Invalid argument` |
| L3 | patch 0005 (syscall 436) | **boots to a root shell on ttyACM0.** Fedora 44, `/run/luma-duo2-booted` present, root grown to 218 GB, one failed unit (`serial-getty@hvc0`); `duo2-bootloader.sh` returns it to fastboot |

### L1: UFS has 4 KiB logical blocks

postmarketOS attaches the subpartitions inside `userdata` with
`losetup --direct-io=on`, 512-byte sectors by default. Direct I/O on 4 KiB
UFS cannot serve 512-byte-aligned reads: the kernel's superblock read at
sector 526338 fails, while `e2fsck` and `resize2fs`, which read 4 KiB at a
time, succeed. `deviceinfo_rootfs_image_sector_size="4096"`, a partition
table written in 4096-byte sectors and 4 KiB ext4 blocks fix it.

### L2: Android's syscall 436 is not close_range

Android backported `process_madvise` at syscall 436 before upstream settled
the numbering; upstream gave 436 to `close_range()` and put `process_madvise`
at 440. systemd 259 calls `close_range()` before every exec and falls back
gracefully on `ENOSYS` -- but here it reached `process_madvise()` and got
`EINVAL`, which it rightly treats as fatal. Patch 0005 moves
`process_madvise` to 440 and leaves 436-439 unassigned. Any modern
userspace on an Android 5.4 kernel with this backport will hit the same thing.

### The way home now covers every stage

| Stage | Mechanism |
|---|---|
| kernel panic / watchdog | patch 0002, `panic_reason=bootloader` |
| initramfs failure | duo2-home phase 1: PID 1 still in the initramfs at 120 s |
| booted system that never reaches multi-user | duo2-home phase 2: no `/run/luma-duo2-booted` at 300 s |
| any stage with a console | `bootloader` command over ttyACM0 (`duo2-bootloader.sh`) |

## Luma's own UI on the panels (2026-10-18)

Luma's package set built for aarch64 with Luma's own builder scripts (phoc,
luma-phosh, luma-greeter, luma-greetd-session, Cage, GTK 4, libadwaita,
libhandy, shell-state, search, backgrounds, Figtree), composed into the
rootfs with `duo2-compose-ui.sh`, greetd on VT 7 (patch 0009).

| # | Change | Result |
|---|---|---|
| U1 | first UI image | the bring-up Weston service (re-added by `duo2-mkuserdata.sh`) took the panels first; Luma's session and Presence both exited, greetd hit its start limit |
| U2 | Weston off, greetd restarted | Presence greeter on phoc: **Luma wallpaper on both panels**, greeter window not visible |
| U3 | `Virtual-1` output disabled in phoc | **Presence clock and date on DSI-1**; wallpaper on DSI-2 |

### U2/U3: the writeback output

The SDE exposes a writeback connector, `Virtual-1`, alongside the two DSI
panels. phoc enables it and places it at 0,0, and the greeter's window opens
on it, where no panel shows it. Weston was told to leave it off; phoc has to be
as well.

### Not yet working

- **Touch.** `spi_hid` finds the digitizer (`045E:0C1D`, bound to
  hid-microsoft) but it is a capacitive heat-map digitizer (Digitizer page,
  usage 0x0F): it reports raw frames, not contacts. Android turns them into
  touches in userspace; Linux has no input device until something does.
- **GPU.** Phoc renders with pixman.
- **Boot animation.** Plymouth is installed but not set up for the Duo 2.
- **Clock.** No network time; the RTC reads September 2026.
