#!/bin/bash
# Hook: Guard Against git merge
# Event: PreToolUse on Bash
# Issue: #28 — a merge happened without user approval; all merges must go
#        through a reviewed PR, so block git merge commands outright.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

if echo "$COMMAND" | grep -qE "git merge( |$)"; then
  jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "git merge is blocked — merges must go through a reviewed PR."}}'
  exit 0
fi

exit 0
