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

Use `gh api --jq` (gh ships with embedded jq) so the filter runs inside the tool and minimized / resolved entries never reach your context. Do NOT drop the `--jq` flag — without it the raw output includes minimized comments, and a minimized comment must never be treated as blocking even if its body still describes failures or concerns.

Each projection includes a `url` so blocking items can be cited verbatim in step 3.

**2a. Unresolved review threads:**

```bash
gh api graphql --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | {url: .comments.nodes[0].url, author: .comments.nodes[0].author.login, body: .comments.nodes[0].body}]' -f query='{ repository(owner: "<owner>", name: "<repo>") { pullRequest(number: <n>) { reviewThreads(first: 100) { nodes { isResolved comments(first: 1) { nodes { url author { login } body } } } } } } }'
```

**2b. Regular PR comments** — use GraphQL (the REST endpoint omits minimization state):

```bash
gh api graphql --jq '[.data.repository.pullRequest.comments.nodes[] | select(.isMinimized == false) | {url, user: .author.login, body, created_at: .createdAt}]' -f query='{ repository(owner: "<owner>", name: "<repo>") { pullRequest(number: <n>) { comments(first: 100) { nodes { url author { login } body createdAt isMinimized } } } } }'
```

Among the remaining (non-minimized) comments, treat any that request changes, raise concerns, or ask unaddressed questions as blocking.

### 3. If blocking: redirect

Post a comment on issue `{{ issue_id }}` via the product development management system tool noting that demo review was blocked, the PR URL, and a one-line summary of the blocking items.

Then output ONLY this fenced ```json block and stop. `user_feedback` MUST cite each blocking item by its `url` from the step 2 output (e.g. `- <url>: <short reason>` per line) so the redirect can be audited; do not paraphrase items that have no matching URL in your filter output.

```json
{
  "type": "demo-review-report",
  "outcome": "redirect",
  "issue_id": "{{ issue_id }}",
  "pr_url": "{{ pr_url }}",
  "user_feedback": "<bulleted list, one line per blocking item, each citing its url>"
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
