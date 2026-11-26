#!/usr/bin/env bash
# Require Worktree - PreToolUse hook for Write|Edit|NotebookEdit.
# Denies edits to tracked files of a checkout on a protected branch: each task is done in
# its own worktree under ~/worktrees, on a feature branch (docs/git.md § Start a task).
#
# Allowed: files outside any repo, gitignored files, repos listed in worktree_exempt.conf.
# Each feature worktree edited is recorded for the session, for require_pr.sh.
set -euo pipefail
HOOK=require-worktree
# shellcheck source=hooklib.sh
source "$(dirname "${BASH_SOURCE[0]}")/hooklib.sh"
EXEMPT_CONF=${WORKTREE_EXEMPT_CONF:-$(dirname "${BASH_SOURCE[0]}")/worktree_exempt.conf}

# is_exempt TOPLEVEL: listed in the exempt conf (one repo root per line, `~` allowed).
is_exempt() {
	local line
	[[ -f $EXEMPT_CONF ]] || return 1
	while IFS= read -r line; do
		[[ -z $line || $line == \#* ]] && continue
		[[ ${line/#\~/$HOME} == "$1" ]] && return 0
	done <"$EXEMPT_CONF"
	return 1
}

# record SESSION_ID TOPLEVEL: add the worktree to the session's list, once.
record() {
	local list
	[[ -n $1 ]] || return 0
	list=$(session_worktrees_file "$1")
	mkdir -p "$(dirname "$list")"
	grep -qxF -- "$2" "$list" 2>/dev/null || printf '%s\n' "$2" >>"$list"
}

# worktree_root TOPLEVEL: where feature worktrees go (docs/git.md § Branches). Bare layout
# (git data in <container>/.bare): <container>, next to main/. Otherwise ~/worktrees/<repo>.
worktree_root() {
	local common
	common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)
	if [[ $(basename "$common") == .bare ]]; then
		dirname "$common"
	else
		printf '%s/worktrees/%s\n' "$HOME" "$(basename "$1")"
	fi
}

main() {
	local event file dir top branch wt_root
	event=$(cat)
	file=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"$event")
	[[ $file == /* ]] || return 0
	dir=$(dirname "$file")
	while [[ ! -d $dir ]]; do dir=$(dirname "$dir"); done
	top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
	branch=$(branch_of "$top")

	if ! is_protected "$branch"; then
		[[ -z $branch ]] || record "$(jq -r '.session_id // ""' <<<"$event")" "$top"
		return 0
	fi
	is_exempt "$top" && return 0
	git -C "$top" check-ignore -q -- "$file" && return 0

	wt_root=$(worktree_root "$top")
	hook_log BLOCKED id edit-on-protected file "$file" branch "$branch" \
		session_id "$(jq -r '.session_id // ""' <<<"$event")"
	pre_tool_deny "⛔ [edit-on-protected] $top is on $branch. Do this task in a worktree:
  git -C $top fetch origin
  git -C $top worktree add $wt_root/<type>-<slug> -b <type>/<slug> --no-track origin/$branch
then make this edit under $wt_root/<type>-<slug>/ instead (docs/git.md § Start a task). Without an origin remote, base it on $branch."
}

main
