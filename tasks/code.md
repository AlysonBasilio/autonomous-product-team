---
model: claude-opus-4-7
---

# Task: Code

## Input

The team manager provides:
- `issue_id` — the issue to implement
- `branch` — the git branch created during planning (work here, do not create a new branch)
- `worktree` — absolute path to the existing worktree created during planning (work here)
- `plan` — the ordered implementation checklist produced by `tasks/plan.md`
- `findings` (optional) — test findings from a prior failed test; present when this is a re-run to fix QA failures
- `user_feedback` (optional) — verbatim user feedback from a demo-review redirect; present when this is a re-run based on user direction

Do not begin implementation until the first four inputs are present.

## Phase 1 — Implementation

### 1. Implement
Write code to satisfy the issue requirements. Follow existing patterns in the codebase. Do not add features beyond what the issue specifies.

### 2. Test
Run the existing test suite and ensure your changes pass. Add or update tests where the issue requires them.

### 3. Lint and build
Run linting, static analysis, and build steps. Fix any errors before proceeding.

### 4. Create a PR
Push your branch and open a pull request. Reference the issue ID in the PR title and description. Keep PRs focused: one issue per PR.

### 5. Code review
Ensure the PR is reviewed (automated and/or human). For every review comment:
1. Fix the code and push an update, OR reply explaining why no change is needed.
2. Then mark the conversation as resolved using the GitHub CLI:
   ```bash
   gh api graphql -f query='mutation { resolveReviewThread(input: { threadId: "<thread_node_id>" }) { thread { isResolved } } }'
   ```
   Get thread node IDs via:
   ```bash
   gh api graphql -f query='{ repository(owner: "<owner>", name: "<repo>") { pullRequest(number: <n>) { reviewThreads(first: 100) { nodes { id isResolved comments(first: 1) { nodes { body } } } } } } }'
   ```
3. After resolving all threads, verify zero unresolved remain:
   ```bash
   gh api graphql -f query='{ repository(owner: "<owner>", name: "<repo>") { pullRequest(number: <n>) { reviewThreads(first: 100) { nodes { isResolved } } } } }' | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length'
   ```
   This must return `0` before proceeding.

### 6. Rebase from main and verify before merge
Before merging, rebase your branch onto the latest main to catch integration issues early:
```bash
git fetch origin main && git rebase origin/main
```
Then run the full test suite, linting, and build on your rebased branch. If anything fails, fix it before proceeding. Do not merge a branch that has not been verified against the latest main.

### 7. Ensure CI is green
All CI checks must pass before merging.

### 8. Identify follow-up issues

Review the diff for any TODO comments added during this implementation. For each one, note the title (the TODO text) and description (file path and a brief explanation of what is deferred and why). Do not remove the TODO comments — they will be tracked as separate issues.

### 9. Report

Once CI is green, your branch is rebased, and all review threads are resolved (verified via the GraphQL check above — must return `0`):

First, post a comment to the PM issue using the product development management system tool:

```
type: task-complete
task: tasks/code.md
pr_url: <PR URL>
```

This is the authoritative completion record for this task. If re-running after findings, this comment supersedes any prior one.

Then report to `team-manager`:

```
type: task-complete
task: tasks/code.md
issue_id: <issue ID>
pr_url: <PR URL>
summary: <one sentence>
follow_up_issues:  # include only if TODOs were added; omit this field entirely if none
  - title: <TODO text>
    description: <file path — brief context on what is deferred and why>
```

If implementation hits a blocker that cannot be resolved, report:

```
type: task-failed
task: tasks/code.md
issue_id: <issue ID>
failure: <exact failure details — test name, error message, unmet criterion>
```

---

## Definition of Done

Your work is **Done** if and only if:
- PR is open and references the issue ID
- All CI checks pass on the branch
- Branch is rebased on latest `main`
- All GitHub review threads are marked resolved (GraphQL check returns 0 unresolved)
- Tests, linting, and build pass on the branch

---

## Rules

- Only work on your assigned issue — do not touch files outside your scope.
- Always read files before editing them.
- Do not skip CI or commit hooks.
- Do not merge the PR — merging is handled after QA and demo review.
