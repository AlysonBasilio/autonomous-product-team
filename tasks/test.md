---
model: openai/gpt-5.5
timeout_s: 3600
inputs:
  required: [issue_id, pr_url, issue_title, issue_description]
  optional: []
---

# Task: Test

Adversarial QA on PR **{{ pr_url }}** for issue **{{ issue_id }}** in the project at `{{ project_url }}`, before any merge. You are testing as a user — do not read the implementation code or PR diff.

## Workflow

### 1. Review the issue

**{{ issue_title }}**

{{ issue_description }}

The acceptance criteria above define what you are testing for. Test blind as a user would.

### 2. Check out the branch

```bash
gh pr checkout {{ pr_url }}
```

### 3. Environment

You are in a Linux container with the usual language toolchains — no Docker, Compose, or k8s. Run things natively (`bundle install && bundle exec …`, `npm install && npm run …`, `pip install -r requirements.txt && …`). Install missing deps yourself (`apt-get install` for system libs, `gem`/`npm`/`pip install` for language packages); start required services in-container (`apt-get install postgresql && service postgresql start`, or run the binary directly). Only emit `outcome: "blocked"` for things you fundamentally can't provide (cloud credentials, third-party API keys, proprietary binaries).

### 4. Start the app and exercise the change with three lenses

Drive the change from the outside through its real interface: hit the HTTP endpoint with `curl`, click through the UI, run the CLI command, observe the database row / log line / file the change is supposed to produce. **Running the repo's existing test suite (`rake test`, `pytest`, `npm test`, etc.) does not count** — it only proves the implementer's own assertions still pass. If you can't drive the change end-to-end, emit `outcome: "blocked"` — do not fall back to the test suite and report `pass`.

Apply three lenses, and complete all three even after finding critical issues:

- **Acceptance criteria** — verify each is demonstrably met from the outside.
- **Boundary and error paths** — target what the implementer might have assumed won't happen.
- **Regression** — spot-check adjacent features that share code paths.

If the app genuinely won't start (after a real attempt to install deps), emit `outcome: "blocked"` with one finding describing what blocked the run and what you tried. The next plan surfaces blocks to the user as an escalation — this is a request for human testing, not a request to write setup docs.

### 5. Report

Post a comment to the PM issue using the product development management system tool, then output your final response. Both are a single fenced ```json block. The PM comment uses `type: "test-complete"`:

```json
{
  "type": "test-complete",
  "issue_id": "<issue ID>",
  "pr_url": "<PR URL>",
  "outcome": "pass",
  "findings": [
    { "description": "<finding>", "severity": "critical" }
  ]
}
```

The final response uses `type: "test-report"` with otherwise the same shape:

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

`outcome` must be `"pass"`, `"fail"`, or `"blocked"`. `severity` must be `"critical"` or `"minor"`. When `outcome` is `"pass"`, `findings` must be `[]`. When `outcome` is `"blocked"`, `findings` must contain one entry describing exactly what blocked the run. When `outcome` is `"fail"`, every finding must be specific and actionable for the implementer.

The PM comment is the authoritative test completion record — if re-running, it supersedes any prior test-complete comment. The final response must be the JSON block and nothing else.
