#!/bin/bash
# Print SLURM job status for the configured user. Read-only.
#
# Usage:
#   bash hpc_status.sh [-c hpc.env]            # your whole queue
#   bash hpc_status.sh [-c hpc.env] <jobid>    # one job; falls back to sacct if it has finished
set -euo pipefail
. "$(dirname "$0")/_hpc_lib.sh"
if [ "${1:-}" = "-c" ] || [ "${1:-}" = "--config" ]; then
    [ -n "${2:-}" ] || hpc_die "$1 needs a path to an hpc.env file"
    export HPC_CONFIG="$2"; shift 2
fi
hpc_load_config

fmt='%.10i %.24j %.12P %.8T %.10M %.10L %R'
if [ "$#" -ge 1 ]; then
    # A jobid is interpolated into the remote squeue command, so it must be
    # numeric (optionally N_M for an array task) — never arbitrary shell.
    case "$1" in
        ''|*[!0-9_]*) hpc_die "jobid must be numeric (optionally N_M for an array task): $1" ;;
    esac
    jobid="$1"
    rc=0
    out="$(ssh "$HPC_HOST" "squeue -j $jobid --format=\"$fmt\"" 2>&1)" || rc=$?
    printf '%s\n' "$out"
    # squeue only lists pending/running jobs. If this jobid is not among them
    # (it has finished, or never existed) squeue prints just a header — which
    # reads as "did it even run?". Fall back to sacct for the final state.
    rows="$(printf '%s\n' "$out" | tail -n +2 | grep -c '[0-9]' || true)"
    if [ "$rc" -ne 0 ] || [ "$rows" -eq 0 ]; then
        echo
        echo "(job $jobid is not in the live queue — final accounting from sacct:)"
        sfmt='JobID%15,JobName%18,State%14,Elapsed,MaxRSS,ReqMem,ExitCode'
        ssh "$HPC_HOST" "sacct -j $jobid --format=$sfmt" \
            || echo "  (sacct returned nothing — accounting may be disabled, or try: ssh $HPC_HOST jobinfo $jobid)"
        rc=0   # a finished job is not an error condition
    fi
    hpc_audit ssh_command --host "$HPC_HOST" --command "squeue/sacct -j $jobid" --exit "$rc"
    exit "$rc"
fi

user="${HPC_USER:-$(ssh "$HPC_HOST" whoami)}"
hpc_reject_unsafe "$user" "HPC_USER"
rc=0
ssh "$HPC_HOST" "squeue -u $user --format=\"$fmt\"" || rc=$?
hpc_audit ssh_command --host "$HPC_HOST" --command "squeue -u $user" --exit "$rc"
exit "$rc"
