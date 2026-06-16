#!/bin/bash
# Print the current SLURM queue for the configured user. Read-only.
#
# Usage:
#   bash hpc_status.sh            # your whole queue
#   bash hpc_status.sh <jobid>    # one job
set -euo pipefail
. "$(dirname "$0")/_hpc_lib.sh"
hpc_load_config

fmt='%.10i %.24j %.12P %.8T %.10M %.10L %R'
if [ "$#" -ge 1 ]; then
    # A jobid is interpolated into the remote squeue command, so it must be
    # numeric (optionally N_M for an array task) — never arbitrary shell.
    case "$1" in
        ''|*[!0-9_]*) hpc_die "jobid must be numeric (optionally N_M for an array task): $1" ;;
    esac
    query="squeue -j $1 --format=\"$fmt\""
    desc="squeue -j $1"
else
    user="${HPC_USER:-$(ssh "$HPC_HOST" whoami)}"
    hpc_reject_unsafe "$user" "HPC_USER"
    query="squeue -u $user --format=\"$fmt\""
    desc="squeue -u $user"
fi

rc=0
ssh "$HPC_HOST" "$query" || rc=$?
hpc_audit ssh_command --host "$HPC_HOST" --command "$desc" --exit "$rc"
exit "$rc"
