#!/usr/bin/env bash
# Build a dtbo image the Duo 2's bootloader accepts, but which changes nothing.
#
# Luma's policy elsewhere is to blank dtbo. This ABL refuses that: with a
# zeroed dtbo it returns to fastboot right after the unlocked warning, without
# drawing the logo or starting any kernel -- even Microsoft's own, which boots
# fine with the stock dtbo (boot-attempts.md, attempt 18). The stock dtbo, on
# the other hand, is twelve overlays written for Microsoft's device tree;
# applied to mainline's they target nodes that do not exist.
#
# So this keeps the stock table's shape -- the same twelve entries, each with
# the same model, qcom,msm-id and qcom,board-id the ABL matches on -- and
# replaces every fragment with a single harmless one: it targets the root by
# path (no symbol lookups, so it applies to any base tree) and adds the
# property luma,dtbo-noop. Overlays with no fragments at all are rejected --
# the ABL returns to fastboot as if dtbo were blank -- so there has to be
# something to apply. The property also shows up in /proc/device-tree,
# which proves the ABL applied an entry.
#
# The ABL does not enforce dtbo's vbmeta hash on this unlocked phone (the
# stock image with 12 bytes changed boots normally), so a dtbo of our own
# is allowed; it just has to be a real one.
#
# Nothing from the stock image is carried over except those identifiers.
#
# Usage: duo2-mkdtbo.sh            writes build/dtbo-empty.img

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

OUT="${LUMA_DUO2_OUT:-$LUMA_DUO2_ROOT/build}"
STOCK="${LUMA_DUO2_STOCK:-$LUMA_DUO2_ROOT/../SD2Firmware}"
SLOT="${DUO2_SLOT:-b}"

command -v dtc >/dev/null || die "no dtc"
[ -f "$STOCK/dtbo_$SLOT.img" ] || die "no $STOCK/dtbo_$SLOT.img"
WORK="$OUT/dtbo-empty"; rm -rf "$WORK"; mkdir -p "$WORK"

python3 - "$STOCK/dtbo_$SLOT.img" "$WORK" "$OUT/dtbo-empty.img" <<'PY'
import struct, subprocess, sys

stock, work, out = sys.argv[1:4]
d = open(stock, "rb").read()
magic, total, hdr_size, ent_size, count, ent_off, page, version = \
    struct.unpack(">8I", d[:32])
assert magic == 0xd7b7ab1e, "stock dtbo has no DTBO table"

KEEP = ("model", "compatible", "qcom,msm-id", "qcom,board-id")
blobs = []
for i in range(count):
    size, off = struct.unpack(">2I", d[ent_off + i*ent_size:][:8])
    src = f"{work}/stock-{i}.dtb"
    open(src, "wb").write(d[off:off+size])
    dts = subprocess.run(["dtc", "-I", "dtb", "-O", "dts", src],
                         capture_output=True, text=True, check=True).stdout
    # Root-level properties only: they precede the first child node.
    root = dts[dts.index("/ {") + 3:]
    root = root[:root.index("{")]
    props = [l.strip() for l in root.splitlines()
             if l.strip().split(" = ")[0] in KEEP]
    # Copied as found: one stock entry (ZTP) has no qcom,msm-id at all.
    names = [p.split(" = ")[0] for p in props]
    assert "model" in names and "qcom,board-id" in names, f"entry {i}: {props}"
    body = "\n\t".join(props)
    empty = (f"/dts-v1/;\n\n/ {{\n\t{body}\n\n"
             "\tfragment@0 {\n\t\ttarget-path = \"/\";\n"
             "\t\t__overlay__ {\n\t\t\tluma,dtbo-noop;\n\t\t};\n\t};\n};\n")
    open(f"{work}/entry-{i}.dts", "w").write(empty)
    blob = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-"], input=empty.encode(),
                          capture_output=True, check=True).stdout
    blobs.append(blob)
    print(f"    entry {i:2}: {props[0]}  ({len(blob)} bytes)")

table = b""
offset = hdr_size + count * ent_size
for b in blobs:
    table += struct.pack(">8I", len(b), offset, 0, 0, 0, 0, 0, 0)
    offset += len(b)
img = struct.pack(">8I", magic, offset, hdr_size, ent_size, count,
                  hdr_size, page, version) + table + b"".join(blobs)
assert len(img) == offset
open(out, "wb").write(img)
print(f"    {out}  {len(img)} bytes, {count} empty overlays")
PY

# The stock dtbo, like boot and vendor_boot, ends in an unsigned AVB hash
# footer (Algorithm NONE) padded to the full partition. The images the ABL
# accepts all have one, so this does too.
AVBTOOL="${LUMA_DUO2_AVBTOOL:-$LUMA_DUO2_ROOT/../tools/avb/avbtool.py}"
DTBO_PART_SIZE=25165824
python3 "$AVBTOOL" add_hash_footer --image "$OUT/dtbo-empty.img" \
    --partition_name dtbo --partition_size "$DTBO_PART_SIZE" --algorithm NONE
[ "$(tail -c 64 "$OUT/dtbo-empty.img" | head -c 4)" = "AVBf" ] || die "no AVBf footer"
info "AVB footer added; padded to $DTBO_PART_SIZE bytes"
