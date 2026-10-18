#!/usr/bin/env bash
# Produce a Duo 2 device tree the Qualcomm bootloader will accept.
#
# Mainline's sm8350-microsoft-surface-duo2.dtb is a plain FDT with no
# Qualcomm identity properties. The ABL selects and validates a device tree by
# matching qcom,msm-id against the SoC it is running on, so a tree without one
# is not a candidate it can choose.
#
# The values are copied from the stock device tree rather than invented. The
# stock vendor_boot carries three concatenated FDTs, one per silicon revision:
#
#   Lahaina V2.1   qcom,msm-id = <0x19f 0x20001 0x1c8 0x20001 0x1f5 0x20001>
#   Lahaina V2     qcom,msm-id = <0x19f 0x20000 ...>
#   lahaina v1     qcom,msm-id = <0x19f 0x10000 ...>
#
# all with qcom,board-id = <0x00 0x00>. 0x19f is 415, the SM8350 SoC id, and
# the second word is the revision. This phone reports hw-revision 20001 over
# fastboot, so it is the V2.1 part and takes the first set.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

KBUILD="${LUMA_DUO2_KBUILD:-$HOME/LumaOS/build/duo2-kernel}"
OUT="${LUMA_DUO2_OUT:-$LUMA_DUO2_ROOT/build}"
SRC="$KBUILD/arch/arm64/boot/dts/qcom/sm8350-microsoft-surface-duo2.dtb"

MSM_ID="${DUO2_MSM_ID:-0x19f 0x20001 0x1c8 0x20001 0x1f5 0x20001}"
BOARD_ID="${DUO2_BOARD_ID:-0x00 0x00}"

[ -f "$SRC" ] || die "no mainline DTB at $SRC -- build the kernel first"
mkdir -p "$OUT"

info "patching $(basename "$SRC") with Qualcomm identity properties"
dtc -I dtb -O dts -o "$OUT/duo2.dts" "$SRC" 2>/dev/null

MSM_ID="$MSM_ID" BOARD_ID="$BOARD_ID" python3 - "$OUT/duo2.dts" <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if "qcom,msm-id" in s:
    print("    already present, leaving alone")
else:
    i = s.index("/ {") + len("/ {")
    s = (s[:i]
         + f"\n\tqcom,msm-id = <{os.environ['MSM_ID']}>;"
         + f"\n\tqcom,board-id = <{os.environ['BOARD_ID']}>;"
         + s[i:])
    p.write_text(s)
    print("    added qcom,msm-id and qcom,board-id")
PY

dtc -I dts -O dtb -o "$OUT/duo2-qcom.dtb" "$OUT/duo2.dts" 2>/dev/null
printf '    %s  %s bytes\n' "$OUT/duo2-qcom.dtb" "$(stat -c%s "$OUT/duo2-qcom.dtb")"
dtc -I dtb -O dts "$OUT/duo2-qcom.dtb" 2>/dev/null | grep -E 'msm-id|board-id' | sed 's/^/    /'
