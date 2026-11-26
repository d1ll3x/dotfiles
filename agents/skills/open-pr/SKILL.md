---
name: open-pr
description: Open a pull request with `gh pr create`. Use when a task branch is ready for review, or the user asks for a PR.
---

# Open a pull request

Run from the task's worktree. One objective per PR; move anything else to its own branch first.

1. **Ready.** `git status --short` is empty, and the repo's lint and tests pass.
2. **Rebased.** `git fetch origin && git rebase origin/main`, following `~/.agents/docs/git.md` § Rebase. Done when `git log origin/main..HEAD` lists only this task's commits.
3. **Pushed.** `git push -u origin HEAD`; after rebasing an already-pushed branch, `git push --force-with-lease`.
4. **Body.** Write it to a file in the scratchpad. Fill in the repo's `.github/pull_request_template.md`, keeping each section within the limit in its comment; without one, use the `pr` skill. Add `Closes #<n>` when the task has an issue.
5. **Created.** The title is a commit subject for the whole PR, under 72 characters:

   ```sh
   gh pr create --base main --title "<type>(<scope>): <description>" --body-file <file>
   ```

   When `gh pr view --json url,state` already shows an `OPEN` PR, run `gh pr edit --title <title> --body-file <file>` instead. On a `pr-size` warning, tell the user the size and where the PR could split.
6. **Verified.** `gh pr view --json url,title,baseRefName` shows the intended title and base, and `gh pr checks` is read. Fix failing checks with new commits on the same branch.

Done when the user has the PR URL and the state of its checks. The user merges.
