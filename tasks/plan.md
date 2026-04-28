---
model: claude-sonnet-4-6
---

# Task: Assess and Plan

## Input

The team lead provides the issue ID.

## Phase 0 — State Assessment

Before doing any planning, assess the actual current state of the issue to determine where work stands.

### 1. Fetch the issue
Read the issue from the product development management system. Understand the requirements and acceptance criteria. Note the issue's last-updated timestamp for use in the stale-implementation check below.

### 2. Read PM issue task history
Read all comments on the PM issue using the product development management system tool. Collect the most recent comment of each of these types:

- `type: task-complete` — implementation was completed; note the `pr_url` and timestamp
- `type: test-complete` — a test run completed; note the `outcome`, `findings`, and timestamp
- `type: demo-review-complete` — a demo review completed; note the `outcome`, `user_feedback`, and timestamp

**Multi-PR tracking**: An issue may have multiple associated PRs. Collect the `pr_url` values from ALL `task-complete` comments (not just the most recent one) to build the complete set of associated PRs for the issue.

**Stale-implementation check**: If a `test-complete` comment with `outcome: pass` exists, compare its timestamp against the issue's last-updated timestamp. If the issue description or acceptance criteria appear to have been edited after the `test-complete` was posted, flag the implementation as **stale**.

### 3. Check git/PR state
- Check if a branch for this issue already exists locally (e.g. `git branch --list "*<issue-id>*"` or check `../worktrees/`).
- Check if a PR is already open on the remote: `gh pr list --search "<issue-id>" --state open`.
- For each associated PR in the multi-PR set (from Step 2), check its state individually: `gh pr view <pr_url> --json state` to determine if it is open, merged, or closed. Build a summary: count how many are merged/closed vs. still open. All associated PRs must be merged or closed for the issue to be considered fully complete.
- If a PR exists and is open, check CI status: `gh pr checks <pr_url>`.
- If a PR exists and is open, check for merge conflicts:

```bash
gh pr view <pr_url> --json mergeable,mergeStateStatus
```

Note whether `mergeable` is `CONFLICTING` (or `mergeStateStatus` is `DIRTY`) — used in the routing table below.

- If a PR exists and is open, count unresolved review threads and collect their bodies:

```bash
gh api graphql -f query='{
  repository(owner: "OWNER", name: "REPO") {
    pullRequest(number: NUMBER) {
      reviewThreads(first: 100) {
        nodes {
          isResolved
          comments(first: 1) { nodes { body } }
        }
      }
    }
  }
}' | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)]'
```

Note the count and the body of each unresolved thread — used in the routing table below.

### 4. Determine the next task

Use the most recent comment of each type from Step 2, combined with git/PR state. Evaluate rows top to bottom and stop at the first match:

| PM issue comment history | Git/PR state | `next_task` |
|---|---|---|
| `demo-review-complete outcome: approved` | All associated PRs merged or closed | Mark issue Done + clean up worktree (see **Worktree Cleanup** below) — report immediately with no `next_task` |
| `demo-review-complete outcome: approved` for most-recent reviewed PR | That PR is now merged, but other associated PRs still open | `test` or `demo-review` — route to the next open PR (check its CI/review state to decide); include the open PR's `pr_url` in the report |
| `demo-review-complete outcome: approved` | PR reviewed is still open (user has not merged yet) | Nothing to do — awaiting user merge; report immediately with no `next_task` |
| `demo-review-complete outcome: redirect`, no newer `task-complete` | any | `code` — user redirected; run Phase 1 with `user_feedback` as `findings` |
| `demo-review-complete outcome: redirect`, newer `task-complete` exists | PR open, CI green, **unresolved review threads** | `code` — resolve review threads first; run Phase 1 with thread bodies as `findings` |
| `demo-review-complete outcome: redirect`, newer `task-complete` exists | PR open, CI green | `test` — implementation was updated after redirect; skip Phase 1 |
| `test-complete outcome: pass`, not stale | PR open, CI green, **unresolved review threads** | `code` — resolve review threads first; run Phase 1 with thread bodies as `findings` |
| `test-complete outcome: pass`, not stale | PR open, CI green | `demo-review` — skip Phase 1 |
| `test-complete outcome: pass`, **stale** | PR open | `code` — issue updated since test; re-plan in Phase 1 |
| `test-complete outcome: fail` | PR open | `code` — fix findings on the existing branch; run Phase 1 with `findings` |
| `task-complete` exists | PR open, **merge conflicts** | `code` — rebase and resolve conflicts; run Phase 1 with merge conflict details as `findings` |
| `task-complete` exists | PR open, CI green, **unresolved review threads** | `code` — resolve review threads first; run Phase 1 with thread bodies as `findings` |
| `task-complete` exists | PR open, CI green | `test` — skip Phase 1 |
| `task-complete` exists | No open PR, or PR CI failing | `code` — lost artifact or broken CI; re-plan in Phase 1 |
| No `task-complete` | Branch exists, no PR | `code` — proceed to Phase 1, reusing the existing branch |
| No `task-complete` | No branch, no PR | `code` — proceed to Phase 1 |

### Worktree Cleanup

When the routing table directs you to **mark the issue Done**, also clean up the local worktree for the merged PR's branch:

```bash
BRANCH=$(gh pr view <pr_url> --json headRefName --jq '.headRefName')
git worktree remove ../worktrees/$BRANCH --force 2>/dev/null || true
git branch -d $BRANCH 2>/dev/null || true
```

Run this for each PR that was just confirmed as merged. If the worktree directory does not exist (e.g. the planner skipped worktree creation, or cleanup already ran), the command silently succeeds. Mark the issue Done in the product development management system after cleanup.

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

If the issue is too big → skip steps 2–4 and send a `split-report` (see Report section). Do **not** mark the issue In Progress and do **not** create a worktree.

**Splitting guidelines:**
- Aim for 2–4 sub-issues; never more than 5
- Each sub-issue must be independently reviewable and testable (self-contained PR)
- Order sub-issues so foundational work (data model, API contract) precedes consumer work (UI, integrations)
- `depends_on` lists titles of other sub-issues in this split that must complete first

### 2. Mark the issue In Progress
Update the issue status to **In Progress** in the product development management system.

### 3. Set up an isolated workspace
If no worktree or branch exists yet, create one:

```bash
# From the repo root
git worktree add ../worktrees/<branch-name> -b <branch-name>
```

If a branch already exists, create a worktree pointing to it:

```bash
git worktree add ../worktrees/<branch-name> <branch-name>
```

All subsequent reads, edits, and commits must happen inside the worktree — never in the main checkout.

### 4. Build the plan
- Read the relevant files and understand existing patterns, conventions, and architecture.
- Identify which files need to be created, modified, or deleted.
- Identify dependencies between changes (what needs to happen first).
- Anticipate edge cases and how the acceptance criteria map to concrete code changes.
- Write out the plan as an ordered checklist of concrete, issue-specific implementation steps. Each step must map directly to a requirement or acceptance criterion — do not use generic placeholders like "implement per spec". If acceptance criteria are numbered, address each one explicitly.

---

## Report

**When sending a `split-report`** (issue is too big for a single PR):

Use the `message` tool to message `team-lead`:

```
type: split-report
source_issue_id: <issue ID>
reason: <one sentence: why this issue is too big for a single PR>
issues:
  - title: <sub-issue title>
    description: <what this sub-issue covers and its acceptance criteria>
    depends_on:
      - <title of another sub-issue in this list that must complete first, if any>
```

**When sending a `plan-report`** (normal path):

Use the `message` tool to message `team-lead`:

```
type: plan-report
issue_id: <issue ID>
next_task: code | test | demo-review
branch: <branch name, if applicable>
worktree: <absolute path to worktree, if applicable>
pr_url: <PR URL, if applicable>
plan: |
  <ordered implementation checklist — only when next_task is implement-*>
findings: <context for the implementer — test findings on failure, or user_feedback on demo-review redirect; only when next_task is implement-*>
```

Fields that do not apply to the current state should be omitted.
