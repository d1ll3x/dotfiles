#!/usr/bin/env python3
"""Block Dangerous Commands - PreToolUse Hook for Bash.
Blocks dangerous patterns before execution. Logs to: ~/.claude/hooks-logs/

HOOK_SAFETY_LEVEL: 'critical' | 'high' | 'strict' (default: 'high')
  critical - Only catastrophic: rm -rf ~, dd to disk, fork bombs
  high     - + risky: force push main, secrets exposure, git reset --hard
  strict   - + cautionary: any force push, sudo rm, docker prune
Invalid values fall back to the default.

Ask mode (opt-in, per level): HOOK_ASK_CRITICAL / HOOK_ASK_HIGH / HOOK_ASK_STRICT set
to the literal "true" makes that level prompt the user ("ask") instead of denying.
"""

import os
import re
from typing import NamedTuple

from hooklib import log, pre_tool_decision, read_event

HOOK = "block-dangerous-commands"
LEVELS = {"critical": 1, "high": 2, "strict": 3}
EMOJIS = {"critical": "🚨", "high": "⛔", "strict": "⚠️"}
SAFETY_LEVEL = os.environ.get("HOOK_SAFETY_LEVEL", "high")
if SAFETY_LEVEL not in LEVELS:
    SAFETY_LEVEL = "high"
ASK = {level: os.environ.get(f"HOOK_ASK_{level.upper()}") == "true" for level in LEVELS}


class Pattern(NamedTuple):
    level: str
    id: str
    regex: re.Pattern[str]
    reason: str


def _p(level: str, id_: str, regex: str, reason: str) -> Pattern:
    return Pattern(level, id_, re.compile(regex), reason)


PATTERNS = [
    # CRITICAL - Catastrophic, unrecoverable
    _p("critical", "rm-home", r"""\brm\s+(-.+\s+)*["']?~/?["']?(\s|$|[;&|])""", "rm targeting home directory"),
    _p("critical", "rm-home-var", r"""\brm\s+(-.+\s+)*["']?\$HOME["']?(\s|$|[;&|])""", "rm targeting $HOME"),
    _p("critical", "rm-home-trailing", r"""\brm\s+.+\s+["']?(~/?|\$HOME)["']?(\s*$|[;&|])""", "rm with trailing ~/ or $HOME"),
    _p("critical", "rm-root", r"\brm\s+(-.+\s+)*/(\*|\s|$|[;&|])", "rm targeting root filesystem"),
    _p("critical", "rm-system", r"\brm\s+(-.+\s+)*/(etc|usr|var|bin|sbin|lib|boot|dev|proc|sys)(/|\s|$)", "rm targeting system directory"),
    _p("critical", "rm-cwd", r"\brm\s+(-.+\s+)*(\./?|\*|\./\*)(\s|$|[;&|])", "rm deleting current directory contents"),
    _p("critical", "dd-disk", r"\bdd\b.+of=/dev/(sd[a-z]|nvme|hd[a-z]|vd[a-z]|xvd[a-z])", "dd writing to disk device"),
    _p("critical", "mkfs", r"\bmkfs(\.\w+)?\s+/dev/(sd[a-z]|nvme|hd[a-z]|vd[a-z])", "mkfs formatting disk"),
    _p("critical", "fork-bomb", r":\(\)\s*\{.*:\s*\|\s*:.*&", "fork bomb detected"),
    # HIGH - Significant risk, data loss, security
    _p("high", "curl-pipe-sh", r"\b(curl|wget)\b.+\|\s*(ba)?sh\b", "piping URL to shell (RCE risk)"),
    _p("high", "git-force-main", r"\bgit\s+push\b(?!.+--force-with-lease).+(--force|-f)\b.+\b(main|master)\b", "force push to main/master"),
    _p("high", "git-reset-hard", r"\bgit\s+reset\s+--hard", "git reset --hard loses uncommitted work"),
    _p("high", "git-clean-f", r"\bgit\s+clean\s+(-\w*f|-f)", "git clean -f deletes untracked files"),
    _p("high", "chmod-777", r"\bchmod\b.+\b777\b", "chmod 777 is a security risk"),
    _p("high", "docker-vol-rm", r"\bdocker\s+volume\s+(rm|prune)", "docker volume deletion loses data"),
    # STRICT - Cautionary, context-dependent
    _p("strict", "git-force-any", r"\bgit\s+push\b(?!.+--force-with-lease).+(--force|-f)\b", "force push (use --force-with-lease)"),
    _p("strict", "git-checkout-dot", r"\bgit\s+checkout\s+\.", "git checkout . discards changes"),
    _p("strict", "sudo-rm", r"\bsudo\s+rm\b", "sudo rm has elevated privileges"),
    _p("strict", "docker-prune", r"\bdocker\s+(system|image)\s+prune", "docker prune removes images"),
    _p("strict", "crontab-r", r"\bcrontab\s+-r", "removes all cron jobs"),
]  # fmt: skip


def check_command(cmd: str, safety_level: str = SAFETY_LEVEL) -> Pattern | None:
    threshold = LEVELS[safety_level]
    return next((p for p in PATTERNS if LEVELS[p.level] <= threshold and p.regex.search(cmd)), None)


def main() -> None:
    data = read_event()
    if data.get("tool_name") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    p = check_command(cmd)
    if p is None:
        return
    decision = "ask" if ASK[p.level] else "deny"
    log(
        HOOK,
        decision.upper() if decision == "ask" else "BLOCKED",
        id=p.id,
        priority=p.level,
        decision=decision,
        cmd=cmd,
        session_id=data.get("session_id"),
        cwd=data.get("cwd"),
        permission_mode=data.get("permission_mode"),
    )
    pre_tool_decision(decision, f"{EMOJIS[p.level]} [{p.id}] {p.reason}")


if __name__ == "__main__":
    main()
