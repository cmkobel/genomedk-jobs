#!/bin/bash
# rsync local files/dirs UP to the HPC project root. Never uses --delete, so
# remote resume checkpoints and prior outputs are preserved. It DOES overwrite
# remote files whose local copy differs — use --dry-run first if unsure, and set
# HPC_PUSH_BACKUP=1 to keep overwritten copies under $HPC_REMOTE_ROOT/.hpc_backups.
#
# Usage:
#   bash hpc_push.sh [-c hpc.env] [opts]                   # push HPC_PUSH_PATHS -> $HPC_REMOTE_ROOT/$HPC_CODE_SUBDIR
#   bash hpc_push.sh [-c hpc.env] [opts] <local>... <dest> # push given local paths -> $HPC_REMOTE_ROOT/<dest>
#
#   opts, in any order, before the source paths:
#     --dry-run, -n    report the transfer without writing anything remotely
#     --relative, -R   keep each source's directory components under <dest>
#                      (rsync -R). Opt-in; also settable per project with
#                      HPC_PUSH_RELATIVE=1 in hpc.env.
#
# WHERE THINGS LAND — both ends, because only one of them is obvious:
#
#   <dest> is interpreted relative to HPC_REMOTE_ROOT and guarded against
#   escaping it.
#
#   <local> is handed to rsync as given, so by DEFAULT only its BASENAME appears
#   remotely — the directory components are STRIPPED:
#       bash hpc_push.sh docs/2026-08-24_foo repo
#           ->  $HPC_REMOTE_ROOT/repo/2026-08-24_foo
#           NOT $HPC_REMOTE_ROOT/repo/docs/2026-08-24_foo
#   That is rsync's own rule and the default keeps it, because HPC_PUSH_PATHS and
#   existing callers depend on it. Note it is the opposite of hpc_fetch.sh, whose
#   local destination defaults to the remote subpath. Consequences:
#     * a top-level source is unaffected — its basename IS its relative path,
#       which is why HPC_PUSH_PATHS ("src scripts pixi.toml pixi.lock") behaves
#       as expected and nested entries do not;
#     * for a nested source, either name its directory in <dest>
#       (bash hpc_push.sh docs/foo repo/docs) or pass --relative;
#     * a trailing slash means "the contents of", so `docs/foo/` puts foo's
#       children directly in <dest> and foo's own name appears nowhere.
#   Every run prints the resolved local -> remote mapping (--dry-run included)
#   and warns when a directory component is about to be dropped, so a wrong
#   landing spot is visible at push time instead of surfacing later as a
#   FileNotFoundError inside a job that has already queued.
set -euo pipefail
. "$(dirname "$0")/_hpc_lib.sh"
if [ "${1:-}" = "-c" ] || [ "${1:-}" = "--config" ]; then
    [ -n "${2:-}" ] || hpc_die "$1 needs a path to an hpc.env file"
    export HPC_CONFIG="$2"; shift 2
fi
hpc_load_config
hpc_require_socket   # fail fast if the socket is down (rsync -n still connects), rather than prompting

# Leading options, in any order. Only these exact strings are consumed; anything
# else starting with '-' falls through and is treated as a source PATH, so a
# local file genuinely named "--delete" stays pushable (see the '--' note at the
# rsync call).
DRY=()
relative=0
if [ "${HPC_PUSH_RELATIVE:-0}" = 1 ]; then relative=1; fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run|-n)  DRY=(-n); shift ;;
        --relative|-R) relative=1; shift ;;
        *) break ;;
    esac
done
if [ "${#DRY[@]}" -ne 0 ]; then echo "(dry run — no files will be transferred)"; fi

EXCLUDES=(--exclude=.git/ --exclude=__pycache__/ --exclude=.pixi/
          --exclude=.ipynb_checkpoints/ --exclude='*.ipynb' --exclude=.DS_Store)

REL=()
if [ "$relative" = 1 ]; then REL=(-R); fi

# Two views of each source, because rsync and the human need different ones:
#   locals[] — exactly what rsync receives (and what must exist on disk);
#   names[]  — the caller-facing path, i.e. the argument as typed or the
#              HPC_PUSH_PATHS entry as written. That is the path whose directory
#              component the mapping and the warning below reason about.
# rsync_cwd is set only for a --relative config push: rsync -R replicates the
# source path *as given*, so the sources must be relative to HPC_LOCAL_ROOT
# rather than absolute — otherwise "src" would land as repo/Users/you/proj/src.
# rsync's /./ anchor marker would express that in one absolute path, but macOS
# ships openrsync as /usr/bin/rsync and openrsync ignores /./ silently, so cd is
# the portable way to say it.
locals=()
names=()
rsync_cwd=""
from_config=0
if [ "$#" -eq 0 ]; then
    : "${HPC_PUSH_PATHS:?no args given and HPC_PUSH_PATHS is unset}"
    from_config=1
    read -r -a rels <<< "$HPC_PUSH_PATHS"
    for p in ${rels[@]+"${rels[@]}"}; do
        names+=("$p")
        if [ "$relative" = 1 ]; then locals+=("$p"); else locals+=("$HPC_LOCAL_ROOT/$p"); fi
    done
    if [ "$relative" = 1 ]; then rsync_cwd="$HPC_LOCAL_ROOT"; fi
    dest="$HPC_CODE_SUBDIR"
elif [ "$#" -eq 1 ]; then
    hpc_die "usage: bash hpc_push.sh [--dry-run] [--relative] <local>... <dest-relative-to-remote-root>"
else
    dest="${*: -1}"
    locals=("${@:1:$#-1}")
    names=("${@:1:$#-1}")
fi

# Resolve one local source to the filesystem path that must exist. Identical to
# the rsync argument except for a --relative config push, whose sources are
# relative to HPC_LOCAL_ROOT rather than to $PWD.
hpc_push_localpath() {
    if [ -n "$rsync_cwd" ]; then
        case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$rsync_cwd" "$1" ;; esac
    else
        printf '%s' "$1"
    fi
}

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
for p in ${locals[@]+"${locals[@]}"}; do
    f="$(hpc_push_localpath "$p")"
    [ -e "$f" ] || missing+=("$f")
done
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

# Where does one source actually land? Mirrors rsync's own rules so the mapping
# printed below is the truth rather than a restatement of intent:
#   --relative : the source path as given is replicated under <dest>;
#   default    : only the basename appears, and a trailing '/' (or '/.') means
#                "the contents of", so nothing of the source's own name appears
#                — signalled here by a target that ends in '/'.
hpc_push_target() {
    local p="$1" leaf
    if [ "$relative" = 1 ]; then
        leaf="$p"
    else
        case "$p" in
            */|.|..|*/.|*/..) printf '%s/' "$remote"; return 0 ;;
        esac
        leaf="${p##*/}"
    fi
    while [ "$leaf" != "${leaf%/}" ] && [ -n "${leaf%/}" ]; do leaf="${leaf%/}"; done
    printf '%s/%s' "$remote" "${leaf#/}"
}

# An absolute source under --relative would have its whole local path replicated
# remotely (repo/Users/you/proj/docs/foo). Refuse rather than print that mapping
# and transfer it: rsync's /./ anchor is the fix on GNU rsync but is silently
# ignored by openrsync (/usr/bin/rsync on current macOS), so the portable answer
# is a relative source.
if [ "$relative" = 1 ] && [ "$from_config" = 0 ]; then
    for p in ${locals[@]+"${locals[@]}"}; do
        case "$p" in
            /*) hpc_die \
"--relative replicates the source path as given, so an absolute source would land
   under a copy of its whole local path:
       $p
         -> $remote/${p#/}
   Pass it relative to your current directory instead (cd to the parent first if
   needed), or drop --relative and name the directory in <dest>." ;;
        esac
    done
fi

# Under --relative the source text becomes part of the remote path, so each
# resolved target has to clear the same guard as <dest> itself — a '..' component
# in a source would otherwise walk out of HPC_REMOTE_ROOT.
if [ "$relative" = 1 ]; then
    for p in ${names[@]+"${names[@]}"}; do hpc_guard_remote "$(hpc_push_target "$p")"; done
fi

# The mapping, every run and in --dry-run too: the local->remote correspondence
# is the one thing about a push that is easy to get wrong and impossible to check
# afterwards without an ssh round trip.
{
    if [ "$from_config" = 1 ]; then
        echo "push mapping (sources relative to $HPC_LOCAL_ROOT):"
    else
        echo "push mapping:"
    fi
    for p in ${names[@]+"${names[@]}"}; do
        t="$(hpc_push_target "$p")"
        note=""
        case "$t" in */) note="   (contents only — trailing slash on the source)" ;; esac
        printf '  %s -> %s:%s%s\n' "$p" "$HPC_HOST" "$t" "$note"
    done
}

# Warn when the default basename semantics are about to drop a directory
# component the caller probably meant to keep — the footgun this mapping exists
# for. Only relative sources are checked: an absolute one has no plausible
# remote counterpart for its leading directories, so the mapping above is the
# whole story there. A <dest> that already ends in the source's directory (as
# `docs/foo repo/docs` does) preserves the path and is not flagged.
if [ "$relative" != 1 ]; then
    flat=()
    dest_cmp="$dest"
    while [ "$dest_cmp" != "${dest_cmp%/}" ] && [ -n "${dest_cmp%/}" ]; do dest_cmp="${dest_cmp%/}"; done
    for p in ${names[@]+"${names[@]}"}; do
        case "$p" in /*|*/|.|..|*/.|*/..) continue ;; esac   # absolute, or a "contents of" push
        case "$p" in */*) : ;; *) continue ;; esac           # no directory component to drop
        d="${p%/*}"
        [ "$d" = "." ] && continue                           # ./foo lands as foo, as written
        case "$dest_cmp" in "$d"|*"/$d") continue ;; esac     # <dest> already ends in it
        flat+=("$p")
    done
    if [ "${#flat[@]}" -ne 0 ]; then
        {
            echo "hpc: WARNING — rsync drops the directory component of these sources, so only"
            echo "     the basename lands under <dest> ($dest):"
            for p in ${flat[@]+"${flat[@]}"}; do
                printf '         %s -> %s   (NOT %s/%s)\n' "$p" "$(hpc_push_target "$p")" "$remote" "$p"
            done
            echo "     If you meant to keep the path, either name the directory in <dest>:"
            echo "         bash hpc_push.sh ${flat[0]} $dest/${flat[0]%/*}"
            echo "     or push with path preservation (rsync -R):"
            echo "         bash hpc_push.sh --relative ${flat[0]} $dest"
            echo "     If flattening is what you wanted, the mapping above is already correct."
        } >&2
    fi
fi

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
( [ -z "$rsync_cwd" ] || cd "$rsync_cwd"
  hpc_rsync -azP ${DRY[@]+"${DRY[@]}"} ${REL[@]+"${REL[@]}"} ${backup[@]+"${backup[@]}"} \
      "${EXCLUDES[@]}" -- "${locals[@]}" "$HPC_HOST:$remote/" ) || rc=$?
hpc_audit rsync_push --host "$HPC_HOST" --target "$remote/" --dry "${#DRY[@]}" \
    --relative "$relative" --exit "$rc"
[ "$rc" -eq 0 ] || hpc_die "rsync push failed (rc=$rc)"
# Name the local root, not just the remote target: it is the one input to a push
# that is inferred rather than given, so showing it makes a wrong one obvious.
if [ "$from_config" = 1 ]; then
    echo "pushed $HPC_LOCAL_ROOT -> $HPC_HOST:$remote/"
else
    echo "pushed -> $HPC_HOST:$remote/"
fi
