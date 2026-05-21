# AGENTS.md

Guidance for coding agents working in this repo. Humans should read
[README.md](README.md) first — this file assumes you understand the product.

## Project overview

Ruby orchestrator (`orchestrator/run.rb`, Sinatra + Puma) that dispatches
Markdown task prompts in `tasks/` to Synthup-managed sessions, polls for
structured JSON reports, and routes between tasks via `router.rb`. State
persists in SQLite (`data/orchestrator.db`). Web UI at `orchestrator/ui.html`
is the primary product surface.

- Ruby ≥ 3.0, Bundler ≥ 2.0
- Sinatra 4.x, Puma 8.x, ActiveRecord 8.x + sqlite3, RubyLLM (OpenRouter), Ferrum (e2e)

## Setup commands

```bash
bundle install              # install gems
./bin/start                 # boot orchestrator at http://localhost:4242
```

## Project structure

```
bin/start              # entrypoint — runs bundle install then boots
orchestrator/
  run.rb               # main entry: boot, resume in-flight issues, start Puma
  run_issue.rb         # per-issue loop: code → test → demo-review
  router.rb            # task transition table
  server.rb            # Sinatra app (web UI + REST API)
  task_runner.rb       # dispatches a task to a Synthup session
  synthup.rb           # Synthup API client
  db.rb                # AR connection + auto-migration on boot
  db/migrate/*.rb      # schema migrations
  models/
    issue.rb           # Issue AR model (input_text, repo_url, lifecycle_stage,
                       #   current_task, escalation, history, ...)
    config_entry.rb    # ConfigEntry AR model (Synthup credentials)
  issues.rb            # Issues module — set_current_task, set_escalation, append_history
  config.rb            # Config module — load/save Synthup credentials
  demo_review.rb       # DemoReview.wait_for_approval — blocks thread until UI action
  template.rb          # prompt template rendering
  ui.html              # single-page web UI (the product surface)
tasks/
  code.md              # implement the issue
  test.md              # run tests / CI
  demo-review.md       # summarise PR for human review
data/orchestrator.db   # SQLite store (gitignored); auto-created on boot
tests/                 # see Testing below
```

## Code style

- Match the surrounding file. Ruby files use 2-space indent, `frozen_string_literal: true`, and small focused classes.
- Strong typing where the language allows (keyword args, explicit returns).
- Reuse existing helpers — `issues.rb`, `config.rb`, `synthup.rb` — instead of re-implementing. Persistence goes through the AR models in `orchestrator/models/`; do not write SQL by hand outside of migrations.
- No comments unless the *why* is non-obvious. Identifiers should explain the *what*.

## Testing

This is the single source of truth for tests. Read it before adding one.

### Layout

```
tests/
├── test_static.rb            # structural checks on tasks/*.md (no API key)
├── test_demo_review.rb       # approve / redirect / follow-up scenarios
├── test_server.rb            # rack-test for the REST API
├── test_issues.rb            # Issues module unit tests
├── test_extract_report.rb    # report extraction unit tests
├── test_recovery.rb          # crash-recovery / resume scenarios
├── test_template.rb          # prompt template rendering
├── db_helper.rb              # points AR at :memory: for test isolation
├── eval_helper.rb            # OpenRouter / RubyLLM glue, dotenv loader
├── judge.rb                  # LLM-as-judge helper
├── run.rb                    # combined Ruby suite
└── e2e/                      # browser-driven full-lifecycle tests
    ├── helper.rb             # OrchestratorProcess + Gh + Browser
    ├── test_e2e_lifecycle.rb
    └── run.rb
```

### Commands

| Suite | Command |
|---|---|
| Static (no API key) | `bundle exec ruby tests/test_static.rb` |
| Full Ruby suite | `bundle exec ruby tests/run.rb` |
| End-to-end | `bundle exec ruby tests/e2e/run.rb` |

### Directives

1. **e2e tests must drive the UI only.** No `Net::HTTP` to `/api/*`, no JSON asserts. Every observation reads from the rendered DOM. If you can't observe the state from the UI, **the UI is missing something** — add the affordance to `orchestrator/ui.html` first, then write the assertion. The orchestrator's primary surface is the web UI; bypassing it tests the API contract, not the product.

2. **`gh` CLI at boundaries only.** Setup (create fixture issue) and teardown (close issue/PR) are fine. Mid-test reads of GitHub state are not — read the PR link from `#dr-summary` like a human would.

3. **Real services, real costs.** e2e burns Synthup credits and opens real GitHub PRs. Run against a sandbox repo, never `alysonbasilio/autonomous-product-team`. Always clean up in `ensure` / `teardown`.

4. **Keep the sandbox clean.** Before running e2e, verify the sandbox has no open issues that would confuse the test:
   ```bash
   gh api 'repos/<sandbox>/issues?state=open' --jq '.[] | select(.pull_request == null) | "#\(.number) \(.title)"'
   ```
   Should print nothing. Dependabot PRs are filtered out automatically.

5. **Isolated state.** Spawn the orchestrator with `ORCHESTRATOR_DATA_DIR=Dir.mktmpdir` (the SQLite DB lives at `<data_dir>/orchestrator.db`) and a free port (`TCPServer.new('127.0.0.1', 0)`). Never touch the developer's `data/`. Unit tests use `tests/db_helper.rb`, which points AR at `:memory:` for full isolation.

6. **Skip, don't fail, on missing env.** Use `skip` with a clear message naming the missing var. `tests/run.rb` without Synthup credentials should still print green.

### Adding an e2e scenario

1. New test method in `tests/e2e/test_e2e_lifecycle.rb`, or a sibling `test_*.rb` under `tests/e2e/`.
2. Reuse `tests/e2e/helper.rb`. Don't fork the harness.
3. Check the UX-gap audit table at the top of `test_e2e_lifecycle.rb` and `~/.claude/plans/` before assuming a selector exists.
4. If the UI doesn't expose what you need, ship the UI change first as a separate commit, then write the test.
5. List new selectors in the PR description.

### tests/.env

Loaded by `Dotenv.load` from `tests/eval_helper.rb` and `tests/e2e/run.rb`. Already in `.gitignore`.

| Var | Used by | Required |
|---|---|---|
| `OPENROUTER_API_KEY` | LLM-judge evals | for evals |
| `SYNTHUP_TENANT` | e2e | yes |
| `SYNTHUP_API_KEY` | e2e | yes |
| `E2E_GITHUB_REPO` | e2e (`owner/repo`) | yes |
| `E2E_PORT` | e2e (default: random free port) | no |
| `E2E_TIMEOUT_S` | e2e wall-clock (default: `1800`) | no |
| `E2E_HEADLESS` | e2e (`0` to run headed) | no |

## Git workflow

- Small, focused commits. Subject in the imperative ("Add X", not "Added X"). Match the existing log style (`git log --oneline -20`).
- Don't amend published commits. After a hook failure, fix and create a new commit.
- Branch naming: short kebab-case description of the change.

## Boundaries

**Always**
- Run `bundle exec ruby tests/test_static.rb` after touching `tasks/*.md`.
- Update this file when adding a new test suite, env var, or top-level directory.
- Treat `orchestrator/ui.html` as the contract for e2e tests — selector changes need a matching test update.

**Ask first**
- Running e2e (real Synthup credits, real GitHub PRs).
- Touching `data/` layout or migration logic — backward compatibility matters; users have persisted state.
- Adding a new task to `tasks/` or a new transition to `router.rb` — these change the lifecycle.

**Never**
- Run e2e against `alysonbasilio/autonomous-product-team` (the canonical repo). Use a sandbox.
- Commit `tests/.env`, `data/`, or anything under `tmp/`.
- Bypass demo review or auto-merge PRs — the human merge gate is a product invariant.
- Use `gh` mid-test as a substitute for reading the DOM.
