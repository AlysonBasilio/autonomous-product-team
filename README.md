# Autonomous Product Team

This project specifies how an autonomous product team should work in the age of AI. The goal is to apply this using https://code.claude.com/docs/en/agent-teams feature.

## Usage

First, add this to your `~/.npmrc` to authenticate with GitHub Packages:

```
@alysonbasilio:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=YOUR_GITHUB_TOKEN
```

You can create a token at https://github.com/settings/tokens with `read:packages` scope.

Then, from your project directory, run:

```bash
npx @alysonbasilio/autonomous-product-team init
```

This installs the agent team files into your project:
- `.claude/skills/team-manager/SKILL.md` — orchestration agent
- `.claude/skills/team-member/SKILL.md` — executor agent
- `.claude/product-team/tasks/` — 7 task definitions

This also installs Claude Code hooks into `.claude/hooks/` and registers them in `.claude/settings.json`:
- **guard-destructive-git.sh** — blocks dangerous git commands (`push --force`, `reset --hard`, `clean -f`, `branch -D`)
- **guard-worktree-discipline.sh** — prevents agents from writing files in the main checkout when they should be in a worktree
- **load-session-context.sh** — loads project config on session start so agents do not re-ask for repo/PM details
- **log-agent-event.sh** — logs subagent lifecycle events to `.claude/product-team/agent.log` for observability

Then open Claude Code in your project and ask:
> "Use the team-manager skill to start working on my product"

Or run `/team-manager` inside Claude Code to invoke the agent directly.

To update to the latest version:

```bash
npx @alysonbasilio/autonomous-product-team update
```

To check what's installed:

```bash
npx @alysonbasilio/autonomous-product-team status
```

## Definitions

### Team

The team which will be responsible for handling a product.

### Team Manager

The role that is responsible for managing team members and delegates tasks.

### Team Member

The role that executes tasks.

### Tasks

The definition of how to do a specific activity to reach a specific goal.

## Premises

1. Each team has one team manager.
2. The team works on **one issue at a time** — the highest-priority unblocked issue. Multiple team members may work in parallel only on independent tasks within that single issue (e.g. backend and frontend simultaneously). No two team members ever work on different issues concurrently.
3. Team managers do not execute tasks. They always delegate tasks to team members.
4. Each task has its own completion status, tracked as structured comments on the PM issue — separate from the issue's overall lifecycle status (In Progress, Done, Blocked).
5. Tasks must be idempotent. Before starting work, the plan task checks PM issue comment history to determine which tasks have already been completed and routes only to what is still needed.
6. Every task posts a structured completion comment to the PM issue when it finishes. These comments are the authoritative record for re-entry after a restart or re-execution.

## Contributing

### Making changes

When modifying role files (`roles/*.md`) or task definitions (`tasks/*.md`), run the eval suite to verify nothing is broken:

```bash
/run-evals
```

Or run directly:

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
| `evals/test_manager_routing.py` | New inbound message types or delegation rules |

Each LLM eval is a scenario dict with `name`, `description`, `mock_context`, and `rubric` — see any existing scenario in those files for the pattern.