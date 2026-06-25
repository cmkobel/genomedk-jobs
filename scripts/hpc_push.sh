#!/bin/bash
# rsync local files/dirs UP to the HPC project root. Never uses --delete, so
# remote resume checkpoints and prior outputs are preserved. It DOES overwrite
# remote files whose local copy differs — use --dry-run first if unsure, and set
# HPC_PUSH_BACKUP=1 to keep overwritten copies under $HPC_REMOTE_ROOT/.hpc_backups.
#
# Usage:
#   bash hpc_push.sh [-c hpc.env] [--dry-run]                   # push HPC_PUSH_PATHS -> $HPC_REMOTE_ROOT/$HPC_CODE_SUBDIR
#   bash hpc_push.sh [-c hpc.env] [--dry-run] <local>... <dest> # push given local paths -> $HPC_REMOTE_ROOT/<dest>
#
# <dest> is interpreted relative to HPC_REMOTE_ROOT and is guarded against
# escaping it. --dry-run, if given, must be the first argument.
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
    echo "(dry run — no files will be transferred)"
fi

EXCLUDES=(--exclude=.git/ --exclude=__pycache__/ --exclude=.pixi/
          --exclude=.ipynb_checkpoints/ --exclude='*.ipynb' --exclude=.DS_Store)

locals=()
if [ "$#" -eq 0 ]; then
    : "${HPC_PUSH_PATHS:?no args given and HPC_PUSH_PATHS is unset}"
    read -r -a rels <<< "$HPC_PUSH_PATHS"
    for p in ${rels[@]+"${rels[@]}"}; do locals+=("$HPC_LOCAL_ROOT/$p"); done
    dest="$HPC_CODE_SUBDIR"
elif [ "$#" -eq 1 ]; then
    hpc_die "usage: bash hpc_push.sh [--dry-run] <local>... <dest-relative-to-remote-root>"
else
    dest="${*: -1}"
    locals=("${@:1:$#-1}")
fi

remote="$HPC_REMOTE_ROOT/$dest"
hpc_guard_remote "$remote"
hpc_verify_root          # confirm the root is really ours before writing

# Optional: keep recoverable copies of anything this push overwrites.
backup=()
if [ "${HPC_PUSH_BACKUP:-0}" = 1 ]; then
    bdir="$HPC_REMOTE_ROOT/.hpc_backups/$(date +%Y%m%dT%H%M%S)"
    hpc_guard_remote "$bdir"
    backup=(--backup --backup-dir="$bdir")
fi

if [ "${#DRY[@]}" -eq 0 ]; then
    ssh "$HPC_HOST" "mkdir -p '$remote'"
fi
rc=0
rsync -azP ${DRY[@]+"${DRY[@]}"} ${backup[@]+"${backup[@]}"} "${EXCLUDES[@]}" "${locals[@]}" "$HPC_HOST:$remote/" || rc=$?
hpc_audit rsync_push --host "$HPC_HOST" --target "$remote/" --dry "${#DRY[@]}" --exit "$rc"
[ "$rc" -eq 0 ] || hpc_die "rsync push failed (rc=$rc)"
echo "pushed -> $HPC_HOST:$remote/"
