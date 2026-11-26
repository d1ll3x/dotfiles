#!/usr/bin/env python3
"""Stop: when this session wrote a /teach learning record (`learning-records/*.md`) and no
lesson recap literature note (tag `lesson`) has been written since, ask Claude once to
write one, per ~/.agents/docs/notes.md → Lesson recap. A learning record is the
deterministic sign that something was learned; it fires again only after a newer record.

Bash is best effort: a command counts as writing a record when it names
`learning-records/<file>.md` together with a redirect or `tee`.
"""

import json
import re
from datetime import datetime
from pathlib import Path

from hooklib import emit, log, read_event

HOOK = "lesson-note-reminder"
LITERATURE = Path.home() / "Documents" / "zettelkasten" / "110-literature-notes"
STATE = Path.home() / ".claude" / "hook-state" / "lesson-note-reminder.json"
MAX_TRANSCRIPT_BYTES = 6 * 1024 * 1024
RECORD = re.compile(r"learning-records/[^\s\"']+\.md")
BASH_WRITE = re.compile(r">|\btee\b")


def record_writes(transcript_path: str) -> list[datetime]:
    """Timestamps of the transcript's tool calls that write a learning record."""
    path = Path(transcript_path)
    if not path.is_file():
        return []
    with path.open("rb") as f:
        f.seek(max(0, path.stat().st_size - MAX_TRANSCRIPT_BYTES))
        lines = f.read().decode("utf-8", "replace").splitlines()
    stamps = []
    for line in lines:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        content = (entry.get("message") or {}).get("content")
        if entry.get("type") != "assistant" or not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use" and writes_record(block):
                stamps.append(datetime.fromisoformat(entry["timestamp"]))
    return stamps


def writes_record(block: dict) -> bool:
    name, args = block.get("name"), block.get("input") or {}
    if name in {"Write", "Edit"}:
        return bool(RECORD.search(args.get("file_path") or ""))
    if name == "Bash":
        cmd = args.get("command") or ""
        return bool(RECORD.search(cmd) and BASH_WRITE.search(cmd))
    return False


def recap_written_since(moment: datetime) -> bool:
    for note in LITERATURE.glob("*.md"):
        if note.stat().st_mtime < moment.timestamp():
            continue
        head = note.read_text(encoding="utf-8").split("\n---", 2)[0]
        if re.search(r"^\s+-\s+lesson\s*$", head, re.M):
            return True
    return False


def main() -> None:
    data = read_event()
    if data.get("stop_hook_active"):
        return
    session = data.get("session_id") or ""
    stamps = record_writes(data.get("transcript_path") or "")
    if not stamps or recap_written_since(max(stamps)):
        return

    state = json.loads(STATE.read_text()) if STATE.is_file() else {}
    if state.get(session, 0) >= len(stamps):
        return
    state[session] = len(stamps)
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state))

    log(HOOK, "REMIND", session_id=session, records=len(stamps))
    emit(
        {
            "decision": "block",
            "reason": (
                "lesson-note-reminder: this session wrote a learning record, and no lesson "
                "recap has been written since. Write one now: read ~/.agents/docs/notes.md → "
                "Lesson recap. If the lesson isn't finished yet, say so in one line and stop."
            ),
        }
    )


if __name__ == "__main__":
    main()
