#!/bin/bash
# Watch a SLURM job until it reaches a terminal state, then report the final
# state + exit code. Read-only: it only runs squeue/sacct, never writes.
#
# Usage:
#   bash hpc_watch.sh [-c hpc.env] [-i seconds] [-w max-seconds] <jobid>
#
#   -c, --config    path to an hpc.env (else the usual walk-up search)
#   -i, --interval  seconds between polls           (default $HPC_WATCH_INTERVAL or 60; min 5)
#   -w, --max-wait  give up after this many seconds  (default $HPC_WATCH_MAX_WAIT or 0 = never)
#
# Meant to be run as a BACKGROUND task in Claude Code, so it can notify the
# session when the job finishes:
#   (in Claude Code) run this with run_in_background — it returns when the job
#   reaches COMPLETED/FAILED/CANCELLED/TIMEOUT/… and prints a one-line verdict.
#
# How it honors the safety rules (see reference/safety.md):
#   * The wait `sleep`s LOCALLY between short remote probes (rule 8) — a SIGTERM
#     during the sleep never lands mid-ssh, so it can't tear down the shared
#     ControlMaster socket.
#   * Probes use `-o BatchMode=yes` so a dead/expired socket fails FAST (exit
#     255) instead of hanging on an OTP prompt the assistant cannot answer; it
#     then tells you to re-run hpc_login.sh rather than spinning forever.
#
# Exit codes (part of the report):
#   0  job COMPLETED
#   1  job reached a non-success terminal state (FAILED/CANCELLED/TIMEOUT/…)
#   2  gave up: max-wait exceeded, socket lost, or sacct reported no state
set -euo pipefail
. "$(dirname "$0")/_hpc_lib.sh"

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

interval="${HPC_WATCH_INTERVAL:-60}"
max_wait="${HPC_WATCH_MAX_WAIT:-0}"
jobid=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -c|--config)   [ -n "${2:-}" ] || hpc_die "$1 needs a path to an hpc.env file"; export HPC_CONFIG="$2"; shift 2 ;;
        -i|--interval) [ -n "${2:-}" ] || hpc_die "$1 needs a value in seconds"; interval="$2"; shift 2 ;;
        -w|--max-wait) [ -n "${2:-}" ] || hpc_die "$1 needs a value in seconds"; max_wait="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        -*)            hpc_die "unknown option: $1 (see -h)" ;;
        *)             [ -z "$jobid" ] || hpc_die "unexpected extra argument: $1"; jobid="$1"; shift ;;
    esac
done

[ -n "$jobid" ] || hpc_die "usage: bash hpc_watch.sh [-c hpc.env] [-i seconds] [-w max-seconds] <jobid>"
# jobid is interpolated into the remote squeue/sacct command, so it must be
# numeric (optionally N_M for an array task) — never arbitrary shell.
case "$jobid"   in ''|*[!0-9_]*) hpc_die "jobid must be numeric (optionally N_M for an array task): $jobid" ;; esac
case "$interval" in ''|*[!0-9]*) hpc_die "interval must be a positive integer (seconds): $interval" ;; esac
[ "$interval" -ge 5 ] || hpc_die "interval must be >= 5s so the watcher doesn't hammer the login node: $interval"
case "$max_wait" in ''|*[!0-9]*) hpc_die "max-wait must be a non-negative integer (seconds; 0 = never give up): $max_wait" ;; esac

hpc_load_config

# Reuse the multiplexed session; never open a new connection that would prompt.
SSH=(ssh -o BatchMode=yes "$HPC_HOST")
# Preflight: confirm we can reach the host without a prompt. Prefer the master
# socket check; fall back to a batch-mode probe for prompt-free (key) auth.
if ! ssh -O check "$HPC_HOST" >/dev/null 2>&1; then
    if ! "${SSH[@]}" true >/dev/null 2>&1; then
        hpc_die "cannot reach $HPC_HOST without a prompt — run 'bash hpc_login.sh' first (you type the OTP), then start the watch."
    fi
fi

hpc_audit watch_start --host "$HPC_HOST" --jobid "$jobid" --interval "$interval"

gaveup=""
[ "$max_wait" -gt 0 ] && gaveup=", giving up after ${max_wait}s"
echo "watching job $jobid on $HPC_HOST (poll every ${interval}s${gaveup}) — Ctrl-C or stop the task to detach."

fails=0
MAX_FAILS=3
last_state=""
while :; do
    if [ "$max_wait" -gt 0 ] && [ "$SECONDS" -ge "$max_wait" ]; then
        echo "hpc: gave up after ${SECONDS}s (max-wait ${max_wait}s) — job $jobid is still active." >&2
        hpc_audit watch_end --host "$HPC_HOST" --jobid "$jobid" --state gave_up --code 0
        exit 2
    fi

    out=""; rc=0
    out="$("${SSH[@]}" "squeue -h -j $jobid -o '%i %T'" 2>/dev/null)" || rc=$?

    if [ "$rc" -eq 255 ]; then
        # ssh transport failure (socket expired / host down), not a job verdict.
        fails=$((fails + 1))
        if [ "$fails" -ge "$MAX_FAILS" ]; then
            echo "hpc: lost the SSH connection to $HPC_HOST ($fails failed probes) — the socket likely expired." >&2
            echo "     re-run 'bash hpc_login.sh' (you type the OTP) and start the watch again." >&2
            hpc_audit watch_end --host "$HPC_HOST" --jobid "$jobid" --state connection_lost --code 0
            exit 2
        fi
        sleep "$interval"
        continue
    fi
    fails=0

    if [ -n "$out" ]; then
        # Still listed by squeue => still pending/running/completing. squeue only
        # shows active jobs, so its mere presence means "not done yet".
        state="$(printf '%s\n' "$out" | awk '{print $2}' | sort -u | paste -sd, -)"
        [ -n "$state" ] || state="ACTIVE"
        if [ "$state" != "$last_state" ]; then
            printf '  [%5ds] %s\n' "$SECONDS" "$state"
            last_state="$state"
        fi
        sleep "$interval"
        continue
    fi

    # Gone from the live queue => terminal. Fall through to final accounting.
    break
done

echo "job $jobid left the queue after ${SECONDS}s — final accounting:"
sfmt='JobID%15,JobName%18,State%14,Elapsed,MaxRSS,ReqMem,ExitCode'
"${SSH[@]}" "sacct -j $jobid --format=$sfmt" || true

# Parse a machine-readable verdict for the exit code + audit line. -X gives one
# row per job (not the .batch/.extern steps); -P is '|'-delimited; -n drops the
# header. State can read "CANCELLED by <uid>", so match on the first word.
parsed=""
parsed="$("${SSH[@]}" "sacct -j $jobid -X -n -P -o State,ExitCode" 2>/dev/null)" || true

overall="UNKNOWN"
worst_exit=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    st="${line%%|*}"; st="${st%% *}"       # "CANCELLED by 42|0:0" -> "CANCELLED"
    codes="${line#*|}"; ec="${codes%%:*}"  # "0:0" -> "0"
    case "$ec" in ''|*[!0-9]*) ec=0 ;; esac
    if [ "$ec" -gt "$worst_exit" ]; then worst_exit="$ec"; fi
    case "$st" in
        COMPLETED) if [ "$overall" = UNKNOWN ]; then overall=COMPLETED; fi ;;
        *)         overall="$st" ;;            # any non-COMPLETED terminal state wins
    esac
done <<EOF
$parsed
EOF

case "$overall" in
    COMPLETED)
        echo "job $jobid: COMPLETED (exit $worst_exit)."
        hpc_audit watch_end --host "$HPC_HOST" --jobid "$jobid" --state COMPLETED --code "$worst_exit"
        exit 0 ;;
    UNKNOWN)
        echo "hpc: job $jobid is no longer queued, but sacct returned no state" >&2
        echo "     (accounting may be disabled, or the id aged out). Try: ssh $HPC_HOST jobinfo $jobid" >&2
        hpc_audit watch_end --host "$HPC_HOST" --jobid "$jobid" --state unknown --code 0
        exit 2 ;;
    *)
        echo "job $jobid: $overall (exit $worst_exit)." >&2
        hpc_audit watch_end --host "$HPC_HOST" --jobid "$jobid" --state "$overall" --code "$worst_exit"
        exit 1 ;;
esac
