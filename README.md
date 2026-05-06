# Autonomous Product Team

An autonomous AI product team that runs on [Synthup](https://www.synthup.dev). A Ruby orchestrator picks up the highest-priority unblocked issue, plans it, implements it, tests it, and presents a PR for user approval — then loops. Synthup manages the sessions that execute each task.

New to the project? Start with [Prerequisites](#prerequisites), then [Environment Setup](#environment-setup), [Verification](#verification), and finally [Setup](#setup). If something goes wrong, see [Troubleshooting](#troubleshooting).

## Prerequisites

You need the following installed on your machine before running the orchestrator. Exact versions matter — gem resolution and Bundler will fail if these are off.

| Tool | Required version | Notes |
|---|---|---|
| Ruby | ≥ 3.0 | Tested with Ruby 3.x. Older Ruby versions will fail to resolve `sinatra 4.x` and `puma 8.x`. |
| Bundler | ≥ 2.0 | This repo's `orchestrator/Gemfile.lock` is pinned to Bundler 4.0.10, but any Bundler ≥ 2 can install it. |
| Node.js | ≥ 18 | Needed for the `npx` CLI bootstrap. |
| `npx` | ships with Node.js ≥ 18 | No separate install. |
| [Synthup](https://synthup.dev) account | — | Needed for the `tenant` and `api_key` configured in the web UI. |

## Environment Setup

Step-by-step instructions for installing the prerequisites from a clean machine.

### 1. Install Ruby ≥ 3.0

We recommend a Ruby version manager (`rbenv`, `rvm`, or `asdf`) so you can pin the version per-project.

**macOS (Homebrew + rbenv):**

```bash
brew install rbenv ruby-build
rbenv init                 # follow the printed instructions to add rbenv to your shell
rbenv install 3.3.0
rbenv global 3.3.0
```

**Linux (apt + rbenv):**

```bash
sudo apt-get update
sudo apt-get install -y rbenv ruby-build build-essential libssl-dev libreadline-dev zlib1g-dev
rbenv init                 # follow the printed instructions to add rbenv to your shell
rbenv install 3.3.0
rbenv global 3.3.0
```

**Linux (asdf, alternative):**

```bash
asdf plugin add ruby
asdf install ruby 3.3.0
asdf global ruby 3.3.0
```

### 2. Install Bundler

Bundler ships with modern Ruby releases, but if `bundle --version` is missing or below 2.0:

```bash
gem install bundler
```

### 3. Install Node.js ≥ 18

**macOS / Linux (nvm):**

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
nvm install 20
nvm use 20
```

**macOS (Homebrew):** `brew install node`

**Linux (apt):**

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
```

`npx` is installed automatically with Node.js ≥ 18.

### Platform-specific notes

- **macOS (arm64 / x86_64):** the standard rbenv + Homebrew path works out of the box. The `Gemfile.lock` includes `arm64-darwin-24` for Apple Silicon.
- **Linux (x86_64):** the `Gemfile.lock` now includes `x86_64-linux` in its `PLATFORMS` section (added in PR #37 to fix the original gem-resolution bug). If you cloned this repo before that fix landed and you see `Could not find puma-X, mustermann-X in locally installed gems`, run:

  ```bash
  cd orchestrator
  bundle lock --add-platform x86_64-linux
  bundle install
  ```
- **Windows:** not officially supported. Use [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install) and follow the Linux instructions above.

## Verification

Before running `npx ... run`, confirm your environment:

```bash
ruby --version    # ruby 3.x.x ...
bundle --version  # Bundler version 2.x.x or higher
node --version    # v18.x.x or higher
npx --version     # any version that ships with Node ≥ 18
```

If any command above fails or reports an unsupported version, fix it before continuing — see [Troubleshooting](#troubleshooting).

## Troubleshooting

### `Could not find puma-X, mustermann-X in locally installed gems`

This means Bundler couldn't resolve gems for your platform from `orchestrator/Gemfile.lock`. The CLI may suppress the underlying error — to see the full output, run Bundler directly:

```bash
cd orchestrator
bundle install
```

The error usually points to one of: missing platform entry (see next item), Ruby version mismatch, or missing Bundler.

### Missing platform entry in `Gemfile.lock`

If `bundle install` complains that your platform is unsupported (typical on Linux x86_64 after a fresh clone of an older revision):

```bash
cd orchestrator
bundle lock --add-platform x86_64-linux   # or arm64-darwin for Apple Silicon
bundle install
```

### Ruby version mismatch

If `ruby --version` is below 3.0 or doesn't match what other tools expect, pin it locally:

```bash
cd orchestrator
rbenv local 3.3.0   # or: asdf local ruby 3.3.0
```

Then re-run `bundle install`.

### Bundler version too old

If `bundle --version` reports below 2.0 or Bundler is missing entirely:

```bash
gem install bundler
```

Re-run `bundle install` afterwards.

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

It also appends `orchestrator-state.json` to your `.gitignore`.

The orchestrator UI is available at `http://localhost:4242`. On first run, the UI shows a setup form for:

- **project_url** — URL of your issues list (e.g. `https://linear.app/your-team/issues`)
- **tenant** — your Synthup tenant id
- **api_key** — your Synthup API key

These values are persisted in `orchestrator-state.json` and reused on restart.

To update task definitions to the latest version:

```bash
npx @alysonbasilio/autonomous-product-team run --force
```

To preview what would be installed without making changes:

```bash
npx @alysonbasilio/autonomous-product-team run --dry-run
```

To pause for manual approval before each routed action (useful for supervised runs and debugging):

```bash
npx @alysonbasilio/autonomous-product-team run --interactive
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
