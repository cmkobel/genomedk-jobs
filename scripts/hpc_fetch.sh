#!/bin/bash
# rsync a path DOWN from the HPC project root to the local machine. Never uses
# --delete.
#
# Usage:
#   bash hpc_fetch.sh [-c hpc.env] [--dry-run] <remote-subpath> [local-dest]
#
# <remote-subpath> is relative to HPC_REMOTE_ROOT and guarded against escaping
# it. A trailing slash on it copies directory contents (standard rsync rules).
# --dry-run (first arg) previews the transfer without writing anything locally.
#
# WHERE IT LANDS. With no <local-dest>, the fetch MIRRORS the remote subpath
# under HPC_LOCAL_ROOT: `hpc_fetch.sh repo/conf` puts the directory at
# $HPC_LOCAL_ROOT/repo/conf. Note that this is the reverse of hpc_push.sh, which
# keeps only a source's basename — a fetch preserves the path, a push does not.
# Getting there takes one step of indirection, because rsync places a source
# INSIDE its destination: to land at $HPC_LOCAL_ROOT/<sub> the destination passed
# to rsync must be the PARENT of <sub> (passing $HPC_LOCAL_ROOT/<sub> itself
# nests the last component twice — repo/conf/conf, which is what this used to
# do). A trailing slash means "the contents of", so then <sub> itself is the
# destination. The resolved landing path is printed either way.
#
# An explicit <local-dest> is passed to rsync verbatim, so rsync's own rules
# apply: a directory source lands INSIDE it (`hpc_fetch.sh repo/conf out` gives
# out/conf), while a single file source names it.
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
hpc_require_socket   # fail fast if the socket is down (rsync -n still connects), rather than prompting

DRY=()
if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ]; then
    DRY=(-n); shift
    echo "(dry run — nothing will be written locally)"
fi

[ "$#" -ge 1 ] || hpc_die "usage: bash hpc_fetch.sh [--dry-run] <remote-subpath> [local-dest]"
sub="$1"
remote="$HPC_REMOTE_ROOT/$sub"
hpc_guard_remote "$remote"

# Resolve the destination, and separately the path the files actually land at, so
# what gets reported is where to look rather than what rsync was handed (with the
# default those two differ by one level — see WHERE IT LANDS above).
if [ "$#" -ge 2 ]; then
    # Given explicitly: pass it to rsync verbatim and report it as the DESTINATION
    # rather than as a landing path. Whether a directory source lands inside it or
    # names it is rsync's rule to apply, and telling the two apart would take an
    # extra round trip to stat the remote path — so don't claim to know.
    local_dest="$2"
    landing="$2"
    mkdir -p "$(dirname "$local_dest")"
else
    landing="$HPC_LOCAL_ROOT/$sub"
    case "$sub" in
        */) local_dest="$HPC_LOCAL_ROOT/$sub" ;;             # contents of <sub> -> <sub>
        *)  local_dest="$HPC_LOCAL_ROOT/$(dirname "$sub")" ;; # <sub> itself -> its parent
    esac
    # The destination must exist as a DIRECTORY before the transfer: rsync treats
    # a nonexistent destination as a filename when the source is a single file,
    # which would otherwise turn `fetch repo/src/mod.py` into a file named src.
    mkdir -p "$local_dest"
    # Only the resolved default gets a mapping line, since it is the one the
    # caller did not write down and cannot otherwise predict.
    echo "fetch mapping: $HPC_HOST:$remote -> $landing"
fi

rc=0
# `--` terminates rsync options (see hpc_push.sh) so no path can inject one.
hpc_rsync -azP ${DRY[@]+"${DRY[@]}"} -- "$HPC_HOST:$remote" "$local_dest" || rc=$?
hpc_audit rsync_pull --host "$HPC_HOST" --target "$sub" --dry "${#DRY[@]}" --exit "$rc"

# Bring the SLURM-side audit log down too (independent of the fetch above).
hpc_merge_remote_audit

[ "$rc" -eq 0 ] || hpc_die "rsync pull failed (rc=$rc)"
echo "fetched $HPC_HOST:$remote -> $landing"
