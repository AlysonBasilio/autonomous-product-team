---
model: claude-haiku-4-5
---

# Task: Demo Review

Customer collaboration touchpoint. Only reached after the tester passes. On approval, this task notifies the user the PR is ready to merge — the user owns the merge action.

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

### 4. Present to the user — MANDATORY

You MUST call `AskUserQuestion` before recording any approval. There is no shortcut.

CI passing, tests passing, and QA state are NOT approval. Only an explicit user response to `AskUserQuestion` counts as approval. Do not infer approval from any other signal.

Use `AskUserQuestion` to present:
- The issue title and what it was supposed to do
- One-sentence summary of what was built
- The PR link
- Question: "Does this meet your expectations? Any feedback or direction changes before you merge?"

Wait for the user's response before proceeding. Do not skip this step under any circumstances.

### 5. Act on the response

If the user's response mentions creating issues, tracking follow-ups, or requests that new work be recorded (e.g., "create an issue for X", "track this as a follow-up", "make a ticket for Y"): extract each request as a follow-up issue with a title and description derived from the user's wording.

**Approved** → before notifying the user, check that the PR has no merge conflicts:

```bash
gh pr view <pr_url> --json mergeable,mergeStateStatus
```

If `mergeable` is `CONFLICTING` or `mergeStateStatus` is `DIRTY`, do **not** proceed. Post a `demo-review-complete` comment with `outcome: redirect` and `user_feedback: "PR has merge conflicts and cannot be merged. The branch must be rebased onto main and conflicts resolved before merging."`, then report to `team-manager` with the same outcome and user_feedback. Stop here.

If the PR is mergeable, inform the user that their approval has been recorded and the PR is ready to merge whenever they would like. **Do not merge the PR yourself** — the user owns the merge action. Do not mark the issue as Done.

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

Report delivered. If approved, user has been notified the PR is ready to merge. If redirect, no merge has occurred.

## Rules

- NEVER skip calling `AskUserQuestion`. Only a direct user response constitutes approval.
- Record the user's feedback verbatim in the report.
- NEVER merge the PR yourself — the user owns the merge action.
- NEVER mark the issue as Done — plan.md detects the merge on the next planning cycle and marks it Done then.
