---
model: deepseek/deepseek-v4-pro
inputs:
  required: [issue_id]
  optional: []
---

# Task: Discovery

You are exploring issue **{{ issue_id }}** in the project at `{{ project_url }}`.

## Workflow

### 1. Fetch the issue

Retrieve issue `{{ issue_id }}` from the product development management system. Read its title, description, and any comments to understand the request, idea, bug, or feature to explore.

### 2. Research

Investigate the codebase and project context:
- Read relevant source files, configuration, and documentation
- Search for related patterns, naming conventions, and existing abstractions
- Check existing issues in the product development management system for related or overlapping work

### 3. Analyze and synthesize

Based on your research, identify:
- **Unknowns** — what information is still missing or ambiguous
- **Risks** — technical, product, or integration risks
- **Open questions** — decisions that need to be made before or during implementation
- **Concrete work needed** — the specific pieces of implementation, testing, or documentation work required

### 4. Define follow-up issues

For each piece of work identified in step 3, draft a follow-up issue with:
- **Title** — concise, action-oriented
- **Description** containing:
  - **Background** — why this work exists, referencing the discovery issue (`{{ issue_id }}`) and what was learned
  - **What needs to be done** — concrete description of the work, written so a future implementer can understand it without reading the discovery issue
  - **Acceptance criteria** — specific, verifiable conditions that define Done

### 5. Create follow-up issues

Create each follow-up issue in the product development management system with:
- Status: **Backlog**
- Priority: **No priority**

### 6. Check dependencies

After creating all issues, review the full list of non-Done issues in the product development management system.

For each newly created issue, check:
- Does it **block** any existing issue?
- Is it **blocked by** any existing issue?
- Are there dependencies **between** the newly created issues themselves?

Link any clear dependencies using the product development management system's dependency feature. Do not add speculative links.

### 7. Close the source issue

Mark issue `{{ issue_id }}` as **Done** in the product development management system. Discovery's deliverable is the set of follow-up issues created in step 5; once those exist, the discovery issue itself is complete.

### 8. Report

Post a comment to the PM issue using the product development management system tool. The comment body must be a single fenced ```json block containing this object:

```json
{
  "type": "discovery-complete",
  "issue_id": "<issue ID>",
  "summary": "<one sentence describing what was explored>",
  "created_issues": [
    { "id": "<new issue ID>", "title": "<title>" }
  ]
}
```

Output your final response as a single fenced ```json code block containing the same object — and nothing else.

## Definition of Done

All follow-up issues have been created, any clear dependencies have been linked, the source issue has been moved to Done, and the discovery-complete report has been output.

## Rules

- Do not implement anything — this task is exploration and issue creation only.
- Do not modify the source issue's priority or any fields other than status — only add a comment and move it to Done after the follow-ups exist.
- Write issue descriptions for a future implementer who has zero context.
- Do not invent requirements beyond what the research supports.
