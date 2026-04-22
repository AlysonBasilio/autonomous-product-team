#!/bin/bash
# Hook: Guard Against Destructive Git Operations
# Event: PreToolUse on Bash
# Blocks dangerous git commands that could cause irreversible damage.
# Allows --force-with-lease for safe post-rebase pushes.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

DANGEROUS_PATTERNS=(
  "git push.*--force([^a-z-]|$)"
  "git push( .*)? -f( |$)"
  "git reset --hard"
  "git clean -f"
  "git checkout -- \."
  "git checkout \."
  "git restore \."
  "git branch -D"
)

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qE "$pattern"; then
    jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "Destructive git command blocked by autonomous-product-team hook. Run manually if intentional."}}'
    exit 0
  fi
done

exit 0
