#!/usr/bin/env bash
# Compile the emulated aarch64 builds natively, through distcc.
#
# The aarch64 builders run under qemu-user, where compiling is the slow part.
# This starts a native x86_64 compile server (luma-duo2-distcc) with Fedora's
# aarch64 cross GCC -- the same GCC release as the native one in the builders
# -- and routes the builders' compiles through ccache (compiler names in
# /usr/local/bin) and on to it (ccache prefix_command = distcc).
# The builders still preprocess, link and run tests themselves; only the
# compile of preprocessed source moves. Anything the server cannot compile
# falls back to the builder's own compiler, so a build never depends on it.
#
# The server drops Fedora's annobin flags: the annobin plugin is built for the
# native compiler only. It records build notes in binaries and changes nothing
# they do. Fedora's hardening specs are honoured (redhat-rpm-config).
#
# Re-run after containers restart (the server's address can change).
#
# Usage: duo2-distcc.sh [--recreate]

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

SERVER=luma-duo2-distcc
CLIENTS=(luma-rpm-builder-f44 "${LUMA_DUO2_BUILDER_NAME:-luma-duo2-builder}")
IMAGE="${LUMA_DUO2_FEDORA_HOST_IMAGE:-registry.fedoraproject.org/fedora:44}"
GCC_VERSION="${LUMA_DUO2_CROSS_GCC:-16.2.1}"

if [ "${1:-}" = --recreate ] || ! docker container inspect "$SERVER" >/dev/null 2>&1; then
    docker rm -f "$SERVER" >/dev/null 2>&1 || true
    docker run -d --name "$SERVER" --hostname "$SERVER" "$IMAGE" sleep infinity >/dev/null
    docker exec "$SERVER" dnf -y -q install distcc-server "gcc-aarch64-linux-gnu-$GCC_VERSION" \
        "gcc-c++-aarch64-linux-gnu-$GCC_VERSION" redhat-rpm-config procps-ng >/dev/null
fi
docker start "$SERVER" >/dev/null

# Compiler names the builders send (gcc, cc, g++, c++, and Fedora's triplet
# names), each the cross compiler minus annobin.
docker exec -i "$SERVER" sh -c 'mkdir -p /usr/local/libexec/duo2-cross && cat > /usr/local/libexec/duo2-cross/wrapper' <<'EOF'
#!/bin/sh
case "${0##*/}" in
    *g++|*c++) real=/usr/bin/aarch64-linux-gnu-g++ ;;
    *) real=/usr/bin/aarch64-linux-gnu-gcc ;;
esac
for a in "$@"; do
    shift
    case "$a" in
        -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1|-fplugin=annobin|-fplugin-arg-annobin-*) ;;
        *) set -- "$@" "$a" ;;
    esac
done
exec "$real" "$@"
EOF
docker exec "$SERVER" sh -c 'cd /usr/local/libexec/duo2-cross && chmod 755 wrapper &&
    for n in gcc cc g++ c++ aarch64-redhat-linux-gcc aarch64-redhat-linux-g++ aarch64-redhat-linux-c++; do
        ln -sf wrapper "$n"; done
    # ccache hands distcc the absolute compiler path (/usr/bin/gcc); this
    # server has no native compiler, so those paths are the cross wrapper too.
    for n in gcc cc g++ c++ aarch64-redhat-linux-gcc aarch64-redhat-linux-g++ aarch64-redhat-linux-c++; do
        ln -sf /usr/local/libexec/duo2-cross/wrapper "/usr/bin/$n"; done'
docker exec "$SERVER" sh -c 'pkill -x distccd; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x distccd >/dev/null || break; sleep 1; done
    DISTCCD_PATH=/usr/local/libexec/duo2-cross distccd --daemon --enable-tcp-insecure \
        --allow 172.16.0.0/12 --listen 0.0.0.0 --jobs "$(nproc)" --log-file /tmp/distccd.log --log-level info'

addr="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$SERVER")"
jobs="$(docker exec "$SERVER" nproc)"
for c in "${CLIENTS[@]}"; do
    docker container inspect "$c" >/dev/null 2>&1 || continue
    docker exec "$c" sh -c 'command -v distcc >/dev/null || dnf -y -q install distcc >/dev/null 2>&1 || dnf5 -y -q install distcc >/dev/null'
    # Luma's builder runs with PATH=/usr/local/bin:/usr/bin, without Fedora's
    # /usr/lib64/ccache: put the ccache compiler names first on that PATH.
    docker exec "$c" sh -c 'command -v ccache >/dev/null || dnf -y -q install ccache >/dev/null 2>&1 || dnf5 -y -q install ccache >/dev/null
        for n in gcc cc g++ c++ aarch64-redhat-linux-gcc aarch64-redhat-linux-g++ aarch64-redhat-linux-c++; do
            ln -sf /usr/bin/ccache "/usr/local/bin/$n"; done
        printf "cache_dir = /var/cache/ccache\nmax_size = 20G\ncompiler_check = content\n" > /etc/ccache.conf'
    # distcc keeps any compile that names a -specs file local. Fedora names
    # two on every compile: redhat-hardened-cc1, which only adds -fPIE when
    # no other PIC/PIE option (or -r) is given -- stated here instead, same
    # code -- and redhat-annobin-cc1, the annobin plugin, dropped as above.
    docker exec -i "$c" sh -c 'cat > /usr/local/libexec/duo2-distcc && chmod 755 /usr/local/libexec/duo2-distcc' <<'WRAP'
#!/bin/sh
pie=1
for a in "$@"; do
    case "$a" in -r|-fpie|-fPIE|-fpic|-fPIC|-fno-pic) pie=0 ;; esac
done
first=1
for a in "$@"; do
    [ "$first" = 1 ] && { set --; first=0; }
    case "$a" in
        -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1) ;;
        -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1) [ "$pie" = 1 ] && set -- "$@" -fPIE ;;
        *) set -- "$@" "$a" ;;
    esac
done
# A remote failure falls back locally either way; do not stop using the
# server for every other compile.
export DISTCC_BACKOFF_PERIOD=0
exec /usr/bin/distcc "$@"
WRAP
    docker exec "$c" sh -c "mkdir -p /etc/distcc && echo '$addr/$jobs,lzo' > /etc/distcc/hosts &&
        grep -q '^prefix_command' /etc/ccache.conf 2>/dev/null &&
            sed -i 's|^prefix_command.*|prefix_command = /usr/local/libexec/duo2-distcc|' /etc/ccache.conf ||
            echo 'prefix_command = /usr/local/libexec/duo2-distcc' >> /etc/ccache.conf"
done
# A failed attempt makes the clients back off from the server for a while;
# forget any from before this (re)start.
for c in "${CLIENTS[@]}"; do
    docker exec "$c" sh -c 'rm -f /tmp/luma-rpm-home/.distcc/lock/backoff_* "$HOME"/.distcc/lock/backoff_*' 2>/dev/null || true
done
info "distcc: $SERVER at $addr ($jobs jobs), used by ${CLIENTS[*]}"
