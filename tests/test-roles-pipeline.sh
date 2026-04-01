#!/bin/bash
# test-roles-pipeline.sh — 端對端整合測試：多角色 pipeline 系統
# 用法: bash tests/test-roles-pipeline.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$HARNESS_DIR"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "[PASS] $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "[FAIL] $1: $2" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
  # 清理後退出
  cleanup
  exit 1
}

# ═══════════════════════════════════════════════════════════
# 步驟 0：初始化測試 DB
# ═══════════════════════════════════════════════════════════
TEST_DB="/tmp/agent-harness-test-$$.db"
export AGENT_DB_PATH="$TEST_DB"

cleanup() {
  rm -f "$TEST_DB" /tmp/test-task-*.json
  rm -rf /tmp/test-import-dir-$$
}
trap cleanup EXIT INT TERM

sqlite3 "$TEST_DB" < schema.sql
pass "init_test_db"

# ═══════════════════════════════════════════════════════════
# 步驟 1：測試角色定義載入
# ═══════════════════════════════════════════════════════════

# 1a. 確認所有 11 個角色定義檔存在
EXPECTED_ROLES="architect debugger devops documenter implementer integrator planner researcher reviewer security-auditor tester"
ROLE_COUNT=0
for role in $EXPECTED_ROLES; do
  if [ ! -f "roles/${role}.md" ]; then
    fail "role_files_exist" "角色定義檔不存在: roles/${role}.md"
  fi
  ROLE_COUNT=$((ROLE_COUNT + 1))
done
if [ "$ROLE_COUNT" -ne 11 ]; then
  fail "role_files_exist" "預期 11 個角色，實際 ${ROLE_COUNT}"
fi
pass "role_files_exist (${ROLE_COUNT} roles)"

# 1b. 確認每個角色定義檔都有 frontmatter（name, allowed_tools）
for role in $EXPECTED_ROLES; do
  ROLE_FILE="roles/${role}.md"
  # 檢查 frontmatter 開頭的 ---
  FIRST_LINE=$(head -1 "$ROLE_FILE")
  if [ "$FIRST_LINE" != "---" ]; then
    fail "role_frontmatter" "${role} 缺少 frontmatter 開頭 ---"
  fi
  # 檢查 name 欄位
  if ! sed -n '1,/^---$/p' "$ROLE_FILE" | tail -n +2 | grep -q '^name:'; then
    fail "role_frontmatter" "${role} 缺少 name 欄位"
  fi
  # 檢查 allowed_tools 欄位
  if ! sed -n '1,/^---$/p' "$ROLE_FILE" | tail -n +2 | grep -q '^allowed_tools:'; then
    fail "role_frontmatter" "${role} 缺少 allowed_tools 欄位"
  fi
done
pass "role_frontmatter (all have name + allowed_tools)"

# 1c. 確認 researcher 角色有 WebSearch 工具
RESEARCHER_TOOLS=$(sed -n '/^---$/,/^---$/p' roles/researcher.md | grep 'allowed_tools:' | cut -d':' -f2-)
if ! echo "$RESEARCHER_TOOLS" | grep -q 'WebSearch'; then
  fail "researcher_websearch" "researcher 角色缺少 WebSearch 工具，目前工具: $RESEARCHER_TOOLS"
fi
pass "researcher_has_WebSearch"

# 1d. 確認 reviewer 角色沒有 Write/Edit 工具（只讀）
REVIEWER_TOOLS=$(sed -n '/^---$/,/^---$/p' roles/reviewer.md | grep 'allowed_tools:' | cut -d':' -f2-)
if echo "$REVIEWER_TOOLS" | grep -q 'Write'; then
  fail "reviewer_readonly" "reviewer 角色不應有 Write 工具，目前工具: $REVIEWER_TOOLS"
fi
if echo "$REVIEWER_TOOLS" | grep -q 'Edit'; then
  fail "reviewer_readonly" "reviewer 角色不應有 Edit 工具，目前工具: $REVIEWER_TOOLS"
fi
pass "reviewer_readonly (no Write/Edit)"

# ═══════════════════════════════════════════════════════════
# 步驟 2：測試 task_picker 角色支援
# ═══════════════════════════════════════════════════════════

# 2a. 建立測試 task JSON（含 role 欄位）並匯入
TEST_IMPORT_DIR="/tmp/test-import-dir-$$"
mkdir -p "$TEST_IMPORT_DIR"

cat > "$TEST_IMPORT_DIR/task-researcher.json" <<'EOF'
{
  "id": "test-researcher-001",
  "project": "test-project",
  "goal": "研究最佳實踐",
  "verify": "echo ok",
  "depends_on": [],
  "touches": ["research.md"],
  "role": "researcher",
  "stage": "research",
  "pipeline_id": "test-pipe-auto"
}
EOF

cat > "$TEST_IMPORT_DIR/task-implementer.json" <<'EOF'
{
  "id": "test-impl-001",
  "project": "test-project",
  "goal": "實作功能",
  "verify": "echo ok",
  "depends_on": ["test-researcher-001"],
  "touches": ["main.py"],
  "role": "implementer",
  "stage": "implement",
  "pipeline_id": "test-pipe-auto"
}
EOF

cat > "$TEST_IMPORT_DIR/task-tester.json" <<'EOF'
{
  "id": "test-tester-001",
  "project": "test-project",
  "goal": "撰寫測試",
  "verify": "echo ok",
  "depends_on": ["test-impl-001"],
  "touches": ["test_main.py"],
  "role": "tester",
  "stage": "test",
  "pipeline_id": "test-pipe-auto"
}
EOF

IMPORT_OUTPUT=$(python3 task_picker.py import "$TEST_IMPORT_DIR")
if ! echo "$IMPORT_OUTPUT" | grep -q "Imported 3"; then
  fail "import_with_role" "匯入失敗: $IMPORT_OUTPUT"
fi
pass "import_tasks_with_role"

# 2b. 確認 role 被正確儲存
TASK_JSON=$(python3 task_picker.py get "test-researcher-001")
STORED_ROLE=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('role',''))")
if [ "$STORED_ROLE" != "researcher" ]; then
  fail "role_stored" "role 儲存錯誤，預期 researcher 實際 ${STORED_ROLE}"
fi
pass "role_stored_correctly"

# 2c. 測試 list-roles 命令
ROLES_OUTPUT=$(python3 task_picker.py list-roles)
if ! echo "$ROLES_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'researcher' in d and 'implementer' in d and 'tester' in d"; then
  fail "list_roles" "list-roles 輸出缺少角色: $ROLES_OUTPUT"
fi
pass "list_roles"

# 2d. 測試 next-batch --role 篩選
BATCH_OUTPUT=$(python3 task_picker.py next-batch --role researcher)
BATCH_IDS=$(echo "$BATCH_OUTPUT" | python3 -c "import sys,json; print(' '.join(t['id'] for t in json.load(sys.stdin)))")
if ! echo "$BATCH_IDS" | grep -q "test-researcher-001"; then
  fail "next_batch_role_filter" "next-batch --role researcher 未回傳 researcher 任務"
fi
# 確認篩選有效：不應包含 implementer 任務
if echo "$BATCH_IDS" | grep -q "test-impl-001"; then
  fail "next_batch_role_filter" "next-batch --role researcher 不應回傳 implementer 任務"
fi
pass "next_batch_role_filter"

# ═══════════════════════════════════════════════════════════
# 步驟 3：測試 pipeline 引擎
# ═══════════════════════════════════════════════════════════

# 3a. 建立測試 pipeline（用 quick-implement 模板）
PIPE_OUTPUT=$(python3 pipeline.py create quick-implement \
  --project test-pipeline-proj \
  --dir /tmp/test-project \
  --var "feature=使用者登入功能")

PIPE_ID=$(echo "$PIPE_OUTPUT" | head -1 | grep -oE 'pipe-[0-9]+-[0-9]+')
if [ -z "$PIPE_ID" ]; then
  fail "create_pipeline" "無法取得 pipeline ID: $PIPE_OUTPUT"
fi
pass "create_pipeline ($PIPE_ID)"

# 3b. 確認 tasks 被正確產生（有正確的 role、stage、pipeline_id、depends_on）
IMPLEMENT_TASK=$(python3 task_picker.py get "${PIPE_ID}-implement")
IMPLEMENT_ROLE=$(echo "$IMPLEMENT_TASK" | python3 -c "import sys,json; print(json.load(sys.stdin)['role'])")
IMPLEMENT_STAGE=$(echo "$IMPLEMENT_TASK" | python3 -c "import sys,json; print(json.load(sys.stdin)['stage'])")
IMPLEMENT_PIPE=$(echo "$IMPLEMENT_TASK" | python3 -c "import sys,json; print(json.load(sys.stdin)['pipeline_id'])")

if [ "$IMPLEMENT_ROLE" != "implementer" ]; then
  fail "pipeline_task_role" "implement 任務 role 錯誤: $IMPLEMENT_ROLE"
fi
if [ "$IMPLEMENT_STAGE" != "implement" ]; then
  fail "pipeline_task_stage" "implement 任務 stage 錯誤: $IMPLEMENT_STAGE"
fi
if [ "$IMPLEMENT_PIPE" != "$PIPE_ID" ]; then
  fail "pipeline_task_pipeline_id" "pipeline_id 錯誤: $IMPLEMENT_PIPE"
fi
pass "pipeline_tasks_correct_fields"

# 3c. 確認 test 任務的 depends_on 包含 implement 任務
TEST_TASK=$(python3 task_picker.py get "${PIPE_ID}-test")
TEST_DEPS=$(echo "$TEST_TASK" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['depends_on']))")
if ! echo "$TEST_DEPS" | grep -q "${PIPE_ID}-implement"; then
  fail "pipeline_depends_on" "test 任務的 depends_on 未包含 implement 任務: $TEST_DEPS"
fi
pass "pipeline_depends_on_correct"

# 3d. 模擬 mark-pass 第一個 stage 的任務
python3 task_picker.py mark-pass "${PIPE_ID}-implement" > /dev/null
IMPL_STATUS=$(python3 task_picker.py get "${PIPE_ID}-implement" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
if [ "$IMPL_STATUS" != "pass" ]; then
  fail "mark_pass_implement" "mark-pass 後 status 應為 pass，實際: $IMPL_STATUS"
fi
pass "mark_pass_implement"

# 3e. 確認下一個 stage 的任務現在 ready（可被 next-batch 取出）
NEXT_BATCH=$(python3 task_picker.py next-batch --role tester)
NEXT_IDS=$(echo "$NEXT_BATCH" | python3 -c "import sys,json; print(' '.join(t['id'] for t in json.load(sys.stdin)))")
if ! echo "$NEXT_IDS" | grep -q "${PIPE_ID}-test"; then
  fail "advance_next_stage" "implement pass 後，test 任務應該 ready，next-batch 結果: $NEXT_IDS"
fi
pass "advance_next_stage_ready"

# 3f. 確認 pipeline status 正確
PIPE_STATUS=$(python3 pipeline.py status "$PIPE_ID")
PIPE_STATE=$(echo "$PIPE_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
if [ "$PIPE_STATE" != "active" ]; then
  fail "pipeline_status" "pipeline 應為 active，實際: $PIPE_STATE"
fi
pass "pipeline_status_active"

# 3g. mark-pass test 任務，advance pipeline 至 completed
python3 task_picker.py mark-pass "${PIPE_ID}-test" > /dev/null
ADV_RESULT=$(python3 pipeline.py advance "$PIPE_ID")
ADV_STATUS=$(echo "$ADV_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
if [ "$ADV_STATUS" != "completed" ]; then
  fail "pipeline_completed" "所有任務 pass 後 pipeline 應為 completed，實際: $ADV_STATUS"
fi
pass "pipeline_completed"

# ═══════════════════════════════════════════════════════════
# 步驟 4：測試 run-task.sh 角色注入（乾跑測試）
# ═══════════════════════════════════════════════════════════

# 4a. 確認 run-task.sh 能讀取角色定義檔並組合 ALLOWED_TOOLS
# 我們不實際呼叫 claude，只測試 prompt 組合邏輯
# 用 bash -x 追蹤變數，但只擷取需要的部分

# 測試：模擬 run-task.sh 的角色讀取邏輯
test_role_injection() {
  local ROLE="$1"
  local EXPECTED_TOOL="$2"
  local NOT_EXPECTED_TOOL="${3:-}"

  local ROLE_FILE="roles/${ROLE}.md"
  local ALLOWED_TOOLS=""

  if [ -f "$ROLE_FILE" ]; then
    ALLOWED_TOOLS=$(sed -n '/^---$/,/^---$/p' "$ROLE_FILE" | grep 'allowed_tools:' | cut -d':' -f2- | tr -d ' ') || true
  fi

  if [ -n "$ALLOWED_TOOLS" ]; then
    CLAUDE_TOOLS="$ALLOWED_TOOLS"
  else
    CLAUDE_TOOLS="Edit,Write,Bash,Read"
  fi

  # 檢查預期工具存在
  if ! echo "$CLAUDE_TOOLS" | grep -q "$EXPECTED_TOOL"; then
    fail "role_injection_${ROLE}" "${ROLE} 角色應包含 ${EXPECTED_TOOL}，實際: $CLAUDE_TOOLS"
  fi

  # 檢查不應有的工具不存在
  if [ -n "$NOT_EXPECTED_TOOL" ]; then
    if echo "$CLAUDE_TOOLS" | grep -q "$NOT_EXPECTED_TOOL"; then
      fail "role_injection_${ROLE}" "${ROLE} 角色不應包含 ${NOT_EXPECTED_TOOL}，實際: $CLAUDE_TOOLS"
    fi
  fi

  return 0
}

test_role_injection "researcher" "WebSearch" "Write"
pass "role_injection_researcher"

test_role_injection "reviewer" "Read" "Write"
pass "role_injection_reviewer"

test_role_injection "implementer" "Edit" ""
pass "role_injection_implementer"

# 4b. 測試角色 prompt 內容讀取
ROLE_PROMPT=$(sed '1,/^---$/d; 1,/^---$/d' roles/researcher.md)
if [ -z "$ROLE_PROMPT" ]; then
  fail "role_prompt_content" "researcher 角色 prompt 為空"
fi
if ! echo "$ROLE_PROMPT" | grep -q "研究"; then
  fail "role_prompt_content" "researcher 角色 prompt 未包含預期關鍵字"
fi
pass "role_prompt_content"

# ═══════════════════════════════════════════════════════════
# 步驟 5：測試 pipeline-status CLI（task_picker）
# ═══════════════════════════════════════════════════════════
PICKER_PIPE_STATUS=$(python3 task_picker.py pipeline-status "$PIPE_ID")
PICKER_TOTAL=$(echo "$PICKER_PIPE_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin)['total'])")
PICKER_PASS=$(echo "$PICKER_PIPE_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin)['pass'])")
if [ "$PICKER_TOTAL" -lt 2 ]; then
  fail "pipeline_status_cli" "pipeline-status total 應 >= 2，實際: $PICKER_TOTAL"
fi
if [ "$PICKER_PASS" -lt 2 ]; then
  fail "pipeline_status_cli" "pipeline-status pass 應 >= 2，實際: $PICKER_PASS"
fi
pass "pipeline_status_cli"

# ═══════════════════════════════════════════════════════════
# 清理（由 trap 處理）
# ═══════════════════════════════════════════════════════════

echo ""
echo "========================================"
echo "  All tests passed! (${PASS_COUNT} checks)"
echo "========================================"
