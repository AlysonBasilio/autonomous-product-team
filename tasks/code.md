---
model: openai/gpt-5.5
timeout_s: 5400
inputs:
  required: [issue_id, issue_title, issue_description]
  optional: [branch, pr_url, findings, user_feedback]
---

# Task: Code

You are implementing issue **{{ issue_id }}** in the project at `{{ project_url }}`.

{{#branch}}
The branch for this work is `{{ . }}`.
{{/branch}}
{{#pr_url}}
A PR is already open at `{{ . }}`. Push to the same branch — do not open a second PR. If `branch` was not supplied above, derive it: `gh pr view {{ . }} --json headRefName --jq '.headRefName'`.
{{/pr_url}}

{{#findings}}
## Findings to address (from a prior test or rebase)

{{ . }}
{{/findings}}
{{#user_feedback}}
## User feedback to address (from a demo-review redirect)

{{ . }}
{{/user_feedback}}
## Issue context

**{{ issue_title }}**

{{ issue_description }}

## Phase 0 — Scope check

Before writing any code, decide whether this issue is too big to deliver as a single PR. An issue is **too big** if it meets any of these:

- Implementation spans ≥3 distinct system layers (e.g., DB schema + service layer + API endpoint + frontend component)
- The work contains 2+ independent sub-deliverables that can each be reviewed, merged, and tested in isolation — partial delivery still provides standalone value
- Estimated to touch ≥6 unrelated files or produce >400 LOC of non-test changes
- The issue description lists multiple major features or capabilities as distinct requirements

If you are **resuming work on an existing branch / open PR** (a `branch` or `pr_url` was supplied above), skip this check and proceed to Phase 1 — splitting is only for fresh starts.

If the issue is too big → do **not** mark it In Progress and do **not** create a branch. Instead, propose 2–4 sub-issues (max 5), ordered so foundational work (data model, API contract) precedes consumer work (UI, integrations); use `depends_on` to encode that. Emit:

```json
{
  "type": "split-needed",
  "issue_id": "<issue ID>",
  "source_issue_id": "<issue ID>",
  "issues": [
    {
      "title": "<sub-issue title>",
      "description": "<what this sub-issue covers and its acceptance criteria>",
      "depends_on": ["<title of another sub-issue in this list that must complete first>"]
    }
  ]
}
```

Omit `depends_on` entirely on sub-issues that have no prerequisites; do not emit `null` or an empty array. After emitting this report, stop — the orchestrator will run `create-issue.md` and return to triage.

Otherwise, continue to Phase 1.

## Phase 1 — Implementation

### 0. Check out the branch
Use `branch` from above (derive from `pr_url` if needed — see top of file). If neither was supplied, derive a branch name from the issue ID (convention: `<issue-id>-<short-description>`).

If it does not yet exist on the remote:
```bash
git fetch origin main
git checkout -b <branch> origin/main
git push -u origin <branch>
```
Otherwise: `git fetch origin && git checkout <branch>`.

### 1. Implement
Write code to satisfy the issue requirements. Follow existing patterns. Do not add features beyond what the issue specifies. Add or update tests where the issue requires them.

### 2. Commit, push, and open the PR
Commit and push. If no PR is open for this branch, open one — reference the issue ID in the title and description. One issue per PR.

### 3. Wait for CI and fix any failures
```bash
gh pr checks <pr_url> --watch
```

If any check fails, inspect logs (`gh run view <run-id> --log-failed` or the PR's checks tab), fix the underlying issue, commit, and push. Repeat until green. Diagnose from CI logs — see Rules about not running locally.

If a failure is unresolvable (infra failure outside your control, or a test requiring a credential CI doesn't have), report `task-failed` with the exact failing check name and a link to the failed run.

### 4. Code review
Ensure the PR is reviewed (automated and/or human). For every unresolved review thread:

1. Decide: fix the code (push an update) or determine no change is needed.
2. Post a reply on the thread stating what you did and why — even when you pushed a fix. The reply is the audit trail; a silently-resolved thread is not acceptable.
3. Mark the conversation as resolved.

See the **GraphQL reference** below for the exact mutations and the final verification query. The verification query must return `0` before proceeding.

### 5. Rebase from main and re-check CI
```bash
git fetch origin main && git rebase origin/main
```
Resolve any conflicts manually (`git add <file> && git rebase --continue`), then `git push --force-with-lease`. If conflicts cannot be resolved (the conflicting change is incompatible with the issue and the correct resolution is unclear), report `task-failed` — do not guess or push unresolved conflict markers.

Pushing re-triggers CI: repeat §3 on the rebased branch. Do not merge a branch that has not been verified against the latest main.

### 6. Identify follow-up issues
Review the diff for any TODO comments added during this implementation. For each, note the title (TODO text) and description (file path + brief context on what is deferred and why). Do not remove the TODOs — they will be tracked as separate issues.

### 7. Report

Once CI is green on the rebased branch and the unresolved-threads query returns `0`, emit the following object — first as a single fenced ```json block posted to the PM issue via the product development management system tool (this is the authoritative completion record; if re-running after findings, this comment supersedes any prior one), and then as your final response, again as a single fenced ```json block and nothing else:

```json
{
  "type": "task-complete",
  "task": "tasks/code.md",
  "issue_id": "<issue ID>",
  "pr_url": "<PR URL>",
  "summary": "<one sentence>",
  "follow_up_issues": [
    { "title": "<TODO text>", "description": "<file path — brief context on what is deferred and why>" }
  ]
}
```

Omit `follow_up_issues` entirely when no TODOs were added; do not emit `null` or `[]`. The PM-comment copy may omit `issue_id`, `summary`, and `follow_up_issues` if your tool integration prefers — only `type`, `task`, and `pr_url` are required there.

If implementation hits an unresolvable blocker, output only:

```json
{
  "type": "task-failed",
  "task": "tasks/code.md",
  "issue_id": "<issue ID>",
  "failure": "<exact failure details — test name, error message, unmet criterion>"
}
```

---

## Definition of Done

- PR is open and references the issue ID
- Branch is rebased on latest `main` and CI is green on the latest commit
- All review threads resolved (GraphQL check returns 0 unresolved)

---

## Rules

- Only work on your assigned issue — do not touch files outside its scope.
- Always read files before editing them.
- **Do not run the test suite, linter, static analysis, or build locally at any point** (implementation, post-CI-failure, or post-rebase). CI runs all of these on every push; diagnose from CI logs and push fixes.
- Do not skip CI or commit hooks.
- Do not merge the PR — merging is handled after QA and demo review. Never merge directly to `main`.
- Always work on the assigned branch; never commit directly to `main`.
- Never use `git push --force` — use `--force-with-lease`.
- Never run destructive commands: `rm -rf /`, `git reset --hard HEAD~N` (discarding committed work), or anything that deletes untracked changes.

---

## GraphQL reference

Get thread node IDs:
```bash
gh api graphql -f query='{ repository(owner: "<owner>", name: "<repo>") { pullRequest(number: <n>) { reviewThreads(first: 100) { nodes { id isResolved comments(first: 1) { nodes { body } } } } } } }'
```

Reply on a thread:
```bash
gh api graphql -f query='mutation { addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: "<thread_node_id>", body: "<reply text>" }) { comment { id } } }'
```

Resolve a thread:
```bash
gh api graphql -f query='mutation { resolveReviewThread(input: { threadId: "<thread_node_id>" }) { thread { isResolved } } }'
```

Verify zero unresolved (must return `0` before reporting):
```bash
gh api graphql -f query='{ repository(owner: "<owner>", name: "<repo>") { pullRequest(number: <n>) { reviewThreads(first: 100) { nodes { isResolved } } } } }' | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length'
```
