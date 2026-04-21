---
model: claude-haiku-4-5
---

# Task: Issue Triage

## Objective

Scan the project in the configured product development management system and produce a report of which issues are ready for work.

## Input

The team manager provides the product development management system name and project identifier.

## Definition of Blocked

An issue is **Blocked** if any of the following are true:
- It has one or more dependencies that are not yet Done
- A required product or architectural decision has not been made
- A spec ambiguity exists that cannot be resolved from project documentation without user input

An issue is **not** blocked solely because its implementation is difficult or uncertain — only external dependencies or missing decisions constitute a blocker.

## Workflow

1. **Fetch all issues** — Query the product development management system for every issue in the project that is not Done. Fetch issues with basic fields first (id, title, status, priority). Then check each issue's dependencies individually with a separate lookup per issue — do not attempt to fetch all issues and all their relations in a single query.

2. **Check blockers** — For each issue, check its dependencies. An issue is blocked if any dependency is not Done. An issue is also blocked if it requires an unresolved product or architectural decision.

3. **Classify each issue** as one of:
   - **Ready** — All dependencies are Done (or no dependencies). Can be assigned immediately.
   - **Blocked** — One or more dependencies are not Done, or an external decision is pending. Note what is blocking it.

4. **Rank ready issues** — Sort the ready issues by priority (highest first), using the priority assigned in the product development management system. If priorities are equal, prefer the issue with the earliest creation date.

5. **Report to team manager** using this schema:

   ```
   type: triage-report
   next_issue: { id, title, summary }
   ```

   `next_issue` is the highest-priority ready issue — the one the team should work on next. If no issues are ready, `next_issue` is null.

   If the product development management system returns an error at any step, stop and report:

   ```
   type: task-failed
   task: tasks/issue-triage.md
   failure: <exact error message and which step failed>
   ```

## Definition of Done

This task is complete when the triage report has been delivered to the team manager with all issues classified.