---
model: google/gemini-3.1-flash-lite-preview
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

If **either** check finds unresolved threads or unaddressed comments: do NOT proceed to user presentation. Post a demo-review-complete comment, then output your final response as a single fenced ```json code block — and nothing else — containing this object, and stop here:

```json
{
  "type": "demo-review-report",
  "outcome": "redirect",
  "issue_id": "<issue ID>",
  "pr_url": "<PR URL>",
  "user_feedback": "<summary of the unresolved threads or unaddressed comments blocking presentation>"
}
```

If both checks are clear: continue to the next step.

### 4. Report to the orchestrator — MANDATORY

Post this report and **end your session immediately** — your job is done here. Output your final response as a single fenced ```json code block — and nothing else — containing this object:

```json
{
  "type": "demo-review-pending",
  "issue_id": "<issue ID>",
  "issue_title": "<issue title>",
  "pr_url": "<PR URL>",
  "summary": "<one sentence: what was built>"
}
```

The orchestrator process receives this report, presents the approval gate to the user in its web UI, and dispatches the next task based on the user's response. You do not wait — exit as soon as the report is sent.

Do NOT call `AskUserQuestion`. Do NOT post any additional comments. Do NOT wait for a reply.

## Definition of Done

Report sent. Session complete.

## Rules

- NEVER call `AskUserQuestion` — approval is handled by the orchestrator UI.
- NEVER merge the PR yourself — the user owns the merge action.
- NEVER mark the issue as Done — plan.md detects the merge on the next planning cycle and marks it Done then.
