# Testing directives

This file is the single source of truth for how tests are structured and what
rules new tests must follow. It is written for humans and for coding agents
that work on this repo.

## Layout

```
tests/
├── test_static.rb            # structural checks on tasks/*.md (no API key needed)
├── test_plan_routing.rb      # router transition table coverage
├── test_demo_review.rb       # approve / redirect / follow-up scenarios
├── test_triage.rb            # triage edge cases
├── test_discovery.rb         # discovery scenarios
├── test_server.rb            # rack-test for POST /api/projects boundary
├── test_projects.rb          # projects.rb unit tests
├── test_extract_report.rb    # report extraction unit tests
├── eval_helper.rb            # OpenRouter / RubyLLM glue, dotenv loader
├── judge.rb                  # LLM-as-judge helper
├── run.rb                    # combined Ruby suite (require_relative each test_*.rb)
│
└── e2e/                      # browser-driven full-lifecycle tests
    ├── helper.rb             # OrchestratorProcess + Gh + Browser
    ├── test_e2e_lifecycle.rb # one Minitest test per scenario
    └── run.rb                # entrypoint: dotenv + require the test files
```

## Running

| Suite | Command |
|---|---|
| Static (no API key) | `bundle exec ruby tests/test_static.rb` |
| Full Ruby suite | `bundle exec ruby tests/run.rb` |
| End-to-end | `bundle exec ruby tests/e2e/run.rb` |

Each `test_*.rb` uses `minitest/autorun`, so requiring them all triggers a
single combined run when `run.rb` exits.

## Core directives

Read these before adding a test. They are not negotiable.

### 1. e2e tests must drive the UI only

No `Net::HTTP` calls to `/api/*`, no asserts against JSON responses. Every
observation comes from the rendered DOM. If you cannot observe the state you
care about from the UI, **the UI is missing something**: add the affordance to
`orchestrator/ui.html` first, then write the assertion.

The reason: the orchestrator is a product whose primary surface is the web UI.
A test that bypasses the UI is testing the API contract, not the product.

### 2. `gh` CLI is allowed at the boundaries only

You may use `gh` to:
- Create the test fixture issue (setup).
- Close the issue and PR (teardown).

You may **not** use `gh` to read state mid-test as a substitute for reading the
DOM. If the test needs to know which PR was opened, it reads the link from
`#dr-summary`, just like a human would.

### 3. Real services, real costs

e2e burns Synthup credits and opens real GitHub PRs. Always:
- Run against a sandbox repo, never the canonical
  `alysonbasilio/autonomous-product-team`.
- Clean up the issue and PR in `ensure` / `teardown`.

### 3a. Keep the sandbox issue tracker clean

The orchestrator's triage picks whichever non-PR issue it considers
highest-priority and unblocked. If the sandbox has stray open issues from
prior runs, manual experiments, or other contributors, triage may select one
of those instead of the test fixture and the test will fail unpredictably
(e.g. routing to `discovery.md` instead of `plan.md`, or escalating).

Before running e2e:

```bash
gh api 'repos/<sandbox>/issues?state=open' --jq '.[] | select(.pull_request == null) | "#\(.number) \(.title)"'
```

Should print nothing. Dependabot **PRs** are fine — they have a non-null
`pull_request` field and triage filters them out.

### 4. Isolated state

Spawn the orchestrator with `ORCHESTRATOR_DATA_DIR=Dir.mktmpdir` and a free
port (`TCPServer.new('127.0.0.1', 0)`). Never touch the developer's `data/`.

### 5. Skip, don't fail, when env is missing

Required env vars absent → `skip` with a clear message naming what's missing.
A developer running `tests/run.rb` without Synthup credentials should see green
output, not red.

## Adding an e2e scenario

1. Add a new test method in `tests/e2e/test_e2e_lifecycle.rb`, or a sibling
   `test_*.rb` file under `tests/e2e/`.
2. Reuse `tests/e2e/helper.rb`. Don't fork the harness.
3. All assertions must read from the DOM. Check the UX-gap audit table at the
   top of `tests/e2e/test_e2e_lifecycle.rb` (and the plan in
   `~/.claude/plans/`) before assuming a selector exists.
4. If you discover the UI doesn't expose what you need, open the gap as a
   separate change to `orchestrator/ui.html` first, then write the test on top.
5. List any new selectors you depend on in the PR description so reviewers can
   sanity-check the UI side.

## Dependencies

- `bundle install` provides everything. e2e adds:
  - `ferrum` — pure-Ruby Chrome driver (no Node).
- System prereqs for e2e:
  - Chrome or Chromium installed and on `$PATH`.
  - `gh` CLI authenticated against the sandbox repo.

## tests/.env

Loaded by `Dotenv.load(File.expand_path('.env', __dir__))` from
`tests/eval_helper.rb` and from `tests/e2e/run.rb`. Already in `.gitignore`.

| Var | Used by | Required |
|---|---|---|
| `OPENROUTER_API_KEY` | LLM-judge evals in `tests/test_*.rb` | for evals |
| `SYNTHUP_TENANT` | e2e | yes |
| `SYNTHUP_API_KEY` | e2e | yes |
| `E2E_GITHUB_REPO` | e2e (`owner/repo`) | yes |
| `E2E_PORT` | e2e (default: random free port) | no |
| `E2E_TIMEOUT_S` | e2e wall-clock (default: `1800`) | no |
| `E2E_HEADLESS` | e2e (`0` to run headed) | no |
