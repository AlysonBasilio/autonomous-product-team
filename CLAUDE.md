# CLAUDE.md — Autonomous Product Team

## Git Merge Policy

`git merge` to the `main` branch is **blocked** by a PreToolUse hook (`guard-git-merge.sh`).

Merges to main must go through a reviewed pull request. Use `gh pr merge` after the PR has passed tests and received user approval.

**Allowed operations:**
- `git merge --abort` — abort an in-progress merge (conflict cleanup)
- `git merge --continue` — continue a merge after resolving conflicts
- `git merge --quit` — quit a merge operation
- Merges between feature branches (not on `main`)

**Blocked:**
- Any `git merge <branch>` command while the current branch is `main`

This policy was introduced in issue #28 after a merge to main occurred without explicit user approval.
