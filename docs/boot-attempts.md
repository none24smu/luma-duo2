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
