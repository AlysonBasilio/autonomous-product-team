---
model: anthropic/claude-haiku-4.5
inputs:
  required: []
  optional: []
---

# Task: Issue Triage

## Objective

Scan the project at `{{ project_url }}` and produce a report of which issues are ready for work.

## Definition of Blocked

An issue is **Blocked** if any of the following are true:
- It has one or more dependencies that are not yet Done
- A required product or architectural decision has not been made
- A spec ambiguity exists that cannot be resolved from project documentation without user input

An issue is **not** blocked solely because its implementation is difficult or uncertain — only external dependencies or missing decisions constitute a blocker.

## Workflow

1. **Fetch all issues** — Query the product development management system for every issue in the project that is not Done. Fetch issues with basic fields first (id, title, status, priority). Then check each issue's dependencies individually with a separate lookup per issue — do not attempt to fetch all issues and all their relations in a single query.

   **A zero-result listing is suspicious, not authoritative.** Projects worth triaging almost always have open issues; an empty list usually means the filter shape was wrong (e.g. passing a project URL slug where a UUID was required, or scoping to the wrong team). If your initial listing returns 0 issues, do not conclude the project is empty. Instead, perform both of the following retries before reporting anything:

   - **Retry A — resolve the project identifier explicitly.** Look up the project by URL or slug to obtain its canonical ID, then re-run the listing with that ID. If this retry returns ≥1 non-Done issue, proceed to step 2 with those issues.
   - **Retry B — re-query without any status filter.** Use the canonical project ID from Retry A but drop the status filter, so the call would return issues in *any* state including Done. Interpret the result as follows:
     - If Retry A returned 0 non-Done issues **and** Retry B returns ≥1 issues (i.e. the project has Done issues but no open ones), the project is complete — emit a normal `triage-report` with `next_issue: null`.
     - If Retry B *also* returns 0 issues — meaning the project contains literally no issues in any state — the listing is misconfigured. Real projects do not exist with zero issues. Emit a `task-failed` report whose `failure` field includes the exact tool name, the exact arguments you passed, and the exact response you received on each of the retries. Do not summarize ("returned no issues") — quote each call and response verbatim so the failure is debuggable.

2. **Check blockers** — For each issue, determine whether it is blocked using all of the following methods:

   a. **Formal dependencies** — Check the PM system's dependency links. An issue is blocked if any linked dependency is not Done.

   b. **Text-inferred dependencies** — Scan each issue's body for cross-reference patterns such as "Depends on #N", "Blocked by #N", "Requires #N", "After #N", or any mention of another issue as a prerequisite. When found, check whether referenced issue #N is Done; if not, the current issue is Blocked.

   c. **Semantic dependencies** — Reason about what each issue describes. If issue A describes *running, using, or exercising* a capability, and issue B describes *creating, building, or implementing* that same capability, then A depends on B. If B is not Done, classify A as Blocked by B.

   d. **Unresolved decisions** — An issue is also blocked if it requires an unresolved product or architectural decision.

3. **Classify each issue** as one of:
   - **Ready** — All dependencies are Done (or no dependencies). Can be assigned immediately.
   - **Blocked** — One or more dependencies are not Done, or an external decision is pending. Note what is blocking it.

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