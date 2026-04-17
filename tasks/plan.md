# Task: Assess and Plan

## Input

The team manager provides the issue ID.

## Phase 0 — State Assessment

Before doing any planning, assess the actual current state of the issue to determine where work stands.

### 1. Fetch the issue
Read the issue from the project management system. Understand the requirements and acceptance criteria.

### 2. Check for existing work
- Check if a branch for this issue already exists locally (e.g. `git branch --list "*<issue-id>*"` or check `../worktrees/`).
- Check if a PR is already open on the remote: `gh pr list --search "<issue-id>" --state open`.

### 3. If a PR exists, inspect it further
- Check CI status: `gh pr checks <pr_url>`.
- Look for a prior test report in PR comments: `gh pr view <pr_url> --comments`. Search for `type: test-report`.
- Look for a prior demo-review signal: search comments for `type: demo-review-report`.

### 4. Determine the next task

| Observed state | `next_task` |
|---|---|
| No branch, no PR | `implement-backend`, `implement-frontend`, or `implement-both` — proceed to Phase 1 to build a plan |
| Branch exists, no PR | `implement-backend`, `implement-frontend`, or `implement-both` — proceed to Phase 1 to build a plan, reusing the existing branch |
| PR exists, CI failing | `implement-backend` or `implement-frontend` — fix CI on the existing branch; proceed to Phase 1 |
| PR exists, CI green, no test report | `test` — skip Phase 1, report immediately |
| PR exists, test report `outcome: fail` | `implement-backend` or `implement-frontend` — fix findings on the existing branch; proceed to Phase 1 |
| PR exists, test report `outcome: pass` | `demo-review` — skip Phase 1, report immediately |

If `next_task` is `test` or `demo-review`, skip Phase 1 entirely and go straight to reporting.

---

## Phase 1 — Planning

Only run this phase when `next_task` is an implementation task.

### 1. Mark the issue In Progress
Update the issue status to **In Progress** in the project management system.

### 2. Set up an isolated workspace
If no worktree or branch exists yet, create one:

```bash
# From the repo root
git worktree add ../worktrees/<branch-name> -b <branch-name>
```

If a branch already exists, create a worktree pointing to it:

```bash
git worktree add ../worktrees/<branch-name> <branch-name>
```

All subsequent reads, edits, and commits must happen inside the worktree — never in the main checkout.

### 2. Build the plan
- Read the relevant files and understand existing patterns, conventions, and architecture.
- Identify which files need to be created, modified, or deleted.
- Identify dependencies between changes (what needs to happen first).
- Anticipate edge cases and how the acceptance criteria map to concrete code changes.
- Write out the plan as a brief ordered checklist of implementation steps.

---

## Report

Report back to `team-manager`:

```
type: plan-report
issue_id: <issue ID>
next_task: implement-backend | implement-frontend | implement-both | test | demo-review
branch: <branch name, if applicable>
worktree: <absolute path to worktree, if applicable>
pr_url: <PR URL, if applicable>
plan: |
  <ordered implementation checklist — only when next_task is implement-*>
findings: <prior test findings — only when next_task is implement-* due to a failed test report>
```

Fields that do not apply to the current state should be omitted.
