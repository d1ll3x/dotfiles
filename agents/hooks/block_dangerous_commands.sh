#!/usr/bin/env bash
# Block Dangerous Commands - PreToolUse hook for Bash.
# Blocks dangerous patterns before execution. Logs to ~/.claude/hooks-logs/.
#
# HOOK_SAFETY_LEVEL: critical | high | strict (default high); invalid values fall back.
#   critical - only catastrophic: rm -rf ~, dd to disk, fork bombs
#   high     - + risky: force push main, secrets exposure, git reset --hard
#   strict   - + cautionary: any force push, sudo rm, docker prune
#
# Ask mode (opt-in, per level): HOOK_ASK_CRITICAL / HOOK_ASK_HIGH / HOOK_ASK_STRICT set
# to the literal "true" makes that level prompt the user ("ask") instead of denying.
set -euo pipefail
HOOK=block-dangerous-commands
# shellcheck source=hooklib.sh
source "$(dirname "${BASH_SOURCE[0]}")/hooklib.sh"

declare -A RANK=([critical]=1 [high]=2 [strict]=3)
declare -A EMOJI=([critical]=🚨 [high]=⛔ [strict]=⚠️)
declare -A ASK=([critical]=${HOOK_ASK_CRITICAL:-} [high]=${HOOK_ASK_HIGH:-} [strict]=${HOOK_ASK_STRICT:-})
SAFETY_LEVEL=${HOOK_SAFETY_LEVEL:-high}
[[ -v RANK[$SAFETY_LEVEL] ]] || SAFETY_LEVEL=high

# level|id|reason|PCRE (grep -P, per command line)
RULES=(
	# CRITICAL - catastrophic, unrecoverable
	'critical|rm-home|rm targeting home directory|\brm\s+(-.+\s+)*["'\'']?~/?["'\'']?(\s|$|[;&|])'
	'critical|rm-home-var|rm targeting $HOME|\brm\s+(-.+\s+)*["'\'']?\$HOME["'\'']?(\s|$|[;&|])'
	'critical|rm-home-trailing|rm with trailing ~/ or $HOME|\brm\s+.+\s+["'\'']?(~/?|\$HOME)["'\'']?(\s*$|[;&|])'
	'critical|rm-root|rm targeting root filesystem|\brm\s+(-.+\s+)*/(\*|\s|$|[;&|])'
	'critical|rm-system|rm targeting system directory|\brm\s+(-.+\s+)*/(etc|usr|var|bin|sbin|lib|boot|dev|proc|sys)(/|\s|$)'
	'critical|rm-cwd|rm deleting current directory contents|\brm\s+(-.+\s+)*(\./?|\*|\./\*)(\s|$|[;&|])'
	'critical|dd-disk|dd writing to disk device|\bdd\b.+of=/dev/(sd[a-z]|nvme|hd[a-z]|vd[a-z]|xvd[a-z])'
	'critical|mkfs|mkfs formatting disk|\bmkfs(\.\w+)?\s+/dev/(sd[a-z]|nvme|hd[a-z]|vd[a-z])'
	'critical|fork-bomb|fork bomb detected|:\(\)\s*\{.*:\s*\|\s*:.*&'
	# HIGH - significant risk, data loss, security
	'high|curl-pipe-sh|piping URL to shell (RCE risk)|\b(curl|wget)\b.+\|\s*(ba)?sh\b'
	'high|git-force-main|force push to main/master|\bgit\s+push\b(?!.+--force-with-lease).+(--force|-f)\b.+\b(main|master)\b'
	'high|git-reset-hard|git reset --hard loses uncommitted work|\bgit\s+reset\s+--hard'
	'high|git-clean-f|git clean -f deletes untracked files|\bgit\s+clean\s+(-\w*f|-f)'
	'high|chmod-777|chmod 777 is a security risk|\bchmod\b.+\b777\b'
	'high|docker-vol-rm|docker volume deletion loses data|\bdocker\s+volume\s+(rm|prune)'
	# STRICT - cautionary, context-dependent
	'strict|git-force-any|force push (use --force-with-lease)|\bgit\s+push\b(?!.+--force-with-lease).+(--force|-f)\b'
	'strict|git-checkout-dot|git checkout . discards changes|\bgit\s+checkout\s+\.'
	'strict|sudo-rm|sudo rm has elevated privileges|\bsudo\s+rm\b'
	'strict|docker-prune|docker prune removes images|\bdocker\s+(system|image)\s+prune'
	'strict|crontab-r|removes all cron jobs|\bcrontab\s+-r'
)

main() {
	local EVENT cmd rule level id reason regex decision
	EVENT=$(cat)
	[[ $(ev .tool_name) == Bash ]] || return 0
	cmd=$(ev .tool_input.command)
	for rule in "${RULES[@]}"; do
		IFS='|' read -r level id reason regex <<<"$rule"
		((RANK[$level] <= RANK[$SAFETY_LEVEL])) || continue
		grep -qP -- "$regex" <<<"$cmd" || continue
		decision=deny
		[[ ${ASK[$level]} == true ]] && decision=ask
		hook_log "$([[ $decision == ask ]] && echo ASK || echo BLOCKED)" \
			id "$id" priority "$level" decision "$decision" cmd "$cmd" \
			session_id "$(ev .session_id)" cwd "$(ev .cwd)" permission_mode "$(ev .permission_mode)"
		pre_tool_decision "$decision" "${EMOJI[$level]} [$id] $reason"
		return 0
	done
}

main
