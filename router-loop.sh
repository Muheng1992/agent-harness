#!/bin/bash
# router-loop.sh — 自主開發的外層迴圈（Router 決策版）
# 替代 loop-orchestrator.sh，加入 Router 決策層。
# 每輪流程：安全檢查 → Router 決策 → 執行任務 → 驗證 → Roadmap 更新 → Git checkpoint → 冷卻
#
# 用法:
#   bash router-loop.sh --project my-project --dir /path/to/project
#   bash router-loop.sh --project my-compiler --dir /path/to/compiler \
#     --test-cmd 'make test' --max-rounds 100 --max-time 7200 --parallel
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

DB_PATH="db/agent.db"

# ── 預設參數 ─────────────────────────────────────────
PROJECT=""
PROJECT_DIR=""
TEST_CMD=""
MAX_ROUNDS=500
MAX_TIME=86400  # 24 小時
PARALLEL=0
CONFIG_FILE="router-config.yaml"

# ── 解析 CLI 參數 ────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)   PROJECT="$2";     shift 2 ;;
    --dir)       PROJECT_DIR="$2"; shift 2 ;;
    --test-cmd)  TEST_CMD="$2";    shift 2 ;;
    --max-rounds) MAX_ROUNDS="$2"; shift 2 ;;
    --max-time)  MAX_TIME="$2";    shift 2 ;;
    --config)    CONFIG_FILE="$2"; shift 2 ;;
    --parallel)  PARALLEL=1;       shift ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: router-loop.sh --project NAME --dir PATH [--test-cmd CMD] [--max-rounds N] [--max-time S] [--config FILE] [--parallel]" >&2
      exit 1 ;;
  esac
done

# ── 驗證必要參數 ─────────────────────────────────────
[[ -z "$PROJECT" ]]     && { echo "[router] Error: --project required" >&2; exit 1; }
[[ -z "$PROJECT_DIR" ]] && { echo "[router] Error: --dir required" >&2; exit 1; }
[[ ! -d "$PROJECT_DIR" ]] && { echo "[router] Error: --dir '$PROJECT_DIR' is not a directory" >&2; exit 1; }

# ── 檢查 router.py 是否存在 ─────────────────────────
[[ ! -f "$SCRIPT_DIR/router.py" ]] && { echo "[router] Error: router.py not found in $SCRIPT_DIR" >&2; exit 1; }

# ── 設定日誌 ─────────────────────────────────────────
mkdir -p "$SCRIPT_DIR/logs"
LOG_FILE="$SCRIPT_DIR/logs/router-$(date +%Y%m%d-%H%M%S).log"

# 同時輸出到 terminal 和 log file
exec > >(tee -a "$LOG_FILE") 2>&1

# ── 確保 DB 目錄存在 ─────────────────────────────────
mkdir -p "$SCRIPT_DIR/db"

# ── 選擇 orchestrator ────────────────────────────────
if [[ "$PARALLEL" -eq 1 ]]; then
  INNER="bash $SCRIPT_DIR/parallel-orchestrator.sh"
else
  INNER="bash $SCRIPT_DIR/orchestrator.sh"
fi

# ── 進度報告 helper ──────────────────────────────────
print_progress() {
  local pass fail pending escalated running
  pass=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE status='pass';" 2>/dev/null || echo 0)
  fail=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE status='fail';" 2>/dev/null || echo 0)
  pending=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE status='pending';" 2>/dev/null || echo 0)
  escalated=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE status='escalated';" 2>/dev/null || echo 0)
  running=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM tasks WHERE status='running';" 2>/dev/null || echo 0)
  echo "[router] Progress — pass:$pass  fail:$fail  pending:$pending  running:$running  escalated:$escalated"
}

# ── 主迴圈 ───────────────────────────────────────────
ROUND=0
START_EPOCH=$(date +%s)
CONSECUTIVE_IDLE=0
CHECKPOINT_INTERVAL=5

echo "[router] Starting autonomous development loop"
echo "[router] Project: $PROJECT @ $PROJECT_DIR"
echo "[router] Max: $MAX_ROUNDS rounds, ${MAX_TIME}s"
echo "[router] Config: $CONFIG_FILE | Parallel: $PARALLEL"
echo "[router] Log: $LOG_FILE"

while true; do
  ROUND=$((ROUND + 1))
  ELAPSED=$(( $(date +%s) - START_EPOCH ))

  # ── 安全限制：輪數 ──────────────────────────────────
  if (( ROUND > MAX_ROUNDS )); then
    echo "[router] Max rounds reached ($MAX_ROUNDS). Stopping."
    print_progress
    break
  fi

  # ── 安全限制：時間 ──────────────────────────────────
  if (( ELAPSED >= MAX_TIME )); then
    echo "[router] Max time reached (${MAX_TIME}s, elapsed ${ELAPSED}s). Stopping."
    print_progress
    break
  fi

  echo "[router] ── Round $ROUND (elapsed ${ELAPSED}s) ──"

  # ── 控制訊號 ────────────────────────────────────────
  STATE=$(sqlite3 "$DB_PATH" "SELECT value FROM control WHERE key='global_state';" 2>/dev/null || echo "running")
  case "$STATE" in
    paused)
      echo "[router] Paused. Waiting 30s..."
      sleep 30
      continue
      ;;
    stopped|stopping)
      echo "[router] Stopped by control signal."
      print_progress
      break
      ;;
  esac

  # ── Step 1: Router 決策 ─────────────────────────────
  echo "[router] Analyzing project state..."

  ROUTER_ARGS=(decide --project "$PROJECT" --dir "$PROJECT_DIR")
  if [[ -n "$TEST_CMD" ]]; then
    ROUTER_ARGS+=(--test-cmd "$TEST_CMD")
  fi

  DECISION_JSON=""
  if ! DECISION_JSON=$(python3 "$SCRIPT_DIR/router.py" "${ROUTER_ARGS[@]}" 2>&1); then
    echo "[router] Router error: $DECISION_JSON"
    echo "[router] Sleeping 60s before retry..."
    sleep 60
    continue
  fi

  # 解析決策 JSON
  ACTION=$(echo "$DECISION_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action','ERROR'))" 2>/dev/null || echo "ERROR")
  REASON=$(echo "$DECISION_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason',''))" 2>/dev/null || echo "")

  echo "[router] Decision: $ACTION — $REASON"

  # ── Step 2: 根據決策行動 ────────────────────────────
  case "$ACTION" in
    IDLE)
      CONSECUTIVE_IDLE=$((CONSECUTIVE_IDLE + 1))
      if (( CONSECUTIVE_IDLE >= 3 )); then
        echo "[router] 連續 3 次 IDLE，結束。"
        print_progress
        break
      fi
      echo "[router] Nothing to do. Sleeping 60s... (idle streak: $CONSECUTIVE_IDLE/3)"
      sleep 60
      continue
      ;;
    ESCALATE)
      echo "[router] ESCALATE: $REASON"
      bash "$SCRIPT_DIR/notify.sh" "Router ESCALATE: $REASON" || true
      print_progress
      break
      ;;
    FIX|BUILD|REFACTOR|EXPLORE)
      CONSECUTIVE_IDLE=0
      ;;
    ERROR)
      echo "[router] Failed to parse router decision. Sleeping 30s..."
      sleep 30
      continue
      ;;
    *)
      echo "[router] Unknown action: $ACTION. Sleeping 30s..."
      sleep 30
      continue
      ;;
  esac

  # ── Step 3: 執行任務 ────────────────────────────────
  # Router 已經把任務寫入 DB，現在跑 orchestrator
  echo "[router] Executing tasks..."
  INNER_EXIT=0
  $INNER || INNER_EXIT=$?

  if [[ "$INNER_EXIT" -eq 2 ]]; then
    echo "[router] Orchestrator signalled paused/stopped."
    print_progress
    break
  fi

  # ── Step 4: 更新 Roadmap ────────────────────────────
  FEATURE_ID=$(echo "$DECISION_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('feature_id',''))" 2>/dev/null || echo "")
  if [[ -n "$FEATURE_ID" && "$ACTION" == "BUILD" ]]; then
    ALL_PASS=$(sqlite3 "$DB_PATH" \
      "SELECT COUNT(*)=0 FROM tasks WHERE goal LIKE '%${FEATURE_ID}%' AND status != 'pass';" 2>/dev/null || echo "0")
    if [[ "$ALL_PASS" == "1" ]]; then
      ROADMAP_FILE="$PROJECT_DIR/roadmap.yaml"
      if [[ -f "$ROADMAP_FILE" ]]; then
        python3 "$SCRIPT_DIR/roadmap.py" mark-done "$ROADMAP_FILE" "$FEATURE_ID" 2>/dev/null || true
        echo "[router] Roadmap: marked $FEATURE_ID as done"
      fi
    fi
  fi

  # ── Step 5: Pipeline 推進 ───────────────────────────
  ACTIVE_PIPELINES=$(sqlite3 "$DB_PATH" "SELECT id FROM pipelines WHERE status='active';" 2>/dev/null || true)
  if [[ -n "$ACTIVE_PIPELINES" ]]; then
    echo "$ACTIVE_PIPELINES" | while IFS= read -r PID; do
      python3 "$SCRIPT_DIR/pipeline.py" advance "$PID" 2>&1 || true
    done
    echo "[router] Pipeline advancement complete"
  fi

  # ── Step 6: Git Checkpoint ──────────────────────────
  if (( ROUND % CHECKPOINT_INTERVAL == 0 )); then
    (
      cd "$PROJECT_DIR"
      git add -A && git commit -m "router: checkpoint round $ROUND" --allow-empty 2>/dev/null || true
      git tag "router-checkpoint-${ROUND}-$(date +%s)" 2>/dev/null || true
    )
    echo "[router] Git checkpoint created (round $ROUND)"
  fi

  # ── Step 7: 進度報告 ────────────────────────────────
  print_progress

  # ── Step 8: 智慧冷卻 ────────────────────────────────
  case "$ACTION" in
    FIX)      sleep 10 ;;
    REFACTOR) sleep 10 ;;
    BUILD)    sleep 5 ;;
    EXPLORE)  sleep 5 ;;
    *)        sleep 5 ;;
  esac
done

ELAPSED=$(( $(date +%s) - START_EPOCH ))
echo "[router] Autonomous loop finished. $ROUND rounds in ${ELAPSED}s."
bash "$SCRIPT_DIR/notify.sh" "Router finished: $ROUND rounds in ${ELAPSED}s" || true
