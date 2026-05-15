---
model: openai/gpt-5.5
timeout_s: 1500
inputs:
  required: []
  optional: []
---

# Task: Issue Triage and Routing

## Objective

Scan the project at `{{ project_url }}` and decide what the team should do next. Pick the highest-priority ready issue, assess where work on that issue currently stands, and emit a single report that tells the orchestrator which task to run next (`code`, `test`, `demo-review`, `discovery`) — or that there is nothing to do.

## Definition of Excluded

An issue is **Excluded** if it has been soft-deleted, trashed, archived, canceled, or marked as a duplicate. All of these mean the issue is settled and not work the team will pick up.

When fetching, do not pass any flag that opts into results from the definition above. When inspecting each issue, check every field that could indicate exclusion — `deleted`, `trashed`, `archived`, `duplicate_of`, `canceled`, or equivalent. If any such marker is set, drop the issue entirely: do not put it in `considered`, do not run dependency lookups on it, and never pick it as `next_issue`.

Excluded is distinct from Blocked. Blocked issues are inspected and reported (they appear in `considered`); Excluded issues are removed from the run as if they never existed.

## Definition of Blocked

A dependency is **resolved** when its status is `Done` or it is Excluded (per the definition above). Any other state is **unresolved** and blocks the dependent issue.

An issue is **Blocked** if any of the following are true:
- It has one or more unresolved dependencies
- A required product or architectural decision has not been made
- A spec ambiguity exists that cannot be resolved from project documentation without user input

An issue is **not** blocked solely because its implementation is difficult or uncertain — only external dependencies or missing decisions constitute a blocker.

## Definition of Ready

For the purposes of this task, an issue is **Ready** if it is non-Done, non-Excluded, and all its dependencies are resolved (per the Definition of Blocked above). A Ready issue is eligible to be picked as `next_issue`.

**Workflow status does not affect Ready.** This system is the sole worker on the project — no status signals "someone else is doing this," because there is no one else. An issue's workflow state (`Todo`, `In Progress`, `In Review`, `Waiting for review`, or anything else short of `Done`) describes where the work currently sits, not whether it's available. An in-flight issue is Ready the same as a fresh one; the system will resume from whatever state it's in rather than restart cold. Do not drop in-flight issues from `considered` or treat them as ineligible — the only gates on candidacy are Excluded and Blocked.

This rule applies only to the issue being evaluated, not to its dependencies. A dependency's status still gates Ready per the Definition of Blocked above — if A depends on B and B is not `Done` or Excluded, A is Blocked, regardless of whether B is in-flight.

---

## Phase 1 — Pick the issue

### 1. Fetch all issues
Query the product development management system for every issue in the project that is not Done. Fetch issues with basic fields first (id, title, status, priority). Then check each issue's dependencies individually with a separate lookup per issue — do not attempt to fetch all issues and all their relations in a single query. Drop Excluded issues from the run per the Definition of Excluded above.

**A zero-result listing is suspicious, not authoritative.** Projects worth triaging almost always have open issues; an empty list usually means the filter shape was wrong (e.g. passing a project URL slug where a UUID was required, or scoping to the wrong team). If your initial listing returns 0 issues, do not conclude the project is empty. Instead, perform both of the following retries before reporting anything:

- **Retry A — resolve the project identifier explicitly.** Look up the project by URL or slug to obtain its canonical ID, then re-run the listing with that ID. If this retry returns ≥1 non-Done issue, proceed to step 2 with those issues.
- **Retry B — re-query without any status filter.** Use the canonical project ID from Retry A but drop the status filter, so the call would return issues in *any* state including Done. Do **not** add any flag that opts into archived, trashed, or deleted results (e.g. `includeArchived: true`) — the retry is only about removing the status filter, not about widening the query to Excluded issues. Interpret the result as follows:
  - If Retry A returned 0 non-Done issues **and** Retry B returns ≥1 issues (i.e. the project has Done issues but no open ones), the project is complete — emit a normal `triage-report` with `next_issue: null`.
  - If Retry B *also* returns 0 issues — meaning the project contains literally no issues in any state — the listing is misconfigured. Real projects do not exist with zero issues. Emit a `task-failed` report whose `failure` field includes the exact tool name, the exact arguments you passed, and the exact response you received on each of the retries. Do not summarize ("returned no issues") — quote each call and response verbatim so the failure is debuggable.

### 2. Check blockers
For each issue, determine whether it is blocked using all of the following methods:

a. **Formal dependencies** — Check the PM system's dependency links. An issue is blocked if any linked dependency is unresolved.

b. **Text-inferred dependencies** — Scan each issue's body for cross-reference patterns such as "Depends on #N", "Blocked by #N", "Requires #N", "After #N", or any mention of another issue as a prerequisite. When found, check the referenced issue; if it's unresolved, the current issue is Blocked.

c. **Semantic dependencies** — Reason about what each issue describes. If issue A describes *running, using, or exercising* a capability, and issue B describes *creating, building, or implementing* that same capability, then A depends on B. If B is unresolved, classify A as Blocked by B.

d. **Unresolved decisions** — An issue is also blocked if it requires an unresolved product or architectural decision.

### 3. Classify each issue
Classify each issue as **Ready** or **Blocked** per the definitions above. Workflow status alone never disqualifies an issue from Ready — see the Definition of Ready.

### 4. Rank ready issues
Sort the ready issues by priority (highest first), using the priority assigned in the product development management system. If priorities are equal, prefer the issue with the earliest creation date. Note: formal PM-system dependency links, text-inferred cross-references, and semantic dependencies all count equally when determining whether an issue is Blocked or Ready.

**Hard rule before picking the candidate to assess in Phase 2:** for the issue you are about to pick, walk its dependency list and confirm that every dependency has status `Done` or is Excluded. If even one dependency is in any other state (`Todo`, `In Progress`, `In Review`, `Waiting`, etc.), that issue is Blocked — skip it. Pick the next-highest-priority Ready candidate, or stop with `next_issue: null` if no candidate passes this check. Never set `next_issue` to an issue whose own summary acknowledges it is blocked.

If the product development management system returns an error at any step in Phase 1, stop and emit a `task-failed` report (see the Report section).

---

## Phase 2 — Assess state and route

For the highest-ranked Ready candidate from Phase 1, work out the next concrete task by inspecting actual project state. Re-running this assessment is how the team recovers from mid-flight work, redirects, and CI failures without losing context.

### 1. Fetch the issue
Read the full issue from the product development management system — title, description, acceptance criteria, last-updated timestamp. Keep the timestamp for the stale-implementation check below.

### 2. Read PM issue task history
Read all comments on the issue. Collect the most recent comment of each of these types:

- `type: task-complete` — implementation was completed; note the `pr_url` and timestamp
- `type: test-complete` — a test run completed; note the `outcome`, `findings`, and timestamp
- `type: demo-review-complete` — a demo review completed; note the `outcome`, `user_feedback`, and timestamp

**Multi-PR tracking**: An issue may have multiple associated PRs. Collect the `pr_url` values from ALL `task-complete` comments (not just the most recent one) to build the complete set of associated PRs for the issue.

**Stale-implementation check**: Flag the implementation as **stale** if the issue was edited after the most recent `test-complete: pass` timestamp.

### 3. Check git/PR state
- Check for an existing local branch: `git branch --list "*<issue-id>*"`.
- Check for an open PR on the remote: `gh pr list --search "<issue-id>" --state open`.
- For each associated PR in the multi-PR set (from Step 2), check its state: `gh pr view <pr_url> --json state`. All associated PRs must be merged or closed for the issue to be fully complete.
- **If a PR is open**, also collect:
  - CI status: `gh pr checks <pr_url>`
  - Merge conflicts: `gh pr view <pr_url> --json mergeable,mergeStateStatus` — flag if `mergeable` is `CONFLICTING` or `mergeStateStatus` is `DIRTY`
  - Unresolved review threads (count + bodies): `gh api graphql -f query='{ repository(owner:"OWNER",name:"REPO"){ pullRequest(number:NUMBER){ reviewThreads(first:100){ nodes{ isResolved comments(first:1){nodes{body}} }}}}}' | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)]'`

### 4. Determine the next task

Two early checks fire only in specific conditions; otherwise fall through to the routing table.

- **Test-blocked.** If the most recent `test-complete` comment has `outcome: blocked`, emit a `blocked` report (see Report section) — the test infra needs human attention.
- **Discovery.** If the issue is exploratory (no concrete acceptance criteria; the deliverable is findings/follow-up issues rather than working software), emit a `triage-report` with `next_task: "discovery"` and skip steps 5–6. Technical complexity alone does **not** qualify.

Otherwise, use the most recent comment of each type from Step 2, combined with git/PR state. Evaluate rows top to bottom and stop at the first match.

**Override**: if a row below routes to `test` or `demo-review` but the PR has **unresolved review threads**, flip to `code` and pass the thread bodies as `findings` (resolve review threads first).

| PM issue comment history | Git/PR state | Action |
|---|---|---|
| `demo-review-complete outcome: approved` | All associated PRs merged or closed | **Mark issue Done** in the PM system, then go back to Phase 1 step 4 and pick the next-highest Ready candidate to assess. If no other candidates remain, emit `next_issue: null`. |
| `demo-review-complete outcome: approved` for most-recent reviewed PR | That PR is now merged, but other associated PRs still open | `next_task: "test"` or `"demo-review"` — route to the next open PR (check its CI/review state to decide); include the open PR's `pr_url` |
| `demo-review-complete outcome: approved` | PR reviewed is still open (user has not merged yet) | Nothing to do — awaiting user merge. **Advance**: go back to Phase 1 step 4 and pick the next-highest Ready candidate. If no other candidates remain, emit `next_issue: null`. |
| `demo-review-complete outcome: redirect`, no newer `task-complete` | any | `next_task: "code"` — user redirected; pass `user_feedback` as `findings` |
| `demo-review-complete outcome: redirect`, newer `task-complete` exists | PR open, CI green | `next_task: "test"` — implementation was updated after redirect |
| `test-complete outcome: pass`, not stale | PR open, CI green | `next_task: "demo-review"` |
| `test-complete outcome: pass`, **stale** | PR open | `next_task: "code"` — issue updated since test; re-run code with the change context as `findings` |
| `test-complete outcome: fail` | PR open | `next_task: "code"` — fix findings on the existing branch; pass test findings as `findings` |
| `task-complete` exists | PR open, **merge conflicts** | `next_task: "code"` — rebase and resolve conflicts; pass merge-conflict details as `findings` |
| `task-complete` exists | PR open, CI green | `next_task: "test"` |
| `task-complete` exists | No open PR, or PR CI failing | `next_task: "code"` — lost artifact or broken CI; pass CI failure context as `findings` if applicable |
| No `task-complete` | Branch exists, no PR | `next_task: "code"` — reuse the existing branch |
| No `task-complete` | No branch, no PR | `next_task: "code"` — fresh start |

When routing to `code`, populate `findings` only when there is a specific reason (test-failure findings, demo-review redirect feedback, staleness, merge conflicts, CI failure context, or unresolved review thread bodies). Omit `findings` entirely for a fresh start with no prior history.

### 5. Mark the issue In Progress (only when routing to `code`)
Update the issue status to **In Progress** in the product development management system. Skip this for `test` / `demo-review` / `discovery` routings — those branches imply the issue is already in flight.

### 6. Determine the branch name (only when routing to `code`)
- If a branch already exists (found via the `git branch --list` check or the open-PR check above), record its name.
- If no branch exists yet, derive a name following the convention `<issue-id>-<short-description>` (e.g. `eng-42-add-login-page`). Do not create or push it — branch creation is handled by the code task.

---

## Report

Your entire output must be exactly one fenced ` ```json ` code block — no prose, analysis, or explanation before or after it. The orchestrator parses fenced JSON blocks only.

**When the test-blocked check fired** in Phase 2 step 4, output a `blocked` report. The orchestrator will surface this as an escalation banner asking the user to verify the change manually.

```json
{
  "type": "blocked",
  "issue_id": "<issue ID>",
  "pr_url": "<PR URL>",
  "what_is_blocked": "<one sentence: what blocked the test run and what was tried>"
}
```

**When the PM system returned an error during Phase 1**, output:

```json
{
  "type": "task-failed",
  "task": "tasks/issue-triage.md",
  "failure": "<exact error message and which step failed>"
}
```

**Otherwise** (normal path), output a `triage-report`:

```json
{
  "type": "triage-report",
  "next_issue": { "id": "<issue ID>", "title": "<title>", "summary": "<summary>" },
  "next_task": "code",
  "branch": "<branch name>",
  "pr_url": "<PR URL>",
  "issue_title": "<issue title>",
  "issue_description": "<full issue description / acceptance criteria>",
  "findings": "<context for the implementer — test findings, user_feedback, merge-conflict details, review-thread bodies>",
  "considered": ["<id>", "<id>", "..."],
  "exclusion_checked": ["<id>:<state>", "..."],
  "dependencies_checked": ["<dep-id>:<status>", "..."]
}
```

Field rules:

- `next_issue` is the Ready candidate you picked in Phase 1 and assessed in Phase 2. Set to `null` when no Ready candidate exists (or when every candidate's assessment said "advance"). When `next_issue` is `null`, omit `next_task`, `branch`, `pr_url`, `issue_title`, `issue_description`, and `findings`.
- `next_task` must be one of `"code"`, `"test"`, `"demo-review"`, or `"discovery"`. There is no `"plan"` or `"create-issue"` value — scope splitting is handled inside the code task.
- `branch` applies only when `next_task` is `"code"`.
- `issue_title` and `issue_description` apply when `next_task` is `"code"`, `"test"`, or `"demo-review"`. They let downstream tasks skip a redundant fetch.
- `findings` applies only when `next_task` is `"code"` and there is a specific reason (see Phase 2 step 4).
- Fields that do not apply must be omitted entirely (no `null`, no empty strings).

`considered` MUST list every non-Done issue ID returned by Phase 1 step 1 — one entry per issue, even those you classified Blocked. The presence of an ID in this list is your attestation that you ran the per-issue dependency lookup from step 2a on it. If you did not run that lookup for an issue, do not include it; instead, treat the run as incomplete and emit a `task-failed` report.

`exclusion_checked` MUST list every issue returned by step 1 — including ones you ultimately dropped as Excluded — formatted `"<id>:<state>"` where `<state>` is `active` if no exclusion field was set, or the name of the exclusion field that was set (`deleted`, `trashed`, `archived`, `duplicate_of`, `canceled`, or whatever equivalent the PM system uses). The presence of an ID here is your attestation that you inspected its exclusion fields on the per-issue lookup. An issue may only appear in `considered` if its corresponding `exclusion_checked` entry is `active`; any other state means the issue is Excluded and must be dropped. Never set `next_issue` to an ID whose `exclusion_checked` entry is anything other than `active`.

`dependencies_checked` MUST list every dependency you verified, formatted `"<dep-id>:<status>"` (for example `"ENG-1980:In Progress"`). Include formal PM-system links, text-inferred references, and semantic dependencies. Specifically:

- When `next_issue` is non-null: list the dependencies you verified for the chosen issue.
- When `next_issue` is null **because every candidate was Blocked**: list the unresolved dependencies that caused each candidate to be classified Blocked. This is the audit trail proving you actually evaluated blockers rather than silently skipping issues. Use `"<dep-id>:<status>"` for issue-link blockers and `"<issue-id>:unresolved-decision"` (or similar) for missing-decision blockers.
- When `next_issue` is null **because there are no non-Done issues at all** (project complete / empty): set `dependencies_checked` to `[]`.

The `next_issue` (when non-null) MUST itself appear in `considered`.

## Definition of Done

This task is complete when a single fenced ```json report has been emitted that either:
- selects a `next_issue` with a `next_task`, or
- explicitly emits `next_issue: null` because no Ready candidate produced a routable assessment, or
- emits `task-failed` (PM system error) or `blocked` (test infra needs human help).
