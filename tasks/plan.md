# Task: Plan

## Input

The team manager provides the Linear issue ID.

## Phase 1 — Planning

### 1. Read your issue and assess current status
Fetch the issue from the project management system. Understand the full requirements, acceptance criteria, and any linked documentation.

Then assess what work already exists for this issue:
- Check if a branch or worktree already exists locally (e.g. from a previous attempt or a QA failure fix).
- Check if a PR is already open on the remote.
- If prior work exists, pick up where it left off instead of starting from scratch.
- If no prior work exists, proceed to step 2.

### 2. Continue or create an isolated workspace
Before touching any code, create a dedicated git worktree for your branch. This keeps your changes fully isolated from other team members working in parallel.

```bash
# From the repo root
git worktree add ../worktrees/<branch-name> -b <branch-name>
```

All subsequent reads, edits, and commits must happen inside the worktree directory — never in the main checkout. After the issue is Done, clean up:

```bash
git worktree remove ../worktrees/<branch-name>
```

### 3. Plan
Before writing any code, build a plan for how you will tackle the issue:
- Read the relevant files and understand existing patterns, conventions, and architecture in the areas your issue touches.
- Identify which files need to be created, modified, or deleted.
- Identify dependencies between changes (what needs to happen first).
- Anticipate edge cases and how the acceptance criteria map to concrete code changes.
- Write out the plan as a brief ordered checklist of implementation steps.

---

When the plan is complete, report back to `team-manager`:

```
type: task-complete
task: tasks/plan.md
issue_id: <issue ID>
branch: <branch name created in step 2>
worktree: <absolute path to the worktree>
plan: |
  <the full ordered implementation checklist>
```
