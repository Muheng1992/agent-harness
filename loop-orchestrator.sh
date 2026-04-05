#!/bin/bash
# loop-orchestrator.sh — Outer loop that runs orchestrator rounds until DAG is complete
# Handles smart cooldown (rate_limit awareness), safety limits, and progress reporting.
# Usage: bash loop-orchestrator.sh [--parallel] [--max-rounds N] [--max-time M]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

DB_PATH="db/agent.db"

# ── Defaults ──────────────────────────────────────────
PARALLEL=0
MAX_ROUNDS=500
MAX_TIME=86400  # 24 hours

# ── Parse arguments ───────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --parallel)
      PARALLEL=1; shift ;;
    --max-rounds)
      MAX_ROUNDS="$2"; shift 2 ;;
    --max-time)
      MAX_TIME="$2"; shift 2 ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: loop-orchestrator.sh [--parallel] [--max-rounds N] [--max-time M]" >&2
      exit 1 ;;
  esac
done

# ── Select inner orchestrator ─────────────────────────
if [ "$PARALLEL" -eq 1 ]; then
  INNER="bash $SCRIPT_DIR/parallel-orchestrator.sh"
else
  INNER="bash $SCRIPT_DIR/orchestrator.sh"
fi

# ── Progress helper ───────────────────────────────────
print_progress() {
  local pass fail pending escalated running
  pass=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE status='pass';")
  fail=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE status='fail';")
  pending=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE status='pending';")
  escalated=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE status='escalated';")
  running=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE status='running';")
  echo "[loop] Progress — pass:$pass  fail:$fail  pending:$pending  running:$running  escalated:$escalated" >&2
}

# ── Remaining tasks helper ────────────────────────────
remaining_count() {
  sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE status IN ('pending','running','fail','blocked');"
}

# ── Smart cooldown helper ─────────────────────────────
compute_cooldown() {
  # Check latest error_class from recently failed tasks
  local latest_error
  latest_error=$(sqlite3 "$DB_PATH" \
    "SELECT error_class FROM tasks WHERE error_class IS NOT NULL ORDER BY updated_at DESC LIMIT 1;" \
    2>/dev/null) || latest_error=""

  if [ "$latest_error" = "rate_limit" ]; then
    echo 120
    return
  fi

  # Check if there was any failure in this round
  local fail_count
  fail_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE status='fail';")

  if [ "$fail_count" -gt 0 ]; then
    # Use DB control.cooldown_sec
    local db_cooldown
    db_cooldown=$(sqlite3 "$DB_PATH" "SELECT value FROM control WHERE key='cooldown_sec';" 2>/dev/null) || db_cooldown=30
    echo "$db_cooldown"
    return
  fi

  # No failures — short cooldown
  echo 5
}

# ── Web Dashboard ────────────────────────────────────
WEB_DASHBOARD_PID=""
WEB_DASHBOARD_PORT=8745

start_web_dashboard() {
  local dashboard_script="$SCRIPT_DIR/web-dashboard"
  # 檢查 web-dashboard 是否存在
  if [ ! -f "$dashboard_script" ] && [ ! -d "$dashboard_script" ]; then
    return
  fi
  # 檢查 port 是否已被佔用
  if lsof -i :"$WEB_DASHBOARD_PORT" >/dev/null 2>&1; then
    echo "[loop] Web Dashboard port $WEB_DASHBOARD_PORT 已被佔用，跳過啟動" >&2
    return
  fi
  python3 "$dashboard_script" --port "$WEB_DASHBOARD_PORT" >/dev/null 2>&1 &
  WEB_DASHBOARD_PID=$!
  echo "[loop] Web Dashboard 已啟動：http://localhost:$WEB_DASHBOARD_PORT" >&2
  open "http://localhost:$WEB_DASHBOARD_PORT" 2>/dev/null || true
}

stop_web_dashboard() {
  if [ -n "$WEB_DASHBOARD_PID" ]; then
    kill "$WEB_DASHBOARD_PID" 2>/dev/null || true
    WEB_DASHBOARD_PID=""
  fi
}

trap stop_web_dashboard EXIT INT TERM

start_web_dashboard

# ── Main loop ─────────────────────────────────────────
ROUND=0
START_EPOCH=$(date +%s)

echo "[loop] Starting loop-orchestrator (max-rounds=$MAX_ROUNDS, max-time=${MAX_TIME}s, parallel=$PARALLEL)" >&2

while true; do
  ROUND=$((ROUND + 1))

  # ── Safety: max rounds ──────────────────────────────
  if [ "$ROUND" -gt "$MAX_ROUNDS" ]; then
    echo "[loop] WARNING: Reached max rounds ($MAX_ROUNDS). Stopping." >&2
    print_progress
    exit 1
  fi

  # ── Safety: max time ────────────────────────────────
  NOW_EPOCH=$(date +%s)
  ELAPSED=$((NOW_EPOCH - START_EPOCH))
  if [ "$ELAPSED" -ge "$MAX_TIME" ]; then
    echo "[loop] WARNING: Reached max time (${MAX_TIME}s, elapsed ${ELAPSED}s). Stopping." >&2
    print_progress
    exit 1
  fi

  # ── Check remaining tasks ───────────────────────────
  REMAINING=$(remaining_count)
  if [ "$REMAINING" -eq 0 ]; then
    echo "[loop] All tasks completed! (${ROUND} rounds, ${ELAPSED}s elapsed)" >&2
    print_progress
    bash "$SCRIPT_DIR/notify.sh" "所有任務已完成！共 ${ROUND} 輪，耗時 ${ELAPSED}s" --level done || true
    exit 0
  fi

  echo "[loop] ── Round $ROUND (remaining=$REMAINING, elapsed=${ELAPSED}s) ──" >&2

  # ── Run inner orchestrator ──────────────────────────
  INNER_EXIT=0
  $INNER || INNER_EXIT=$?

  if [ "$INNER_EXIT" -eq 2 ]; then
    echo "[loop] Orchestrator signalled paused/stopped. Exiting loop." >&2
    print_progress
    exit 2
  fi

  # ── Progress report ─────────────────────────────────
  print_progress

  # ── Check again after round (tasks may have all passed) ──
  REMAINING=$(remaining_count)
  if [ "$REMAINING" -eq 0 ]; then
    echo "[loop] All tasks completed! (${ROUND} rounds, ${ELAPSED}s elapsed)" >&2
    bash "$SCRIPT_DIR/notify.sh" "所有任務已完成！共 ${ROUND} 輪，耗時 ${ELAPSED}s" --level done || true
    exit 0
  fi

  # ── Pipeline Advance ───────────────────────────────
  # 檢查所有 active pipeline，推進到下一階段
  ACTIVE_PIPELINES=$(sqlite3 "$DB_PATH" "SELECT id FROM pipelines WHERE status='active';" 2>/dev/null || true)
  if [ -n "$ACTIVE_PIPELINES" ]; then
    echo "$ACTIVE_PIPELINES" | while IFS= read -r PID; do
      python3 pipeline.py advance "$PID" 2>&1 || true
    done
    echo "[loop] Pipeline advancement complete" >&2
  fi

  # ── Smart cooldown ──────────────────────────────────
  COOLDOWN=$(compute_cooldown)
  echo "[loop] Cooling down for ${COOLDOWN}s..." >&2
  sleep "$COOLDOWN"
done
