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
hpc_require_socket   # fail fast if the socket is down (rsync -n still connects), rather than prompting

DRY=()
if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ]; then
    DRY=(-n); shift
    echo "(dry run — no files will be transferred)"
fi

EXCLUDES=(--exclude=.git/ --exclude=__pycache__/ --exclude=.pixi/
          --exclude=.ipynb_checkpoints/ --exclude='*.ipynb' --exclude=.DS_Store)

locals=()
from_config=0
if [ "$#" -eq 0 ]; then
    : "${HPC_PUSH_PATHS:?no args given and HPC_PUSH_PATHS is unset}"
    from_config=1
    read -r -a rels <<< "$HPC_PUSH_PATHS"
    for p in ${rels[@]+"${rels[@]}"}; do locals+=("$HPC_LOCAL_ROOT/$p"); done
    dest="$HPC_CODE_SUBDIR"
elif [ "$#" -eq 1 ]; then
    hpc_die "usage: bash hpc_push.sh [--dry-run] <local>... <dest-relative-to-remote-root>"
else
    dest="${*: -1}"
    locals=("${@:1:$#-1}")
fi

# Preflight: every local source must exist. Left to rsync, a missing path is
# reported as exit 23 *after* the surviving paths have already transferred — so
# the wrapper would abort with "rsync push failed" on a push that in fact partly
# landed, and a later submit would run against half-synced code. Checking first
# makes it all-or-nothing with one actionable message.
#
# It doubles as the check for a misplaced config: HPC_PUSH_PATHS resolves against
# HPC_LOCAL_ROOT (the directory holding hpc.env unless overridden), so an hpc.env
# sitting somewhere other than the local project root shows up here as "every
# path is missing" rather than as a silently wrong transfer.
missing=()
for p in ${locals[@]+"${locals[@]}"}; do [ -e "$p" ] || missing+=("$p"); done
if [ "${#missing[@]}" -ne 0 ] && [ "${HPC_PUSH_ALLOW_MISSING:-0}" != 1 ]; then
    {
        echo "hpc: refusing to push — local path(s) do not exist:"
        for p in ${missing[@]+"${missing[@]}"}; do echo "         $p"; done
        if [ "$from_config" = 1 ]; then
            echo "     HPC_PUSH_PATHS is resolved against the local root:"
            echo "         local root : $HPC_LOCAL_ROOT"
            echo "         config     : ${HPC_CONFIG:-?}"
            echo "         paths      : $HPC_PUSH_PATHS"
            echo "     If the local root is wrong, move hpc.env to your project root or set"
            echo "     HPC_LOCAL_ROOT (in hpc.env, or in the environment) to point at it."
            echo "     If a listed file is simply not generated yet (e.g. pixi.lock — run"
            echo "     'pixi lock'), create it or drop it from HPC_PUSH_PATHS."
        fi
        echo "     To push the paths that do exist anyway: HPC_PUSH_ALLOW_MISSING=1"
    } >&2
    hpc_audit rsync_push --host "$HPC_HOST" --target "(preflight)" --dry "${#DRY[@]}" --exit 1
    exit 1
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
# `--` terminates rsync options, so a source path beginning with '-' (e.g. a file
# literally named --delete, or a glob that expands to one) is treated as a PATH,
# never an option — keeping the "never --delete" invariant intact for odd paths.
rsync -azP ${DRY[@]+"${DRY[@]}"} ${backup[@]+"${backup[@]}"} "${EXCLUDES[@]}" -- "${locals[@]}" "$HPC_HOST:$remote/" || rc=$?
hpc_audit rsync_push --host "$HPC_HOST" --target "$remote/" --dry "${#DRY[@]}" --exit "$rc"
[ "$rc" -eq 0 ] || hpc_die "rsync push failed (rc=$rc)"
# Name the local root, not just the remote target: it is the one input to a push
# that is inferred rather than given, so showing it makes a wrong one obvious.
if [ "$from_config" = 1 ]; then
    echo "pushed $HPC_LOCAL_ROOT -> $HPC_HOST:$remote/"
else
    echo "pushed -> $HPC_HOST:$remote/"
fi
