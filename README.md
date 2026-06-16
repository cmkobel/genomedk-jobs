# genomedk-jobs

A [Claude Code](https://claude.com/claude-code) skill for offloading heavy compute from a laptop to a SLURM cluster. The laptop stays the source of truth for code; the cluster only runs jobs. Five small wrappers cover the whole loop: log in, push inputs, submit, watch the queue, fetch outputs. Everything project-specific lives in one config file, so the same skill works in any project.

Built for **GenomeDK** (Aarhus), but works on any SLURM cluster reachable through a multiplexed SSH alias.

## Install

Clone into your personal skills directory (available in every project):

```bash
git clone <repo-url> ~/.claude/skills/genomedk-jobs
```

Then in each project, copy `config/hpc.env.example` to `hpc.env` at the project root and fill in your host, account, and remote working directory. The wrappers find it by walking up from the current directory.

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

Inside Claude Code, just describe the task ("submit an ESM-2 job to GenomeDK", "check my queue") and the skill activates.

## What is here

- `SKILL.md` is the full operating manual: the workflow, the `--chunks` long-run pattern, and a worked ESM-2 example. Read this for detail.
- `config/hpc.env.example` is the one file you edit per project.
- `scripts/` holds the wrappers; `templates/job.slurm.tmpl` is the generic SBATCH template.
- `reference/ssh_setup.md` is the `~/.ssh/config` block to add (one-time per machine); `reference/safety.md` is the hard rules for a shared cluster.

## Safety

The wrappers confine every remote write to the configured project directory, never pass `rsync --delete`, and append a JSONL line per action to `.hpc_audit.log`. The human types the OTP, never the assistant. Read `reference/safety.md` before running anything on a shared cluster.
