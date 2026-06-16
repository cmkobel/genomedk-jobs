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

> **Authoritative reference.** The full GenomeDK documentation is at <https://genome.au.dk/docs/>. If anything here is unclear, or the cluster has changed (partitions, resource limits, login, GPU types), treat that site as the source of truth and consult it — this skill summarizes it but does not replace it.

## First read the safety rules

`reference/safety.md` is non-negotiable, especially: all remote writes confined to `HPC_REMOTE_ROOT`; no login-node compute; never `rsync --delete`; the **human types the OTP, not you**; every action is audited. Read it before doing anything on a cluster.

## One-time setup per project

1. **SSH alias with multiplexing.** Add a `Host` block to `~/.ssh/config` so one login lasts ~12 h. See `reference/ssh_setup.md` for the exact block.
2. **Config.** Copy `config/hpc.env.example` to `hpc.env` at the project root and fill in `HPC_HOST`, `HPC_ACCOUNT`, `HPC_REMOTE_ROOT`, `HPC_PARTITION`, `HPC_MAIL_USER`, and `HPC_PUSH_PATHS`. The wrappers find it by walking up from the current directory. It holds no secrets, so it is safe to commit. Add `.hpc_audit.log` to `.gitignore`.

## Validate the install

Before relying on the skill — and after editing or porting it — run the self-test to confirm the machinery is intact:

```bash
bash $S/hpc_selftest.sh            # offline: syntax, config loading, safety guard, template rendering, audit logger
bash $S/hpc_selftest.sh --online   # also probe the configured cluster, read-only (run from inside your project)
```

The offline checks need only `bash` + `python3`, touch nothing outside a temp dir, and never contact a cluster — Claude Code should run them after any change to the scripts or template to catch regressions. It prints a `PASS`/`FAIL` line per check and exits non-zero if anything fails. The `--online` checks reuse your real `hpc.env` and only run read-only commands (`ssh -O check`, `squeue`, `test -d`); they `SKIP` cleanly when no config or live SSH socket is present.

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
- **`hpc_submit.py` is generic.** You give it the exact command to run on the node via `--command`; per-job env activation goes in `--setup` (or the `HPC_JOB_SETUP` default in `hpc.env`). `--dry-run` prints the rendered SLURM script without submitting. The SLURM job emails `HPC_MAIL_USER` on END/FAIL. `--gpus` defaults to **1** — pass `--gpus 0` for a CPU-only job so no GPU directive is emitted.
- **Long runs: `--chunks N`.** Emits `#SBATCH --array=1-N%1` so N tasks queue but only one runs at a time. Each task resumes from your job's own checkpoint, so a multi-hour run auto-chains past a partition's walltime cap without manual resubmits. This only helps if your command itself resumes from a checkpoint on restart.
- **Partitions.** `--partition` (or `HPC_PARTITION`) takes a single name or a comma-list; SLURM picks the first free one and the walltime cap becomes the most restrictive partition in the list. On GenomeDK the GPU partitions are `gpu-l40s`/`gpu-short` (L40S, 48 GB) and `gpu-h200` (H200, 141 GB); run `gnodes` on the login node for the live list and per-node limits.
- **Status detail.** `hpc_status.sh` runs `squeue` (portable across clusters). On GenomeDK, `ssh $HPC_HOST jobinfo <jobid>` reports more — memory use and live GPU utilization — which is the quickest way to confirm a GPU job is clearing the 75%-after-2h auto-cancel threshold (see safety rule 3).
- **Push excludes.** `hpc_push.sh` skips `.git/`, `__pycache__/`, `.pixi/`, `.ipynb_checkpoints/`, `*.ipynb`, and `.DS_Store`. Note that notebooks (`*.ipynb`) are excluded by default; pass a notebook explicitly as a `<local>` argument if a job needs one.

## Dependencies: pixi

The wrappers do not install anything themselves — they just run the `--command` you give them on the node. **The assumed default environment manager is [pixi](https://pixi.sh), and every example here uses it.** If you use pixi, follow this convention; if not, see the note at the end.

1. **Commit `pixi.toml` and `pixi.lock`** to your repo and list them in `HPC_PUSH_PATHS` (the example does: `"src scripts pixi.toml pixi.lock"`) so `hpc_push.sh` syncs the lockfile up with your code.
2. **Install on the login node, once, after pushing and before submitting** — never inside a job, because compute nodes have no internet (GenomeDK downloads happen only on the front-end). On GenomeDK the login node has no GPU, so set `CONDA_OVERRIDE_CUDA` to let pixi resolve GPU-flavored packages:
   ```bash
   ssh $HPC_HOST 'cd <HPC_REMOTE_ROOT>/<HPC_CODE_SUBDIR> && CONDA_OVERRIDE_CUDA=12.0 pixi install -e hpc'
   ```
   Re-run this whenever `pixi.lock` changes. Point `PIXI_CACHE_DIR` at a project-dir path in `HPC_JOB_SETUP` (see the example) so the cache is reused across jobs and stays inside `HPC_REMOTE_ROOT`.
3. **Run your job through pixi** via `--command "pixi run -e hpc python work.py"`, and put `export PATH=$HOME/.pixi/bin:$PATH` in `HPC_JOB_SETUP` so the node finds the `pixi` binary.

**Using something else (conda/mamba, a venv, apptainer)?** The skill still works — it is manager-agnostic. Put the activation in `HPC_JOB_SETUP` (or `--setup`) and the run in `--command`. The one rule that carries over: build or pull the environment on the login node once, never inside a job (GenomeDK is explicit about this — e.g. "never put `apptainer pull` in a job script").

## Worked example: ESM-2 embeddings on GenomeDK

This is the workflow the skill was generalized from. With `hpc.env` set to `HPC_REMOTE_ROOT=/faststorage/project/PM_group/carl/01_saturn`, `HPC_CODE_SUBDIR=repo`, and `HPC_JOB_SETUP='export PIXI_CACHE_DIR=$REMOTE_ROOT/.pixi-cache; export PATH=$HOME/.pixi/bin:$PATH; export TORCH_HOME=$REMOTE_ROOT/.torch-cache'` (single-quoted so `$REMOTE_ROOT` is expanded inside the job, not when the config is read):

```bash
bash $S/hpc_login.sh
bash $S/hpc_push.sh                                          # src/ scripts/ pixi.toml pixi.lock
bash $S/hpc_push.sh data/proteomes_clean/Triticum_aestivum.IWGSC.pep.all_clean.fa data/proteomes_clean
python $S/hpc_submit.py --name esm2-wheat --chunks 3 --time 12:00:00 \
    --command "pixi run -e hpc python scripts/compute_esm2.py --species wheat --device cuda"
# ... SLURM emails on END/FAIL ...
bash $S/hpc_fetch.sh data/embeddings_per_protein/Triticum_aestivum.IWGSC
```

GenomeDK specifics baked into the template / known gotchas: download from the internet only on the login/front-end node — GenomeDK's policy is never to fetch external data inside a job — so prefetch model weights on the login node into a project-dir cache that `HPC_JOB_SETUP` points at (`TORCH_HOME`); the template pins `OMP_NUM_THREADS` and sets `KMP_AFFINITY=disabled` because some nodes' cgroup cpusets trip the libomp affinity assertion at torch import (installing the env is covered under [Dependencies](#dependencies-pixi) above). For I/O-bound GPU jobs the docs recommend staging inputs to node-local `$TMPDIR` for higher, steadier throughput (which also helps keep GPU utilization above the 75% floor).

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
│   ├── hpc_fetch.sh            # rsync outputs down (never --delete)
│   └── hpc_selftest.sh         # validate the skill (offline; --online probes the cluster)
├── templates/job.slurm.tmpl    # generic SBATCH template (@@PLACEHOLDER@@ substitution)
└── reference/
    ├── ssh_setup.md            # the ~/.ssh/config block to add
    └── safety.md               # the hard rules for a shared cluster
```

## Porting and sharing

The directory is self-contained: copy it into another project's `.claude/skills/` (or into `~/.claude/skills/` to make it available across all your projects), give that project its own `hpc.env`, and it works. Colleagues get it by copying the same directory and writing their own `hpc.env` with their account and project path. Nothing in `scripts/` or `templates/` is project-specific; all of that lives in `hpc.env`.

For a non-GenomeDK SLURM cluster, point `hpc.env` at that cluster's host/account/partition/root. Adjust the `HPC_JOB_SETUP` env activation and trim the GenomeDK-specific lines in `templates/job.slurm.tmpl` (the `KMP_AFFINITY`/`OMP_NUM_THREADS` block) if they do not apply.
