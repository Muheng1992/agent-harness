# Agent Harness — 系統架構文件

> 自主多代理編排系統，基於 Claude Code CLI 構建。
> 自動迴圈 + DAG 排程 + 並行執行 + 自我修復 + 智慧冷卻 + 客觀驗證。

---

## 1. 系統層次架構

```mermaid
graph TB
    subgraph "控制層 Control Plane"
        CTL["agent-ctl<br/>監控/控制 CLI"]
        Skill["/harness skill<br/>Claude Code 整合"]
    end

    subgraph "排程層 Scheduling"
        Loop["loop-orchestrator.sh<br/>外層自動迴圈"]
        Orch["orchestrator.sh<br/>單輪主迴圈"]
        POrc["parallel-orchestrator.sh<br/>並行調度"]
    end

    subgraph "執行層 Execution"
        Run["run-task.sh<br/>任務執行器"]
        Verify["verify-task.sh<br/>客觀驗證"]
        Claude["Claude Code CLI<br/>claude -p"]
    end

    subgraph "智慧層 Intelligence"
        TP["task_picker.py<br/>DAG + 衝突偵測"]
        Heal["healer.py<br/>錯誤分類 + 修復策略"]
        WD["watchdog.py<br/>健康監控 + 自動重派"]
        Mem["memory.py<br/>跨 session 記憶"]
    end

    subgraph "基礎設施層 Infrastructure"
        DB[(SQLite WAL<br/>db/agent.db)]
        WT["Git Worktrees<br/>.worktrees/"]
        Merge["merge-results.py<br/>分支合併"]
        Notify["notify.sh<br/>macOS 通知"]
    end

    CTL --> DB
    Skill -->|"規劃 + 匯入"| TP
    Loop -->|"持續呼叫"| Orch
    Loop -->|"--parallel"| POrc
    POrc -->|"N 個 worker"| Orch
    Orch --> WD
    Orch --> TP
    Orch --> Run
    Orch --> Verify
    Orch --> Heal
    Orch --> Merge
    Orch --> Notify
    Run --> Mem
    Run --> Claude
    Run --> WT
    TP --> DB
    Heal --> DB
    WD --> DB
    Mem --> DB
    Merge --> WT

    style Loop fill:#2d5016,color:#fff
    style DB fill:#1a3a5c,color:#fff
    style Claude fill:#5c1a1a,color:#fff
```

---

## 2. 核心迴圈流程

### 2.1 外層迴圈 — loop-orchestrator.sh

整個系統的**推薦入口**。持續執行 orchestrator 直到 DAG 完成。

```mermaid
flowchart TD
    Start["啟動 loop-orchestrator.sh"] --> SafeCheck

    SafeCheck{"超過 max-rounds<br/>或 max-time?"}
    SafeCheck -->|Yes| Warn["印警告 + exit 1"]
    SafeCheck -->|No| Remain

    Remain{"remaining tasks<br/>(pending+running+fail)"}
    Remain -->|"= 0"| Done["All tasks completed!<br/>exit 0"]
    Remain -->|"> 0"| Inner

    Inner["執行 orchestrator.sh<br/>或 parallel-orchestrator.sh"]
    Inner --> ExitCode

    ExitCode{"exit code?"}
    ExitCode -->|"= 2"| Paused["paused/stopped<br/>exit 2"]
    ExitCode -->|"其他"| Progress

    Progress["印出進度摘要<br/>pass/fail/pending/escalated"]
    Progress --> Cooldown

    Cooldown["智慧冷卻"]
    Cooldown --> Sleep

    subgraph "Smart Cooldown Logic"
        Sleep{"最近 error_class?"}
        Sleep -->|rate_limit| S120["sleep 120s"]
        Sleep -->|"有 fail"| S30["sleep DB.cooldown_sec<br/>(預設 30s)"]
        Sleep -->|"無 fail"| S5["sleep 5s"]
    end

    S120 & S30 & S5 --> SafeCheck

    style Start fill:#2d5016,color:#fff
    style Done fill:#2d5016,color:#fff
    style Warn fill:#8b0000,color:#fff
    style Paused fill:#555,color:#fff
```

**安全限制（預設值）：**

| 參數 | 預設 | 說明 |
|------|------|------|
| `--max-rounds` | 500 | 防止無限迴圈 |
| `--max-time` | 86400 (24h) | 防止無限空轉 |

### 2.2 單輪迴圈 — orchestrator.sh

每輪處理一個任務的完整生命週期。

```mermaid
sequenceDiagram
    participant O as orchestrator.sh
    participant WD as watchdog.py
    participant DB as SQLite
    participant TP as task_picker.py
    participant R as run-task.sh
    participant C as Claude CLI
    participant V as verify-task.sh
    participant H as healer.py
    participant M as merge-results.py
    participant N as notify.sh

    O->>WD: auto-redispatch
    WD->>DB: fail→pending (if attempt < max)
    O->>WD: check
    WD-->>O: issues / OK

    O->>DB: SELECT global_state
    alt paused/stopped
        O-->>O: exit 2
    end

    O->>TP: next-batch --max 1
    TP->>DB: 查詢 pending + 檢查 depends_on + touches
    TP-->>O: task_id (or empty)

    alt no tasks
        O->>M: merge-results
        O-->>O: exit 0
    end

    O->>R: run-task.sh $TASK_ID
    R->>DB: memory.py read (歷史上下文)
    R->>DB: mark-running
    R->>C: claude -p "$PROMPT"
    C-->>R: 程式碼變更
    R->>DB: memory.py write (儲存輸出)

    alt Claude 失敗 (exit ≠ 0)
        R->>DB: record-failure
        R-->>O: exit 1
        O->>H: healer.py (分類錯誤)
        H->>DB: 更新 error_class
    end

    O->>V: verify-task.sh $TASK_ID
    alt 驗證通過
        V->>DB: mark-pass
        V-->>O: PASS
        O->>M: merge-results
        O->>N: "Task passed"
    else 驗證失敗
        V->>DB: record-failure
        V->>H: healer.py (分類 + 策略)
        H->>DB: 更新 error_class
        V-->>O: FAIL
        O->>N: "Task failed / escalated"
    end
```

### 2.3 並行調度 — parallel-orchestrator.sh

同時派發多個不衝突的任務。

```mermaid
flowchart LR
    PO["parallel-orchestrator.sh"]
    PO -->|"next-batch --max N"| TP["task_picker.py"]
    TP -->|"DAG + touches 檢查"| Batch["[task-1, task-2, task-3]"]

    Batch --> W0["Worker 0<br/>run-task + verify"]
    Batch --> W1["Worker 1<br/>run-task + verify"]
    Batch --> W2["Worker 2<br/>run-task + verify"]

    W0 --> WT0[".worktrees/w0"]
    W1 --> WT1[".worktrees/w1"]
    W2 --> WT2[".worktrees/w2"]

    W0 & W1 & W2 --> Wait["wait all"]
    Wait --> Merge["merge-results.py"]
```

---

## 3. 自我修復迴圈

完整的 fail → classify → heal → retry → pass/escalate 流程：

```mermaid
stateDiagram-v2
    [*] --> pending: import

    pending --> running: mark-running<br/>(挑選 + 分配 worker)
    running --> pass: verify 通過
    running --> fail: verify 失敗 / Claude 崩潰

    fail --> pending: watchdog auto-redispatch<br/>(attempt < max)
    fail --> escalated: watchdog check<br/>(attempt >= max)

    pass --> [*]
    escalated --> [*]: 需要人工介入

    escalated --> pending: agent-ctl retry<br/>(手動重置)

    note right of fail
        healer.py 分類錯誤:
        rate_limit → cooldown 120s
        build_fail → 帶 build log
        test_fail → 帶 test output
        unknown → 一般重試
        attempt >= 3 → root cause 分析
    end note

    note right of running
        run-task.sh 注入 HEAL_PROMPT:
        包含上次錯誤 + 修復建議
        + memory.py 的歷史上下文
    end note
```

### 自癒資料流

```mermaid
flowchart LR
    subgraph "Round N: 失敗"
        A1["Claude 執行"] --> A2["verify 失敗"]
        A2 --> A3["record-failure<br/>(寫 last_error)"]
        A3 --> A4["healer.py<br/>(寫 error_class)"]
    end

    subgraph "Between Rounds"
        B1["watchdog auto-redispatch<br/>(fail→pending)"]
        B2["loop-orchestrator<br/>smart cooldown"]
    end

    subgraph "Round N+1: 重試"
        C1["run-task.sh<br/>讀 last_error"]
        C2["注入 HEAL_PROMPT"]
        C3["memory.py read<br/>(歷史上下文)"]
        C4["Claude 帶修復 context 重試"]
    end

    A4 --> B1
    B1 --> B2
    B2 --> C1
    C1 --> C2
    C3 --> C2
    C2 --> C4

    style A2 fill:#8b0000,color:#fff
    style C4 fill:#2d5016,color:#fff
```

---

## 4. 資料模型

### 4.1 資料庫 Schema

```mermaid
erDiagram
    tasks {
        TEXT id PK "任務 ID"
        TEXT project "專案名稱"
        TEXT project_dir "目標專案絕對路徑"
        TEXT goal "任務描述"
        TEXT verify_cmd "驗證指令"
        TEXT depends_on "JSON array — 前置任務 ID"
        TEXT touches "JSON array — 會碰的檔案"
        TEXT status "pending|running|pass|fail|escalated|skipped"
        INTEGER attempt_count "已嘗試次數"
        INTEGER max_attempts "最大重試次數 (預設 5)"
        INTEGER assigned_worker "被分配的 worker"
        TEXT error_class "最近錯誤分類"
        TEXT last_error "最近錯誤摘要"
        DATETIME created_at
        DATETIME updated_at
    }

    runs {
        INTEGER id PK "自增 ID"
        TEXT task_id FK "→ tasks.id"
        INTEGER worker_id
        INTEGER attempt "第幾次嘗試"
        TEXT status "running|pass|fail|error"
        TEXT prompt_hash "prompt 的 SHA256 前綴"
        TEXT claude_output "Claude 輸出"
        TEXT verify_output "驗證輸出"
        TEXT error_class "錯誤分類"
        REAL duration_sec "執行秒數"
        DATETIME started_at
        DATETIME finished_at
    }

    control {
        TEXT key PK "global_state|max_parallel|cooldown_sec"
        TEXT value
        DATETIME updated_at
    }

    tasks ||--o{ runs : "has many"
```

### 4.2 Control 表預設值

| key | 預設值 | 用途 |
|-----|--------|------|
| `global_state` | `running` | 系統狀態（running/paused/stopped） |
| `max_parallel` | `4` | 並行 worker 上限 |
| `cooldown_sec` | `30` | 一般失敗冷卻時間 |

### 4.3 任務狀態機

```mermaid
stateDiagram-v2
    direction LR

    [*] --> pending: import / retry

    pending --> running: mark-running
    running --> pass: verify PASS
    running --> fail: verify FAIL / Claude crash

    fail --> pending: auto-redispatch<br/>(attempt < max)
    fail --> escalated: check<br/>(attempt >= max)

    state "人工介入" as manual {
        escalated --> pending: agent-ctl retry
        pending --> skipped: agent-ctl skip
    }

    pass --> [*]
    escalated --> [*]
    skipped --> [*]
```

---

## 5. 模組詳細說明

### 5.1 loop-orchestrator.sh — 外層自動迴圈

**推薦的系統入口。** 持續執行 orchestrator 直到 DAG 完成或安全限制觸發。

```bash
bash loop-orchestrator.sh [--parallel] [--max-rounds N] [--max-time M]
```

**職責：**
- 查詢 remaining tasks（pending + running + fail）
- 呼叫 orchestrator.sh 或 parallel-orchestrator.sh
- 根據 error_class 決定 cooldown 時間
- 每輪印出進度摘要
- max-rounds / max-time 安全保險絲

**Exit codes：** 0=全部完成, 1=安全限制, 2=paused/stopped

### 5.2 orchestrator.sh — 單輪主迴圈

單輪處理一個任務的完整生命週期。

**流程：**
1. `watchdog.py auto-redispatch` — 重派可重試的失敗任務
2. `watchdog.py check` — 健康檢查 + escalation
3. 檢查 `control.global_state`
4. `task_picker.py next-batch --max 1` — 挑選下一個可執行任務
5. `run-task.sh` — 執行任務
6. **若 Claude 崩潰 → 呼叫 healer.py 分類錯誤**
7. `verify-task.sh` — 驗證結果
8. 處理結果（pass → merge, fail → record）

**Exit codes：** 0=正常, 1=錯誤, 2=paused/stopped

### 5.3 parallel-orchestrator.sh — 並行調度

一次派發多個不衝突的任務到不同 worker。

**流程：**
1. 健康檢查 + 控制訊號
2. `task_picker.py next-batch --max N` — 取得一批不衝突的任務
3. 為每個任務在背景啟動 `run-task.sh` + `verify-task.sh`
4. 等待所有 worker 完成
5. `merge-results.py` 合併通過的分支

### 5.4 run-task.sh — 任務執行器

在正確的工作目錄中執行 Claude CLI。

**關鍵機制：**
- 讀取 `memory.py` 歷史上下文
- 讀取 `last_error` 組合 HEAL_PROMPT（帶上次失敗資訊）
- 決定工作目錄：`project_dir` > worktree > harness dir
- 呼叫 `claude -p` 執行任務
- Claude 崩潰時呼叫 `record-failure`

### 5.5 verify-task.sh — 客觀驗證

在 `project_dir` 下執行 `verify_cmd`。

- 無 verify_cmd → 自動 pass
- exit 0 → mark-pass
- exit ≠ 0 → record-failure + 呼叫 healer.py

### 5.6 task_picker.py — DAG 管理

**CLI 子命令：**

| 命令 | 說明 |
|------|------|
| `import <dir>` | 匯入 JSON 任務定義 |
| `get <task_id>` | 取得任務 JSON |
| `get-verify <task_id>` | 取得驗證指令 |
| `mark-running <task_id> <worker>` | 標記為執行中 |
| `mark-pass <task_id>` | 標記為通過 |
| `record-failure <task_id> <text>` | 記錄失敗 |
| `next-batch --max N` | 取得下批可執行任務 |
| `escalate <task_id>` | 標記為 escalated |

**next-batch 選擇邏輯：**
1. `status = 'pending'`
2. 所有 `depends_on` 任務 status = 'pass'
3. `touches` 與 running 任務不衝突
4. 回傳不超過 max 個任務

### 5.7 healer.py — 錯誤分類 + 修復策略

讀取失敗輸出，分類錯誤，產生修復建議。

**錯誤分類：**

| error_class | 匹配模式 | cooldown |
|-------------|---------|----------|
| `rate_limit` | "429", "rate limit" | 120s |
| `merge_conflict` | "merge conflict" | 0s |
| `build_fail` | "build failed" | 0s |
| `test_fail` | "test failed" | 0s |
| `unknown` | 其他 | 0s |

**策略升級：**
- attempt >= 3 → 強制 root cause 分析（prompt 前綴）
- attempt >= max_attempts → `{"action": "escalate"}`

### 5.8 watchdog.py — 健康監控

**check 子命令：**
- 卡住的任務（running > 15 分鐘）
- 全域停滯（連續 10 次失敗無通過）
- 超過重試上限 → 自動標記 escalated
- 全部完成偵測

**auto-redispatch 子命令：**
- `status='fail' AND attempt_count < max_attempts` → `status='pending'`

### 5.9 memory.py — 跨 Session 記憶

讓 Claude 能回顧先前嘗試的結果。

- `read <task_id>` — 回傳最近 3 次執行的 Markdown 格式摘要
- `write <task_id>` — 記錄本次執行結果到 runs 表

### 5.10 merge-results.py — 分支合併

將通過驗證的 worker 分支合併回 main。

- 掃描 `.worktrees/w*`
- 確認對應任務 status = 'pass'
- `git merge --no-ff`
- 衝突 → 自動建立 resolve-conflict 任務

### 5.11 agent-ctl — 監控/控制 CLI

提供完整的系統監控和控制能力。

**子命令：** status, tasks, logs, pause, resume, stop, kill, skip, retry, plan

### 5.12 notify.sh — macOS 通知

透過 `osascript` 發送桌面通知。失敗不中斷流程。

### 5.13 setup-worktrees.sh — Git Worktree 初始化

為並行 worker 建立獨立的 git worktree 工作環境。

---

## 6. 模組依賴關係

```mermaid
graph LR
    subgraph "入口"
        Loop["loop-orchestrator.sh"]
        CTL["agent-ctl"]
        Skill["/harness skill"]
    end

    subgraph "排程"
        Orch["orchestrator.sh"]
        POrc["parallel-orchestrator.sh"]
    end

    subgraph "執行"
        Run["run-task.sh"]
        Verify["verify-task.sh"]
    end

    subgraph "Python 核心"
        TP["task_picker.py"]
        Heal["healer.py"]
        WD["watchdog.py"]
        Mem["memory.py"]
        Merge["merge-results.py"]
    end

    subgraph "外部"
        Claude["Claude CLI"]
        DB[(SQLite)]
        Git["Git"]
        OS["osascript"]
    end

    Loop --> Orch
    Loop --> POrc
    Loop --> DB

    POrc --> Run
    POrc --> Verify
    Orch --> Run
    Orch --> Verify
    Orch --> WD
    Orch --> TP
    Orch --> Heal
    Orch --> Merge
    Orch -->|notify.sh| OS

    Run --> TP
    Run --> Mem
    Run --> Claude

    Verify --> TP
    Verify --> Heal

    CTL --> DB
    Skill --> TP

    TP --> DB
    Heal --> DB
    WD --> DB
    Mem --> DB
    Merge --> Git
    Merge --> DB
```

### 依賴矩陣

| 模組 | 依賴 | 被依賴 |
|------|------|--------|
| `loop-orchestrator.sh` | `orchestrator.sh`, `parallel-orchestrator.sh`, SQLite | 使用者入口 |
| `orchestrator.sh` | `task_picker.py`, `run-task.sh`, `verify-task.sh`, `healer.py`, `watchdog.py`, `merge-results.py`, `notify.sh` | `loop-orchestrator.sh`, `parallel-orchestrator.sh` |
| `parallel-orchestrator.sh` | `run-task.sh`, `verify-task.sh`, `watchdog.py`, `task_picker.py`, `merge-results.py` | `loop-orchestrator.sh` |
| `run-task.sh` | `task_picker.py`, `memory.py`, Claude CLI | `orchestrator.sh`, `parallel-orchestrator.sh` |
| `verify-task.sh` | `task_picker.py`, `healer.py` | `orchestrator.sh`, `parallel-orchestrator.sh` |
| `task_picker.py` | SQLite | 幾乎所有模組 |
| `healer.py` | SQLite | `orchestrator.sh`, `verify-task.sh` |
| `watchdog.py` | SQLite | `orchestrator.sh`, `parallel-orchestrator.sh` |
| `memory.py` | SQLite | `run-task.sh` |
| `merge-results.py` | SQLite, Git | `orchestrator.sh`, `parallel-orchestrator.sh` |
| `agent-ctl` | SQLite, `task_picker.py` | 使用者 |

---

## 7. SQLite 存取模式

```mermaid
graph TB
    subgraph "寫入者 (WAL mode 允許並行寫入)"
        W0["Worker 0"]
        W1["Worker 1"]
        WN["Worker N"]
        WD["watchdog.py"]
        Heal["healer.py"]
    end

    subgraph "讀取者"
        CTL["agent-ctl"]
        Loop["loop-orchestrator.sh<br/>(sqlite3 查詢)"]
        TP["task_picker.py<br/>next-batch"]
    end

    DB[(db/agent.db<br/>WAL mode)]

    W0 & W1 & WN & WD & Heal -->|寫入| DB
    CTL & Loop & TP -->|讀取| DB
```

**WAL 模式優勢：**
- 讀寫不互相阻塞
- 多個 reader 可同時讀取
- 寫入是序列化的，但速度足夠（SQLite 可處理數千次/秒）

---

## 8. 跨專案執行架構

```mermaid
flowchart TB
    Harness["Agent Harness<br/>/path/to/agent-harness/"]

    subgraph "Target Projects"
        P1["Project A<br/>/home/user/project-a/"]
        P2["Project B<br/>/home/user/project-b/"]
        P3["Project C<br/>/home/user/project-c/"]
    end

    Harness -->|"task.project_dir"| P1
    Harness -->|"task.project_dir"| P2
    Harness -->|"task.project_dir"| P3

    subgraph "run-task.sh 工作目錄選擇"
        D1{"project_dir 存在?"}
        D1 -->|Yes| CD1["cd project_dir<br/>(跨專案模式)"]
        D1 -->|No| D2{"worktree 存在?"}
        D2 -->|Yes| CD2["cd .worktrees/wN<br/>(並行隔離模式)"]
        D2 -->|No| CD3["cd harness_dir<br/>(fallback)"]
    end
```

---

## 9. 安裝與部署

### 一鍵安裝

```bash
curl -sSL https://raw.githubusercontent.com/Muheng1992/agent-harness/main/install.sh | bash
```

**install.sh 做的事：**
1. 檢查 prerequisites（python3, sqlite3, jq, git, claude）
2. Clone 或 update repo 到 `~/.agent-harness/`
3. 初始化 SQLite 資料庫
4. 設定腳本執行權限
5. 建立 `agent-ctl` symlink 到 `~/.local/bin/`
6. 安裝 `/harness` Claude Code skill

### 目錄結構

```
~/.agent-harness/           # 安裝目錄
├── db/agent.db             # 所有任務狀態
├── tasks/{project}/        # 任務定義
├── logs/                   # 執行日誌
└── .worktrees/             # Git worktrees (並行用)

~/.local/bin/agent-ctl      # CLI symlink
~/.claude/commands/harness.md  # Claude Code skill
```

---

## 10. 設計決策與取捨

### 為什麼用 SQLite 而非 Redis/Postgres？

- 零依賴：macOS 內建 sqlite3
- WAL 模式足以應付 4-8 個並行 worker
- 單檔案，方便備份和傳輸
- 適合本機執行的 agent 系統（非分散式）

### 為什麼每輪都啟動新 Claude session？

- 避免 context window 壓縮導致的遺忘
- 每輪乾淨狀態，避免前次失敗的殘留影響
- 記憶外化到 SQLite，由 memory.py 在 prompt 中注入相關上下文
- Max 訂閱方案無 API 費用限制

### 為什麼 loop-orchestrator 而非 cron？

- cron 需要額外設定，且缺乏智慧冷卻
- loop-orchestrator 能根據 error_class 動態調整 cooldown
- 內建安全限制（max-rounds, max-time）
- 更好的進度追蹤和日誌輸出
- cron 仍可用，但不再是推薦方式

### verify_cmd 的安全考量

- verify_cmd 直接在 shell 中 `eval` 執行
- **前提假設**：任務 JSON 來自可信來源（你自己或 /harness skill）
- 不適合執行來自不可信使用者提交的任務

---

## 11. 多角色系統架構

### 11.1 角色系統架構圖

```
┌─────────────────────────────────────────────────────────────────┐
│                        run-task.sh                              │
│  ┌───────────┐    ┌───────────────┐    ┌──────────────────┐    │
│  │ 讀取 task │───→│ 載入 role 定義 │───→│ 組合最終 prompt  │    │
│  │ (task_id) │    │ (roles/*.md)  │    │ role + goal +    │    │
│  └───────────┘    └───────────────┘    │ memory + heal    │    │
│                          │              └────────┬─────────┘    │
│                          │                       │              │
│                   ┌──────▼──────┐         ┌──────▼──────┐      │
│                   │ 解析 YAML   │         │ claude -p   │      │
│                   │ frontmatter │         │ --allowedTools│     │
│                   │             │         │ $CLAUDE_TOOLS │     │
│                   │ name        │         └─────────────┘      │
│                   │ allowed_tools│                               │
│                   │ model       │                               │
│                   └─────────────┘                               │
└─────────────────────────────────────────────────────────────────┘

角色定義檔結構：
┌─────────────────────────────┐
│  roles/                     │
│  ├── planner.md        只讀 │  ← Read,Grep,Glob,Bash
│  ├── researcher.md     只讀 │  ← Read,Bash,WebSearch,WebFetch,Grep,Glob
│  ├── architect.md      只讀 │  ← Read,Grep,Glob,Bash
│  ├── implementer.md    讀寫 │  ← Edit,Write,Bash,Read,Grep,Glob
│  ├── tester.md         讀寫 │  ← Edit,Write,Bash,Read,Grep,Glob
│  ├── reviewer.md       只讀 │  ← Read,Grep,Glob,Bash
│  ├── debugger.md       讀寫 │  ← Edit,Write,Bash,Read,Grep,Glob
│  ├── security-auditor.md只讀│  ← Read,Grep,Glob,Bash
│  ├── documenter.md     讀寫 │  ← Write,Edit,Read,Grep,Glob,Bash
│  ├── integrator.md     讀寫 │  ← Edit,Write,Bash,Read,Grep,Glob
│  └── devops.md         讀寫 │  ← Edit,Write,Bash,Read,Grep,Glob
└─────────────────────────────┘

工具權限分級：
┌──────────────┬──────────────────────────────────────────┐
│ 分析/審查類   │ 只授予 Read, Grep, Glob, Bash            │
│ （不修改程式碼）│ planner, architect, reviewer,            │
│              │ security-auditor                          │
├──────────────┼──────────────────────────────────────────┤
│ 實作/修復類   │ 額外授予 Edit, Write                      │
│ （需修改程式碼）│ implementer, tester, debugger,           │
│              │ documenter, integrator, devops            │
├──────────────┼──────────────────────────────────────────┤
│ 研究類       │ 額外授予 WebSearch, WebFetch               │
│ （需上網查資料）│ researcher                               │
└──────────────┴──────────────────────────────────────────┘
```

### 11.2 角色載入流程

```mermaid
sequenceDiagram
    participant RT as run-task.sh
    participant TP as task_picker.py
    participant RF as roles/*.md
    participant Mem as memory.py
    participant C as Claude CLI

    RT->>TP: get $TASK_ID
    TP-->>RT: {goal, role, last_error, ...}

    RT->>RF: 讀取 roles/${ROLE}.md
    RF-->>RT: frontmatter (allowed_tools) + 角色 prompt

    RT->>Mem: read $TASK_ID
    Mem-->>RT: 歷史上下文

    Note over RT: 組合 prompt =<br/>角色 prompt + goal +<br/>memory context + heal prompt

    RT->>C: claude -p "$PROMPT"<br/>--allowedTools "$CLAUDE_TOOLS"
    C-->>RT: 執行結果
```

---

## 12. Pipeline 引擎資料流

### 12.1 Pipeline 生命週期

```mermaid
stateDiagram-v2
    [*] --> active: pipeline.py create
    active --> active: advance（部分階段完成）
    active --> completed: 所有階段 pass
    active --> failed: 任一階段 escalated
    active --> paused: 手動暫停

    paused --> active: 手動恢復
```

### 12.2 Pipeline 建立與執行資料流

```mermaid
flowchart TB
    subgraph "1. Pipeline 建立"
        User["使用者"]
        User -->|"pipeline.py create<br/>--template full-dev-cycle<br/>--var feature=X"| PY["pipeline.py"]
        PY -->|"讀取模板"| TPL["pipelines/*.yaml"]
        PY -->|"替換 {variable}"| Goals["產生各階段 goal"]
        PY -->|"寫入 pipelines 表"| DB[(SQLite)]
        PY -->|"寫入 tasks 表<br/>（含 role, stage, pipeline_id,<br/>depends_on 鏈）"| DB
    end

    subgraph "2. 自動執行"
        Loop["loop-orchestrator.sh"]
        Loop -->|"照常運作"| Orch["orchestrator.sh"]
        Orch -->|"next-batch"| TP["task_picker.py"]
        TP -->|"depends_on 滿足?"| DB
        TP -->|"回傳可執行任務"| Orch
        Orch -->|"run-task.sh"| RT["run-task.sh"]
        RT -->|"載入角色定義"| Roles["roles/*.md"]
        RT -->|"claude -p"| Claude["Claude CLI"]
    end

    subgraph "3. Fix Loop"
        Fail["階段失敗"]
        Fail -->|"pipeline.py advance"| Advance["advance 邏輯"]
        Advance -->|"on_fail 定義?"| Check{"fix_count<br/>< max?"}
        Check -->|"Yes"| Spawn["產生 debugger 任務<br/>+ 重試原階段任務"]
        Check -->|"No"| Esc["escalate"]
        Spawn -->|"寫入 tasks 表"| DB
    end

    DB --> Loop

    style DB fill:#1a3a5c,color:#fff
    style Claude fill:#5c1a1a,color:#fff
    style Loop fill:#2d5016,color:#fff
```

### 12.3 元件交互圖

```
┌─────────────────────────────────────────────────────────────────────┐
│                        使用者操作                                     │
│  pipeline.py create ──→ 建立 pipeline + tasks                        │
│  agent-ctl status    ──→ 查看執行進度                                  │
│  loop-orchestrator.sh ─→ 啟動自動執行                                  │
└──────────┬──────────────────────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────────────────────┐
│  task_picker.py                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ next-batch: 查詢 status='pending' AND depends_on 全 pass       │  │
│  │            + touches 衝突檢查 + role 欄位保留                    │  │
│  └────────────────┬───────────────────────────────────────────────┘  │
└───────────────────┼──────────────────────────────────────────────────┘
                    │ 回傳 task_id（含 role 資訊）
                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│  run-task.sh                                                         │
│  ┌──────────┐  ┌──────────────┐  ┌────────────┐  ┌──────────────┐  │
│  │ 讀取 task │→│ 讀取 role 定義│→│ 讀取 memory │→│ 組合 prompt   │  │
│  │ (DB)     │  │ (roles/*.md) │  │ (memory.py)│  │ + heal context│  │
│  └──────────┘  └──────────────┘  └────────────┘  └──────┬───────┘  │
│                                                          │          │
│                                              claude -p + --allowedTools│
└──────────────────────────────────────────────────────────────────────┘
                    │ 執行完成
                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│  pipeline.py advance（由 orchestrator 在每輪呼叫）                     │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │ 檢查 pipeline 下所有 tasks 的 status                          │    │
│  │ ├─ 全部 pass → pipeline status = completed                   │    │
│  │ ├─ 有 escalated → pipeline status = failed                   │    │
│  │ └─ 有 fail + on_fail 定義 → 產生 debugger + retry 任務        │    │
│  └──────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 13. 新增的資料庫欄位

### 13.1 tasks 表新增欄位

| 欄位 | 型別 | 預設值 | 說明 |
|------|------|--------|------|
| `role` | TEXT | `'implementer'` | 指派角色，對應 `roles/*.md` 的檔案名稱 |
| `stage` | TEXT | NULL | Pipeline 階段名稱（如 research、design、implement） |
| `pipeline_id` | TEXT | NULL | 所屬 pipeline 群組 ID，用於追蹤多階段流程 |
| `spawned_by` | TEXT | NULL | 觸發此任務的上游任務 ID（fix loop 產生的任務會指向失敗的原任務） |

### 13.2 新增 pipelines 表

```sql
CREATE TABLE IF NOT EXISTS pipelines (
  id         TEXT PRIMARY KEY,           -- pipe-{timestamp}-{random}
  name       TEXT NOT NULL,              -- 模板顯示名稱
  project    TEXT NOT NULL,              -- 所屬專案
  template   TEXT,                       -- 使用的模板名稱（如 full-dev-cycle）
  config     TEXT DEFAULT '{}',          -- JSON 配置（變數、verify_cmd、fix_loops）
  status     TEXT DEFAULT 'active'       -- active|completed|failed|paused
             CHECK(status IN ('active','completed','failed','paused')),
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

### 13.3 新增索引

```sql
CREATE INDEX IF NOT EXISTS idx_tasks_role ON tasks(role);
CREATE INDEX IF NOT EXISTS idx_tasks_pipeline_id ON tasks(pipeline_id);
CREATE INDEX IF NOT EXISTS idx_pipelines_status ON pipelines(status);
```

---

*文件版本: 3.0 | 建立日期: 2026-04-01 | Agent Harness 架構設計（含多角色 + Pipeline 系統）*
