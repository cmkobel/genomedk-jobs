"""Append one JSON line to the HPC audit log for every remote action.

The log is intentionally minimal: timestamp, actor, action verb, and
action-specific kwargs. It never contains stdout/stderr (which could leak
data) — only structured intent and outcome. Audit it any time with:
    jq . .hpc_audit.log

Location: $HPC_AUDIT_LOG, else $HPC_LOCAL_ROOT/.hpc_audit.log, else
./.hpc_audit.log.

CLI use (from the bash wrappers):
    python _hpc_log.py <action> [--key value ...]

Python use:
    from _hpc_log import log
    log("rsync_push", host="genomedk", target="...", exit=0)
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sys
from pathlib import Path


def _log_path() -> Path:
    explicit = os.environ.get("HPC_AUDIT_LOG")
    if explicit:
        return Path(explicit)
    root = os.environ.get("HPC_LOCAL_ROOT", ".")
    return Path(root) / ".hpc_audit.log"


def _actor() -> str:
    actor = os.environ.get("HPC_AUDIT_ACTOR")
    if actor:
        return actor
    # CLAUDE_CODE / CLAUDECODE is set in the Claude Code environment.
    if os.environ.get("CLAUDE_CODE") or os.environ.get("CLAUDECODE"):
        return "claude-code"
    return "human"


def log(action: str, **fields) -> None:
    entry = {
        "ts": _dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "actor": _actor(),
        "action": action,
        **fields,
    }
    path = _log_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(entry, separators=(",", ":")) + "\n")


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument("action")
    args, extra = p.parse_known_args(argv)
    fields: dict[str, object] = {}
    it = iter(extra)
    for tok in it:
        if not tok.startswith("--"):
            raise SystemExit(f"expected --key value pairs, got {tok!r}")
        key = tok[2:]
        try:
            val = next(it)
        except StopIteration:
            raise SystemExit(f"--{key} requires a value")
        fields[key] = int(val) if val.lstrip("-").isdigit() else val
    log(args.action, **fields)


if __name__ == "__main__":
    main(sys.argv[1:])
