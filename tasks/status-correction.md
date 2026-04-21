---
model: claude-haiku-4-5
---

# Task: Status Correction

## Objective

Audit a set of issues in the product development management system and correct any status that is inconsistent with ground truth.

## Input

The team manager provides either:
- A specific issue ID to audit, or
- A scope (e.g. "all issues in the project") to audit broadly.

## Workflow

1. **Fetch the issue(s)** from the product development management system.

2. **For each issue, verify the status is consistent with reality:**
   - If marked **Done** — confirm that:
     - A PR was merged into main for this issue.
     - All acceptance criteria are checked off.
     - Dependencies are also Done.
     - If any of these are false, the status is wrong.
   - If marked **In Progress** — confirm that a team member is actively working on it. If no work is happening, it should revert to its prior status.
   - If marked **Blocked** — confirm the blocker still exists. If the blocking issue is now Done, this issue may no longer be blocked.

3. **Correct any inconsistencies** — Update the issue status to match ground truth. Add a comment on the issue noting what was corrected and why.

4. **Report to team manager** using this schema:

   ```
   type: status-correction-report
   audited: [issue IDs]
   corrections: [{ id, old_status, new_status, reason }]
   now_unblocked: [issue IDs]
   ```

## Definition of Done

This task is complete when all audited issues have accurate statuses in the product development management system and the correction report has been delivered to the team manager.
