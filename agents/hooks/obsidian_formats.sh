#!/usr/bin/env bash
# PreToolUse(Write|Edit|NotebookEdit|Bash): deny putting files Obsidian can't open
# natively into the vault. Formats: https://obsidian.md/help/file-formats. This hook is
# the single source of truth for the rule; no instruction file restates it.
#
# Bash is best effort: write targets (redirects, tee/touch, curl/wget output, cp/mv/
# install/ln/rsync destinations) are resolved against the session cwd; archives
# (tar, unzip) and scripts that write files are not inspected.
# Dot-paths (.obsidian/, .git/, .gitignore, .trash/) are vault infrastructure and pass.
set -euo pipefail
HOOK='vault-formats'
# shellcheck source=hooklib.sh
source "$(dirname "${BASH_SOURCE[0]}")/hooklib.sh"

SUPPORTED=(
	.md .base .canvas .pdf
	.avif .bmp .gif .jpeg .jpg .png .svg .webp
	.flac .m4a .mp3 .ogg .wav .webm .3gp
	.mkv .mov .mp4 .ogv
)

# suffix NAME: lowercased extension like Path.suffix ('' for none or a dotfile).
suffix() {
	local name=${1##*/}
	name=${name#.}
	[[ $name == *.?* ]] && printf '.%s' "${name##*.}" | tr '[:upper:]' '[:lower:]'
	return 0
}

# unsupported_in_vault CWD PATH
unsupported_in_vault() {
	local abs vault rel ext s
	abs=$(abs_path "$1" "$2")
	vault=$(realpath -m -- "$VAULT")
	[[ $abs == "$vault"/* ]] || return 1
	rel=${abs#"$vault"/}
	[[ /$rel == */.* ]] && return 1
	ext=$(suffix "$abs")
	for s in "${SUPPORTED[@]}"; do [[ $ext == "$s" ]] && return 1; done
	return 0
}

# write_targets CWD WORD...: paths one simple command writes: redirects, tee/touch args,
# curl/wget outputs, and the destination of a copy/move (a directory destination keeps
# source names).
write_targets() {
	local cwd=$1 w cmd dest src i
	local -a args=() rest=() operands=()
	shift
	while (($#)); do
		w=$1
		shift
		if [[ $w =~ ^[0-9]?\>\>?$ ]]; then
			echo "${1:-}"
			(($#)) && shift
		elif [[ $w =~ ^[0-9]?\>\>?(.+)$ ]]; then
			echo "${BASH_REMATCH[1]}"
		else
			args+=("$w")
		fi
	done
	((${#args[@]})) || return 0
	cmd=${args[0]##*/}
	rest=("${args[@]:1}")
	for w in "${rest[@]}"; do [[ $w == -* ]] || operands+=("$w"); done
	case $cmd in
	tee | touch) ((${#operands[@]} == 0)) || printf '%s\n' "${operands[@]}" ;;
	curl | wget)
		for ((i = 0; i + 1 < ${#rest[@]}; i++)); do
			case ${rest[i]} in -o | -O | --output | --output-document) echo "${rest[i + 1]}" ;; esac
		done
		;;
	cp | mv | install | ln | rsync)
		((${#operands[@]} >= 2)) || return 0
		dest=${operands[-1]}
		if [[ $dest == */ || -d $(abs_path "$cwd" "$dest") ]]; then
			for src in "${operands[@]:0:${#operands[@]}-1}"; do echo "${dest%/}/${src##*/}"; done
		else
			echo "$dest"
		fi
		;;
	esac
}

# offending_bash_paths CMD CWD
offending_bash_paths() {
	local seg target
	local -a words
	while IFS= read -r seg; do
		mapfile -t words < <(shell_words "$seg")
		((${#words[@]})) || continue
		while IFS= read -r target; do
			[[ -n $target ]] && unsupported_in_vault "$2" "$target" && echo "$target"
		done < <(write_targets "$2" "${words[@]}")
	done < <(sed -E 's/&&|\|\||[;|&]/\n/g' <<<"$1")
	return 0
}

main() {
	local EVENT tool cwd raw paths
	EVENT=$(cat)
	tool=$(ev .tool_name)
	cwd=$(ev .cwd)
	cwd=${cwd:-$PWD}
	case $tool in
	Write | Edit | NotebookEdit)
		raw=$(ev '.tool_input.file_path // .tool_input.notebook_path')
		paths=''
		[[ -n $raw ]] && unsupported_in_vault "$cwd" "$raw" && paths=$raw
		;;
	Bash) paths=$(offending_bash_paths "$(ev .tool_input.command)" "$cwd") ;;
	*) return 0 ;;
	esac
	[[ -n $paths ]] || return 0

	hook_log BLOCKED tool "$tool" paths:json "$(jq -Rnc '[inputs]' <<<"$paths")" session_id "$(ev .session_id)"
	pre_tool_deny "vault-formats: $(jq -Rnr '[inputs] | join(", ")' <<<"$paths") would put a format Obsidian can't open into the vault ($VAULT). The vault holds only $(printf '%s\n' "${SUPPORTED[@]}" | LC_ALL=C sort | paste -sd' '). Keep this file outside the vault, as is, and link to it from a note by path or URL."
}

main
