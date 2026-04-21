#!/bin/bash
# Hook: Enforce Worktree Discipline
# Event: PreToolUse on Edit, Write, MultiEdit
# Denies writes to files under the main checkout when an agent should be
# working inside a worktree.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only enforce when CLAUDE_PROJECT_DIR is set (the main checkout root)
if [ -z "$CLAUDE_PROJECT_DIR" ]; then
  exit 0
fi

# Get the current git branch
BRANCH=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)

# If we are on main, no worktree discipline needed — we ARE the main checkout
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  exit 0
fi

# Check if the file path is inside the main checkout (not a worktree)
REAL_PROJECT_DIR=$(cd "$CLAUDE_PROJECT_DIR" && pwd -P)
REAL_FILE_DIR=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P)

if [ -z "$REAL_FILE_DIR" ]; then
  exit 0
fi

# If the file is under the main checkout, deny the write
if [[ "$REAL_FILE_DIR" == "$REAL_PROJECT_DIR"* ]]; then
  # Check if this is actually a worktree (worktrees have .git as a file, not a directory)
  if [ -d "$CLAUDE_PROJECT_DIR/.git" ]; then
    # This is the main checkout (not a worktree) — deny writes from non-main branches
    jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "Write to main checkout blocked. You should be editing files in the worktree, not the main checkout."}}'
    exit 0
  fi
fi

exit 0
