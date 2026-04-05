#!/bin/bash
# test-traceability.sh — 追蹤性驗證：prompt 儲存、audit log、完整記錄鏈
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

TEST_DB="/tmp/test-traceability-$$.db"
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
  rm -f /tmp/test-prompt-*.txt /tmp/test-output-*.txt
}
trap cleanup EXIT

echo "=== 追蹤性（Traceability）測試 ==="

# ── 1. 初始化 DB ─────────────────────────────────────────
echo ""
echo "── 1. 初始化 ──"
sqlite3 "$TEST_DB" < schema.sql
sqlite3 "$TEST_DB" < migrations/003-add-features.sql 2>/dev/null || true
sqlite3 "$TEST_DB" < migrations/004-add-traceability.sql 2>/dev/null || true
check "DB 初始化成功" test -f "$TEST_DB"

# 確認新欄位存在
check "runs 有 prompt_text 欄位" \
  sqlite3 "$TEST_DB" "SELECT prompt_text FROM runs LIMIT 0;"
check "runs 有 input_prompt_hash 欄位" \
  sqlite3 "$TEST_DB" "SELECT input_prompt_hash FROM runs LIMIT 0;"
check "audit_log 表存在" \
  sqlite3 "$TEST_DB" "SELECT id FROM audit_log LIMIT 0;"

# ── 2. write_run 存入 prompt ─────────────────────────────
echo ""
echo "── 2. Prompt 儲存 ──"

sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status) VALUES ('trace-1', 'test', 'test goal', 'running');"

# 建立測試 prompt 和 output 檔案
echo "This is the actual prompt sent to Claude" > /tmp/test-prompt-trace.txt
echo '{"result": "task completed successfully"}' > /tmp/test-output-trace.txt

python3 memory.py write trace-1 \
  --output-file /tmp/test-output-trace.txt \
  --prompt-file /tmp/test-prompt-trace.txt \
  --worker-id 0 --attempt 1 --duration 30 --status running

# 確認 prompt 被存入
STORED_PROMPT=$(sqlite3 "$TEST_DB" "SELECT prompt_text FROM runs WHERE task_id='trace-1' ORDER BY id DESC LIMIT 1;")
check "prompt_text 已存入 DB" test -n "$STORED_PROMPT"
check "prompt_text 內容正確" bash -c "[[ '$STORED_PROMPT' == *actual*prompt* ]]"

# 確認 input_prompt_hash 被計算
INPUT_HASH=$(sqlite3 "$TEST_DB" "SELECT input_prompt_hash FROM runs WHERE task_id='trace-1' ORDER BY id DESC LIMIT 1;")
check "input_prompt_hash 已計算" test -n "$INPUT_HASH"
check "input_prompt_hash 長度為 32" test ${#INPUT_HASH} -eq 32

# ── 3. write_run 不帶 prompt 時降級 ─────────────────────
echo ""
echo "── 3. 無 prompt 時降級 ──"

python3 memory.py write trace-1 \
  --output-file /tmp/test-output-trace.txt \
  --worker-id 0 --attempt 2 --duration 20 --status running

NO_PROMPT=$(sqlite3 "$TEST_DB" "SELECT prompt_text FROM runs WHERE task_id='trace-1' AND attempt=2;")
check "未傳 prompt 時 prompt_text 為 NULL" test -z "$NO_PROMPT"

# ── 4. Audit Log 寫入 ───────────────────────────────────
echo ""
echo "── 4. Audit Log ──"

python3 memory.py audit trace-1 \
  --event-type healer_decision \
  --event-data '{"action":"retry_with_role_switch","new_role":"debugger"}' \
  --actor healer

AUDIT_COUNT=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM audit_log WHERE task_id='trace-1';")
check "audit_log 有記錄" test "$AUDIT_COUNT" -ge 1

AUDIT_TYPE=$(sqlite3 "$TEST_DB" "SELECT event_type FROM audit_log WHERE task_id='trace-1' LIMIT 1;")
check "event_type 正確" test "$AUDIT_TYPE" = "healer_decision"

AUDIT_DATA=$(sqlite3 "$TEST_DB" "SELECT event_data FROM audit_log WHERE task_id='trace-1' LIMIT 1;")
check "event_data 包含 action" bash -c "[[ '$AUDIT_DATA' == *retry_with_role_switch* ]]"

AUDIT_ACTOR=$(sqlite3 "$TEST_DB" "SELECT actor FROM audit_log WHERE task_id='trace-1' LIMIT 1;")
check "actor 正確" test "$AUDIT_ACTOR" = "healer"

# 多個 event type
python3 memory.py audit trace-1 \
  --event-type role_switch \
  --event-data '{"from":"implementer","to":"debugger"}' \
  --actor orchestrator

AUDIT_COUNT2=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM audit_log WHERE task_id='trace-1';")
check "可寫入多筆 audit log" test "$AUDIT_COUNT2" -ge 2

# ── 5. Watchdog looping 寫入 audit ────────────────────────
echo ""
echo "── 5. Watchdog Audit ──"

sqlite3 "$TEST_DB" "INSERT INTO tasks (id, project, goal, status, attempt_count, max_attempts) VALUES ('trace-loop', 'test', 'looping', 'fail', 2, 5);"

SAME_FP=$(python3 -c "from memory import compute_output_fingerprint; print(compute_output_fingerprint('repeated output'))")
sqlite3 "$TEST_DB" "INSERT INTO runs (task_id, worker_id, attempt, status, output_fingerprint, claude_output) VALUES ('trace-loop', 0, 1, 'fail', '$SAME_FP', 'repeated output');"
sqlite3 "$TEST_DB" "INSERT INTO runs (task_id, worker_id, attempt, status, output_fingerprint, claude_output) VALUES ('trace-loop', 0, 2, 'fail', '$SAME_FP', 'repeated output');"

python3 watchdog.py check-looping >/dev/null 2>&1

LOOP_AUDIT=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM audit_log WHERE task_id='trace-loop' AND event_type='looping_detected';")
check "watchdog looping 寫入 audit_log" test "$LOOP_AUDIT" -ge 1

LOOP_DATA=$(sqlite3 "$TEST_DB" "SELECT event_data FROM audit_log WHERE task_id='trace-loop' AND event_type='looping_detected' LIMIT 1;")
check "looping audit 包含 fingerprint" bash -c "[[ '$LOOP_DATA' == *fingerprint* ]]"

# ── 6. 完整記錄鏈驗證 ────────────────────────────────────
echo ""
echo "── 6. 記錄鏈完整性 ──"

# 對於 trace-1：應該有 runs 記錄 + audit 記錄
RUN_COUNT=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM runs WHERE task_id='trace-1';")
check "trace-1 有 run 記錄" test "$RUN_COUNT" -ge 1

# 驗證可以用 task_id 關聯查詢所有相關紀錄
FULL_TRACE=$(sqlite3 "$TEST_DB" "
  SELECT 'runs' as source, attempt, status, CASE WHEN prompt_text IS NOT NULL THEN 'HAS_PROMPT' ELSE 'NO_PROMPT' END as prompt_status
  FROM runs WHERE task_id='trace-1'
  UNION ALL
  SELECT 'audit' as source, 0, event_type, event_data
  FROM audit_log WHERE task_id='trace-1'
  ORDER BY source;
")
check "可用 task_id 關聯查詢完整追蹤鏈" test -n "$FULL_TRACE"

# ── 7. prompt_hash vs input_prompt_hash 區分 ─────────────
echo ""
echo "── 7. Hash 區分 ──"

OUTPUT_HASH=$(sqlite3 "$TEST_DB" "SELECT prompt_hash FROM runs WHERE task_id='trace-1' AND attempt=1;")
check "prompt_hash（output hash）存在" test -n "$OUTPUT_HASH"
check "prompt_hash 和 input_prompt_hash 不同" test "$OUTPUT_HASH" != "$INPUT_HASH"

# ── 8. migration 未跑時降級 ──────────────────────────────
echo ""
echo "── 8. Migration 降級 ──"

# 用一個沒跑 004 migration 的 DB 測試
OLD_DB="/tmp/test-trace-old-$$.db"
sqlite3 "$OLD_DB" < schema.sql
sqlite3 "$OLD_DB" < migrations/003-add-features.sql 2>/dev/null || true
export AGENT_DB_PATH="$OLD_DB"

sqlite3 "$OLD_DB" "INSERT INTO tasks (id, project, goal, status) VALUES ('old-1', 'test', 'old task', 'running');"
echo "test output" > /tmp/test-output-old.txt
echo "test prompt" > /tmp/test-prompt-old.txt

# 應該不報錯，只是不存 prompt
python3 memory.py write old-1 \
  --output-file /tmp/test-output-old.txt \
  --prompt-file /tmp/test-prompt-old.txt \
  --worker-id 0 --attempt 1 --duration 10 --status running 2>/dev/null
check "migration 未跑時 write_run 不報錯" test $? -eq 0

# audit 也應該靜默降級
python3 memory.py audit old-1 \
  --event-type test_event \
  --event-data '{"test":true}' 2>/dev/null
check "migration 未跑時 audit 不報錯" test $? -eq 0

export AGENT_DB_PATH="$TEST_DB"
rm -f "$OLD_DB" "$OLD_DB-wal" "$OLD_DB-shm" /tmp/test-output-old.txt /tmp/test-prompt-old.txt

# ── 結果 ──────────────────────────────────────────────
echo ""
echo "════════════════════════════════"
echo "結果: $PASS 通過, $FAIL 失敗"
echo "════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
