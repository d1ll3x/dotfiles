#!/usr/bin/env bash
# PreToolUse(Write|Edit|Bash): deny a note in 100-fleeting-notes/ or 110-literature-notes/
# that breaks the shape in ~/.agents/docs/notes.md → "Notes by Claude": the template's
# frontmatter with real values, the folder's tag, and for Claude's own kinds (tags
# `troubleshooting`, `lesson`) their headings and the 600-word limit. A new note also needs
# an H1 equal to its filename, and a new fleeting note the `todo` tag.
#
# Edits to Dylan's existing notes only get the checks that every note there passes.
# Bash is best effort: only `obsidian create path=… content=…` is inspected; scripts
# that write notes are not.
set -euo pipefail
HOOK=obsidian-note-format
# shellcheck source=hooklib.sh
source "$(dirname "${BASH_SOURCE[0]}")/hooklib.sh"

FLEETING=100-fleeting-notes
LITERATURE=110-literature-notes

# Note text on stdin → its problems joined by "; ". Args: $folder, $stem, $is_new ("true"/"false").
PROBLEMS='
def kinds: [["troubleshooting", ["Symptom", "Root cause", "Fix", "Prevention", "Dead ends"]],
            ["lesson", ["What we learned", "Still shaky", "Next"]]];
def frontmatter:
	if startswith("---\n") | not then null
	else (.[4:] | split("\n---")) as $p
	| if ($p | length) < 2 then null
	  else {fm: $p[0], body: ($p[1:] | join("\n---") | if startswith("\n") then .[1:] else . end)} end
	end;
def parse_fm:
	reduce split("\n")[] as $l ({keys: {}, tags: [], cur: null};
		([$l | capture("\\A(?<k>[A-Za-z]+):\\s*(?<v>.*)")] | .[0]) as $kv
		| ([$l | capture("\\A\\s+-\\s+(?<t>.+)")] | .[0]) as $item
		| if $kv then .cur = $kv.k | .keys[$kv.k] = ($kv.v | trim)
		  elif $item and .cur == "Tags" then .tags += [$item.t | trim | ltrimstr("\"") | ltrimstr("'\''") | rtrimstr("\"") | rtrimstr("'\''")]
		  else . end);
($is_new == "true") as $new
| . as $text
| [if ($text | contains("<%")) then "contains Templater code `<% %>`: write real values" else empty end]
+ (($text | frontmatter) as $split
   | if $split == null then ["has no YAML frontmatter"]
     else ($split.fm | parse_fm) as $fm | $split.body as $body
     | ([$body | splits("\\s+") | select(length > 0)] | length) as $words
     | (["Created", "Modified", "Tags"] + (if $folder == "110-literature-notes" then ["Related"] else [] end)) as $req
     | (if $folder == "100-fleeting-notes" then "zettelkasten/fleeting" else "zettelkasten/literature" end) as $ftag
     | [$req[] | select($fm.keys[.] == null) | "frontmatter lacks `\(.)`"]
     + [("Created", "Modified") | select($fm.keys[.] != null and ($fm.keys[.] | test("\\A\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}\\z") | not))
        | "`\(.)` is not `YYYY-MM-DD HH:mm` (use `date '\''+%Y-%m-%d %H:%M'\''`)"]
     + (if ($fm.tags | index([$ftag])) then [] else ["Tags lack `\($ftag)` for \($folder)/"] end)
     + (if $new and $folder == "100-fleeting-notes" and ($fm.tags | index(["todo"]) | not)
        then ["a new fleeting note needs the `todo` tag"] else [] end)
     + (if $new and ([$body | split("\n")[] | capture("\\A# (?<h>.+)\\z")] | .[0].h // null | if . then trim else . end) != $stem
        then ["the H1 must equal the filename: `# \($stem)`"] else [] end)
     + (if $folder == "110-literature-notes" and (("\n" + $body) | contains("\n# References") | not)
        then ["lacks the closing `---` + `# References` section"] else [] end)
     + [kinds[] as [$kind, $hs] | select($fm.tags | index([$kind])) | $hs[] as $h
        | select(("\n" + $body + "\n") | contains("\n## \($h)\n") | not) | "lacks `## \($h)`"]
     + (if $folder == "110-literature-notes" and ($new or ([kinds[][0] as $k | $fm.tags | index([$k])] | any))
              and $words > 600
            then ["is \($words) words; literature notes stay at most 600"] else [] end)
     end)
| join("; ")'

# note_folder ABS: the note folder of a direct .md child of it, else nothing.
note_folder() {
	local vault rel
	vault=$(realpath -m -- "$VAULT")
	[[ $1 == "$vault"/*/*.md ]] || return 0
	rel=${1#"$vault"/}
	[[ $rel == */*/* ]] && return 0
	case ${rel%%/*} in "$FLEETING" | "$LITERATURE") echo "${rel%%/*}" ;; esac
}

# check_note ABS IS_NEW: note text on stdin → "name: problem; problem" or nothing.
check_note() {
	local folder name found
	folder=$(note_folder "$1")
	if [[ -z $folder ]]; then
		cat >/dev/null
		return 0
	fi
	name=${1##*/}
	found=$(jq -Rsr --arg folder "$folder" --arg stem "${name%.*}" --arg is_new "$2" "$PROBLEMS")
	[[ -z $found ]] || printf '%s: %s\n' "$name" "$found"
}

# bash_notes CMD: report lines for `obsidian create path=… content=…` commands.
bash_notes() {
	local seg w path content
	local -a words
	local -A seen
	while IFS= read -r seg; do
		mapfile -t words < <(shell_words "$seg")
		((${#words[@]})) && [[ ${words[0]##*/} == obsidian ]] || continue
		seen=()
		for w in "${words[@]}"; do
			case $w in
			create) seen[create]=1 ;;
			path=*) path=${w#path=} seen[path]=1 ;;
			content=*) content=${w#content=} seen[content]=1 ;;
			esac
		done
		[[ -v seen[create] && -v seen[path] && -v seen[content] ]] || continue
		content=${content//\\n/$'\n'}
		content=${content//\\t/$'\t'}
		printf '%s' "$content" | check_note "$(realpath -m -- "$VAULT/$path")" true
	done < <(sed -E 's/&&|\|\||[;|&]/\n/g' <<<"$1")
}

main() {
	local EVENT tool cwd raw abs report
	EVENT=$(cat)
	tool=$(ev .tool_name)
	cwd=$(ev .cwd)
	case $tool in
	Write | Edit)
		raw=$(ev .tool_input.file_path)
		[[ -n $raw ]] || return 0
		abs=$(abs_path "${cwd:-$PWD}" "$raw")
		if [[ $tool == Write ]]; then
			local new=true
			[[ -e $abs ]] && new=false
			report=$(jq -j '.tool_input.content // ""' <<<"$EVENT" | check_note "$abs" "$new")
		else
			[[ -e $abs ]] || return 0
			report=$(jq -j --rawfile cur "$abs" '
				(.tool_input.old_string // "") as $old | (.tool_input.new_string // "") as $new
				| if $old == "" then $new + $cur
				  elif .tool_input.replace_all then $cur | split($old) | join($new)
				  else ($cur | split($old)) as $p
				  | if ($p | length) < 2 then $cur else $p[0] + $new + ($p[1:] | join($old)) end
				  end' <<<"$EVENT" | check_note "$abs" false)
		fi
		;;
	Bash) report=$(bash_notes "$(ev .tool_input.command)") ;;
	*) return 0 ;;
	esac
	[[ -n $report ]] || return 0

	hook_log BLOCKED tool "$tool" notes:json "$(jq -Rnc '[inputs]' <<<"$report")" session_id "$(ev .session_id)"
	pre_tool_deny "obsidian-note-format: $(jq -Rnr '[inputs] | join(" | ")' <<<"$report"). The shapes are in ~/.agents/docs/notes.md → Notes by Claude; fix the note and write it again."
}

main
