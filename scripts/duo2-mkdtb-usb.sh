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
STOCK_DTB="${1:-$OUT/stock-dtb/blob0.dtb}"

[ -f "$STOCK_DTB" ] || die "no stock DTB at $STOCK_DTB"
mkdir -p "$OUT"

info "decompiling $(basename "$STOCK_DTB")"
dtc -I dtb -O dts -o "$OUT/stock-usb.dts" "$STOCK_DTB" 2>/dev/null

python3 - "$OUT/stock-usb.dts" <<'PY'
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

dtc -I dts -O dtb -o "$OUT/duo2-usb.dtb" "$OUT/stock-usb.dts" 2>/dev/null
printf '    %s  %s bytes\n' "$OUT/duo2-usb.dtb" "$(stat -c%s "$OUT/duo2-usb.dtb")"
dtc -I dtb -O dts "$OUT/duo2-usb.dtb" 2>/dev/null \
    | sed -n '/ssusb@a600000/,/^\t\t};/p' | grep -E 'dr_mode|extcon|maximum-speed' | sed 's/^/    /'
