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

**Approved** → merge the PR into `main` (squash merge preferred). Mark the issue as Done in the product development management system. Report:

```
type: demo-review-report
issue_id: <issue ID>
outcome: approved
user_feedback: <verbatim user response>
```

**Redirect** → do NOT merge. Mark the issue status as **In Progress** in the product development management system. Report:

```
type: demo-review-report
issue_id: <issue ID>
outcome: redirect
user_feedback: <verbatim user response>
```

## Definition of Done

Report delivered. If approved, PR is merged and issue is marked Done. If redirect, no merge has occurred.

## Rules

- Do not merge until the user explicitly approves.
- Record the user's feedback verbatim in the report.
- If approved, mark the issue as Done in the product development management system before reporting.
