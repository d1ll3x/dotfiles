#!/usr/bin/env bash
# Tests for the git-workflow hooks: git_safety.sh, require_worktree.sh, require_pr.sh.
# Run: bash ~/.agents/hooks/tests/git_safety_test.sh
set -euo pipefail
HOOKS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# Hooks log and keep state under $HOME; keep test runs out of the real ones.
export HOME=$TMP/home GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$HOME"
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# main checkout on main, a feature worktree, a repo with a bare "origin"
g init -qb main "$TMP/origin.git" --bare
g clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
g -C "$TMP/repo" commit -q --allow-empty -m init
g -C "$TMP/repo" push -q origin main
printf 'ignored.txt\n' >"$TMP/repo/.gitignore"
g -C "$TMP/repo" add .gitignore && g -C "$TMP/repo" commit -qm ignore && g -C "$TMP/repo" push -q origin main
WT=$HOME/worktrees/repo/feat-x
g -C "$TMP/repo" worktree add -q "$WT" -b feat/x --no-track origin/main
mkdir -p "$TMP/repo/a/b" "$TMP/vault" && g init -qb main "$TMP/vault"

bash_event() { jq -cn --arg c "$1" --arg d "$2" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, session_id: "test"}'; }
edit_event() { jq -cn --arg f "$1" '{tool_name: "Edit", tool_input: {file_path: $f}, cwd: "/", session_id: "test"}'; }
stop_event() { jq -cn '{hook_event_name: "Stop", stop_hook_active: false, session_id: "test", cwd: "/"}'; }

# expect WANT(deny|allow|block) NAME HOOK EVENT
expect() {
	local want=$1 name=$2 hook=$3 out got
	out=$(HOOK_SAFETY_LEVEL=strict bash "$HOOKS/$hook" <<<"$4")
	got=$(jq -r '.hookSpecificOutput.permissionDecision // .decision // "allow"' <<<"${out:-{\}}")
	if [[ $got == "$want" ]]; then return; fi
	FAILS=$((FAILS + 1))
	printf 'FAIL %s: want %s, got %s\n  %s\n' "$name" "$want" "$got" "$out"
}
safety() { expect "$1" "git_safety: $2" git_safety.sh "$(bash_event "$2" "${3:-$TMP/repo}")"; }

# --- git_safety.sh ---
safety deny 'git push origin main'
safety deny 'git push origin HEAD:main' "$WT"
safety deny 'git push origin feat/x:refs/heads/main' "$WT"
safety deny 'git push --force origin feat/x' "$WT"
safety deny 'git push -f origin feat/x' "$WT"
safety deny 'git branch -D main' "$WT"
safety deny 'gh pr merge 12'
safety deny 'gh pr close 3'
safety deny 'echo ok; git commit -m x'
safety deny "cd $TMP/repo && git commit -m x" "$WT"
safety deny "git -C $TMP/repo commit -m x" "$WT"
safety deny 'git -C ../.. rebase origin/main' "$TMP/repo/a/b"
safety allow 'git push -u origin fix/main-menu' "$WT"
safety allow 'git push origin main-fix' "$WT"
safety allow 'git push --force-with-lease' "$WT"
safety allow 'git push origin --delete feat/domain' "$WT"
safety allow 'git commit -m x' "$WT"
safety allow "cd $WT && git commit -m x && git push -u origin feat/x"
safety allow "git -C $WT commit -m 'fix: main; push to main'"
safety allow 'git commit -m x' "$TMP" # not a repo
# Logged false positives from 2026-11-02 and 2026-11-08:
safety allow 'git push -u origin feat/x 2>&1 | tail -2 && gh pr create --base main --title t' "$WT"
safety allow "$(printf "cat > /tmp/pr.md <<'EOF'\nnever lands on main.\ngit push origin main\nEOF\ngh pr create --base main --body-file /tmp/pr.md")" "$WT"
safety allow "$(printf 'cat <<-EOF\n\tgit push origin main\n\tEOF')" "$WT"
safety allow 'jq -r .n <<<"$m" && git status' "$WT"

# --- require_worktree.sh ---
worktree() { expect "$1" "require_worktree: $2" require_worktree.sh "$(edit_event "$2")"; }
worktree deny "$TMP/repo/README.md"
worktree deny "$TMP/repo/new/dir/file.md"
worktree allow "$TMP/repo/ignored.txt"
worktree allow "$WT/README.md"
worktree allow "$TMP/not-a-repo.md"
printf '%s\n' "$TMP/vault" >"$HOME/worktree_exempt.conf"
WORKTREE_EXEMPT_CONF=$HOME/worktree_exempt.conf worktree allow "$TMP/vault/note.md"

# --- require_pr.sh --- ($WT is now recorded for session "test")
pr() { expect "$1" "require_pr: $2" require_pr.sh "$(stop_event)"; }
pr allow 'no commits ahead of origin/main'
printf 'x\n' >"$WT/README.md"
pr allow 'uncommitted work: mid-task'
g -C "$WT" add README.md && g -C "$WT" commit -qm 'feat: x'
pr block 'committed, not pushed'
expect allow 'require_pr: stop_hook_active' require_pr.sh \
	"$(stop_event | jq -c '.stop_hook_active = true')"

if ((FAILS)); then
	printf '%d failed\n' "$FAILS"
	exit 1
fi
echo 'all passed'
