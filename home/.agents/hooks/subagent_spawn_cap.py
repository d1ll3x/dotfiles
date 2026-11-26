#!/usr/bin/env python3
"""Subagent Spawn Cap - PreToolUse Hook for Agent|Task.

A total-spawns-per-session budget for subagents: counts every Agent tool call per
session_id (nested spawns from inside subagents included), asks at spawn
SPAWN_CAP_ASK and every SPAWN_CAP_ASK_STEP after it, denies at SPAWN_CAP_DENY.
Defaults prompt at 20, 30, 40, 50 and stop at 60.
State: one append-only JSONL per session under ~/.claude/subagent-spawn-cap/
(parallel hook processes append safely; count = line count). Denied calls are not
recorded. Logs to: ~/.claude/hooks-logs/

Env (validated positive integers, invalid values fall back):
  SPAWN_CAP_ASK=20  SPAWN_CAP_ASK_STEP=10  SPAWN_CAP_DENY=60 (clamped up to
  SPAWN_CAP_ASK if lower; equal to it = no asks)
  SPAWN_CAP_ALLOW=true lets spawns through while set (still counted).
Unattended (-p, dontAsk) runs turn asks into denies: set ASK equal to DENY.
"""

import os
import re
import time
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from hooklib import log, now_iso, pre_tool_decision, read_event, to_json

HOOK = "subagent-spawn-cap"
HOME = Path.home()
STATE_DIR = HOME / ".claude" / "subagent-spawn-cap"
PRUNE_STAMP = STATE_DIR / ".last-prune"

# `Agent` on current builds, `Task` on older ones.
SPAWN_TOOLS = {"Agent", "Task"}

DEFAULT_ASK = 20
DEFAULT_ASK_STEP = 10
DEFAULT_DENY = 60
DAY_S = 24 * 60 * 60
PRUNE_AFTER_S = 7 * DAY_S
PRUNE_EVERY_S = DAY_S

EMOJIS = {"ask": "⚠️", "deny": "🚨"}


@dataclass(frozen=True)
class Thresholds:
    ask: int
    step: int
    deny: int
    clamped: bool


def parse_positive_int(raw: str | None, fallback: int) -> int:
    if raw is None or not re.fullmatch(r"\d+", raw.strip()):
        return fallback
    n = int(raw.strip())
    return n if n > 0 else fallback


def read_thresholds(env: Mapping[str, str]) -> Thresholds:
    ask = parse_positive_int(env.get("SPAWN_CAP_ASK"), DEFAULT_ASK)
    step = parse_positive_int(env.get("SPAWN_CAP_ASK_STEP"), DEFAULT_ASK_STEP)
    deny = parse_positive_int(env.get("SPAWN_CAP_DENY"), DEFAULT_DENY)
    return Thresholds(ask, step, max(deny, ask), clamped=deny < ask)


def session_file(session_id: str) -> Path:
    """session_id becomes a file name: safe charset, bounded length."""
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", session_id)[:128]
    return STATE_DIR / f"{safe}.jsonl"


def display_path(file: Path) -> str:
    return f"~/{file.relative_to(HOME)}" if file.is_relative_to(HOME) else str(file)


def count_lines(file: Path) -> int:
    try:
        return file.read_bytes().count(b"\n")
    except FileNotFoundError:
        return 0


def append_line(file: Path, record: dict[str, Any]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with file.open("a", encoding="utf-8") as f:
        f.write(to_json(record) + "\n")


def prune_stale(now: float) -> None:
    """Drop ledgers untouched for 7 days; at most once a day (stamp mtime)."""
    if PRUNE_STAMP.exists() and now - PRUNE_STAMP.stat().st_mtime < PRUNE_EVERY_S:
        return
    for ledger in STATE_DIR.glob("*.jsonl"):
        # A parallel hook may have pruned it first.
        if now - ledger.stat().st_mtime > PRUNE_AFTER_S:
            ledger.unlink(missing_ok=True)
    PRUNE_STAMP.write_text(str(int(now * 1000)))


def should_ask(count: int, t: Thresholds) -> bool:
    return count >= t.ask and (count - t.ask) % t.step == 0


def build_reason(decision: str, n: int, t: Thresholds, file: Path) -> str:
    """Ask reasons are shown to the user, deny reasons to Claude."""
    ledger = display_path(file)
    if decision == "deny":
        return (
            f"[spawn-cap] Subagent spawn #{n} in this session hit the hard cap "
            f"(SPAWN_CAP_DENY={t.deny}). Do not retry: finish with the results you already "
            "have and tell the user the session's spawn budget is spent. The user can reset it "
            f"by deleting {ledger}, or raise SPAWN_CAP_DENY in the settings.json env block and "
            "restart."
        )
    silent = min(t.step - 1, t.deny - n - 1)
    next_check = f"next check at #{n + t.step}, " if n + t.step < t.deny else ""
    after = (
        f"the next {silent} spawn{'' if silent == 1 else 's'} then pass without asking."
        if silent > 0
        else f"spawn #{t.deny} is then denied."
    )
    return (
        f"[spawn-cap] Subagent spawn #{n} in this session (ask threshold SPAWN_CAP_ASK={t.ask}, "
        f"{next_check}hard cap SPAWN_CAP_DENY={t.deny}). Approve to continue; {after} Deny to "
        f"stop the fan-out. Reset this session's count by deleting {ledger}; change the cadence "
        "via SPAWN_CAP_ASK / SPAWN_CAP_ASK_STEP in the settings.json env block (restart needed)."
    )


def main() -> None:
    event = read_event()
    tool_name = event.get("tool_name")
    if tool_name not in SPAWN_TOOLS:
        return
    session_id = event.get("session_id")
    if not session_id:
        log(HOOK, "WARN", msg="spawn event without session_id; allowed uncounted", tool=tool_name)
        return

    t = read_thresholds(os.environ)
    if t.clamped:
        log(HOOK, "WARN", msg="SPAWN_CAP_DENY below SPAWN_CAP_ASK; clamped", ask=t.ask, deny=t.deny)
    file = session_file(str(session_id))
    count = count_lines(file) + 1
    bypass = os.environ.get("SPAWN_CAP_ALLOW") == "true"
    tool_input = event.get("tool_input") or {}
    subagent_type = tool_input.get("subagent_type")
    log_fields: dict[str, Any] = {
        "count": count,
        "ask": t.ask,
        "step": t.step,
        "deny": t.deny,
        "subagent_type": subagent_type if isinstance(subagent_type, str) else None,
        "agent_id": event.get("agent_id"),
        "agent_type": event.get("agent_type"),
        "tool": tool_name,
        "session_id": session_id,
        "cwd": event.get("cwd"),
        "permission_mode": event.get("permission_mode"),
    }

    decision = "allow"
    if not bypass and count >= t.deny:
        decision = "deny"
    elif not bypass and should_ask(count, t):
        decision = "ask"

    if decision != "deny":
        record = {
            "ts": now_iso(),
            "n": count,
            "decision": "bypass" if bypass else decision,
            "agent_id": event.get("agent_id"),
            "agent_type": event.get("agent_type"),
            "subagent_type": log_fields["subagent_type"],
        }
        if isinstance(desc := tool_input.get("description"), str):
            record["description"] = desc[:80]
        append_line(file, {k: v for k, v in record.items() if v})
        prune_stale(time.time())

    if bypass:
        log(HOOK, "ALLOW_OVERRIDE", **log_fields)
    if decision == "allow":
        return

    log(
        HOOK,
        "ASK" if decision == "ask" else "BLOCKED",
        id="spawn-cap",
        decision=decision,
        **log_fields,
    )
    pre_tool_decision(decision, f"{EMOJIS[decision]} {build_reason(decision, count, t, file)}")


if __name__ == "__main__":
    main()
