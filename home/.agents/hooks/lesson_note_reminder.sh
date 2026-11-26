#!/usr/bin/env bash
# Stop: when this session wrote a /teach learning record (`learning-records/*.md`) and no
# lesson recap literature note (tag `lesson`) has been written since, ask Claude once to
# write one, per ~/.agents/docs/notes.md → Lesson recap. A learning record is the
# deterministic sign that something was learned; it fires again only after a newer record.
#
# Bash is best effort: a command counts as writing a record when it names
# `learning-records/<file>.md` together with a redirect or `tee`.
set -euo pipefail
HOOK=lesson-note-reminder
# shellcheck source=hooklib.sh
source "$(dirname "${BASH_SOURCE[0]}")/hooklib.sh"

LITERATURE="$VAULT/110-literature-notes"
STATE="$HOOKS_STATE_DIR/lesson-note-reminder.json"
MAX_TRANSCRIPT_BYTES=$((6 * 1024 * 1024))

# record_writes TRANSCRIPT: epoch seconds of each tool call that writes a learning record.
record_writes() {
	[[ -f $1 ]] || return 0
	tail -c "$MAX_TRANSCRIPT_BYTES" -- "$1" | jq -Rr '
		def record: test("learning-records/[^\\s\"'\'']+\\.md");
		fromjson? | select(type == "object" and .type == "assistant")
		| .timestamp as $ts | (.message.content? // empty)
		| select(type == "array") | .[]
		| select(type == "object" and .type == "tool_use")
		| (.input // {}) as $in
		| select(
			(.name == "Write" or .name == "Edit") and (($in.file_path // "") | record)
			or .name == "Bash" and (($in.command // "") | record and test(">|\\btee\\b")))
		| $ts | sub("\\.[0-9]+"; "") | fromdateiso8601'
}

# recap_written_since EPOCH: a literature note tagged `lesson` modified at or after EPOCH.
recap_written_since() {
	local note
	[[ -d $LITERATURE ]] || return 1
	for note in "$LITERATURE"/*.md; do
		[[ -f $note ]] || continue
		(($(stat -c %Y -- "$note") >= $1)) || continue
		awk 'NR > 1 && /^---/ {exit} {print}' "$note" | grep -qE '^\s+-\s+lesson\s*$' && return 0
	done
	return 1
}

main() {
	local EVENT session stamps count latest seen
	EVENT=$(cat)
	[[ $(ev .stop_hook_active) == true ]] && return 0
	session=$(ev .session_id)
	stamps=$(record_writes "$(ev .transcript_path)")
	[[ -n $stamps ]] || return 0
	count=$(wc -l <<<"$stamps")
	latest=$(sort -n <<<"$stamps" | tail -1)
	recap_written_since "$latest" && return 0

	seen=0
	[[ -f $STATE ]] && seen=$(jq --arg s "$session" '.[$s] // 0' "$STATE")
	((seen < count)) || return 0
	mkdir -p "$(dirname "$STATE")"
	{ [[ -f $STATE ]] && cat "$STATE" || echo '{}'; } |
		jq -c --arg s "$session" --argjson n "$count" '.[$s] = $n' >"$STATE.tmp"
	mv "$STATE.tmp" "$STATE"

	hook_log REMIND session_id "$session" records:json "$count"
	stop_block "lesson-note-reminder: this session wrote a learning record, and no lesson recap has been written since. Write one now: read ~/.agents/docs/notes.md → Lesson recap. If the lesson isn't finished yet, say so in one line and stop."
}

main
