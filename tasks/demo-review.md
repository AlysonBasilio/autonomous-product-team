# Task: Demo Review

Customer collaboration touchpoint. Only reached after the tester passes. On approval, this task merges the PR.

## Input

You will receive `issue_id` and `pr_url` from the test-report.

## Workflow

### 1. Fetch the issue

Fetch the issue from the product development management system: title, description, acceptance criteria.

### 2. Fetch PR details

Fetch the PR title and description from the PR URL.

### 3. Present to the user

Use `AskUserQuestion` to present:
- The issue title and what it was supposed to do
- One-sentence summary of what was built
- The PR link
- Question: "Does this meet your expectations? Any feedback or direction changes before we merge?"

### 4. Act on the response

**Approved** → merge the PR into `main` (squash merge preferred). Mark the issue as Done in the product development management system.

**Redirect** → do NOT merge. Mark the issue status as **In Progress** in the product development management system.

In both cases, post a comment to the PM issue using the product development management system tool:

```
type: demo-review-complete
pr_url: <PR URL>
outcome: approved | redirect
user_feedback: <verbatim user response>
```

This is the authoritative demo-review completion record. If re-running, this comment supersedes any prior demo-review-complete comment.

Then report to `team-manager`:

```
type: demo-review-report
issue_id: <issue ID>
outcome: approved | redirect
user_feedback: <verbatim user response>
```

## Definition of Done

Report delivered. If approved, PR is merged and issue is marked Done. If redirect, no merge has occurred.

## Rules

- Do not merge until the user explicitly approves.
- Record the user's feedback verbatim in the report.
- If approved, mark the issue as Done in the product development management system before reporting.
