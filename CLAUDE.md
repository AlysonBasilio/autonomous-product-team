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

## Installation Pipeline Rule

Any change to tasks, roles (personas), or hooks **must** also be reflected in the installation pipeline:

- **`lib/install.js` MANIFEST** — add a new `{ src, dest, mode }` entry for every new file in `tasks/`, `roles/`, `hooks/`, or `config/`
- **`lib/install.js` REQUIRED_SETTINGS** — for every new hook, add its `command` to the appropriate `hooks` event in `REQUIRED_SETTINGS` so it gets wired into `settings.json` on install
- **`README.md`** — update the hook list or agent file list so users know what is installed

Failing to update `lib/install.js` means new files will not be installed when users run `npx @alysonbasilio/autonomous-product-team init` or `update`.

## Two-Copy Rule

All agent files exist in **two locations** that must always be kept in sync:

| Source (git / npm) | Installed copy (runs locally) |
|---|---|
| `hooks/<file>` | `.claude/hooks/<file>` |
| `tasks/<file>` | `.claude/product-team/tasks/<file>` |
| `roles/<file>` | `.claude/skills/<role>/SKILL.md` |

**When editing any of these files, always update both copies.** The source is what gets deployed to users on `npx ... init/update`. The installed copy is what Claude Code executes right now. Editing only one creates a split-brain state where local behavior differs from what is shipped.
