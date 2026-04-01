#!/bin/bash
# orchestrator.sh — Single-round main loop
# Runs one cycle: watchdog -> control check -> pick task -> execute -> verify -> handle result
# Designed to be called repeatedly by a wrapper (cron, loop, etc.)
# Exit codes: 0=normal, 1=error, 2=paused/stopped
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

DB_PATH="db/agent.db"

# ── 1. Watchdog: auto-redispatch + health check ─────────
echo "[orchestrator] Running watchdog..." >&2
python3 watchdog.py auto-redispatch >&2 || true

WATCHDOG_ISSUES=$(python3 watchdog.py check 2>&1) || true
if [ -n "$WATCHDOG_ISSUES" ] && [ "$WATCHDOG_ISSUES" != "No issues detected." ]; then
  echo "[orchestrator] Watchdog: $WATCHDOG_ISSUES" >&2
  bash "$SCRIPT_DIR/notify.sh" "$WATCHDOG_ISSUES" || true
fi

# ── 2. Check control signal ─────────────────────────────
STATE=$(sqlite3 "$DB_PATH" "SELECT value FROM control WHERE key='global_state';")

case "$STATE" in
  stopped|stopping)
    echo "[orchestrator] State is '$STATE'. Exiting." >&2
    exit 2
    ;;
  paused)
    echo "[orchestrator] State is 'paused'. Sleeping." >&2
    exit 2
    ;;
  running)
    # continue
    ;;
  *)
    echo "[orchestrator] Unknown state '$STATE'. Treating as stopped." >&2
    exit 1
    ;;
esac

# ── 3. Pick next ready task ─────────────────────────────
BATCH_JSON=$(python3 task_picker.py next-batch --max 1 2>/dev/null) || true

# Extract first task ID from the JSON array
TASK_ID=""
if [ -n "$BATCH_JSON" ] && [ "$BATCH_JSON" != "[]" ] && [ "$BATCH_JSON" != "null" ]; then
  TASK_ID=$(echo "$BATCH_JSON" | jq -r '.[0].id // empty')
fi

if [ -z "$TASK_ID" ]; then
  echo "[orchestrator] No ready tasks. Attempting merge." >&2
  python3 merge-results.py >&2 || true
  exit 0
fi

echo "[orchestrator] Picked task: $TASK_ID" >&2

# ── 4. Execute task ─────────────────────────────────────
RUN_EXIT=0
bash "$SCRIPT_DIR/run-task.sh" "$TASK_ID" || RUN_EXIT=$?

if [ "$RUN_EXIT" -ne 0 ]; then
  echo "[orchestrator] run-task.sh failed for $TASK_ID (exit=$RUN_EXIT)" >&2
fi

# ── 5. Verify task (only if run succeeded) ──────────────
VERIFY_RESULT=""
VERIFY_EXIT=0
if [ "$RUN_EXIT" -eq 0 ]; then
  VERIFY_RESULT=$(bash "$SCRIPT_DIR/verify-task.sh" "$TASK_ID" 2>&1) || VERIFY_EXIT=$?
  echo "[orchestrator] Verify result: $VERIFY_RESULT" >&2
fi

# ── 6. Handle result ────────────────────────────────────
if echo "$VERIFY_RESULT" | grep -q "PASS"; then
  echo "[orchestrator] Task $TASK_ID PASSED." >&2
  python3 merge-results.py >&2 || true
  bash "$SCRIPT_DIR/notify.sh" "Task $TASK_ID passed" || true
else
  echo "[orchestrator] Task $TASK_ID FAILED." >&2

  # Check if task was escalated (watchdog.py handles escalation automatically)
  TASK_JSON=$(python3 task_picker.py get "$TASK_ID" 2>/dev/null) || true
  STATUS=$(echo "$TASK_JSON" | jq -r '.status // "unknown"' 2>/dev/null) || STATUS="unknown"
  ATTEMPT=$(echo "$TASK_JSON" | jq -r '.attempt_count // 0' 2>/dev/null) || ATTEMPT=0
  MAX=$(echo "$TASK_JSON" | jq -r '.max_attempts // 5' 2>/dev/null) || MAX=5

  if [ "$STATUS" = "escalated" ] || [ "$ATTEMPT" -ge "$MAX" ]; then
    echo "[orchestrator] Task $TASK_ID escalated after $ATTEMPT attempts." >&2
    bash "$SCRIPT_DIR/notify.sh" "Task $TASK_ID ESCALATED after $ATTEMPT failures" || true
  else
    echo "[orchestrator] Task $TASK_ID will retry (attempt $ATTEMPT/$MAX)." >&2
  fi
fi

echo "[orchestrator] Round complete." >&2
