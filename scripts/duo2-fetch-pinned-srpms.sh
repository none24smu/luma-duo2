#!/usr/bin/env bash
# Put the exact source RPMs Luma pins into Luma's SRPM cache.
#
# Luma's builders take Fedora source RPMs pinned by name and SHA-256
# (config/desktop/inputs.env) and fetch them with dnf5 when they are not
# cached. Once Fedora updates a package, the pinned build leaves the repos,
# and Koji keeps only the unsigned copy -- whose bytes differ from the signed
# one Luma pinned, so the checksum gate rightly refuses it.
#
# A signed RPM is the unsigned package with the signature header spliced in
# after the 96-byte lead; Koji keeps that header in data/sigcache/<key>/. This
# rebuilds the signed file from those two Koji parts exactly as Koji does,
# and keeps it only if it matches Luma's pinned SHA-256. Nothing unverified
# reaches the cache. The release and updates trees are tried first.
#
# Usage: duo2-fetch-pinned-srpms.sh [VAR ...]   (default: every *_SRPM with a
#                                                 *_SRPM_SHA256 in inputs.env)

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

LUMA="$(cd "${LUMA_DUO2_LUMA_TREE:-$LUMA_DUO2_ROOT/../luma}" && pwd)"
CACHE="$LUMA/build/cache/srpm"
STAGE="$LUMA_DUO2_ROOT/build/srpm-staging"
HOST="${LUMA_DUO2_HOST_NAME:-luma-duo2-host}"
KOJI=https://kojipkgs.fedoraproject.org/packages
mkdir -p "$STAGE"

# shellcheck disable=SC1091
. "$LUMA/config/desktop/inputs.env"
if [ $# -eq 0 ]; then
    mapfile -t vars < <(grep -oE '^[A-Z0-9_]+_SRPM_SHA256=' "$LUMA/config/desktop/inputs.env" \
        | sed 's/_SHA256=$//')
else
    vars=("$@")
fi

ok() { echo "$2  $1" | sha256sum -c --status; }

# The cache belongs to root (the builder containers write it), so files go in
# through the Fedora host container, which mounts Luma's tree.
store() { docker exec "$HOST" install -D -m 0644 "$1" "$CACHE/$2"; }

for var in "${vars[@]}"; do
    srpm="${!var:-}"; sha_var="${var}_SHA256"; sha="${!sha_var:-}"
    case "$srpm" in *.src.rpm) ;; *) warn "$var: '$srpm' is not a source RPM, skipped"; continue ;; esac
    [ -n "$sha" ] || { warn "$var: no $sha_var"; continue; }
    if [ -f "$CACHE/$srpm" ] && ok "$CACHE/$srpm" "$sha"; then
        info "$srpm: already cached"; continue
    fi
    nvr="${srpm%.src.rpm}"; rel="${nvr##*-}"; nv="${nvr%-*}"; ver="${nv##*-}"; name="${nv%-*}"
    first="$(printf %s "$name" | cut -c1 | tr '[:upper:]' '[:lower:]')"
    out="$STAGE/$srpm"; rm -f "$out"
    for tree in releases/44 updates/44; do
        url="https://dl.fedoraproject.org/pub/fedora/linux/$tree/Everything/source/tree/Packages/$first/$srpm"
        curl -sfL -o "$out" "$url" && ok "$out" "$sha" && break || rm -f "$out"
    done
    if [ ! -f "$out" ]; then
        base="$KOJI/$name/$ver/$rel"
        curl -sfL -o "$STAGE/unsigned.rpm" "$base/src/$srpm" \
            || { warn "$srpm: not on Koji"; continue; }
        for key in $(curl -sfL "$base/data/sigcache/" | grep -oE 'href="[0-9a-f]{8}/"' | cut -d'"' -f2); do
            curl -sfL -o "$STAGE/sighdr" "$base/data/sigcache/${key}src/$srpm.sig" || continue
            python3 -I - "$STAGE/unsigned.rpm" "$STAGE/sighdr" "$out" <<'PY'
import struct, sys
rpm = open(sys.argv[1], 'rb').read(); sig = open(sys.argv[2], 'rb').read()
start = 96                                    # the RPM lead
assert rpm[start:start+3] == b'\x8e\xad\xe8' and sig[:3] == b'\x8e\xad\xe8'
il, dl = struct.unpack('>II', rpm[start+8:start+16])
size = 16 + 16*il + dl
size += (8 - size % 8) % 8                    # signature header pads to 8 bytes
open(sys.argv[3], 'wb').write(rpm[:start] + sig + rpm[start+size:])
PY
            ok "$out" "$sha" && { info "$srpm: rebuilt from Koji (key ${key%/}), matches pin"; break; }
            rm -f "$out"
        done
        rm -f "$STAGE/unsigned.rpm" "$STAGE/sighdr"
    else
        info "$srpm: from the Fedora 44 tree, matches pin"
    fi
    if [ -f "$out" ]; then store "$out" "$srpm"; rm -f "$out"
    else warn "$srpm: no source matches Luma's pinned SHA-256"
    fi
done
