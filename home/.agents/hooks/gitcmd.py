"""Parse a Bash command string into the git and gh invocations it would run.

A word-level parse, so text that only mentions a command (a grep pattern, a commit message,
a heredoc body) is not mistaken for one, and `git -C <path>` / `cd <path> &&` resolve to the
repo they act on. It guards against accidents, not against deliberate obfuscation.
"""

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

HEREDOC = re.compile(r"(?<!<)<<(-?)[ \t]*(['\"]?)([A-Za-z_]\w*)\2(?=[\s;&|)<>]|$)")
MARK = "\x00{}\x00"
MARK_RE = re.compile(r"\x00(\d+)\x00")
CAT_MARK_RE = re.compile(r"\$\(\s*cat\s+\x00(\d+)\x00\s*\)")
REDIRECT = re.compile(r"\d*(?:>>?|<)[&|]?|&>>?")
ASSIGN = re.compile(r"[A-Za-z_]\w*=")
KEYWORDS = set("if then else elif do while until ! { }".split())
WRAPPERS = set("sudo command env nohup time exec builtin".split())
SHELLS = set("bash sh zsh".split())
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
MAX_DEPTH = 5


@dataclass(frozen=True)
class Call:
    """One invocation: `tool` is 'git' or 'gh', `args` starts at the subcommand."""

    tool: str
    args: list[str]
    cwd: Path

    def git(self, *args: str) -> str:
        """stdout of a read-only git command in this call's repo; '' when it fails."""
        if not self.cwd.is_dir():
            return ""
        result = subprocess.run(
            ["git", *args], cwd=self.cwd, capture_output=True, text=True, check=False
        )
        return result.stdout.strip() if result.returncode == 0 else ""


def calls(cmd: str, cwd: str | Path) -> list[Call]:
    return _calls(cmd, Path(cwd), [], 0)


def _calls(cmd: str, cwd: Path, bodies: list[str], depth: int) -> list[Call]:
    if depth > MAX_DEPTH:
        return []
    text = _lift_heredocs(cmd, bodies)
    found: list[Call] = []
    for words, nested in _split(text):
        for inner in nested:
            found += _calls(inner, cwd, bodies, depth + 1)
        argv = [_restore(w, bodies) for w in _unwrap(words)]
        if not argv:
            continue
        name = Path(argv[0]).name
        if name == "cd" and len(argv) > 1:
            cwd = _resolve(cwd, argv[-1])
        elif name == "eval":
            found += _calls(" ".join(argv[1:]), cwd, bodies, depth + 1)
        elif name in SHELLS and (script := _script(argv)) is not None:
            found += _calls(script, cwd, bodies, depth + 1)
        elif name == "git":
            found.append(_git_call(argv[1:], cwd))
        elif name == "gh":
            found.append(Call("gh", argv[1:], cwd))
    return found


def _lift_heredocs(cmd: str, bodies: list[str]) -> str:
    """Move each heredoc body to `bodies`, leaving a marker word that is never parsed."""
    pos = 0
    while m := HEREDOC.search(cmd, pos):
        eol = cmd.find("\n", m.end())
        tabs = r"\t*" if m[1] else ""
        end = re.compile(rf"^{tabs}{m[3]}[ \t]*$", re.M).search(cmd, eol + 1) if eol >= 0 else None
        if end is None:
            pos = m.end()
            continue
        body = cmd[eol + 1 : end.start()]
        mark = " " + MARK.format(len(bodies))
        bodies.append(body)
        cmd = cmd[: m.start()] + mark + cmd[m.end() : eol] + cmd[end.end() :]
        pos = m.start() + len(mark)
    return cmd


def _restore(word: str, bodies: list[str]) -> str:
    """`$(cat <<EOF...)` becomes the text it prints; a bare heredoc word becomes its body."""
    for pattern in (CAT_MARK_RE, MARK_RE):
        word = pattern.sub(lambda m: bodies[int(m[1])], word)
    return word


def _split(text: str) -> list[tuple[list[str], list[str]]]:  # noqa: PLR0915 - one scanner loop
    """Simple commands as (words, command substitutions found in those words)."""
    out: list[tuple[list[str], list[str]]] = []
    words: list[str] = []
    nested: list[str] = []
    word: str | None = None
    i, n = 0, len(text)

    def end_word() -> None:
        nonlocal word
        if word is not None:
            words.append(word)
            word = None

    def end_command() -> None:
        nonlocal words, nested
        end_word()
        if words or nested:
            out.append((words, nested))
        words, nested = [], []

    def substitution(at: int) -> tuple[str, int]:
        """(raw text, index after) of the `$(...)` or backtick substitution at `at`."""
        if text[at] == "`":
            close = text.find("`", at + 1)
            close = n if close < 0 else close
            nested.append(text[at + 1 : close])
        else:
            close = _closing_paren(text, at + 2)
            nested.append(text[at + 2 : close])
        return text[at : close + 1], close + 1

    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            if text[i + 1] != "\n":
                word = (word or "") + text[i + 1]
            i += 2
        elif c == "'":
            close = text.find("'", i + 1)
            close = n if close < 0 else close
            word = (word or "") + text[i + 1 : close]
            i = close + 1
        elif c == '"':
            word = word or ""
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n and text[i + 1] in '"\\$`\n':
                    word += "" if text[i + 1] == "\n" else text[i + 1]
                    i += 2
                elif text.startswith("$(", i) or text[i] == "`":
                    raw, i = substitution(i)
                    word += raw
                else:
                    word += text[i]
                    i += 1
            i += 1
        elif text.startswith("$(", i) or c == "`":
            raw, i = substitution(i)
            word = (word or "") + raw
        elif c == "#" and word is None:
            eol = text.find("\n", i)
            i = n if eol < 0 else eol
        elif (c == "&" and (text[i - 1 : i] in {">", "<"} or text[i + 1 : i + 2] == ">")) or (
            c == "|" and text[i - 1 : i] == ">"
        ):
            word = (word or "") + c
            i += 1
        elif c in ";&|()\n":
            end_command()
            i += 1
        elif c in " \t\r":
            end_word()
            i += 1
        else:
            word = (word or "") + c
            i += 1
    end_command()
    return out


def _closing_paren(text: str, i: int) -> int:
    depth, quote = 1, ""
    while i < len(text):
        c = text[i]
        if c == "\\" and quote != "'":
            i += 1
        elif quote:
            quote = "" if c == quote else quote
        elif c in "'\"":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(text)


def _unwrap(words: list[str]) -> list[str]:
    """Drop redirections, shell keywords, VAR=x prefixes and wrappers such as sudo."""
    argv: list[str] = []
    skip = False
    for w in words:
        if skip:
            skip = False
        elif REDIRECT.fullmatch(w):
            skip = True
        elif not REDIRECT.match(w):
            argv.append(w)
    while argv:
        if argv[0] in KEYWORDS or ASSIGN.match(argv[0]):
            argv = argv[1:]
        elif argv[0] in WRAPPERS or argv[0] == "timeout":
            duration = 1 if argv[0] == "timeout" else 0
            argv = argv[1:]
            while argv and argv[0].startswith("-"):
                argv = argv[1:]
            argv = argv[duration:]
        else:
            break
    return argv


def _script(argv: list[str]) -> str | None:
    """The script a shell runs: its `-c` string, or a heredoc fed on stdin."""
    for i, a in enumerate(argv[1:-1], 1):
        if re.fullmatch(r"-[a-z]*c[a-z]*", a):
            return argv[i + 1]
    return next((a for a in argv[1:] if "\n" in a), None)


def _resolve(cwd: Path, path: str) -> Path:
    return cwd / Path(path).expanduser()


def _git_call(args: list[str], cwd: Path) -> Call:
    while args and args[0].startswith("-"):
        if args[0] in GIT_VALUE_OPTS and len(args) > 1:
            if args[0] == "-C":
                cwd = _resolve(cwd, args[1])
            args = args[2:]
        else:
            args = args[1:]
    return Call("git", args, cwd)
