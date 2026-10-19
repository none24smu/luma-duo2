# Touch on the Surface Duo 2

The Duo 2's digitizer is a Microsoft "G6" capacitive sensor behind both
panels, on `spi0.0`, driven by Microsoft's `spi-hid` (HID `045E:0C1D`, product
`Zeta`). It does not report finger positions. It streams raw heat frames, one
HID collection per panel, and on Android a userspace library turns them into
contacts. Luma uses that same library, from the stock vendor image.

Nothing here is guessed: every value below comes out of the stock firmware or
the digitizer itself.

## What the stock firmware contains

| Piece | Where | Role |
|---|---|---|
| `vendor.surface.touchpen@1.3-service` | `/vendor/bin/hw/` | the touch HAL: reads `hidraw`, drives the library, injects through uinput |
| `libsurfacetouch_c1.so` | `/vendor/lib64/c1/` | Microsoft's heat processor, Duo 2 build: contact detection, palm rejection, panel stitching, hinge handling, tuning (`PS_CFG_DATA_Zeta`) |
| `G6_FW_PKG_Zeta.cfu` | `/vendor/firmware/cfu/hid/touch/0C1D/` | the digitizer's own firmware (already on the device) |
| `PixelAlignmentData.bin` | `sfpd` partition, `display/` | per-unit two-panel alignment |

The digitizer's metadata feature report (report 6) gives the sensor geometry:
30 x 21 sensors per panel, 85.21 x 120.20 mm.

## How the stock service drives the library

Read from the service with Ghidra (it keeps RTTI class names) and from the
library's own symbols:

1. `dlopen` the library when the digitizer's product ID is `0x0C1D`, and call
   `CreateHeatProcessorInstance()` (no arguments).
2. Describe the two panels as `EosHeatDevice { u8 region; u32 kind; collection }`:
   region 1 / kind 2 for the collection holding report `0x0A`, region 2 /
   kind 1 for the one holding report `0x3C`.
3. Call, by vtable slot of `SurfaceHeatProcessorEos`:
   `InitPenTouchMw(devA, state dir, service, 0x0C1D)` (2),
   `OnDeviceAttached(devB)` (5), `OnStitchingModeChange(true)` (9),
   `GetAxisRange()` (12), `GetMaxConcurrentPenTouchSlots()` (13).
4. For each report read from `hidraw`: `ProcessIncomingReport(dev, length, data)`
   (3), then `PostDispatchProcessing(dev)` (4). Heartbeats (`0xFE`) name their
   panel in their second byte.
5. On display changes: `OnDisplayChange(dev, on)` (10) per panel and
   `OnStitchingModeChange` (9).

The library calls back through `IEosHeatService` (slots 2-6:
`SetAngleSensitivity`, `SendMessageToTouchFw`, `SendPenReports`,
`SendTouchReports`, `SendHidReportsToTPAgent`). `SendMessageToTouchFw` is a
plain `write()` to `hidraw` and returns true on failure. `SendTouchReports`
delivers 31-byte contacts: id at +2, state at +4 (7 = touching), x/y at
+5/+9, width/height at +0xD/+0x11, orientation at +0x15.

Before the library is started the service waits for `spi0.0/ready` to read
`ready`. The library then configures the digitizer itself through
`SendMessageToTouchFw` (report `0x05` = heat mode, `0x09` = display state and
panel alignment). On Luma heat frames have also needed the heat-mode feature
(report 5 = 1) and the panel-state output report (`0x38`, bit 0 left, bit 1
right) sent directly; duo2-touchd does both after starting the library.

Stitching (`OnStitchingModeChange`) merges both panels into one surface and
needs a frame from each panel every scan cycle; anything else is dropped
(`ParserInvalidStitchingCycleNumber`). Android enables it only while an app
spans both screens, so duo2-touchd leaves it off.

## Factory data the library expects

The library keeps its own storage directory (`/data/vendor/vendor.touchpen_hal`
on Android, `/var/lib/duo2-touchd` here). Android's
`init.surface.touch.preloads.sh` copies the unit's two-panel alignment into it
at every boot, from the factory-data partition `sfpd`
(`display/PixelAlignmentData.bin` -> `TwoPanelAlignment.bin`).
`luma-duo2-touch-calibration` does the same from the phone's own `sfpd` before
the service starts. The other files the library reads there (`IsTouchEnable`,
`PressureCurve`, `RecentPens`) default sensibly when absent.

## On Luma

`tools/duo2-touchd` is that service, minus Android: an Android (bionic)
program run with the stock `linker64` and the stock runtime libraries, which
`scripts/duo2-touch-bundle.sh` assembles from the user's own firmware into
`build/duo2-touch/` (vendor image first, then the VNDK apex, then the system
image). None of it is committed.

The library reports contacts on one stitched surface spanning both panels
(x 0..17455, the right panel starting after the hinge gap). Linux compositors
map each touch device to one output, so duo2-touchd splits it back at the
panel width the digitizer reports and creates one uinput touchscreen per
panel. A udev rule (`90-luma-duo2-touch.rules`) tags them with their outputs
(`WL_OUTPUT` = `DSI-1` left, `DSI-2` right), which libinput reports as the
device's output name. wlroots does not pass that on, and both panels report
the same EDID, so phoc reads it from libinput itself (`luma-fixes/0003`).

## Debugging

- `LD_PRELOAD=/opt/duo2-touch/liblog-stderr.so` (a drop-in for the unit) sends
  the library's own Android log messages to the journal.
- `--dump` logs every contact the library reports.
- `systemctl kill -s USR1 luma-duo2-touchd` (full) or `-s USR2` (short) sends a
  scripted swipe up the right panel through the service's own devices.
- `echo "tap r 0.5 0.5" > /run/duo2-touchd.ctl` taps a panel (`l`/`r`) at a
  fractional position; `echo lift > /run/duo2-touchd.ctl` releases every contact.
- New input devices created while phoc runs are not picked up by phoc, so
  test through the service's devices rather than a second process.
