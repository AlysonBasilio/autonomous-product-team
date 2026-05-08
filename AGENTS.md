# AGENTS.md

Guidance for coding agents working in this repo. Humans should read
[README.md](README.md) first — this file assumes you understand the product.

## Project overview

Ruby orchestrator (`orchestrator/run.rb`, Sinatra + Puma) that dispatches
Markdown task prompts in `tasks/` to Synthup-managed sessions, polls for
structured JSON reports, and routes between tasks via `router.rb`. State
persists under `data/`. Web UI at `orchestrator/ui.html` is the primary
product surface.

- Ruby ≥ 3.0, Bundler ≥ 2.0
- Sinatra 4.x, Puma 8.x, RubyLLM (OpenRouter), Ferrum (e2e)

## Setup commands

```bash
bundle install              # install gems
./bin/start                 # boot orchestrator at http://localhost:4242
```

## Project structure

```
bin/start              # entrypoint — runs bundle install then boots
orchestrator/
  run.rb               # main loop: triage → plan → code → test → demo-review
  router.rb            # task transition table
  server.rb            # Sinatra app (web UI + /api/projects)
  task_runner.rb       # dispatches a task to a Synthup session
  synthup.rb           # Synthup API client
  projects.rb, state.rb, storage.rb, config.rb, demo_review.rb
  ui.html              # single-page web UI (the product surface)
tasks/*.md             # task prompts with model frontmatter
data/                  # runtime state (gitignored); see README.md
tests/                 # see Testing below
```

## Code style

- Match the surrounding file. Ruby files use 2-space indent, `frozen_string_literal: true`, and small focused classes.
- Strong typing where the language allows (keyword args, explicit returns).
- Reuse existing helpers — `state.rb`, `storage.rb`, `synthup.rb` — instead of re-implementing.
- No comments unless the *why* is non-obvious. Identifiers should explain the *what*.

## Testing

This is the single source of truth for tests. Read it before adding one.

### Layout

```
tests/
├── test_static.rb            # structural checks on tasks/*.md (no API key)
├── test_plan_routing.rb      # router transition table coverage
├── test_demo_review.rb       # approve / redirect / follow-up scenarios
├── test_triage.rb            # triage edge cases
├── test_discovery.rb         # discovery scenarios
├── test_server.rb            # rack-test for POST /api/projects
├── test_projects.rb          # projects.rb unit tests
├── test_extract_report.rb    # report extraction unit tests
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

4. **Keep the sandbox issue tracker clean.** Triage picks the highest-priority unblocked non-PR issue. Stray issues from prior runs cause unpredictable routing. Verify before running e2e:
   ```bash
   gh api 'repos/<sandbox>/issues?state=open' --jq '.[] | select(.pull_request == null) | "#\(.number) \(.title)"'
   ```
   Should print nothing. Dependabot PRs are filtered out automatically.

5. **Isolated state.** Spawn the orchestrator with `ORCHESTRATOR_DATA_DIR=Dir.mktmpdir` and a free port (`TCPServer.new('127.0.0.1', 0)`). Never touch the developer's `data/`.

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
- Branch naming follows what `plan.md` generates per issue — manual branches should mirror that style.

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
