#!/bin/bash
# install.sh — Install Agent Harness for any user
# Usage: curl -sSL https://raw.githubusercontent.com/Muheng1992/agent-harness/main/install.sh | bash
#   or:  bash install.sh [--install-dir DIR]
set -euo pipefail

# ── Configuration ──────────────────────────────────────
DEFAULT_INSTALL_DIR="$HOME/.agent-harness"
INSTALL_DIR="${1:-$DEFAULT_INSTALL_DIR}"
REPO_URL="https://github.com/Muheng1992/agent-harness.git"
BIN_DIR="$HOME/.local/bin"

echo "🤖 Agent Harness Installer"
echo "=========================="
echo ""

# ── 1. Check prerequisites ─────────────────────────────
echo "Checking prerequisites..."

check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "❌ $1 not found. Please install $1 first."
    return 1
  fi
  echo "  ✅ $1"
}

check_cmd python3 || exit 1
check_cmd sqlite3 || exit 1
check_cmd jq || exit 1
check_cmd git || exit 1
check_cmd claude || { echo "  ⚠️  claude not found — needed for task execution (install Claude Code CLI)"; }

echo ""

# ── 2. Clone or update ─────────────────────────────────
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "Updating existing installation at $INSTALL_DIR..."
  cd "$INSTALL_DIR" && git pull --ff-only
else
  echo "Installing to $INSTALL_DIR..."
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# ── 3. Initialize database ─────────────────────────────
echo "Initializing database..."
mkdir -p db logs
sqlite3 db/agent.db < schema.sql
echo "  ✅ db/agent.db created"

# ── 4. Make scripts executable ──────────────────────────
chmod +x orchestrator.sh parallel-orchestrator.sh loop-orchestrator.sh run-task.sh verify-task.sh setup-worktrees.sh notify.sh agent-ctl
echo "  ✅ Scripts made executable"

# ── 5. Create symlink ──────────────────────────────────
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/agent-ctl" "$BIN_DIR/agent-ctl"
echo "  ✅ agent-ctl linked to $BIN_DIR/agent-ctl"

# ── 6. Check PATH ──────────────────────────────────────
if ! echo "$PATH" | tr ':' '\n' | grep -q "$BIN_DIR"; then
  echo ""
  echo "⚠️  $BIN_DIR is not in your PATH."
  echo "   Add this to your shell config (~/.zshrc or ~/.bashrc):"
  echo ""
  echo "   export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi

# ── 7. Install Claude Code skill ───────────────────────
COMMANDS_DIR="$HOME/.claude/commands"
mkdir -p "$COMMANDS_DIR"

# Write skill with actual install path baked in
sed "s|__HARNESS_HOME__|${INSTALL_DIR}|g" > "$COMMANDS_DIR/harness.md" << 'SKILL_EOF'
**Purpose**: Autonomous Agent Harness — 自動拆解任務、生成 DAG、啟動自主執行

---

## 你是 Agent Harness 的任務規劃器

使用者會用自然語言描述他想做的事。你的工作是：

1. **分析需求** — 理解使用者想做什麼
2. **分析目標專案** — 掃描專案結構，理解 tech stack、現有程式碼
3. **拆解成任務 DAG** — 每個任務是一個獨立的、可驗證的工作單元
4. **寫出 task JSON** — 寫入 agent-harness 的 tasks/ 目錄
5. **匯入 + 啟動** — 匯入資料庫並詢問是否啟動 orchestrator

## 輸入

使用者的自然語言描述在 `$ARGUMENTS` 中。

## Harness 位置

Agent Harness 安裝在 `__HARNESS_HOME__`。
所有操作都以這個目錄為基礎。

## 跨專案支援

這個 skill 可以在任何專案目錄下使用。關鍵是 `project_dir` 欄位：

- **當前工作目錄**就是目標專案（除非使用者另外指定）
- 每個 task JSON 必須包含 `project_dir` — 目標專案的**絕對路徑**
- Harness 的 worker 會 `cd` 到 `project_dir` 再跑 Claude
- Verify 指令也在 `project_dir` 下執行

## 任務 JSON 格式

每個任務是一個 JSON 檔案，放在 `__HARNESS_HOME__/tasks/{project-name}/` 目錄下：

```json
{
  "id": "unique-task-id",
  "project": "project-name",
  "project_dir": "/absolute/path/to/target/project",
  "goal": "清楚、具體的任務描述，讓 Claude agent 知道要做什麼。包含：做什麼、在哪做、預期結果。",
  "touches": ["src/index.ts", "package.json"],
  "verify": "npm test",
  "depends_on": ["前置任務 id"],
  "max_attempts": 5
}
```

### 重要欄位說明

| 欄位 | 說明 |
|------|------|
| `project_dir` | **必填**。目標專案的絕對路徑。Worker 會在這個目錄裡執行 Claude 和 verify |
| `goal` | 不需要再寫 "cd /path/to/project" — worker 已經在正確目錄了 |
| `touches` | 相對於 project_dir 的檔案路徑 |
| `verify` | 在 project_dir 下執行的驗證指令 |

## 拆解原則

1. **每個任務要可獨立驗證** — verify 指令必須是客觀的，不能是「看起來對」
2. **粒度適中** — 太大會失敗率高，太小會浪費 session。一個任務 ≈ 一個 Claude session 能做完的量
3. **touches 要準確** — 這決定哪些任務可以並行。碰同樣檔案的任務不能同時跑
4. **依賴關係要正確** — depends_on 形成 DAG，系統會自動排序
5. **goal 要具體** — 想像你在跟一個新人交代任務，要包含足夠 context
6. **verify 要靠譜** — 用 test、build、grep、curl 等客觀指令。不要用「echo success」

## 拆解策略

### 典型的 DAG 結構：
```
setup (初始化專案/環境)
  ├── feature-a (獨立功能 A)
  ├── feature-b (獨立功能 B)
  └── feature-c (獨立功能 C)
      └── integration (整合所有功能)
          └── polish (最終調整/文件)
```

### 任務粒度指南：
- **太大**：「建一個完整的 REST API」→ 拆開
- **剛好**：「建立 Express server，加入 GET /health endpoint，回傳 {status: ok}」
- **太小**：「在 package.json 加一個 dependency」→ 合併到其他任務

## 執行流程

1. 讀取 $ARGUMENTS 理解需求
2. **偵測目標專案**：
   - 如果使用者指定了專案路徑 → 用那個
   - 如果使用者在某個專案目錄下執行 → 用當前工作目錄
   - 用絕對路徑表示 project_dir
3. 掃描目標專案結構：
   - 用 Glob 找檔案
   - 用 Read 讀關鍵檔案（package.json、pyproject.toml、主要入口等）
   - 理解 tech stack 和現有架構
4. 設計任務 DAG（列出所有任務、依賴關係、驗證方式）
5. 顯示 DAG 圖讓使用者確認
6. 使用者確認後，寫入 JSON 檔案到 `__HARNESS_HOME__/tasks/{project}/`
7. 確認 DB 已初始化（如果 db/agent.db 不存在，先跑 `sqlite3 __HARNESS_HOME__/db/agent.db < __HARNESS_HOME__/schema.sql`）
8. 執行匯入：`python3 __HARNESS_HOME__/task_picker.py import __HARNESS_HOME__/tasks/{project}/`
9. 確認匯入成功後，詢問是否要啟動 orchestrator

## 輸出格式

先展示 DAG 概覽：
```
任務 DAG: {project-name}
目標目錄: {project_dir}

setup-express (無依賴)
  ├── add-user-model (等 setup)
  ├── add-auth-middleware (等 setup)
  │   └── add-protected-routes (等 auth)
  └── add-tests (等 setup)
      └── integration-test (等 routes + tests)

共 6 個任務，預估 3 輪完成（有 2 輪可並行）
```

然後逐一列出每個任務的詳細 JSON。

## 啟動指令

匯入完成後，告訴使用者：
```bash
# 自動跑到全部完成（推薦）
cd __HARNESS_HOME__ && bash loop-orchestrator.sh

# 並行 + 自動跑到完
cd __HARNESS_HOME__ && bash loop-orchestrator.sh --parallel

# 自訂安全限制
cd __HARNESS_HOME__ && bash loop-orchestrator.sh --max-rounds 20 --max-time 1800

# 跑一輪（一次一個任務）
cd __HARNESS_HOME__ && bash orchestrator.sh

# 或並行跑一輪
cd __HARNESS_HOME__ && bash parallel-orchestrator.sh

# 或用 agent-ctl 看狀態
agent-ctl status
```

## 注意

- 如果使用者沒指定驗證方式，你要根據 tech stack 自動決定（pytest、jest、go test、xcodebuild test 等）
- 如果使用者的需求不清楚，先問清楚再拆
- **project_dir 必須是絕對路徑**，不要用 ~ 或相對路徑
- goal 不需要寫 cd 指令 — worker 已經在正確目錄
- 如果不確定某個技術細節，用 WebSearch 查，不要猜
- 同一個 project 的任務共享同一個 project_dir
SKILL_EOF

echo "  ✅ /harness skill installed to $COMMANDS_DIR/harness.md"

# ── 8. Install bootstrap skill ───────────────────────────
cp "$INSTALL_DIR/install-harness.md" "$COMMANDS_DIR/install-harness.md"
echo "  ✅ /install-harness skill installed to $COMMANDS_DIR/install-harness.md"

# ── 9. Done ─────────────────────────────────────────────
echo ""
echo "🎉 Agent Harness installed successfully!"
echo ""
echo "Quick start:"
echo "  agent-ctl status                    # Check status"
echo "  agent-ctl plan 'build a todo API' \\"
echo "    --project todo -d ~/projects/todo  # Auto-plan tasks"
echo ""
echo "Or in Claude Code:"
echo "  /harness build a REST API with Express in this project"
echo ""
