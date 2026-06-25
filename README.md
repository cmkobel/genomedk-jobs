# genomedk-jobs

A [Claude Code](https://claude.com/claude-code) skill for offloading heavy compute from a laptop to a SLURM cluster. The laptop stays the source of truth for code; the cluster only runs jobs. Five small wrappers cover the whole loop: log in, push inputs, submit, watch the queue, fetch outputs. Everything project-specific lives in one config file, so the same skill works in any project.

Built for **GenomeDK** (Aarhus), but works on any SLURM cluster reachable through a multiplexed SSH alias.

> The authoritative GenomeDK documentation is at <https://genome.au.dk/docs/>. This skill summarizes the parts it automates (login, partitions, GPU/resource limits); if anything is unclear or the cluster has changed, that site is the source of truth.

## Install

**1. Clone** into your personal skills directory (available in every project):

```bash
git clone https://codeberg.org/cmkobel/genomedk-jobs.git ~/.claude/skills/genomedk-jobs
```

**2. Add the SSH alias** (one-time per machine). Put a `Host` block with connection multiplexing in `~/.ssh/config` so one login lasts the session. The exact block is in `reference/ssh_setup.md`.

**3. Create the config** (once per project). Copy the example to your project root and fill it in:

```bash
cp ~/.claude/skills/genomedk-jobs/config/hpc.env.example /path/to/project/hpc.env
```

Set at least `HPC_HOST`, `HPC_ACCOUNT`, and `HPC_REMOTE_ROOT` (every remote write is confined to that directory); also `HPC_PARTITION`, `HPC_MAIL_USER`, and `HPC_PUSH_PATHS`. The file holds no secrets, so it is safe to commit. The wrappers find it by walking up from the current directory, so commands work from anywhere inside the project.

## Use

```bash
S=~/.claude/skills/genomedk-jobs/scripts
bash   $S/hpc_login.sh                               # warm the SSH socket (you type the OTP)
bash   $S/hpc_push.sh                                # rsync inputs up
python $S/hpc_submit.py --name myjob --gpus 1 --time 12:00:00 \
       --command "pixi run -e hpc python work.py"    # render + sbatch
bash   $S/hpc_status.sh                              # squeue (read-only)
bash   $S/hpc_fetch.sh results/myjob                 # rsync outputs back
```

The assumed environment manager is **[pixi](https://pixi.sh)**: commit `pixi.toml`/`pixi.lock`, install once on the login node (`CONDA_OVERRIDE_CUDA=12.0 pixi install -e hpc`) since compute nodes have no internet, and run jobs via `pixi run`. Other managers (conda, venv, apptainer) work too — put activation in `HPC_JOB_SETUP`. See the **Dependencies** section in `SKILL.md`.

Inside Claude Code, just describe the task ("submit an ESM-2 job to GenomeDK", "check my queue") and the skill activates.

## What is here

- `SKILL.md` is the full operating manual: the workflow, the `--chunks` long-run pattern, and a worked ESM-2 example. Read this for detail.
- `config/hpc.env.example` is the one file you edit per project.
- `scripts/` holds the wrappers; `templates/job.slurm.tmpl` is the generic SBATCH template.
- `scripts/hpc_selftest.sh` validates the install: `bash scripts/hpc_selftest.sh` runs offline checks (syntax, config loading, the safety guard, template rendering, the audit logger); add `--online` to also probe a configured cluster read-only.
- `reference/ssh_setup.md` is the `~/.ssh/config` block to add (one-time per machine); `reference/safety.md` is the hard rules for a shared cluster.

## Safety

The wrappers confine every remote write to the configured project directory, never pass `rsync --delete`, and append a JSONL line per action to `.hpc_audit.log`. The human types the OTP, never the assistant. Beyond that:

- **Injection-hardened.** Every agent-supplied value that reaches a remote shell (job name, jobid, paths) is restricted to a safe character set and quoted, so a crafted input can't break out of the remote command.
- **Wrong-root protection.** The first push/submit verifies over SSH that `HPC_REMOTE_ROOT` is owned by you, catching a mistyped path before it writes into another project.
- **Preview & recover.** `--dry-run` on push/fetch previews without writing; `HPC_PUSH_BACKUP=1` keeps copies of anything an overwrite would replace.
- **Optional enforcement hook.** `scripts/hpc_guard_hook.py` is a PreToolUse hook that blocks raw `rsync --delete` / destructive `ssh <host> …` even if the wrappers are bypassed — see SKILL.md to enable it (recommended if your settings auto-approve Bash).

Read `reference/safety.md` before running anything on a shared cluster.

## License

[MIT](LICENSE). Provided as-is, without warranty of any kind; the authors are not liable for any damages arising from its use.
