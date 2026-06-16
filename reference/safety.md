# Hard safety rules (shared cluster)

GenomeDK and clusters like it are shared infrastructure. These rules are non-negotiable and the wrappers encode them; do not work around them.

1. **All remote writes are confined to `HPC_REMOTE_ROOT`.** Never edit `$HOME`, other projects, or anything system-wide. `hpc_push.sh`, `hpc_fetch.sh`, and `hpc_submit.py` refuse any destination outside it (`hpc_guard_remote`). Set it once in `hpc.env` and do not pass paths that escape it.

2. **No login-node compute.** The login node is for submitting jobs, rendering scripts, and short rsyncs only. Anything heavy goes through SLURM (`hpc_submit.py`). Never run training/inference/large analysis directly over `ssh <host> ...`.

3. **GPU jobs must keep the GPU busy.** GenomeDK auto-cancels GPU jobs that sit below roughly 75% utilization in the first ~2 h. If a first run looks borderline, `ssh <host> nvidia-smi` to check. Right-size `--gpus`/`--cpus`/`--mem` to what the job actually uses.

4. **rsync never uses `--delete`.** The wrappers never pass it. Per-task checkpoints and prior outputs on the remote are the resume mechanism for chunked/long runs; deleting them throws away progress.

5. **The human types the OTP, not the assistant.** Two-factor login is interactive. Probe for a live socket first (`ssh -O check`, or `bash hpc_login.sh` which is a no-op when a socket exists) and only ask the human to authenticate when the probe fails.

6. **Every action is logged.** `hpc_login.sh`, `hpc_status.sh`, `hpc_push.sh`, `hpc_fetch.sh`, and `hpc_submit.py` append one JSON line per action to `.hpc_audit.log` (gitignored), and the SLURM job appends `job_start`/`job_end` to a remote `audit.remote.log` that `hpc_fetch.sh` merges back. Inspect any time: `jq . .hpc_audit.log`. The log records intent and outcome only — never stdout/stderr — so it cannot leak data.

7. **Avoid long foreground sleeps inside ssh.** A `sleep N; ssh ...` chain that receives SIGTERM tears down the ControlMaster socket. To wait for a job, poll with short `hpc_status.sh` calls or rely on the SLURM END/FAIL email, rather than blocking on a long sleep.
