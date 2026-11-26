#!/usr/bin/env python3
"""Git Conventions - PreToolUse hook for Bash. Logs to ~/.claude/hooks-logs/.

Denies a commit message, new branch name or PR title that breaks conventions.py, and warns
when a pull request exceeds PR_LINES. What it can't see (an editor, a $VAR) it lets through.

A repo with its own conventions opts out with a commitlint config, or with
`git config claude.conventions false`.
"""

import re
from pathlib import Path

from conventions import branch_error, subject_error, title_error
from gitcmd import Call, calls
from hooklib import emit, log, pre_tool_decision, read_event

HOOK = "git-conventions"
PR_LINES = 300
TRUNKS = {"main", "master"}
COMMIT_VALUE_FLAGS = "mFCctuS"
PR_VALUE_FLAGS = "aBbFHlmprtT"
BRANCH_FLAGS = {
    "switch": ("cC", {"--create", "--force-create"}),
    "checkout": ("bB", set()),
    "worktree": ("bB", set()),
}


def option(args: list[str], short: str, long: set[str], value_flags: str = "") -> str | None:
    """Value of the first matching option: -x v, -xv, -axv, --long v or --long=v."""
    for i, a in enumerate(args):
        if a == "--":
            return None
        following = args[i + 1] if i + 1 < len(args) else None
        if a.startswith("--"):
            name, eq, value = a.partition("=")
            if name in long:
                return value if eq else following
        elif a.startswith("-"):
            for j, flag in enumerate(a[1:], 1):
                if flag in short:
                    return a[j + 1 :] or following
                if flag in value_flags:
                    break
    return None


def unresolved(text: str) -> bool:
    """The shell still has to expand this, so its final text is unknown here."""
    return "$" in text or "`" in text


def opted_out(call: Call) -> bool:
    if call.git("config", "--type=bool", "claude.conventions") == "false":
        return True
    top = call.git("rev-parse", "--show-toplevel")
    return bool(top) and any(
        any(Path(top).glob(pattern)) for pattern in ("commitlint.config.*", ".commitlintrc*")
    )


def check_commit(call: Call, args: list[str]) -> str | None:
    message = option(args, "m", {"--message"}, COMMIT_VALUE_FLAGS)
    if message is None:
        source = option(args, "F", {"--file"}, COMMIT_VALUE_FLAGS)
        if source is None:
            return None
        if source == "-":
            message = next((a for a in args if "\n" in a), None)
        elif (file := call.cwd / Path(source).expanduser()).is_file():
            message = file.read_text(errors="replace")
        if message is None:
            return None
    subject = (message.strip().splitlines() or [""])[0]
    return None if unresolved(subject) else subject_error(subject)


def exists_on_remote(call: Call, name: str) -> bool:
    refs = call.git("for-each-ref", "--format=%(refname:lstrip=3)", "refs/remotes")
    return name in refs.splitlines()


def check_branch(call: Call, name: str) -> str | None:
    """A name already on a remote is kept, whatever its prefix."""
    if name in TRUNKS or unresolved(name) or exists_on_remote(call, name):
        return None
    return branch_error(name)


def check_push(call: Call, args: list[str]) -> str | None:
    if "--set-upstream" not in args and not any(re.fullmatch(r"-[a-z]*u[a-z]*", a) for a in args):
        return None
    refspecs = [a for a in args if not a.startswith("-")][1:] or ["HEAD"]
    for refspec in refspecs:
        name = refspec.lstrip("+").rpartition(":")[2].removeprefix("refs/heads/")
        if name in {"HEAD", "@"}:
            name = call.git("branch", "--show-current")
        if name and (error := check_branch(call, name)):
            return error
    return None


def is_pr_create(call: Call) -> bool:
    return call.tool == "gh" and call.args[:2] in (["pr", "create"], ["pr", "new"])


def pr_size(call: Call) -> int:
    args = call.args[2:]
    base = option(args, "B", {"--base"}, PR_VALUE_FLAGS) or "main"
    head = option(args, "H", {"--head"}, PR_VALUE_FLAGS) or "HEAD"
    if call.git("rev-parse", "-q", "--verify", f"refs/remotes/origin/{base}"):
        base = f"origin/{base}"
    stat = call.git("diff", "--shortstat", f"{base}...{head}")
    return sum(int(n) for n in re.findall(r"(\d+) (?:insertion|deletion)", stat))


def check(call: Call) -> tuple[str, str] | None:
    """(rule id, reason) when the call must be denied."""
    if is_pr_create(call):
        title = option(call.args[2:], "t", {"--title"}, PR_VALUE_FLAGS)
        error = None if title is None or unresolved(title) else title_error(title)
        return ("pr-title", error) if error else None
    if call.tool != "git" or not call.args:
        return None
    sub, args = call.args[0], call.args[1:]
    if sub == "commit":
        error = check_commit(call, args)
        return ("commit-message", error) if error else None
    if sub == "push":
        error = check_push(call, args)
        return ("branch-name", error) if error else None
    if sub in BRANCH_FLAGS and (sub != "worktree" or args[:1] == ["add"]):
        short, long = BRANCH_FLAGS[sub]
        name = option(args, short, long)
        error = check_branch(call, name) if name else None
        return ("branch-name", error) if error else None
    return None


def main() -> None:
    data = read_event()
    if data.get("tool_name") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    context = {"cmd": cmd, "session_id": data.get("session_id"), "cwd": data.get("cwd")}
    warning = ""
    for call in calls(cmd, data.get("cwd") or "."):
        hit = check(call)
        size = pr_size(call) if is_pr_create(call) else 0
        if (hit is None and size <= PR_LINES) or opted_out(call):
            continue
        if hit:
            id_, reason = hit
            log(HOOK, "BLOCKED", id=id_, **context)
            return pre_tool_decision("deny", f"⛔ [{id_}] {reason}")
        warning = f"⚠️ [pr-size] {size} changed lines, over {PR_LINES}; consider splitting the PR"
    if warning:
        log(HOOK, "WARNED", id="pr-size", **context)
        output = {"hookEventName": "PreToolUse", "additionalContext": warning}
        emit({"systemMessage": warning, "hookSpecificOutput": output})


if __name__ == "__main__":
    main()
