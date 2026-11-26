# shellcheck shell=bash disable=SC2034  # constants are used by the sourcing hooks
# Shared plumbing for shell command hooks: event in, decision out, JSONL log.
# Source it; the caller sets `set -euo pipefail` and HOOK (its log name).

HOOKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOKS_LOG_DIR="$HOME/.claude/hooks-logs"
HOOKS_STATE_DIR="$HOME/.claude/hook-state"
VAULT="$HOME/Documents/zettelkasten"
# Simplified gitflow: the user merges feature branches into these via pull requests.
PROTECTED_BRANCHES=(main master)

# now_iso: UTC timestamp in the JS toISOString() shape the logs and registries use.
now_iso() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }

# ev FILTER: jq FILTER applied to the event in $EVENT, raw output ('' for null).
ev() { jq -r "($1) // empty" <<<"$EVENT"; }

# hook_log LEVEL [KEY VALUE]...: append one record to today's log. Empty values are
# dropped; a KEY ending in `:json` takes VALUE as JSON (numbers, arrays).
hook_log() {
	local level=$1 stamp
	shift
	stamp=$(now_iso)
	mkdir -p "$HOOKS_LOG_DIR"
	jq -cn --arg ts "$stamp" --arg hook "$HOOK" --arg level "$level" --args '
		reduce range(0; $ARGS.positional | length; 2) as $i
			({ts: $ts, hook: $hook, level: $level};
			 $ARGS.positional[$i] as $k | $ARGS.positional[$i + 1] as $v
			 | if $v == "" then .
			   elif ($k | endswith(":json")) then .[$k | rtrimstr(":json")] = ($v | fromjson)
			   else .[$k] = $v end)' \
		-- "$@" >>"$HOOKS_LOG_DIR/${stamp:0:10}.jsonl"
}

# pre_tool_decision allow|ask|deny REASON: PreToolUse verdict.
pre_tool_decision() {
	jq -cn --arg d "$1" --arg r "$2" \
		'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
}
pre_tool_deny() { pre_tool_decision deny "$1"; }

# stop_block REASON: Stop/PostToolUse verdict that sends Claude back to work.
stop_block() { jq -cn --arg r "$1" '{decision: "block", reason: $r}'; }

# shell_words TEXT: split one simple command into words like shlex.split(comments=True),
# one per line (NUL-free). Unbalanced quotes fall back to whitespace splitting.
shell_words() {
	local words
	if ! words=$(xargs -r printf '%s\n' <<<"$1" 2>/dev/null); then
		words=$(tr -s '[:space:]' '\n' <<<"$1" | sed '/^$/d')
	fi
	# a word starting with # begins a comment
	awk '/^#/ {exit} {print}' <<<"$words"
}

# abs_path BASE PATH: PATH with ~ expanded, made absolute against BASE, normalized
# and symlink-resolved like Path.resolve() (missing parts allowed).
abs_path() {
	local p=${2/#\~/$HOME}
	[[ $p == /* ]] || p=$1/$p
	realpath -m -- "$p"
}

# is_protected BRANCH
is_protected() {
	local b
	for b in "${PROTECTED_BRANCHES[@]}"; do [[ $1 == "$b" ]] && return 0; done
	return 1
}

# branch_of DIR: checked-out branch; empty outside a repo, on a detached HEAD, or if DIR is missing.
branch_of() { [[ -d $1 ]] && git -C "$1" branch --show-current 2>/dev/null || true; }

# session_worktrees_file SESSION_ID: where a session's touched feature worktrees are listed.
session_worktrees_file() { printf '%s/worktree-sessions/%s' "$HOOKS_STATE_DIR" "$1"; }
