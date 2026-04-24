#!/bin/bash
# Hook: Guard Against git merge to main
# Event: PreToolUse on Bash
# Issue: #28 — a merge happened without user approval; merges to main must go
#        through a reviewed PR, so block git merge commands on the main branch.
#        Merges between feature branches are allowed.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only inspect git merge commands
if echo "$COMMAND" | grep -qE "git merge( |$)"; then
  # Always allow safety/cleanup operations (--abort, --continue, --quit)
  if echo "$COMMAND" | grep -qE "git merge --(abort|continue|quit)"; then
    exit 0
  fi

  # Only block when the current branch is main
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
  if [ "$CURRENT_BRANCH" = "main" ]; then
    jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "git merge to main is blocked — merges must go through a reviewed PR."}}'
    exit 0
  fi
fi

exit 0
