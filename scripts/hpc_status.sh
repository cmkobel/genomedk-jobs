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
    query="squeue -j $1 --format=\"$fmt\""
    desc="squeue -j $1"
else
    user="${HPC_USER:-$(ssh "$HPC_HOST" whoami)}"
    query="squeue -u $user --format=\"$fmt\""
    desc="squeue -u $user"
fi

rc=0
ssh "$HPC_HOST" "$query" || rc=$?
hpc_audit ssh_command --host "$HPC_HOST" --command "$desc" --exit "$rc"
exit "$rc"
