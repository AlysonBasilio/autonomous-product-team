# Task: Implement (Backend)

> This task assumes a clear written plan already exists from `plan.md`. Do not begin implementation until the planning phase is complete.

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
Ensure the PR is reviewed (automated and/or human). Address all review comments — either fix the code and push an update, or reply explaining why no change is needed. Do not leave any comment unaddressed.

### 6. Rebase from main and verify before merge
Before merging, rebase your branch onto the latest main to catch integration issues early:
```bash
git fetch origin main && git rebase origin/main
```
Then run the full test suite, linting, and build on your rebased branch. If anything fails, fix it before proceeding. Do not merge a branch that has not been verified against the latest main.

### 7. Ensure CI is green
All CI checks must pass before merging.

### 8. Report

Once CI is green, your branch is rebased, and all review feedback is resolved, report to `team-manager`:

```
type: task-complete
task: tasks/implement-backend.md
issue_id: <issue ID>
pr_url: <PR URL>
summary: <one sentence>
```

If implementation hits a blocker that cannot be resolved, report:

```
type: task-failed
task: tasks/implement-backend.md
issue_id: <issue ID>
failure: <exact failure details — test name, error message, unmet criterion>
```

---

## Definition of Done

Your work is **Done** if and only if:
- PR is open and references the issue ID
- All CI checks pass on the branch
- Branch is rebased on latest `main`
- All code review feedback is resolved
- Tests, linting, and build pass on the branch

---

## Rules

- Only work on your assigned issue — do not touch files outside your scope.
- Always read files before editing them.
- Do not skip CI or commit hooks.
- Do not merge the PR — merging is handled after QA and demo review.
