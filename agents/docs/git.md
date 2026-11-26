# Git

- Repo conventions override these.
- New work: `git wt <type>/<name>`; never edit `main/`.
- Atomic commits: one concern each; if the message needs "and", split it.
- Conventional Commits; add a scope only when it tells a reader what changed.
- PRs: one objective. Use the `open-pr` skill.

The `git_conventions` hook denies malformed commit messages, branch names and PR titles, and warns on PRs over 300 changed lines. A repo with its own conventions opts out with a commitlint config or `git config claude.conventions false`. The `git_safety` hook denies force-pushes, pushes to `main`, and commands that discard work.

## Branches

A task branch is one per task, always checked out in its own worktree at `<wt-root>/<prefix>-<slug>`. It is short-lived: it exists from the task's start until I merge its pull request.

### Branch names

[Conventional Branch](https://conventionalbranch.org/): `<prefix>/<slug>`, where the prefix states the branch's purpose:

| Prefix | Purpose |
|---|---|
| `feat/` | new feature |
| `fix/` | bug fix |
| `hotfix/` | urgent fix to what's already deployed |
| `release/` | release preparation; slug is the version (`release/v1.2.0`) |
| `chore/` | everything else: docs, deps, config, refactors, CI |

These are the only five prefixes. Do not use agent-source prefixes such as `claude/` or `ai/`, because the prefix records purpose, not authorship.

`<slug>` is lowercase letters, digits, hyphens between words, and dots for versions (`chore/upgrade-node-v20.11`). It never starts or ends with a hyphen or dot, and never has two of them in a row. When the task has a GitHub issue, the slug starts with it: `feat/issue-42-bgp-peering`. Trunk (`main`) takes no prefix.

`<wt-root>` depends on the repo's layout:

- Bare layout (`<container>/.bare` holds the git data, `<container>/.git` points to it, `main` is checked out at `<container>/main`): `<wt-root>` is `<container>`, so task worktrees sit next to `main/`. Run git commands from `<container>/main`.
- Normal clone: `<wt-root>` is `~/worktrees/<repo>`.

The main checkout stays on `main`; the `require_worktree` hook denies edits there. The `require_pr` hook won't let a session stop while a worktree it edited has committed work without a pull request.

A repo without a GitHub remote has no pull requests: there, hand-off means telling me the rebased branch is ready, and I merge it locally.

### Start a task

1. [Clean up merged branches](#clean-up-merged-branches).
2. `git wt <type>/<name>` from any worktree of the repo. It is `~/.agents/scripts/git-wt`: it fetches, branches from the tip of `origin/main` (local `main` without a remote) and prints the worktree path.
3. `cd` there; edit and commit only under that path.

Done when the worktree exists on the new branch at the tip of `origin/main`.

### Open a pull request

Once the task's done criterion holds and lint and tests are green, use the `open-pr` skill.

### Clean up merged branches

Run `git sweep` from any worktree (`git sweep -n` first for a dry run). It is `~/.agents/scripts/git-sweep`, and it:

1. fetches with prune, then runs `pull --ff-only` in trunk's worktree. It skips the pull when trunk is dirty.
2. for each branch whose `gh pr view <branch> --json state -q .state` is `MERGED`:
   - removes its worktree (a dirty worktree is reported and skipped),
   - runs `git branch -D` (`-D`: squash and rebase merges leave git unaware the branch merged; the `MERGED` state is the proof),
   - deletes the remote branch if GitHub kept it. A merged remote branch with no local branch is deleted too.
3. ends with `git fetch --prune`, `git worktree prune` and a status of worktrees and branches.

Done when no merged task branch or its worktree remains locally or on the remote. Act on any skipped dirty worktree by hand.

Trunk's worktree is pull-only: in bare layouts it has `pull.ff=only` and `rebase.autoStash=false` as worktree config (`extensions.worktreeConfig`, with `core.bare=true` moved into `.bare/config.worktree`). A dirty trunk then makes `pull` fail instead of carrying edits along.

## Commit messages

- Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert.
- Subject: imperative, lowercase, no period, under 72 characters.
- Body only if needed.

## Rebase

`rerere` has `autoupdate` on, so it silently stages past conflict resolutions. After each rebase stop, review `git diff --cached` before `git rebase --continue`.
