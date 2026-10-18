#!/usr/bin/env bash
# Finish a Luma build whose only failure is a stale aarch64 pin.
#
# Luma's config/desktop/inputs.env pins each package's built NEVRA per
# architecture, and for some packages the aarch64 line has fallen behind the
# release the spec now produces: GTK 4 is pinned at 1.luma.14.preview1 for
# aarch64 but 1.luma.23.creator20261006.1 for x86_64, and the spec builds the
# latter. Those builders compile and package correctly, then fail at their
# last step, copying an RPM name that was never built.
#
# This performs that copy for them, using the release the x86_64 pin names
# (which is what the spec built) with the architecture swapped, exactly as the
# builder would: the main RPM, or every name-*.rpm for builders that ship the
# whole set (libadwaita, whose dependents need its -devel), plus the source
# RPM, then SHA256SUMS. It refuses if the expected RPM is not in the build.
#
# Usage: duo2-collect-luma-rpms.sh PACKAGE      e.g. gtk4, libadwaita

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

LUMA="$(cd "${LUMA_DUO2_LUMA_TREE:-$LUMA_DUO2_ROOT/../luma}" && pwd)"
HOST="${LUMA_DUO2_HOST_NAME:-luma-duo2-host}"
pkg="${1:?usage: duo2-collect-luma-rpms.sh PACKAGE}"
var="$(printf %s "$pkg" | tr '[:lower:]-' '[:upper:]_')"
# shellcheck disable=SC1091
. "$LUMA/config/desktop/inputs.env"
x86_var="${var}_NEVRA"; x86="${!x86_var:-}"
[ -n "$x86" ] || die "no $x86_var in Luma's inputs.env"
nvr="${x86%.x86_64}"; nvr="${nvr%.noarch}"
case "$pkg" in
    libadwaita) set_glob="$pkg-*.rpm" ;;   # builder ships the whole set
    *)          set_glob="$nvr.aarch64.rpm" ;;
esac

docker exec -w "$LUMA/build/packages/$pkg" "$HOST" bash -euo pipefail -c '
    nvr=$1 set_glob=$2
    work=$(ls -d work.* | tail -1)
    rpms=$work/rpmbuild/RPMS/aarch64
    [ -f "$rpms/$nvr.aarch64.rpm" ] || { echo "no $nvr.aarch64.rpm in $rpms" >&2; exit 1; }
    rm -rf RPMS/aarch64 SHA256SUMS; install -d RPMS/aarch64 SRPMS
    for f in $rpms/$set_glob; do
        case "$f" in *-debuginfo-*|*-debugsource-*) continue ;; esac
        install -m 0644 "$f" RPMS/aarch64/
    done
    install -m 0644 "$work/rpmbuild/SRPMS/$nvr.src.rpm" SRPMS/
    find RPMS SRPMS -type f -name "*.rpm" -exec sha256sum {} + | sort > SHA256SUMS
    sed "s|  |  $PWD/|" SHA256SUMS
' _ "$nvr" "$set_glob"
