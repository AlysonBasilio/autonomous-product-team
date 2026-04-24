#!/bin/bash
# Hook: Subagent Observability Logging
# Events: SubagentStart, SubagentStop, TaskCreated, TaskCompleted
# Appends JSON log entries to .claude/product-team/agent.log for tracing.

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

LOG_DIR="$CLAUDE_PROJECT_DIR/.claude/product-team"
LOG_FILE="$LOG_DIR/agent.log"

# Ensure the log directory exists
mkdir -p "$LOG_DIR" 2>/dev/null

# Append the event as a JSON line
jq -n \
  --arg event "$EVENT" \
  --arg timestamp "$TIMESTAMP" \
  --argjson payload "$INPUT" \
  '{event: $event, timestamp: $timestamp, payload: $payload}' \
  >> "$LOG_FILE" 2>/dev/null

exit 0
