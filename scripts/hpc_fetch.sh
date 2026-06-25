#!/bin/bash
# rsync a path DOWN from the HPC project root to the local machine. Never uses
# --delete.
#
# Usage:
#   bash hpc_fetch.sh [-c hpc.env] [--dry-run] <remote-subpath> [local-dest]
#
# <remote-subpath> is relative to HPC_REMOTE_ROOT and guarded against escaping
# it. <local-dest> defaults to $HPC_LOCAL_ROOT/<remote-subpath>. A trailing
# slash on <remote-subpath> copies directory contents (standard rsync rules).
# --dry-run (first arg) previews the transfer without writing anything locally.
#
# Also merges the SLURM-side audit.remote.log into the local audit log so
# job_start/job_end events show up alongside the rest.
set -euo pipefail
. "$(dirname "$0")/_hpc_lib.sh"
if [ "${1:-}" = "-c" ] || [ "${1:-}" = "--config" ]; then
    [ -n "${2:-}" ] || hpc_die "$1 needs a path to an hpc.env file"
    export HPC_CONFIG="$2"; shift 2
fi
hpc_load_config

DRY=()
if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ]; then
    DRY=(-n); shift
    echo "(dry run — nothing will be written locally)"
fi

[ "$#" -ge 1 ] || hpc_die "usage: bash hpc_fetch.sh [--dry-run] <remote-subpath> [local-dest]"
sub="$1"
remote="$HPC_REMOTE_ROOT/$sub"
hpc_guard_remote "$remote"

local_dest="${2:-$HPC_LOCAL_ROOT/$sub}"
mkdir -p "$(dirname "$local_dest")"

rc=0
rsync -azP ${DRY[@]+"${DRY[@]}"} "$HPC_HOST:$remote" "$local_dest" || rc=$?
hpc_audit rsync_pull --host "$HPC_HOST" --target "$sub" --dry "${#DRY[@]}" --exit "$rc"

# Bring the SLURM-side audit log down too (independent of the fetch above).
hpc_merge_remote_audit

[ "$rc" -eq 0 ] || hpc_die "rsync pull failed (rc=$rc)"
echo "fetched $HPC_HOST:$remote -> $local_dest"
