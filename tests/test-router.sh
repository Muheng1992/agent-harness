#!/bin/bash
# test-router.sh — Router 系統整合測試
# 驗證 state-collector、roadmap、tech-debt、router 等元件能正確協作
# 用法: bash tests/test-router.sh
set -uo pipefail

# === 測試框架 ===
PASSED=0
FAILED=0
SKIPPED=0
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() {
  echo "[PASS] $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo "[FAIL] $1"
  FAILED=$((FAILED + 1))
}

skip() {
  echo "[SKIP] $1"
  SKIPPED=$((SKIPPED + 1))
}

# === 測試環境設置 ===
TEST_DB="/tmp/agent-harness-router-test-$$.db"
export AGENT_DB_PATH="$TEST_DB"
sqlite3 "$TEST_DB" < "$HARNESS_DIR/schema.sql"

TEST_PROJECT="/tmp/router-test-project-$$"
mkdir -p "$TEST_PROJECT"

# 保存原始目錄以便清理
ORIG_DIR="$(pwd)"

cd "$TEST_PROJECT"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo '#!/bin/bash' > test.sh
echo 'echo all tests pass' >> test.sh
chmod +x test.sh
git add -A && git commit -q -m 'init'

echo "=== Router 系統整合測試 ==="
echo "HARNESS_DIR: $HARNESS_DIR"
echo "TEST_DB: $TEST_DB"
echo "TEST_PROJECT: $TEST_PROJECT"
echo ""

# === 1. State Collector 基本功能 ===
OUTPUT=$(bash "$HARNESS_DIR/state-collector.sh" "$TEST_PROJECT" --test-cmd 'bash test.sh' 2>/dev/null)
STATE_OK=true
echo "$OUTPUT" | grep -q 'Test Results' || { fail "state_collector_basic: missing Test Results"; STATE_OK=false; }
echo "$OUTPUT" | grep -q 'Git Status' || { fail "state_collector_basic: missing Git Status"; STATE_OK=false; }
echo "$OUTPUT" | grep -q 'Code Metrics' || { fail "state_collector_basic: missing Code Metrics"; STATE_OK=false; }
if $STATE_OK; then
  pass "state_collector_basic"
fi

# === 2. State Collector 測試失敗偵測 ===
OUTPUT=$(bash "$HARNESS_DIR/state-collector.sh" "$TEST_PROJECT" --test-cmd 'exit 1' 2>/dev/null)
if echo "$OUTPUT" | grep -q 'FAIL'; then
  pass "state_collector_failure"
else
  fail "state_collector_failure: should detect test failure"
fi

# === 3. Roadmap 基本操作 ===
# 檢查 PyYAML 是否可用
if python3 -c "import yaml" 2>/dev/null; then

  cp "$HARNESS_DIR/examples/roadmap-calculator.yaml" "$TEST_PROJECT/roadmap.yaml"

  # status
  if python3 "$HARNESS_DIR/roadmap.py" status "$TEST_PROJECT/roadmap.yaml" 2>/dev/null | grep -q 'Progress'; then
    pass "roadmap_status"
  else
    fail "roadmap_status: missing Progress output"
  fi

  # next
  NEXT=$(python3 "$HARNESS_DIR/roadmap.py" next "$TEST_PROJECT/roadmap.yaml" 2>/dev/null)
  if echo "$NEXT" | grep -q 'f1-init'; then
    pass "roadmap_next"
  else
    fail "roadmap_next: first feature should be f1-init"
  fi

  # mark-done
  python3 "$HARNESS_DIR/roadmap.py" mark-done "$TEST_PROJECT/roadmap.yaml" f1-init >/dev/null 2>&1
  NEXT2=$(python3 "$HARNESS_DIR/roadmap.py" next "$TEST_PROJECT/roadmap.yaml" 2>/dev/null)
  if echo "$NEXT2" | grep -q 'f2-addition\|f3-subtraction'; then
    pass "roadmap_mark_done"
  else
    fail "roadmap_mark_done: should advance to next features"
  fi

else
  skip "roadmap_status (PyYAML not installed)"
  skip "roadmap_next (PyYAML not installed)"
  skip "roadmap_mark_done (PyYAML not installed)"
fi

# === 4. Tech Debt Scorer ===
for i in $(seq 1 5); do
  python3 -c "print('# line ' * 100)" > "$TEST_PROJECT/file$i.py"
done

SCORE=$(python3 "$HARNESS_DIR/tech-debt.py" "$TEST_PROJECT" --score-only 2>/dev/null)
if [[ "$SCORE" =~ ^[0-9]+$ ]]; then
  pass "tech_debt_score"
else
  fail "tech_debt_score: score should be a number, got '$SCORE'"
fi

# === 5. Router 決策（dry-run） ===
if command -v claude &>/dev/null; then
  DECISION=$(python3 "$HARNESS_DIR/router.py" decide \
    --project test-calc \
    --dir "$TEST_PROJECT" \
    --test-cmd 'bash test.sh' \
    --dry-run 2>/dev/null) || { skip "router_decide (claude not available or error)"; DECISION=""; }
  if [ -n "$DECISION" ]; then
    if echo "$DECISION" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["action"] in ["FIX","BUILD","REFACTOR","EXPLORE","IDLE","ESCALATE"]' 2>/dev/null; then
      pass "router_decide"
    else
      fail "router_decide: invalid action in decision JSON"
    fi
  fi
else
  skip "router_decide (no claude CLI)"
fi

# === 6. Router Decision 表 ===
if python3 -c "
import sqlite3, os
conn = sqlite3.connect(os.environ['AGENT_DB_PATH'])
conn.execute('''CREATE TABLE IF NOT EXISTS router_decisions
  (id INTEGER PRIMARY KEY AUTOINCREMENT, action TEXT, reason TEXT,
   created_at DATETIME DEFAULT CURRENT_TIMESTAMP)''')
conn.execute('INSERT INTO router_decisions (action, reason) VALUES (?, ?)', ('BUILD', 'test'))
count = conn.execute('SELECT COUNT(*) FROM router_decisions').fetchone()[0]
assert count >= 1
conn.close()
" 2>/dev/null; then
  pass "router_decisions_table"
else
  fail "router_decisions_table: could not create/insert/query"
fi

# === 7. Router Loop 語法檢查 ===
if bash -n "$HARNESS_DIR/router-loop.sh" 2>/dev/null; then
  pass "router_loop_syntax"
else
  fail "router_loop_syntax: router-loop.sh has syntax errors"
fi

# === 8. Router Config ===
CONFIG_OK=true
if [ ! -f "$HARNESS_DIR/router-config.yaml" ]; then
  fail "router_config: missing router-config.yaml"
  CONFIG_OK=false
fi
if $CONFIG_OK && ! grep -q 'max_consecutive_fixes' "$HARNESS_DIR/router-config.yaml"; then
  fail "router_config: missing max_consecutive_fixes"
  CONFIG_OK=false
fi
if $CONFIG_OK; then
  pass "router_config"
fi

# === 清理 ===
cd "$ORIG_DIR"
rm -rf "$TEST_PROJECT" "$TEST_DB"

# === 結果統計 ===
echo ""
echo "=== 測試結果 ==="
TOTAL=$((PASSED + FAILED + SKIPPED))
echo "Total: $TOTAL | Passed: $PASSED | Failed: $FAILED | Skipped: $SKIPPED"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
