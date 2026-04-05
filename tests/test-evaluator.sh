#!/bin/bash
# test-evaluator.sh — Evaluator 角色與 evaluate-task.sh 的整合測試
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TEST_DB="/tmp/test-evaluator-$$.db"
export AGENT_DB_PATH="$TEST_DB"

PASS=0
FAIL=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc"
    FAIL=$((FAIL + 1))
  fi
}

cleanup() {
  rm -f "$TEST_DB" "$TEST_DB-wal" "$TEST_DB-shm"
  rm -f /tmp/eval-out-eval-test*.txt
}
trap cleanup EXIT

echo "=== Evaluator 角色與腳本 測試 ==="

# ── 1. 初始化 DB ─────────────────────────────────────────
echo ""
echo "── 1. 初始化 ──"
sqlite3 "$TEST_DB" < schema.sql
sqlite3 "$TEST_DB" < migrations/003-add-features.sql 2>/dev/null || true
check "DB 初始化成功" test -f "$TEST_DB"

# ── 2. 角色定義檢查 ──────────────────────────────────────
echo ""
echo "── 2. 角色定義 ──"

check "evaluator.md 存在" test -f roles/evaluator.md
check "evaluator 使用唯讀工具" grep -q "allowed_tools: Read,Grep,Glob,Bash" roles/evaluator.md
check "evaluator 有 verdict 輸出格式" grep -q "verdict" roles/evaluator.md
check "evaluator 不允許 Write" bash -c "! sed -n '/allowed_tools/p' roles/evaluator.md | grep -q 'Write'"

# ── 3. 控制參數 ──────────────────────────────────────────
echo ""
echo "── 3. 控制參數 ──"

EVAL_ROLES=$(sqlite3 "$TEST_DB" "SELECT value FROM control WHERE key='evaluate_roles';")
check "evaluate_roles 預設包含 implementer" bash -c "echo '$EVAL_ROLES' | grep -q 'implementer'"
check "evaluate_roles 預設包含 integrator" bash -c "echo '$EVAL_ROLES' | grep -q 'integrator'"

EVAL_TIMEOUT=$(sqlite3 "$TEST_DB" "SELECT value FROM control WHERE key='evaluate_timeout';")
check "evaluate_timeout 預設為 300" test "$EVAL_TIMEOUT" = "300"

# ── 4. evaluate-task.sh 跳過非目標角色 ───────────────────
echo ""
echo "── 4. 角色過濾 ──"

# 建立 reviewer 角色的任務（不在 evaluate_roles 中）
sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, role) VALUES ('eval-test-1', 'test', 'review code', 'pass', 'reviewer');"

RESULT=$(bash evaluate-task.sh eval-test-1 2>/dev/null)
check "reviewer 角色被跳過 (APPROVE)" bash -c "[[ '$RESULT' == *APPROVE* ]]"

# 建立 tester 角色的任務
sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, role) VALUES ('eval-test-2', 'test', 'write tests', 'pass', 'tester');"

RESULT2=$(bash evaluate-task.sh eval-test-2 2>/dev/null)
check "tester 角色被跳過 (APPROVE)" bash -c "[[ '$RESULT2' == *APPROVE* ]]"

# 建立 alignment-checker 角色的任務
sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, role) VALUES ('eval-test-3', 'test', 'check alignment', 'pass', 'alignment-checker');"

RESULT3=$(bash evaluate-task.sh eval-test-3 2>/dev/null)
check "alignment-checker 角色被跳過 (APPROVE)" bash -c "[[ '$RESULT3' == *APPROVE* ]]"

# ── 5. evaluate-task.sh 對不存在的任務降級 ────────────────
echo ""
echo "── 5. 錯誤處理 ──"

RESULT4=$(bash evaluate-task.sh nonexistent-task 2>/dev/null)
check "不存在的任務降級為 APPROVE" bash -c "[[ '$RESULT4' == *APPROVE* ]]"

# ── 6. evaluate-task.sh 腳本語法正確 ─────────────────────
echo ""
echo "── 6. 腳本品質 ──"

check "evaluate-task.sh 語法正確" bash -n evaluate-task.sh
check "evaluate-task.sh 可執行" test -x evaluate-task.sh

# ── 7. healer 能識別 evaluator_reject ────────────────────
echo ""
echo "── 7. Healer 整合 ──"

sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, attempt_count, max_attempts) VALUES ('eval-test-heal', 'test', 'rejected task', 'fail', 1, 5);"
echo "EVALUATOR: REQUEST_CHANGES: missing error handling" > /tmp/test-eval-heal.txt

HEAL=$(python3 healer.py eval-test-heal /tmp/test-eval-heal.txt 2>/dev/null)
ERROR_CLS=$(sqlite3 "$TEST_DB" "SELECT error_class FROM tasks WHERE id='eval-test-heal';")
check "healer 分類為 evaluator_reject" test "$ERROR_CLS" = "evaluator_reject"

HEAL_PROMPT=$(echo "$HEAL" | jq -r '.extra_prompt // empty')
check "healer 的 extra_prompt 包含評審意見" bash -c "[[ '$HEAL_PROMPT' == *評審員* ]]"

rm -f /tmp/test-eval-heal.txt

# ── 結果 ──────────────────────────────────────────────
echo ""
echo "════════════════════════════════"
echo "結果: $PASS 通過, $FAIL 失敗"
echo "════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
