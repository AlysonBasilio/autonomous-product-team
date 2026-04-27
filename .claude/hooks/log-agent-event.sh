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

# Rotate if the first entry in the log is older than 24 hours
if [ -f "$LOG_FILE" ]; then
    FIRST_TS=$(jq -r '.timestamp // empty' "$LOG_FILE" 2>/dev/null | head -1)
    if [ -n "$FIRST_TS" ]; then
        FIRST_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$FIRST_TS" +%s 2>/dev/null || echo 0)
        NOW=$(date +%s)
        if [ $(( NOW - FIRST_EPOCH )) -gt 86400 ]; then
            ARCHIVE_DATE=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$FIRST_TS" +%Y-%m-%d 2>/dev/null)
            mv "$LOG_FILE" "$LOG_DIR/agent-${ARCHIVE_DATE}.log"
            gzip -q "$LOG_DIR/agent-${ARCHIVE_DATE}.log" &
        fi
    fi
fi
# Prune archives older than 7 days
find "$LOG_DIR" -name "agent-*.log.gz" -mtime +7 -delete 2>/dev/null

# Append the event as a JSON line
jq -n \
  --arg event "$EVENT" \
  --arg timestamp "$TIMESTAMP" \
  --argjson payload "$INPUT" \
  '{event: $event, timestamp: $timestamp, payload: $payload}' \
  >> "$LOG_FILE" 2>/dev/null

exit 0
