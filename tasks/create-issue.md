---
model: openai/gpt-5.4-mini
timeout_s: 900
inputs:
  required: [issues]
  optional: [source_issue_id, priority, block_source, split_context, return_to, context, issue_id, pr_url]
---

# Task: Create Issues

Create new issues in the project at `{{ project_url }}` for follow-up work identified during implementation or review. Write descriptions that give future implementers full context, not just a summary of the deferral.

## Issues to create

{{#issues}}
{{ . }}
{{/issues}}

{{#source_issue_id}}
The source issue is **{{ . }}**.
{{/source_issue_id}}
{{#priority}}
Assign priority **{{ . }}** to every created issue.
{{/priority}}
{{#block_source}}
After creating the issues, link the source issue as **blocked by** every newly created issue.
{{/block_source}}
{{#split_context}}
The source issue is being **split** — the newly created issues collectively replace it. After all issues are created and dependencies are linked, mark the source issue as **Done** in the product management system. The source issue's goal is achieved by completing the new issues, so it should not remain open.
{{/split_context}}
{{#return_to}}
After completion, the orchestrator will dispatch the **{{ . }}** task next. Echo `return_to: "{{ . }}"` in the report so the router can route correctly.
{{/return_to}}
{{#context}}
Caller-provided context (echo unchanged in the report):

{{ . }}
{{/context}}

## Workflow

### 1. Gather context

Fetch the following to inform the issue descriptions:
- The source issue from the product management system: title, description, acceptance criteria, and any relevant comments
- The PR linked to the source issue (if one exists): title, description, and any review comments that prompted the follow-up

Use this context to understand the surrounding product intent and technical decisions — not just the literal deferral note.

### 2. Write descriptions and create each issue

For each entry in `issues`, draft a description using the gathered context, then create it in the product management system.

The description must include:

**Background** — Why this work exists. Reference the source issue (when provided in the input above) and explain what was deferred and why (e.g., out of scope, time constraint, design uncertainty).

**What needs to be done** — Concrete description of the work, written so a future implementer who has not read the source issue can understand it without follow-up questions.

**Acceptance criteria** — Specific, verifiable conditions that define Done for this issue. Derive these from the product intent of the source issue and the nature of the deferred work.

Create each issue with:
- Status: **Backlog**
- Priority: the provided `priority` value, or **No priority** if not specified

### 3. Check for dependencies

After creating all issues, fetch the full list of non-Done issues from the product management system.

For each newly created issue, review its title and description against the existing issues and ask:
- Does the new issue **block** any existing issue? (i.e., existing work cannot proceed until this is resolved)
- Is the new issue **blocked by** any existing issue? (i.e., this cannot start until that work is done)

Apply the same check across the newly created issues themselves — if two follow-ups were created together, determine whether one must precede the other.

For any dependency identified, link the issues using the product management system's dependency feature. Do not add speculative links — only link when the relationship is clear from the issue content.

If `block_source` was set in the input, link the source issue as **blocked by** every newly created issue (per the instruction at the top), even if the heuristic review above did not surface that link. This is non-negotiable — the caller has asserted the dependency.

### 3. Report

Post a comment to the source PM issue using the product development management system tool. The comment body must be a single fenced ```json block containing this object:

```json
{
  "type": "create-issue-complete",
  "source_issue_id": "<source issue ID>",
  "context": "<echo the context field from input, if present>",
  "split_context": true,
  "return_to": "<echo the return_to value from input, if present>",
  "pr_url": "<echo the pr_url from input, if present>",
  "created_issues": [
    { "id": "<new issue ID>", "title": "<title>" }
  ]
}
```

Omit the `context` field entirely when no context was provided in the input; do not emit `null` or an empty string. Likewise, only include `split_context` when it was set to `true` in the input — omit the field otherwise. Echo `return_to` and `pr_url` verbatim when they were provided in the input; omit otherwise.

Output your final response as a single fenced ```json code block containing the same object — and nothing else.

## Definition of Done

All issues in the input list have been created, any clear dependencies between new and existing issues have been linked, and the report has been output.

## Rules

- Do not modify the source issue's status, priority, or any other fields — only add a comment. Exception: when `split_context` is set, mark the source issue **Done** after the new issues are created (its work is now tracked by the split sub-issues).
- Write descriptions for a future implementer who has zero context — do not assume they have read the source issue or PR.
- Do not invent requirements. Acceptance criteria must be derivable from the source issue's product intent and the deferred work's nature.
