#!/bin/bash
# test-alignment-check.sh — 對齊檢查整合測試
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TEST_DB="/tmp/test-alignment-$$.db"
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
}
trap cleanup EXIT

echo "=== 對齊檢查 測試 ==="

# ── 1. 初始化 DB ─────────────────────────────────────────
echo ""
echo "── 1. 初始化 ──"
sqlite3 "$TEST_DB" < schema.sql
sqlite3 "$TEST_DB" < migrations/003-add-features.sql 2>/dev/null || true
check "DB 初始化成功" test -f "$TEST_DB"

# ── 2. 角色定義檢查 ──────────────────────────────────────
echo ""
echo "── 2. 角色定義 ──"

check "alignment-checker.md 存在" test -f roles/alignment-checker.md
check "alignment-checker 使用唯讀工具" grep -q "allowed_tools: Read,Grep,Glob,Bash" roles/alignment-checker.md
check "alignment-checker 有 alignment 輸出格式" grep -q "ON_TRACK" roles/alignment-checker.md

# ── 3. should_run — 不足 interval 回傳 NO ────────────────
echo ""
echo "── 3. should_run 判斷 ──"

# 只有 3 個通過的任務（interval=5）
for i in 1 2 3; do
  sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, role) VALUES ('at-$i', 'test', 'task $i', 'pass', 'implementer');"
done

RESULT=$(python3 alignment-check.py check 2>/dev/null)
check "3 個通過 < interval 5 → NO" bash -c "[[ '$RESULT' == *NO* ]]"

# 再加 2 個達到 5
for i in 4 5; do
  sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, role) VALUES ('at-$i', 'test', 'task $i', 'pass', 'implementer');"
done

RESULT2=$(python3 alignment-check.py check 2>/dev/null)
check "5 個通過 >= interval 5 → YES" bash -c "[[ '$RESULT2' == *YES* ]]"

# ── 4. inject — 建立 alignment-check 任務 ────────────────
echo ""
echo "── 4. inject ──"

INJECT_RESULT=$(python3 alignment-check.py inject --project test 2>/dev/null)
check "inject 成功建立任務" bash -c "[[ '$INJECT_RESULT' == *alignment-check-* ]]"

# 確認任務在 DB 中
AC_COUNT=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM tasks WHERE role='alignment-checker';")
check "DB 中有 alignment-checker 任務" test "$AC_COUNT" -ge 1

AC_TASK=$(sqlite3 "$TEST_DB" "SELECT id FROM tasks WHERE role='alignment-checker' LIMIT 1;")
AC_STATUS=$(sqlite3 "$TEST_DB" "SELECT status FROM tasks WHERE id='$AC_TASK';")
check "alignment-check 任務狀態為 pending" test "$AC_STATUS" = "pending"

AC_DEPS=$(sqlite3 "$TEST_DB" "SELECT depends_on FROM tasks WHERE id='$AC_TASK';")
check "alignment-check 無依賴" test "$AC_DEPS" = "[]"

AC_TOUCHES=$(sqlite3 "$TEST_DB" "SELECT touches FROM tasks WHERE id='$AC_TASK';")
check "alignment-check 不修改檔案" test "$AC_TOUCHES" = "[]"

# ── 5. inject 防重複 ─────────────────────────────────────
echo ""
echo "── 5. 防重複 ──"

INJECT2=$(python3 alignment-check.py inject --project test 2>/dev/null)
check "1 分鐘內重複 inject 被跳過" bash -c "[[ '$INJECT2' == *跳過* ]]"

# ── 6. should_run — 上次 check 後重新計算 ────────────────
echo ""
echo "── 6. 上次 check 後重新計算 ──"

RESULT3=$(python3 alignment-check.py check 2>/dev/null)
check "inject 後重新檢查回傳 NO（計數歸零）" bash -c "[[ '$RESULT3' == *NO* ]]"

# ── 7. apply — 套用修正 ──────────────────────────────────
echo ""
echo "── 7. apply 修正 ──"

# 模擬 alignment-check 任務完成，寫入假 output
sqlite3 "$TEST_DB" "UPDATE tasks SET status='pass' WHERE id='$AC_TASK';"

# 建立一個待修改的 pending 任務
sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status) VALUES ('target-task', 'test', 'old goal', 'pending');"

# 模擬 Claude output with corrections
MOCK_OUTPUT='{"result": "分析完成。\n```json\n{\"alignment\": \"DRIFTING\", \"drift_areas\": [\"naming convention\"], \"corrections\": [{\"type\": \"modify_goal\", \"task_id\": \"target-task\", \"new_goal\": \"updated goal with corrections\"}, {\"type\": \"flag\", \"description\": \"需要注意命名規範\"}]}\n```"}'

sqlite3 "$TEST_DB" "INSERT INTO runs (task_id, worker_id, attempt, status, claude_output) VALUES ('$AC_TASK', 0, 1, 'pass', '$MOCK_OUTPUT');"

APPLY_RESULT=$(python3 alignment-check.py apply "$AC_TASK" 2>/dev/null)
check "apply 回報修正數量" bash -c "[[ '$APPLY_RESULT' == *已套用* ]]"

# 確認 goal 被修改
NEW_GOAL=$(sqlite3 "$TEST_DB" "SELECT goal FROM tasks WHERE id='target-task';")
check "目標任務 goal 被修改" bash -c "[[ '$NEW_GOAL' == *updated*goal* ]]"

# ── 8. apply — ON_TRACK 不做修正 ─────────────────────────
echo ""
echo "── 8. ON_TRACK 不修正 ──"

sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, role) VALUES ('ac-ok', 'test', 'check', 'pass', 'alignment-checker');"
MOCK_OK='{"result": "```json\n{\"alignment\": \"ON_TRACK\", \"drift_areas\": [], \"corrections\": []}\n```"}'
sqlite3 "$TEST_DB" "INSERT INTO runs (task_id, worker_id, attempt, status, claude_output) VALUES ('ac-ok', 0, 1, 'pass', '$MOCK_OK');"

APPLY2=$(python3 alignment-check.py apply ac-ok 2>/dev/null)
check "ON_TRACK 回報 0 修正" bash -c "[[ '$APPLY2' == *0* ]]"

# ── 9. alignment-check.py 語法正確 ───────────────────────
echo ""
echo "── 9. 腳本品質 ──"

check "alignment-check.py 語法正確" python3 -c "import py_compile; py_compile.compile('alignment-check.py', doraise=True)"

# ── 結果 ──────────────────────────────────────────────
echo ""
echo "════════════════════════════════"
echo "結果: $PASS 通過, $FAIL 失敗"
echo "════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
