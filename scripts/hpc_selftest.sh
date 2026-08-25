#!/bin/bash
# Self-test for the genomedk-jobs skill. Validates the skill's machinery so you
# (or Claude Code) can confirm everything is intact after editing or porting it.
#
# Usage:
#   bash hpc_selftest.sh            # offline checks only — no SSH, no cluster
#   bash hpc_selftest.sh --online   # also probe your configured cluster (read-only)
#
# Offline checks need only bash + python3 and touch nothing outside a temp dir:
# script syntax, config loading, the remote-root safety guard, the submit guard,
# SLURM-template rendering, and the audit logger. The --online checks use your
# project's real hpc.env (run them from inside your project) and only run
# read-only commands (ssh -O check, squeue, test -d) — they never write remotely.
#
# Exits 0 if every check passes, non-zero otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
SUBMIT="$HERE/hpc_submit.py"
LIB="$HERE/_hpc_lib.sh"
LOGGER="$HERE/_hpc_log.py"
HOOK="$HERE/hpc_guard_hook.py"

ONLINE=0
[ "${1:-}" = "--online" ] && ONLINE=1

pass=0 fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
skip() { printf '  SKIP  %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

# expect_ok "<desc>" cmd...   -> PASS if cmd exits 0
# expect_fail "<desc>" cmd... -> PASS if cmd exits non-zero
expect_ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
expect_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d (expected failure)"; else ok "$d"; fi; }
# check_contains/absent "<desc>" "<needle>" "<haystack>"
check_contains() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1"; fi; }
check_absent()   { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1"; else ok "$1"; fi; }

# --- hermeticity -------------------------------------------------------------
# Clear any HPC_* variable inherited from the caller. The fixtures below are
# meant to be the only configuration in play, and a real project's exported
# HPC_LOCAL_ROOT / HPC_CONFIG / HPC_PUSH_BACKUP would silently retarget them —
# e.g. resolving the fixture's push paths and .hpc_root_verified outside $TMP,
# failing checks that have nothing to do with the caller's project. Every check
# passes what it needs explicitly (via `env HPC_...=` or -c), and the --online
# section rediscovers the real hpc.env by walking up from $PWD, so none of them
# are needed here.
for v in $(env | sed -n 's/^\(HPC_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done

# --- a throwaway project + config so nothing real is touched -----------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/hpc.env" <<EOF
HPC_HOST=selftest-host
HPC_USER=tester
HPC_ACCOUNT=test_account
HPC_REMOTE_ROOT=/faststorage/project/test/root
HPC_PARTITION=gpu-l40s
HPC_MAIL_USER=tester@example.com
HPC_CODE_SUBDIR=repo
HPC_PUSH_PATHS="src scripts"
HPC_JOB_SETUP='export TORCH_HOME=\$REMOTE_ROOT/.torch-cache'
HPC_AUDIT_LOG=$TMP/.hpc_audit.log
EOF
cat > "$TMP/bad_relative.env" <<'EOF'
HPC_HOST=h
HPC_ACCOUNT=a
HPC_REMOTE_ROOT=relative/path
EOF
# The HPC_PUSH_PATHS above must actually exist, or hpc_push.sh's preflight
# (correctly) refuses to push. Creating them keeps the wrapper-execution checks
# exercising a realistic transfer rather than an all-paths-missing abort.
mkdir -p "$TMP/src" "$TMP/scripts"
: > "$TMP/src/mod.py"
: > "$TMP/scripts/run.py"
# A NESTED source, for the push path-resolution checks below: rsync strips the
# directory component by default, and that only diverges from the caller's
# likely intent when the source is nested (for a top-level path the basename IS
# the relative path, which is why "src scripts" above never shows it).
mkdir -p "$TMP/docs/2026-08-24_foo" "$TMP/conf"
: > "$TMP/docs/2026-08-24_foo/note.md"
: > "$TMP/conf/params.yaml"

section "Syntax"
for f in "$HERE"/*.sh; do expect_ok "bash -n $(basename "$f")" bash -n "$f"; done
expect_ok "py_compile hpc_submit.py"    python3 -m py_compile "$SUBMIT"
expect_ok "py_compile _hpc_log.py"      python3 -m py_compile "$LOGGER"
expect_ok "py_compile hpc_guard_hook.py" python3 -m py_compile "$HOOK"

section "Config loading (_hpc_lib.sh)"
HPC_CONFIG="$TMP/hpc.env" expect_ok "loads a valid hpc.env" \
    bash -c '. "$0"; hpc_load_config; [ "$HPC_ACCOUNT" = test_account ]' "$LIB"
HPC_CONFIG="$TMP/nope.env" expect_fail "dies on a missing config" \
    bash -c '. "$0"; hpc_load_config' "$LIB"
HPC_CONFIG="$TMP/bad_relative.env" expect_fail "rejects a relative HPC_REMOTE_ROOT" \
    bash -c '. "$0"; hpc_load_config' "$LIB"

# hpc.env is meant to be committed/shared, so loading it must NOT run code.
EVIL_MARK="$TMP/parse_pwned"
rm -f "$EVIL_MARK"
cat > "$TMP/inject.env" <<EOF
HPC_HOST=selftest-host
HPC_ACCOUNT=a
HPC_REMOTE_ROOT=/faststorage/project/test/root
HPC_EVIL=\$(touch $EVIL_MARK && echo gotcha)
HPC_TICK=\`touch $EVIL_MARK\`
EOF
HPC_CONFIG="$TMP/inject.env" bash -c '. "$0"; hpc_load_config' "$LIB" >/dev/null 2>&1
expect_fail "a \$(...)/backtick value does NOT execute on load (no marker)" test -f "$EVIL_MARK"
HPC_CONFIG="$TMP/inject.env" expect_ok "...but the line still loads (value kept, literal)" \
    bash -c '. "$0"; hpc_load_config; [ -n "$HPC_EVIL" ]' "$LIB"

# A trailing slash on the root must be normalized away, or the shell prefix
# guard would reject every valid subpath (shell vs python divergence).
cat > "$TMP/trailing.env" <<'EOF'
HPC_HOST=h
HPC_ACCOUNT=a
HPC_REMOTE_ROOT=/faststorage/project/test/root/
EOF
HPC_CONFIG="$TMP/trailing.env" expect_ok "normalizes a trailing slash, then accepts a subpath" \
    bash -c '. "$0"; hpc_load_config; [ "$HPC_REMOTE_ROOT" = /faststorage/project/test/root ] && hpc_guard_remote "$HPC_REMOTE_ROOT/sub"' "$LIB"

section "Remote-root guard (hpc_guard_remote)"
ROOT=/faststorage/project/test/root
guard() { HPC_REMOTE_ROOT="$ROOT" bash -c '. "$1"; hpc_guard_remote "$2"' _ "$LIB" "$1"; }
expect_ok   "accepts a path under the root"      guard "$ROOT/results/my-job_1"
expect_ok   "accepts the root itself"            guard "$ROOT"
expect_fail "rejects '..' traversal"             guard "$ROOT/../../etc/passwd"
expect_fail "rejects a trailing '..'"            guard "$ROOT/sub/.."
expect_fail "rejects a sibling outside the root" guard "/faststorage/project/test/other"
expect_fail "rejects ';' (command injection)"    guard "$ROOT/x;rm -rf ~"
expect_fail "rejects '\$(...)' substitution"      guard "$ROOT/\$(id)"
expect_fail "rejects a space"                    guard "$ROOT/a b"

section "Submit guard + template rendering (hpc_submit.py)"
sub() { HPC_CONFIG="$TMP/hpc.env" python3 "$SUBMIT" "$@"; }
expect_fail "rejects --name with '/'"            sub --name a/b           --command 'echo hi' --dry-run
expect_fail "rejects --name with '..'"           sub --name ../../x       --command 'echo hi' --dry-run
expect_fail "rejects --name with metacharacters" sub --name 'job;whoami'  --command 'echo hi' --dry-run
expect_fail "rejects --name with a space"        sub --name 'a b'         --command 'echo hi' --dry-run
expect_fail "rejects escaping --remote-subdir"   sub --name ok --remote-subdir ../../etc --command 'echo hi' --dry-run

render="$(sub --name selftest --command 'python work.py' --gpus 0 --chunks 3 --dry-run 2>/dev/null)"
check_contains "renders the account directive"   '#SBATCH --account test_account' "$render"
check_contains "renders the partition"           '#SBATCH --partition gpu-l40s'   "$render"
check_contains "renders the array block (chunks)" '#SBATCH --array=1-3%1'         "$render"
check_contains "renders the mail-user"           '#SBATCH --mail-user tester@example.com' "$render"
check_contains "renders the command"             'python work.py'                "$render"
check_contains "keeps \$REMOTE_ROOT literal in setup" 'export TORCH_HOME=$REMOTE_ROOT/.torch-cache' "$render"
check_absent   "omits --gpus when --gpus 0"      '#SBATCH --gpus'                 "$render"

render_gpu="$(sub --name g --command 'echo hi' --gpus 2 --dry-run 2>/dev/null)"
check_contains "renders --gpus when requested"   '#SBATCH --gpus 2'               "$render_gpu"
check_absent   "omits the array block at chunks=1" '#SBATCH --array'              "$render_gpu"

# Single-pass render: an earlier value containing a later key's placeholder must
# NOT be re-expanded (an ordered chain of str.replace() would turn this into
# 'echo RUNME').
render_sp="$(sub --name n --command RUNME --setup 'echo @@COMMAND@@' --dry-run 2>/dev/null)"
check_contains "render is single-pass (a value's @@COMMAND@@ stays literal)" 'echo @@COMMAND@@' "$render_sp"

# Trailing-slash root is normalized on the python side too (no doubled slash).
render_ts="$(HPC_CONFIG="$TMP/trailing.env" python3 "$SUBMIT" --name n --command 'echo hi' --dry-run 2>/dev/null)"
check_contains "submit normalizes a trailing-slash root" '#SBATCH --output /faststorage/project/test/root/slurm_logs/%j.out' "$render_ts"
check_absent   "...with no doubled slash"                '/root//slurm_logs'                                              "$render_ts"

section "Audit logger (_hpc_log.py)"
alog="$TMP/audit_test.log"
expect_ok "writes a log line" env HPC_AUDIT_LOG="$alog" \
    python3 "$LOGGER" selftest_action --host h1 --exit 0
expect_ok "log line is valid JSON with expected fields" python3 - "$alog" <<'PY'
import json, sys
line = open(sys.argv[1]).read().splitlines()[-1]
d = json.loads(line)
assert d["action"] == "selftest_action" and d["host"] == "h1" and d["exit"] == 0, d
PY

section "Deny-hook (hpc_guard_hook.py)"
# Feed a PreToolUse payload; the fake hpc.env's HPC_HOST is 'selftest-host'.
hook_ec() {
    local payload
    payload="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1")"
    printf '%s' "$payload" | HPC_CONFIG="$TMP/hpc.env" python3 "$HOOK" >/dev/null 2>&1
    echo $?
}
expect_block() { local d="$1"; if [ "$(hook_ec "$2")" = 2 ]; then ok "$d"; else bad "$d"; fi; }
expect_allow() { local d="$1"; if [ "$(hook_ec "$2")" = 0 ]; then ok "$d"; else bad "$d"; fi; }
expect_block "blocks rsync --delete to the host"  "rsync -az --delete ./x selftest-host:/faststorage/project/test/root/"
expect_block "blocks 'ssh host rm -rf'"           "ssh selftest-host 'rm -rf /faststorage/project/test/root/out'"
expect_block "blocks 'ssh host find -delete'"     "ssh selftest-host 'find /faststorage/project/test/root -name \"*.ckpt\" -delete'"
expect_block "blocks 'ssh host shred'"            "ssh selftest-host 'shred -u /faststorage/project/test/root/out'"
expect_block "blocks 'ssh host truncate -s 0'"    "ssh selftest-host 'truncate -s 0 /faststorage/project/test/root/db'"
expect_block "blocks 'ssh host mkfs'"             "ssh selftest-host mkfs.ext4 /dev/sdb"
expect_allow "allows a wrapper invocation"        "bash scripts/hpc_push.sh"
expect_allow "allows a normal rsync push"         "rsync -azP ./src selftest-host:/faststorage/project/test/root/repo/"
expect_allow "allows 'ssh host squeue'"           "ssh selftest-host squeue -u me"
expect_allow "allows a local rm (not the host)"   "rm -rf /tmp/scratch"
expect_allow "allows local rsync --delete (no host)" "rsync -a --delete ./a ./b"
expect_allow "allows a benign '2>/dev/null' redirect" "ssh selftest-host 'squeue -j 1 2>/dev/null'"
expect_block "blocks '> /etc/...' (system path)"   "ssh selftest-host 'echo x > /etc/passwd'"
expect_block "blocks '> /dev/sda' (device write)"  "ssh selftest-host 'cat z > /dev/sda'"

section "Root verification (cached marker)"
printf 'selftest-host::/faststorage/project/test/root\n' > "$TMP/.hpc_root_verified"
HPC_CONFIG="$TMP/hpc.env" expect_ok "hpc_verify_root short-circuits on a matching marker (no ssh)" \
    bash -c '. "$0"; hpc_load_config; hpc_verify_root' "$LIB"
rm -f "$TMP/.hpc_root_verified"

section "SSH multiplexing check (hpc_check_ssh_multiplexing)"
# Stub `ssh -G <host>` to emit a configured vs. an unconfigured effective config,
# so the check is exercised without touching the user's real ~/.ssh/config.
MUXOK="$TMP/muxok"; mkdir -p "$MUXOK"
cat > "$MUXOK/ssh" <<'SH'
#!/bin/sh
if [ "$1" = "-G" ]; then
  printf 'controlmaster auto\ncontrolpath /tmp/cm-socket\ncontrolpersist 43200\n'
fi
exit 0
SH
MUXNO="$TMP/muxno"; mkdir -p "$MUXNO"
cat > "$MUXNO/ssh" <<'SH'
#!/bin/sh
if [ "$1" = "-G" ]; then
  printf 'controlmaster false\ncontrolpersist no\n'
fi
exit 0
SH
chmod +x "$MUXOK/ssh" "$MUXNO/ssh"
expect_ok   "passes when ControlMaster+ControlPath are configured" \
    env "PATH=$MUXOK:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash -c '. "$0"; hpc_load_config; hpc_check_ssh_multiplexing' "$LIB"
expect_fail "warns when multiplexing is absent (no Host block)" \
    env "PATH=$MUXNO:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash -c '. "$0"; hpc_load_config; hpc_check_ssh_multiplexing' "$LIB"

section "SSH socket preflight (hpc_require_socket)"
# Stub ssh three ways: a live master socket, a dead one (every probe fails), and
# a host with no master but working prompt-free (key) auth.
SOCKUP="$TMP/sockup";   mkdir -p "$SOCKUP";   printf '#!/bin/sh\nexit 0\n'   > "$SOCKUP/ssh";   chmod +x "$SOCKUP/ssh"
SOCKDOWN="$TMP/sockdn"; mkdir -p "$SOCKDOWN"; printf '#!/bin/sh\nexit 255\n' > "$SOCKDOWN/ssh"; chmod +x "$SOCKDOWN/ssh"
SOCKKEY="$TMP/sockkey"; mkdir -p "$SOCKKEY"
cat > "$SOCKKEY/ssh" <<'SH'
#!/bin/sh
case "$*" in
  *"-O check"*) exit 255 ;;   # no master socket configured...
  *)            exit 0 ;;     # ...but a direct (key-auth) connection works
esac
SH
chmod +x "$SOCKKEY/ssh"
req() { env "PATH=$1:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash -c '. "$0"; hpc_load_config; hpc_require_socket' "$LIB"; }
expect_ok   "passes when the master socket is alive"                req "$SOCKUP"
expect_ok   "passes via BatchMode fallback (prompt-free key auth)"  req "$SOCKKEY"
expect_fail "dies when no socket and no prompt-free auth"           req "$SOCKDOWN"
# Every network-touching wrapper must abort fast on a dead socket (never prompt).
expect_fail "hpc_status.sh aborts when the socket is down" \
    env "PATH=$SOCKDOWN:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash "$HERE/hpc_status.sh"
expect_fail "hpc_push.sh aborts when the socket is down" \
    env "PATH=$SOCKDOWN:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash "$HERE/hpc_push.sh"
expect_fail "hpc_fetch.sh aborts when the socket is down" \
    env "PATH=$SOCKDOWN:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash "$HERE/hpc_fetch.sh" repo/results
expect_fail "hpc_submit.py aborts when the socket is down" \
    env "PATH=$SOCKDOWN:$PATH" "HPC_CONFIG=$TMP/hpc.env" python3 "$SUBMIT" --name n --command 'echo hi'
# ...but a dry-run submit stays fully offline (no socket needed).
expect_ok "hpc_submit.py --dry-run needs no socket" \
    env "PATH=$SOCKDOWN:$PATH" "HPC_CONFIG=$TMP/hpc.env" python3 "$SUBMIT" --name n --command 'echo hi' --dry-run

section "Wrapper execution — empty-array safety (stubbed ssh/rsync)"
# Run hpc_push.sh / hpc_fetch.sh end-to-end with ssh+rsync stubbed and WITHOUT
# --dry-run, so the optional-arg arrays (DRY, backup) are expanded while empty.
# That is the exact path that aborts under bash 3.2's `set -u` if a wrapper uses
# a bare "${arr[@]}" on an empty array — and a --dry-run test would NOT catch it
# (--dry-run makes DRY non-empty). Guards the macOS /bin/bash 3.2 regression.
STUB="$TMP/stubbin"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 0\n' > "$STUB/ssh"
printf '#!/bin/sh\nexit 0\n' > "$STUB/rsync"
chmod +x "$STUB/ssh" "$STUB/rsync"
printf 'selftest-host::/faststorage/project/test/root\n' > "$TMP/.hpc_root_verified"
expect_ok "hpc_push.sh runs end-to-end (no --dry-run) under bash $BASH_VERSION" \
    env "PATH=$STUB:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash "$HERE/hpc_push.sh"
expect_ok "hpc_fetch.sh runs end-to-end (no --dry-run) under bash $BASH_VERSION" \
    env "PATH=$STUB:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash "$HERE/hpc_fetch.sh" repo/results
expect_ok "hpc_push.sh honors -c <config>" \
    env "PATH=$STUB:$PATH" bash "$HERE/hpc_push.sh" -c "$TMP/hpc.env" --dry-run

# Missing-source preflight. rsync alone reports a missing path as exit 23 only
# AFTER transferring the paths that do exist, so the push must be refused up
# front (all-or-nothing) instead of partially landing and then reporting failure.
cat > "$TMP/missing.env" <<EOF
HPC_HOST=selftest-host
HPC_ACCOUNT=test_account
HPC_REMOTE_ROOT=/faststorage/project/test/root
HPC_CODE_SUBDIR=repo
HPC_PUSH_PATHS="src scripts nope.lock"
HPC_LOCAL_ROOT=$TMP
HPC_AUDIT_LOG=$TMP/.hpc_audit.log
EOF
mres="$(env "PATH=$STUB:$PATH" "HPC_CONFIG=$TMP/missing.env" \
    bash "$HERE/hpc_push.sh" 2>&1 || true)"
expect_fail "push refuses when an HPC_PUSH_PATHS entry is missing" \
    env "PATH=$STUB:$PATH" "HPC_CONFIG=$TMP/missing.env" bash "$HERE/hpc_push.sh"
check_contains "...names the missing path" "nope.lock" "$mres"
check_contains "...names the resolved local root (the usual root cause)" \
    "local root : $TMP" "$mres"
check_contains "...offers the override" "HPC_PUSH_ALLOW_MISSING=1" "$mres"
expect_ok "HPC_PUSH_ALLOW_MISSING=1 pushes the paths that do exist" \
    env "PATH=$STUB:$PATH" "HPC_CONFIG=$TMP/missing.env" "HPC_PUSH_ALLOW_MISSING=1" \
    bash "$HERE/hpc_push.sh"
expect_fail "push refuses an explicitly named nonexistent local path" \
    env "PATH=$STUB:$PATH" "HPC_CONFIG=$TMP/hpc.env" \
    bash "$HERE/hpc_push.sh" "$TMP/definitely_absent" somedest
rm -f "$TMP/.hpc_root_verified"

section "Wrapper rsync option-safety ('--' terminates options)"
# A source/dest beginning with '-' must reach rsync as a PATH, never an option,
# or the "wrappers never pass --delete" invariant leaks. The stub records rsync's
# argv (fetch invokes rsync twice: the transfer + the audit-log merge, so append).
ARGV="$TMP/argvstub"; mkdir -p "$ARGV"
printf '#!/bin/sh\nexit 0\n' > "$ARGV/ssh"
cat > "$ARGV/rsync" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$RSYNC_ARGV_OUT"
exit 0
SH
chmod +x "$ARGV/ssh" "$ARGV/rsync"
printf 'selftest-host::/faststorage/project/test/root\n' > "$TMP/.hpc_root_verified"

pout="$TMP/push_argv.txt"; : > "$pout"
# The source must really exist, else the missing-source preflight (correctly)
# refuses the push before rsync is ever reached. Creating an actual file named
# '--delete' and pushing it from that directory is the true scenario anyway.
touch -- "$TMP/--delete"
( cd "$TMP" && env "PATH=$ARGV:$PATH" "HPC_CONFIG=$TMP/hpc.env" "RSYNC_ARGV_OUT=$pout" \
    bash "$HERE/hpc_push.sh" --delete somedest ) >/dev/null 2>&1
check_contains "push sends a --delete-named SOURCE as a path, not an option" '-- --delete' "$(cat "$pout")"

fout="$TMP/fetch_argv.txt"; : > "$fout"
env "PATH=$ARGV:$PATH" "HPC_CONFIG=$TMP/hpc.env" "RSYNC_ARGV_OUT=$fout" \
    bash "$HERE/hpc_fetch.sh" results ./out >/dev/null 2>&1
check_contains "fetch terminates rsync options with '--'" \
    '-- selftest-host:/faststorage/project/test/root/results' "$(cat "$fout")"
rm -f "$TMP/.hpc_root_verified"

section "Push path resolution (basename default vs --relative)"
# rsync strips a source's directory component, so `push docs/foo repo` lands at
# repo/foo, not repo/docs/foo. That default is kept (HPC_PUSH_PATHS and existing
# callers depend on it), so the guarantee under test is that it is never SILENT:
# every push prints the resolved local -> remote-absolute mapping, and a dropped
# directory component is warned about at push time — not discovered later as a
# FileNotFoundError inside a job that already queued.
PMAP="$TMP/pmapstub"; mkdir -p "$PMAP"
printf '#!/bin/sh\nexit 0\n' > "$PMAP/ssh"
cat > "$PMAP/rsync" <<'SH'
#!/bin/sh
printf 'cwd=%s argv=%s\n' "$(pwd)" "$*" >> "$RSYNC_ARGV_OUT"
exit 0
SH
chmod +x "$PMAP/ssh" "$PMAP/rsync"
printf 'selftest-host::/faststorage/project/test/root\n' > "$TMP/.hpc_root_verified"
RROOT=/faststorage/project/test/root

# $1 = output file for the rsync argv, rest = hpc_push.sh args. Run from $TMP so
# the relative sources resolve, with stdout+stderr merged (mapping is stdout, the
# warning is stderr).
push_out() {
    local argv_out="$1"; shift
    ( cd "$TMP" && env "PATH=$PMAP:$PATH" "HPC_CONFIG=$TMP/hpc.env" \
        "RSYNC_ARGV_OUT=$argv_out" bash "$HERE/hpc_push.sh" "$@" 2>&1 )
}

nest="$(push_out "$TMP/p1.txt" --dry-run docs/2026-08-24_foo repo)"
check_contains "push prints the resolved mapping (in --dry-run too)" \
    "docs/2026-08-24_foo -> selftest-host:$RROOT/repo/2026-08-24_foo" "$nest"
check_contains "...warns that the directory component is dropped" "WARNING" "$nest"
check_contains "...names the path the caller probably expected" \
    "NOT $RROOT/repo/docs/2026-08-24_foo" "$nest"
check_contains "...offers the <dest> remedy"    "hpc_push.sh docs/2026-08-24_foo repo/docs" "$nest"
check_contains "...offers the --relative remedy" "hpc_push.sh --relative docs/2026-08-24_foo repo" "$nest"

# <dest> already ending in the source's parent preserves the path: no warning.
same="$(push_out "$TMP/p2.txt" --dry-run docs/2026-08-24_foo repo/docs)"
check_contains "maps a matching <dest> to the preserved path" \
    "-> selftest-host:$RROOT/repo/docs/2026-08-24_foo" "$same"
check_absent   "...and does not warn (nothing is dropped)" "WARNING" "$same"

# The SKILL.md worked-example shape: <dest> IS the source's parent.
worked="$(push_out "$TMP/p3.txt" --dry-run conf/params.yaml conf)"
check_absent "does not warn when <dest> is the source's own parent" "WARNING" "$worked"

# Top-level HPC_PUSH_PATHS ("src scripts") is unaffected by the stripping.
cfgpush="$(push_out "$TMP/p4.txt" --dry-run)"
check_contains "config push maps each HPC_PUSH_PATHS entry" \
    "src -> selftest-host:$RROOT/repo/src" "$cfgpush"
check_absent   "...and does not warn for top-level entries" "WARNING" "$cfgpush"

# ...but a NESTED HPC_PUSH_PATHS entry has the same footgun, and must warn too.
cat > "$TMP/nested.env" <<EOF
HPC_HOST=selftest-host
HPC_ACCOUNT=test_account
HPC_REMOTE_ROOT=$RROOT
HPC_CODE_SUBDIR=repo
HPC_PUSH_PATHS="src conf/params.yaml"
HPC_LOCAL_ROOT=$TMP
HPC_AUDIT_LOG=$TMP/.hpc_audit.log
EOF
nestcfg="$( ( cd "$TMP" && env "PATH=$PMAP:$PATH" "HPC_CONFIG=$TMP/nested.env" \
    "RSYNC_ARGV_OUT=$TMP/p5.txt" bash "$HERE/hpc_push.sh" --dry-run 2>&1 ) )"
check_contains "warns for a NESTED HPC_PUSH_PATHS entry as well" \
    "conf/params.yaml -> $RROOT/repo/params.yaml" "$nestcfg"

# A trailing slash means "the contents of" — the source's own name lands nowhere.
slash="$(push_out "$TMP/p6.txt" --dry-run docs/2026-08-24_foo/ repo)"
check_contains "flags a trailing-slash source as a contents-only push" "contents only" "$slash"

# --relative (opt-in) preserves the path and passes -R through to rsync.
rel="$(push_out "$TMP/p7.txt" --dry-run --relative docs/2026-08-24_foo repo)"
check_contains "--relative maps the source's full path under <dest>" \
    "-> selftest-host:$RROOT/repo/docs/2026-08-24_foo" "$rel"
check_absent   "...and does not warn"        "WARNING" "$rel"
check_contains "...and passes -R to rsync"   " -R "     "$(cat "$TMP/p7.txt")"
check_absent   "default mode passes no -R to rsync" " -R " "$(cat "$TMP/p1.txt")"

# A --relative config push must run rsync FROM HPC_LOCAL_ROOT with relative
# sources: rsync -R replicates the path as given, so absolute sources would land
# under a copy of the whole local path. (rsync's /./ anchor would say the same in
# one path, but openrsync — /usr/bin/rsync on current macOS — ignores it.)
: > "$TMP/p8.txt"
( cd / && env "PATH=$PMAP:$PATH" "RSYNC_ARGV_OUT=$TMP/p8.txt" \
    bash "$HERE/hpc_push.sh" -c "$TMP/nested.env" --relative --dry-run ) >/dev/null 2>&1
check_contains "--relative config push runs rsync from HPC_LOCAL_ROOT" "cwd=$TMP " "$(cat "$TMP/p8.txt")"
check_contains "...with sources relative to it"      " conf/params.yaml " "$(cat "$TMP/p8.txt")"
check_absent   "...not as absolute paths"            "$TMP/conf/params.yaml" "$(cat "$TMP/p8.txt")"
expect_ok "HPC_PUSH_RELATIVE=1 enables it from hpc.env" \
    env "PATH=$PMAP:$PATH" "HPC_CONFIG=$TMP/nested.env" "HPC_PUSH_RELATIVE=1" \
    "RSYNC_ARGV_OUT=$TMP/p9.txt" bash "$HERE/hpc_push.sh" --dry-run

# Under --relative the source text becomes part of the remote path, so the two
# ways it could point outside <dest> must be refused rather than mapped.
expect_fail "--relative refuses an absolute source (would replicate /Users/...)" \
    env "PATH=$PMAP:$PATH" "HPC_CONFIG=$TMP/hpc.env" "RSYNC_ARGV_OUT=$TMP/p10.txt" \
    bash "$HERE/hpc_push.sh" --relative "$TMP/docs/2026-08-24_foo" repo
esc="$( ( cd "$TMP/src" && env "PATH=$PMAP:$PATH" "HPC_CONFIG=$TMP/hpc.env" \
    "RSYNC_ARGV_OUT=$TMP/p11.txt" bash "$HERE/hpc_push.sh" -R ../docs repo 2>&1 ) || true )"
check_contains "--relative refuses a '..' source (guarded like <dest>)" "'..'" "$esc"
rm -f "$TMP/.hpc_root_verified"

section "Fetch destination resolution (hpc_fetch.sh)"
# rsync places a source INSIDE its destination, so the default destination has to
# be the PARENT of <remote-subpath> for the fetch to land at
# $HPC_LOCAL_ROOT/<remote-subpath> as documented. Passing $HPC_LOCAL_ROOT/<sub>
# instead doubled the last component (repo/conf/conf). Checked on the resolved
# rsync argv, since the transfer itself is stubbed here.
printf 'selftest-host::/faststorage/project/test/root\n' > "$TMP/.hpc_root_verified"
# Compare the destination EXACTLY, not by substring: the pre-fix value
# ($TMP/repo/conf) contains the correct one ($TMP/repo), so a substring check
# cannot tell them apart and would pass against the very bug under test.
fetch_dest() {   # $1 = subpath, rest = extra args; echoes the destination rsync got
    local sub="$1"; shift
    : > "$TMP/fargv.txt"
    ( cd "$TMP" && env "PATH=$PMAP:$PATH" "HPC_CONFIG=$TMP/nested.env" \
        "RSYNC_ARGV_OUT=$TMP/fargv.txt" bash "$HERE/hpc_fetch.sh" "$sub" "$@" ) >/dev/null 2>&1
    awk 'NR==1{print $NF}' "$TMP/fargv.txt"
}
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
same "a nested subpath is pulled into its PARENT (no doubled tail)" \
    "$(fetch_dest repo/conf)"          "$TMP/repo"
same "a top-level subpath resolves to the local root itself" \
    "$(fetch_dest results)"            "$TMP/."
same "a trailing slash keeps <sub> as the destination (contents of)" \
    "$(fetch_dest 'repo/conf/')"       "$TMP/repo/conf/"
same "an explicit <local-dest> is still passed verbatim" \
    "$(fetch_dest repo/conf "$TMP/somewhere")" "$TMP/somewhere"
# The landing path must be reported, and must be the mirrored path, not the
# parent that rsync was actually handed.
fout="$( ( cd "$TMP" && env "PATH=$PMAP:$PATH" "HPC_CONFIG=$TMP/nested.env" \
    "RSYNC_ARGV_OUT=$TMP/fargv2.txt" bash "$HERE/hpc_fetch.sh" repo/conf ) 2>&1 )"
# Reported landing is the mirrored path; the parent is what rsync was handed
# (asserted on the argv above). Those two together are the whole property.
check_contains "fetch prints the resolved landing path" "-> $TMP/repo/conf" "$fout"
# A single-file fetch needs its destination to pre-exist as a DIRECTORY, or rsync
# would treat the nonexistent path as a filename (repo/src/mod.py -> a file 'src').
( cd "$TMP" && env "PATH=$PMAP:$PATH" "HPC_CONFIG=$TMP/nested.env" \
    "RSYNC_ARGV_OUT=$TMP/fargv3.txt" bash "$HERE/hpc_fetch.sh" repo/src/mod.py ) >/dev/null 2>&1
if [ -d "$TMP/repo/src" ]; then ok "a single-file fetch pre-creates its destination directory"
else bad "a single-file fetch pre-creates its destination directory"; fi
rm -rf "$TMP/repo" "$TMP/somewhere"
# ...but --dry-run says "nothing will be written locally", so it must create
# nothing either — an empty directory left by a preview makes --dry-run a lie.
( cd "$TMP" && env "PATH=$PMAP:$PATH" "HPC_CONFIG=$TMP/nested.env" \
    "RSYNC_ARGV_OUT=$TMP/fargv4.txt" bash "$HERE/hpc_fetch.sh" --dry-run repo/conf ) >/dev/null 2>&1
if [ -e "$TMP/repo" ]; then bad "a --dry-run fetch creates no local directory (found $TMP/repo)"
else ok "a --dry-run fetch creates no local directory"; fi
( cd "$TMP" && env "PATH=$PMAP:$PATH" "HPC_CONFIG=$TMP/nested.env" \
    "RSYNC_ARGV_OUT=$TMP/fargv5.txt" bash "$HERE/hpc_fetch.sh" -n repo/conf x/y/dest ) >/dev/null 2>&1
if [ -e "$TMP/x" ]; then bad "...nor with an explicit <local-dest> (found $TMP/x)"
else ok "...nor with an explicit <local-dest>"; fi
rm -rf "$TMP/repo" "$TMP/x"
rm -f "$TMP/.hpc_root_verified"

section "rsync binary override (HPC_RSYNC)"
# The wrappers call whatever `rsync` is on PATH, which on macOS 15+ is openrsync
# (/usr/bin/rsync) rather than a Homebrew GNU rsync. HPC_RSYNC pins one binary.
# Since hpc.env is shared, the expected way to get this wrong is a path that
# exists on one laptop only — which must say so, not fail with a bare 127.
printf 'selftest-host::/faststorage/project/test/root\n' > "$TMP/.hpc_root_verified"
ALT="$TMP/alt_rsync"                       # deliberately NOT on PATH
cat > "$ALT" <<'SH'
#!/bin/sh
printf 'alt rsync ran: %s\n' "$*" >> "$ALT_RSYNC_LOG"
exit 0
SH
chmod +x "$ALT"
: > "$TMP/alt.log"
expect_ok "a push with HPC_RSYNC set to another binary succeeds" \
    env "PATH=$STUB:$PATH" "HPC_CONFIG=$TMP/hpc.env" "HPC_RSYNC=$ALT" "ALT_RSYNC_LOG=$TMP/alt.log" \
    bash "$HERE/hpc_push.sh"
check_contains "...and that binary is the one actually invoked" "alt rsync ran:" "$(cat "$TMP/alt.log")"

bogus="$(env "PATH=$STUB:$PATH" "HPC_CONFIG=$TMP/hpc.env" "HPC_RSYNC=$TMP/no/such/rsync" \
    bash "$HERE/hpc_push.sh" 2>&1 || true)"
expect_fail "a push with an HPC_RSYNC that does not exist fails" \
    env "PATH=$STUB:$PATH" "HPC_CONFIG=$TMP/hpc.env" "HPC_RSYNC=$TMP/no/such/rsync" \
    bash "$HERE/hpc_push.sh"
check_contains "...with an actionable message, not a bare 127" "does not exist here" "$bogus"
check_contains "...naming the config it came from" "config:" "$bogus"
expect_fail "fetch honours it too (same check, same message)" \
    env "PATH=$STUB:$PATH" "HPC_CONFIG=$TMP/hpc.env" "HPC_RSYNC=$TMP/no/such/rsync" \
    bash "$HERE/hpc_fetch.sh" repo/results
# Unset must keep working: every other check in this file relies on the PATH stub.
expect_ok "unset HPC_RSYNC still uses 'rsync' from PATH" \
    env "PATH=$STUB:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash "$HERE/hpc_push.sh"
rm -f "$TMP/.hpc_root_verified"

section "Job watcher (hpc_watch.sh)"
WATCH="$HERE/hpc_watch.sh"
# Stub ssh so the watcher sees the job already gone (squeue empty on the first
# probe => no sleep), then sacct reports a terminal state. The stub distinguishes
# calls by their command string:
#   -O check            -> master socket alive
#   ...State,ExitCode   -> the parseable verdict query
#   squeue              -> empty (job left the queue)
#   sacct (pretty)      -> one human-readable row
mk_watch_stub() {  # $1 dir  $2 final-state  $3 exit-code
    mkdir -p "$1"
    cat > "$1/ssh" <<SH
#!/bin/sh
case "\$*" in
  *"-O check"*)       exit 0 ;;
  *State,ExitCode*)   echo "$2|$3:0"; exit 0 ;;
  *squeue*)           exit 0 ;;
  *sacct*)            echo "        123  job  $2  00:01  1M  1G  $3:0"; exit 0 ;;
  *)                  exit 0 ;;
esac
SH
    chmod +x "$1/ssh"
}
mk_watch_stub "$TMP/watch_ok"   COMPLETED 0
mk_watch_stub "$TMP/watch_fail" FAILED    1

w_ok="$(env "PATH=$TMP/watch_ok:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash "$WATCH" -i 5 123 2>&1)"; w_ok_rc=$?
check_contains "watch reports a COMPLETED job" "COMPLETED" "$w_ok"
if [ "$w_ok_rc" -eq 0 ]; then ok "watch exits 0 on COMPLETED"; else bad "watch exits 0 on COMPLETED (got $w_ok_rc)"; fi

w_bad="$(env "PATH=$TMP/watch_fail:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash "$WATCH" -i 5 123 2>&1)"; w_bad_rc=$?
check_contains "watch reports a FAILED job" "FAILED" "$w_bad"
if [ "$w_bad_rc" -eq 1 ]; then ok "watch exits 1 on a non-success terminal state"; else bad "watch exits 1 on a non-success terminal state (got $w_bad_rc)"; fi

expect_fail "watch rejects a non-numeric jobid (before any ssh)" \
    env "PATH=$TMP/watch_ok:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash "$WATCH" 'abc; rm -rf /'
expect_fail "watch rejects a sub-5s interval" \
    env "PATH=$TMP/watch_ok:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash "$WATCH" -i 1 123

# A dead socket (both `-O check` and a batch probe fail) must abort fast, not hang.
mkdir -p "$TMP/watch_down"; printf '#!/bin/sh\nexit 255\n' > "$TMP/watch_down/ssh"; chmod +x "$TMP/watch_down/ssh"
expect_fail "watch refuses to start with no live SSH socket" \
    env "PATH=$TMP/watch_down:$PATH" "HPC_CONFIG=$TMP/hpc.env" bash "$WATCH" -i 5 123

if [ "$ONLINE" = 1 ]; then
    section "Online checks (read-only; uses your real hpc.env)"
    unset HPC_CONFIG
    # Load the real config in a subshell so a "no config" hpc_die can't exit us;
    # %q-quote the values so the eval back into this shell is safe.
    cfg_out="$( ( . "$LIB"; hpc_load_config; printf 'HOST=%q\nROOT=%q\n' "$HPC_HOST" "$HPC_REMOTE_ROOT" ) 2>/dev/null )"
    if [ -z "$cfg_out" ]; then
        skip "no hpc.env found from $(pwd) — run --online from inside your project"
    else
        eval "$cfg_out"   # sets HOST and ROOT from the resolved config
        if ssh -O check "$HOST" 2>/dev/null; then
            ok "ssh master socket is alive ($HOST)"
            expect_ok "hpc_status.sh (squeue) works"    bash "$HERE/hpc_status.sh"
            expect_ok "HPC_REMOTE_ROOT exists remotely" ssh "$HOST" test -d "$ROOT"
        else
            skip "no live SSH socket — run 'bash hpc_login.sh' first (you type the OTP), then retry --online"
        fi
    fi
fi

section "Summary"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
