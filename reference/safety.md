# Hard safety rules (shared cluster)

GenomeDK and clusters like it are shared infrastructure. These rules are non-negotiable and the wrappers encode them; do not work around them.

The authoritative policy is the GenomeDK documentation at <https://genome.au.dk/docs/> (see *Partitions and resource limits* and *Computing with GPUs*). The figures below were current as of June 2026; if in doubt, check the docs.

1. **All remote writes are confined to `HPC_REMOTE_ROOT`.** Never edit `$HOME`, other projects, or anything system-wide. `hpc_push.sh` and `hpc_fetch.sh` refuse any destination outside it via `hpc_guard_remote` (which rejects `..` traversal *and* shell metacharacters, so a crafted path can't break out of the remote command); `hpc_submit.py` applies the equivalent check to `--name` and `--remote-subdir` before writing the job script. As a backstop against a mistyped config, the first push/submit verifies over SSH that `HPC_REMOTE_ROOT` is owned by you and refuses if not (override with `HPC_ALLOW_UNOWNED_ROOT=1` for a genuinely shared directory). Set the root once in `hpc.env` and do not pass paths that escape it.

2. **No login-node compute.** The login node is for submitting jobs, rendering scripts, and short rsyncs only. Anything heavy goes through SLURM (`hpc_submit.py`). Never run training/inference/large analysis directly over `ssh <host> ...`.

3. **GPU jobs must keep the GPU busy.** GenomeDK auto-cancels GPU jobs whose average utilization is below 75% after the first 2 h. If a first run looks borderline, `ssh <host> nvidia-smi` or `ssh <host> jobinfo <jobid>` to check. Right-size `--gpus`/`--cpus`/`--mem` to what the job actually uses.

4. **Stay within the documented per-user limits.** GenomeDK caps a single job at a **7-day** walltime, and a user at **3600 cores** and **12 GPUs** in use at once. `--chunks` chains a long run as sequential array tasks, each within the partition's walltime cap, so the total run can exceed 7 days while no single task does. Do not try to defeat these caps.

5. **rsync never uses `--delete`.** The wrappers never pass it. Per-task checkpoints and prior outputs on the remote are the resume mechanism for chunked/long runs; deleting them throws away progress. Note that push still *overwrites* a remote file whose local copy differs — preview first with `bash hpc_push.sh --dry-run` (and `hpc_fetch.sh --dry-run`), and set `HPC_PUSH_BACKUP=1` to keep overwritten copies under `$HPC_REMOTE_ROOT/.hpc_backups/<timestamp>`.

6. **The human types the OTP, not the assistant.** Two-factor login is interactive. Probe for a live socket first (`ssh -O check`, or `bash hpc_login.sh` which is a no-op when a socket exists) and only ask the human to authenticate when the probe fails.

7. **Every action is logged.** `hpc_login.sh`, `hpc_status.sh`, `hpc_push.sh`, `hpc_fetch.sh`, and `hpc_submit.py` append one JSON line per action to `.hpc_audit.log` (gitignored), and the SLURM job appends `job_start`/`job_end` to a remote `audit.remote.log` that `hpc_fetch.sh` merges back. Inspect any time: `jq . .hpc_audit.log`. The log records intent and outcome only — never stdout/stderr — so it cannot leak data.

8. **Avoid long foreground sleeps inside ssh.** A `sleep N; ssh ...` chain that receives SIGTERM tears down the ControlMaster socket. To wait for a job, poll with short `hpc_status.sh` calls or rely on the SLURM END/FAIL email, rather than blocking on a long sleep.

9. **Enforcement is opt-in (defense in depth).** Rules 1–5 live in the wrappers, but an agent could bypass them with a raw `ssh <host> 'rm -rf …'` or `rsync --delete`. Enable the PreToolUse hook (`scripts/hpc_guard_hook.py`) so the Claude Code harness blocks those directly — it only acts on cluster-targeting commands in projects that have an `hpc.env`, so it is safe to enable globally. Setup is in SKILL.md ("Enforce the safety rules with a hook"). This matters most if your settings auto-approve Bash, where there is no permission prompt to catch a bad command.
