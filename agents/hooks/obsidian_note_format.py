#!/usr/bin/env python3
"""PreToolUse(Write|Edit|Bash): deny a note in 100-fleeting-notes/ or 110-literature-notes/
that breaks the shape in ~/.agents/docs/notes.md → "Notes by Claude": the template's
frontmatter with real values, the folder's tag, and for Claude's own kinds (tags
`troubleshooting`, `lesson`) their headings and the 600-word limit. A new note also needs
an H1 equal to its filename, and a new fleeting note the `todo` tag.

Edits to Dylan's existing notes only get the checks that every note there passes.
Bash is best effort: only `obsidian create path=… content=…` is inspected; scripts
that write notes are not.
"""

import re
import shlex
from pathlib import Path

from hooklib import log, pre_tool_decision, read_event

HOOK = "obsidian-note-format"
VAULT = Path.home() / "Documents" / "zettelkasten"
FLEETING, LITERATURE = "100-fleeting-notes", "110-literature-notes"
STAMP = re.compile(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}")
SEGMENT = re.compile(r"&&|\|\||[;|&\n]")
KIND_HEADINGS = {
    "troubleshooting": ["Symptom", "Root cause", "Fix", "Prevention", "Dead ends"],
    "lesson": ["What we learned", "Still shaky", "Next"],
}
MAX_WORDS = 600


def note_folder(path: Path) -> str | None:
    try:
        rel = path.resolve().relative_to(VAULT.resolve())
    except ValueError:
        return None
    if path.suffix != ".md" or len(rel.parts) != 2:
        return None
    return rel.parts[0] if rel.parts[0] in {FLEETING, LITERATURE} else None


def split_frontmatter(text: str) -> tuple[dict[str, str], list[str], str] | None:
    """(keys → inline value, tags, body), or None when the note has no frontmatter."""
    m = re.match(r"---\n(.*?)\n---\n?(.*)", text, re.S)
    if not m:
        return None
    keys: dict[str, str] = {}
    tags: list[str] = []
    current = None
    for line in m[1].splitlines():
        if km := re.match(r"([A-Za-z]+):\s*(.*)", line):
            current, keys[km[1]] = km[1], km[2].strip()
        elif (item := re.match(r"\s+-\s+(.+)", line)) and current == "Tags":
            tags.append(item[1].strip().strip("\"'"))
    return keys, tags, m[2]


def problems(folder: str, path: Path, text: str, is_new: bool) -> list[str]:
    found = []
    if "<%" in text:
        found.append("contains Templater code `<% %>`: write real values")
    parsed = split_frontmatter(text)
    if parsed is None:
        return [*found, "has no YAML frontmatter"]
    keys, tags, body = parsed

    required = ["Created", "Modified", "Tags"] + (["Related"] if folder == LITERATURE else [])
    found += [f"frontmatter lacks `{k}`" for k in required if k not in keys]
    found += [
        f"`{k}` is not `YYYY-MM-DD HH:mm` (use `date '+%Y-%m-%d %H:%M'`)"
        for k in ("Created", "Modified")
        if k in keys and not STAMP.fullmatch(keys[k])
    ]
    folder_tag = "zettelkasten/fleeting" if folder == FLEETING else "zettelkasten/literature"
    if folder_tag not in tags:
        found.append(f"Tags lack `{folder_tag}` for {folder}/")
    if is_new and folder == FLEETING and "todo" not in tags:
        found.append("a new fleeting note needs the `todo` tag")

    if is_new:
        h1 = re.search(r"^# (.+)$", body, re.M)
        if not h1 or h1[1].strip() != path.stem:
            found.append(f"the H1 must equal the filename: `# {path.stem}`")
    if folder == LITERATURE and "\n# References" not in "\n" + body:
        found.append("lacks the closing `---` + `# References` section")

    for kind, headings in KIND_HEADINGS.items():
        if kind in tags:
            found += [f"lacks `## {h}`" for h in headings if f"\n## {h}\n" not in f"\n{body}\n"]
    if folder == LITERATURE and (is_new or tags_mark_claude(tags)):
        words = len(body.split())
        if words > MAX_WORDS:
            found.append(f"is {words} words; literature notes stay at most {MAX_WORDS}")
    return found


def tags_mark_claude(tags: list[str]) -> bool:
    return any(kind in tags for kind in KIND_HEADINGS)


def file_tool_note(tool: str, tool_input: dict, cwd: Path) -> tuple[Path, str, bool] | None:
    raw = tool_input.get("file_path")
    if not raw:
        return None
    path = cwd / Path(raw).expanduser()
    if tool == "Write":
        return path, tool_input.get("content") or "", not path.exists()
    if not path.exists():
        return None
    current = path.read_text(encoding="utf-8")
    old, new = tool_input.get("old_string") or "", tool_input.get("new_string") or ""
    count = -1 if tool_input.get("replace_all") else 1
    return path, current.replace(old, new, count), False


def bash_notes(cmd: str) -> list[tuple[Path, str, bool]]:
    notes = []
    for segment in SEGMENT.split(cmd):
        try:
            tokens = shlex.split(segment, comments=True)
        except ValueError:
            continue
        if not tokens or Path(tokens[0]).name != "obsidian" or "create" not in tokens:
            continue
        params = dict(t.split("=", 1) for t in tokens if "=" in t)
        if "path" in params and "content" in params:
            content = params["content"].replace("\\n", "\n").replace("\\t", "\t")
            notes.append((VAULT / params["path"], content, True))
    return notes


def main() -> None:
    data = read_event()
    tool = data.get("tool_name")
    tool_input = data.get("tool_input") or {}
    cwd = Path(data.get("cwd") or Path.cwd())

    if tool in {"Write", "Edit"}:
        note = file_tool_note(tool, tool_input, cwd)
        candidates = [note] if note else []
    elif tool == "Bash":
        candidates = bash_notes(tool_input.get("command") or "")
    else:
        return

    report = []
    for path, text, is_new in candidates:
        folder = note_folder(path)
        if folder and (found := problems(folder, path, text, is_new)):
            report.append(f"{path.name}: " + "; ".join(found))
    if not report:
        return

    log(HOOK, "BLOCKED", tool=tool, notes=report, session_id=data.get("session_id"))
    pre_tool_decision(
        "deny",
        "obsidian-note-format: "
        + " | ".join(report)
        + ". The shapes are in ~/.agents/docs/notes.md → Notes by Claude; fix the note and write it again.",
    )


if __name__ == "__main__":
    main()
