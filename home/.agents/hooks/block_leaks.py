#!/usr/bin/env python3
"""PreToolUse(Bash): deny commands whose output would put secret values into
Claude's context (and so into the Anthropic API). Pattern-based, best effort:
it complements Read() deny rules and .gitignore, it is not a sandbox.

Rules match per command line (like grep), first match wins.
"""

import re

from hooklib import pre_tool_decision, read_event

READERS = (
    r"(cat|bat|less|more|head|tail|grep|rg|ag|sed|awk|yq|jq|base64|xxd|od|hexdump|strings"
    r"|diff|cp|scp|rsync|tee|curl|wget|nc|code|vim|nvim)"
)
FILES = (
    r"(secrets\.ya?ml|talosconfig|kubeconfig|\.kube/config|talos/(controlplane|worker)\.ya?ml"
    r"|talos/rendered/|\.ssh/id_|\.env\b|\.pem\b|\.key\b|gh/hosts\.yml|\.docker/config\.json"
    r"|\.aws/credentials|\.netrc|\.git-credentials|age\.key|\.sops)"
)

RULES: list[tuple[str, str]] = [
    # 1. Reading/copying secret files from the shell
    (rf"(^|[^A-Za-z0-9_./-]){READERS}\b[^|;&]*{FILES}", "reads a secret file"),
    (rf"<\s*[^|;&]*{FILES}", "redirects a secret file into a command"),
    # 2. Secret managers printing values
    (r"\bfnox\s+(get|export|show|reveal)\b", "fnox would print a secret value"),
    (r"\bfnox\s+(list|ls)\b[^|;&]*(--values|-V\b|--show)", "fnox would list secret values"),
    (r"\bbws\s+(secret|secrets)\b", "bws would print secret values"),
    (
        r"\b(op\s+(read|item|inject)|bw\s+get|pass\s+show|security\s+find-generic-password"
        r"|secret-tool\s+lookup)\b",
        "secret manager would print a value",
    ),
    # 3. Dumping an environment that fnox/mise populated with secrets
    (
        r"\bfnox\s+exec\b.*\s--\s+(env|printenv|set|export|declare|sh|bash|zsh|fish)\b",
        "dumps or opens a shell over the fnox-injected environment",
    ),
    (r"(^|[;&|]\s*)(env|printenv|export -p|declare -x|set)\s*($|[|;&>])", "dumps the environment"),
    (r"/proc/\S*/environ", "reads a process environment"),
    (
        r"\becho\b[^|;&]*\$\{?(MACHINE_|CLUSTER_|BWS_|GITHUB_|GH_TOKEN|.*(TOKEN|SECRET|PASSWORD|_KEY)\b)",
        "echoes a secret variable",
    ),
    # 4. Rendering secret-bearing templates to stdout (minijinja: see minijinja_reason)
    (
        r"\btalosctl\s+gen\s+(secrets|config)\b[^|;&]*(-o|--output)\s*-(\s|$)",
        "talosctl gen would print secrets to stdout",
    ),
    # 5. Cluster APIs that return secret material
    (
        r"\btalosctl\b[^|;&]*\b(get|g)\s+[^|;&]*(machineconfig|\bmc\b|secret|certificate|\bcert)",
        "talosctl resource contains secrets",
    ),
    (
        r"\btalosctl\b[^|;&]*\b(read|cat)\b[^|;&]*(/system/state|config\.yaml|/etc/kubernetes|/var/lib)",
        "talosctl read of a secret-bearing node file",
    ),
    (r"\btalosctl\b[^|;&]*\bkubeconfig\s+-(\s|$)", "talosctl would print a kubeconfig"),
    (
        r"\btalosctl\b[^|;&]*\bconfig\s+(view|export)\b",
        "talosctl would print talosconfig credentials",
    ),
    (
        r"\bkubectl\b[^|;&]*\bget\s+(secret|secrets|sec)\b[^|;&]*(-o|--output)",
        "kubectl would print Secret data",
    ),
    (
        r"\bkubectl\b[^|;&]*\bget\b[^|;&]*(secret|secrets)/[^|;&]*(-o|--output)",
        "kubectl would print Secret data",
    ),
    (r"\bkubectl\b[^|;&]*\b(view-secret|ksd)\b", "kubectl would decode Secret data"),
    (
        r"\bkubectl\b[^|;&]*\bconfig\s+view\b[^|;&]*--raw",
        "kubectl would print raw kubeconfig credentials",
    ),
    (
        r"\bhelm\b[^|;&]*\bget\s+(values|all|manifest)\b",
        "helm release values/manifests may contain secrets",
    ),
]
COMPILED = [(re.compile(p), reason) for p, reason in RULES]

MINIJINJA_ENV = re.compile(r"\bminijinja-cli\b[^|;&]*--env")
MINIJINJA_REDIRECTED = re.compile(r"\bminijinja-cli\b[^;&]*(\||[^2]>|-o\s)")
MINIJINJA_STDERR = re.compile(r"\bminijinja-cli\b[^;&|]*2>")
RENDER_ADVICE = "render via a just recipe that writes to a file and filters stderr"


def _any_line(regex: re.Pattern[str], cmd: str) -> bool:
    return any(regex.search(line) for line in cmd.splitlines())


def minijinja_reason(cmd: str) -> str | None:
    """minijinja with --env is fine piped/redirected, but it also dumps every ENV
    value to stderr on error, so stderr must be redirected too."""
    if not _any_line(MINIJINJA_ENV, cmd):
        return None
    if not _any_line(MINIJINJA_REDIRECTED, cmd):
        return f"renders a template with secrets to stdout; {RENDER_ADVICE}"
    if not _any_line(MINIJINJA_STDERR, cmd):
        return f"minijinja error output dumps ENV values; {RENDER_ADVICE}"
    return None


def check(cmd: str) -> str | None:
    """Reason to deny cmd, or None."""
    if reason := minijinja_reason(cmd):
        return reason
    return next((reason for regex, reason in COMPILED if _any_line(regex, cmd)), None)


def main() -> None:
    cmd = (read_event().get("tool_input") or {}).get("command") or ""
    if reason := check(cmd):
        pre_tool_decision(
            "deny",
            f"block-leaks: {reason}. Run it yourself in a separate terminal (not with !), "
            "or redirect output to a file that is gitignored and Read-denied.",
        )


if __name__ == "__main__":
    main()
