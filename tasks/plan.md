---
model: anthropic/claude-opus-4.7
timeout_s: 1200
inputs:
  required: [issue_id]
  optional: [pr_url, user_feedback, test_outcome, findings]
---

# Task: Assess and Plan

You are planning issue **{{ issue_id }}** in the project at `{{ project_url }}`.

## Phase 0 — State Assessment

Before doing any planning, assess the actual current state of the issue to determine where work stands.

### 1. Fetch the issue
Read issue `{{ issue_id }}` from the product development management system. Understand the requirements and acceptance criteria. Note the issue's last-updated timestamp for use in the stale-implementation check below.

### 2. Read PM issue task history
Read all comments on the PM issue using the product development management system tool. Collect the most recent comment of each of these types:

- `type: task-complete` — implementation was completed; note the `pr_url` and timestamp
- `type: test-complete` — a test run completed; note the `outcome`, `findings`, and timestamp
- `type: demo-review-complete` — a demo review completed; note the `outcome`, `user_feedback`, and timestamp

**Multi-PR tracking**: An issue may have multiple associated PRs. Collect the `pr_url` values from ALL `task-complete` comments (not just the most recent one) to build the complete set of associated PRs for the issue.

**Stale-implementation check**: Flag the implementation as **stale** if the issue was edited after the most recent `test-complete: pass` timestamp.

### 3. Check git/PR state
- Check for an existing local branch: `git branch --list "*{{ issue_id }}*"`.
- Check for an open PR on the remote: `gh pr list --search "{{ issue_id }}" --state open`.
- For each associated PR in the multi-PR set (from Step 2), check its state: `gh pr view <pr_url> --json state`. All associated PRs must be merged or closed for the issue to be fully complete.
- **If a PR is open**, also collect:
  - CI status: `gh pr checks <pr_url>`
  - Merge conflicts: `gh pr view <pr_url> --json mergeable,mergeStateStatus` — flag if `mergeable` is `CONFLICTING` or `mergeStateStatus` is `DIRTY`
  - Unresolved review threads (count + bodies): `gh api graphql -f query='{ repository(owner:"OWNER",name:"REPO"){ pullRequest(number:NUMBER){ reviewThreads(first:100){ nodes{ isResolved comments(first:1){nodes{body}} }}}}}' | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)]'`

### 4. Determine the next task

Two early checks fire only in specific conditions; otherwise fall through to the routing table.

- **Test-blocked.** If the most recent `test-complete` comment has `outcome: blocked`, emit a `blocked` report (see Report section) — the test infra needs human attention.
- **Discovery.** If the issue is exploratory (no concrete acceptance criteria; the deliverable is findings/follow-up issues rather than working software), emit a plan-report with `next_task: "discovery"` and skip Phase 1. Technical complexity alone does **not** qualify.

Otherwise, use the most recent comment of each type from Step 2, combined with git/PR state. Evaluate rows top to bottom and stop at the first match.

**Override**: if a row below routes to `test` or `demo-review` but the PR has **unresolved review threads**, flip to `code` and pass the thread bodies as `findings` (resolve review threads first).

| PM issue comment history | Git/PR state | `next_task` |
|---|---|---|
| `demo-review-complete outcome: approved` | All associated PRs merged or closed | Mark issue Done — emit `next_task: "triage"` so the loop picks the next issue |
| `demo-review-complete outcome: approved` for most-recent reviewed PR | That PR is now merged, but other associated PRs still open | `test` or `demo-review` — route to the next open PR (check its CI/review state to decide); include the open PR's `pr_url` in the report |
| `demo-review-complete outcome: approved` | PR reviewed is still open (user has not merged yet) | Nothing to do — awaiting user merge; emit `next_task: "triage"` |
| `demo-review-complete outcome: redirect`, no newer `task-complete` | any | `code` — user redirected; run Phase 1 with `user_feedback` as `findings` |
| `demo-review-complete outcome: redirect`, newer `task-complete` exists | PR open, CI green | `test` — implementation was updated after redirect; skip Phase 1 |
| `test-complete outcome: pass`, not stale | PR open, CI green | `demo-review` — skip Phase 1 |
| `test-complete outcome: pass`, **stale** | PR open | `code` — issue updated since test; re-plan in Phase 1 |
| `test-complete outcome: fail` | PR open | `code` — fix findings on the existing branch; run Phase 1 with `findings` |
| `task-complete` exists | PR open, **merge conflicts** | `code` — rebase and resolve conflicts; run Phase 1 with merge conflict details as `findings` |
| `task-complete` exists | PR open, CI green | `test` — skip Phase 1 |
| `task-complete` exists | No open PR, or PR CI failing | `code` — lost artifact or broken CI; re-plan in Phase 1 |
| No `task-complete` | Branch exists, no PR | `code` — proceed to Phase 1, reusing the existing branch |
| No `task-complete` | No branch, no PR | `code` — proceed to Phase 1 |

---

When routing to `code`, populate `findings` in the plan-report:
- From `test-complete` findings when re-running after a test failure
- From `demo-review-complete user_feedback` when re-running after a redirect

If `next_task` is `test` or `demo-review`, skip Phase 1 entirely and go straight to reporting.

---

## Phase 1 — Planning

Only run this phase when `next_task` is `code`.

### 1. Scope Assessment

Read the issue description and acceptance criteria. Skim the key areas of the codebase that would be touched. Evaluate whether this issue is too big for a single PR.

**An issue is too big for a single PR if it meets any of these:**
- Implementation spans ≥3 distinct system layers (e.g., DB schema + service layer + API endpoint + frontend component)
- The work contains 2+ independent sub-deliverables that can each be reviewed, merged, and tested in isolation — partial delivery still provides standalone value
- Estimated to touch ≥6 unrelated files or produce >400 LOC of non-test changes
- The issue description lists multiple major features or capabilities as distinct requirements

If the issue is too big → skip steps 2–4 and output a plan-report with `next_task: "create-issue"` and `split_context: true` (see Report section). Do **not** mark the issue In Progress and do **not** create a branch.

**Splitting guidelines:** Aim for 2–4 sub-issues (max 5). Order them so foundational work (data model, API contract) precedes consumer work (UI, integrations); use `depends_on` to encode that.

### 2. Mark the issue In Progress
Update the issue status to **In Progress** in the product development management system.

### 3. Determine the branch name

- If a branch already exists (found via `git branch --list "*{{ issue_id }}*"` or the open-PR check above), record its name.
- If no branch exists yet, derive a name following the convention `<issue-id>-<short-description>` (e.g. `eng-42-add-login-page`). Do not create or push it — branch creation is handled by the code task.

Include the branch name in the report.

### 4. Build the plan

Read the relevant source files to understand existing patterns, conventions, and architecture. Identify production files to create/modify/delete and their dependencies. For every production file you plan to modify, find all test files that exercise the affected code.

Then write an ordered checklist of concrete, issue-specific steps. Each step must map directly to a requirement or acceptance criterion. The spec-update step must enumerate every spec file by path — if the list is long, group by change needed rather than omitting files.

**Do not include steps that run tests, linters, type checks, or builds locally** — CI handles all of those on push. End the plan at "commit and push".

---

## Report

Your entire output must be exactly one fenced ` ```json ` code block — no prose, analysis, or explanation before or after it. The orchestrator parses fenced JSON blocks only.

**When the test-blocked check (4a) fired**, output a `blocked` report. The orchestrator will surface this as an escalation banner asking the user to verify the change manually.

```json
{
  "type": "blocked",
  "issue_id": "<issue ID>",
  "pr_url": "<PR URL>",
  "what_is_blocked": "<one sentence: what blocked the test run and what was tried>"
}
```

**When the issue is too big for a single PR** (Phase 1 splitting), output a `plan-report` with `next_task: "create-issue"` and `split_context: true`:

```json
{
  "type": "plan-report",
  "issue_id": "<issue ID>",
  "next_task": "create-issue",
  "source_issue_id": "<issue ID>",
  "split_context": true,
  "return_to": "triage",
  "issues": [
    {
      "title": "<sub-issue title>",
      "description": "<what this sub-issue covers and its acceptance criteria>",
      "depends_on": ["<title of another sub-issue in this list that must complete first>"]
    }
  ]
}
```

Omit `depends_on` entirely on sub-issues that have no prerequisites; do not emit `null` or an empty array.

**Otherwise** (normal path), output a `plan-report`:

```json
{
  "type": "plan-report",
  "issue_id": "<issue ID>",
  "next_task": "code",
  "branch": "<branch name>",
  "pr_url": "<PR URL>",
  "issue_title": "<issue title>",
  "issue_description": "<full issue description / acceptance criteria>",
  "plan": "<ordered implementation checklist as a single string with newlines>",
  "findings": "<context for the implementer — test findings on failure, or user_feedback on demo-review redirect>"
}
```

`next_task` must be one of `"discovery"`, `"code"`, `"test"`, `"demo-review"`, `"create-issue"`, or `"triage"`. Fields that do not apply to the current state must be omitted entirely (no `null`, no empty strings). `plan` and `findings` apply only when `next_task` is `"code"`. `issue_title` and `issue_description` apply when `next_task` is `"code"`, `"test"`, or `"demo-review"`. When the routing table says to kick back to the loop (issue Done, or awaiting user merge), emit `next_task: "triage"`.