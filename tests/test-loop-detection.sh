#!/bin/bash
# test-loop-detection.sh — 迴圈偵測 + 策略輪替的整合測試
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TEST_DB="/tmp/test-loop-detection-$$.db"
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
  rm -f /tmp/handoff-loop-test*.json
}
trap cleanup EXIT

echo "=== 迴圈偵測 + 策略輪替 測試 ==="

# ── 1. 初始化 DB ─────────────────────────────────────────
echo ""
echo "── 1. 初始化 ──"
sqlite3 "$TEST_DB" < schema.sql
sqlite3 "$TEST_DB" < migrations/003-add-features.sql 2>/dev/null || true
check "DB 初始化成功" test -f "$TEST_DB"

# 確認 output_fingerprint 欄位存在
check "runs 表有 output_fingerprint 欄位" \
  sqlite3 "$TEST_DB" "SELECT output_fingerprint FROM runs LIMIT 0;"

# 確認控制參數存在
check "evaluate_roles 控制參數" \
  test "$(sqlite3 "$TEST_DB" "SELECT value FROM control WHERE key='evaluate_roles';")" = "implementer,integrator"
check "alignment_interval 控制參數" \
  test "$(sqlite3 "$TEST_DB" "SELECT value FROM control WHERE key='alignment_interval';")" = "5"

# ── 2. 測試 fingerprint 計算 ────────────────────────────
echo ""
echo "── 2. Fingerprint 計算 ──"

# 相同內容 → 相同 fingerprint
FP1=$(python3 -c "from memory import compute_output_fingerprint; print(compute_output_fingerprint('hello world test output'))")
FP2=$(python3 -c "from memory import compute_output_fingerprint; print(compute_output_fingerprint('hello world test output'))")
check "相同輸入產生相同 fingerprint" test "$FP1" = "$FP2"

# 不同內容 → 不同 fingerprint
FP3=$(python3 -c "from memory import compute_output_fingerprint; print(compute_output_fingerprint('completely different output'))")
check "不同輸入產生不同 fingerprint" test "$FP1" != "$FP3"

# 只有時間戳不同 → 相同 fingerprint（正規化生效）
FP4=$(python3 -c "from memory import compute_output_fingerprint; print(compute_output_fingerprint('built at 2024-01-01T10:00:00 success'))")
FP5=$(python3 -c "from memory import compute_output_fingerprint; print(compute_output_fingerprint('built at 2025-12-31T23:59:59 success'))")
check "時間戳正規化後 fingerprint 相同" test "$FP4" = "$FP5"

# fingerprint 長度為 32 字元
check "fingerprint 長度為 32" test ${#FP1} -eq 32

# ── 3. 測試 write_run 存 fingerprint ───────────────────
echo ""
echo "── 3. Write Run + Fingerprint ──"

# 建立測試任務
sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, attempt_count, max_attempts) VALUES ('loop-test-1', 'test', 'test goal', 'running', 0, 5);"

echo "test output content" > /tmp/test-loop-output.txt
python3 memory.py write loop-test-1 \
  --output-file /tmp/test-loop-output.txt \
  --worker-id 0 --attempt 1 --duration 10 --status running
rm -f /tmp/test-loop-output.txt

STORED_FP=$(sqlite3 "$TEST_DB" "SELECT output_fingerprint FROM runs WHERE task_id='loop-test-1' ORDER BY id DESC LIMIT 1;")
check "write_run 存入 fingerprint" test -n "$STORED_FP"

# ── 4. 測試迴圈偵測 ────────────────────────────────────
echo ""
echo "── 4. 迴圈偵測 ──"

# 建立一個失敗任務，寫入 2 次相同的 output
sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, attempt_count, max_attempts) VALUES ('loop-test-2', 'test', 'looping task', 'fail', 3, 5);"

SAME_OUTPUT="same failure output every time"
SAME_FP=$(python3 -c "from memory import compute_output_fingerprint; print(compute_output_fingerprint('$SAME_OUTPUT'))")

sqlite3 "$TEST_DB" "INSERT INTO runs (task_id, worker_id, attempt, status, output_fingerprint, claude_output) VALUES ('loop-test-2', 0, 1, 'fail', '$SAME_FP', '$SAME_OUTPUT');"
sqlite3 "$TEST_DB" "INSERT INTO runs (task_id, worker_id, attempt, status, output_fingerprint, claude_output) VALUES ('loop-test-2', 0, 2, 'fail', '$SAME_FP', '$SAME_OUTPUT');"

# 執行偵測
LOOP_RESULT=$(python3 watchdog.py check-looping 2>&1)
check "偵測到迴圈任務" bash -c "echo '$LOOP_RESULT' | grep -q 'LOOPING'"

# 確認 error_class 被設為 looping
ERROR_CLASS=$(sqlite3 "$TEST_DB" "SELECT error_class FROM tasks WHERE id='loop-test-2';")
check "error_class 設為 looping" test "$ERROR_CLASS" = "looping"

# 確認 max_attempts 被降低
NEW_MAX=$(sqlite3 "$TEST_DB" "SELECT max_attempts FROM tasks WHERE id='loop-test-2';")
check "max_attempts 被降低" test "$NEW_MAX" -le 4

# ── 5. 測試非迴圈任務不被誤判 ─────────────────────────
echo ""
echo "── 5. 非迴圈任務 ──"

sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, attempt_count, max_attempts) VALUES ('loop-test-3', 'test', 'normal task', 'fail', 2, 5);"

FP_A=$(python3 -c "from memory import compute_output_fingerprint; print(compute_output_fingerprint('first attempt output'))")
FP_B=$(python3 -c "from memory import compute_output_fingerprint; print(compute_output_fingerprint('second different output'))")

sqlite3 "$TEST_DB" "INSERT INTO runs (task_id, worker_id, attempt, status, output_fingerprint, claude_output) VALUES ('loop-test-3', 0, 1, 'fail', '$FP_A', 'first');"
sqlite3 "$TEST_DB" "INSERT INTO runs (task_id, worker_id, attempt, status, output_fingerprint, claude_output) VALUES ('loop-test-3', 0, 2, 'fail', '$FP_B', 'second');"

LOOP_RESULT2=$(python3 watchdog.py check-looping 2>&1)
check "不同 output 的任務不被標為 looping" bash -c "! echo '$LOOP_RESULT2' | grep -q 'loop-test-3'"

# ── 6. 測試 healer 策略輪替 ────────────────────────────
echo ""
echo "── 6. Healer 策略輪替 ──"

# 建立 looping 任務
sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, attempt_count, max_attempts, error_class) VALUES ('loop-test-4', 'test', 'stuck task', 'fail', 3, 6, 'looping');"

# 寫入假 failure file
echo "some failure output" > /tmp/test-loop-failure.txt

HEAL_JSON=$(python3 healer.py loop-test-4 /tmp/test-loop-failure.txt 2>/dev/null)
HEAL_ACTION=$(echo "$HEAL_JSON" | jq -r '.action')
check "looping 任務觸發角色切換" test "$HEAL_ACTION" = "retry_with_role_switch"

NEW_ROLE=$(echo "$HEAL_JSON" | jq -r '.new_role // empty')
check "切換到 debugger 角色" test "$NEW_ROLE" = "debugger"

# 測試 evaluator_reject 分類
echo "EVALUATOR: REQUEST_CHANGES: code quality issues" > /tmp/test-eval-failure.txt
sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, attempt_count, max_attempts) VALUES ('loop-test-5', 'test', 'eval rejected', 'fail', 1, 5);"

HEAL_JSON2=$(python3 healer.py loop-test-5 /tmp/test-eval-failure.txt 2>/dev/null)
HEAL_ACTION2=$(echo "$HEAL_JSON2" | jq -r '.action')
check "evaluator_reject 觸發 retry_with_context" test "$HEAL_ACTION2" = "retry_with_context"

rm -f /tmp/test-loop-failure.txt /tmp/test-eval-failure.txt

# ── 結果 ──────────────────────────────────────────────
echo ""
echo "════════════════════════════════"
echo "結果: $PASS 通過, $FAIL 失敗"
echo "════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
