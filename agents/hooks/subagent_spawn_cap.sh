#!/usr/bin/env bash
# Subagent Spawn Cap - PreToolUse hook for Agent|Task.
#
# A total-spawns-per-session budget for subagents: counts every Agent tool call per
# session_id (nested spawns from inside subagents included), asks at spawn
# SPAWN_CAP_ASK and every SPAWN_CAP_ASK_STEP after it, denies at SPAWN_CAP_DENY.
# Defaults prompt at 20, 30, 40, 50 and stop at 60.
# State: one append-only JSONL per session under ~/.claude/subagent-spawn-cap/
# (parallel hook processes append safely; count = line count). Denied calls are not
# recorded. Logs to ~/.claude/hooks-logs/.
#
# Env (validated positive integers, invalid values fall back):
#   SPAWN_CAP_ASK=20  SPAWN_CAP_ASK_STEP=10  SPAWN_CAP_DENY=60 (clamped up to
#   SPAWN_CAP_ASK if lower; equal to it = no asks)
#   SPAWN_CAP_ALLOW=true lets spawns through while set (still counted).
# Unattended (-p, dontAsk) runs turn asks into denies: set ASK equal to DENY.
set -euo pipefail
HOOK=subagent-spawn-cap
# shellcheck source=hooklib.sh
source "$(dirname "${BASH_SOURCE[0]}")/hooklib.sh"

STATE_DIR="$HOME/.claude/subagent-spawn-cap"
PRUNE_STAMP="$STATE_DIR/.last-prune"
DAY_S=$((24 * 60 * 60))
PRUNE_AFTER_S=$((7 * DAY_S))
PRUNE_EVERY_S=$DAY_S
declare -A EMOJI=([ask]=⚠️ [deny]=🚨)

# positive_int RAW FALLBACK
positive_int() {
	local raw
	raw=$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"$1")
	if [[ $raw =~ ^[0-9]+$ ]] && ((10#$raw > 0)); then echo $((10#$raw)); else echo "$2"; fi
}

# session_file SESSION_ID: session_id as a file name: safe charset, bounded length.
session_file() {
	local safe=${1//[^A-Za-z0-9._-]/_}
	printf '%s/%s.jsonl' "$STATE_DIR" "${safe:0:128}"
}

# display_path FILE
display_path() {
	# shellcheck disable=SC2088  # a literal ~ for display
	if [[ $1 == "$HOME"/* ]]; then printf '~/%s\n' "${1#"$HOME"/}"; else echo "$1"; fi
}

# prune_stale: drop ledgers untouched for 7 days; at most once a day (stamp mtime).
prune_stale() {
	local now ledger
	now=$(date +%s)
	if [[ -e $PRUNE_STAMP ]] && ((now - $(stat -c %Y -- "$PRUNE_STAMP") < PRUNE_EVERY_S)); then
		return 0
	fi
	for ledger in "$STATE_DIR"/*.jsonl; do
		[[ -e $ledger ]] || continue
		# A parallel hook may have pruned it first.
		if ((now - $(stat -c %Y -- "$ledger" 2>/dev/null || echo "$now") > PRUNE_AFTER_S)); then
			rm -f -- "$ledger"
		fi
	done
	date +%s%3N >"$PRUNE_STAMP"
}

# build_reason DECISION N LEDGER: ask reasons are shown to the user, deny reasons to Claude.
build_reason() {
	local decision=$1 n=$2 ledger silent next_check after
	ledger=$(display_path "$3")
	if [[ $decision == deny ]]; then
		echo "[spawn-cap] Subagent spawn #$n in this session hit the hard cap (SPAWN_CAP_DENY=$DENY). Do not retry: finish with the results you already have and tell the user the session's spawn budget is spent. The user can reset it by deleting $ledger, or raise SPAWN_CAP_DENY in the settings.json env block and restart."
		return
	fi
	silent=$((STEP - 1 < DENY - n - 1 ? STEP - 1 : DENY - n - 1))
	next_check=''
	((n + STEP < DENY)) && next_check="next check at #$((n + STEP)), "
	if ((silent > 0)); then
		after="the next $silent spawn$( ((silent == 1)) || echo s) then pass without asking."
	else
		after="spawn #$DENY is then denied."
	fi
	echo "[spawn-cap] Subagent spawn #$n in this session (ask threshold SPAWN_CAP_ASK=$ASK, ${next_check}hard cap SPAWN_CAP_DENY=$DENY). Approve to continue; $after Deny to stop the fan-out. Reset this session's count by deleting $ledger; change the cadence via SPAWN_CAP_ASK / SPAWN_CAP_ASK_STEP in the settings.json env block (restart needed)."
}

main() {
	local EVENT tool session file count bypass=false decision=allow subagent_type
	local -a fields
	EVENT=$(cat)
	tool=$(ev .tool_name)
	[[ $tool == Agent || $tool == Task ]] || return 0
	session=$(ev .session_id)
	if [[ -z $session ]]; then
		hook_log WARN msg 'spawn event without session_id; allowed uncounted' tool "$tool"
		return 0
	fi

	ASK=$(positive_int "${SPAWN_CAP_ASK:-}" 20)
	STEP=$(positive_int "${SPAWN_CAP_ASK_STEP:-}" 10)
	DENY=$(positive_int "${SPAWN_CAP_DENY:-}" 60)
	if ((DENY < ASK)); then
		DENY=$ASK
		hook_log WARN msg 'SPAWN_CAP_DENY below SPAWN_CAP_ASK; clamped' ask:json "$ASK" deny:json "$DENY"
	fi
	file=$(session_file "$session")
	count=$(($([[ -f $file ]] && wc -l <"$file" || echo 0) + 1))
	[[ ${SPAWN_CAP_ALLOW:-} == true ]] && bypass=true
	subagent_type=$(ev '.tool_input.subagent_type | strings')
	fields=(count:json "$count" ask:json "$ASK" step:json "$STEP" deny:json "$DENY"
		subagent_type "$subagent_type" agent_id "$(ev .agent_id)" agent_type "$(ev .agent_type)"
		tool "$tool" session_id "$session" cwd "$(ev .cwd)" permission_mode "$(ev .permission_mode)")

	if [[ $bypass == false ]] && ((count >= DENY)); then
		decision=deny
	elif [[ $bypass == false ]] && ((count >= ASK && (count - ASK) % STEP == 0)); then
		decision=ask
	fi

	if [[ $decision != deny ]]; then
		mkdir -p "$STATE_DIR"
		jq -c --arg ts "$(now_iso)" --argjson n "$count" \
			--arg decision "$([[ $bypass == true ]] && echo bypass || echo "$decision")" '
			{ts: $ts, n: $n, decision: $decision, agent_id, agent_type,
			 subagent_type: ((.tool_input.subagent_type | strings) // null),
			 description: ((.tool_input.description | strings | .[:80]) // null)}
			| with_entries(select(.value | . != null and . != "" and . != 0))' <<<"$EVENT" >>"$file"
		prune_stale
	fi

	[[ $bypass == true ]] && hook_log ALLOW_OVERRIDE "${fields[@]}"
	[[ $decision != allow ]] || return 0
	hook_log "$([[ $decision == ask ]] && echo ASK || echo BLOCKED)" id spawn-cap decision "$decision" "${fields[@]}"
	pre_tool_decision "$decision" "${EMOJI[$decision]} $(build_reason "$decision" "$count" "$file")"
}

main
