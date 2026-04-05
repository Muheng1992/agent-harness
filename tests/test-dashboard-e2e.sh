#!/bin/bash
# test-dashboard-e2e.sh — E2E 測試：dashboard + notify + 多輪任務執行
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$HARNESS_DIR"

# 顏色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass_count=0
fail_count=0

pass_test() {
  echo -e "  ${GREEN}✅ PASS${NC}: $1"
  pass_count=$((pass_count + 1))
}

fail_test() {
  echo -e "  ${RED}❌ FAIL${NC}: $1 ${2:+— $2}"
  fail_count=$((fail_count + 1))
}

echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Agent Harness — Dashboard & Notify E2E 測試${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo ""

# ── 清理 + 初始化 ─────────────────────────────────────────

TEST_DB="/tmp/test-agent-harness-e2e.db"
TEST_PROJECT_DIR="/tmp/test-harness-project"
TEST_TASKS_DIR="$HARNESS_DIR/tasks/e2e-test"
NOTIFY_LOG="$HARNESS_DIR/db/notify.log"
DASHBOARD="$HARNESS_DIR/agent-dashboard"

rm -f "$TEST_DB" "$NOTIFY_LOG"
rm -rf "$TEST_PROJECT_DIR" "$TEST_TASKS_DIR"

export AGENT_DB_PATH="$TEST_DB"
export AGENT_NOTIFY_DESKTOP=0
export AGENT_NOTIFY_BELL=0
export AGENT_NOTIFY_LOG=1

echo -e "${YELLOW}▸ 初始化測試資料庫...${NC}"
sqlite3 "$TEST_DB" < "$HARNESS_DIR/schema.sql" 2>/dev/null

if [ -f "$TEST_DB" ]; then
  pass_test "資料庫初始化"
else
  fail_test "資料庫初始化失敗"
  exit 1
fi

# ── 建立臨時專案 + 測試任務 ───────────────────────────────

echo -e "${YELLOW}▸ 建立臨時專案和任務...${NC}"

mkdir -p "$TEST_PROJECT_DIR/src"
echo '{"name":"e2e-test","version":"1.0.0"}' > "$TEST_PROJECT_DIR/package.json"
echo 'console.log("hello");' > "$TEST_PROJECT_DIR/src/index.js"

mkdir -p "$TEST_TASKS_DIR"

cat > "$TEST_TASKS_DIR/01-setup.json" << TASKJSON
{
  "id": "e2e-setup",
  "project": "e2e-test",
  "project_dir": "$TEST_PROJECT_DIR",
  "goal": "建立 src/utils.js，內含 add(a,b) 函數",
  "touches": ["src/utils.js"],
  "verify": "test -f src/utils.js && grep -q function src/utils.js",
  "depends_on": [],
  "max_attempts": 3
}
TASKJSON

cat > "$TEST_TASKS_DIR/02-feature.json" << TASKJSON
{
  "id": "e2e-feature",
  "project": "e2e-test",
  "project_dir": "$TEST_PROJECT_DIR",
  "goal": "建立 src/greeting.js，export greet(name) 函數",
  "touches": ["src/greeting.js"],
  "verify": "test -f src/greeting.js && grep -q greet src/greeting.js",
  "depends_on": ["e2e-setup"],
  "max_attempts": 3
}
TASKJSON

cat > "$TEST_TASKS_DIR/03-integration.json" << TASKJSON
{
  "id": "e2e-integration",
  "project": "e2e-test",
  "project_dir": "$TEST_PROJECT_DIR",
  "goal": "建立 src/test.js，測試 greeting 和 utils",
  "touches": ["src/test.js"],
  "verify": "test -f src/test.js",
  "depends_on": ["e2e-feature"],
  "max_attempts": 3
}
TASKJSON

pass_test "臨時專案和 3 個 DAG 任務建立"

# ── 匯入任務 ──────────────────────────────────────────────

echo -e "${YELLOW}▸ 匯入任務...${NC}"

python3 "$HARNESS_DIR/task_picker.py" import "$TEST_TASKS_DIR" 2>/dev/null

TASK_COUNT=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM tasks;")
if [ "$TASK_COUNT" -eq 3 ]; then
  pass_test "匯入 3 個任務"
else
  fail_test "任務數量不正確" "期望 3，實際 $TASK_COUNT"
fi

# ═══════════════════════════════════════════════════════════
# 測試 1: Dashboard --snapshot 基本狀態
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 1: Dashboard snapshot — 初始狀態...${NC}"

SNAP=$(python3 "$DASHBOARD" --snapshot 2>/dev/null)

PENDING=$(echo "$SNAP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['pending'])")
STATE=$(echo "$SNAP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['global_state'])")

if [ "$PENDING" = "3" ]; then
  pass_test "snapshot 顯示 3 個 pending"
else
  fail_test "snapshot pending 數量不正確" "$PENDING"
fi

if [ "$STATE" = "RUNNING" ]; then
  pass_test "snapshot 顯示 RUNNING 狀態"
else
  fail_test "snapshot 狀態不正確" "$STATE"
fi

# ═══════════════════════════════════════════════════════════
# 測試 2: 模擬任務狀態變更 → Dashboard 反映
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 2: 模擬狀態變更...${NC}"

# mark-running
python3 "$HARNESS_DIR/task_picker.py" mark-running "e2e-setup" 0 2>/dev/null

SNAP=$(python3 "$DASHBOARD" --snapshot 2>/dev/null)
RUNNING=$(echo "$SNAP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['running'])")
RTASKS=$(echo "$SNAP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['running_tasks'])")

if [ "$RUNNING" = "1" ]; then
  pass_test "mark-running → snapshot 顯示 1 running"
else
  fail_test "running 數量不正確" "$RUNNING"
fi

if [ "$RTASKS" = "1" ]; then
  pass_test "running_tasks detail = 1"
else
  fail_test "running_tasks detail 不正確" "$RTASKS"
fi

# 模擬 claude output 檔案
echo "正在建立 utils.js..." > "/tmp/claude-out-e2e-setup.txt"
echo "已完成 add() 函數" >> "/tmp/claude-out-e2e-setup.txt"

# mark-pass
python3 "$HARNESS_DIR/task_picker.py" mark-pass "e2e-setup" 2>/dev/null

SNAP=$(python3 "$DASHBOARD" --snapshot 2>/dev/null)
PASS_CNT=$(echo "$SNAP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['pass'])")
PEND_CNT=$(echo "$SNAP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['pending'])")

if [ "$PASS_CNT" = "1" ]; then
  pass_test "mark-pass → pass=1"
else
  fail_test "pass 計數不正確" "$PASS_CNT"
fi

if [ "$PEND_CNT" = "2" ]; then
  pass_test "mark-pass → pending=2"
else
  fail_test "pending 計數不正確" "$PEND_CNT"
fi

# ═══════════════════════════════════════════════════════════
# 測試 3: 模擬 escalated
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 3: 模擬 escalated 狀態...${NC}"

sqlite3 "$TEST_DB" "UPDATE tasks SET status='escalated', error_class='build_fail', last_error='compilation error' WHERE id='e2e-feature';"

SNAP=$(python3 "$DASHBOARD" --snapshot 2>/dev/null)
ESC_CNT=$(echo "$SNAP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['escalated'])")
ESC_TASKS=$(echo "$SNAP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['escalated_tasks'])")

if [ "$ESC_CNT" = "1" ]; then
  pass_test "escalated=1"
else
  fail_test "escalated 計數不正確" "$ESC_CNT"
fi

if [ "$ESC_TASKS" = "1" ]; then
  pass_test "escalated_tasks detail=1"
else
  fail_test "escalated_tasks detail 不正確" "$ESC_TASKS"
fi

# 恢復
sqlite3 "$TEST_DB" "UPDATE tasks SET status='pending', error_class=NULL, last_error=NULL WHERE id='e2e-feature';"

# ═══════════════════════════════════════════════════════════
# 測試 4: Dashboard --snapshot-render（畫面渲染）
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 4: Dashboard 畫面渲染...${NC}"

RENDER_OUTPUT=$(python3 "$DASHBOARD" --snapshot-render 2>&1)

if echo "$RENDER_OUTPUT" | grep -q "Agent Harness Dashboard"; then
  pass_test "畫面渲染包含標題"
else
  fail_test "畫面渲染缺少標題"
fi

if echo "$RENDER_OUTPUT" | grep -q "Running Agents"; then
  pass_test "畫面渲染包含 Running Agents 面板"
else
  fail_test "畫面渲染缺少 Running Agents"
fi

if echo "$RENDER_OUTPUT" | grep -q "Pending Queue"; then
  pass_test "畫面渲染包含 Pending Queue 面板"
else
  fail_test "畫面渲染缺少 Pending Queue"
fi

if echo "$RENDER_OUTPUT" | grep -q "Escalated"; then
  pass_test "畫面渲染包含 Escalated 面板"
else
  fail_test "畫面渲染缺少 Escalated"
fi

# ═══════════════════════════════════════════════════════════
# 測試 5: Notify 層級系統
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 5: 通知系統層級...${NC}"

rm -f "$NOTIFY_LOG"

bash "$HARNESS_DIR/notify.sh" "測試 info"
bash "$HARNESS_DIR/notify.sh" "測試 success" --level success
bash "$HARNESS_DIR/notify.sh" "測試 error" --level error
bash "$HARNESS_DIR/notify.sh" "測試 escalated" --level escalated
bash "$HARNESS_DIR/notify.sh" "測試 done" --level done

if [ -f "$NOTIFY_LOG" ]; then
  LOG_LINES=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
  if [ "$LOG_LINES" -eq 5 ]; then
    pass_test "通知日誌記錄 5 條"
  else
    fail_test "通知日誌行數" "期望 5，實際 $LOG_LINES"
  fi

  ALL_LEVELS_OK=true
  for lvl in info success error escalated done; do
    if ! grep -q "\\[$lvl\\]" "$NOTIFY_LOG"; then
      fail_test "通知層級缺失" "$lvl"
      ALL_LEVELS_OK=false
    fi
  done
  if [ "$ALL_LEVELS_OK" = true ]; then
    pass_test "所有 5 個通知層級都正確記錄"
  fi
else
  fail_test "通知日誌檔案不存在"
fi

# ═══════════════════════════════════════════════════════════
# 測試 6: agent-ctl dashboard 子命令
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 6: agent-ctl dashboard 子命令...${NC}"

CTL_HELP=$(python3 "$HARNESS_DIR/agent-ctl" dashboard --help 2>&1)
if echo "$CTL_HELP" | grep -q "watch"; then
  pass_test "agent-ctl dashboard --help 正常"
else
  fail_test "agent-ctl dashboard 子命令不存在"
fi

# ═══════════════════════════════════════════════════════════
# 測試 7: 多輪模擬（full lifecycle）
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 7: 多輪完整生命週期模擬...${NC}"

# 重置所有任務為 pending
sqlite3 "$TEST_DB" "UPDATE tasks SET status='pending', attempt_count=0, error_class=NULL, last_error=NULL;"

# 第一輪：e2e-setup → running → pass
python3 "$HARNESS_DIR/task_picker.py" mark-running "e2e-setup" 0 2>/dev/null
SNAP1=$(python3 "$DASHBOARD" --snapshot 2>/dev/null)
R1_RUNNING=$(echo "$SNAP1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['running'])")
[ "$R1_RUNNING" = "1" ] && pass_test "第 1 輪: setup running" || fail_test "第 1 輪 running" "$R1_RUNNING"

python3 "$HARNESS_DIR/task_picker.py" mark-pass "e2e-setup" 2>/dev/null

# 第二輪：e2e-feature → running → fail → retry → pass
python3 "$HARNESS_DIR/task_picker.py" mark-running "e2e-feature" 0 2>/dev/null
python3 "$HARNESS_DIR/task_picker.py" record-failure "e2e-feature" "build error: missing module" 2>/dev/null

SNAP2=$(python3 "$DASHBOARD" --snapshot 2>/dev/null)
R2_FAIL=$(echo "$SNAP2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['fail'])")
[ "$R2_FAIL" = "1" ] && pass_test "第 2 輪: feature failed" || fail_test "第 2 輪 fail" "$R2_FAIL"

# Retry
sqlite3 "$TEST_DB" "UPDATE tasks SET status='pending' WHERE id='e2e-feature';"
python3 "$HARNESS_DIR/task_picker.py" mark-running "e2e-feature" 0 2>/dev/null
python3 "$HARNESS_DIR/task_picker.py" mark-pass "e2e-feature" 2>/dev/null

SNAP3=$(python3 "$DASHBOARD" --snapshot 2>/dev/null)
R3_PASS=$(echo "$SNAP3" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['pass'])")
[ "$R3_PASS" = "2" ] && pass_test "第 2 輪(重試): feature pass" || fail_test "第 2 輪 pass 計數" "$R3_PASS"

# 第三輪：e2e-integration → running → pass
python3 "$HARNESS_DIR/task_picker.py" mark-running "e2e-integration" 0 2>/dev/null
python3 "$HARNESS_DIR/task_picker.py" mark-pass "e2e-integration" 2>/dev/null

SNAP4=$(python3 "$DASHBOARD" --snapshot 2>/dev/null)
R4_PASS=$(echo "$SNAP4" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['pass'])")
R4_PEND=$(echo "$SNAP4" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['pending'])")

[ "$R4_PASS" = "3" ] && pass_test "第 3 輪: 全部 pass=3" || fail_test "第 3 輪 pass" "$R4_PASS"
[ "$R4_PEND" = "0" ] && pass_test "第 3 輪: pending=0（全部完成）" || fail_test "第 3 輪 pending" "$R4_PEND"

# ═══════════════════════════════════════════════════════════
# 測試 8: 寫入 runs 記錄 → events 面板
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 8: events 面板（runs 記錄）...${NC}"

# 手動寫幾筆 run
sqlite3 "$TEST_DB" "INSERT INTO runs (task_id, worker_id, attempt, status, duration_sec, started_at, finished_at) VALUES ('e2e-setup', 0, 1, 'pass', 45.2, datetime('now', '-2 minutes'), datetime('now', '-1 minute'));"
sqlite3 "$TEST_DB" "INSERT INTO runs (task_id, worker_id, attempt, status, error_class, duration_sec, started_at, finished_at) VALUES ('e2e-feature', 0, 1, 'fail', 'build_fail', 30.0, datetime('now', '-3 minutes'), datetime('now', '-2 minutes'));"
sqlite3 "$TEST_DB" "INSERT INTO runs (task_id, worker_id, attempt, status, duration_sec, started_at, finished_at) VALUES ('e2e-feature', 0, 2, 'pass', 50.0, datetime('now', '-1 minute'), datetime('now'));"

SNAP5=$(python3 "$DASHBOARD" --snapshot 2>/dev/null)
EVENTS=$(echo "$SNAP5" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['recent_events'])")
TOTAL_RUNS=$(echo "$SNAP5" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['total_runs'])")

[ "$EVENTS" = "3" ] && pass_test "recent_events=3" || fail_test "recent_events" "$EVENTS"
[ "$TOTAL_RUNS" = "3" ] && pass_test "total_runs=3" || fail_test "total_runs" "$TOTAL_RUNS"

# ── 清理 ──────────────────────────────────────────────────

echo ""
echo -e "${YELLOW}▸ 清理...${NC}"
rm -f "$TEST_DB" "$NOTIFY_LOG"
rm -rf "$TEST_PROJECT_DIR" "$TEST_TASKS_DIR"
rm -f /tmp/claude-out-e2e-setup.txt
pass_test "清理完成"

# ── 結果 ──────────────────────────────────────────────────

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
TOTAL=$((pass_count + fail_count))
echo -e "  結果: ${GREEN}${pass_count} passed${NC} / ${RED}${fail_count} failed${NC} / ${TOTAL} total"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
