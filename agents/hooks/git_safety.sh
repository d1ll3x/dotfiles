#!/usr/bin/env bash
# Git Safety - PreToolUse hook for Bash.
# Blocks destructive git and gh CLI operations. Logs to ~/.claude/hooks-logs/.
#
# The command is checked one simple command (segment) at a time: heredoc bodies are
# dropped, then it is split on && || ; | and newlines. So `git push -u origin feat/x &&
# gh pr create --base main` is not a push to main.
#
# Branch-only rules look up the branch where the segment runs: the event's cwd, moved
# by earlier `cd`/`pushd` segments, overridden by the segment's own `git -C <dir>`.
#
# HOOK_SAFETY_LEVEL: critical | high | strict (default high); invalid values fall back.
#   critical - no git-safety rules apply (defer entirely to block_dangerous_commands.sh)
#   high     - branch-aware guardrails (commit/merge/rebase/reset/push on a protected
#              branch), protected-branch deletion, pushes to main/master by name, and
#              destructive gh CLI operations
#   strict   - + force-push, so this hook is self-sufficient standalone
set -euo pipefail
HOOK=git-safety
# shellcheck source=hooklib.sh
source "$(dirname "${BASH_SOURCE[0]}")/hooklib.sh"

declare -A RANK=([critical]=1 [high]=2 [strict]=3)
declare -A EMOJI=([critical]=🚨 [high]=⛔ [strict]=⚠️)
SAFETY_LEVEL=${HOOK_SAFETY_LEVEL:-high}
[[ -v RANK[$SAFETY_LEVEL] ]] || SAFETY_LEVEL=high

# `git`, any `-C <dir>`/`-c <k=v>` options, then the subcommand
GIT='\bgit(?:\s+-[Cc]\s+\S+)*\s+'
# A protected branch as a whole ref or refspec destination (`main`, `HEAD:main`,
# `x:refs/heads/main`), not `fix/main-menu`
PROTECTED_REF='[\s:](?:refs/heads/)?(?:main|master)(?=\s|$)'

# level|id|on_protected_branch_only|reason|PCRE matched against one segment
RULES=(
	"strict|force-push|0|Force-pushing is not allowed|${GIT}push\b.*\s(?:--force(?!-with-lease|-if-includes)|-f)\b"
	"high|push-protected|0|Pushing to main/master is not allowed|${GIT}push\b.*${PROTECTED_REF}"
	"high|branch-delete-protected|0|Deleting a protected branch is not allowed|${GIT}branch\s+.*(?:-[dD]|--delete)\s+(?:main|master)(?=\s|$)"
	"high|commit-on-protected|1|Committing directly on {branch} is not allowed|${GIT}commit\b"
	"high|merge-on-protected|1|Merging into {branch} is not allowed|${GIT}merge\b"
	"high|rebase-on-protected|1|Rebasing {branch} is not allowed|${GIT}rebase\b"
	"high|reset-on-protected|1|Resetting {branch} is not allowed|${GIT}reset\b"
	"high|push-on-protected|1|Pushing from {branch} is not allowed|${GIT}push\b"
	"high|gh-pr-merge|0|Merging PRs via gh CLI is not allowed|\bgh\s+pr\s+merge\b"
	"high|gh-pr-close|0|Closing PRs via gh CLI is not allowed|\bgh\s+pr\s+close\b"
	"high|gh-issue-close|0|Closing issues via gh CLI is not allowed|\bgh\s+issue\s+close\b"
	"high|gh-release-delete|0|Deleting releases via gh CLI is not allowed|\bgh\s+release\s+delete\b"
	"high|gh-repo-delete|0|Deleting repos via gh CLI is not allowed|\bgh\s+repo\s+delete\b"
)

# Print lines, skipping heredoc bodies (the `<<EOF` line itself stays). `<<<` is a
# here-string, not a heredoc.
STRIP_HEREDOCS='
pending == "" {
	print
	if (match($0, /(^|[^<])<<-?[ \t]*["\047\\]?[A-Za-z_][A-Za-z0-9_]*/)) {
		d = substr($0, RSTART, RLENGTH)
		sub(/^[^<]?<<-?[ \t]*["\047\\]?/, "", d)
		pending = d
	}
	next
}
{ t = $0; sub(/^\t+/, "", t); if (t == pending) pending = "" }
'

# segments CMD: one simple command per line.
segments() { awk "$STRIP_HEREDOCS" <<<"$1" | sed -E 's/&&|\|\||;|\|/\n/g'; }

# resolve_dir BASE PATH: absolute PATH as seen from BASE; empty when it can't be known
# statically (unknown BASE for a relative path, `cd -`, variables other than HOME).
resolve_dir() {
	local base=$1 path=${2//[\"\']/}
	path=${path/#\~/$HOME}
	path=${path/#\$\{HOME\}/$HOME}
	path=${path/#\$HOME/$HOME}
	if [[ $path == - || $path == *'$'* ]]; then
		return
	elif [[ $path == /* ]]; then
		printf '%s' "$path"
	elif [[ -n $base ]]; then
		printf '%s/%s' "$base" "$path"
	fi
}

# check CMD CWD: print "id<TAB>level<TAB>reason" for the first violation, nothing if allowed.
check() {
	local seg dir=$2 rule level id branch_only reason regex git_dir branch
	while IFS= read -r seg; do
		if [[ $seg =~ ^[[:space:]\(\{]*(cd|pushd)[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
			dir=$(resolve_dir "$dir" "${BASH_REMATCH[2]}")
			continue
		fi
		for rule in "${RULES[@]}"; do
			IFS='|' read -r level id branch_only reason regex <<<"$rule"
			((RANK[$level] <= RANK[$SAFETY_LEVEL])) || continue
			grep -qP -- "$regex" <<<"$seg" || continue
			if ((branch_only)); then
				git_dir=$dir
				if [[ $seg =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
					git_dir=$(resolve_dir "$dir" "${BASH_REMATCH[1]}")
				fi
				branch=$(branch_of "$git_dir")
				is_protected "$branch" || continue
				reason=${reason//\{branch\}/$branch}
			fi
			printf '%s\t%s\t%s\n' "$id" "$level" "$reason"
			return
		done
	done < <(segments "$1")
}

main() {
	local event cmd cwd hit id level reason
	event=$(cat)
	[[ $(jq -r '.tool_name // ""' <<<"$event") == Bash ]] || return 0
	cmd=$(jq -r '.tool_input.command // ""' <<<"$event")
	cwd=$(jq -r '.cwd // ""' <<<"$event")
	hit=$(check "$cmd" "${cwd:-$PWD}")
	[[ -n $hit ]] || return 0
	IFS=$'\t' read -r id level reason <<<"$hit"
	hook_log BLOCKED id "$id" priority "$level" cmd "$cmd" cwd "$cwd" \
		session_id "$(jq -r '.session_id // ""' <<<"$event")" \
		permission_mode "$(jq -r '.permission_mode // ""' <<<"$event")"
	pre_tool_deny "${EMOJI[$level]} [$id] $reason"
}

main
