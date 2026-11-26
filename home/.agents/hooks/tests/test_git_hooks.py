"""Tests for git_safety.py and git_conventions.py, run as the real hook processes.
Run: python3 ~/.agents/hooks/tests/test_git_hooks.py
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HOOKS = Path(__file__).resolve().parent.parent
TMP = Path(tempfile.mkdtemp(prefix="git-hooks-"))
ENV = os.environ | {"HOME": str(TMP / "home"), "GIT_CONFIG_GLOBAL": "/dev/null"}
REPO, WT = TMP / "repo", TMP / "wt"


def git(*args: str, cwd: Path = TMP) -> None:
    ident = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
    subprocess.run(["git", *ident, *args], cwd=cwd, env=ENV, check=True, capture_output=True)


def hook(name: str, cmd: str, cwd: Path) -> dict:
    event = {"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": str(cwd)}
    run = subprocess.run(
        [sys.executable, HOOKS / name],
        input=json.dumps(event),
        env=ENV,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(run.stdout or "{}")


def verdict(name: str, cmd: str, cwd: Path) -> str:
    out = hook(name, cmd, cwd)
    return out.get("hookSpecificOutput", {}).get("permissionDecision", "allow")


def setUpModule() -> None:
    (TMP / "home").mkdir()
    git("init", "-qb", "main", "--bare", str(TMP / "origin.git"))
    git("clone", "-q", str(TMP / "origin.git"), str(REPO))
    git("commit", "-q", "--allow-empty", "-m", "init", cwd=REPO)
    git("push", "-q", "origin", "main", "main:renovate/all", cwd=REPO)
    git("fetch", "-q", cwd=REPO)
    git("worktree", "add", "-q", str(WT), "-b", "feat/x", "--no-track", "origin/main", cwd=REPO)


class Case(unittest.TestCase):
    name = ""

    def each(self, want: str, cwd: Path, *cmds: str) -> None:
        for cmd in cmds:
            with self.subTest(cmd=cmd):
                self.assertEqual(verdict(self.name, cmd, cwd), want)


class Safety(Case):
    name = "git_safety.py"

    def test_push(self) -> None:
        self.each(
            "deny",
            WT,
            "git push --force",
            "git push -f origin feat/x",
            "git push -uf origin feat/x",
            "git push origin +feat/x",
            "git push --mirror",
            "git push --all",
            "git push origin main",
            "git push origin HEAD:main",
            "git push origin feat/x:refs/heads/main",
            "git push origin --delete main",
            "git push origin :main",
            f"git -C {REPO} push",
            f"cd {REPO} && git push",
            "cd nowhere; git push --force",
            "FOO=1 sudo -E git push --force",
            "bash -c 'git push --force'",
            "bash <<'EOF'\ngit push --force\nEOF",
            "x=$(git push --force)",
            "if true; then git push --force; fi",
            "git push --force 2>&1 | tail -2",
            "git -c push.default=current push --force",
        )
        self.each(
            "allow",
            WT,
            "git push",
            "git push -u origin HEAD",
            "git push -u origin feat/x 2>&1 | tail -2 && gh pr create --base main --title t",
            "git push --force-with-lease",
            "git push origin fix/main-menu",
            "git push origin --delete feat/old",
            "git push --follow-tags origin feat/x",
        )
        self.each("deny", REPO, "git push", "git push origin HEAD")
        self.each("allow", REPO, f"git -C {WT} push", "git push origin feat/x")

    def test_destructive(self) -> None:
        self.each(
            "deny",
            WT,
            "git reset --hard",
            "git reset -q --hard HEAD~1",
            "git clean -f",
            "git clean -fd",
            "git clean -xdf",
            "git clean -d --force",
            "git branch -D x",
            "git branch -d -f x",
            "git branch --delete --force x",
            "git checkout .",
            "git checkout -- .",
            "git checkout HEAD -- .",
            "git restore .",
            "git restore --staged --worktree .",
            "git restore -SW .",
        )

    def test_everything_else(self) -> None:
        self.each(
            "allow",
            REPO,
            "git commit -m 'feat: x'",
            "git merge feat/x",
            "git rebase origin/main",
            "git reset --soft HEAD~1",
            "git clean -nfd",
            "git branch -d x",
            "git checkout main",
            "git checkout ./file",
            "git restore file",
            "git restore --staged .",
            "git stash drop",
            "gh pr merge 12",
        )

    def test_mentions_are_not_commands(self) -> None:
        self.each(
            "allow",
            REPO,
            "grep -E 'git push --force|git reset --hard' log",
            'echo "git clean -fd"',
            "cat > f <<'EOF'\ngit push origin main\nit's git reset --hard\nEOF\nls",
            "cat <<-EOF\n\tgit push --force\n\tEOF",
            "git commit -m 'fix: stop git push --force; git reset --hard'",
            "ls # git push --force",
            'jq . <<<"$m" && git status',
        )


class Conventions(Case):
    name = "git_conventions.py"

    def test_commit(self) -> None:
        self.each(
            "deny",
            WT,
            "git commit -m 'added stuff'",
            "git commit -m 'fix(bws) incorrect reference'",
            "git commit -m 'feat: Add thing'",
            "git commit -m 'Feat: add thing'",
            "git commit -m 'feature: add thing'",
            "git commit -am 'nope'",
            "git commit -mnope",
            "git commit --message='nope'",
            f"git -C {WT} commit -m nope",
            "git add . && git commit -m nope",
            'git commit -m "$(cat <<\'EOF\'\nnope "quoted" it\'s\n\nbody\nEOF\n)"',
            "git commit -F - <<'EOF'\nnope\n\nbody\nEOF",
        )
        self.each(
            "allow",
            WT,
            "git commit -m 'feat: add thing'",
            "git commit -m 'feat(external-dns)!: make unifi-dns the only dns provider'",
            "git commit -m 'fix(a): b' -m 'Body text, any case'",
            'git commit -m "$(cat <<\'EOF\'\nfix(a): say "it\'s" fine\n\nBody\nEOF\n)"',
            "git commit -F - <<'EOF'\nfix: ok\n\nBody\nEOF",
            'git commit -m "$MSG"',
            "git commit --amend --no-edit",
            "git commit --fixup HEAD",
            "git commit",
            "git log --grep 'commit -m nope'",
        )

    def test_branch(self) -> None:
        self.each(
            "deny",
            WT,
            "git switch -c claude/x",
            "git switch --create=x",
            "git checkout -b docs/x",
            "git checkout -B Feat/x",
            "git worktree add ../y -b wip origin/main",
            "git worktree add -b feat/a--b ../y",
            "git push -u origin HEAD:wip",
            "git push --set-upstream origin wip",
        )
        self.each(
            "allow",
            WT,
            "git switch -c feat/issue-42-bgp",
            "git checkout -b release/v1.2.0",
            "git worktree add ../y -b chore/y --no-track origin/main",
            "git worktree add ../y feat/x",
            "git worktree list",
            "git checkout -b renovate/all origin/renovate/all",
            "git push -u origin renovate/all",
            "git push -u origin HEAD",
            "git push origin wip",
            "git checkout feat/x",
        )

    def test_pr_title(self) -> None:
        long = "feat: " + "x" * 66
        self.each(
            "deny",
            WT,
            "gh pr create --title 'Add stuff' --body b",
            "gh pr create -t 'fix(bws) x'",
            f"gh pr create --title '{long}'",
        )
        self.each(
            "allow",
            WT,
            "gh pr create --base main --title 'feat(a): b' --body 'Fixes -t nope'",
            f"gh pr create --title '{long[:-1]}'",
            "gh pr create --fill",
            "gh pr view 1",
            "gh issue create --title 'Any Title'",
        )

    def test_pr_size_warns_only(self) -> None:
        cmd = "gh pr create --title 'feat: x' --body b"
        (WT / "f").write_text("x\n" * 300)
        git("add", "f", cwd=WT)
        git("commit", "-qm", "feat: x", cwd=WT)
        self.assertEqual(hook(self.name, cmd, WT), {})
        (WT / "f").write_text("x\n" * 301)
        git("commit", "-qam", "feat: y", cwd=WT)
        for at, c in ((WT, cmd), (TMP, f"cd {WT} && {cmd}")):
            out = hook(self.name, c, at)
            self.assertIn("301 changed lines", out["systemMessage"])
            self.assertNotIn("permissionDecision", out["hookSpecificOutput"])

    def test_repo_opt_out(self) -> None:
        repo = TMP / "own"
        git("init", "-q", str(repo))
        self.each("deny", repo, "git commit -m nope")
        git("config", "claude.conventions", "false", cwd=repo)
        self.each("allow", repo, "git commit -m nope", "git switch -c nope")
        git("config", "--unset", "claude.conventions", cwd=repo)
        (repo / "commitlint.config.js").touch()
        self.each("allow", repo, "git commit -m nope")


if __name__ == "__main__":
    unittest.main()
