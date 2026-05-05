# Autonomous Product Team

An autonomous AI product team that runs on [Synthup](https://www.synthup.dev). A Ruby orchestrator picks up the highest-priority unblocked issue, plans it, implements it, tests it, and presents a PR for user approval — then loops. Synthup manages the sessions that execute each task.

## Prerequisites

- Node.js ≥ 18
- Ruby ≥ 3.0 + Bundler
- A [Synthup](https://synthup.dev) account

## Setup

First, add this to your `~/.npmrc` to authenticate with GitHub Packages:

```
@alysonbasilio:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=YOUR_GITHUB_TOKEN
```

You can create a token at https://github.com/settings/tokens with `read:packages` scope.

From your project directory, run:

```bash
npx @alysonbasilio/autonomous-product-team run
```

This installs any missing files and starts the orchestrator:
- `tasks/` — 8 task definitions (issue-triage, discovery, plan, code, test, demo-review, create-issue, status-correction)
- `product-team.config.json` — project configuration (edit this before running; never overwritten by `--force`)

It also appends `orchestrator-state.json` to your `.gitignore`.

Before starting, edit `product-team.config.json`:

```json
{
  "project_url": "https://linear.app/your-team/issues",
  "system": "Linear",
  "synthup_tenant": "<your-synthup-tenant-id>"
}
```

`system` is the name of your issue management system (e.g. `"GitHub Issues"`, `"Linear"`). `project_url` points to your issues list in that system.

Set your Synthup API key:

```bash
export SYNTHUP_API_KEY=<your-key>
```

The orchestrator UI is available at `http://localhost:4242`.

To update task definitions to the latest version:

```bash
npx @alysonbasilio/autonomous-product-team run --force
```

To preview what would be installed without making changes:

```bash
npx @alysonbasilio/autonomous-product-team run --dry-run
```

To check what's installed:

```bash
npx @alysonbasilio/autonomous-product-team status
```

## How it works

### Components

- **Orchestrator** — Ruby process (`orchestrator/run.rb`) that drives the lifecycle loop. Routes between tasks based on their JSON output.
- **Task** — A Markdown prompt file in `tasks/` defining one step of the workflow (e.g. `plan.md`, `code.md`). Each task specifies a model in its frontmatter.
- **Session** — A Synthup-managed execution that runs a task prompt and outputs a structured JSON report. The orchestrator polls for the report and routes to the next task.
- **State file** — `orchestrator-state.json` in your project root. Tracks the active session and history; enables crash-safe resume.

### Lifecycle

```
triage → plan → code → test → demo-review → [user approves + merges] → triage → …
```

The orchestrator dispatches one task at a time. Each task runs as a Synthup session and signals completion by outputting a JSON report. The orchestrator reads the report and dispatches the next task automatically.

Demo review is the one human gate: the orchestrator pauses and presents the PR in the web UI. The user approves or redirects — the orchestrator never merges.

### How the orchestrator behaves

1. Works on **one issue at a time** — the highest-priority unblocked issue.
2. **The user owns the merge.** Demo review presents the PR in the web UI and waits. The orchestrator never merges.
3. **Tasks are idempotent.** Each task posts a structured JSON comment to the PM issue on completion. On restart, `plan.md` reads these comments to determine what has already been done.
4. **Sessions resume after a crash.** The active session ID is saved to `orchestrator-state.json` before polling. On restart, the orchestrator resumes polling the existing session.
5. **A branch is created per issue and cleaned up automatically.** `plan.md` creates a branch for each issue and pushes it. Each Synthup session checks out that branch at the start. After the PR merges, the next planning cycle deletes the local branch.

## Web UI

The orchestrator UI at `http://localhost:4242` lets you:

- **Pause / Resume** — Stop the orchestrator between tasks without killing the process
- **Triage Now** — Force an immediate re-triage (useful after manually resolving a blocker)
- **Cancel** — Abort the current running task
- **Approve / Redirect** — The approval gate for demo review. Approve records your consent and lets the orchestrator move on; Redirect sends your feedback back through the code task
- **Escalation banner** — Shown when a task fails; includes error details and a Triage Now button to reset

## Contributing

### Making changes

When modifying task definitions (`tasks/*.md`), run the eval suite to verify nothing is broken:

```bash
# Fast structural checks (no API key required)
evals/.venv/bin/python -m pytest evals/test_static.py -v

# Full suite including LLM-as-judge evals (requires OPENROUTER_API_KEY in evals/.env)
evals/.venv/bin/python -m pytest evals/ -v
```

### Setup

```bash
python3 -m venv evals/.venv && evals/.venv/bin/pip install -r evals/requirements.txt
echo "OPENROUTER_API_KEY=sk-or-..." > evals/.env
```

### Adding evals

| File | What to add |
|---|---|
| `evals/test_static.py` | Structural checks — new fields, new task references, new report types |
| `evals/test_triage.py` | New triage edge cases (blocker definitions, priority rules) |
| `evals/test_plan_routing.py` | New routing table rows or state combinations |
| `evals/test_demo_review.py` | New demo-review scenarios or approval/redirect edge cases |
| `evals/test_discovery.py` | New discovery scenarios or issue analysis edge cases |

Each LLM eval is a scenario dict with `name`, `description`, `mock_context`, and `rubric` — see any existing scenario in those files for the pattern.
