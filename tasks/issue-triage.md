---
model: anthropic/claude-haiku-4.5
inputs:
  required: []
  optional: []
---

# Task: Issue Triage

## Objective

Scan the project at `{{ project_url }}` and produce a report of which issues are ready for work.

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

## Workflow

1. **Fetch all issues** — Query the product development management system for every issue in the project that is not Done. Fetch issues with basic fields first (id, title, status, priority). Then check each issue's dependencies individually with a separate lookup per issue — do not attempt to fetch all issues and all their relations in a single query. Drop Excluded issues from the run per the Definition of Excluded above.

   **A zero-result listing is suspicious, not authoritative.** Projects worth triaging almost always have open issues; an empty list usually means the filter shape was wrong (e.g. passing a project URL slug where a UUID was required, or scoping to the wrong team). If your initial listing returns 0 issues, do not conclude the project is empty. Instead, perform both of the following retries before reporting anything:

   - **Retry A — resolve the project identifier explicitly.** Look up the project by URL or slug to obtain its canonical ID, then re-run the listing with that ID. If this retry returns ≥1 non-Done issue, proceed to step 2 with those issues.
   - **Retry B — re-query without any status filter.** Use the canonical project ID from Retry A but drop the status filter, so the call would return issues in *any* state including Done. Interpret the result as follows:
     - If Retry A returned 0 non-Done issues **and** Retry B returns ≥1 issues (i.e. the project has Done issues but no open ones), the project is complete — emit a normal `triage-report` with `next_issue: null`.
     - If Retry B *also* returns 0 issues — meaning the project contains literally no issues in any state — the listing is misconfigured. Real projects do not exist with zero issues. Emit a `task-failed` report whose `failure` field includes the exact tool name, the exact arguments you passed, and the exact response you received on each of the retries. Do not summarize ("returned no issues") — quote each call and response verbatim so the failure is debuggable.

2. **Check blockers** — For each issue, determine whether it is blocked using all of the following methods:

   a. **Formal dependencies** — Check the PM system's dependency links. An issue is blocked if any linked dependency is unresolved.

   b. **Text-inferred dependencies** — Scan each issue's body for cross-reference patterns such as "Depends on #N", "Blocked by #N", "Requires #N", "After #N", or any mention of another issue as a prerequisite. When found, check the referenced issue; if it's unresolved, the current issue is Blocked.

   c. **Semantic dependencies** — Reason about what each issue describes. If issue A describes *running, using, or exercising* a capability, and issue B describes *creating, building, or implementing* that same capability, then A depends on B. If B is unresolved, classify A as Blocked by B.

   d. **Unresolved decisions** — An issue is also blocked if it requires an unresolved product or architectural decision.

3. **Classify each issue** as **Ready** or **Blocked** per the definitions above. Workflow status alone never disqualifies an issue from Ready — see the Definition of Ready.

   For each Ready issue, also determine its **issue type**:
   - `discovery` — The issue itself asks for research, investigation, or breakdown of a vague idea. Key signal: the deliverable is a set of findings or follow-up issues, not working software. There are no concrete acceptance criteria describing what to build.
   - `implementation` — The issue has a concrete deliverable (something to build, fix, or configure) with acceptance criteria. This is the default. **Technical complexity, uncertainty, or the need to research an approach during implementation does NOT make an issue `discovery`** — only the absence of a concrete deliverable does.

4. **Rank ready issues** — Sort the ready issues by priority (highest first), using the priority assigned in the product development management system. If priorities are equal, prefer the issue with the earliest creation date. Note: formal PM-system dependency links, text-inferred cross-references, and semantic dependencies all count equally when determining whether an issue is Blocked or Ready.

5. **Report** — Output your final response as a single fenced ```json code block — and nothing else — containing this object:

   ```json
   {
     "type": "triage-report",
     "next_issue": { "id": "<id>", "title": "<title>", "summary": "<summary>" },
     "issue_type": "implementation",
     "considered": ["<id>", "<id>", "..."],
     "dependencies_checked": ["<dep-id>:<status>", "..."]
   }
   ```

   `next_issue` is the highest-priority ready issue — the one the team should work on next. If no issues are ready, set `next_issue` to `null` and omit `issue_type`.

   `issue_type` is `"discovery"` when the issue is exploratory (no concrete acceptance criteria), or `"implementation"` (the default) when the issue has concrete acceptance criteria and can proceed to planning.

   `considered` MUST list every non-Done issue ID returned in step 1 — one entry per issue, even those you classified Blocked. The presence of an ID in this list is your attestation that you ran the per-issue dependency lookup from step 2a on it. If you did not run that lookup for an issue, do not include it; instead, treat the run as incomplete and emit a `task-failed` report explaining which issues you were unable to inspect.

   `dependencies_checked` MUST list every dependency you verified for the chosen `next_issue`, formatted `"<dep-id>:<status>"` (for example `"ENG-1980:In Progress"`). Include formal PM-system links, text-inferred references, and semantic dependencies you identified. If `next_issue` is null, set `dependencies_checked` to `[]`. The `next_issue` MUST itself appear in `considered`.

   If the product development management system returns an error at any step, stop and output your final response as a single fenced ```json code block containing this object — and nothing else:

   ```json
   {
     "type": "task-failed",
     "task": "tasks/issue-triage.md",
     "failure": "<exact error message and which step failed>"
   }
   ```

## Definition of Done

This task is complete when the triage report has been output with all issues classified.