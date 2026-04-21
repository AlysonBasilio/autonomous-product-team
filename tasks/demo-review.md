---
model: claude-haiku-4-5
---

# Task: Demo Review

Customer collaboration touchpoint. Only reached after the tester passes. On approval, this task merges the PR.

## Input

You will receive `issue_id` and `pr_url` from the test-report.

## Workflow

### 1. Fetch the issue

Fetch the issue from the product development management system: title, description, acceptance criteria.

### 2. Fetch PR details

Fetch the PR title and description from the PR URL.

### 3. Verify all review threads are resolved and check for new comments

Before presenting to the user, run both checks:

**3a. Unresolved review threads:**

```bash
gh api graphql -f query='{ repository(owner: "<owner>", name: "<repo>") { pullRequest(number: <n>) { reviewThreads(first: 100) { nodes { isResolved comments(first: 1) { nodes { body } } } } } } }' | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)]'
```

**3b. Regular PR comments** (issue-style comments at the bottom of the PR):

```bash
gh api /repos/<owner>/<repo>/issues/<n>/comments | jq '[.[] | {id, user: .user.login, body, created_at}]'
```

Read all comments returned. If any comment appears to be requesting changes, raising a concern, or asking a question that has not been addressed — treat it as blocking feedback.

If **either** check finds unresolved threads or unaddressed comments: do NOT proceed to user presentation. Post a demo-review-complete comment and use the `message` tool to message `team-manager` with `outcome: redirect` and `user_feedback` summarising the blocking items. Stop here.

If both checks are clear: continue to the next step.

### 4. Present to the user

Use `AskUserQuestion` to present:
- The issue title and what it was supposed to do
- One-sentence summary of what was built
- The PR link
- Question: "Does this meet your expectations? Any feedback or direction changes before we merge?"

### 5. Act on the response

If the user's response mentions creating issues, tracking follow-ups, or requests that new work be recorded (e.g., "create an issue for X", "track this as a follow-up", "make a ticket for Y"): extract each request as a follow-up issue with a title and description derived from the user's wording.

**Approved** → merge the PR into `main` (squash merge preferred). Mark the issue as Done in the product development management system.

**Redirect** → do NOT merge. Mark the issue status as **In Progress** in the product development management system.

In both cases, post a comment to the PM issue using the product development management system tool:

```
type: demo-review-complete
pr_url: <PR URL>
outcome: approved | redirect
user_feedback: <verbatim user response>
follow_up_issues:  # include only if user requested issue creation; omit this field entirely if none
  - title: <title>
    description: <description>
```

This is the authoritative demo-review completion record. If re-running, this comment supersedes any prior demo-review-complete comment.

Then use the `message` tool to message `team-manager`:

```
type: demo-review-report
issue_id: <issue ID>
outcome: approved | redirect
user_feedback: <verbatim user response>
follow_up_issues:  # include only if user requested issue creation; omit this field entirely if none
  - title: <title>
    description: <description>
```

## Definition of Done

Report delivered. If approved, PR is merged and issue is marked Done. If redirect, no merge has occurred.

## Rules

- Do not merge until the user explicitly approves.
- Record the user's feedback verbatim in the report.
- If approved, mark the issue as Done in the product development management system before reporting.
