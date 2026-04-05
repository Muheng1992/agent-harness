#!/bin/bash
# test-live-orchestration.sh — 真正跑 orchestrator 一輪，驗證 dashboard + notify 整合
# 這個測試會呼叫 Claude CLI（需要 Claude Code 已安裝且認證）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$HARNESS_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass_count=0
fail_count=0

pass_test() { echo -e "  ${GREEN}✅ PASS${NC}: $1"; pass_count=$((pass_count + 1)); }
fail_test() { echo -e "  ${RED}❌ FAIL${NC}: $1 ${2:+— $2}"; fail_count=$((fail_count + 1)); }

echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Live Orchestration Integration Test${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo ""

# ── 準備 ──────────────────────────────────────────────────

LIVE_DB="$HARNESS_DIR/db/agent.db"
LIVE_PROJECT="/tmp/test-live-harness-project"
LIVE_TASKS="$HARNESS_DIR/tasks/live-test"
NOTIFY_LOG="$HARNESS_DIR/db/notify.log"
DASHBOARD="$HARNESS_DIR/agent-dashboard"

# 清理
rm -rf "$LIVE_PROJECT" "$LIVE_TASKS"
rm -f "$NOTIFY_LOG"

# 確保 DB 存在
if [ ! -f "$LIVE_DB" ]; then
  echo -e "${YELLOW}▸ 初始化主資料庫...${NC}"
  sqlite3 "$LIVE_DB" < "$HARNESS_DIR/schema.sql" 2>/dev/null
fi

# 清除舊的 live-test 任務
sqlite3 "$LIVE_DB" "DELETE FROM runs WHERE task_id LIKE 'live-%';" 2>/dev/null || true
sqlite3 "$LIVE_DB" "DELETE FROM tasks WHERE project='live-test';" 2>/dev/null || true

# 建立簡單的臨時專案
mkdir -p "$LIVE_PROJECT/src"
echo '{"name":"live-test","version":"1.0.0"}' > "$LIVE_PROJECT/package.json"

echo -e "${YELLOW}▸ 建立 2 個快速任務（每個 ~10 秒）...${NC}"
mkdir -p "$LIVE_TASKS"

# 任務 1：建一個極簡的檔案（快速完成）
cat > "$LIVE_TASKS/01-create-file.json" << TASKJSON
{
  "id": "live-create-file",
  "project": "live-test",
  "project_dir": "$LIVE_PROJECT",
  "goal": "建立檔案 src/hello.js，內容只需要一行：module.exports = { greet: (name) => 'Hello ' + name };",
  "touches": ["src/hello.js"],
  "verify": "test -f src/hello.js && grep -q greet src/hello.js",
  "depends_on": [],
  "max_attempts": 3
}
TASKJSON

# 任務 2：依賴任務 1，也很快
cat > "$LIVE_TASKS/02-create-test.json" << TASKJSON
{
  "id": "live-create-test",
  "project": "live-test",
  "project_dir": "$LIVE_PROJECT",
  "goal": "建立檔案 src/hello.test.js，用 node assert 測試 src/hello.js 的 greet 函數。測試 greet('World') 應回傳 'Hello World'。",
  "touches": ["src/hello.test.js"],
  "verify": "node src/hello.test.js",
  "depends_on": ["live-create-file"],
  "max_attempts": 3
}
TASKJSON

# 匯入
python3 "$HARNESS_DIR/task_picker.py" import "$LIVE_TASKS" 2>/dev/null
TASK_COUNT=$(sqlite3 "$LIVE_DB" "SELECT COUNT(*) FROM tasks WHERE project='live-test';")
[ "$TASK_COUNT" = "2" ] && pass_test "匯入 2 個 live 任務" || fail_test "任務匯入" "$TASK_COUNT"

# ── Dashboard 初始 snapshot ───────────────────────────────

echo ""
echo -e "${YELLOW}▸ Dashboard 初始 snapshot...${NC}"
SNAP_BEFORE=$(python3 "$DASHBOARD" --snapshot 2>/dev/null)
BEFORE_PEND=$(echo "$SNAP_BEFORE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['pending'])")
echo "  Pending: $BEFORE_PEND"
[ "$BEFORE_PEND" -ge 2 ] && pass_test "初始 pending >= 2" || fail_test "初始 pending" "$BEFORE_PEND"

# ── 跑 orchestrator 兩輪 ─────────────────────────────────

echo ""
echo -e "${YELLOW}▸ 啟動 orchestrator（最多 2 輪）...${NC}"
echo -e "${CYAN}  （這會呼叫 Claude CLI，每輪約 10-30 秒）${NC}"

# 跑 loop-orchestrator，限 2 輪 + 5 分鐘超時
bash "$HARNESS_DIR/loop-orchestrator.sh" --max-rounds 4 --max-time 300 2>&1 | while IFS= read -r line; do
  echo "  [orch] $line"
done
ORCH_EXIT=${PIPESTATUS[0]}

echo ""
echo -e "${YELLOW}▸ Orchestrator 完成 (exit=$ORCH_EXIT)${NC}"

# ── Dashboard 結束 snapshot ───────────────────────────────

echo ""
echo -e "${YELLOW}▸ Dashboard 結束 snapshot...${NC}"
SNAP_AFTER=$(python3 "$DASHBOARD" --snapshot 2>/dev/null)
AFTER_PASS=$(echo "$SNAP_AFTER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['pass'])")
AFTER_PEND=$(echo "$SNAP_AFTER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['pending'])")
AFTER_FAIL=$(echo "$SNAP_AFTER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['fail'])")
AFTER_ESC=$(echo "$SNAP_AFTER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['counts']['escalated'])")
AFTER_RUNS=$(echo "$SNAP_AFTER" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['total_runs'])")

echo "  pass=$AFTER_PASS fail=$AFTER_FAIL pending=$AFTER_PEND escalated=$AFTER_ESC runs=$AFTER_RUNS"

# 判斷結果
LIVE_PASS_COUNT=$(sqlite3 "$LIVE_DB" "SELECT COUNT(*) FROM tasks WHERE project='live-test' AND status='pass';")
LIVE_ESC_COUNT=$(sqlite3 "$LIVE_DB" "SELECT COUNT(*) FROM tasks WHERE project='live-test' AND status='escalated';")

if [ "$LIVE_PASS_COUNT" -eq 2 ]; then
  pass_test "兩個 live 任務都 pass"
elif [ "$LIVE_PASS_COUNT" -ge 1 ]; then
  pass_test "至少 1 個 live 任務 pass (${LIVE_PASS_COUNT}/2)"
  [ "$LIVE_ESC_COUNT" -gt 0 ] && fail_test "有任務 escalated" "可能 Claude 執行超時"
else
  fail_test "沒有任務 pass" "pass=$LIVE_PASS_COUNT"
fi

# ── 驗證 notify 日誌 ─────────────────────────────────────

echo ""
echo -e "${YELLOW}▸ 驗證通知記錄...${NC}"

if [ -f "$NOTIFY_LOG" ]; then
  NOTIFY_LINES=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
  echo "  通知記錄: $NOTIFY_LINES 條"
  cat "$NOTIFY_LOG" | while IFS= read -r line; do echo "    $line"; done
  [ "$NOTIFY_LINES" -ge 1 ] && pass_test "通知有記錄 ($NOTIFY_LINES 條)" || fail_test "通知無記錄"
else
  echo "  (無通知日誌)"
  fail_test "notify.log 不存在"
fi

# ── 驗證 claude output 檔案 ──────────────────────────────

echo ""
echo -e "${YELLOW}▸ 驗證 Claude 輸出檔案...${NC}"

for tid in live-create-file live-create-test; do
  OUT_FILE="/tmp/claude-out-${tid}.txt"
  if [ -f "$OUT_FILE" ]; then
    SIZE=$(wc -c < "$OUT_FILE" | tr -d ' ')
    pass_test "Claude 輸出: $tid (${SIZE} bytes)"
  else
    echo "  (${tid} 輸出檔案不存在 — 可能任務未執行到)"
  fi
done

# ── 驗證生成的程式碼 ─────────────────────────────────────

echo ""
echo -e "${YELLOW}▸ 驗證生成的程式碼...${NC}"

if [ -f "$LIVE_PROJECT/src/hello.js" ]; then
  pass_test "hello.js 已建立"
  if grep -q "greet" "$LIVE_PROJECT/src/hello.js"; then
    pass_test "hello.js 包含 greet 函數"
  else
    fail_test "hello.js 缺少 greet"
  fi
else
  fail_test "hello.js 不存在"
fi

if [ -f "$LIVE_PROJECT/src/hello.test.js" ]; then
  pass_test "hello.test.js 已建立"
  # 跑測試
  if (cd "$LIVE_PROJECT" && node src/hello.test.js 2>/dev/null); then
    pass_test "hello.test.js 執行通過"
  else
    fail_test "hello.test.js 執行失敗"
  fi
else
  echo "  hello.test.js 不存在（可能第 2 輪未執行到）"
fi

# ── 清理 live-test 任務（但不刪 DB） ─────────────────────

echo ""
echo -e "${YELLOW}▸ 清理 live-test 資料...${NC}"
sqlite3 "$LIVE_DB" "DELETE FROM runs WHERE task_id LIKE 'live-%';"
sqlite3 "$LIVE_DB" "DELETE FROM tasks WHERE project='live-test';"
rm -rf "$LIVE_PROJECT" "$LIVE_TASKS"
rm -f /tmp/claude-out-live-create-file.txt /tmp/claude-out-live-create-test.txt
rm -f "$NOTIFY_LOG"
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
