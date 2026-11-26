#!/usr/bin/env bash
# PreToolUse(Bash): deny commands whose output would put secret values into Claude's
# context (and so into the Anthropic API). Pattern-based, best effort: it complements
# Read() deny rules and .gitignore, it is not a sandbox.
#
# Rules match per command line (grep -P), first match wins.
set -euo pipefail
# shellcheck source=hooklib.sh
source "$(dirname "${BASH_SOURCE[0]}")/hooklib.sh"

READERS='(cat|bat|less|more|head|tail|grep|rg|ag|sed|awk|yq|jq|base64|xxd|od|hexdump|strings|diff|cp|scp|rsync|tee|curl|wget|nc|code|vim|nvim)'
FILES='(secrets\.ya?ml|talosconfig|kubeconfig|\.kube/config|talos/(controlplane|worker)\.ya?ml|talos/rendered/|\.ssh/id_|\.env\b|\.pem\b|\.key\b|gh/hosts\.yml|\.docker/config\.json|\.aws/credentials|\.netrc|\.git-credentials|age\.key|\.sops)'

# reason|PCRE
RULES=(
	# 1. Reading/copying secret files from the shell
	"reads a secret file|(^|[^A-Za-z0-9_./-])${READERS}\b[^|;&]*${FILES}"
	"redirects a secret file into a command|<\s*[^|;&]*${FILES}"
	# 2. Secret managers printing values
	'fnox would print a secret value|\bfnox\s+(get|export|show|reveal)\b'
	'fnox would list secret values|\bfnox\s+(list|ls)\b[^|;&]*(--values|-V\b|--show)'
	'bws would print secret values|\bbws\s+(secret|secrets)\b'
	'secret manager would print a value|\b(op\s+(read|item|inject)|bw\s+get|pass\s+show|security\s+find-generic-password|secret-tool\s+lookup)\b'
	# 3. Dumping an environment that fnox/mise populated with secrets
	'dumps or opens a shell over the fnox-injected environment|\bfnox\s+exec\b.*\s--\s+(env|printenv|set|export|declare|sh|bash|zsh|fish)\b'
	'dumps the environment|(^|[;&|]\s*)(env|printenv|export -p|declare -x|set)\s*($|[|;&>])'
	'reads a process environment|/proc/\S*/environ'
	'echoes a secret variable|\becho\b[^|;&]*\$\{?(MACHINE_|CLUSTER_|BWS_|GITHUB_|GH_TOKEN|.*(TOKEN|SECRET|PASSWORD|_KEY)\b)'
	# 4. Rendering secret-bearing templates to stdout (minijinja: see minijinja_reason)
	'talosctl gen would print secrets to stdout|\btalosctl\s+gen\s+(secrets|config)\b[^|;&]*(-o|--output)\s*-(\s|$)'
	# 5. Cluster APIs that return secret material
	'talosctl resource contains secrets|\btalosctl\b[^|;&]*\b(get|g)\s+[^|;&]*(machineconfig|\bmc\b|secret|certificate|\bcert)'
	'talosctl read of a secret-bearing node file|\btalosctl\b[^|;&]*\b(read|cat)\b[^|;&]*(/system/state|config\.yaml|/etc/kubernetes|/var/lib)'
	'talosctl would print a kubeconfig|\btalosctl\b[^|;&]*\bkubeconfig\s+-(\s|$)'
	'talosctl would print talosconfig credentials|\btalosctl\b[^|;&]*\bconfig\s+(view|export)\b'
	'kubectl would print Secret data|\bkubectl\b[^|;&]*\bget\s+(secret|secrets|sec)\b[^|;&]*(-o|--output)'
	'kubectl would print Secret data|\bkubectl\b[^|;&]*\bget\b[^|;&]*(secret|secrets)/[^|;&]*(-o|--output)'
	'kubectl would decode Secret data|\bkubectl\b[^|;&]*\b(view-secret|ksd)\b'
	'kubectl would print raw kubeconfig credentials|\bkubectl\b[^|;&]*\bconfig\s+view\b[^|;&]*--raw'
	'helm release values/manifests may contain secrets|\bhelm\b[^|;&]*\bget\s+(values|all|manifest)\b'
)
RENDER_ADVICE='render via a just recipe that writes to a file and filters stderr'

# minijinja_reason CMD: minijinja with --env is fine piped/redirected, but it also dumps
# every ENV value to stderr on error, so stderr must be redirected too.
minijinja_reason() {
	grep -qP -- '\bminijinja-cli\b[^|;&]*--env' <<<"$1" || return 0
	if ! grep -qP -- '\bminijinja-cli\b[^;&]*(\||[^2]>|-o\s)' <<<"$1"; then
		echo "renders a template with secrets to stdout; $RENDER_ADVICE"
	elif ! grep -qP -- '\bminijinja-cli\b[^;&|]*2>' <<<"$1"; then
		echo "minijinja error output dumps ENV values; $RENDER_ADVICE"
	fi
}

# check CMD: reason to deny, or nothing.
check() {
	local rule reason regex
	reason=$(minijinja_reason "$1")
	if [[ -n $reason ]]; then
		echo "$reason"
		return
	fi
	for rule in "${RULES[@]}"; do
		IFS='|' read -r reason regex <<<"$rule"
		if grep -qP -- "$regex" <<<"$1"; then
			echo "$reason"
			return
		fi
	done
}

main() {
	local EVENT reason
	EVENT=$(cat)
	reason=$(check "$(ev .tool_input.command)")
	[[ -n $reason ]] || return 0
	pre_tool_deny "block-leaks: $reason. Run it yourself in a separate terminal (not with !), or redirect output to a file that is gitignored and Read-denied."
}

main
