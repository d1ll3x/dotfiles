"""Shared plumbing for Claude Code command hooks: event in, decision out, JSONL log."""

import json
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

LOG_DIR = Path.home() / ".claude" / "hooks-logs"


def now_iso() -> str:
    """UTC timestamp in the JS toISOString() shape the existing logs/registries use."""
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def to_json(data: Any) -> str:
    return json.dumps(data, ensure_ascii=False, separators=(",", ":"))


def read_event() -> dict[str, Any]:
    data = json.load(sys.stdin)
    if not isinstance(data, dict):
        raise TypeError(f"hook input is not a JSON object: {type(data).__name__}")
    return data


def emit(output: dict[str, Any] | None = None) -> None:
    print(to_json(output or {}))


def pre_tool_decision(decision: str, reason: str) -> None:
    """PreToolUse verdict: decision is 'allow' | 'ask' | 'deny'."""
    emit(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": reason,
            }
        }
    )


def log(hook: str, level: str, **fields: Any) -> None:
    """Append one record to today's hooks log; None-valued fields are dropped."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    stamp = now_iso()
    record = {"ts": stamp, "hook": hook, "level": level}
    record |= {k: v for k, v in fields.items() if v is not None}
    with (LOG_DIR / f"{stamp[:10]}.jsonl").open("a", encoding="utf-8") as f:
        f.write(to_json(record) + "\n")
