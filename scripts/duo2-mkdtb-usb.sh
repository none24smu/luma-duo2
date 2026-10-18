#!/usr/bin/env bash
# Patch the stock Duo 2 device tree so the USB gadget comes up on its own.
#
# The stock tree describes the USB controller as dual-role and gates it on a
# cable-detect event:
#
#     ssusb@a600000 {
#         compatible = "qcom,dwc-usb3-msm";
#         extcon = <...>;                     <- waits for cable detect
#         dwc3@a600000 { dr_mode = "otg"; }   <- neither host nor device yet
#     }
#
# That event comes from the PMIC charger driver, which Android's first-stage
# init loads as a module. During bring-up there is no Android init and there
# are no modules, so the event never arrives, dwc3-msm never registers a UDC,
# and the built-in g_serial gadget has nothing to bind to. The result is no
# /dev/ttyGS0 and no console -- which looks exactly like a kernel that never
# booted, and is why several earlier attempts were unreadable.
#
# Forcing dr_mode to "peripheral" and dropping the extcon makes dwc3 come up
# as a gadget unconditionally at probe, with no userspace and no modules
# involved. That is wrong for a shipping image -- the port can no longer act
# as a host or charge-negotiate properly -- and right for a bring-up image
# whose only job is to produce a console.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

OUT="${LUMA_DUO2_OUT:-$LUMA_DUO2_ROOT/build}"
STOCK="${LUMA_DUO2_STOCK:-$LUMA_DUO2_ROOT/../SD2Firmware}"
UNPACK="${LUMA_DUO2_UNPACK:-$LUMA_DUO2_ROOT/../tools/mkbootimg/unpack_bootimg.py}"
WORK="$OUT/dtb-usb"

# The stock vendor_boot DTB section is three DTBs back to back, one per
# Lahaina silicon revision (v1, v2, v2.1); the bootloader picks the one whose
# qcom,msm-id matches the chip. Patching only one of them would leave the
# others stock, and the phone would silently boot whichever its chip matches.
# So every DTB in the section is patched and the section rebuilt.
rm -rf "$WORK"; mkdir -p "$WORK/vb"
python3 "$UNPACK" --boot_img "$STOCK/vendor_boot_b.img" --out "$WORK/vb" >/dev/null
python3 - "$WORK/vb/dtb" "$WORK" <<'PY'
import sys
d = open(sys.argv[1], "rb").read(); i = n = 0
while (i := d.find(b"\xd0\x0d\xfe\xed", i)) >= 0:
    size = int.from_bytes(d[i+4:i+8], "big")
    open(f"{sys.argv[2]}/stock-{n}.dtb", "wb").write(d[i:i+size]); n += 1; i += size
print(f"    stock DTB section: {n} DTBs")
PY

: > "$OUT/duo2-usb.dtb"
for STOCK_DTB in "$WORK"/stock-*.dtb; do
DTS="${STOCK_DTB%.dtb}.dts"
info "patching $(basename "$STOCK_DTB")"
dtc -I dtb -O dts -o "$DTS" "$STOCK_DTB" 2>/dev/null

python3 - "$DTS" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

# Narrow to the ssusb@a600000 block (usb_1, the port the cable is in and the
# controller Microsoft's own cmdline names in androidboot.usbcontroller).
start = s.index("ssusb@a600000 {")
depth, i = 0, start
while True:
    if s[i] == "{": depth += 1
    elif s[i] == "}":
        depth -= 1
        if depth == 0: break
    i += 1
block = s[start:i+1]
orig = block

block_new = re.sub(r'\n\s*extcon = <[^>]*>;', '', block, count=1)
n_extcon = 1 if block_new != block else 0
block = block_new

block_new, n_mode = re.subn(r'dr_mode = "otg";', 'dr_mode = "peripheral";', block)
block = block_new

# Make sure it negotiates at high speed only; SuperSpeed needs the QMP PHY
# fully up and a CDC-ACM console has no use for the bandwidth.
block, n_speed = re.subn(r'maximum-speed = "super-speed-plus";',
                         'maximum-speed = "high-speed";', block)

s = s[:start] + block + s[i+1:]
p.write_text(s)
print(f"    extcon removed: {n_extcon}, dr_mode->peripheral: {n_mode}, speed->high-speed: {n_speed}")
if n_mode == 0:
    sys.exit("error: dr_mode was not patched; the tree is not shaped as expected")
PY

dtc -I dts -O dtb -o "${DTS%.dts}-usb.dtb" "$DTS" 2>/dev/null
cat "${DTS%.dts}-usb.dtb" >> "$OUT/duo2-usb.dtb"
done

printf '    %s  %s bytes\n' "$OUT/duo2-usb.dtb" "$(stat -c%s "$OUT/duo2-usb.dtb")"
