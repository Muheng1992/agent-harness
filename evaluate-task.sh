#!/bin/bash
# evaluate-task.sh — AI 評審員��證腳本
# 在 verify_cmd 通過後，用 Claude 做 AI 級品質審查
# 用法：./evaluate-task.sh TASK_ID
# Exit codes: 0=APPROVE, 1=REQUEST_CHANGES, 2=系統錯誤
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

TASK_ID="${1:?Usage: evaluate-task.sh TASK_ID}"
DB_PATH="db/agent.db"

# ── 1. 讀取任務資訊 ────────────────────────────────────────
TASK_JSON=$(python3 task_picker.py get "$TASK_ID" 2>/dev/null) || true
if [ -z "$TASK_JSON" ]; then
  echo "[evaluate] Task $TASK_ID not found, skipping." >&2
  echo "APPROVE"
  exit 0
fi

TASK_ROLE=$(echo "$TASK_JSON" | jq -r '.role // "unknown"')
PROJECT_DIR=$(echo "$TASK_JSON" | jq -r '.project_dir // empty')
GOAL=$(echo "$TASK_JSON" | jq -r '.goal')
TOUCHES=$(echo "$TASK_JSON" | jq -r '.touches // [] | .[]' 2>/dev/null) || TOUCHES=""

# ── 2. 檢查是否需要評估 ──────────────────────────────────
EVALUATE_ROLES=$(sqlite3 "$DB_PATH" "SELECT value FROM control WHERE key='evaluate_roles';" 2>/dev/null) || EVALUATE_ROLES="implementer,integrator"

# 檢查任務角色是否在評估清單中
if ! echo ",$EVALUATE_ROLES," | grep -q ",$TASK_ROLE,"; then
  echo "[evaluate] Role '$TASK_ROLE' not in evaluate_roles ($EVALUATE_ROLES), skipping." >&2
  echo "APPROVE"
  exit 0
fi

# ── 3. 讀取 evaluator 角色定義 ───────────────────────────
ROLE_FILE="${SCRIPT_DIR}/roles/evaluator.md"
EVAL_ROLE_PROMPT=""
if [ -f "$ROLE_FILE" ]; then
  EVAL_ROLE_PROMPT=$(sed '1,/^---$/d; 1,/^---$/d' "$ROLE_FILE") || true
fi

# ── 4. 讀取 project brief ────────────────────────────────
PROJECT_BRIEF=""
if [ -n "$PROJECT_DIR" ] && [ -f "${PROJECT_DIR}/.harness/project-brief.md" ]; then
  PROJECT_BRIEF=$(head -c 4000 "${PROJECT_DIR}/.harness/project-brief.md") || true
fi

# ── 5. 組裝 prompt ───────────────────────────────────────
TOUCHES_LIST=""
if [ -n "$TOUCHES" ]; then
  TOUCHES_LIST="以下是此任務修改的檔案��你必須 Read 每一���：
$(echo "$TOUCHES" | sed 's/^/- /')"
fi

EVAL_PROMPT="${EVAL_ROLE_PROMPT}

你正在審查任務 '${TASK_ID}' 的產出。

任務目標：
${GOAL}

${TOUCHES_LIST:+${TOUCHES_LIST}
}${PROJECT_BRIEF:+
PROJECT BRIEF（專案架構與決策）：
${PROJECT_BRIEF}
}
請 Read 上述檔案，然後輸出你的判定 JSON。"

# ── 6. 取得 timeout 設定 ─────────────────────────────────
EVAL_TIMEOUT=$(sqlite3 "$DB_PATH" "SELECT value FROM control WHERE key='evaluate_timeout';" 2>/dev/null) || EVAL_TIMEOUT=300

# ── 7. 決定工作目錄 ──────────────────────────────────────
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
  WORK_DIR="$PROJECT_DIR"
else
  WORK_DIR="$(pwd)"
fi

# ── 8. 執行 Claude 評估 ──────────────────────────────────
EVAL_OUTPUT_FILE="/tmp/eval-out-${TASK_ID}.txt"
EVAL_EXIT=0

cd "$WORK_DIR" && timeout "$EVAL_TIMEOUT" claude -p "$EVAL_PROMPT" \
  --allowedTools "Read,Grep,Glob,Bash" \
  --dangerously-skip-permissions \
  --output-format json \
  > "$EVAL_OUTPUT_FILE" 2>&1 || EVAL_EXIT=$?

cd "$SCRIPT_DIR"

# ── 9. 記錄 evaluator prompt + output 到 runs 表 ────────
EVAL_PROMPT_FILE="/tmp/eval-prompt-${TASK_ID}.txt"
printf '%s' "$EVAL_PROMPT" > "$EVAL_PROMPT_FILE"
python3 memory.py write "$TASK_ID" \
  --output-file "$EVAL_OUTPUT_FILE" \
  --prompt-file "$EVAL_PROMPT_FILE" \
  --worker-id -1 \
  --attempt 0 \
  --duration 0 \
  --status "running" 2>/dev/null || true

# ── 10. 解析判定結果 ─────────────────────────────────────
if [ "$EVAL_EXIT" -ne 0 ]; then
  echo "[evaluate] Claude 評估失敗 (exit=$EVAL_EXIT)，降級為 APPROVE" >&2
  python3 memory.py audit "$TASK_ID" \
    --event-type evaluator_verdict \
    --event-data "{\"verdict\":\"APPROVE\",\"reason\":\"claude_exit=$EVAL_EXIT\"}" \
    --actor evaluator 2>/dev/null || true
  echo "APPROVE"
  exit 0
fi

# 嘗試從 output 中提取 verdict JSON
VERDICT=""
if [ -f "$EVAL_OUTPUT_FILE" ]; then
  # Claude --output-format json 會包一層 {"result": "..."}，先解開
  RAW_TEXT=$(jq -r '.result // empty' "$EVAL_OUTPUT_FILE" 2>/dev/null) || RAW_TEXT=$(cat "$EVAL_OUTPUT_FILE")

  # 找 ```json ... ``` 中的 verdict
  VERDICT_JSON=$(echo "$RAW_TEXT" | grep -oP '```json\s*\n\K\{[^}]*"verdict"[^}]*\}' 2>/dev/null | head -1) || true

  if [ -z "$VERDICT_JSON" ]; then
    # 嘗試直接找含 verdict 的 JSON
    VERDICT_JSON=$(echo "$RAW_TEXT" | grep -oP '\{"verdict"\s*:\s*"[^"]+?"[^}]*\}' 2>/dev/null | head -1) || true
  fi

  if [ -n "$VERDICT_JSON" ]; then
    VERDICT=$(echo "$VERDICT_JSON" | jq -r '.verdict // empty' 2>/dev/null) || VERDICT=""
  fi
fi

# ── 10. 根據 verdict ���傳結果 ────────────────────���───────
case "$VERDICT" in
  APPROVE)
    echo "[evaluate] 評審員 APPROVE task $TASK_ID" >&2
    python3 memory.py audit "$TASK_ID" \
      --event-type evaluator_verdict \
      --event-data '{"verdict":"APPROVE"}' \
      --actor evaluator 2>/dev/null || true
    echo "APPROVE"
    exit 0
    ;;
  REQUEST_CHANGES)
    ISSUES=$(echo "$VERDICT_JSON" | jq -r '.issues // [] | join("; ")' 2>/dev/null) || ISSUES="未提供具體問題"
    echo "[evaluate] 評審員 REQUEST_CHANGES for $TASK_ID: $ISSUES" >&2
    python3 memory.py audit "$TASK_ID" \
      --event-type evaluator_verdict \
      --event-data "{\"verdict\":\"REQUEST_CHANGES\",\"issues\":\"$ISSUES\"}" \
      --actor evaluator 2>/dev/null || true
    echo "REQUEST_CHANGES: $ISSUES"
    exit 1
    ;;
  *)
    echo "[evaluate] 無法解析評審結果，降級為 APPROVE" >&2
    python3 memory.py audit "$TASK_ID" \
      --event-type evaluator_verdict \
      --event-data '{"verdict":"APPROVE","reason":"parse_failed"}' \
      --actor evaluator 2>/dev/null || true
    echo "APPROVE"
    exit 0
    ;;
esac
