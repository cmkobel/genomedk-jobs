#!/usr/bin/env python3
"""Claude Code PreToolUse hook for the genomedk-jobs skill — defense in depth.

The wrappers confine writes to HPC_REMOTE_ROOT and never delete, but an agent
could bypass them by running raw `ssh <host> 'rm -rf ...'` or `rsync --delete`
directly. This hook inspects each Bash command and BLOCKS (exit code 2) the
common destructive ones that target the configured cluster, catching an
accidental footgun before it runs.

The whole design question is *what to judge*. Matching the destructive patterns
against the raw command string does not work: `rsync host:/out ./out && rm -rf
./out/tmp` is a remote read plus a local cleanup, and a bare word-match for the
host fires on any path that merely contains it (`~/.claude/skills/genomedk-jobs`
matches `\\bgenomedk\\b`). Both read as attacks; neither is one. So instead:

  1. Lex the command into segments at unquoted `;` `&&` `||` `|` `&` newline.
  2. Keep only the segments that actually reach the cluster — `ssh <host> ...`
     with the host in the *operand* position, or an rsync/scp whose endpoint is
     `[user@]<host>:path`. A local segment sitting next to a remote one is never
     judged, and a host name inside a path or a comment targets nothing.
  3. Apply the rules to the remote command text alone (for ssh) or the transfer's
     own option words (for rsync/scp). Since everything judged runs on the
     cluster, the rules can be broad without touching local work: a bare `rm`
     counts, not just `rm -rf`.

Lexing also strips quotes, which both un-nests the remote command out of
`ssh host 'rm -rf x'` and collapses an obfuscated `r''m` back to `rm`.

This is a best-effort backstop, NOT a security boundary. It still cannot reason
about intent, and several bypasses are inherent to inspecting a command string:
addressing the cluster by its real hostname or IP instead of the configured
HPC_HOST alias, piping a script over stdin (`ssh host bash -s < x.sh`), queueing
one (`ssh host sbatch cleanup.sh`), an interactive `ssh -t host`, or an un-listed
verb whose data loss looks like ordinary work (`mv` off the tree, a truncating
`> results.ckpt`). Treat it as a seatbelt against mistakes; the hardened wrappers
(which confine writes and never delete) remain the actual safeguard. On any
internal error it fails open (exit 0) so a hook bug can never wedge your shell.
Enable it via a PreToolUse hook in settings.json (see SKILL.md /
reference/safety.md).
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


def at_cmd(pat: str) -> str:
    """Anchor `pat` at a position where a command can actually start.

    The lookbehind rejects a match that is really part of a longer word, a path
    segment, or an option cluster — `grep -rm 1 x` must not read as an `rm`.
    Everything else stays a valid start: string start, whitespace, `;`, `&&`,
    `|`, `$(`, a backtick, or a leading path as in `/bin/rm`.
    """
    return r"(?<![-\w.])(?:" + pat + r")"


# Rules for a REMOTE SHELL COMMAND — the text after `ssh <host>`. Every byte of
# it runs on the cluster, so these are deliberately broader than a raw-string
# pass could afford: a bare `rm` is blocked, not only the textbook `rm -rf`,
# because `rm *.ckpt`, `rm <path> -rf` and `... | xargs rm -rf` destroy exactly
# as much. `rmdir` (empty directories only) is intentionally not matched.
SHELL_RULES = [
    (at_cmd(r"rm(?![-\w/.])"),
     "remote 'rm' is blocked: deleting under HPC_REMOTE_ROOT throws away job "
     "checkpoints and outputs, which are the resume mechanism for long runs."),
    (at_cmd(r"find\b.*?(?<![-\w])-delete\b"),
     "find -delete recursively removes matched files; like rm under "
     "HPC_REMOTE_ROOT it discards job checkpoints and outputs."),
    (r"\b(?:shutil\.rmtree|os\.(?:remove|unlink|rmdir)|\.unlink\()",
     "an interpreter one-liner that deletes files is blocked for the same reason "
     "as rm; nothing under HPC_REMOTE_ROOT should be removed from outside a job."),
    (at_cmd(r"shred\b"), "shred destroys file contents irrecoverably."),
    (at_cmd(r"truncate\b[^;&|\n]*\s-s\s*0\b"), "truncate -s 0 empties a file in place."),
    (at_cmd(r"mkfs\b"), "mkfs is destructive and never appropriate from this skill."),
    (at_cmd(r"dd\b[^;&|\n]*\bof=/"), "dd writing to a device/path is blocked."),
    (r":\s*\(\s*\)\s*\{", "fork-bomb pattern blocked."),
    # The -R may sit anywhere in a flag cluster (-Rv) or after the operands
    # (`chmod 000 -R dir`), so match it as a whole option word rather than
    # assuming it follows the verb — but require the leading '-', or a filename
    # like `my-Rfile` would trip it.
    (at_cmd(r"ch(?:mod|own)\b[^;&|\n]*\s(?:-[A-Za-z]*R[A-Za-z]*|--recursive)(?=\s|$)"),
     "recursive chmod/chown on the cluster is blocked."),
    (r">\s*/(?:etc|usr|bin|boot|sys|proc|lib)\b",
     "redirect into a system path (e.g. > /etc/...) is blocked."),
    # Block writes to device files (e.g. > /dev/sda) but NOT the universally
    # benign sinks 2>/dev/null, >/dev/stdout|stderr|tty, >/dev/fd/N — otherwise a
    # routine `... 2>/dev/null` diagnostic would be refused.
    (r">\s*/dev/(?!(?:null|stdout|stderr|tty)\b|fd/)",
     "redirect to a device file is blocked (/dev/null, /dev/std{out,err}, "
     "/dev/tty, /dev/fd/N are allowed)."),
]

# Rules for a TRANSFER (rsync/scp) with an endpoint on the cluster. Only the
# transfer's own option words are judged — the payload is files, not commands, so
# `rsync -a ./mkfs-notes.md host:/x/` is just a file with an alarming name.
XFER_RULES = [
    # --del is rsync's documented abbreviation for --delete-during; --delete-after
    # / -before / -during / -excluded / -delay are the other spellings. All of
    # them delete remotely, so match the family, not the one literal string.
    # (`--delay-updates` deletes nothing and must not match.)
    (r"--del(?:ete)?(?:-[a-z]+)?(?![\w-])",
     "rsync --delete removes remote files; the wrappers never use it because "
     "remote checkpoints/outputs are the resume mechanism for long runs."),
    (r"--remove-source-files\b",
     "rsync --remove-source-files deletes the local files it just transferred."),
]

# Shell operators that end one command and begin the next. Order matters: the
# two-character forms must be tried before their prefixes.
OPERATORS = ("&&", "||", ";;", ";", "|", "&", "(", ")")

# ssh options that consume the FOLLOWING word, so that word is never the host
# operand (`ssh -i key -o Foo=bar <host> cmd` must still resolve to <host>).
SSH_ARG_FLAGS = set("BbcDEeFIiJLlmOopQRSWw")

# Leading words to look past when identifying the program a segment runs.
WRAPPERS = {"sudo", "env", "nohup", "time", "command", "exec", "stdbuf", "nice", "ionice"}


def lex(text: str) -> list[tuple[str, str]]:
    """Best-effort shell lexer: a list of ('w', word) and ('op', operator) tokens.

    Only as much shell as the rules need. Quotes are honored — an operator inside
    them belongs to the word, so `ssh h 'rm -rf x && ls'` yields one word holding
    the whole remote command — and are stripped from the word, so an obfuscated
    `r''m` collapses to `rm`. An unterminated quote or trailing backslash runs to
    end of string rather than raising: a hook must never fail on input it cannot
    parse.
    """
    toks: list[tuple[str, str]] = []
    buf: list[str] = []
    i, n = 0, len(text)

    def flush() -> None:
        if buf:
            toks.append(("w", "".join(buf)))
            del buf[:]

    while i < n:
        c = text[i]
        if c in "'\"":
            quote, i = c, i + 1
            while i < n and text[i] != quote:
                if quote == '"' and text[i] == "\\" and i + 1 < n:
                    i += 1                      # \" inside "..." is a literal quote
                buf.append(text[i])
                i += 1
            i += 1                              # closing quote, or EOS if unterminated
            continue
        if c == "\\" and i + 1 < n:
            buf.append(text[i + 1])             # escaped char is data, never an operator
            i += 2
            continue
        if c == "#" and not buf:
            while i < n and text[i] != "\n":    # a comment at a word start runs
                i += 1                          # to end of line and is not code
            continue
        if c.isspace():
            flush()
            if c == "\n":
                toks.append(("op", "\n"))
            i += 1
            continue
        for op in OPERATORS:
            if text.startswith(op, i):
                flush()
                toks.append(("op", op))
                i += len(op)
                break
        else:
            buf.append(c)
            i += 1
    flush()
    return toks


def segments(text: str) -> list[list[str]]:
    """Split a command into its individual command segments (words per segment)."""
    out: list[list[str]] = []
    seg: list[str] = []
    for kind, tok in lex(text):
        if kind == "op":
            if seg:
                out.append(seg)
                seg = []
        else:
            seg.append(tok)
    if seg:
        out.append(seg)
    return out


def relex(text: str) -> str:
    """Re-lex a remote command and rejoin it, as the remote shell will see it.

    `ssh host 'r""m -rf x'` arrives as one word whose *content* is still shell:
    the quotes inside are literal to us but code to the shell on the other end,
    which reads it as `rm -rf x`. Running the text through the lexer once more
    collapses that layer. Operators are kept as tokens so patterns that span them
    (a fork bomb, `cd x && rm y`) still read correctly.
    """
    return " ".join(tok for _, tok in lex(text))


def program(words: list[str]) -> tuple[str, list[str]]:
    """(basename of the program a segment runs, its remaining words).

    Looks past leading VAR=value assignments and wrappers, so `env FOO=1 sudo ssh
    host ...` still resolves to ssh.
    """
    for i, w in enumerate(words):
        if re.fullmatch(r"[A-Za-z_]\w*=.*", w) or os.path.basename(w) in WRAPPERS:
            continue
        return os.path.basename(w), words[i + 1:]
    return "", []


def is_host(word: str, host: str) -> bool:
    """Does `word` name our cluster — as `host` or `user@host`? (Hostnames are
    case-insensitive; a trailing dot is the FQDN root.)"""
    w = word.lower().rstrip(".")
    h = host.lower()
    return w == h or w.endswith("@" + h)


def ssh_remote_command(rest: list[str], host: str) -> str | None:
    """The remote command from an ssh segment's words, or None if it is not aimed
    at our cluster. Options and their arguments are skipped so the host is
    recognised in the operand position and only there."""
    i = 0
    while i < len(rest):
        w = rest[i]
        if w.startswith("-") and len(w) > 1:
            if w[-1] in SSH_ARG_FLAGS:          # ...but not `-p2222` / `-oFoo=bar`
                i += 1
            i += 1
            continue
        if is_host(w, host):
            return " ".join(rest[i + 1:])       # "" for a bare interactive login
        return None                             # first operand is some other host
    return None


def xfer_options(rest: list[str], host: str) -> str | None:
    """An rsync/scp segment's option words, or None if no endpoint is on our
    cluster. Stops at a bare `--`, after which everything is a path — so a file
    genuinely named `--delete` is data, not an option."""
    if "--" in rest:
        rest = rest[:rest.index("--")]
    remote = any(
        ":" in w and not w.startswith("-") and is_host(w.split(":", 1)[0], host)
        for w in rest
    )
    if not remote:
        return None
    return " ".join(w for w in rest if w.startswith("-"))


def offences(command: str, host: str):
    """Yield (reason, offending text) for each destructive cluster operation."""
    for words in segments(command):
        prog, rest = program(words)
        if prog in ("ssh", "slogin"):
            remote = ssh_remote_command(rest, host)
            if remote:
                normalized = relex(remote)
                for pat, reason in SHELL_RULES:
                    if re.search(pat, normalized, re.S):
                        yield reason, remote
        elif prog in ("rsync", "scp", "sftp"):
            opts = xfer_options(rest, host)
            if opts:
                for pat, reason in XFER_RULES:
                    if re.search(pat, opts):
                        yield reason, " ".join([prog] + rest)


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
                    val = val.strip()
                    if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                        val = val[1:-1]
                    return val
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
    # Cheap pre-filter: nothing can reach the cluster without one of these.
    if not cmd or not re.search(r"\b(?:ssh|slogin|rsync|scp|sftp)\b", cmd):
        sys.exit(0)
    host = find_host()
    if not host:
        sys.exit(0)  # not a project that uses this skill

    for reason, offending in offences(cmd, host):
        if len(offending) > 200:
            offending = offending[:197] + "..."
        sys.stderr.write(
            "genomedk-jobs safety hook BLOCKED this command.\n"
            f"On {host}: {offending}\n"
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
