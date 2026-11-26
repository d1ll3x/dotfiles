#!/usr/bin/env bash
# Require PR - Stop hook.
# Before stopping, every feature worktree this session edited (recorded by
# require_worktree.sh) must be handed off: pushed, with a pull request open.
#
# A worktree is skipped while it has uncommitted changes (mid-task, e.g. stopping to ask
# a question), when it has no commits ahead of origin/main, or when it has no origin
# remote. Blocks once per stop: a stop that is already a retry (stop_hook_active) passes.
set -euo pipefail
HOOK=require-pr
# shellcheck source=hooklib.sh
source "$(dirname "${BASH_SOURCE[0]}")/hooklib.sh"

# handoff_gap WORKTREE: print what's missing for the hand-off; nothing if done or skipped.
handoff_gap() {
	local wt=$1 branch ahead out
	[[ -d $wt ]] || return 0
	branch=$(branch_of "$wt")
	[[ -n $branch ]] && ! is_protected "$branch" || return 0
	[[ -z $(git -C "$wt" status --porcelain) ]] || return 0
	git -C "$wt" rev-parse -q --verify refs/remotes/origin/main >/dev/null || return 0
	ahead=$(git -C "$wt" rev-list --count origin/main..HEAD)
	((ahead > 0)) || return 0

	if ! git -C "$wt" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null ||
		(($(git -C "$wt" rev-list --count "origin/$branch..HEAD") > 0)); then
		printf -- '- %s (%s): not pushed; push it and open the PR\n' "$wt" "$branch"
		return 0
	fi
	if ! out=$(cd "$wt" && gh pr view "$branch" --json state -q .state 2>&1); then
		[[ $out == *"no pull requests found"* ]] || {
			printf 'require-pr: gh pr view failed in %s: %s\n' "$wt" "$out" >&2
			exit 1
		}
		printf -- '- %s (%s): pushed, no pull request; open it\n' "$wt" "$branch"
	fi
}

main() {
	local event list wt gaps=""
	event=$(cat)
	[[ $(jq -r '.stop_hook_active // false' <<<"$event") == false ]] || return 0
	list=$(session_worktrees_file "$(jq -r '.session_id // ""' <<<"$event")")
	[[ -f $list ]] || return 0
	while IFS= read -r wt; do
		gaps+=$(handoff_gap "$wt")
	done <"$list"
	[[ -n $gaps ]] || return 0
	hook_log BLOCKED id handoff-missing gaps "$gaps" \
		session_id "$(jq -r '.session_id // ""' <<<"$event")"
	stop_block "Hand off before stopping (docs/git.md § Open a pull request):
$gaps
Then give me the PR URL. If the task isn't finished, say what's left instead."
}

main
