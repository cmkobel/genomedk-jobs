---
name: genomedk-jobs
description: >-
  Submit, monitor, and retrieve SLURM batch jobs on GenomeDK (or any SLURM
  cluster reachable over SSH). Use when the user wants to run heavy compute on
  GenomeDK or an HPC cluster: logging in, syncing inputs up, submitting a batch
  job, checking the queue, or pulling outputs back. Config-driven (host,
  account, remote working directory) so it ports across projects unchanged.
---

# genomedk-jobs

Offload heavy compute from a laptop to a SLURM cluster. The laptop stays the source of truth for code; the cluster only runs jobs. Five small wrappers cover the whole loop: log in, push inputs, submit, watch the queue, fetch outputs. Everything project-specific lives in one config file (`hpc.env`), so the same skill works in any project once that file is filled in.

Primary target is **GenomeDK** (Aarhus). It also works on any SLURM cluster you can reach with a multiplexed SSH alias.

## First read the safety rules

`reference/safety.md` is non-negotiable, especially: all remote writes confined to `HPC_REMOTE_ROOT`; no login-node compute; never `rsync --delete`; the **human types the OTP, not you**; every action is audited. Read it before doing anything on a cluster.

## One-time setup per project

1. **SSH alias with multiplexing.** Add a `Host` block to `~/.ssh/config` so one login lasts ~12 h. See `reference/ssh_setup.md` for the exact block.
2. **Config.** Copy `config/hpc.env.example` to `hpc.env` at the project root and fill in `HPC_HOST`, `HPC_ACCOUNT`, `HPC_REMOTE_ROOT`, `HPC_PARTITION`, `HPC_MAIL_USER`, and `HPC_PUSH_PATHS`. The wrappers find it by walking up from the current directory. It holds no secrets, so it is safe to commit. Add `.hpc_audit.log` to `.gitignore`.

## The workflow

Run scripts from the skill's `scripts/` directory (adjust the path to wherever the skill is installed, e.g. `.claude/skills/genomedk-jobs/scripts/`):

```bash
S=.claude/skills/genomedk-jobs/scripts

bash $S/hpc_login.sh                      # warm the SSH socket (human types OTP if needed)
bash $S/hpc_push.sh                       # rsync HPC_PUSH_PATHS up to the remote
python $S/hpc_submit.py --name myjob \
    --command "pixi run -e hpc python work.py" \
    --time 12:00:00 --gpus 1 --cpus 8 --mem 16g
bash $S/hpc_status.sh                      # squeue for you (read-only); pass a jobid for one job
bash $S/hpc_fetch.sh results/myjob         # rsync a remote subpath back down
```

- **Always probe before asking for the OTP.** `hpc_login.sh` is a no-op when a socket is already alive, so run it (or `ssh -O check <host>`) first and only ask the human to authenticate when it fails. You cannot type the OTP yourself.
- **`hpc_submit.py` is generic.** You give it the exact command to run on the node via `--command`; per-job env activation goes in `--setup` (or the `HPC_JOB_SETUP` default in `hpc.env`). `--dry-run` prints the rendered SLURM script without submitting. The SLURM job emails `HPC_MAIL_USER` on END/FAIL.
- **Long runs: `--chunks N`.** Emits `#SBATCH --array=1-N%%1` so N tasks queue but only one runs at a time. Each task resumes from your job's own checkpoint, so a multi-hour run auto-chains past a partition's walltime cap without manual resubmits. This only helps if your command itself resumes from a checkpoint on restart.
- **Partitions.** `--partition` (or `HPC_PARTITION`) takes a single name or a comma-list; SLURM picks the first free one and the walltime cap becomes the most restrictive partition in the list.

## Worked example: ESM-2 embeddings on GenomeDK

This is the workflow the skill was generalized from. With `hpc.env` set to `HPC_REMOTE_ROOT=/faststorage/project/PM_group/carl/01_saturn`, `HPC_CODE_SUBDIR=repo`, and `HPC_JOB_SETUP="export PIXI_CACHE_DIR=$REMOTE_ROOT/.pixi-cache; export PATH=$HOME/.pixi/bin:$PATH; export TORCH_HOME=$REMOTE_ROOT/.torch-cache"`:

```bash
bash $S/hpc_login.sh
bash $S/hpc_push.sh                                          # src/ scripts/ pixi.toml pixi.lock
bash $S/hpc_push.sh data/proteomes_clean/Triticum_aestivum.IWGSC.pep.all_clean.fa data/proteomes_clean
python $S/hpc_submit.py --name esm2-wheat --chunks 3 --time 12:00:00 \
    --command "pixi run -e hpc python scripts/compute_esm2.py --species wheat --device cuda"
# ... SLURM emails on END/FAIL ...
bash $S/hpc_fetch.sh data/embeddings_per_protein/Triticum_aestivum.IWGSC
```

GenomeDK specifics baked into the template / known gotchas: GPU compute nodes are firewalled from the internet, so prefetch model weights from the login node into a project-dir cache that `HPC_JOB_SETUP` points at (`TORCH_HOME`); the template pins `OMP_NUM_THREADS` and sets `KMP_AFFINITY=disabled` because some nodes' cgroup cpusets trip the libomp affinity assertion at torch import; and `pixi install` on the CUDA-less login node needs `CONDA_OVERRIDE_CUDA=12.0`.

## What is in this directory

```
genomedk-jobs/
├── SKILL.md                    # this file
├── config/hpc.env.example      # copy to hpc.env at the project root and fill in
├── scripts/
│   ├── _hpc_lib.sh             # config loader + remote-root guard + audit (sourced)
│   ├── _hpc_log.py             # JSONL audit logger
│   ├── hpc_login.sh            # warm the SSH ControlMaster socket
│   ├── hpc_status.sh           # squeue (read-only)
│   ├── hpc_push.sh             # rsync inputs/code up (never --delete)
│   ├── hpc_submit.py           # render template + sbatch + capture jobid
│   └── hpc_fetch.sh            # rsync outputs down (never --delete)
├── templates/job.slurm.tmpl    # generic SBATCH template (@@PLACEHOLDER@@ substitution)
└── reference/
    ├── ssh_setup.md            # the ~/.ssh/config block to add
    └── safety.md               # the hard rules for a shared cluster
```

## Porting and sharing

The directory is self-contained: copy it into another project's `.claude/skills/` (or into `~/.claude/skills/` to make it available across all your projects), give that project its own `hpc.env`, and it works. Colleagues get it by copying the same directory and writing their own `hpc.env` with their account and project path. Nothing in `scripts/` or `templates/` is project-specific; all of that lives in `hpc.env`.

For a non-GenomeDK SLURM cluster, point `hpc.env` at that cluster's host/account/partition/root. Adjust the `HPC_JOB_SETUP` env activation and trim the GenomeDK-specific lines in `templates/job.slurm.tmpl` (the `KMP_AFFINITY`/`OMP_NUM_THREADS` block) if they do not apply.
