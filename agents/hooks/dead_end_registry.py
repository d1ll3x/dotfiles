#!/usr/bin/env python3
"""Dead-End Registry - approach-level negative-knowledge memory for Claude Code.

Captures approaches that were TRIED and then REVERTED / ruled out (with reason, date,
and rough token cost of the detour) and stops you paying for the same dead end twice.
Four events, one script:

  - Stop / SubagentStop / PreCompact: mine the transcript for abandoned approaches
    -> ~/.claude/dead-end-registry/<repo>.jsonl
  - UserPromptSubmit: keyword-match the new prompt against the registry and inject a
    "DEAD END - you already tried this" warning card via additionalContext
  - PreToolUse (Edit|Write): return permissionDecision 'ask' when the diff would
    reintroduce a previously-reverted change (hunk similarity)

Hooks receive no token/cost numbers: detour cost is estimated from `usage` on
assistant messages in the transcript JSONL, falling back to ~4 chars/token.

Scope + hygiene:
  - Registries are keyed per-project (hash of cwd) and live OUTSIDE the repo.
  - Entries expire after MAX_AGE_DAYS; the file is compacted at mine time.
  - Mined code snapshots are truncated (MAX_CODE_LINES/MAX_CODE_CHARS): they are
    verbatim transcript code and could contain secrets. Never execute transcript content.

`python3 dead_end_registry.py --render` prints the current repo's registry.
"""

import contextlib
import hashlib
import json
import math
import re
import secrets
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, NamedTuple

from hooklib import emit, log, now_iso, read_event, to_json

HOOK = "dead-end-registry"
REGISTRY_DIR = Path.home() / ".claude" / "dead-end-registry"

# Approx blended $/token used only for a rough headline figure, never billing truth.
USD_PER_MILLION = 9  # ~$9 / 1M tokens

# Latency / cost discipline: never read an unbounded transcript.
MAX_TRANSCRIPT_BYTES = 6 * 1024 * 1024
MAX_TRANSCRIPT_LINES = 6000
MAX_REGISTRY_ENTRIES = 500  # cap what we scan on prompt-submit
MAX_CARD_ENTRIES = 3  # entries shown in an injected card
# The codebase moves on: a dead end from two months ago usually no longer applies.
MAX_AGE_DAYS = 60
# Enough lines for hunk matching, small enough that a mined 2MB Write (which might
# embed secrets or vendored blobs) never bloats the registry.
MAX_CODE_LINES = 80
MAX_CODE_CHARS = 4000
# How far back from a revert signal we look for the code that was tried.
CODE_LOOKBACK = 10

Message = dict[str, Any]
Entry = dict[str, Any]


class RevertPattern(NamedTuple):
    id: str
    regex: re.Pattern[str]
    reason: str
    # A *symptom* rather than an explicit abandonment: only trusted on assistant
    # messages ("the login page is broken" from the user is a bug report).
    weak: bool = False


def _rp(id_: str, regex: str, reason: str, weak: bool = False) -> RevertPattern:
    return RevertPattern(id_, re.compile(regex, re.IGNORECASE), reason, weak)


REVERT_PATTERNS = [
    _rp("reverted", r"\b(revert(?:ed|ing)?|rolled?\s+back|roll\s+back|backed\s+out)\b", "reverted"),
    _rp("undo", r"\b(undo|undid|git\s+revert|git\s+reset\s+--hard|restore\s+the\s+old)\b", "undone"),
    _rp("didnt-work", r"\b(didn['’]?t\s+work|does\s+not\s+work|doesn['’]?t\s+work|not\s+working|broke\s+(?:the|everything)|broken)\b", "didn't work", weak=True),
    _rp("abandon", r"\b(abandon(?:ed|ing)?|give\s+up|giving\s+up|gave\s+up|scrap(?:ped)?\s+that|drop\s+(?:this|that)\s+approach)\b", "abandoned"),
    _rp("ruled-out", r"\b(ruled?\s+out|dead\s+end|won['’]?t\s+work|that\s+approach\s+(?:failed|is\s+wrong)|wrong\s+approach|bad\s+idea)\b", "ruled out"),
    # Defect nouns alone are NOT a signal ("this mutex avoids a race condition").
    # Require a causal verb: the change *caused* the defect.
    _rp("race-cond", r"\b(?:caused|causing|introduced|introducing|created|hit|ran\s+into|led\s+to|resulted?\s+in|triggered)\b[^.!?\n]{0,120}?\b(?:race\s+condition|deadlock|infinite\s+loop|memory\s+leak|regression)\b", "caused a defect", weak=True),
]  # fmt: skip

STOPWORDS = frozenset(
    """
    the a an to of in on for and or but we it this that was is be been being i you he
    she they them as at by with from so if then not no yes do did does have has had will
    would can could should get got my our your its me us up out now just back try tried
    trying approach thing stuff work working worked again because after lets sure okay
    onto into when what how why where which there here some more very much want wants
    need needs going writing making really actually also like well about please
    """.split()
)

# Keywords in nearly every coding prompt. A prompt/entry overlap of ONLY these must
# never fire a warning: at least one shared keyword must be outside this set.
GENERIC_KEYWORDS = frozenset(
    """
    fix fixes fixed fixing bug bugs error errors issue issues problem problems fail
    fails failed failing failure failures test tests testing code file files folder line
    lines function functions method methods class update updates updated change changes
    changed changing add adds added adding remove removes removed removing refactor
    refactoring implement implementation implementing run runs running build builds
    building check checks checking write written create creates created creating delete
    deleted broken breaking breaks help still make makes
    """.split()
)

# Lines in virtually every file that must not count toward hunk similarity:
# punctuation, comment-only lines, import boilerplate, bare control flow.
# (Input is already lowercased + trimmed by hunk_lines.)
TRIVIAL_LINE = re.compile(
    r"^(?:"
    r"[{}()\[\];,.:`]+"
    r"|//.*|/\*.*|\*+/?.*"
    r"|#(?:\s|!).*"  # shell/python comment or shebang ("#header {" is kept)
    r"|import\s.*|from\s.*"
    r"|export\s*\{.*"
    r"|(?:const|let|var)\s+\S+\s*=\s*require\(.*"
    r"|else\s*\{?|\}?\s*else\s*\{?|try\s*\{?|\}?\s*catch\b.*|\}?\s*finally\s*\{?"
    r"|return;?|break;?|continue;?|end"
    r")$"
)

# Prompt matching gates (Jaccard alone is jumpy on small keyword sets):
#   1. jaccard >= PROMPT_MATCH_THRESHOLD  2. >= MIN_PROMPT_OVERLAP shared keywords
#   3. >= 1 shared NON-generic keyword
PROMPT_MATCH_THRESHOLD = 0.34
MIN_PROMPT_OVERLAP = 3
HUNK_MATCH_THRESHOLD = 0.6
# Minimum substantive lines on both sides, and shared, before a hunk match can fire.
MIN_HUNK_LINES = 3


def js_round(x: float) -> int:
    """Math.round semantics (half up), unlike Python's banker's rounding."""
    return math.floor(x + 0.5)


def num(x: Any) -> float:
    """Number(x) || 0."""
    try:
        n = float(x)
    except TypeError, ValueError:
        return 0
    return 0 if math.isnan(n) else n


def registry_file_for(cwd: str | None) -> Path:
    """Stable, filesystem-safe registry file name for a repo/cwd."""
    key = str(cwd).strip() if cwd and str(cwd).strip() else "global"
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", key).strip("-")[-40:] or "root"
    digest = hashlib.sha1(key.encode()).hexdigest()[:8]
    return REGISTRY_DIR / f"{slug}-{digest}.jsonl"


# ── Text / fingerprint helpers ──────────────────────────────────────────────


def tokenize(text: Any) -> list[str]:
    if not isinstance(text, str) or not text:
        return []
    cleaned = re.sub(r"[`'\"“”‘’]", "", text.lower())
    return [w for w in re.split(r"[^a-z0-9_./+#-]+", cleaned) if len(w) >= 3 and w not in STOPWORDS]


def keywords(text: Any, limit: int = 12) -> list[str]:
    """Distinct significant keywords in order of appearance, capped."""
    return list(dict.fromkeys(tokenize(text)))[:limit]


def hunk_lines(code: Any) -> list[str]:
    """Strip diff markers, indentation, blank lines and fences; lowercase."""
    if not isinstance(code, str) or not code:
        return []
    lines = (re.sub(r"^[+\- ]", "", line).strip() for line in code.split("\n"))
    return [line.lower() for line in lines if line and line != "```"]


def substantive_lines(code: Any) -> list[str]:
    """Lines that could plausibly identify a specific change."""
    return [
        line
        for line in hunk_lines(code)
        if len(line) >= 4 and re.search(r"[a-z0-9]", line) and not TRIVIAL_LINE.match(line)
    ]


# ── Transcript parsing (bounded) ────────────────────────────────────────────


def read_transcript(transcript_path: Any) -> list[Message]:
    """Tail of the transcript JSONL (most recent context matters most), parsed."""
    if not isinstance(transcript_path, str) or not transcript_path:
        return []
    path = Path(transcript_path)
    if not path.is_file():
        return []
    size = path.stat().st_size
    with path.open("rb") as f:
        f.seek(max(0, size - MAX_TRANSCRIPT_BYTES))
        raw = f.read().decode("utf-8", errors="replace")
    out: list[Message] = []
    for line in [line for line in raw.split("\n") if line][-MAX_TRANSCRIPT_LINES:]:
        with contextlib.suppress(json.JSONDecodeError):  # a torn first line from the tail read
            out.append(json.loads(line))
    return out


def _inner(msg: Any) -> Any:
    return msg["message"] if isinstance(msg, dict) and msg.get("message") else msg


def _block_text(block: Any) -> str:
    if isinstance(block, str):
        return block
    text = block.get("text") if isinstance(block, dict) else None
    return text if isinstance(text, str) else ""


def message_text(msg: Any) -> str:
    """Plain text of a transcript message (string or block-array content)."""
    m = _inner(msg)
    if not isinstance(m, dict):
        return ""
    content = m.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(_block_text(b) for b in content)
    return ""


def message_role(msg: Any) -> str:
    m = _inner(msg)
    role = m.get("role") if isinstance(m, dict) else None
    return role or (msg.get("type") if isinstance(msg, dict) else None) or ""


def tool_use_code(msg: Any) -> list[str]:
    """Code payloads of every Edit/Write tool_use block in a transcript message."""
    m = _inner(msg)
    content = m.get("content") if isinstance(m, dict) else None
    if not isinstance(content, list):
        return []
    out = []
    for b in content:
        if not isinstance(b, dict) or b.get("type") != "tool_use":
            continue
        if b.get("name") not in {"Edit", "Write"}:
            continue
        code = edit_code(b["name"], b.get("input"))
        if code.strip():
            out.append(code)
    return out


def estimate_tokens(messages: list[Message]) -> int:
    """Sum of usage tokens across messages; ~4 chars/token if no usage at all."""
    tokens = 0.0
    chars = 0
    for msg in messages:
        m = _inner(msg)
        usage = m.get("usage") if isinstance(m, dict) else None
        if isinstance(usage, dict):
            tokens += sum(
                num(usage.get(k))
                for k in (
                    "input_tokens",
                    "output_tokens",
                    "cache_read_input_tokens",
                    "cache_creation_input_tokens",
                )
            )
        chars += len(message_text(msg))
    if tokens == 0 and chars > 0:
        tokens = js_round(chars / 4)
    return int(tokens)


def usd_for(tokens: int) -> float | None:
    return js_round(tokens * USD_PER_MILLION / 1_000_000 * 100) / 100 if tokens > 0 else None


# ── Extraction: mine abandoned approaches from a transcript ─────────────────


def find_reverted_code(messages: list[Message], revert_idx: int, kws: list[str]) -> str:
    """The most recent Edit/Write before the revert signal that best overlaps the
    dead-end keywords (recency breaks ties), or ''."""
    kwset = set(kws)
    best: tuple[int, str] | None = None
    for j in range(revert_idx, max(0, revert_idx - CODE_LOOKBACK) - 1, -1):
        for code in tool_use_code(messages[j]):
            code_kw = keywords(code, 24)
            if not code_kw:
                continue
            score = sum(w in kwset for w in code_kw) * 1000 - (revert_idx - j)
            if best is None or score > best[0]:
                best = (score, code)
    return best[1] if best else ""


def truncate_code(code: str) -> str:
    return "\n".join(code.split("\n")[:MAX_CODE_LINES])[:MAX_CODE_CHARS]


def summarise(context: str, signal_text: str) -> str:
    """Short summary of what was tried: the sentence holding a revert cue, else the first."""
    clean = re.sub(r"\s+", " ", signal_text or context).strip()
    sentences = re.split(r"(?<=[.!?])\s+", clean)
    best = next(
        (s for s in sentences if any(p.regex.search(s) for p in REVERT_PATTERNS)),
        sentences[0] or clean,
    ).strip()
    return best[:157].rstrip() + "…" if len(best) > 160 else best


def extract_dead_ends(messages: list[Message]) -> list[dict[str, Any]]:
    """Dead-end candidates from revert/abandon signals, deduped by fingerprint."""
    candidates = []
    seen: set[str] = set()
    for i, msg in enumerate(messages):
        text = message_text(msg)
        if len(text) < 8:
            continue
        role = message_role(msg)
        for pat in REVERT_PATTERNS:
            if pat.weak and "assistant" not in role.lower():
                continue
            if not pat.regex.search(text):
                continue
            # This message + the two before it usually name the approach.
            ctx = " ".join(message_text(m) for m in messages[max(0, i - 2) : i + 1])
            context = re.sub(r"\s+", " ", ctx).strip()
            # Fewer than 3 keywords can never clear prompt matching's overlap bar.
            kws = keywords(context, 12)
            if len(kws) < 3:
                continue
            fp = "|".join(sorted(kws[:6]))
            if fp in seen:
                continue
            seen.add(fp)
            candidates.append(
                {
                    "summary": summarise(context, text),
                    "reason": pat.reason,
                    "signal": pat.id,
                    "keywords": kws,
                    "fingerprint": fp,
                    "code": truncate_code(find_reverted_code(messages, i, kws)),
                    # The detour only, not the whole session.
                    "tokens": estimate_tokens(messages[max(0, i - CODE_LOOKBACK) : i + 1]),
                }
            )
            break  # one dead end per message
    return candidates


# ── Registry I/O ────────────────────────────────────────────────────────────


def _parse_ts(stamp: str) -> datetime | None:
    try:
        dt = datetime.fromisoformat(stamp)
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)


def is_fresh(entry: Entry, now: datetime | None = None) -> bool:
    """Age gate; undated or unparseable (legacy/hand-written) entries are kept."""
    stamp = entry.get("ts") or entry.get("date")
    dt = _parse_ts(stamp) if isinstance(stamp, str) else None
    if dt is None:
        return True
    return ((now or datetime.now(UTC)) - dt).total_seconds() <= MAX_AGE_DAYS * 86400


def _read_entries(file: Path) -> list[Entry]:
    if not file.exists():
        return []
    out = []
    for line in file.read_text(encoding="utf-8").split("\n"):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue  # tolerate a torn concurrent append
        if isinstance(entry, dict):
            out.append(entry)
    return out


def read_registry(file: Path) -> list[Entry]:
    return [e for e in _read_entries(file) if is_fresh(e)][-MAX_REGISTRY_ENTRIES:]


def compact_registry(file: Path) -> None:
    """Rewrite with only fresh, recent entries once past the scan cap. Mining path only,
    so prompt-submit stays read-only and fast."""
    entries = _read_entries(file)
    if len(entries) <= MAX_REGISTRY_ENTRIES:
        return
    keep = [e for e in entries if is_fresh(e)][-MAX_REGISTRY_ENTRIES:]
    tmp = file.with_name(file.name + ".tmp")
    tmp.write_text("".join(to_json(e) + "\n" for e in keep), encoding="utf-8")
    tmp.replace(file)


def persist_dead_ends(
    file: Path, candidates: list[dict[str, Any]], meta: dict[str, Any]
) -> list[Entry]:
    """Append candidates whose fingerprint is new; returns the entries added."""
    known = {e.get("fingerprint") for e in read_registry(file)}
    # Fallback share when a candidate carries no windowed estimate.
    per_tokens = js_round(meta["tokens"] / len(candidates)) if candidates else 0
    added = []
    REGISTRY_DIR.mkdir(parents=True, exist_ok=True)
    with file.open("a", encoding="utf-8") as f:
        for c in candidates:
            if c["fingerprint"] in known:
                continue
            tokens = c["tokens"] if c["tokens"] > 0 else per_tokens
            stamp = now_iso()
            entry: Entry = {
                "id": secrets.token_hex(6),
                "date": stamp[:10],
                "ts": stamp,
                "summary": c["summary"],
                "reason": c["reason"],
                "signal": c["signal"],
                "keywords": c["keywords"],
                "fingerprint": c["fingerprint"],
                "tokens": tokens,  # always an ESTIMATE
                "usd": usd_for(tokens),
                "session_id": meta.get("session_id"),
                "source_event": meta.get("event"),
            }
            if c["code"]:
                entry["code"] = c["code"]
            f.write(to_json(entry) + "\n")
            added.append(entry)
            known.add(c["fingerprint"])
    return added


# ── Matching ────────────────────────────────────────────────────────────────


def match_prompt(prompt: str, registry: list[Entry]) -> list[tuple[Entry, float]]:
    """Registry entries whose keyword fingerprint overlaps the prompt, best first."""
    pset = set(keywords(prompt, 16))
    if not pset:
        return []
    scored = []
    for entry in registry:
        eset = set(entry.get("keywords") or [])
        shared = eset & pset
        if len(shared) < MIN_PROMPT_OVERLAP or not shared - GENERIC_KEYWORDS:
            continue
        score = len(shared) / len(pset | eset)
        if score >= PROMPT_MATCH_THRESHOLD:
            scored.append((entry, score))
    return sorted(scored, key=lambda s: s[1], reverse=True)


def edit_code(tool_name: str, tool_input: Any) -> str:
    """Code payload of an Edit/Write tool_input."""
    if not isinstance(tool_input, dict):
        return ""
    key = "content" if tool_name == "Write" else "new_string"
    return str(tool_input.get(key) or "")


def match_edit(code: str, registry: list[Entry]) -> tuple[Entry, float] | None:
    """Best registry entry whose reverted hunk this edit reintroduces, or None."""
    edit_lines = substantive_lines(code)
    # Tiny edits are too generic to match confidently.
    if len(edit_lines) < MIN_HUNK_LINES:
        return None
    edit_set = set(edit_lines)
    best: tuple[Entry, float] | None = None
    for entry in registry:
        entry_lines = substantive_lines(entry.get("code"))
        if len(entry_lines) < MIN_HUNK_LINES:
            continue
        entry_set = set(entry_lines)
        shared = len(entry_set & edit_set)
        # Ratio alone is not enough: MIN_HUNK_LINES literally shared lines too.
        if shared < MIN_HUNK_LINES:
            continue
        sim = shared / len(edit_set | entry_set)
        if sim >= HUNK_MATCH_THRESHOLD and (best is None or sim > best[1]):
            best = (entry, sim)
    return best


# ── Rendering ───────────────────────────────────────────────────────────────


def money(entry: Entry) -> str | None:
    usd = entry.get("usd")
    return f"~${usd:.2f}" if usd is not None else None


def dead_end_line(entry: Entry, score: float) -> str:
    bits = [f"tried on {entry.get('date')}", f"outcome: {entry.get('reason')}"]
    if cost := money(entry):
        bits.append(f"paid {cost} in tokens (est.)")
    return (
        f"⚠️  DEAD END [{js_round(score * 100)}% match]: {entry.get('summary')}\n"
        f"    → {' · '.join(bits)}"
    )


def render_prompt_card(matches: list[tuple[Entry, float]]) -> str:
    top = matches[:MAX_CARD_ENTRIES]
    total_usd = sum(e.get("usd") or 0 for e, _ in top)
    lines = [
        "╔══════════════════════════════════════════════════════════════╗",
        "║  🪦  DEAD-END REGISTRY: you have been here before             ║",
        "╚══════════════════════════════════════════════════════════════╝",
        *(dead_end_line(e, s) for e, s in top),
        "",
    ]
    advice = (
        "Do NOT silently retry the same approach: confirm with the user, "
        "or explain why it will be different this time."
    )
    if total_usd > 0:
        lines.append(
            f"💸  These dead ends already cost an estimated ~${total_usd:.2f} in tokens "
            f"the first time. {advice}"
        )
    else:
        lines.append(advice)
    return "\n".join(lines)


def render_edit_reason(entry: Entry, score: float) -> str:
    cost = money(entry)
    paid = (
        f" You have now paid for this dead end twice (an estimated {cost} in tokens the first time)."
        if cost
        else ""
    )
    what = f' What was tried: "{entry["summary"]}".' if entry.get("summary") else ""
    return (
        f"🪦 DEAD END: this change closely matches ({js_round(score * 100)}%) code you already "
        f"tried on {entry.get('date')} and walked back ({entry.get('reason')}).{what}{paid} "
        "Reintroduce it only if you know why it will be different this time."
    )


def render_registry(entries: list[Entry]) -> str:
    """This repo's recorded dead ends as a human-readable card, newest first."""
    if not entries:
        return (
            "No dead ends recorded yet for this repo.\n"
            "Keep using Claude Code here: the Stop/PreCompact hooks mine tried-and-reverted "
            "approaches as you go: then run this again."
        )

    def stamp(e: Entry) -> float:
        raw = e.get("ts") or e.get("date")
        dt = _parse_ts(raw) if isinstance(raw, str) else None
        return dt.timestamp() if dt else 0  # undated entries sort last

    ordered = sorted(entries, key=stamp, reverse=True)
    n = len(ordered)
    lines = [
        "╔══════════════════════════════════════════════════════════════╗",
        "║  🪦  DEAD-END REGISTRY: approaches already tried & walked back ║",
        "╚══════════════════════════════════════════════════════════════╝",
        f"{n} recorded dead end{'' if n == 1 else 's'} for this repo (newest first):",
        "",
    ]
    total_usd = 0.0
    for i, e in enumerate(ordered, 1):
        bits = [
            f"tried {e.get('date') or 'unknown date'}",
            f"walked back: {e.get('reason') or 'ruled out'}",
        ]
        if cost := money(e):
            bits.append(f"paid {cost} in tokens (est.)")
            total_usd += e.get("usd") or 0
        lines.append(f"{i}. {e.get('summary') or '(no summary recorded)'}")
        lines.append(f"    → {' · '.join(bits)}")
    if total_usd > 0:
        lines += [
            "",
            f"💸  Estimated total already paid for these dead ends the first time: "
            f"~${total_usd:.2f} in tokens.",
        ]
    return "\n".join(lines)


# ── Event handlers ──────────────────────────────────────────────────────────


def handle_mine(data: dict[str, Any]) -> dict[str, Any]:
    event, session_id = data.get("hook_event_name"), data.get("session_id")
    file = registry_file_for(data.get("cwd"))
    messages = read_transcript(data.get("transcript_path"))
    if not messages:
        log(HOOK, "MINE_SKIP", reason="empty transcript", event=event, session_id=session_id)
        return {}
    candidates = extract_dead_ends(messages)
    if not candidates:
        log(HOOK, "MINE_NONE", event=event, session_id=session_id)
        return {}
    tokens = estimate_tokens(messages)
    added = persist_dead_ends(
        file, candidates, {"tokens": tokens, "session_id": session_id, "event": event}
    )
    compact_registry(file)
    log(
        HOOK,
        "MINED",
        event=event,
        found=len(candidates),
        added=len(added),
        tokens=tokens,
        session_id=session_id,
    )
    return {}


def handle_prompt(data: dict[str, Any]) -> dict[str, Any]:
    prompt = data.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return {}
    registry = read_registry(registry_file_for(data.get("cwd")))
    matches = match_prompt(prompt, registry)
    if not matches:
        return {}
    log(
        HOOK,
        "PROMPT_MATCH",
        matches=len(matches),
        top=matches[0][0].get("fingerprint"),
        score=round(matches[0][1], 2),
        session_id=data.get("session_id"),
    )
    return {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": render_prompt_card(matches),
        }
    }


def handle_edit(data: dict[str, Any]) -> dict[str, Any]:
    tool_name = data.get("tool_name")
    if tool_name not in {"Edit", "Write"}:
        return {}
    registry = read_registry(registry_file_for(data.get("cwd")))
    match = match_edit(edit_code(tool_name, data.get("tool_input")), registry)
    if match is None:
        return {}
    entry, score = match
    log(
        HOOK,
        "EDIT_ASK",
        tool=tool_name,
        score=round(score, 2),
        fingerprint=entry.get("fingerprint"),
        session_id=data.get("session_id"),
    )
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": render_edit_reason(entry, score),
        }
    }


def route(data: dict[str, Any]) -> dict[str, Any]:
    match data.get("hook_event_name"):
        case "Stop" | "SubagentStop" | "PreCompact":
            return handle_mine(data)
        case "UserPromptSubmit":
            return handle_prompt(data)
        case "PreToolUse":
            return handle_edit(data)
        case _:
            return {}


def main() -> None:
    if "--render" in sys.argv[1:]:
        print(render_registry(read_registry(registry_file_for(str(Path.cwd())))))
        return
    emit(route(read_event()))


if __name__ == "__main__":
    main()
