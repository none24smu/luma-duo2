#!/usr/bin/env bash
# SSH into the booted Duo 2 over the USB network link (172.16.42.1).
#
# The interactive channel that does not depend on the serial console, whose
# receive side stops ~300 s into boot on this kernel. Uses the bring-up key
# in build/ssh/ and records no host key: the phone gets a new one with every
# reflash, and this is a point-to-point USB link to it.
#
# Usage: duo2-ssh.sh [command ...]      (no command: interactive shell)

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/duo2-env.sh"

KEY="${LUMA_DUO2_SSH_KEY:-$LUMA_DUO2_ROOT/../build/ssh/duo2_ed25519}"
HOST="${DUO2_SSH_HOST:-172.16.42.1}"
[ -f "$KEY" ] || die "no $KEY -- run duo2-mkuserdata.sh, which creates it"

exec ssh -i "$KEY" -o IdentitiesOnly=yes -o ConnectTimeout=5 \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no -o LogLevel=ERROR "root@$HOST" "$@"
