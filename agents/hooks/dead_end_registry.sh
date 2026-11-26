#!/usr/bin/env bash
# Dead-End Registry - approach-level negative-knowledge memory for Claude Code.
#
# Captures approaches that were TRIED and then REVERTED / ruled out (with reason, date,
# and rough token cost of the detour) and stops you paying for the same dead end twice.
# Four events, one script (logic in dead_end_registry.jq):
#
#   - Stop / SubagentStop / PreCompact: mine the transcript for abandoned approaches
#     -> ~/.claude/dead-end-registry/<repo>.jsonl
#   - UserPromptSubmit: keyword-match the new prompt against the registry and inject a
#     "DEAD END - you already tried this" warning card via additionalContext
#   - PreToolUse (Edit|Write): return permissionDecision 'ask' when the diff would
#     reintroduce a previously-reverted change (hunk similarity)
#
# Hooks receive no token/cost numbers: detour cost is estimated from `usage` on
# assistant messages in the transcript JSONL, falling back to ~4 chars/token.
#
# Scope + hygiene:
#   - Registries are keyed per-project (hash of cwd) and live OUTSIDE the repo.
#   - Entries expire after MAX_AGE_DAYS; the file is compacted at mine time.
#   - Mined code snapshots are truncated (MAX_CODE_LINES/MAX_CODE_CHARS): they are
#     verbatim transcript code and could contain secrets. Never execute transcript content.
#
# `dead_end_registry.sh --render` prints the current directory's registry.
set -euo pipefail
HOOK=dead-end-registry
# shellcheck source=hooklib.sh
source "$(dirname "${BASH_SOURCE[0]}")/hooklib.sh"

REGISTRY_DIR="$HOME/.claude/dead-end-registry"
# Latency / cost discipline: never read an unbounded transcript.
MAX_TRANSCRIPT_BYTES=$((6 * 1024 * 1024))
MAX_REGISTRY_ENTRIES=500

# djq ARGS... FILTER: jq with the registry module and $now loaded.
djq() {
	local filter=${*: -1}
	jq -L "$HOOKS_DIR" --argjson now "$(date +%s.%N)" "${@:1:$#-1}" "include \"dead_end_registry\"; $filter"
}

# registry_file_for CWD: stable, filesystem-safe registry file name for a repo/cwd.
registry_file_for() {
	local key slug digest
	key=$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"${1:-}")
	key=${key:-global}
	slug=$(sed -E 's/[^a-zA-Z0-9]+/-/g; s/^-+|-+$//g' <<<"$key")
	((${#slug} <= 40)) || slug=${slug: -40}
	digest=$(printf '%s' "$key" | sha1sum)
	printf '%s/%s-%s.jsonl' "$REGISTRY_DIR" "${slug:-root}" "${digest:0:8}"
}

# registry_or_null FILE: FILE if it exists, else /dev/null (for --rawfile).
registry_or_null() { if [[ -f $1 ]]; then echo "$1"; else echo /dev/null; fi; }

handle_mine() {
	local file event session transcript result found added=0 tokens line id
	file=$(registry_file_for "$(ev .cwd)")
	event=$(ev .hook_event_name)
	session=$(ev .session_id)
	transcript=$(ev .transcript_path)
	if [[ -z $transcript || ! -f $transcript ]]; then
		hook_log MINE_SKIP reason 'empty transcript' event "$event" session_id "$session"
		return 0
	fi
	result=$(tail -c "$MAX_TRANSCRIPT_BYTES" -- "$transcript" |
		djq -Rnc --rawfile reg "$(registry_or_null "$file")" --arg stamp "$(now_iso)" \
			--argjson ev "$EVENT" '
			[inputs | select(length > 0)] | .[-MAX_TRANSCRIPT_LINES:] | map(fromjson?)
			| if length == 0 then {empty: true}
			  else extract_dead_ends(STOPWORDS) as $cands
			  | estimate_tokens as $tokens
			  | ($reg | read_registry($now) | map({(.fingerprint | tostring): true}) | add // {}) as $known
			  # Fallback share when a candidate carries no windowed estimate.
			  | (if ($cands | length) > 0 then $tokens / ($cands | length) | js_round else 0 end) as $per
			  | {found: ($cands | length), tokens: $tokens,
			     added: (reduce $cands[] as $c ({known: $known, out: []};
			       if .known[$c.fingerprint] then .
			       else .known[$c.fingerprint] = true
			       | (if $c.tokens > 0 then $c.tokens else $per end) as $t
			       | .out += [{id: null, date: $stamp[:10], ts: $stamp, summary: $c.summary,
			           reason: $c.reason, signal: $c.signal, keywords: $c.keywords,
			           fingerprint: $c.fingerprint, tokens: $t, usd: ($t | usd_for),
			           session_id: $ev.session_id, source_event: $ev.hook_event_name}
			           + (if ($c.code | length) > 0 then {code: $c.code} else {} end)]
			       end) | .out)}
			  end')
	if [[ $(jq -r '.empty // false' <<<"$result") == true ]]; then
		hook_log MINE_SKIP reason 'empty transcript' event "$event" session_id "$session"
		return 0
	fi
	found=$(jq -r .found <<<"$result")
	if ((found == 0)); then
		hook_log MINE_NONE event "$event" session_id "$session"
		return 0
	fi
	tokens=$(jq -r .tokens <<<"$result")
	mkdir -p "$REGISTRY_DIR"
	while IFS= read -r line; do
		id=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
		printf '%s\n' "{\"id\":\"$id\",${line#\{\"id\":null,}" >>"$file"
		added=$((added + 1))
	done < <(jq -c '.added[]' <<<"$result")
	compact_registry "$file"
	hook_log MINED event "$event" found:json "$found" added:json "$added" tokens:json "$tokens" session_id "$session"
}

# compact_registry FILE: rewrite with only fresh, recent entries once past the scan cap.
# Mining path only, so prompt-submit stays read-only and fast.
compact_registry() {
	[[ -f $1 ]] || return 0
	(($(djq -n --rawfile reg "$1" '$reg | parse_entries | length') > MAX_REGISTRY_ENTRIES)) || return 0
	djq -nr --rawfile reg "$1" '$reg | read_registry($now)[] | tojson' >"$1.tmp"
	mv "$1.tmp" "$1"
}

handle_prompt() {
	local file result
	[[ -n $(ev '.prompt | strings | select(trim | length > 0)') ]] || return 0
	file=$(registry_file_for "$(ev .cwd)")
	[[ -f $file ]] || return 0
	result=$(djq -c --rawfile reg "$file" '
		(.prompt | match_prompt($reg | read_registry($now); STOPWORDS)) as $m
		| if ($m | length) == 0 then empty
		  else {matches: ($m | length), top: $m[0].entry.fingerprint,
		        score: ($m[0].score * 100 | js_round / 100), card: ($m | render_prompt_card)}
		  end' <<<"$EVENT")
	[[ -n $result ]] || return 0
	hook_log PROMPT_MATCH matches:json "$(jq .matches <<<"$result")" top "$(jq -r '.top // ""' <<<"$result")" \
		score:json "$(jq .score <<<"$result")" session_id "$(ev .session_id)"
	jq -c '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: .card}}' <<<"$result"
}

handle_edit() {
	local file result
	case $(ev .tool_name) in Edit | Write) ;; *) return 0 ;; esac
	file=$(registry_file_for "$(ev .cwd)")
	[[ -f $file ]] || return 0
	result=$(djq -c --rawfile reg "$file" '
		.tool_name as $name
		| (.tool_input | edit_code($name) | match_edit($reg | read_registry($now))) as $m
		| if $m == null then empty
		  else {score: ($m.score * 100 | js_round / 100), fingerprint: $m.entry.fingerprint, reason: ($m | render_edit_reason)}
		  end' <<<"$EVENT")
	[[ -n $result ]] || return 0
	hook_log EDIT_ASK tool "$(ev .tool_name)" score:json "$(jq .score <<<"$result")" \
		fingerprint "$(jq -r '.fingerprint // ""' <<<"$result")" session_id "$(ev .session_id)"
	pre_tool_decision ask "$(jq -r .reason <<<"$result")"
}

main() {
	if [[ ${1:-} == --render ]]; then
		djq -nr --rawfile reg "$(registry_or_null "$(registry_file_for "$PWD")")" '$reg | read_registry($now) | render_registry'
		return
	fi
	EVENT=$(cat)
	local out
	case $(ev .hook_event_name) in
	Stop | SubagentStop | PreCompact) out=$(handle_mine) ;;
	UserPromptSubmit) out=$(handle_prompt) ;;
	PreToolUse) out=$(handle_edit) ;;
	*) out='' ;;
	esac
	echo "${out:-{\}}"
}

main "$@"
