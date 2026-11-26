#!/usr/bin/env python3
"""Git Safety - PreToolUse hook for Bash. Logs to ~/.claude/hooks-logs/.

Denies only the git commands below, in all their spellings; every other git and gh command
is allowed:
  push             forced, or reaching main/master (--force-with-lease of a task branch is fine)
  reset --hard
  clean -f         (a dry run is fine)
  branch -D
  checkout . / restore .   (restore --staged . only unstages, so it is fine)
"""

from gitcmd import Call, calls
from hooklib import log, pre_tool_decision, read_event

HOOK = "git-safety"
TRUNKS = {"main", "master"}
WHOLE_TREE = {".", "./", "./*", ":/", ":/.", ":/*", ":(top)", "*", "**"}
PUSH_VALUE_OPTS = {"-o", "--push-option", "--receive-pack", "--exec", "--repo"}


def short_flags(args: list[str]) -> str:
    """Letters of every bundled short option: ['-fd', '-x'] -> 'fdx'."""
    return "".join(a[1:] for a in args if a.startswith("-") and not a.startswith("--"))


def check_push(call: Call, args: list[str]) -> tuple[str, str] | None:
    positional: list[str] = []
    flags: list[str] = []
    rest = iter(args)
    for a in rest:
        if a in PUSH_VALUE_OPTS:
            next(rest, None)
        else:
            (flags if a.startswith("-") else positional).append(a)

    refspecs = positional[1:]
    if "--force" in flags or "f" in short_flags(flags) or any(r.startswith("+") for r in refspecs):
        return "push-force", "Force-pushing is blocked; use --force-with-lease on a task branch"
    if "--mirror" in flags:
        return "push-force", "git push --mirror force-updates every ref"
    if {"--all", "--branches"} & set(flags):
        return "push-trunk", "Pushing every branch would include main; push one task branch"

    current = call.git("branch", "--show-current")
    for target in [r.rpartition(":")[2] for r in refspecs] or [current]:
        name = current if target in {"HEAD", "@"} else target.removeprefix("refs/heads/")
        if name in TRUNKS:
            return "push-trunk", f"Pushing to {name} is blocked; open a pull request"
    return None


def check(call: Call) -> tuple[str, str] | None:
    """(rule id, reason) when the call must be denied."""
    if call.tool != "git" or not call.args:
        return None
    sub, args = call.args[0], call.args[1:]
    opts = args[: args.index("--")] if "--" in args else args
    flags = short_flags(opts)
    forced = "f" in flags or "--force" in opts

    if sub == "push":
        return check_push(call, args)
    if sub == "reset" and "--hard" in opts:
        return "reset-hard", "git reset --hard discards uncommitted work"
    if sub == "clean" and forced and "n" not in flags and "--dry-run" not in opts:
        return "clean-force", "git clean -f deletes untracked files; preview with -n"
    if sub == "branch":
        delete = "d" in flags or "--delete" in opts
        if "D" in flags or (delete and forced):
            return "branch-delete-force", "git branch -D drops unmerged commits; use git sweep"
    if sub == "checkout" and WHOLE_TREE & set(args):
        return "checkout-all", "git checkout . discards all uncommitted changes"
    if sub == "restore" and WHOLE_TREE & set(args):
        staged = "S" in flags or "--staged" in opts
        if not staged or "W" in flags or "--worktree" in opts:
            return "restore-all", "git restore . discards all uncommitted changes"
    return None


def main() -> None:
    data = read_event()
    if data.get("tool_name") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    context = {"cmd": cmd, "session_id": data.get("session_id"), "cwd": data.get("cwd")}
    for call in calls(cmd, data.get("cwd") or "."):
        if hit := check(call):
            id_, reason = hit
            log(HOOK, "BLOCKED", id=id_, **context)
            return pre_tool_decision("deny", f"⛔ [{id_}] {reason}")


if __name__ == "__main__":
    main()
