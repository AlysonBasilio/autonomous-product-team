#!/bin/bash
# Hook: Session Context Loader
# Event: SessionStart (matcher: startup, resume)
# Reads project config and injects it as additional context so
# agents do not need to re-ask the user for repo/PM details.

CONFIG_FILE="$CLAUDE_PROJECT_DIR/.claude/product-team/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  exit 0
fi

REPO=$(jq -r '.repo // empty' "$CONFIG_FILE")
PM=$(jq -r '.pm_system // empty' "$CONFIG_FILE")
PROJECT=$(jq -r '.project_id // empty' "$CONFIG_FILE")

if [ -n "$REPO" ] || [ -n "$PM" ] || [ -n "$PROJECT" ]; then
  CONTEXT="Project config: repo=$REPO, pm_system=$PM, project_id=$PROJECT"
  jq -n --arg ctx "$CONTEXT" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
fi

exit 0
