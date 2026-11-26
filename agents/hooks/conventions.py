#!/usr/bin/env python3
"""Commit, branch and PR-title conventions; the single source for the hooks and `git wt`.

CLI: conventions.py branch <name>   exits 1 with the reason when the name is invalid.
"""

import re
import sys

COMMIT_TYPES = "feat fix docs style refactor perf test build ci chore revert".split()
BRANCH_TYPES = "feat fix hotfix release chore".split()
TITLE_LIMIT = 72

COMMIT = re.compile(
    rf"(?:{'|'.join(COMMIT_TYPES)})(?:\([a-z0-9][a-z0-9 ,./_-]*\))?!?: (?![A-Z\s])\S.*"
)
BRANCH = re.compile(rf"(?:{'|'.join(BRANCH_TYPES)})/[a-z0-9]+(?:[.-][a-z0-9]+)*")
# Subjects git itself writes
GENERATED = re.compile(r"(?:Merge |Revert \"|(?:fixup|squash|amend)! )")


def subject_error(subject: str) -> str | None:
    if COMMIT.fullmatch(subject) or GENERATED.match(subject):
        return None
    return (
        f'"{subject}" is not <type>[(scope)][!]: <description>, with a lowercase description. '
        f"Types: {', '.join(COMMIT_TYPES)}"
    )


def title_error(title: str) -> str | None:
    if error := subject_error(title):
        return error
    if len(title) >= TITLE_LIMIT:
        return f"title is {len(title)} characters; keep it under {TITLE_LIMIT}"
    return None


def branch_error(name: str) -> str | None:
    if BRANCH.fullmatch(name):
        return None
    return (
        f'"{name}" is not <type>/<name>: lowercase letters, digits, single hyphens or dots. '
        f"Types: {', '.join(BRANCH_TYPES)}"
    )


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "branch":
        sys.exit("usage: conventions.py branch <name>")
    sys.exit(branch_error(sys.argv[2]))
