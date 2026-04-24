#!/bin/bash
# Hook: Session Context Loader
# Event: SessionStart (matcher: startup, resume)
# Reads project config and injects it as additional context so
# agents do not need to re-ask the user for repo/PM details.

CONFIG_FILE="$CLAUDE_PROJECT_DIR/.claude/product-team/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  exit 0
fi

REPO=$(jq -r '.project_url // empty' "$CONFIG_FILE")
PM=$(jq -r '.system // empty' "$CONFIG_FILE")

if [ -n "$REPO" ] || [ -n "$PM" ]; then
  CONTEXT="Project config: project_url=$REPO, system=$PM"
  jq -n --arg ctx "$CONTEXT" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
fi

exit 0
