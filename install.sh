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
chmod +x orchestrator.sh parallel-orchestrator.sh run-task.sh verify-task.sh setup-worktrees.sh notify.sh agent-ctl
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

cat > "$COMMANDS_DIR/harness.md" << 'SKILL_EOF'
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

Agent Harness 安裝路徑由以下方式偵測（優先順序）：
1. 環境變數 `AGENT_HARNESS_HOME`
2. `~/.agent-harness/`（預設安裝路徑）

用 Bash 指令偵測：
```bash
HARNESS_HOME="${AGENT_HARNESS_HOME:-$HOME/.agent-harness}"
```

## 跨專案支援

這個 skill 可以在任何專案目錄下使用。關鍵是 `project_dir` 欄位：

- **當前工作目錄**就是目標專案（除非使用者另外指定）
- 每個 task JSON 必須包含 `project_dir` — 目標專案的**絕對路徑**
- Harness 的 worker 會 `cd` 到 `project_dir` 再跑 Claude
- Verify 指令也在 `project_dir` 下執行

## 任務 JSON 格式

```json
{
  "id": "unique-task-id",
  "project": "project-name",
  "project_dir": "/absolute/path/to/target/project",
  "goal": "清楚、具體的任務描述",
  "touches": ["src/index.ts", "package.json"],
  "verify": "npm test",
  "depends_on": ["前置任務 id"],
  "max_attempts": 5
}
```

### 重要：project_dir 必須是絕對路徑

## 拆解原則

1. **每個任務要可獨立驗證** — verify 必須是客觀指令
2. **粒度適中** — 一個任務 ≈ 一個 Claude session 能做完的量
3. **touches 要準確** — 決定哪些任務可以並行
4. **依賴關係要正確** — depends_on 形成 DAG
5. **goal 要具體** — 包含足夠 context
6. **verify 要靠譜** — test/build/lint/grep，不要 echo

## 執行流程

1. 讀取 $ARGUMENTS 理解需求
2. 偵測 harness 路徑：`HARNESS_HOME="${AGENT_HARNESS_HOME:-$HOME/.agent-harness}"`
3. 偵測目標專案：當前工作目錄或使用者指定的路徑
4. 掃描目標專案結構（Glob + Read 關鍵檔案）
5. 設計任務 DAG
6. 顯示 DAG 圖讓使用者確認
7. 確認 DB 已初始化（`sqlite3 $HARNESS_HOME/db/agent.db < $HARNESS_HOME/schema.sql`）
8. 寫入 JSON + 匯入：`python3 $HARNESS_HOME/task_picker.py import $HARNESS_HOME/tasks/{project}/`
9. 詢問是否啟動 orchestrator

## 注意

- 如果使用者沒指定驗證方式，根據 tech stack 自動決定
- project_dir 必須是絕對路徑
- goal 不需要寫 cd 指令
- 如果不確定技術細節，用 WebSearch 查
SKILL_EOF

echo "  ✅ /harness skill installed to $COMMANDS_DIR/harness.md"

# ── 8. Done ─────────────────────────────────────────────
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
