# Task: Test

Adversarial QA from the branch, before any merge. You are testing as a user — do not read the implementation code or PR diff.

## Input

You will receive `issue_id` and `pr_url` from the implementation task-complete report.

## Workflow

### 1. Fetch the issue

Fetch the issue from the product development management system to understand the acceptance criteria. Do NOT read the implementation code or PR diff — test blind as a user would.

### 2. Check out the branch

Check out the PR branch locally:

```bash
gh pr checkout <pr_url>
```

### 3. Start the application

Start the application from the branch and confirm it is running.

### 4. Test with three lenses

**Acceptance criteria** — Verify each criterion is demonstrably met from the outside (API calls, UI interaction, observable side effects). Do not verify by reading source code.

**Boundary and error paths** — Test invalid inputs, missing fields, out-of-range values, unauthorized access. Target anything the implementer might have assumed won't happen.

**Regression** — Spot-check adjacent features that share code paths with this change. Confirm they still work.

### 5. Report

First, post a comment to the PM issue using the product development management system tool:

```
type: test-complete
pr_url: <PR URL>
outcome: pass | fail
findings: [{ description, severity: critical | minor }]
```

This is the authoritative test completion record for this issue. If re-running, this comment supersedes any prior test-complete comment.

Then report to `team-manager`:

```
type: test-report
issue_id: <issue ID>
pr_url: <PR URL>
outcome: pass | fail
findings: [{ description, severity: critical | minor }]
```

## Definition of Done

Report delivered. If `outcome: pass`, findings list is empty. If `outcome: fail`, every finding is specific and actionable for the implementer.

## Rules

- Do not read the PR diff or implementation code before testing — test as an external user would.
- Test from the branch, not from main.
- Every finding must include enough detail for the implementer to reproduce and fix it.
