# Autonomous Product Team

An autonomous AI product team that runs on [Synthup](https://www.synthup.dev). A Ruby orchestrator picks up the highest-priority unblocked issue, plans it, implements it, tests it, and presents a PR for user approval — then loops. Synthup manages the sessions that execute each task.

This repo *is* the app: clone it, run `./bin/start`, configure via the web UI. No npm, no copy-into-your-project step. Tasks live in `tasks/` and are read in place.

## Prerequisites

| Tool | Required version | Notes |
|---|---|---|
| Ruby | ≥ 3.0 | Older versions fail to resolve `sinatra 4.x` and `puma 8.x`. |
| Bundler | ≥ 2.0 | Bundler ships with modern Ruby; `gem install bundler` if missing. |
| [Synthup](https://synthup.dev) account | — | Needed for the `tenant` and `api_key` configured in the web UI. |

Windows is not officially supported — use [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install).

## Quick start

```bash
git clone https://github.com/alysonbasilio/autonomous-product-team.git
cd autonomous-product-team
./bin/start
```

`bin/start` runs `bundle install` if needed, then boots the orchestrator. Open `http://localhost:4242`:

1. Enter your Synthup `tenant` and `api_key` under **Global Config**.
2. Add a project: paste the URL of your issues list (e.g. `https://linear.app/your-team/issues`) and optionally a `local_path`.
3. The first project becomes active automatically. The orchestrator starts dispatching `issue-triage.md` against it.

Stop with Ctrl-C; restart with `./bin/start`. State is persisted under `data/` and survives restarts.

## Configuration

| Env var | Purpose |
|---|---|
| `SYNTHUP_TENANT` | Override the tenant from `data/config.json`. When set, the UI hides the field. |
| `SYNTHUP_API_KEY` | Override the api key from `data/config.json`. When set, the UI hides the field. |
| `ORCHESTRATOR_PORT` | Web UI port (default `4242`). |
| `ORCHESTRATOR_INTERACTIVE` | Set to `1` to pause for approval before every routed action. |
| `ORCHESTRATOR_DATA_DIR` | Override the data root (default `data/` next to the repo). |

### Data layout

```
data/
├── config.json                  # global Synthup creds + active_project_id
└── projects/<slug>.json         # one file per configured project
```

`<slug>` is derived deterministically from `project_url` (e.g. `https://linear.app/acme/issues` → `linear-acme-issues`). Re-adding the same URL re-binds the existing state file.

## How it works

### Components

- **Orchestrator** — Ruby process (`orchestrator/run.rb`) that drives the lifecycle loop. Routes between tasks based on their JSON output.
- **Task** — A Markdown prompt file in `tasks/` defining one step of the workflow (e.g. `plan.md`, `code.md`). Each task specifies a model in its frontmatter.
- **Session** — A Synthup-managed execution that runs a task prompt and outputs a structured JSON report. The orchestrator polls for the report and routes to the next task.
- **Project state** — `data/projects/<slug>.json`. Tracks the active session and history per project; enables crash-safe resume.

### Lifecycle

```
triage → plan → code → test → demo-review → [user approves + merges] → triage → …
```

The orchestrator dispatches one task at a time. Each task runs as a Synthup session and signals completion by outputting a JSON report. The orchestrator reads the report and dispatches the next task automatically.

Demo review is the one human gate: the orchestrator pauses and presents the PR in the web UI. The user approves or redirects — the orchestrator never merges.

### Behavior

1. Works on **one issue at a time** for the active project — the highest-priority unblocked issue.
2. **The user owns the merge.** Demo review presents the PR in the web UI and waits.
3. **Tasks are idempotent.** Each task posts a structured JSON comment to the PM issue on completion. On restart, `plan.md` reads these comments to determine what has already been done.
4. **Sessions resume after a crash.** The active session ID is saved before polling. On restart, the orchestrator resumes polling the existing session.
5. **A branch is created per issue and cleaned up automatically.** `plan.md` creates a branch for each issue and pushes it. Each Synthup session checks out that branch at the start. After the PR merges, the next planning cycle deletes the local branch.

The orchestrator never `cd`s into your project on disk — all git/file work happens inside the Synthup session against the GitHub repo derived from `project_url`.

## Web UI

The orchestrator UI at `http://localhost:4242` lets you:

- **Switch active project** — header dropdown. Disabled while a task is in flight.
- **Pause / Resume** — stop the orchestrator between tasks without killing the process.
- **Triage Now** — force an immediate re-triage (useful after manually resolving a blocker).
- **Cancel** — abort the current running task.
- **Approve / Redirect** — the approval gate for demo review. Approve records your consent and lets the orchestrator move on; Redirect sends your feedback back through the code task.
- **Escalation banner** — shown when a task fails; includes error details and a Triage Now button to reset.

## Multiple projects

The first cut runs **one active project at a time**. Add as many as you like; pick which one drives the loop via the header dropdown. Each project's state, history, and escalations are isolated in its own `data/projects/<slug>.json`.

Switching projects is disabled while a task is in flight — wait for it to finish (or cancel it) before swapping.

Synthup credentials are global today: two projects on different tenants require manually changing `SYNTHUP_TENANT` (or the saved config) between runs.

## Updating

```bash
git pull
./bin/start
```

If `bundle install` fails after a pull, see [Troubleshooting](#troubleshooting).

## Troubleshooting

### `Could not find puma-X, mustermann-X in locally installed gems`

Bundler couldn't resolve gems for your platform. Run `bundle install` directly to see the underlying error.

### Missing platform entry in `Gemfile.lock`

If `bundle install` complains your platform is unsupported (typical on a fresh Linux x86_64 clone of an older revision):

```bash
bundle lock --add-platform x86_64-linux   # or arm64-darwin for Apple Silicon
bundle install
```

### Ruby version mismatch

If `ruby --version` is below 3.0, pin a supported version locally with rbenv / asdf and re-run `bundle install`.

### Bundler version too old

```bash
gem install bundler
```

## Contributing

### Making changes

When modifying task definitions (`tasks/*.md`), run the eval suite:

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
