#!/bin/bash
# run-task.sh — Execute a single task via headless Claude
# Usage: ./run-task.sh TASK_ID
# Env: WORKER_ID (optional, defaults to 0)
# Exit codes: 0=success, 1=task failed, 2=system error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

TASK_ID="${1:?Usage: run-task.sh TASK_ID}"
WORKER_ID="${WORKER_ID:-0}"
DB_PATH="db/agent.db"
OUTPUT_FILE="/tmp/claude-out-${TASK_ID}.txt"

# ── Cleanup on exit ─────────────────────────────────────
cleanup() {
  rm -f "/tmp/agent-harness-${TASK_ID}.pid"
}
trap cleanup EXIT INT TERM

# Record PID
echo $$ > "/tmp/agent-harness-${TASK_ID}.pid"

# ── 1. Read task details ────────────────────────────────
TASK_JSON=$(python3 task_picker.py get "$TASK_ID")
if [ -z "$TASK_JSON" ]; then
  echo "[run-task] ERROR: Task $TASK_ID not found." >&2
  exit 2
fi

GOAL=$(echo "$TASK_JSON" | jq -r '.goal')
PROJECT=$(echo "$TASK_JSON" | jq -r '.project')
ATTEMPT=$(echo "$TASK_JSON" | jq -r '.attempt_count')
MAX_ATTEMPTS=$(echo "$TASK_JSON" | jq -r '.max_attempts')

echo "[run-task] Running task $TASK_ID (attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS, worker $WORKER_ID)" >&2

# ── 2. Read memory context ──────────────────────────────
MEMORY_CONTEXT=$(python3 memory.py read "$TASK_ID" 2>/dev/null) || MEMORY_CONTEXT=""

# ── 3. Check for previous errors (heal prompt) ──────────
ERROR_HISTORY=$(echo "$TASK_JSON" | jq -r '.last_error // empty')
HEAL_PROMPT=""
if [ -n "$ERROR_HISTORY" ]; then
  HEAL_PROMPT="

PREVIOUS ATTEMPT FAILED with this error:
${ERROR_HISTORY}

Analyze the error and try a different approach. Do NOT repeat the same mistake."
fi

# ── 4. Build prompt ─────────────────────────────────────
PROMPT="You are an autonomous coding agent working on project '${PROJECT}'.

TASK: ${GOAL}

${MEMORY_CONTEXT:+CONTEXT FROM PREVIOUS WORK:
${MEMORY_CONTEXT}
}${HEAL_PROMPT}

INSTRUCTIONS:
- Complete the task fully and correctly.
- Work in the current directory.
- Do not ask questions; make reasonable decisions.
- When done, output a brief summary of what you did."

# ── 5. Mark task as running ──────────────────────────────
python3 task_picker.py mark-running "$TASK_ID" "$WORKER_ID"

# ── 6. Determine working directory ──────────────────────
if [ "$WORKER_ID" -gt 0 ] && [ -d ".worktrees/w${WORKER_ID}" ]; then
  WORK_DIR="$(pwd)/.worktrees/w${WORKER_ID}"
else
  WORK_DIR="$(pwd)"
fi

# ── 7. Execute Claude ───────────────────────────────────
START_TIME=$(date +%s)
CLAUDE_EXIT=0

cd "$WORK_DIR" && claude --bare -p "$PROMPT" \
  --allowedTools "Edit,Write,Bash,Read" \
  --output-format json \
  > "$OUTPUT_FILE" 2>&1 || CLAUDE_EXIT=$?

cd "$SCRIPT_DIR"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "[run-task] Claude finished in ${DURATION}s (exit=$CLAUDE_EXIT)" >&2

# ── 8. Write result to memory ───────────────────────────
python3 memory.py write "$TASK_ID" \
  --output-file "$OUTPUT_FILE" \
  --worker-id "$WORKER_ID" \
  --attempt "$((ATTEMPT + 1))" \
  --duration "$DURATION" \
  --status "running" 2>/dev/null || true

# ── 9. Handle Claude failure ────────────────────────────
if [ "$CLAUDE_EXIT" -ne 0 ]; then
  echo "[run-task] ERROR: Claude execution failed for task $TASK_ID" >&2
  FAILURE_TEXT="Claude exited with code $CLAUDE_EXIT"
  if [ -f "$OUTPUT_FILE" ]; then
    FAILURE_TEXT=$(tail -c 2000 "$OUTPUT_FILE")
  fi
  python3 task_picker.py record-failure "$TASK_ID" "$FAILURE_TEXT"
  exit 1
fi

echo "[run-task] Task $TASK_ID execution complete." >&2
