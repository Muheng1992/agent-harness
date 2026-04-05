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

python3 watchdog.py check-blocked >&2 || true
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
  # Call healer to classify error (ensures error_class is set for Claude crashes too)
  OUTPUT_FILE="/tmp/claude-out-${TASK_ID}.txt"
  if [ -f "$OUTPUT_FILE" ]; then
    python3 healer.py "$TASK_ID" "$OUTPUT_FILE" >&2 || true
  fi
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
  # ── 6a. AI 評審員驗證 ──────────────────────────────────
  EVAL_EXIT=0
  EVAL_RESULT=$(bash "$SCRIPT_DIR/evaluate-task.sh" "$TASK_ID" 2>&1) || EVAL_EXIT=$?

  if [ "$EVAL_EXIT" -ne 0 ] && ! echo "$EVAL_RESULT" | grep -q "APPROVE"; then
    # 評審員要求修改 — 標記為失敗並附上評審意見
    echo "[orchestrator] Evaluator REQUEST_CHANGES for $TASK_ID: $EVAL_RESULT" >&2
    python3 task_picker.py record-failure "$TASK_ID" "EVALUATOR: $EVAL_RESULT"
    bash "$SCRIPT_DIR/notify.sh" "Task $TASK_ID: 評審員要求修改" --level error || true
  else
    echo "[orchestrator] Task $TASK_ID PASSED (evaluator approved)." >&2
    python3 merge-results.py >&2 || true
    bash "$SCRIPT_DIR/notify.sh" "Task $TASK_ID passed" --level success || true

    # ── 6b. 對齊檢查相關處理 ─────────────────────────────
    PASS_TASK_JSON=$(python3 task_picker.py get "$TASK_ID" 2>/dev/null) || true
    TASK_ROLE=$(echo "$PASS_TASK_JSON" | jq -r '.role // ""' 2>/dev/null) || TASK_ROLE=""
    TASK_PROJECT=$(echo "$PASS_TASK_JSON" | jq -r '.project // ""' 2>/dev/null) || TASK_PROJECT=""

    # 如果通過���是 alignment-checker 任務，套用修正
    if [ "$TASK_ROLE" = "alignment-checker" ]; then
      echo "[orchestrator] 套用對齊檢查修正..." >&2
      python3 alignment-check.py apply "$TASK_ID" >&2 || true
    fi

    # 檢查是否需要注入新的對齊檢查
    python3 alignment-check.py check --auto-inject ${TASK_PROJECT:+--project "$TASK_PROJECT"} >&2 || true
  fi
else
  echo "[orchestrator] Task $TASK_ID FAILED." >&2

  # Check if task was escalated (watchdog.py handles escalation automatically)
  TASK_JSON=$(python3 task_picker.py get "$TASK_ID" 2>/dev/null) || true
  STATUS=$(echo "$TASK_JSON" | jq -r '.status // "unknown"' 2>/dev/null) || STATUS="unknown"
  ATTEMPT=$(echo "$TASK_JSON" | jq -r '.attempt_count // 0' 2>/dev/null) || ATTEMPT=0
  MAX=$(echo "$TASK_JSON" | jq -r '.max_attempts // 5' 2>/dev/null) || MAX=5

  if [ "$STATUS" = "escalated" ] || [ "$ATTEMPT" -ge "$MAX" ]; then
    echo "[orchestrator] Task $TASK_ID escalated after $ATTEMPT attempts." >&2
    bash "$SCRIPT_DIR/notify.sh" "Task $TASK_ID ESCALATED after $ATTEMPT failures" --level escalated || true
  else
    echo "[orchestrator] Task $TASK_ID will retry (attempt $ATTEMPT/$MAX)." >&2
    bash "$SCRIPT_DIR/notify.sh" "Task $TASK_ID failed (attempt $ATTEMPT/$MAX), retrying..." --level error || true

    # ── 策略輪替：讀取 healer 的修復策略 ──────────────
    HEAL_JSON=""
    OUTPUT_FILE="/tmp/claude-out-${TASK_ID}.txt"
    if [ -f "$OUTPUT_FILE" ]; then
      HEAL_JSON=$(python3 healer.py "$TASK_ID" "$OUTPUT_FILE" 2>/dev/null) || HEAL_JSON=""
    fi

    HEAL_ACTION=$(echo "$HEAL_JSON" | jq -r '.action // empty' 2>/dev/null) || HEAL_ACTION=""

    # 記錄 healer 決策到 audit log
    if [ -n "$HEAL_ACTION" ]; then
      python3 memory.py audit "$TASK_ID" \
        --event-type healer_decision \
        --event-data "$HEAL_JSON" \
        --actor healer 2>/dev/null || true
    fi

    if [ "$HEAL_ACTION" = "retry_with_role_switch" ]; then
      OLD_ROLE=$(echo "$TASK_JSON" | jq -r '.role // "unknown"' 2>/dev/null) || OLD_ROLE="unknown"
      NEW_ROLE=$(echo "$HEAL_JSON" | jq -r '.new_role // "debugger"')
      sqlite3 "$DB_PATH" "UPDATE tasks SET role='${NEW_ROLE}', updated_at=datetime('now') WHERE id='${TASK_ID}';"
      echo "[orchestrator] 角色切換: $TASK_ID -> $NEW_ROLE" >&2
      # 記錄角色切換到 audit log
      python3 memory.py audit "$TASK_ID" \
        --event-type role_switch \
        --event-data "{\"from\":\"$OLD_ROLE\",\"to\":\"$NEW_ROLE\",\"reason\":\"looping\",\"attempt\":$ATTEMPT}" \
        --actor orchestrator 2>/dev/null || true
    elif [ "$HEAL_ACTION" = "spawn_research" ]; then
      python3 task_picker.py spawn-subtasks --parent "$TASK_ID" \
        --subtasks "[{\"id\":\"${TASK_ID}-research\",\"goal\":\"研究 ${TASK_ID} 反覆失敗的根因。閱讀相關程式碼和錯誤訊息，分析錯誤模式並提出具體解決方案。\",\"role\":\"researcher\",\"max_attempts\":2}]" \
        2>&1 >&2 || true
      echo "[orchestrator] 已生成研究子任務 ${TASK_ID}-research" >&2
      # 記錄 spawn 到 audit log
      python3 memory.py audit "$TASK_ID" \
        --event-type spawn_research \
        --event-data "{\"spawned\":\"${TASK_ID}-research\",\"reason\":\"looping\",\"attempt\":$ATTEMPT}" \
        --actor orchestrator 2>/dev/null || true
    fi
  fi
fi

# ── Pipeline Advance ───────────────────────────────
# 檢查所有 active pipeline，推進到下一階段
ACTIVE_PIPELINES=$(sqlite3 "$DB_PATH" "SELECT id FROM pipelines WHERE status='active';" 2>/dev/null || true)
if [ -n "$ACTIVE_PIPELINES" ]; then
  echo "$ACTIVE_PIPELINES" | while IFS= read -r PID; do
    python3 pipeline.py advance "$PID" 2>&1 || true
  done
  echo "[orchestrator] Pipeline advancement complete" >&2
fi

echo "[orchestrator] Round complete." >&2
