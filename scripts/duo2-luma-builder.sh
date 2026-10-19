#!/usr/bin/env bash
# Build Luma's own packages for the Duo 2, with Luma's own builder scripts.
#
# Luma's package builders expect to run on (or inside) a Fedora 44 AArch64
# builder: some run rpmbuild directly and check uname -m, others wrap
# themselves in a pinned Fedora container through podman and offer a direct
# mode for when they already are on the builder. This workstation is x86_64
# with Docker, so the builder is one persistent Fedora 44 arm64 container
# under qemu-user emulation, created from the exact image Luma pins
# (FEDORA_RPM_BUILD_CONTAINER_AARCH64 in config/desktop/inputs.env), with the
# Luma tree mounted at /luma. Builders that expect to be on the aarch64
# builder run inside it, with each spec's BuildRequires from dnf builddep.
# Builders that wrap themselves in Luma's pinned container through podman
# run on the host with tools/podman-docker first on PATH. Either way Luma's
# scripts run unchanged.
# Output lands where Luma's rootfs compose looks: luma/build/packages/, and
# each result is installed into the builder for the packages that follow.
#
# Usage: duo2-luma-builder.sh BUILDER [BUILDER ...]
#   BUILDER is a script name under luma/scripts/packages/, e.g. build-luma-phoc.sh,
#   or a path under luma/scripts/, e.g. mobile/build-luma-keyboard-fp6.sh
#   duo2-luma-builder.sh --shell      interactive shell in the builder

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

LUMA="$(cd "${LUMA_DUO2_LUMA_TREE:-$LUMA_DUO2_ROOT/../luma}" && pwd)"
NAME="${LUMA_DUO2_BUILDER_NAME:-luma-duo2-builder}"
LOGS="$LUMA_DUO2_ROOT/logs/luma-packages"
# shellcheck disable=SC1091
IMAGE="$(. "$LUMA/config/desktop/inputs.env" && echo "$FEDORA_RPM_BUILD_CONTAINER_AARCH64")"
[ -n "$IMAGE" ] || die "no FEDORA_RPM_BUILD_CONTAINER_AARCH64 in Luma's inputs.env"

if ! docker container inspect "$NAME" >/dev/null 2>&1; then
    info "creating builder $NAME from $IMAGE (arm64)"
    docker run --detach --init --platform linux/arm64 --name "$NAME" \
        --hostname luma-rpm-builder -v "$LUMA:/luma" \
        --env HOME=/tmp/luma-rpm-home --env LUMA_RPM_BUILDER_DIRECT=1 \
        "$IMAGE" sleep infinity >/dev/null
    # Beyond rpm-build: tools Luma's FP6 builder has that some builders call
    # outside rpmbuild, so their specs do not pull them in (greetd-session
    # runs cargo itself and links PAM).
    docker exec "$NAME" bash -c 'dnf -y -q install rpm-build dnf-plugins-core \
        git curl tar xz bzip2 patch which findutils diffutils make \
        cargo rust pam-devel >/dev/null'
fi
[ "$(docker inspect --format '{{.State.Running}}' "$NAME")" = true ] || docker start "$NAME" >/dev/null

# The Fedora x86_64 host Luma's wrapped builders expect, from Luma's pinned
# x86_64 image. Luma's tree and this repository are mounted at the same
# paths as on this machine, and the Docker socket and CLI are passed in, so
# the volume paths those builders give "podman" mean the same thing to the
# real Docker daemon.
HOSTNAME_C="${LUMA_DUO2_HOST_NAME:-luma-duo2-host}"
ensure_host_container() {
    local img
    # shellcheck disable=SC1091
    img="$(. "$LUMA/config/desktop/inputs.env" && echo "$FEDORA_RPM_BUILD_CONTAINER")"
    if ! docker container inspect "$HOSTNAME_C" >/dev/null 2>&1; then
        info "creating Fedora x86_64 host $HOSTNAME_C from $img"
        docker run --detach --init --platform linux/amd64 --name "$HOSTNAME_C" \
            -v "$LUMA:$LUMA" -v "$LUMA_DUO2_ROOT:$LUMA_DUO2_ROOT:ro" \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v "$(command -v docker):/usr/local/bin/docker:ro" \
            "$img" sleep infinity >/dev/null
        docker exec "$HOSTNAME_C" bash -c 'dnf -y -q install rpm cpio rpm-build \
            dnf5-plugins git curl patch tar xz zstd findutils diffutils >/dev/null'
    fi
    [ "$(docker inspect --format '{{.State.Running}}' "$HOSTNAME_C")" = true ] \
        || docker start "$HOSTNAME_C" >/dev/null
}

if [ "${1:-}" = "--shell" ]; then
    exec docker exec -it -w /luma "$NAME" bash
fi
[ $# -gt 0 ] || die "usage: duo2-luma-builder.sh BUILDER [BUILDER ...]"

# Defects found in the Luma tree itself, kept as patches in luma-fixes/ and
# applied to the checkout before building. Already-applied fixes are skipped.
for fix in "$LUMA_DUO2_ROOT"/luma-fixes/*.patch; do
    [ -f "$fix" ] || continue
    if git -C "$LUMA" apply --check -R "$fix" 2>/dev/null; then continue; fi
    git -C "$LUMA" apply "$fix" || die "luma-fixes/$(basename "$fix") does not apply"
    info "applied luma-fixes/$(basename "$fix")"
done

# Lift the per-build job caps some Luma builders put on rpmbuild (see
# tools/rpmbuild-jobs/rpmbuild) in every builder container that exists.
install_jobs_shim() {
    local c
    for c in "$NAME" "${LUMA_DUO2_HOST_NAME:-luma-duo2-host}" luma-rpm-builder-f44 luma-rpm-builder-f44-x86; do
        docker container inspect "$c" >/dev/null 2>&1 || continue
        docker cp "$LUMA_DUO2_ROOT/tools/rpmbuild-jobs/rpmbuild" "$c:/usr/local/bin/rpmbuild" >/dev/null
        # The containers build as root in a checkout the workstation user
        # owns; builders that ask git about the tree need it trusted.
        docker exec "$c" sh -c "command -v git >/dev/null && git config --global --get-all safe.directory | grep -qx '*' || git config --global --add safe.directory '*'" >/dev/null 2>&1 || true
    done
}
install_jobs_shim
mkdir -p "$LOGS"

for builder in "$@"; do
    # "name.sh@x86_64" or "@aarch64" forces the target architecture.
    force_arch=""
    case "$builder" in *@*) force_arch="${builder#*@}"; builder="${builder%@*}" ;; esac
    case "$builder" in */*) rel="$builder" ;; *) rel="packages/$builder" ;; esac
    script="/luma/scripts/$rel"
    [ -f "$LUMA/scripts/$rel" ] || die "no $rel in Luma's scripts"
    install_jobs_shim
    log="$LOGS/${builder%.sh}.log"
    # The spec(s) a builder installs into SPECS/ -- their BuildRequires are
    # what dnf builddep needs to satisfy before rpmbuild can run.
    mapfile -t specs < <(grep -oE 'packaging/rpm/[A-Za-z0-9._+-]+\.spec' \
        "$LUMA/scripts/$rel" | sort -u)
    info "$builder: ${#specs[@]} spec(s): ${specs[*]##*/}  (log: ${log#$LUMA_DUO2_ROOT/})"
    start=$SECONDS
    stamp="$(mktemp)"   # RPMs newer than this were produced by this build
    # The builder, plus a shared builder it hands off to (build-luma-terminal.sh
    # execs build-luma-python-app.sh), decides how it runs.
    chain=("$LUMA/scripts/$rel")
    for next in $(grep -oE 'build-[a-z0-9-]+\.sh' "$LUMA/scripts/$rel" | sort -u); do
        [ -f "$LUMA/scripts/packages/$next" ] && chain+=("$LUMA/scripts/packages/$next")
    done
    if grep -q 'run-in-rpm-builder' "${chain[@]}"; then
        # Wraps itself in Luma's pinned builder container through podman,
        # from a Fedora x86_64 host (uname, rpm2cpio, dnf5). Run it in the
        # Fedora x86_64 "host" container, with the podman->docker shim first
        # on PATH talking to this machine's Docker.
        ensure_host_container
        mode="wrapped (Fedora x86_64 host -> Luma's pinned arm64 container)"
        # Builders that take LUMA_TARGET_ARCHITECTURE build for aarch64 in
        # Luma's pinned arm64 container; the rest are noarch and build in its
        # x86_64 one -- natively here, no emulation. They need separate
        # container names: Luma's wrapper rightly refuses to reuse a builder
        # made from a different image.
        # aarch64 for builders that can target it, unless forced otherwise or
        # the builder insists on an x86_64 machine (architecture-independent
        # packages Luma builds against its x86_64 developer platform).
        want=aarch64
        grep -q 'LUMA_TARGET_ARCHITECTURE' "${chain[@]}" || want=x86_64
        if grep -qE 'uname -m\)" = x86_64 \]' "$LUMA/scripts/$rel" &&
                ! grep -q 'LUMA_TARGET_ARCHITECTURE' "$LUMA/scripts/$rel"; then
            want=x86_64
        fi
        [ -n "$force_arch" ] && want="$force_arch"
        if [ "$want" = aarch64 ]; then
            target_env=(LUMA_TARGET_ARCHITECTURE=aarch64 LUMA_RPM_BUILDER_NAME=luma-rpm-builder-f44)
        else
            target_env=(LUMA_RPM_BUILDER_NAME=luma-rpm-builder-f44-x86)
            grep -q 'LUMA_TARGET_ARCHITECTURE' "${chain[@]}" && target_env+=(LUMA_TARGET_ARCHITECTURE=x86_64)
            mode="wrapped x86_64 (Fedora x86_64 host -> Luma's pinned x86_64 container)"
        fi
        run() { docker exec -w "$LUMA" "$HOSTNAME_C" env \
                    PATH="$LUMA_DUO2_ROOT/tools/podman-docker:/usr/local/bin:/usr/bin:/bin" \
                    "${target_env[@]}" \
                    bash "$LUMA/scripts/$rel"; }
    else
        # Expects to run on the aarch64 builder itself.
        mode="native (in $NAME)"
        run() { docker exec -w /luma "$NAME" bash -c '
                    set -euo pipefail
                    for s in "${@:2}"; do dnf -y -q builddep "$s"; done
                    bash "$1"
                    ' _ "$script" "${specs[@]}"; }
    fi
    info "$builder: $mode"
    # A wrapped build whose only failure is copying a stale aarch64 pin is
    # finished by duo2-collect-luma-rpms.sh (its output joins the log).
    stale_pin() {
        grep -qE "install: cannot stat '[^']*/RPMS/aarch64/[^']+\.rpm'" "$log" &&
            "$LUMA_DUO2_ROOT/scripts/duo2-collect-luma-rpms.sh" "${builder_pkg:-}" >> "$log" 2>&1
    }
    builder_pkg="$(grep -oE 'build/packages/[a-z0-9-]+' "$LUMA/scripts/$rel" | head -1 || true)"
    builder_pkg="${builder_pkg#build/packages/}"
    if run > "$log" 2>&1 || stale_pin; then
        info "$builder: built in $(( (SECONDS - start) / 60 )) min"
        # Luma's builders end by printing the SHA-256 and path of each RPM
        # they produced. Install those into the builder, so packages built
        # later compile against Luma's versions (its patched GTK, libadwaita,
        # libhandy, ...) rather than Fedora's.
        # Native builders print /luma/... paths, wrapped ones host paths;
        # both name files under Luma's build/packages, mounted at /luma.
        mapfile -t rpms < <(grep -oE '^[0-9a-f]{64}  [^ ]*build/packages/[^ ]+\.rpm$' \
            "$log" | awk '{print $2}' | grep -v '\.src\.rpm$' \
            | sed "s|^$LUMA/|/luma/|" | sort -u || true)
        # Some builders print no checksums, or print their dependencies'
        # too: take the RPMs this build actually wrote into a stable RPMS/
        # (or <arch>/RPMS/, or <arch>/) directory -- never a work tree.
        mapfile -t produced < <(find "$LUMA/build/packages" -path '*work*' -prune \
            -o -name '*.rpm' ! -name '*.src.rpm' ! -name '*-debug*' -newer "$stamp" -print 2>/dev/null \
            | sed "s|^$LUMA/|/luma/|" | sort)
        [ ${#produced[@]} -gt 0 ] && rpms=("${produced[@]}")
        rm -f "$stamp"
        for r in "${rpms[@]}"; do printf '    %s\n' "${r#/luma/}"; done
        # Later builds expect earlier results installed in their builder:
        # aarch64 and noarch RPMs in the arm64 one, x86_64 and noarch ones in
        # Luma's x86_64 container (at /build there rather than /luma/build).
        arm=() x86=()
        declare -A seen_rpm=()
        for r in "${rpms[@]}"; do
            # One copy of each package: a noarch RPM can be listed from both
            # an aarch64 and an x86_64 build directory.
            [ -n "${seen_rpm[${r##*/}]:-}" ] && continue
            seen_rpm[${r##*/}]=1
            case "$r" in
                *.aarch64.rpm) arm+=("$r") ;;
                *.x86_64.rpm) x86+=("${r/\/luma\/build\//\/build\/}") ;;
                *.noarch.rpm) arm+=("$r"); x86+=("${r/\/luma\/build\//\/build\/}") ;;
            esac
        done
        if [ ${#arm[@]} -gt 0 ]; then
            docker exec "$NAME" dnf -y -q install --allowerasing "${arm[@]}" >> "$log" 2>&1 \
                || warn "$builder: could not install its RPMs into the builder"
            if docker container inspect luma-rpm-builder-f44 >/dev/null 2>&1; then
                docker exec luma-rpm-builder-f44 dnf5 -y -q install --allowerasing \
                    "${arm[@]/\/luma\/build\//\/build\/}" >> "$log" 2>&1 \
                    || warn "$builder: could not install its RPMs into the arm64 builder"
            fi
        fi
        if [ ${#x86[@]} -gt 0 ] && docker container inspect luma-rpm-builder-f44-x86 >/dev/null 2>&1; then
            docker exec luma-rpm-builder-f44-x86 dnf5 -y -q install --allowerasing "${x86[@]}" >> "$log" 2>&1 \
                || warn "$builder: could not install its RPMs into the x86_64 builder"
        fi
    else
        warn "$builder: FAILED after $(( (SECONDS - start) / 60 )) min -- tail of $log:"
        tail -15 "$log" | sed 's/^/    /'
        exit 1
    fi
done
