#!/bin/bash
# parallel-orchestrator.sh — Parallel dispatch orchestrator
# Spawns multiple workers to handle tasks concurrently using git worktrees
# Usage: ./parallel-orchestrator.sh [MAX_WORKERS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

DB_PATH="db/agent.db"
MAX_WORKERS="${1:-4}"
WORKER_PIDS=()

# ── Cleanup: kill all workers on exit ────────────────────
cleanup() {
  echo "[parallel] Cleaning up worker processes..." >&2
  for pid in "${WORKER_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  # Remove PID files
  for i in $(seq 0 $((MAX_WORKERS - 1))); do
    rm -f ".worktrees/w${i}/.worker.pid"
  done
}
trap cleanup EXIT INT TERM

# ── 1. Watchdog: auto-redispatch + health check ─────────
echo "[parallel] Running watchdog..." >&2
python3 watchdog.py auto-redispatch >&2 || true

WATCHDOG_ISSUES=$(python3 watchdog.py check 2>&1) || true
if [ -n "$WATCHDOG_ISSUES" ] && [ "$WATCHDOG_ISSUES" != "No issues detected." ]; then
  echo "[parallel] Watchdog: $WATCHDOG_ISSUES" >&2
  bash "$SCRIPT_DIR/notify.sh" "$WATCHDOG_ISSUES" || true
fi

# ── 2. Check control signal ─────────────────────────────
STATE=$(sqlite3 "$DB_PATH" "SELECT value FROM control WHERE key='global_state';")

case "$STATE" in
  stopped|stopping)
    echo "[parallel] State is '$STATE'. Exiting." >&2
    exit 0
    ;;
  paused)
    echo "[parallel] State is 'paused'. Sleeping." >&2
    exit 0
    ;;
  running)
    # continue
    ;;
  *)
    echo "[parallel] Unknown state '$STATE'. Treating as stopped." >&2
    exit 1
    ;;
esac

# ── 3. Get parallel batch ───────────────────────────────
BATCH_JSON=$(python3 task_picker.py next-batch --max "$MAX_WORKERS" 2>/dev/null) || true

if [ -z "$BATCH_JSON" ] || [ "$BATCH_JSON" = "[]" ] || [ "$BATCH_JSON" = "null" ]; then
  echo "[parallel] No ready tasks. Done." >&2
  exit 0
fi

# Parse task IDs from JSON array of objects
TASK_IDS=$(echo "$BATCH_JSON" | jq -r '.[].id')
TASK_COUNT=$(echo "$BATCH_JSON" | jq 'length')

echo "[parallel] Dispatching $TASK_COUNT tasks across workers..." >&2

# ── 4. Spawn workers ────────────────────────────────────
WORKER_IDX=0
for TASK_ID in $TASK_IDS; do
  WORKTREE=".worktrees/w${WORKER_IDX}"

  # Ensure worktree exists
  if [ ! -d "$WORKTREE" ]; then
    echo "[parallel] WARNING: Worktree $WORKTREE missing. Run setup-worktrees.sh first." >&2
  fi

  echo "[parallel] Worker $WORKER_IDX -> task $TASK_ID" >&2

  # Spawn worker in background
  (
    export WORKER_ID="$WORKER_IDX"

    # Record PID
    if [ -d "$WORKTREE" ]; then
      echo $$ > "${WORKTREE}/.worker.pid"
    fi

    # Run task
    RUN_EXIT=0
    bash "$SCRIPT_DIR/run-task.sh" "$TASK_ID" || RUN_EXIT=$?

    if [ "$RUN_EXIT" -eq 0 ]; then
      # Verify
      bash "$SCRIPT_DIR/verify-task.sh" "$TASK_ID" || true
    else
      echo "[worker-${WORKER_IDX}] run-task failed for $TASK_ID" >&2
    fi

    # Cleanup PID file
    if [ -d "$WORKTREE" ]; then
      rm -f "${WORKTREE}/.worker.pid"
    fi
  ) &

  WORKER_PIDS+=($!)
  WORKER_IDX=$((WORKER_IDX + 1))
done

# ── 5. Wait for all workers ─────────────────────────────
echo "[parallel] Waiting for $TASK_COUNT workers to finish..." >&2

FAILURES=0
for pid in "${WORKER_PIDS[@]}"; do
  if ! wait "$pid"; then
    FAILURES=$((FAILURES + 1))
  fi
done

echo "[parallel] All workers done. Failures: $FAILURES/$TASK_COUNT" >&2

# ── 6. Merge results ────────────────────────────────────
echo "[parallel] Running merge-results..." >&2
python3 merge-results.py >&2 || true

# ── 7. Notify ────────────────────────────────────────────
if [ "$FAILURES" -eq 0 ]; then
  bash "$SCRIPT_DIR/notify.sh" "Batch complete: $TASK_COUNT/$TASK_COUNT passed" || true
else
  bash "$SCRIPT_DIR/notify.sh" "Batch done: $FAILURES/$TASK_COUNT failed" || true
fi

# ── 8. Cooldown ──────────────────────────────────────────
COOLDOWN=$(sqlite3 "$DB_PATH" "SELECT value FROM control WHERE key='cooldown_sec';" 2>/dev/null) || COOLDOWN=30
echo "[parallel] Cooling down for ${COOLDOWN}s..." >&2
sleep "$COOLDOWN"

echo "[parallel] Round complete." >&2
