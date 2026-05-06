---
model: anthropic/claude-sonnet-4-6
---

# Task: Test

Adversarial QA from the branch, before any merge. You are testing as a user — do not read the implementation code or PR diff.

## Input

You will receive `issue_id` and `pr_url` from the implementation task-complete report.

## Workflow

### 1. Fetch the issue

Fetch the issue from the product development management system to understand the acceptance criteria. Do NOT read the implementation code or PR diff — test blind as a user would.

### 2. Check out the branch

Check out the PR branch locally:

```bash
gh pr checkout <pr_url>
```

### 3. Start the application and test

Try to start the application from the branch and exercise the change. Use whatever cues the repo gives you, any setup notes you happen across, or sensible defaults for the stack.

If you genuinely cannot run the app yourself (commands fail with missing dependencies, no obvious entry point, the environment refuses to start, required services are unavailable, etc.), stop and hand the test off to the user. Do NOT post a test-complete comment in this case. Output your final response as a single fenced ```json code block — and nothing else — containing this object:

```json
{
  "type": "test-blocked",
  "issue_id": "<issue ID>",
  "pr_url": "<PR URL>",
  "summary": "<one sentence: what you tried and what blocked you>"
}
```

The orchestrator will pause and ask the user to verify the change manually. This is a request for human testing, not a request to write setup documentation — do not propose creating env-setup issues or similar follow-ups.

If the app starts, continue to step 4.

### 4. Test with three lenses

**Acceptance criteria** — Verify each criterion is demonstrably met from the outside (API calls, UI interaction, observable side effects). Do not verify by reading source code.

**Boundary and error paths** — Test invalid inputs, missing fields, out-of-range values, unauthorized access. Target anything the implementer might have assumed won't happen.

**Regression** — Spot-check adjacent features that share code paths with this change. Confirm they still work.

### 5. Report

First, post a comment to the PM issue using the product development management system tool. The comment body must be a single fenced ```json block containing this object:

```json
{
  "type": "test-complete",
  "pr_url": "<PR URL>",
  "outcome": "pass",
  "findings": [
    { "description": "<finding>", "severity": "critical" }
  ]
}
```

`outcome` must be `"pass"` or `"fail"`. `severity` must be `"critical"` or `"minor"`. When `outcome` is `"pass"`, `findings` must be `[]`.

This is the authoritative test completion record for this issue. If re-running, this comment supersedes any prior test-complete comment.

Then output your final response as a single fenced ```json code block — and nothing else — containing this object:

```json
{
  "type": "test-report",
  "issue_id": "<issue ID>",
  "pr_url": "<PR URL>",
  "outcome": "pass",
  "findings": [
    { "description": "<finding>", "severity": "critical" }
  ]
}
```

## Definition of Done

Either a `test-report` (after running the tests yourself) or a `test-blocked` (handing the test to the user) has been delivered. If `outcome: pass`, findings list is empty. If `outcome: fail`, every finding is specific and actionable for the implementer.

## Rules

- Do not read the PR diff or implementation code before testing — test as an external user would.
- Test from the branch, not from main.
- Try to run the app yourself before handing off to the user.
- Every finding must include enough detail for the implementer to reproduce and fix it.
