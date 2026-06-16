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
    : "${HPC_LOCAL_ROOT:=$(cd "$(dirname "$cfg")" && pwd)}"
    : "${HPC_AUDIT_LOG:=$HPC_LOCAL_ROOT/.hpc_audit.log}"
    : "${HPC_CODE_SUBDIR:=repo}"
    export HPC_HOST HPC_ACCOUNT HPC_REMOTE_ROOT HPC_LOCAL_ROOT HPC_AUDIT_LOG HPC_CODE_SUBDIR HPC_CONFIG
}

# Refuse any remote path that is not HPC_REMOTE_ROOT or under it. Call this on
# every path before an ssh mkdir / rsync destination / submit target.
hpc_guard_remote() {
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
