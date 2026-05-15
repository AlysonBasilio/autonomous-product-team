---
model: google/gemini-3.1-flash-lite-preview
inputs:
  required: [issue_id, issue_title, pr_url]
  optional: []
---

# Task: Demo Review

Customer touchpoint for PR **{{ pr_url }}** (issue **{{ issue_id }}** in `{{ project_url }}`). Reached only after the tester passes. On approval, the orchestrator notifies the user the PR is ready to merge — the user owns the merge.

## Workflow

### 1. Fetch PR

Fetch the PR title/body — you'll need them to write the `summary` field in step 4.

### 2. Check for blocking feedback

**2a. Unresolved review threads:**

```bash
gh api graphql -f query='{ repository(owner: "<owner>", name: "<repo>") { pullRequest(number: <n>) { reviewThreads(first: 100) { nodes { isResolved comments(first: 1) { nodes { body } } } } } } }' | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)]'
```

**2b. Regular PR comments** — use GraphQL (the REST endpoint omits minimization state). You MUST pipe through `jq` with the `isMinimized == false` filter so minimized comments are dropped before you read the output:

```bash
gh api graphql -f query='{ repository(owner: "<owner>", name: "<repo>") { pullRequest(number: <n>) { comments(first: 100) { nodes { databaseId author { login } body createdAt isMinimized } } } } }' | jq '[.data.repository.pullRequest.comments.nodes[] | select(.isMinimized == false) | {id: .databaseId, user: .author.login, body, created_at: .createdAt}]'
```

A minimized comment (`isMinimized: true`, e.g. `minimizedReason: "outdated"`) is by definition resolved. **Never treat a minimized comment as blocking, even if its body still describes failures or concerns.**

Among the remaining (non-minimized) comments, treat any that request changes, raise concerns, or ask unaddressed questions as blocking.

### 3. If blocking: redirect

Post a comment on issue `{{ issue_id }}` via the product development management system tool noting that demo review was blocked, the PR URL, and a one-line summary of the blocking items.

Then output ONLY this fenced ```json block and stop:

```json
{
  "type": "demo-review-report",
  "outcome": "redirect",
  "issue_id": "{{ issue_id }}",
  "pr_url": "{{ pr_url }}",
  "user_feedback": "<summary of blocking items>"
}
```

### 4. If clear: report to orchestrator

Post a comment on issue `{{ issue_id }}` via the product development management system tool noting that demo review is ready for approval, the PR URL, and the one-sentence summary of what was built.

Then output ONLY this fenced ```json block and exit — the orchestrator handles the approval UI:

```json
{
  "type": "demo-review-pending",
  "issue_id": "{{ issue_id }}",
  "issue_title": "{{ issue_title }}",
  "pr_url": "{{ pr_url }}",
  "summary": "<one sentence: what was built>"
}
```

## Rules

- NEVER call `AskUserQuestion` — approval is handled by the orchestrator UI.
- NEVER post comments on the PR — report outcomes via the JSON block only.
- NEVER merge the PR — the user owns the merge.
- NEVER mark the issue Done — issue-triage detects the merge next cycle.
