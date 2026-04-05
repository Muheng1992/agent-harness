#!/bin/bash
# test-web-dashboard.sh — Web Dashboard 整合測試 / API 端點測試
# 測試 web-dashboard server 的啟動、API 回應格式、CORS、空 DB 行為、--check / --help 模式
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$HARNESS_DIR"

# ── 顏色 ──────────────────────────────────────────────────
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
echo -e "${CYAN}  Agent Harness — Web Dashboard 整合測試${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo ""

# ── 清理函式 ──────────────────────────────────────────────
SERVER_PID=""
TEST_DB="/tmp/test-web-dashboard-$$.db"
EMPTY_DB="/tmp/test-web-dashboard-empty-$$.db"
PORT=18745  # 用高 port 避免衝突

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$TEST_DB" "$EMPTY_DB"
}
trap cleanup EXIT

# ── 初始化測試資料庫 ──────────────────────────────────────

echo -e "${YELLOW}▸ 初始化測試資料庫...${NC}"
sqlite3 "$TEST_DB" < "$HARNESS_DIR/schema.sql" >/dev/null 2>&1

# 套用 migration 建立 audit_log 等額外 table
for mig in "$HARNESS_DIR"/migrations/*.sql; do
  sqlite3 "$TEST_DB" < "$mig" >/dev/null 2>&1 || true
done

# 插入測試資料
sqlite3 "$TEST_DB" <<'SQL'
INSERT INTO tasks (id, project, goal, status, role, attempt_count, max_attempts, spawned_by)
VALUES
  ('task-001', 'test-project', '實作功能 A', 'pass', 'implementer', 2, 5, NULL),
  ('task-002', 'test-project', '撰寫測試 B', 'fail', 'tester', 1, 5, 'task-001'),
  ('task-003', 'other-project', '設計 API C', 'pending', 'architect', 0, 5, NULL),
  ('task-004', 'test-project', '修復 Bug D', 'running', 'implementer', 1, 5, 'task-001');

INSERT INTO runs (task_id, attempt, status, duration_sec, started_at, finished_at)
VALUES
  ('task-001', 1, 'fail', 12.5, '2025-01-01 10:00:00', '2025-01-01 10:00:12'),
  ('task-001', 2, 'pass', 8.3, '2025-01-01 10:01:00', '2025-01-01 10:01:08'),
  ('task-002', 1, 'fail', 5.0, '2025-01-01 11:00:00', '2025-01-01 11:00:05');

INSERT INTO pipelines (id, name, project, status)
VALUES ('pipe-001', '測試 Pipeline', 'test-project', 'active');

INSERT INTO router_decisions (action, reason, task_ids, tech_debt_score, test_status)
VALUES ('BUILD', '功能 A 需要建構', '["task-001"]', 3, 'PASS');

INSERT INTO audit_log (task_id, event_type, event_data, actor)
VALUES
  ('task-001', 'healer_decision', '{"action":"retry"}', 'healer'),
  ('task-002', 'role_switch', '{"from":"implementer","to":"tester"}', 'orchestrator');
SQL

if [ -f "$TEST_DB" ]; then
  pass_test "測試資料庫初始化"
else
  fail_test "測試資料庫初始化失敗"
  exit 1
fi

# ══════════════════════════════════════════════════════════
# 1. --help 測試
# ══════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}▸ 測試 --help...${NC}"

HELP_OUTPUT=$(python3 "$HARNESS_DIR/web-dashboard" --help 2>&1)
if echo "$HELP_OUTPUT" | grep -q "port"; then
  pass_test "--help 包含 port 說明"
else
  fail_test "--help 缺少 port 說明"
fi

# ══════════════════════════════════════════════════════════
# 2. --check 模式測試
# ══════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}▸ 測試 --check 模式...${NC}"

export AGENT_DB_PATH="$TEST_DB"
if python3 "$HARNESS_DIR/web-dashboard" --check --port $((PORT + 100)) 2>/dev/null; then
  pass_test "--check 模式 exit code 0"
else
  fail_test "--check 模式 exit code 非 0"
fi

# ══════════════════════════════════════════════════════════
# 3. Server 啟動測試
# ══════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}▸ 啟動 web-dashboard server (port $PORT)...${NC}"

python3 "$HARNESS_DIR/web-dashboard" --port "$PORT" &
SERVER_PID=$!
sleep 1

if kill -0 "$SERVER_PID" 2>/dev/null; then
  pass_test "Server 啟動成功 (PID $SERVER_PID)"
else
  fail_test "Server 啟動失敗"
  exit 1
fi

# 確認 port 可連接
if curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
  pass_test "Port $PORT 可連接"
else
  fail_test "Port $PORT 無法連接"
fi

# ══════════════════════════════════════════════════════════
# 4. API 端點測試
# ══════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}▸ 測試 API 端點...${NC}"

BASE="http://127.0.0.1:$PORT"

# GET / → 200, Content-Type text/html
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE/")
CONTENT_TYPE=$(curl -sf -o /dev/null -w "%{content_type}" "$BASE/")
if [ "$HTTP_CODE" = "200" ] && echo "$CONTENT_TYPE" | grep -q "text/html"; then
  pass_test "GET / → 200, text/html"
else
  fail_test "GET / → HTTP $HTTP_CODE, Content-Type: $CONTENT_TYPE"
fi

# GET /api/stats → 200, JSON, 包含 counts 和 pass_rate
RESP=$(curl -sf "$BASE/api/stats")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'counts' in d and 'pass_rate' in d" 2>/dev/null; then
  pass_test "GET /api/stats → 200, 包含 counts/pass_rate"
else
  fail_test "GET /api/stats → 回傳格式不正確"
fi

# GET /api/tasks → 200, JSON array
RESP=$(curl -sf "$BASE/api/tasks")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list) and len(d) == 4" 2>/dev/null; then
  pass_test "GET /api/tasks → 200, JSON array (4 筆)"
else
  fail_test "GET /api/tasks → 回傳格式不正確"
fi

# GET /api/tasks?status=pass → 篩選結果
RESP=$(curl -sf "$BASE/api/tasks?status=pass")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list) and len(d) == 1 and d[0]['status'] == 'pass'" 2>/dev/null; then
  pass_test "GET /api/tasks?status=pass → 篩選正確 (1 筆)"
else
  fail_test "GET /api/tasks?status=pass → 篩選不正確"
fi

# GET /api/tasks?project=test-project → 篩選結果
RESP=$(curl -sf "$BASE/api/tasks?project=test-project")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list) and len(d) == 3 and all(t['project'] == 'test-project' for t in d)" 2>/dev/null; then
  pass_test "GET /api/tasks?project=test-project → 篩選正確 (3 筆)"
else
  fail_test "GET /api/tasks?project=test-project → 篩選不正確"
fi

# GET /api/tasks/<id>/runs → 200
RESP=$(curl -sf "$BASE/api/tasks/task-001/runs")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list) and len(d) == 2" 2>/dev/null; then
  pass_test "GET /api/tasks/task-001/runs → 200, 2 筆 runs"
else
  fail_test "GET /api/tasks/task-001/runs → 回傳不正確"
fi

# GET /api/graph → 200, JSON 包含 nodes/edges
RESP=$(curl -sf "$BASE/api/graph")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'nodes' in d and 'edges' in d and len(d['nodes']) > 0" 2>/dev/null; then
  pass_test "GET /api/graph → 200, 包含 nodes/edges"
else
  fail_test "GET /api/graph → 回傳格式不正確"
fi

# GET /api/audit → 200, JSON array
RESP=$(curl -sf "$BASE/api/audit")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list) and len(d) == 2" 2>/dev/null; then
  pass_test "GET /api/audit → 200, JSON array (2 筆)"
else
  fail_test "GET /api/audit → 回傳格式不正確"
fi

# GET /api/pipelines → 200
RESP=$(curl -sf "$BASE/api/pipelines")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list) and len(d) == 1" 2>/dev/null; then
  pass_test "GET /api/pipelines → 200 (1 筆)"
else
  fail_test "GET /api/pipelines → 回傳不正確"
fi

# GET /api/router-decisions → 200
RESP=$(curl -sf "$BASE/api/router-decisions")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list) and len(d) == 1" 2>/dev/null; then
  pass_test "GET /api/router-decisions → 200 (1 筆)"
else
  fail_test "GET /api/router-decisions → 回傳不正確"
fi

# ══════════════════════════════════════════════════════════
# 5. CORS 測試
# ══════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}▸ 測試 CORS headers...${NC}"

CORS_HEADER=$(curl -sf -D - "$BASE/api/stats" 2>/dev/null | grep -i "access-control-allow-origin" || true)
if echo "$CORS_HEADER" | grep -qi "access-control-allow-origin"; then
  pass_test "CORS header: Access-Control-Allow-Origin 存在"
else
  fail_test "CORS header 缺少 Access-Control-Allow-Origin"
fi

# OPTIONS preflight
OPTIONS_RESP=$(curl -sf -X OPTIONS -I "$BASE/api/stats" 2>/dev/null || true)
if echo "$OPTIONS_RESP" | grep -qi "access-control-allow-methods"; then
  pass_test "OPTIONS preflight 回傳 Access-Control-Allow-Methods"
else
  fail_test "OPTIONS preflight 缺少 Access-Control-Allow-Methods"
fi

# ══════════════════════════════════════════════════════════
# 6. 停止 server，準備空 DB 測試
# ══════════════════════════════════════════════════════════
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

echo ""
echo -e "${YELLOW}▸ 測試空 DB 行為...${NC}"

# 建立空 DB（只有 schema，無資料）
sqlite3 "$EMPTY_DB" < "$HARNESS_DIR/schema.sql" >/dev/null 2>&1
for mig in "$HARNESS_DIR"/migrations/*.sql; do
  sqlite3 "$EMPTY_DB" < "$mig" >/dev/null 2>&1 || true
done

EMPTY_PORT=$((PORT + 1))
export AGENT_DB_PATH="$EMPTY_DB"

python3 "$HARNESS_DIR/web-dashboard" --port "$EMPTY_PORT" &
SERVER_PID=$!
sleep 1

if kill -0 "$SERVER_PID" 2>/dev/null; then
  pass_test "空 DB server 啟動成功"
else
  fail_test "空 DB server 啟動失敗"
fi

# 空 DB 下各端點不 crash
EMPTY_BASE="http://127.0.0.1:$EMPTY_PORT"

RESP=$(curl -sf "$EMPTY_BASE/api/stats")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'counts' in d" 2>/dev/null; then
  pass_test "空 DB: /api/stats 回傳正常"
else
  fail_test "空 DB: /api/stats 失敗"
fi

RESP=$(curl -sf "$EMPTY_BASE/api/tasks")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list) and len(d) == 0" 2>/dev/null; then
  pass_test "空 DB: /api/tasks 回傳空 array"
else
  fail_test "空 DB: /api/tasks 回傳不正確"
fi

RESP=$(curl -sf "$EMPTY_BASE/api/graph")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['nodes'] == [] and d['edges'] == []" 2>/dev/null; then
  pass_test "空 DB: /api/graph 回傳空 nodes/edges"
else
  fail_test "空 DB: /api/graph 回傳不正確"
fi

# ══════════════════════════════════════════════════════════
# 7. Python Unit Test
# ══════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}▸ 執行 Python Unit Test...${NC}"

UNIT_TEST="$SCRIPT_DIR/test-web-dashboard-unit.py"
if [ -f "$UNIT_TEST" ]; then
  UNIT_OUTPUT=$(python3 -m unittest "$UNIT_TEST" 2>&1)
  UNIT_EXIT=$?
  if [ "$UNIT_EXIT" -eq 0 ]; then
    TEST_COUNT=$(echo "$UNIT_OUTPUT" | grep -oE 'Ran [0-9]+ tests' || echo "Ran ? tests")
    pass_test "Python Unit Test 通過 ($TEST_COUNT)"
  else
    echo "$UNIT_OUTPUT"
    fail_test "Python Unit Test 失敗 (exit code $UNIT_EXIT)"
  fi
else
  fail_test "找不到 $UNIT_TEST"
fi

# ══════════════════════════════════════════════════════════
# 結果摘要
# ══════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
total=$((pass_count + fail_count))
echo -e "  總測試數: $total | ${GREEN}PASS: $pass_count${NC} | ${RED}FAIL: $fail_count${NC}"

if [ "$fail_count" -gt 0 ]; then
  echo -e "  ${RED}部分測試失敗${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
  exit 1
else
  echo -e "  ${GREEN}全部測試通過 ✓${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
  exit 0
fi
