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
rm -f "$TMP/.hpc_root_verified"

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
