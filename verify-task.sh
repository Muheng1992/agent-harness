#!/bin/bash
# verify-task.sh — Run verification for a completed task
# Usage: ./verify-task.sh TASK_ID
# Env: WORKER_ID (optional, defaults to 0)
# Exit codes: 0=pass, 1=fail, 2=system error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

TASK_ID="${1:?Usage: verify-task.sh TASK_ID}"
WORKER_ID="${WORKER_ID:-0}"
DB_PATH="db/agent.db"
VERIFY_OUTPUT_FILE="/tmp/verify-out-${TASK_ID}.txt"

# ── 1. Get verify command ────────────────────────────────
VERIFY_CMD=$(python3 task_picker.py get-verify "$TASK_ID")

if [ -z "$VERIFY_CMD" ] || [ "$VERIFY_CMD" = "null" ] || [ "$VERIFY_CMD" = "None" ]; then
  echo "[verify] No verify command for task $TASK_ID, marking as pass." >&2
  python3 task_picker.py mark-pass "$TASK_ID"
  echo "PASS"
  exit 0
fi

echo "[verify] Verifying task $TASK_ID: $VERIFY_CMD" >&2

# ── 2. Determine working directory ──────────────────────
# Read project_dir from task if available
PROJECT_DIR=$(python3 task_picker.py get "$TASK_ID" 2>/dev/null | jq -r '.project_dir // empty') || true

if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
  # 跨專案模式：在目標專案目錄驗證
  WORK_DIR="$PROJECT_DIR"
  echo "[verify] Working in target project: $WORK_DIR" >&2
elif [ "$WORKER_ID" -gt 0 ] && [ -d ".worktrees/w${WORKER_ID}" ]; then
  WORK_DIR=".worktrees/w${WORKER_ID}"
else
  WORK_DIR="."
fi

# ── 3. Run verify command, capture output to file ───────
VERIFY_EXIT=0
(cd "$WORK_DIR" && eval "$VERIFY_CMD") > "$VERIFY_OUTPUT_FILE" 2>&1 || VERIFY_EXIT=$?

# Print output to stderr for logging
cat "$VERIFY_OUTPUT_FILE" >&2

# ── 4. Handle result ────────────────────────────────────
if [ "$VERIFY_EXIT" -eq 0 ]; then
  python3 task_picker.py mark-pass "$TASK_ID"
  echo "PASS"
else
  # Record failure with output text
  FAILURE_TEXT=$(head -c 2000 "$VERIFY_OUTPUT_FILE")
  python3 task_picker.py record-failure "$TASK_ID" "$FAILURE_TEXT"

  # Consult healer for retry strategy (requires task_id + failure file path)
  HEAL_OUTPUT=$(python3 healer.py "$TASK_ID" "$VERIFY_OUTPUT_FILE" 2>&1) || true
  echo "[verify] Healer strategy: $HEAL_OUTPUT" >&2

  echo "FAIL"
  exit 1
fi
