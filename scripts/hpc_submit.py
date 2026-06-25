"""Render a SLURM job from a template and submit it to the cluster over SSH.

Generic: you supply the command to run on the compute node, and this builds the
SBATCH header (account / partition / resources / mail), optionally chains a long
run via array chunks, writes the rendered script under HPC_REMOTE_ROOT/slurm_logs,
submits it with `ssh <host> sbatch`, captures the jobid, and audits the action.
All remote writes are confined to HPC_REMOTE_ROOT.

Config (host, account, remote root, partition, mail, job setup) is read from the
project's hpc.env — found via $HPC_CONFIG or by walking up from the cwd.

Examples:
    # one-off GPU job
    python hpc_submit.py --name train --command "pixi run -e hpc python train.py" \
        --time 12:00:00 --gpus 1 --cpus 8 --mem 16g

    # chain a long run as 3 sequential array tasks (each resumes from a checkpoint)
    python hpc_submit.py --name esm2-wheat --chunks 3 --gpus 1 --time 12:00:00 \
        --command "pixi run -e hpc python scripts/compute_esm2.py --species wheat --device cuda"

    # CPU-only job (the default): no GPU directive is emitted
    python hpc_submit.py --name primes --cpus 1 --mem 2g --time 00:05:00 \
        --command "python3 scripts/compute_primes.py"

    # see the rendered script without submitting
    python hpc_submit.py --name probe --command "nvidia-smi" --dry-run
"""
from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPTS_DIR.parent
sys.path.insert(0, str(SCRIPTS_DIR))
from _hpc_log import log  # noqa: E402


def load_config() -> dict:
    """Find and parse hpc.env (KEY=value). Same search order as _hpc_lib.sh."""
    cfg_path = os.environ.get("HPC_CONFIG")
    if not cfg_path:
        start = Path.cwd()
        for cand in (start, *start.parents):
            for name in ("hpc.env", ".hpc/hpc.env"):
                p = cand / name
                if p.is_file():
                    cfg_path = str(p)
                    break
            if cfg_path:
                break
    if not cfg_path or not Path(cfg_path).is_file():
        raise SystemExit(
            "no HPC config found. Set HPC_CONFIG or create hpc.env at your "
            "project root (see config/hpc.env.example)."
        )
    cfg: dict[str, str] = {}
    for raw in Path(cfg_path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        cfg[key.strip()] = val.strip().strip('"').strip("'")

    for required in ("HPC_HOST", "HPC_ACCOUNT", "HPC_REMOTE_ROOT"):
        if not cfg.get(required):
            raise SystemExit(f"{required} is unset in {cfg_path}")
    if not cfg["HPC_REMOTE_ROOT"].startswith("/"):
        raise SystemExit(f"HPC_REMOTE_ROOT must be absolute: {cfg['HPC_REMOTE_ROOT']}")
    cfg.setdefault("HPC_LOCAL_ROOT", str(Path(cfg_path).resolve().parent))
    cfg.setdefault("HPC_CODE_SUBDIR", "repo")
    cfg["_config_path"] = cfg_path
    return cfg


def render(tmpl: str, mapping: dict[str, str]) -> str:
    out = tmpl
    for key, val in mapping.items():
        out = out.replace(f"@@{key}@@", val)
    return out


_SAFE = re.compile(r"\A[A-Za-z0-9._/-]+\Z")


def reject_unsafe(val: str, what: str, allow_slash: bool = True) -> str:
    """Reject a value with shell metacharacters before it reaches a remote shell
    (mirrors hpc_reject_unsafe in _hpc_lib.sh). Set allow_slash=False for a bare
    filename like --name."""
    pat = _SAFE if allow_slash else re.compile(r"\A[A-Za-z0-9._-]+\Z")
    if not val or ".." in val or not pat.match(val):
        kind = "letters, digits, . _ -" + (" /" if allow_slash else " (no '/')")
        raise SystemExit(f"{what} must use only {kind}, no '..': {val!r}")
    return val


def guard_under_root(path: str, root: str, what: str) -> str:
    """Reject a remote path that escapes HPC_REMOTE_ROOT (mirrors hpc_guard_remote
    in _hpc_lib.sh). Returns the normalized path."""
    norm = os.path.normpath(path)
    if norm != root and not norm.startswith(root.rstrip("/") + "/"):
        raise SystemExit(f"refusing to operate outside HPC_REMOTE_ROOT ({root}): {what}={path}")
    return norm


def verify_root(host: str, root: str, local_root: str) -> None:
    """Confirm HPC_REMOTE_ROOT is owned by us before writing, so a mistyped config
    can't submit into another project. Honors the same marker + override as
    hpc_verify_root in _hpc_lib.sh: a push earlier in the session already verified."""
    marker = Path(local_root) / ".hpc_root_verified"
    want = f"{host}::{root}"
    try:
        if marker.is_file() and marker.read_text().strip() == want:
            return
    except OSError:
        pass
    probe = (f"if [ ! -e {shlex.quote(root)} ]; then echo missing; "
             f"elif [ -O {shlex.quote(root)} ]; then echo owned; else echo notowned; fi")
    res = subprocess.run(["ssh", host, probe], capture_output=True, text=True)
    if res.returncode != 0:
        raise SystemExit(f"could not reach {host} to verify HPC_REMOTE_ROOT — "
                         "is the SSH socket up? (run hpc_login.sh)")
    status = res.stdout.strip()
    if status == "notowned" and os.environ.get("HPC_ALLOW_UNOWNED_ROOT") != "1":
        raise SystemExit(
            f"HPC_REMOTE_ROOT exists but is not owned by you on {host}:\n  {root}\n"
            "  This often means hpc.env points at the wrong path. If it is genuinely\n"
            "  yours (a shared project dir), re-run with HPC_ALLOW_UNOWNED_ROOT=1.")
    if status == "missing":
        sys.stderr.write(f"note: HPC_REMOTE_ROOT does not exist yet on {host}: {root}\n")
    try:
        marker.write_text(want + "\n")
    except OSError:
        pass


def _preparse_config() -> None:
    """Honor -c/--config before load_config() runs (defaults are drawn from the
    config, so it must be resolved before argparse builds the parser)."""
    argv = sys.argv[1:]
    for i, a in enumerate(argv):
        if a in ("-c", "--config") and i + 1 < len(argv):
            os.environ["HPC_CONFIG"] = argv[i + 1]
            return
        if a.startswith("--config="):
            os.environ["HPC_CONFIG"] = a.split("=", 1)[1]
            return


def main() -> None:
    _preparse_config()
    cfg = load_config()
    # Make the audit helper write to this project's log.
    os.environ.setdefault("HPC_LOCAL_ROOT", cfg["HPC_LOCAL_ROOT"])
    if cfg.get("HPC_AUDIT_LOG"):
        os.environ.setdefault("HPC_AUDIT_LOG", cfg["HPC_AUDIT_LOG"])

    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--name", required=True,
                   help="job name (also the rendered .slurm filename)")
    p.add_argument("--command", required=True,
                   help="the command to run on the compute node")
    p.add_argument("--setup", default=cfg.get("HPC_JOB_SETUP", ""),
                   help="shell lines run before the command (env activation, caches); "
                        "defaults to HPC_JOB_SETUP from hpc.env")
    p.add_argument("--time", default="12:00:00", help="walltime HH:MM:SS")
    p.add_argument("--partition", default=cfg.get("HPC_PARTITION", ""),
                   help="single name or comma-list; SLURM picks the first free one")
    p.add_argument("--gpus", type=int, default=0,
                   help="GPUs to request; default 0 (CPU-only, no GPU directive). "
                        "Pass --gpus N to request a GPU.")
    p.add_argument("-c", "--config",
                   help="path to hpc.env (overrides directory-walk discovery); "
                        "equivalent to setting HPC_CONFIG")
    p.add_argument("--cpus", type=int, default=8)
    p.add_argument("--mem", default="16g")
    p.add_argument("--chunks", type=int, default=1,
                   help="sequential array tasks via --array=1-N%%1; each task resumes "
                        "from a checkpoint to auto-chain a run past a walltime cap")
    p.add_argument("--remote-subdir", default=cfg["HPC_CODE_SUBDIR"],
                   help="job working dir relative to HPC_REMOTE_ROOT")
    p.add_argument("--template", default=str(SKILL_DIR / "templates" / "job.slurm.tmpl"))
    p.add_argument("--dry-run", action="store_true",
                   help="print the rendered script and exit without submitting")
    args = p.parse_args()
    if args.chunks < 1:
        raise SystemExit("--chunks must be >= 1")

    host = cfg["HPC_HOST"]
    root = cfg["HPC_REMOTE_ROOT"]
    reject_unsafe(root, "HPC_REMOTE_ROOT")  # interpolated into remote shells
    mail_user = cfg.get("HPC_MAIL_USER", "")

    # Safety guard: --name becomes a remote filename and --remote-subdir a remote
    # working dir, both interpolated into remote shell commands — so restrict them
    # to a safe charset and keep them inside HPC_REMOTE_ROOT (see safety.md).
    reject_unsafe(args.name, "--name", allow_slash=False)
    reject_unsafe(args.remote_subdir, "--remote-subdir")
    guard_under_root(f"{root}/slurm_logs/{args.name}.slurm", root, "--name")
    guard_under_root(f"{root}/{args.remote_subdir}", root, "--remote-subdir")

    mail_block = (f"#SBATCH --mail-type END,FAIL\n#SBATCH --mail-user {mail_user}\n"
                  if mail_user else "")
    gpu_block = f"#SBATCH --gpus {args.gpus}\n" if args.gpus > 0 else ""
    array_block = f"#SBATCH --array=1-{args.chunks}%1\n" if args.chunks > 1 else ""
    partition_block = f"#SBATCH --partition {args.partition}\n" if args.partition else ""

    rendered = render(Path(args.template).read_text(), {
        "ACCOUNT": cfg["HPC_ACCOUNT"],
        "PARTITION_BLOCK": partition_block,
        "ARRAY_BLOCK": array_block,
        "GPU_BLOCK": gpu_block,
        "CPUS": str(args.cpus),
        "MEM": args.mem,
        "TIME": args.time,
        "NAME": args.name,
        "REMOTE_ROOT": root,
        "REMOTE_SUBDIR": args.remote_subdir,
        "MAIL_BLOCK": mail_block,
        "SETUP": args.setup,
        "COMMAND": args.command,
    })

    if args.dry_run:
        print(rendered)
        return

    # Confirm the root is really ours before writing anything to it.
    verify_root(host, root, cfg["HPC_LOCAL_ROOT"])

    remote_path = f"{root}/slurm_logs/{args.name}.slurm"
    qpath = shlex.quote(remote_path)
    print(f"Submitting name={args.name} partition={args.partition or '(default)'} "
          f"gpus={args.gpus} time={args.time} chunks={args.chunks}")

    subprocess.run(["ssh", host, f"mkdir -p {shlex.quote(root + '/slurm_logs')}"], check=True)
    write = subprocess.run(["ssh", host, f"cat > {qpath}"],
                           input=rendered, text=True)
    if write.returncode != 0:
        raise SystemExit("failed to write the SLURM script on the remote")

    proc = subprocess.run(["ssh", host, f"sbatch {qpath}"],
                          capture_output=True, text=True)
    out = proc.stdout.strip()
    jobid = out.split()[-1] if (proc.returncode == 0 and out) else "?"
    # Audit every submission attempt, success or failure (not just the happy path).
    log("sbatch_submit", host=host, name=args.name, script=remote_path,
        jobid=jobid, exit=proc.returncode)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(f"sbatch failed (rc={proc.returncode})")

    print(f"\nSubmitted jobid={jobid}")
    print(f"Watch:  ssh {host} squeue -j {jobid}")
    print(f"Logs:   ssh {host} tail -f {root}/slurm_logs/{jobid}.out")


if __name__ == "__main__":
    main()
