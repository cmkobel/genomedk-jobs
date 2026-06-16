#!/bin/bash
# rsync local files/dirs UP to the HPC project root. Never uses --delete, so
# remote resume checkpoints and prior outputs are preserved.
#
# Usage:
#   bash hpc_push.sh                      # push HPC_PUSH_PATHS -> $HPC_REMOTE_ROOT/$HPC_CODE_SUBDIR
#   bash hpc_push.sh <local>... <dest>    # push given local paths -> $HPC_REMOTE_ROOT/<dest>
#
# <dest> is interpreted relative to HPC_REMOTE_ROOT and is guarded against
# escaping it.
set -euo pipefail
. "$(dirname "$0")/_hpc_lib.sh"
hpc_load_config

EXCLUDES=(--exclude=.git/ --exclude=__pycache__/ --exclude=.pixi/
          --exclude=.ipynb_checkpoints/ --exclude='*.ipynb' --exclude=.DS_Store)

locals=()
if [ "$#" -eq 0 ]; then
    : "${HPC_PUSH_PATHS:?no args given and HPC_PUSH_PATHS is unset}"
    read -r -a rels <<< "$HPC_PUSH_PATHS"
    for p in "${rels[@]}"; do locals+=("$HPC_LOCAL_ROOT/$p"); done
    dest="$HPC_CODE_SUBDIR"
elif [ "$#" -eq 1 ]; then
    hpc_die "usage: bash hpc_push.sh <local>... <dest-relative-to-remote-root>"
else
    dest="${*: -1}"
    locals=("${@:1:$#-1}")
fi

remote="$HPC_REMOTE_ROOT/$dest"
hpc_guard_remote "$remote"

ssh "$HPC_HOST" "mkdir -p $remote"
rc=0
rsync -azP "${EXCLUDES[@]}" "${locals[@]}" "$HPC_HOST:$remote/" || rc=$?
hpc_audit rsync_push --host "$HPC_HOST" --target "$remote/" --exit "$rc"
[ "$rc" -eq 0 ] || hpc_die "rsync push failed (rc=$rc)"
echo "pushed -> $HPC_HOST:$remote/"
