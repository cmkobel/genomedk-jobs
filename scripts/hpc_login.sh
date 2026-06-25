#!/bin/bash
# Warm up the SSH ControlMaster socket to the cluster. Run once per session;
# the socket persists per ControlPersist in ~/.ssh/config (12 h on GenomeDK),
# and every subsequent ssh/rsync/scp reuses it and skips the OTP/SSO prompt.
#
# THE HUMAN TYPES THE OTP, NOT THE ASSISTANT. If a socket is already alive this
# exits immediately without prompting — always run it (or `ssh -O check`) before
# asking the user to authenticate.
#
# Usage: bash hpc_login.sh [-c hpc.env]
set -euo pipefail
. "$(dirname "$0")/_hpc_lib.sh"
if [ "${1:-}" = "-c" ] || [ "${1:-}" = "--config" ]; then
    [ -n "${2:-}" ] || hpc_die "$1 needs a path to an hpc.env file"
    export HPC_CONFIG="$2"; shift 2
fi
hpc_load_config
hpc_check_ssh_multiplexing || true   # warn-only; never blocks a login attempt

if ssh -O check "$HPC_HOST" 2>/dev/null; then
    echo "ssh master socket to $HPC_HOST already alive."
    hpc_audit hpc_login_reuse --host "$HPC_HOST" --exit 0
    exit 0
fi

echo "Opening ssh master socket to $HPC_HOST (type your OTP/credential at the prompt)..."
# `ssh -fN` backgrounds the client before authentication, which prevents the
# interactive OTP prompt from rendering. Run a no-op foreground command
# instead — it triggers auth, runs `true`, exits, and the multiplexed master
# socket persists per ControlPersist in ~/.ssh/config.
rc=0
ssh "$HPC_HOST" true || rc=$?
hpc_audit hpc_login_open --host "$HPC_HOST" --exit "$rc"
exit "$rc"
