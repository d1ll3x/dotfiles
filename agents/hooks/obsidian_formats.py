#!/usr/bin/env python3
"""PreToolUse(Write|Edit|NotebookEdit|Bash): deny putting files Obsidian can't open
natively into the vault. Formats: https://obsidian.md/help/file-formats. This hook is
the single source of truth for the rule; no instruction file restates it.

Bash is best effort: write targets (redirects, tee/touch, curl/wget output, cp/mv/
install/ln/rsync destinations) are resolved against the session cwd; archives
(tar, unzip) and scripts that write files are not inspected.
Dot-paths (.obsidian/, .git/, .gitignore, .trash/) are vault infrastructure and pass.
"""

import itertools
import re
import shlex
from pathlib import Path

from hooklib import log, pre_tool_decision, read_event

HOOK = "vault-formats"
VAULT = Path.home() / "Documents" / "zettelkasten"
SUPPORTED = {
    ".md", ".base", ".canvas", ".pdf",
    ".avif", ".bmp", ".gif", ".jpeg", ".jpg", ".png", ".svg", ".webp",
    ".flac", ".m4a", ".mp3", ".ogg", ".wav", ".webm", ".3gp",
    ".mkv", ".mov", ".mp4", ".ogv",
}  # fmt: skip
FILE_TOOLS = {"Write", "Edit", "NotebookEdit"}
COPIERS = {"cp", "mv", "install", "ln", "rsync"}
OUTPUT_FLAGS = {"-o", "-O", "--output", "--output-document"}
SEGMENT = re.compile(r"&&|\|\||[;|&\n]")


def unsupported_in_vault(path: Path) -> bool:
    try:
        rel = path.resolve().relative_to(VAULT.resolve())
    except ValueError:
        return False
    if any(part.startswith(".") for part in rel.parts):
        return False
    return path.suffix.lower() not in SUPPORTED


def write_targets(tokens: list[str], cwd: Path) -> list[str]:
    """Paths one simple command writes: redirects, tee/touch args, curl/wget outputs,
    and the destination of a copy/move (a directory destination keeps source names)."""
    targets: list[str] = []
    args: list[str] = []
    it = iter(tokens)
    for token in it:
        if re.fullmatch(r"\d?>>?", token):
            targets.append(next(it, ""))
        elif m := re.fullmatch(r"\d?>>?(.+)", token):
            targets.append(m[1])
        else:
            args.append(token)
    if not args:
        return targets
    cmd, rest = Path(args[0]).name, args[1:]
    operands = [a for a in rest if not a.startswith("-")]
    if cmd in {"tee", "touch"}:
        targets += operands
    elif cmd in {"curl", "wget"}:
        targets += [b for a, b in itertools.pairwise(rest) if a in OUTPUT_FLAGS]
    elif cmd in COPIERS and len(operands) >= 2:
        *sources, dest = operands
        if dest.endswith("/") or (cwd / Path(dest).expanduser()).is_dir():
            targets += [str(Path(dest) / Path(src).name) for src in sources]
        else:
            targets.append(dest)
    return targets


def offending_bash_paths(cmd: str, cwd: Path) -> list[str]:
    hits = []
    for segment in SEGMENT.split(cmd):
        try:
            tokens = shlex.split(segment, comments=True)
        except ValueError:  # unbalanced quotes: fall back to whitespace
            tokens = segment.split()
        for target in write_targets(tokens, cwd):
            if target and unsupported_in_vault(cwd / Path(target).expanduser()):
                hits.append(target)
    return hits


def main() -> None:
    data = read_event()
    tool = data.get("tool_name")
    tool_input = data.get("tool_input") or {}
    cwd = Path(data.get("cwd") or Path.cwd())

    if tool in FILE_TOOLS:
        raw = tool_input.get("file_path") or tool_input.get("notebook_path")
        paths = [raw] if raw and unsupported_in_vault(cwd / Path(raw).expanduser()) else []
    elif tool == "Bash":
        paths = offending_bash_paths(tool_input.get("command") or "", cwd)
    else:
        return
    if not paths:
        return

    log(HOOK, "BLOCKED", tool=tool, paths=paths, session_id=data.get("session_id"))
    pre_tool_decision(
        "deny",
        f"vault-formats: {', '.join(paths)} would put a format Obsidian can't open into the "
        f"vault ({VAULT}). The vault holds only {' '.join(sorted(SUPPORTED))}. Keep this file "
        "outside the vault, as is, and link to it from a note by path or URL.",
    )


if __name__ == "__main__":
    main()
