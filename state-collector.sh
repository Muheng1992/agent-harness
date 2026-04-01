#!/bin/bash
set -euo pipefail

# state-collector.sh — 專案狀態收集器（Router 感知層）
# 收集專案的測試結果、Git 狀態、任務歷史、Roadmap 進度、程式碼指標
# 輸出結構化 Markdown 報告到 stdout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === 參數解析 ===
PROJECT_DIR=""
TEST_CMD=""
DB_PATH="${SCRIPT_DIR}/db/agent.db"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-cmd)
      TEST_CMD="$2"
      shift 2
      ;;
    --db-path)
      DB_PATH="$2"
      shift 2
      ;;
    -*)
      echo "未知選項: $1" >&2
      exit 1
      ;;
    *)
      PROJECT_DIR="$1"
      shift
      ;;
  esac
done

if [ -z "$PROJECT_DIR" ]; then
  echo "用法: bash state-collector.sh /path/to/project [--test-cmd 'make test'] [--db-path /path/to/agent.db]" >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "錯誤: 目錄不存在 — $PROJECT_DIR" >&2
  exit 1
fi

cd "$PROJECT_DIR"

# === 報告標頭 ===
echo "# Project State Report"
echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Project: $PROJECT_DIR"
echo ""

# === 1. 測試結果 ===
echo "## Test Results"

detect_test_cmd() {
  if [ -n "$TEST_CMD" ]; then
    echo "$TEST_CMD"
    return
  fi

  # Makefile with test target
  if [ -f "Makefile" ] && grep -q '^test:' Makefile 2>/dev/null; then
    echo "make test"
    return
  fi

  # package.json with test script
  if [ -f "package.json" ] && python3 -c "import json,sys; d=json.load(open('package.json')); sys.exit(0 if 'test' in d.get('scripts',{}) else 1)" 2>/dev/null; then
    echo "npm test"
    return
  fi

  # pytest
  if [ -f "pytest.ini" ] || ([ -f "pyproject.toml" ] && grep -q 'pytest' pyproject.toml 2>/dev/null); then
    echo "pytest"
    return
  fi

  # Cargo
  if [ -f "Cargo.toml" ]; then
    echo "cargo test"
    return
  fi

  # Xcode — 太慢，只記錄
  if ls ./*.xcodeproj 1>/dev/null 2>&1 || ls ./**/*.xcodeproj 1>/dev/null 2>&1; then
    echo "XCODE_SKIP"
    return
  fi

  echo ""
}

DETECTED_CMD="$(detect_test_cmd)"

if [ -z "$DETECTED_CMD" ]; then
  echo "Status: NO_TESTS"
  echo "Exit Code: N/A"
  echo "Output: 無測試框架"
  echo ""
elif [ "$DETECTED_CMD" = "XCODE_SKIP" ]; then
  echo "Status: SKIPPED"
  echo "Exit Code: N/A"
  echo "Output: 偵測到 Xcode 專案，因執行時間過長而略過自動測試"
  echo ""
else
  TEST_OUTPUT=""
  TEST_EXIT=0
  TEST_OUTPUT=$(timeout 60 bash -c "$DETECTED_CMD" 2>&1 | tail -c 3000) || TEST_EXIT=$?

  if [ "$TEST_EXIT" -eq 0 ]; then
    echo "Status: PASS"
  elif [ "$TEST_EXIT" -eq 124 ]; then
    echo "Status: FAIL (TIMEOUT)"
  else
    echo "Status: FAIL"
  fi
  echo "Exit Code: $TEST_EXIT"
  echo "Output:"
  echo '```'
  echo "$TEST_OUTPUT"
  echo '```'
  echo ""
fi

# === 2. Git 狀態 ===
echo "## Git Status"

GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "N/A")
echo "Branch: $GIT_BRANCH"

echo "Recent Commits:"
echo '```'
git log --oneline -20 2>/dev/null || echo "(no git history)"
echo '```'

echo "Changes Since Last Commit:"
echo '```'
git diff --stat HEAD~1 2>/dev/null || echo "(no previous commit)"
echo '```'

echo "Uncommitted:"
echo '```'
git status --short 2>/dev/null || echo "(not a git repo)"
echo '```'
echo ""

# === 3. 任務歷史 ===
if [ -f "$DB_PATH" ] && command -v sqlite3 &>/dev/null; then
  echo "## Task History"

  echo "| ID | Role | Status | Attempts |"
  echo "|---|---|---|---|"
  sqlite3 -separator '|' "$DB_PATH" \
    "SELECT id, role, status, attempt_count FROM tasks ORDER BY updated_at DESC LIMIT 10;" 2>/dev/null \
    | while IFS='|' read -r tid trole tstatus tattempts; do
        echo "| ${tid} | ${trole} | ${tstatus} | ${tattempts} |"
      done || true

  echo ""

  # 統計
  SUMMARY=$(sqlite3 "$DB_PATH" "SELECT status, COUNT(*) FROM tasks GROUP BY status;" 2>/dev/null || true)
  if [ -n "$SUMMARY" ]; then
    echo "Summary: $SUMMARY"
  fi

  # 連續 FIX 次數
  FIX_COUNT=$(sqlite3 "$DB_PATH" \
    "SELECT COUNT(*) FROM (SELECT id FROM tasks WHERE role='debugger' OR goal LIKE '%修復%' OR goal LIKE '%fix%' ORDER BY updated_at DESC LIMIT 20) sub;" \
    2>/dev/null || echo "0")
  echo "Consecutive FIX rounds: ${FIX_COUNT}"
  echo ""
fi

# === 4. Roadmap 進度 ===
echo "## Roadmap Progress"

ROADMAP_FILE=""
if [ -f "$PROJECT_DIR/roadmap.yaml" ]; then
  ROADMAP_FILE="$PROJECT_DIR/roadmap.yaml"
elif [ -f "$PROJECT_DIR/.harness/roadmap.yaml" ]; then
  ROADMAP_FILE="$PROJECT_DIR/.harness/roadmap.yaml"
fi

if [ -n "$ROADMAP_FILE" ] && [ -f "${SCRIPT_DIR}/roadmap.py" ]; then
  python3 "${SCRIPT_DIR}/roadmap.py" status "$ROADMAP_FILE" 2>/dev/null || echo "Roadmap 解析失敗"
elif [ -n "$ROADMAP_FILE" ]; then
  echo "Roadmap 檔案存在但缺少 roadmap.py 解析器: $ROADMAP_FILE"
else
  echo "No roadmap found"
fi
echo ""

# === 5. 程式碼指標 ===
echo "## Code Metrics"

FILE_EXTENSIONS=( -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.tsx' -o -name '*.swift' -o -name '*.c' -o -name '*.cpp' -o -name '*.go' -o -name '*.rs' -o -name '*.java' -o -name '*.sh' )

FILE_COUNT=$(find . -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/build/*' -not -path '*/.build/*' \( "${FILE_EXTENSIONS[@]}" \) 2>/dev/null | wc -l | tr -d ' ' || echo "0")
echo "Files: $FILE_COUNT"

LINE_COUNT=$(find . -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/vendor/*' -not -path '*/build/*' -not -path '*/.build/*' \( "${FILE_EXTENSIONS[@]}" \) -exec cat {} + 2>/dev/null | wc -l | tr -d ' ' || echo "0")
echo "Lines: $LINE_COUNT"

TODO_COUNT=$(grep -rn 'TODO\|FIXME\|HACK\|XXX' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.tsx' \
  --include='*.swift' --include='*.c' --include='*.cpp' --include='*.go' \
  --include='*.rs' --include='*.java' --include='*.sh' \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor --exclude-dir=build \
  . 2>/dev/null | wc -l | tr -d ' ' || echo "0")
echo "TODO/FIXME: $TODO_COUNT"
