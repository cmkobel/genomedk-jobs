#!/usr/bin/env python3
"""Claude Code PreToolUse hook for the genomedk-jobs skill — defense in depth.

The wrappers confine writes to HPC_REMOTE_ROOT and never delete, but an agent
could bypass them by running raw `ssh <host> 'rm -rf ...'` or `rsync --delete`
directly. This hook inspects each Bash command and BLOCKS (exit code 2) the
clearly destructive ones that target the configured cluster, turning the
safety.md rules from "the agent should" into "the harness won't let it".

Scope is deliberately narrow to avoid false positives:
  * It does nothing unless an hpc.env is found (so it only acts in projects that
    use this skill) and the command references that project's HPC_HOST.
  * It only inspects ssh/rsync/scp commands — local commands are never touched.
  * It blocks rsync --delete and a short list of high-harm remote operations
    (recursive/forced rm, mkfs, dd of=, fork bombs, recursive chmod/chown,
    redirects into system paths). Normal wrapper calls and reads pass through.

Enable it by adding a PreToolUse hook to settings.json (see SKILL.md /
reference/safety.md). It is best-effort: on any internal error it fails open
(exit 0) so a hook bug can never wedge your shell — the hardened wrappers remain
the primary safeguard.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

# (regex, human reason). Matched against the full Bash command string.
RULES = [
    (r"\brsync\b.*--delete",
     "rsync --delete removes remote files; the wrappers never use it because "
     "remote checkpoints/outputs are the resume mechanism for long runs."),
    (r"\brm\b\s+(?:-\S*[rf]\S*\s+)+",
     "remote 'rm -r/-f' is blocked: deleting under HPC_REMOTE_ROOT throws away "
     "job checkpoints and outputs."),
    (r"\bmkfs\b", "mkfs is destructive and never appropriate from this skill."),
    (r"\bdd\b[^|]*\bof=/", "dd writing to a device/path is blocked."),
    (r":\s*\(\s*\)\s*\{", "fork-bomb pattern blocked."),
    (r"\bchmod\b\s+-R\b", "recursive chmod over ssh is blocked."),
    (r"\bchown\b\s+-R\b", "recursive chown over ssh is blocked."),
    (r">\s*/(?:etc|usr|bin|boot|sys|proc|lib)\b",
     "redirect into a system path (e.g. > /etc/...) is blocked."),
    # Block writes to device files (e.g. > /dev/sda) but NOT the universally
    # benign sinks 2>/dev/null, >/dev/stdout|stderr|tty, >/dev/fd/N — otherwise a
    # routine `... 2>/dev/null` diagnostic would be refused.
    (r">\s*/dev/(?!(?:null|stdout|stderr|tty)\b|fd/)",
     "redirect to a device file is blocked (/dev/null, /dev/std{out,err}, "
     "/dev/tty, /dev/fd/N are allowed)."),
]


def find_host() -> str | None:
    """Read HPC_HOST from the project's hpc.env (same search order as the wrappers)."""
    candidates = []
    if os.environ.get("HPC_CONFIG"):
        candidates.append(Path(os.environ["HPC_CONFIG"]))
    cwd = Path.cwd()
    for d in (cwd, *cwd.parents):
        candidates.append(d / "hpc.env")
        candidates.append(d / ".hpc" / "hpc.env")
    for p in candidates:
        try:
            if not p.is_file():
                continue
            for line in p.read_text().splitlines():
                key, sep, val = line.strip().partition("=")
                if sep and key.strip() == "HPC_HOST":
                    return val.strip().strip('"').strip("'")
        except OSError:
            continue
    return None


def main() -> None:
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        sys.exit(0)  # not a payload we understand — let it through
    if data.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = (data.get("tool_input") or {}).get("command", "")
    if not cmd or not re.search(r"\b(?:ssh|rsync|scp)\b", cmd):
        sys.exit(0)
    host = find_host()
    if not host or not re.search(r"\b" + re.escape(host) + r"\b", cmd):
        sys.exit(0)  # only police commands targeting the configured cluster

    for pat, reason in RULES:
        if re.search(pat, cmd):
            sys.stderr.write(
                "genomedk-jobs safety hook BLOCKED this command.\n"
                f"Reason: {reason}\n"
                "Use the skill's wrappers (hpc_push.sh / hpc_fetch.sh / "
                "hpc_submit.py / hpc_status.sh): they confine writes to "
                "HPC_REMOTE_ROOT and never delete. See reference/safety.md.\n")
            sys.exit(2)  # exit 2 = block the tool call (fail closed on a match)
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)  # best-effort: never wedge the shell on a hook bug
