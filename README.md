# Agent Harness

> 基於 Claude Code CLI 的自主多 Agent 編排系統
> 外部排程 + 外部記憶 + 並行執行 + 自我修復 + 監控控制

## 設計理念

- **每輪乾淨 session** — 每次都用 `claude --bare -p` 啟動全新 context，不被壓縮
- **記憶外化** — 所有狀態保存在 SQLite，Claude 是無狀態的執行器
- **驗證不信自報** — 永遠用客觀指令（test / build / lint）判斷結果
- **失敗即重派** — 任務失敗自動帶錯誤 context 重新排入佇列
- **卡住才通知** — 只在 escalate 或全局卡死時才推播通知
- **可中斷可恢復** — 任何時候 pause/stop，恢復後從斷點繼續
- **衝突隔離** — git worktree 讓並行 worker 互不干擾

> **前提**：使用 Claude Max 訂閱方案，無 API 費用問題。

## 快速開始

```bash
# 1. 初始化
make init

# 2. 建立任務（參考 tasks/examples/ 的格式）
make import-tasks DIR=tasks/examples

# 3. 跑一輪（單任務）
bash orchestrator.sh

# 4. 跑一輪（並行，最多 4 個 worker）
bash parallel-orchestrator.sh

# 5. 查看狀態
./agent-ctl status
```

## 架構

```
┌─────────────────────────────────────────────────────────┐
│               Orchestrator (主控迴圈)                     │
│                                                         │
│  Scheduler ──▶ Plan ──▶ Execute ──▶ Verify ──▶ Decide   │
│  (cron)       (DAG)    (claude -p)  (test)    (pass?)   │
│                                                         │
│       ▲                                        │        │
│       │                                   pass │ fail   │
│       │                                        │        │
│       │  ┌─────────────────────────────┐       │        │
│       └──│       Watchdog              │◀──────┘        │
│          │  有重試額度? → 自動重派      │                │
│          │  超過上限?   → escalate      │                │
│          └─────────────────────────────┘                │
│                                                         │
│  SQLite (WAL)          macOS 通知                       │
│  記憶+狀態+歷史        escalate 時推播                   │
└─────────────────────────────────────────────────────────┘
```

## 任務定義

在 `tasks/` 目錄下建立 JSON 檔案：

```json
{
  "id": "implement-feature-x",
  "project": "my-project",
  "goal": "實作 X 功能，修改 src/main.py，加入 ...",
  "touches": ["src/main.py", "tests/test_main.py"],
  "verify": "python3 -m pytest tests/ -v",
  "depends_on": ["setup-project"],
  "max_attempts": 5
}
```

| 欄位 | 說明 |
|------|------|
| `id` | 唯一識別 |
| `project` | 所屬專案，用於多專案並行 |
| `goal` | 給 Claude 的任務描述 |
| `touches` | 會碰的檔案，用於並行衝突偵測 |
| `verify` | 客觀驗證指令 |
| `depends_on` | 前置任務 ID |
| `max_attempts` | 最大重試次數 |

## 控制面板 — agent-ctl

```bash
./agent-ctl status              # 總覽面板
./agent-ctl tasks               # 所有任務 DAG
./agent-ctl tasks my-project    # 只看某專案
./agent-ctl logs task-id        # 查某任務的執行歷史

./agent-ctl pause               # 暫停
./agent-ctl resume              # 恢復
./agent-ctl stop                # 停止

./agent-ctl kill                # 強殺所有 worker
./agent-ctl kill 2              # 只殺 Worker 2

./agent-ctl skip task-id        # 跳過某任務
./agent-ctl retry task-id       # 重置某任務
```

## 自主運轉

設定 cron 或 launchd 定時觸發：

```bash
# 每 5 分鐘跑一輪
*/5 * * * * cd /path/to/agent-harness && bash parallel-orchestrator.sh >> logs/orchestrator.log 2>&1
```

## 錯誤修復策略

| 錯誤類型 | 偵測方式 | 修復策略 |
|---------|---------|---------|
| rate_limit | "429" / "rate limit" | 等 120 秒後重試 |
| build_fail | "build failed" | 帶 error log，只修編譯錯誤 |
| test_fail | "test failed" | 帶失敗 test case，修到過 |
| merge_conflict | "merge conflict" | 帶衝突檔案，要求解決 |
| 多次失敗 | attempt >= 3 | 要求先分析 root cause |
| 超過上限 | attempt >= max | escalate + 通知 |

## 檔案結構

```
agent-harness/
├── orchestrator.sh          # 單輪主迴圈
├── parallel-orchestrator.sh # 並行版主迴圈
├── run-task.sh              # 單輪執行
├── verify-task.sh           # 驗證
├── setup-worktrees.sh       # 初始化 git worktree
├── notify.sh                # macOS 通知
├── task_picker.py           # DAG 管理 + 任務挑選
├── healer.py                # 錯誤分類 + 修復策略
├── watchdog.py              # 卡死偵測 + 自動重派
├── memory.py                # SQLite 讀寫
├── merge-results.py         # 合併成功的 worker 分支
├── agent-ctl                # CLI 監控 + 控制工具
├── schema.sql               # 資料庫 schema
├── Makefile                 # 初始化捷徑
├── db/agent.db              # SQLite 資料庫（自動生成）
├── tasks/                   # 任務定義
│   └── examples/            # 範例任務
└── .worktrees/              # git worktree（自動生成）
```

## 需求

- macOS（通知使用 osascript）
- Python 3.10+（無外部依賴）
- Claude Code CLI（`claude` 指令）
- SQLite3
- jq
- Git

## License

MIT
