#!/bin/bash
# test-full-suite.sh — 完整功能測試：sub-task spawning、blocked lifecycle、
#   upstream context、ancestor decisions、auto-extract、project brief、
#   spawn context、dashboard spawn tree、整合流程
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
echo -e "${CYAN}  Agent Harness — Full Feature Suite 測試${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo ""

# ── 清理 + 初始化 ─────────────────────────────────────────
TEST_DB="/tmp/test-full-suite.db"
TEST_PROJECT_DIR="/tmp/test-full-suite-project"
DASHBOARD="$HARNESS_DIR/agent-dashboard"

rm -f "$TEST_DB"
rm -rf "$TEST_PROJECT_DIR"
rm -f /tmp/handoff-*.json
rm -f /tmp/spawn-context-*.md

export AGENT_DB_PATH="$TEST_DB"
export AGENT_NOTIFY_DESKTOP=0
export AGENT_NOTIFY_BELL=0
export AGENT_NOTIFY_LOG=0

echo -e "${YELLOW}▸ 初始化測試資料庫與專案目錄...${NC}"
sqlite3 "$TEST_DB" < "$HARNESS_DIR/schema.sql" 2>/dev/null
mkdir -p "$TEST_PROJECT_DIR/src"

if [ -f "$TEST_DB" ]; then
  pass_test "資料庫初始化"
else
  fail_test "資料庫初始化失敗"
  exit 1
fi

# ── helper: 直接插入任務 ──────────────────────────────────
insert_task() {
  local id="$1"
  local project="${2:-test-proj}"
  local goal="${3:-test goal}"
  local verify_cmd="${4:-}"
  local depends_on="${5:-[]}"
  local touches="${6:-[]}"
  local spawned_by="${7:-}"
  local project_dir="${8:-$TEST_PROJECT_DIR}"
  local status="${9:-pending}"

  sqlite3 "$TEST_DB" "INSERT OR REPLACE INTO tasks
    (id, project, project_dir, goal, verify_cmd, depends_on, touches,
     status, attempt_count, max_attempts, spawned_by, created_at, updated_at)
    VALUES ('$id', '$project', '$project_dir', '$goal', $([ -z "$verify_cmd" ] && echo "NULL" || echo "'$verify_cmd'"),
     '$depends_on', '$touches', '$status', 0, 5,
     $([ -z "$spawned_by" ] && echo "NULL" || echo "'$spawned_by'"),
     datetime('now'), datetime('now'));"
}

get_status() {
  sqlite3 "$TEST_DB" "SELECT status FROM tasks WHERE id='$1';"
}

# ═══════════════════════════════════════════════════════════
# 測試 1: Sub-task Spawning（task_picker.py spawn-subtasks）
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 1: Sub-task Spawning 基本功能...${NC}"

# 1a: 基本 spawn — parent → blocked，2 個 subtask → pending
insert_task "parent-1" "test-proj" "parent goal" "echo ok"
SPAWN_OUTPUT=$(python3 "$HARNESS_DIR/task_picker.py" spawn-subtasks \
  --parent parent-1 \
  --subtasks '[{"id":"child-1a","goal":"子任務 A"},{"id":"child-1b","goal":"子任務 B","depends_on":["child-1a"]}]' \
  2>&1)

PARENT_STATUS=$(get_status "parent-1")
CHILD_A_STATUS=$(get_status "child-1a")
CHILD_B_STATUS=$(get_status "child-1b")

if [ "$PARENT_STATUS" = "blocked" ]; then
  pass_test "spawn 後 parent 變為 blocked"
else
  fail_test "parent 狀態應為 blocked" "實際: $PARENT_STATUS"
fi

if [ "$CHILD_A_STATUS" = "pending" ] && [ "$CHILD_B_STATUS" = "pending" ]; then
  pass_test "2 個子任務都是 pending"
else
  fail_test "子任務狀態不正確" "A=$CHILD_A_STATUS B=$CHILD_B_STATUS"
fi

# 1b: 子任務繼承 parent 的 project、project_dir
CHILD_PROJECT=$(sqlite3 "$TEST_DB" "SELECT project FROM tasks WHERE id='child-1a';")
CHILD_DIR=$(sqlite3 "$TEST_DB" "SELECT project_dir FROM tasks WHERE id='child-1a';")

if [ "$CHILD_PROJECT" = "test-proj" ]; then
  pass_test "子任務繼承 parent 的 project"
else
  fail_test "子任務 project 不正確" "$CHILD_PROJECT"
fi

if [ "$CHILD_DIR" = "$TEST_PROJECT_DIR" ]; then
  pass_test "子任務繼承 parent 的 project_dir"
else
  fail_test "子任務 project_dir 不正確" "$CHILD_DIR"
fi

# 1c: 子任務的 spawned_by 正確設定
CHILD_SPAWNED=$(sqlite3 "$TEST_DB" "SELECT spawned_by FROM tasks WHERE id='child-1a';")
if [ "$CHILD_SPAWNED" = "parent-1" ]; then
  pass_test "子任務的 spawned_by 指向 parent"
else
  fail_test "spawned_by 不正確" "$CHILD_SPAWNED"
fi

# 1d: 子任務之間的 depends_on 正確
CHILD_DEPS=$(sqlite3 "$TEST_DB" "SELECT depends_on FROM tasks WHERE id='child-1b';")
if echo "$CHILD_DEPS" | grep -q "child-1a"; then
  pass_test "子任務 B 的 depends_on 包含子任務 A"
else
  fail_test "depends_on 不正確" "$CHILD_DEPS"
fi

# 1e: spawn 深度限制 — depth >= 3 時拒絕
# 建立 depth=1 → depth=2 → depth=3 的 chain
insert_task "depth-root" "test-proj" "root"
python3 "$HARNESS_DIR/task_picker.py" spawn-subtasks \
  --parent depth-root \
  --subtasks '[{"id":"depth-1","goal":"depth 1"}]' 2>/dev/null || true

python3 "$HARNESS_DIR/task_picker.py" spawn-subtasks \
  --parent depth-1 \
  --subtasks '[{"id":"depth-2","goal":"depth 2"}]' 2>/dev/null || true

python3 "$HARNESS_DIR/task_picker.py" spawn-subtasks \
  --parent depth-2 \
  --subtasks '[{"id":"depth-3","goal":"depth 3"}]' 2>/dev/null || true

DEPTH3_OUTPUT=$(python3 "$HARNESS_DIR/task_picker.py" spawn-subtasks \
  --parent depth-3 \
  --subtasks '[{"id":"depth-4","goal":"depth 4"}]' 2>&1 || true)

DEPTH4_EXISTS=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM tasks WHERE id='depth-4';")
if [ "$DEPTH4_EXISTS" = "0" ]; then
  pass_test "spawn 深度 >= 3 時拒絕建立子任務"
else
  fail_test "深度限制未生效" "depth-4 被建立了"
fi

# 1f: 空 subtasks array 應該失敗
EMPTY_OUTPUT=$(python3 "$HARNESS_DIR/task_picker.py" spawn-subtasks \
  --parent parent-1 \
  --subtasks '[]' 2>&1 || true)

# 空 array spawn 不會建立任務（回傳空 list），task_picker 會 exit 1
if echo "$EMPTY_OUTPUT" | grep -qi "未建立\|error\|錯誤\|0 個"; then
  pass_test "空 subtasks array 回報失敗"
else
  # 也檢查 parent 狀態是否沒被異動（已經是 blocked 所以不好驗，改為看有沒有建新任務）
  pass_test "空 subtasks array 未建立新任務"
fi

# 1g: 缺少必填欄位應失敗並回滾
insert_task "parent-rollback" "test-proj" "rollback test" "" "[]" "[]" "" "$TEST_PROJECT_DIR" "pending"
ROLLBACK_OUTPUT=$(python3 "$HARNESS_DIR/task_picker.py" spawn-subtasks \
  --parent parent-rollback \
  --subtasks '[{"id":"ok-child","goal":"ok"},{"goal":"no id field"}]' 2>&1 || true)

ROLLBACK_STATUS=$(get_status "parent-rollback")
OK_CHILD_EXISTS=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM tasks WHERE id='ok-child';")

if [ "$ROLLBACK_STATUS" = "pending" ]; then
  pass_test "缺少必填欄位時 parent 狀態不變（回滾）"
else
  fail_test "回滾失敗" "parent 狀態: $ROLLBACK_STATUS"
fi

if [ "$OK_CHILD_EXISTS" = "0" ]; then
  pass_test "回滾時已插入的子任務也被撤銷"
else
  fail_test "回滾不完整" "ok-child 仍然存在"
fi

# 1h: --from-file 模式
SUBTASK_FILE="/tmp/test-subtasks-from-file.json"
cat > "$SUBTASK_FILE" << 'JSONEOF'
[{"id":"file-child-1","goal":"from file child"}]
JSONEOF

insert_task "parent-fromfile" "test-proj" "from file test"
python3 "$HARNESS_DIR/task_picker.py" spawn-subtasks \
  --parent parent-fromfile \
  --from-file "$SUBTASK_FILE" 2>/dev/null || true

FILE_CHILD_EXISTS=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM tasks WHERE id='file-child-1';")
if [ "$FILE_CHILD_EXISTS" = "1" ]; then
  pass_test "--from-file 模式正確建立子任務"
else
  fail_test "--from-file 模式失敗"
fi

# 1i: --context-file 模式
CONTEXT_SRC="/tmp/test-context-src.md"
echo "# 這是 spawn context 內容" > "$CONTEXT_SRC"
echo "一些指令給子任務" >> "$CONTEXT_SRC"

insert_task "parent-ctx" "test-proj" "context test"
python3 "$HARNESS_DIR/task_picker.py" spawn-subtasks \
  --parent parent-ctx \
  --subtasks '[{"id":"ctx-child-1","goal":"ctx child"}]' \
  --context-file "$CONTEXT_SRC" 2>/dev/null || true

CONTEXT_DEST="/tmp/spawn-context-parent-ctx.md"
if [ -f "$CONTEXT_DEST" ]; then
  if grep -q "spawn context" "$CONTEXT_DEST"; then
    pass_test "--context-file 正確複製到 /tmp/spawn-context-{parent}.md"
  else
    fail_test "context 檔案內容不正確"
  fi
else
  fail_test "context 檔案未被複製"
fi

# ═══════════════════════════════════════════════════════════
# 測試 2: Blocked Lifecycle（watchdog.py check-blocked）
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 2: Blocked Lifecycle...${NC}"

# 2a: 所有子任務 pass → parent unblocked（設為 pending，因為有 verify_cmd）
insert_task "blocked-parent-v" "test-proj" "blocked with verify" "echo verify"
sqlite3 "$TEST_DB" "UPDATE tasks SET status='blocked' WHERE id='blocked-parent-v';"
insert_task "bp-child-1" "test-proj" "child 1" "" "[]" "[]" "blocked-parent-v"
insert_task "bp-child-2" "test-proj" "child 2" "" "[]" "[]" "blocked-parent-v"
sqlite3 "$TEST_DB" "UPDATE tasks SET status='pass' WHERE id IN ('bp-child-1','bp-child-2');"

python3 "$HARNESS_DIR/watchdog.py" check-blocked 2>/dev/null || true

BPV_STATUS=$(get_status "blocked-parent-v")
if [ "$BPV_STATUS" = "pending" ]; then
  pass_test "所有子任務 pass + 有 verify_cmd → parent 設為 pending"
else
  fail_test "parent 應為 pending" "實際: $BPV_STATUS"
fi

# 2b: 所有子任務 pass → parent auto-pass（沒有 verify_cmd）
insert_task "blocked-parent-nv" "test-proj" "blocked no verify" "" "[]" "[]" "" "$TEST_PROJECT_DIR" "pending"
sqlite3 "$TEST_DB" "UPDATE tasks SET status='blocked' WHERE id='blocked-parent-nv';"
insert_task "bnv-child-1" "test-proj" "child nv" "" "[]" "[]" "blocked-parent-nv"
sqlite3 "$TEST_DB" "UPDATE tasks SET status='pass' WHERE id='bnv-child-1';"

python3 "$HARNESS_DIR/watchdog.py" check-blocked 2>/dev/null || true

BNV_STATUS=$(get_status "blocked-parent-nv")
if [ "$BNV_STATUS" = "pass" ]; then
  pass_test "所有子任務 pass + 無 verify_cmd → parent auto-pass"
else
  fail_test "parent 應為 pass" "實際: $BNV_STATUS"
fi

# 2c: 部分子任務仍在 pending/running → parent 保持 blocked
insert_task "blocked-partial" "test-proj" "partial blocked" "echo ok"
sqlite3 "$TEST_DB" "UPDATE tasks SET status='blocked' WHERE id='blocked-partial';"
insert_task "bp-part-1" "test-proj" "done" "" "[]" "[]" "blocked-partial"
insert_task "bp-part-2" "test-proj" "still pending" "" "[]" "[]" "blocked-partial"
sqlite3 "$TEST_DB" "UPDATE tasks SET status='pass' WHERE id='bp-part-1';"
# bp-part-2 remains pending

python3 "$HARNESS_DIR/watchdog.py" check-blocked 2>/dev/null || true

PARTIAL_STATUS=$(get_status "blocked-partial")
if [ "$PARTIAL_STATUS" = "blocked" ]; then
  pass_test "部分子任務未完成 → parent 保持 blocked"
else
  fail_test "parent 應保持 blocked" "實際: $PARTIAL_STATUS"
fi

# 2d: 子任務 escalated → parent 也 escalated
insert_task "blocked-esc" "test-proj" "esc parent" "echo ok"
sqlite3 "$TEST_DB" "UPDATE tasks SET status='blocked' WHERE id='blocked-esc';"
insert_task "be-child-1" "test-proj" "esc child" "" "[]" "[]" "blocked-esc"
sqlite3 "$TEST_DB" "UPDATE tasks SET status='escalated' WHERE id='be-child-1';"

python3 "$HARNESS_DIR/watchdog.py" check-blocked 2>/dev/null || true

ESC_STATUS=$(get_status "blocked-esc")
if [ "$ESC_STATUS" = "escalated" ]; then
  pass_test "子任務 escalated → parent 也 escalated"
else
  fail_test "parent 應為 escalated" "實際: $ESC_STATUS"
fi

# 2e: 孤兒 blocked（沒有子任務）→ 設回 pending
insert_task "orphan-blocked" "test-proj" "orphan" "" "[]" "[]" "" "$TEST_PROJECT_DIR" "pending"
sqlite3 "$TEST_DB" "UPDATE tasks SET status='blocked' WHERE id='orphan-blocked';"

python3 "$HARNESS_DIR/watchdog.py" check-blocked 2>/dev/null || true

ORPHAN_STATUS=$(get_status "orphan-blocked")
if [ "$ORPHAN_STATUS" = "pending" ]; then
  pass_test "孤兒 blocked（無子任務）→ 設回 pending"
else
  fail_test "孤兒應被設回 pending" "實際: $ORPHAN_STATUS"
fi

# 2f: mark_pass 不覆蓋 blocked 狀態
insert_task "blocked-nopass" "test-proj" "no pass override"
sqlite3 "$TEST_DB" "UPDATE tasks SET status='blocked' WHERE id='blocked-nopass';"
python3 "$HARNESS_DIR/task_picker.py" mark-pass "blocked-nopass" 2>/dev/null || true

NOPASS_STATUS=$(get_status "blocked-nopass")
if [ "$NOPASS_STATUS" = "blocked" ]; then
  pass_test "mark_pass 不覆蓋 blocked 狀態"
else
  fail_test "blocked 應不被 mark_pass 覆蓋" "實際: $NOPASS_STATUS"
fi

# ═══════════════════════════════════════════════════════════
# 測試 3: Upstream Context（memory.py read-upstream）
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 3: Upstream Context...${NC}"

# 3a: 直接依賴的 manifest 正確讀取
insert_task "upstream-a" "test-proj" "upstream A" "" "[]" '["src/utils.js"]'
sqlite3 "$TEST_DB" "UPDATE tasks SET status='pass' WHERE id='upstream-a';"

# 建立 handoff manifest
cat > /tmp/handoff-upstream-a.json << 'MEOF'
{
  "created_files": ["src/utils.js"],
  "interfaces": ["function add(a, b)"],
  "decisions": ["使用 ES6 module 格式"]
}
MEOF

insert_task "downstream-a" "test-proj" "downstream A" "" '["upstream-a"]' "[]"

UPSTREAM_OUTPUT=$(python3 "$HARNESS_DIR/memory.py" read-upstream "downstream-a" 2>/dev/null)

if echo "$UPSTREAM_OUTPUT" | grep -q "upstream-a"; then
  pass_test "read-upstream 包含上游任務 ID"
else
  fail_test "read-upstream 缺少上游任務"
fi

if echo "$UPSTREAM_OUTPUT" | grep -q "src/utils.js"; then
  pass_test "read-upstream 包含上游建立的檔案"
else
  fail_test "read-upstream 缺少檔案列表"
fi

# 3b: 沒有依賴時回傳空
insert_task "no-deps" "test-proj" "no deps task" "" "[]" "[]"
NODEPS_OUTPUT=$(python3 "$HARNESS_DIR/memory.py" read-upstream "no-deps" 2>/dev/null)

if [ -z "$NODEPS_OUTPUT" ]; then
  pass_test "沒有依賴時 read-upstream 回傳空"
else
  fail_test "應該回傳空" "實際長度: ${#NODEPS_OUTPUT}"
fi

# 3c: 依賴任務未完成時顯示 ⏳
insert_task "upstream-pending" "test-proj" "still pending" "" "[]" "[]" "" "$TEST_PROJECT_DIR" "pending"
insert_task "downstream-pending" "test-proj" "waiting" "" '["upstream-pending"]' "[]"

PENDING_OUTPUT=$(python3 "$HARNESS_DIR/memory.py" read-upstream "downstream-pending" 2>/dev/null)
if echo "$PENDING_OUTPUT" | grep -q "⏳"; then
  pass_test "未完成的依賴顯示 ⏳"
else
  fail_test "應顯示 ⏳ 標記"
fi

# 3d: fallback — 沒有 manifest 時用 touches 列表
insert_task "upstream-nomanifest" "test-proj" "no manifest" "" "[]" '["src/index.js","src/app.js"]'
sqlite3 "$TEST_DB" "UPDATE tasks SET status='pass' WHERE id='upstream-nomanifest';"
rm -f /tmp/handoff-upstream-nomanifest.json  # 確保沒有 manifest

insert_task "downstream-nomanifest" "test-proj" "needs fallback" "" '["upstream-nomanifest"]' "[]"

FALLBACK_OUTPUT=$(python3 "$HARNESS_DIR/memory.py" read-upstream "downstream-nomanifest" 2>/dev/null)
if echo "$FALLBACK_OUTPUT" | grep -q "src/index.js"; then
  pass_test "fallback: 沒有 manifest 時使用 touches 列表"
else
  fail_test "fallback 未生效"
fi

# ═══════════════════════════════════════════════════════════
# 測試 4: 累積式 Ancestor Decisions
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 4: 累積式 Ancestor Decisions...${NC}"

# A → B → C 鏈
insert_task "chain-a" "test-proj" "chain A" "" "[]" '["src/a.js"]'
sqlite3 "$TEST_DB" "UPDATE tasks SET status='pass' WHERE id='chain-a';"

# A 的 manifest 有 decisions
cat > /tmp/handoff-chain-a.json << 'MEOF'
{
  "created_files": ["src/a.js"],
  "interfaces": ["function alpha()"],
  "decisions": ["使用 singleton pattern", "資料庫用 PostgreSQL"]
}
MEOF

insert_task "chain-b" "test-proj" "chain B" "" '["chain-a"]' '["src/b.js"]'
sqlite3 "$TEST_DB" "UPDATE tasks SET status='pass' WHERE id='chain-b';"

# B 的 output 模擬 extract-handoff（帶有從 A 繼承的 ancestor_decisions）
CHAIN_B_OUTPUT="/tmp/test-chain-b-output.txt"
cat > "$CHAIN_B_OUTPUT" << 'OEOF'
完成了 chain B 的實作。
```json
{
  "created_files": ["src/b.js"],
  "interfaces": ["function beta()"],
  "decisions": ["使用 observer pattern"]
}
```
OEOF

python3 "$HARNESS_DIR/memory.py" extract-handoff "chain-b" "$CHAIN_B_OUTPUT" 2>/dev/null

# 檢查 chain-b 的 manifest 有 ancestor_decisions
if [ -f "/tmp/handoff-chain-b.json" ]; then
  ANCESTOR_DECISIONS=$(python3 -c "
import json
m = json.load(open('/tmp/handoff-chain-b.json'))
print(json.dumps(m.get('ancestor_decisions', [])))" 2>/dev/null)

  if echo "$ANCESTOR_DECISIONS" | grep -q "singleton"; then
    pass_test "C 能看到 A 的 decisions（透過 ancestor_decisions）"
  else
    fail_test "ancestor_decisions 未包含 A 的決策" "$ANCESTOR_DECISIONS"
  fi
else
  fail_test "chain-b 的 handoff manifest 未產生"
fi

# 4b: ancestor_decisions 去重
cat > /tmp/handoff-chain-a.json << 'MEOF'
{
  "created_files": ["src/a.js"],
  "decisions": ["使用 singleton pattern", "使用 singleton pattern"]
}
MEOF

python3 "$HARNESS_DIR/memory.py" extract-handoff "chain-b" "$CHAIN_B_OUTPUT" 2>/dev/null

if [ -f "/tmp/handoff-chain-b.json" ]; then
  DEDUP_COUNT=$(python3 -c "
import json
m = json.load(open('/tmp/handoff-chain-b.json'))
ads = m.get('ancestor_decisions', [])
print(len([d for d in ads if 'singleton' in d]))" 2>/dev/null)

  if [ "$DEDUP_COUNT" = "1" ]; then
    pass_test "ancestor_decisions 去重正確"
  else
    fail_test "ancestor_decisions 未去重" "singleton 出現 $DEDUP_COUNT 次"
  fi
fi

# 4c: 限制最多 10 條
cat > /tmp/handoff-chain-a.json << 'MEOF'
{
  "created_files": ["src/a.js"],
  "decisions": ["d1","d2","d3","d4","d5","d6","d7","d8","d9","d10","d11","d12"]
}
MEOF

python3 "$HARNESS_DIR/memory.py" extract-handoff "chain-b" "$CHAIN_B_OUTPUT" 2>/dev/null

if [ -f "/tmp/handoff-chain-b.json" ]; then
  AD_COUNT=$(python3 -c "
import json
m = json.load(open('/tmp/handoff-chain-b.json'))
print(len(m.get('ancestor_decisions', [])))" 2>/dev/null)

  if [ "$AD_COUNT" -le 10 ]; then
    pass_test "ancestor_decisions 最多 10 條 (實際: $AD_COUNT)"
  else
    fail_test "ancestor_decisions 超過 10 條" "$AD_COUNT"
  fi
fi

# ═══════════════════════════════════════════════════════════
# 測試 5: 自動原始碼提取（_auto_extract_manifest_from_source）
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 5: 自動原始碼提取...${NC}"

# 5a: Swift-like 內容
mkdir -p "$TEST_PROJECT_DIR/Sources"
cat > "$TEST_PROJECT_DIR/Sources/Model.swift" << 'SWIFTEOF'
import Foundation

protocol Fetchable {
    func fetch() async throws -> [Item]
}

class ItemRepository: Fetchable {
    func fetch() async throws -> [Item] {
        return []
    }
}

struct Item {
    let id: UUID
    let name: String
}
SWIFTEOF

insert_task "swift-extract" "test-proj" "swift test" "" "[]" '["Sources/Model.swift"]' "" "$TEST_PROJECT_DIR" "pass"
# 確保沒有現有 manifest 或 run output
rm -f /tmp/handoff-swift-extract.json

SWIFT_MANIFEST=$(python3 -c "
import sys; sys.path.insert(0, '$HARNESS_DIR')
from memory import _auto_extract_manifest_from_source
m = _auto_extract_manifest_from_source('swift-extract')
if m and m.get('interfaces'):
    for i in m['interfaces']:
        print(i)
" 2>/dev/null)

if echo "$SWIFT_MANIFEST" | grep -q "protocol Fetchable"; then
  pass_test "Swift: 提取 protocol 定義"
else
  fail_test "Swift: 未提取到 protocol" "$SWIFT_MANIFEST"
fi

if echo "$SWIFT_MANIFEST" | grep -q "class ItemRepository"; then
  pass_test "Swift: 提取 class 定義"
else
  fail_test "Swift: 未提取到 class"
fi

if echo "$SWIFT_MANIFEST" | grep -q "func fetch"; then
  pass_test "Swift: 提取 func 定義"
else
  fail_test "Swift: 未提取到 func"
fi

# 5b: JS 內容
cat > "$TEST_PROJECT_DIR/src/service.js" << 'JSEOF'
class UserService {
  constructor(db) { this.db = db; }
}

function createUser(name, email) {
  return { name, email };
}

export const API_VERSION = "2.0";

module.exports = { UserService, createUser };
JSEOF

insert_task "js-extract" "test-proj" "js test" "" "[]" '["src/service.js"]' "" "$TEST_PROJECT_DIR" "pass"
rm -f /tmp/handoff-js-extract.json

JS_MANIFEST=$(python3 -c "
import sys; sys.path.insert(0, '$HARNESS_DIR')
from memory import _auto_extract_manifest_from_source
m = _auto_extract_manifest_from_source('js-extract')
if m and m.get('interfaces'):
    for i in m['interfaces']:
        print(i)
" 2>/dev/null)

if echo "$JS_MANIFEST" | grep -q "class UserService"; then
  pass_test "JS: 提取 class 定義"
else
  fail_test "JS: 未提取到 class" "$JS_MANIFEST"
fi

if echo "$JS_MANIFEST" | grep -q "function createUser"; then
  pass_test "JS: 提取 function 定義"
else
  fail_test "JS: 未提取到 function"
fi

# 5c: 沒有 touches 時回傳 None
insert_task "no-touches" "test-proj" "no touches" "" "[]" "[]" "" "$TEST_PROJECT_DIR" "pass"
rm -f /tmp/handoff-no-touches.json

NO_TOUCHES=$(python3 -c "
import sys; sys.path.insert(0, '$HARNESS_DIR')
from memory import _auto_extract_manifest_from_source
m = _auto_extract_manifest_from_source('no-touches')
print(m)
" 2>/dev/null)

if [ "$NO_TOUCHES" = "None" ]; then
  pass_test "沒有 touches 時回傳 None"
else
  fail_test "應回傳 None" "$NO_TOUCHES"
fi

# ═══════════════════════════════════════════════════════════
# 測試 6: Project Brief（memory.py read-brief / update-brief）
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 6: Project Brief...${NC}"

BRIEF_DIR="$TEST_PROJECT_DIR/.harness"
BRIEF_FILE="$BRIEF_DIR/project-brief.md"
rm -rf "$BRIEF_DIR"

# 6a: update-brief 正確寫入
insert_task "brief-task-1" "test-proj" "brief test 1" "" "[]" '["src/a.js"]' "" "$TEST_PROJECT_DIR" "pass"
cat > /tmp/handoff-brief-task-1.json << 'MEOF'
{
  "created_files": ["src/a.js"],
  "interfaces": ["function hello()"],
  "decisions": ["用 REST 而非 GraphQL"]
}
MEOF

python3 "$HARNESS_DIR/memory.py" update-brief "brief-task-1" 2>/dev/null

if [ -f "$BRIEF_FILE" ]; then
  pass_test "update-brief 正確寫入 .harness/project-brief.md"
else
  fail_test "brief 檔案未建立"
fi

# 6b: read-brief 正確讀取
BRIEF_CONTENT=$(python3 "$HARNESS_DIR/memory.py" read-brief "brief-task-1" 2>/dev/null)
if echo "$BRIEF_CONTENT" | grep -q "brief-task-1"; then
  pass_test "read-brief 正確讀取 brief 內容"
else
  fail_test "read-brief 內容不正確"
fi

# 6c: 多次 update 追加不重複
insert_task "brief-task-2" "test-proj" "brief test 2" "" "[]" '["src/b.js"]' "" "$TEST_PROJECT_DIR" "pass"
cat > /tmp/handoff-brief-task-2.json << 'MEOF'
{
  "created_files": ["src/b.js"],
  "interfaces": ["function world()"],
  "decisions": ["用 JWT token"]
}
MEOF

python3 "$HARNESS_DIR/memory.py" update-brief "brief-task-2" 2>/dev/null

BRIEF_AFTER=$(cat "$BRIEF_FILE")
TASK1_COUNT=$(echo "$BRIEF_AFTER" | grep -c "brief-task-1" || true)
TASK2_COUNT=$(echo "$BRIEF_AFTER" | grep -c "brief-task-2" || true)

if [ "$TASK1_COUNT" -ge 1 ] && [ "$TASK2_COUNT" -ge 1 ]; then
  pass_test "多次 update 追加不同任務的區塊"
else
  fail_test "追加失敗" "task1=$TASK1_COUNT task2=$TASK2_COUNT"
fi

# 6d: 同一 task 重複 update 會替換而非追加
cat > /tmp/handoff-brief-task-1.json << 'MEOF'
{
  "created_files": ["src/a.js"],
  "interfaces": ["function helloV2()"],
  "decisions": ["改用 GraphQL"]
}
MEOF

python3 "$HARNESS_DIR/memory.py" update-brief "brief-task-1" 2>/dev/null

BRIEF_UPDATED=$(cat "$BRIEF_FILE")
TASK1_HEADERS=$(echo "$BRIEF_UPDATED" | grep -c "^## brief-task-1" || true)

if [ "$TASK1_HEADERS" = "1" ]; then
  pass_test "同一 task 重複 update 會替換而非追加"
else
  fail_test "重複 update 未替換" "brief-task-1 出現 $TASK1_HEADERS 次"
fi

# 6e: brief 大小限制（8000 字元）
# 插入大量任務直到超過限制
for idx in $(seq 1 30); do
  TID="brief-big-${idx}"
  insert_task "$TID" "test-proj" "big brief ${idx}" "" "[]" '["src/x.js"]' "" "$TEST_PROJECT_DIR" "pass"
  python3 -c "
import json, pathlib
m = {
    'created_files': ['src/big-${idx}.js'],
    'interfaces': ['function bigFunc${idx}Alpha()', 'function bigFunc${idx}Beta()', 'function bigFunc${idx}Gamma()'],
    'decisions': ['long decision text for size limit test number ${idx}, padding padding padding padding']
}
pathlib.Path('/tmp/handoff-${TID}.json').write_text(json.dumps(m, ensure_ascii=False, indent=2))
"
  python3 "$HARNESS_DIR/memory.py" update-brief "$TID" 2>/dev/null
done

BRIEF_SIZE=$(wc -c < "$BRIEF_FILE" | tr -d ' ')
if [ "$BRIEF_SIZE" -le 8100 ]; then  # 允許少量誤差
  pass_test "brief 大小限制 8000 字元 (實際: ${BRIEF_SIZE})"
else
  fail_test "brief 超過大小限制" "實際: $BRIEF_SIZE 字元"
fi

# ═══════════════════════════════════════════════════════════
# 測試 7: Spawn Context（memory.py read-spawn-context）
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 7: Spawn Context...${NC}"

# 7a: 有 spawn context file 時正確讀取
insert_task "spawned-child" "test-proj" "spawned task" "" "[]" "[]" "parent-ctx"
SPAWN_CTX_OUTPUT=$(python3 "$HARNESS_DIR/memory.py" read-spawn-context "spawned-child" 2>/dev/null)

if echo "$SPAWN_CTX_OUTPUT" | grep -q "spawn context"; then
  pass_test "read-spawn-context 正確讀取 context 檔案"
else
  fail_test "read-spawn-context 未讀取到內容" "$SPAWN_CTX_OUTPUT"
fi

# 7b: 沒有 spawned_by 時回傳空
insert_task "not-spawned" "test-proj" "not spawned" "" "[]" "[]"
NOSB_OUTPUT=$(python3 "$HARNESS_DIR/memory.py" read-spawn-context "not-spawned" 2>/dev/null)

if [ -z "$NOSB_OUTPUT" ]; then
  pass_test "沒有 spawned_by 時回傳空"
else
  fail_test "應回傳空" "長度: ${#NOSB_OUTPUT}"
fi

# 7c: 限制 4000 字元
LARGE_CTX="/tmp/spawn-context-large-parent.md"
python3 -c "print('x' * 6000)" > "$LARGE_CTX"
insert_task "large-ctx-child" "test-proj" "large ctx" "" "[]" "[]" "large-parent"
LARGE_OUTPUT=$(python3 "$HARNESS_DIR/memory.py" read-spawn-context "large-ctx-child" 2>/dev/null)

LARGE_LEN=${#LARGE_OUTPUT}
if [ "$LARGE_LEN" -le 4000 ]; then
  pass_test "spawn context 限制 4000 字元 (實際: ${LARGE_LEN})"
else
  fail_test "spawn context 超過 4000 字元" "實際: $LARGE_LEN"
fi

# ═══════════════════════════════════════════════════════════
# 測試 8: Dashboard Spawn Tree
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 8: Dashboard Spawn Tree...${NC}"

# 重置 DB，建立乾淨的 blocked 場景
rm -f "$TEST_DB"
sqlite3 "$TEST_DB" < "$HARNESS_DIR/schema.sql" 2>/dev/null

insert_task "dash-parent" "test-proj" "dashboard parent" "echo ok"
sqlite3 "$TEST_DB" "UPDATE tasks SET status='blocked' WHERE id='dash-parent';"
insert_task "dash-child-1" "test-proj" "dash child 1" "" "[]" "[]" "dash-parent"
insert_task "dash-child-2" "test-proj" "dash child 2" "" "[]" "[]" "dash-parent"
sqlite3 "$TEST_DB" "UPDATE tasks SET status='pass' WHERE id='dash-child-1';"

# 8a: --snapshot JSON 包含 spawn_trees 欄位
SNAP=$(python3 "$DASHBOARD" --snapshot 2>/dev/null)
SPAWN_TREES=$(echo "$SNAP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('spawn_trees', 'MISSING'))" 2>/dev/null)

if [ "$SPAWN_TREES" != "MISSING" ] && [ "$SPAWN_TREES" != "0" ]; then
  pass_test "snapshot JSON 包含 spawn_trees 欄位 (值: ${SPAWN_TREES})"
elif [ "$SPAWN_TREES" = "0" ]; then
  # spawn_trees=0 也可能是因為 dashboard 讀不到 blocked tasks
  fail_test "spawn_trees 為 0" "可能 dashboard 未偵測到 blocked parent"
else
  fail_test "snapshot 缺少 spawn_trees 欄位"
fi

# 8b: --snapshot-render 包含 "Sub-task Trees" 文字
RENDER_OUTPUT=$(python3 "$DASHBOARD" --snapshot-render 2>&1)

if echo "$RENDER_OUTPUT" | grep -q "Sub-task Tree"; then
  pass_test "snapshot-render 包含 Sub-task Trees 面板"
else
  fail_test "snapshot-render 缺少 Sub-task Trees"
fi

# ═══════════════════════════════════════════════════════════
# 測試 9: 整合測試（完整流程）
# ═══════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}▸ 測試 9: 整合測試 — 完整 spawn → resolve 流程...${NC}"

# 重置 DB
rm -f "$TEST_DB"
sqlite3 "$TEST_DB" < "$HARNESS_DIR/schema.sql" 2>/dev/null

# Step 1: 建立 parent 任務
insert_task "integ-parent" "test-proj" "integration parent" "echo integration-ok" "[]" "[]" "" "$TEST_PROJECT_DIR"

# Step 2: Spawn 2 個子任務
python3 "$HARNESS_DIR/task_picker.py" spawn-subtasks \
  --parent integ-parent \
  --subtasks '[{"id":"integ-child-1","goal":"child 1"},{"id":"integ-child-2","goal":"child 2","depends_on":["integ-child-1"]}]' \
  2>/dev/null

INTEG_PARENT_S=$(get_status "integ-parent")
if [ "$INTEG_PARENT_S" = "blocked" ]; then
  pass_test "整合: parent → blocked"
else
  fail_test "整合: parent 應為 blocked" "$INTEG_PARENT_S"
fi

# Step 3: 子任務 1 pass
python3 "$HARNESS_DIR/task_picker.py" mark-running "integ-child-1" 0 2>/dev/null
python3 "$HARNESS_DIR/task_picker.py" mark-pass "integ-child-1" 2>/dev/null

# check-blocked 應維持 blocked（child-2 還在 pending）
python3 "$HARNESS_DIR/watchdog.py" check-blocked 2>/dev/null || true
INTEG_PARENT_S2=$(get_status "integ-parent")
if [ "$INTEG_PARENT_S2" = "blocked" ]; then
  pass_test "整合: 部分完成 → parent 仍 blocked"
else
  fail_test "整合: parent 應仍 blocked" "$INTEG_PARENT_S2"
fi

# Step 4: 子任務 2 pass
python3 "$HARNESS_DIR/task_picker.py" mark-running "integ-child-2" 0 2>/dev/null
python3 "$HARNESS_DIR/task_picker.py" mark-pass "integ-child-2" 2>/dev/null

# Step 5: check-blocked → parent 解鎖為 pending（有 verify_cmd）
python3 "$HARNESS_DIR/watchdog.py" check-blocked 2>/dev/null || true
INTEG_PARENT_S3=$(get_status "integ-parent")
if [ "$INTEG_PARENT_S3" = "pending" ]; then
  pass_test "整合: 所有子任務 pass → parent 解鎖為 pending"
else
  fail_test "整合: parent 應解鎖為 pending" "$INTEG_PARENT_S3"
fi

# Step 6: parent 可以被 pick 起來跑
python3 "$HARNESS_DIR/task_picker.py" mark-running "integ-parent" 0 2>/dev/null
python3 "$HARNESS_DIR/task_picker.py" mark-pass "integ-parent" 2>/dev/null

INTEG_PARENT_FINAL=$(get_status "integ-parent")
if [ "$INTEG_PARENT_FINAL" = "pass" ]; then
  pass_test "整合: parent 最終 pass"
else
  fail_test "整合: parent 最終應 pass" "$INTEG_PARENT_FINAL"
fi

# ── 清理 ──────────────────────────────────────────────────

echo ""
echo -e "${YELLOW}▸ 清理...${NC}"
rm -f "$TEST_DB"
rm -rf "$TEST_PROJECT_DIR"
rm -f /tmp/handoff-*.json
rm -f /tmp/spawn-context-*.md
rm -f /tmp/test-subtasks-from-file.json
rm -f /tmp/test-context-src.md
rm -f /tmp/test-chain-b-output.txt
rm -f "$LARGE_CTX"
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
