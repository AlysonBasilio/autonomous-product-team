# Task: Issue Triage

## Objective

Scan the project in the configured project management system and produce a report of which issues are ready for work.

## Input

The team manager provides the project management system name and project identifier.

## Definition of Blocked

An issue is **Blocked** if any of the following are true:
- It has one or more dependencies that are not yet Done
- A required product or architectural decision has not been made
- A spec ambiguity exists that cannot be resolved from project documentation without user input

An issue is **not** blocked solely because its implementation is difficult or uncertain — only external dependencies or missing decisions constitute a blocker.

## Workflow

1. **Fetch all issues** — Query the project management system for every issue in the project that is not Done.

2. **Check blockers** — For each issue, check its dependencies. An issue is blocked if any dependency is not Done. An issue is also blocked if it requires an unresolved product or architectural decision.

3. **Classify each issue** as one of:
   - **Ready** — All dependencies are Done (or no dependencies). Can be assigned immediately.
   - **Blocked** — One or more dependencies are not Done, or an external decision is pending. Note what is blocking it.

4. **Report to team manager** using this schema:

   ```
   type: triage-report
   ready: [{ id, title, summary }]
   blocked: [{ id, title, blocker }]
   inconsistent: [{ id, title, current_status, expected_status }]
   ```

## Definition of Done

This task is complete when the triage report has been delivered to the team manager with all issues classified.