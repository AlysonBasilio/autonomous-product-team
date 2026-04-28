# Claude Code Hooks — Discovery Report

## What are Claude Code Hooks?

Hooks are user-defined shell commands, HTTP endpoints, or LLM prompts that execute automatically at specific points in Claude Code's lifecycle. They enable automation, validation, and control over Claude's actions — without requiring changes to the prompts or task definitions themselves.

### Hook Types

| Type | Description |
|------|-------------|
| `command` | Shell command; receives JSON via stdin, returns decision via exit code / stdout |
| `http` | POST request to a remote endpoint |
| `prompt` | Sends a yes/no question to a Claude model |
| `agent` | Spawns a subagent to evaluate a condition (experimental) |

### Hook Events (Lifecycle)

**Session lifecycle:**
- `SessionStart` — fires on startup, resume, clear, or compact
- `SessionEnd` — fires when the session terminates

**Turn lifecycle:**
- `UserPromptSubmit` — fires before Claude processes a prompt; can block or add context
- `Stop` — fires when Claude finishes a response; can block Claude from stopping
- `StopFailure` — fires when the stop itself fails

**Tool lifecycle (most powerful):**
- `PreToolUse` — fires before a tool runs; can allow, deny, modify input, or defer
- `PostToolUse` — fires after a successful tool call; can add feedback
- `PostToolUseFailure` — fires after a tool fails

**Other events:**
- `SubagentStart` / `SubagentStop` — subagent lifecycle
- `TaskCreated` / `TaskCompleted` — task lifecycle
- `WorktreeCreate` / `WorktreeRemove` — worktree operations
- `PermissionRequest` / `PermissionDenied` — permission system integration
- `FileChanged` — watched file mutations
- `InstructionsLoaded` — when CLAUDE.md files load

### Configuration

Hooks are defined in `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/validate-bash.sh",
            "timeout": 10,
            "statusMessage": "Validating command..."
          }
        ]
      }
    ]
  }
}
```

Hooks can also be defined in skill/task frontmatter (scoped to that skill's lifetime).

---

## How the Current System Works

The autonomous-product-team project installs:
- `roles/team-lead.md` → `.claude/skills/team-lead/SKILL.md`
- `roles/teammate.md` → `.claude/skills/teammate/SKILL.md`
- 8 task definitions → `.claude/product-team/tasks/`
- `.claude/settings.json` with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`

No hooks are currently configured.

---

## Hook Opportunities for This Project

### 1. Guard Against Destructive Git Operations (HIGH PRIORITY)

**Event:** `PreToolUse` on `Bash`

**Problem:** Agents running `git push --force`, `git reset --hard`, `git clean -f`, or `git checkout .` on the main repo checkout could destroy uncommitted work or corrupt the worktree setup. The task definitions warn against this, but the warning is enforced only at the prompt level.

**Hook:** A shell script that inspects the command and denies any of the following patterns:
- `git push.*--force` / `git push.*-f`
- `git reset --hard`
- `git clean -f` / `git clean -fd`
- `git checkout --` (discards working tree changes)
- `git branch -D` (deletes branches)

**Implementation sketch:**
```bash
#!/bin/bash
COMMAND=$(jq -r '.tool_input.command // empty')
DANGEROUS_PATTERNS=("git push.*--force" "git push.*-f" "git reset --hard" "git clean -f" "git branch -D")
for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qE "$pattern"; then
    jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
      permissionDecisionReason: "Destructive git command blocked by autonomous-product-team hook. Run manually if intentional."}}'
    exit 0
  fi
done
exit 0
```

**Files to add:**
- `.claude/hooks/guard-destructive-git.sh` (the hook script)
- Reference in `.claude/settings.json` and `lib/install.js` MANIFEST

---

### 2. Enforce Worktree Discipline (HIGH PRIORITY)

**Event:** `PreToolUse` on `Edit`, `Write`, `MultiEdit`

**Problem:** Task definitions instruct agents to edit files only inside the worktree, never in the main checkout. But there's no enforcement — a confused agent could edit files in `/Users/alyson/projects/autonomous-product-team/` instead of the worktree. This could corrupt the main branch state.

**Hook:** Check if `$CLAUDE_PROJECT_DIR` is the main checkout. If a write tool targets a file that is under the main checkout directory but the agent is expected to be working in a worktree (detectable by checking if a worktree path is active), deny the call.

**Note:** This requires either (a) a convention-based check on the file path, or (b) reading a small state file written during worktree setup. The simpler approach is option (a): deny writes to the repo root if the path matches the main checkout and the branch is not `main`.

---

### 3. Session Context Loader (MEDIUM PRIORITY)

**Event:** `SessionStart` with matcher `startup` and `resume`

**Problem:** Every time a team-lead or teammate session starts, the agent must discover or be told which GitHub repo and PM system to use. For the team-lead, this means asking the user on every fresh start. For resumed sessions, the context is re-established from memory only.

**Hook:** On session start, read a lightweight project config file (e.g. `.claude/product-team/config.json`) containing the repo, PM system, and project identifier, and inject it as `additionalContext`.

**Implementation sketch:**
```bash
#!/bin/bash
CONFIG_FILE="$CLAUDE_PROJECT_DIR/.claude/product-team/config.json"
if [ -f "$CONFIG_FILE" ]; then
  REPO=$(jq -r '.project_url // empty' "$CONFIG_FILE")
  PM=$(jq -r '.system // empty' "$CONFIG_FILE")
  jq -n --arg ctx "Project config: project_url=$REPO, system=$PM" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
fi
exit 0
```

**Installer change:** `lib/install.js` should prompt for repo + PM system during `init` and write `config.json`. Or the team-lead's first run creates it.

---

### 4. Enforce Structured Reports on Stop (MEDIUM PRIORITY)

**Event:** `Stop`

**Problem:** Team members are supposed to report back with structured YAML messages. If a teammate finishes without sending a report (e.g. just says "Done"), the team lead receives no message and the workflow stalls. There's currently no enforcement.

**Hook type:** `prompt` — ask Claude to evaluate whether the session produced a valid structured report before allowing it to stop.

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "prompt",
            "prompt": "Did this session end with a structured report message (containing a 'type:' field like 'plan-report', 'task-complete', 'test-report', etc.) sent to 'team-lead'? Answer yes or no.",
            "model": "claude-haiku-4-5"
          }
        ]
      }
    ]
  }
}
```

**Caveat:** This would trigger for team-lead sessions too. Matcher could be scoped, but Stop hooks do not currently support skill-scoped matchers in the same way PreToolUse does.

---

### 5. Subagent Observability Logging (LOW PRIORITY)

**Event:** `SubagentStart`, `SubagentStop`, `TaskCreated`, `TaskCompleted`

**Problem:** When multiple subagents are running (team-lead spawning teammates), there's no structured log of which agent started, what it was doing, and when it finished. Debugging failures requires reading terminal output, which can be interleaved and hard to trace.

**Hook:** A shell command that appends a JSON log entry to `.claude/product-team/agent.log` on each subagent lifecycle event. The hook receives the subagent's task context in the JSON payload.

**Implementation sketch:**
```bash
#!/bin/bash
EVENT=$(jq -r '.hook_event_name // empty')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "{\"event\": \"$EVENT\", \"timestamp\": \"$TIMESTAMP\", \"payload\": $(cat)}" \
  >> "$CLAUDE_PROJECT_DIR/.claude/product-team/agent.log"
exit 0
```

---

### 6. Installer Integration (REQUIRED FOR ALL HOOKS)

For hooks to be useful in a distributed package, they need to be:
1. Shipped as files in the package (`hooks/` directory at repo root)
2. Copied to the target project during `init` (added to the `MANIFEST` in `lib/install.js`)
3. Registered in `REQUIRED_SETTINGS` in `lib/install.js` so `mergeSettings` writes them into `.claude/settings.json`

---

## Recommended Implementation Order

| Priority | Hook | Event | Benefit |
|----------|------|-------|---------|
| 1 | Guard destructive git | `PreToolUse(Bash)` | Safety — prevents irreversible damage |
| 2 | Worktree discipline | `PreToolUse(Edit\|Write)` | Safety — prevents main checkout corruption |
| 3 | Session context loader | `SessionStart` | DX — removes repetitive context setup |
| 4 | Structured report enforcement | `Stop` | Reliability — prevents silent workflow stalls |
| 5 | Subagent observability | `SubagentStart/Stop` | Debugging — structured log of agent activity |

---

## Files That Would Need to Change

| File | Change |
|------|--------|
| `hooks/guard-destructive-git.sh` | New: shell script for hook #1 |
| `hooks/load-session-context.sh` | New: shell script for hook #3 |
| `hooks/log-subagent-event.sh` | New: shell script for hook #5 |
| `lib/install.js` | Update MANIFEST to copy hooks; extend mergeSettings to write hooks config |
| `.claude/settings.json` (target project) | Written by updated installer |
| `evals/test_static.py` | Add tests asserting hooks are present in settings and hook scripts exist |
