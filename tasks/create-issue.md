---
model: claude-sonnet-4-6
---

# Task: Create Issues

Create new issues in the product management system for follow-up work identified during implementation or review. Write descriptions that give future implementers full context, not just a summary of the deferral.

## Input

The team manager provides:
- `source_issue_id` — the issue that identified this follow-up work
- `issues` — list of issues to create, each with `title` and `description`

## Workflow

### 1. Gather context

Fetch the following to inform the issue descriptions:
- The source issue from the product management system: title, description, acceptance criteria, and any relevant comments
- The PR linked to the source issue (if one exists): title, description, and any review comments that prompted the follow-up

Use this context to understand the surrounding product intent and technical decisions — not just the literal deferral note.

### 2. Write descriptions and create each issue

For each entry in `issues`, draft a description using the gathered context, then create it in the product management system.

The description must include:

**Background** — Why this work exists. Reference the source issue (`<source_issue_id>`) and explain what was deferred and why (e.g., out of scope, time constraint, design uncertainty).

**What needs to be done** — Concrete description of the work, written so a future implementer who has not read the source issue can understand it without follow-up questions.

**Acceptance criteria** — Specific, verifiable conditions that define Done for this issue. Derive these from the product intent of the source issue and the nature of the deferred work.

Create each issue with:
- Status: **Backlog**
- Priority: **No priority**

### 3. Check for dependencies

After creating all issues, fetch the full list of non-Done issues from the product management system.

For each newly created issue, review its title and description against the existing issues and ask:
- Does the new issue **block** any existing issue? (i.e., existing work cannot proceed until this is resolved)
- Is the new issue **blocked by** any existing issue? (i.e., this cannot start until that work is done)

Apply the same check across the newly created issues themselves — if two follow-ups were created together, determine whether one must precede the other.

For any dependency identified, link the issues using the product management system's dependency feature. Do not add speculative links — only link when the relationship is clear from the issue content.

### 3. Report

Post a comment to the source PM issue using the product development management system tool:

```
type: create-issue-complete
source_issue_id: <source issue ID>
created_issues:
  - id: <new issue ID>
    title: <title>
```

Then use the `message` tool to message `team-manager` with the same content.

## Definition of Done

All issues in the input list have been created, any clear dependencies between new and existing issues have been linked, and the report has been delivered.

## Rules

- Do not modify the source issue's status, priority, or any other fields — only add a comment.
- Write descriptions for a future implementer who has zero context — do not assume they have read the source issue or PR.
- Do not invent requirements. Acceptance criteria must be derivable from the source issue's product intent and the deferred work's nature.
