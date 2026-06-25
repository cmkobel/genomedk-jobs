# Shared helpers for the genomedk-jobs skill. `source` this from every wrapper:
#     . "$(dirname "$0")/_hpc_lib.sh"; hpc_load_config
#
# Provides: config loading, the remote-root safety guard, and audit logging.

hpc_die() { echo "hpc: $*" >&2; exit 1; }

# Locate and source the project's hpc.env. Search order:
#   1. $HPC_CONFIG, if set.
#   2. hpc.env or .hpc/hpc.env, walking up from $PWD to /.
# Exports the config vars (set -a) so child processes (python helpers) see them.
hpc_load_config() {
    local cfg="${HPC_CONFIG:-}"
    if [ -z "$cfg" ]; then
        local d="$PWD"
        while :; do
            if [ -f "$d/hpc.env" ]; then cfg="$d/hpc.env"; break; fi
            if [ -f "$d/.hpc/hpc.env" ]; then cfg="$d/.hpc/hpc.env"; break; fi
            [ "$d" = "/" ] && break
            d="$(dirname "$d")"
        done
    fi
    [ -n "$cfg" ] && [ -f "$cfg" ] || hpc_die \
        "no config found. Set HPC_CONFIG or create hpc.env at your project root (see config/hpc.env.example)."

    set -a
    # shellcheck disable=SC1090
    . "$cfg"
    set +a
    HPC_CONFIG="$cfg"

    : "${HPC_HOST:?set HPC_HOST in $cfg}"
    : "${HPC_ACCOUNT:?set HPC_ACCOUNT in $cfg}"
    : "${HPC_REMOTE_ROOT:?set HPC_REMOTE_ROOT in $cfg}"
    case "$HPC_REMOTE_ROOT" in
        /*) : ;;
        *) hpc_die "HPC_REMOTE_ROOT must be an absolute path: $HPC_REMOTE_ROOT" ;;
    esac
    # HPC_REMOTE_ROOT is interpolated into remote shell commands all over the
    # skill, so it must contain no shell metacharacters.
    hpc_reject_unsafe "$HPC_REMOTE_ROOT" "HPC_REMOTE_ROOT"
    : "${HPC_LOCAL_ROOT:=$(cd "$(dirname "$cfg")" && pwd)}"
    : "${HPC_AUDIT_LOG:=$HPC_LOCAL_ROOT/.hpc_audit.log}"
    : "${HPC_CODE_SUBDIR:=repo}"
    export HPC_HOST HPC_ACCOUNT HPC_REMOTE_ROOT HPC_LOCAL_ROOT HPC_AUDIT_LOG HPC_CODE_SUBDIR HPC_CONFIG
}

# Warn (never fail) when HPC_HOST has no SSH connection multiplexing configured.
# `ssh -G <host>` prints the effective config; without `ControlMaster auto` and a
# `ControlPath`, a cluster with interactive 2FA (e.g. GenomeDK) re-prompts for the
# OTP on every ssh/rsync — and the assistant cannot type it, so push/submit/
# status/fetch stall. This turns that confusing failure into one actionable line.
# Returns 0 if multiplexing looks configured (or cannot be determined), 1 after
# printing guidance if it is clearly absent. The most common trigger is simply
# having no `Host $HPC_HOST` block in ~/.ssh/config at all.
hpc_check_ssh_multiplexing() {
    command -v ssh >/dev/null 2>&1 || return 0
    local g cm cp ref
    g="$(ssh -G "$HPC_HOST" 2>/dev/null)" || return 0   # pre-6.8 ssh lacks -G: skip
    [ -n "$g" ] || return 0
    cm="$(printf '%s\n' "$g" | awk 'tolower($1)=="controlmaster"{print tolower($2); exit}')"
    cp="$(printf '%s\n' "$g" | awk 'tolower($1)=="controlpath"{print $2; exit}')"
    case "$cm" in auto|yes) ;; *) cm=off ;; esac
    case "$cp" in ''|none|None) cp=off ;; esac
    [ "$cm" != off ] && [ "$cp" != off ] && return 0

    ref="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/reference/ssh_setup.md"
    cat >&2 <<EOF
hpc: WARNING — SSH connection multiplexing is not configured for "$HPC_HOST".
     Without it, a cluster with interactive 2FA (e.g. GenomeDK) re-prompts for
     your OTP on every ssh/rsync, and the assistant cannot type it — so push,
     submit, status, and fetch will stall. Most often this just means there is
     no "Host $HPC_HOST" block in ~/.ssh/config.

     Fix: add a block for "$HPC_HOST" to ~/.ssh/config containing
         ControlMaster auto
         ControlPath ~/.ssh/cm-%r@%h:%p
         ControlPersist 12h
     Copy-paste example: $ref

     (If "$HPC_HOST" uses key-based or otherwise prompt-free auth, ignore this.)
EOF
    return 1
}

# Reject a string that contains anything outside a conservative safe set
# (letters, digits, '.', '_', '/', '-'). Every value the skill interpolates into
# a remote shell command passes through here so a crafted path/name cannot break
# out of the command (e.g. ';rm -rf ~', '$(...)', backticks, spaces, newlines).
hpc_reject_unsafe() {
    local val="$1" what="${2:-value}" stripped
    stripped="${val//[A-Za-z0-9._\/-]/}"
    [ -z "$stripped" ] || hpc_die "refusing $what with unsafe character(s) [$stripped]: $val"
}

# Refuse any remote path that is not HPC_REMOTE_ROOT or under it. Call this on
# every path before an ssh mkdir / rsync destination / submit target. A bare
# prefix check is not enough: a ".." component keeps the prefix while escaping
# the root (e.g. $ROOT/../../etc), so reject ".." and shell metacharacters first.
hpc_guard_remote() {
    hpc_reject_unsafe "$1" "remote path"
    case "$1" in
        ..|../*|*/..|*/../*) hpc_die "refusing path with a '..' component: $1" ;;
    esac
    case "$1" in
        "$HPC_REMOTE_ROOT"|"$HPC_REMOTE_ROOT"/*) : ;;
        *) hpc_die "refusing to operate outside HPC_REMOTE_ROOT ($HPC_REMOTE_ROOT): $1" ;;
    esac
}

# Append one structured JSON line to the audit log via the python helper.
hpc_audit() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$here/_hpc_log.py" "$@"
}

# Pull the SLURM-side audit log ($HPC_REMOTE_ROOT/audit.remote.log, written by
# the job template's log_remote) and append any lines not already present to the
# local audit log, so job_start/job_end show up alongside login/push/fetch.
# Best-effort: a silent no-op if the remote log does not exist yet.
hpc_merge_remote_audit() {
    local remote_audit="$HPC_REMOTE_ROOT/audit.remote.log" tmp line
    tmp="$(mktemp)" || return 0
    if rsync -az "$HPC_HOST:$remote_audit" "$tmp" 2>/dev/null; then
        touch "$HPC_AUDIT_LOG"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            grep -qxF -- "$line" "$HPC_AUDIT_LOG" 2>/dev/null || printf '%s\n' "$line" >> "$HPC_AUDIT_LOG"
        done < "$tmp"
    fi
    rm -f "$tmp"
}

# Before the first remote write, confirm HPC_REMOTE_ROOT is actually yours, so a
# mistyped config cannot push/submit into another project's directory. Result is
# cached in a local marker (host::root) so it costs one ssh per project, not per
# command. A genuinely shared root you do not own can be allowed with
# HPC_ALLOW_UNOWNED_ROOT=1. Callers: hpc_push.sh, hpc_submit.py (mirrored).
hpc_verify_root() {
    local marker="$HPC_LOCAL_ROOT/.hpc_root_verified" want status
    want="$HPC_HOST::$HPC_REMOTE_ROOT"
    [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$want" ] && return 0

    status="$(ssh "$HPC_HOST" "if [ ! -e '$HPC_REMOTE_ROOT' ]; then echo missing; elif [ -O '$HPC_REMOTE_ROOT' ]; then echo owned; else echo notowned; fi" 2>/dev/null)" \
        || hpc_die "could not reach $HPC_HOST to verify HPC_REMOTE_ROOT — is the SSH socket up? (run hpc_login.sh)"

    case "$status" in
        owned) ;;
        missing)
            echo "hpc: HPC_REMOTE_ROOT does not exist yet on $HPC_HOST: $HPC_REMOTE_ROOT" >&2
            echo "     it will be created on first push — double-check the path in hpc.env is correct." >&2
            ;;
        notowned)
            [ "${HPC_ALLOW_UNOWNED_ROOT:-0}" = 1 ] || hpc_die \
"HPC_REMOTE_ROOT exists but is not owned by you on $HPC_HOST:
       $HPC_REMOTE_ROOT
   This often means hpc.env points at the wrong path (e.g. another project).
   If it is genuinely yours (a shared project dir), re-run with HPC_ALLOW_UNOWNED_ROOT=1." ;;
        *) hpc_die "unexpected response while verifying HPC_REMOTE_ROOT: '$status'" ;;
    esac

    printf '%s\n' "$want" > "$marker" 2>/dev/null || true
}
