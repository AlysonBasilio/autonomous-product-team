---
model: openai/gpt-5.4
inputs:
  required: [issue_id, pr_url]
  optional: []
---

# Task: Test

Adversarial QA on PR **{{ pr_url }}** for issue **{{ issue_id }}** in the project at `{{ project_url }}`, before any merge. You are testing as a user — do not read the implementation code or PR diff.

## Workflow

### 1. Fetch the issue

Fetch issue `{{ issue_id }}` from the product development management system to understand the acceptance criteria. Do NOT read the implementation code or PR diff — test blind as a user would.

### 2. Check out the branch

Check out the PR branch locally:

```bash
gh pr checkout {{ pr_url }}
```

### 3. Environment

You are already running inside a Linux container with Ruby, Node, Python, and the usual language toolchains preinstalled. There is no nested Docker, Docker Compose, or Kubernetes available. When a repo documents `docker compose up` or similar as the way to run things, treat that as instructions for a developer on their own machine; in your container, install and run the project natively instead (`bundle install && bundle exec …`, `npm install && npm run …`, `pip install -r requirements.txt && …`). Don't try to start Docker.

If the native path hits a missing dependency, **try to install it first** before handing off. You have a normal Linux container with package managers — `apt-get install` for system libraries (libpq, imagemagick, build-essential, etc.), `gem install` / `npm install` / `pip install` for language packages. If a service like Postgres or Redis is required, install and start it inside this container (`apt-get install postgresql && service postgresql start`, or run the binary directly). Only after a real attempt to install the dependency fails — or the missing piece is something you fundamentally can't provide (cloud credentials, a third-party API key, a proprietary binary) — should you emit `outcome: "blocked"`.

### 4. Start the application and test

Try to start the application from the branch and exercise the change. Use whatever cues the repo gives you, any setup notes you happen across, or sensible defaults for the stack.

**What "exercise the change" means.** You must drive the change from the outside through its real interface: hit the HTTP endpoint with `curl`, click through the UI, run the CLI command, observe the database row / log line / file the change is supposed to produce. Running the repo's existing test suite (`rake test`, `pytest`, `npm test`, `go test`, etc.) does **not** count and is not a substitute. Those tests only prove the implementer's own assertions still pass; they cannot catch anything the implementer didn't already think to check, and the whole point of adversarial QA is to find what they missed. If you genuinely cannot drive the change end-to-end (the app won't start, the endpoint isn't reachable, the UI won't render), emit `outcome: "blocked"` — do **not** fall back to running the test suite and reporting `pass`.

If you genuinely cannot run the app yourself (commands fail with missing dependencies, no obvious entry point, the environment refuses to start, required services are unavailable, etc.), stop and emit a test-report with `outcome: "blocked"`. Post the same shape as a test-complete PM comment so the next plan can see what blocked the run. The next plan will surface the block to the user via an escalation banner — this is a request for human testing, not a request to write setup documentation, so do not propose creating env-setup follow-ups.

If the app starts, continue to step 5.

### 5. Test with three lenses

**Acceptance criteria** — Verify each criterion is demonstrably met from the outside (API calls, UI interaction, observable side effects). Do not verify by reading source code.

**Boundary and error paths** — Test invalid inputs, missing fields, out-of-range values, unauthorized access. Target anything the implementer might have assumed won't happen.

**Regression** — Spot-check adjacent features that share code paths with this change. Confirm they still work.

### 6. Report

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

`outcome` must be `"pass"`, `"fail"`, or `"blocked"`. `severity` must be `"critical"` or `"minor"`. When `outcome` is `"pass"`, `findings` must be `[]`. When `outcome` is `"blocked"`, `findings` must contain one entry describing exactly what blocked the run.

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

A `test-report` has been delivered with `outcome` set to `pass`, `fail`, or `blocked`. If `outcome: pass`, findings list is empty. If `outcome: fail`, every finding is specific and actionable for the implementer. If `outcome: blocked`, the single finding describes what blocked the run and what was already tried.

## Rules

- Do not read the PR diff or implementation code before testing — test as an external user would.
- Test from the branch, not from main.
- Try to run the app yourself before emitting `outcome: blocked`.
- The repo's existing test suite is not a valid substitute for exercising the change. If you can't drive the change as a user, emit `outcome: blocked` — don't run `rake test` / `pytest` / `npm test` and call it pass.
- Every finding must include enough detail for the implementer to reproduce and fix it.
