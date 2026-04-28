---
model: claude-haiku-4-5
---

# Task: Issue Triage

## Objective

Scan the project in the configured product development management system and produce a report of which issues are ready for work.

## Input

The team lead provides the product development management system name and project identifier.

## Definition of Blocked

An issue is **Blocked** if any of the following are true:
- It has one or more dependencies that are not yet Done
- A required product or architectural decision has not been made
- A spec ambiguity exists that cannot be resolved from project documentation without user input

An issue is **not** blocked solely because its implementation is difficult or uncertain — only external dependencies or missing decisions constitute a blocker.

## Workflow

1. **Fetch all issues** — Query the product development management system for every issue in the project that is not Done. Fetch issues with basic fields first (id, title, status, priority). Then check each issue's dependencies individually with a separate lookup per issue — do not attempt to fetch all issues and all their relations in a single query.

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

5. **Report** — Use the `message` tool to message `team-lead` using this schema:

   ```
   type: triage-report
   next_issue: { id, title, summary, issue_type }
   ```

   `next_issue` is the highest-priority ready issue — the one the team should work on next. If no issues are ready, `next_issue` is null.

   `issue_type` is `discovery` when the issue is exploratory (no concrete acceptance criteria), or `implementation` (the default) when the issue has concrete acceptance criteria and can proceed to planning.

   If the product development management system returns an error at any step, stop and use the `message` tool to message `team-lead`:

   ```
   type: task-failed
   task: tasks/issue-triage.md
   failure: <exact error message and which step failed>
   ```

## Definition of Done

This task is complete when the triage report has been delivered to the team lead with all issues classified.