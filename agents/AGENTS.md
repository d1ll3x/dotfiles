# Global Instructions

## Plans

- Extremely concise; sacrifice grammar for concision.
- End with a list of unresolved questions, if any.

## Coding

- Use the Github CLI for interacting with Github
- Python → `uv` for deps, venvs, and running scripts. Tool versions → `mise`.
- Prefer deep modules with shallow interfaces.
- Error handling: fail fast.

## Git

- Commit on the task branch at logical checkpoints, without asking.
- Commits are SSH-signed; a commit may block awaiting my approval or passphrase.
- Before branching, committing, rebasing or merging, read [git.md](~/.agents/docs/git.md).

## Notes

- Placement: what changes with the code, or what an agent needs to do the work, lives in the repo: tasks as GitHub Issues (one milestone per phase), decisions in `docs/adr/`, vocabulary in `GLOSSARY.md`, and `docs/agents/` for how skills use them.
