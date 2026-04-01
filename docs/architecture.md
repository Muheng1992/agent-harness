# Agent Harness — 系統架構文件

> 自主多代理編排系統，基於 Claude Code CLI 構建。
> 透過外部排程觸發、SQLite 持久化、Git worktree 隔離、客觀驗證。

---

## 1. 模組依賴圖

```
                        ┌─────────────────┐
                        │  外部排程器       │
                        │  (cron/launchd)  │
                        └────────┬────────┘
                                 │ 觸發
                                 ▼
          ┌──────────────────────────────────────────┐
          │  parallel-orchestrator.sh                 │
          │  (平行調度 N 個 worker)                    │
          └──┬───────┬───────┬───────┬───────┬──────┘
             │       │       │       │       │
             ▼       │       │       │       │
   ┌─────────────┐   │       │       │       │
   │orchestrator │   │       │       │       │
   │   .sh       │   │       │       │       │
   │ (單輪主迴圈) │   │       │       │       │
   └──┬──┬──┬──┬─┘   │       │       │       │
      │  │  │  │      │       │       │       │
      │  │  │  │      ▼       ▼       │       │
      │  │  │  │  ┌──────┐ ┌──────┐   │       │
      │  │  │  │  │run-  │ │run-  │   │       │
      │  │  │  │  │task  │ │task  │  ...      │
      │  │  │  │  │.sh   │ │.sh   │   │       │
      │  │  │  │  └──┬───┘ └──┬───┘   │       │
      │  │  │  │     │        │       │       │
      │  │  │  │     ▼        ▼       │       │
      │  │  │  │  ┌─────────────┐     │       │
      │  │  │  │  │ verify-task │     │       │
      │  │  │  │  │    .sh      │     │       │
      │  │  │  │  └──────┬──────┘     │       │
      │  │  │  │         │            │       │
      ▼  ▼  ▼  ▼         ▼            ▼       ▼
┌─────────────────────────────────────────────────┐
│                  Python 核心模組                   │
│  ┌────────────┐ ┌────────┐ ┌──────────┐         │
│  │task_picker │ │memory  │ │ healer   │         │
│  │   .py      │ │  .py   │ │   .py    │         │
│  └─────┬──────┘ └───┬────┘ └────┬─────┘         │
│        │            │           │                │
│  ┌─────┴────────────┴───────────┴─────┐         │
│  │          SQLite (WAL mode)          │         │
│  │          db/agent.db                │         │
│  └─────────────────────────────────────┘         │
│  ┌────────────┐ ┌──────────────┐                 │
│  │watchdog.py │ │merge-results │                 │
│  │            │ │    .py       │                 │
│  └────────────┘ └──────────────┘                 │
└─────────────────────────────────────────────────┘

  ┌────────────────────┐   ┌────────────────┐
  │ agent-ctl          │   │ setup-worktrees│
  │ (監控/控制 CLI)     │   │    .sh         │
  └────────────────────┘   └────────────────┘

  ┌────────────────┐
  │ notify.sh      │
  │ (macOS 通知)   │
  └────────────────┘
```

### 依賴關係矩陣

| 模組 | 依賴 | 被依賴 |
|------|------|--------|
| `parallel-orchestrator.sh` | `orchestrator.sh`, `setup-worktrees.sh` | 外部排程器 |
| `orchestrator.sh` | `task_picker.py`, `run-task.sh`, `healer.py`, `watchdog.py`, `merge-results.py`, `notify.sh` | `parallel-orchestrator.sh` |
| `run-task.sh` | `memory.py`, `task_picker.py`, `claude -p`, `verify-task.sh` | `orchestrator.sh` |
| `verify-task.sh` | `task_picker.py` | `run-task.sh` |
| `task_picker.py` | SQLite | `orchestrator.sh`, `run-task.sh`, `verify-task.sh`, `agent-ctl` |
| `healer.py` | SQLite | `orchestrator.sh`, `run-task.sh` |
| `memory.py` | SQLite | `run-task.sh` |
| `watchdog.py` | SQLite, `task_picker.py` | `orchestrator.sh`, 外部排程器 |
| `merge-results.py` | SQLite, Git | `orchestrator.sh` |
| `agent-ctl` | SQLite, `task_picker.py` | 使用者 |
| `setup-worktrees.sh` | Git | `parallel-orchestrator.sh` |
| `notify.sh` | `osascript` | `orchestrator.sh` |

---

## 2. 模組公開 API

### 2.1 task_picker.py — DAG 管理與任務選擇

**位置**: `src/task_picker.py`
**CLI 介面**: `python3 task_picker.py <command> [args]`

```python
"""
task_picker.py — 任務 DAG 管理器

負責任務匯入、依賴解析、衝突偵測、狀態轉換。
所有狀態儲存於 SQLite，透過 CLI 子命令對外暴露功能。
"""

import sqlite3, json, sys
from pathlib import Path

DB_PATH = Path(__file__).parent.parent / "db" / "agent.db"

# ── 公開函式 ──────────────────────────────────────────────

def import_tasks(task_dir: str) -> dict:
    """
    匯入任務定義檔目錄。

    掃描 task_dir 下所有 .json 檔案，解析為任務物件，
    寫入 tasks 表。若 task ID 已存在則跳過（不覆蓋）。

    參數:
        task_dir: 包含任務 JSON 檔案的目錄路徑

    回傳:
        {"imported": int, "skipped": int, "errors": list[str]}

    Exit code: 0=成功, 1=目錄不存在或無有效檔案
    """

def get_task(task_id: str) -> dict | None:
    """
    取得單一任務的完整資訊。

    參數:
        task_id: 任務 ID

    回傳:
        任務字典（含所有欄位），或 None（不存在時）
    輸出:
        JSON 格式輸出至 stdout
    Exit code: 0=找到, 1=不存在
    """

def get_verify_cmd(task_id: str) -> str | None:
    """
    取得任務的驗證指令。

    參數:
        task_id: 任務 ID

    回傳:
        verify_cmd 字串，或 None
    輸出:
        純文字輸出至 stdout
    Exit code: 0=找到, 1=不存在
    """

def mark_running(task_id: str, worker_id: int) -> bool:
    """
    將任務標記為 running 狀態。

    前置條件: status 必須為 'pending' 或 'fail'
    副作用:
      - 更新 tasks.status = 'running'
      - 更新 tasks.assigned_worker = worker_id
      - 更新 tasks.attempt_count += 1
      - 插入一筆 runs 記錄 (status='running')

    參數:
        task_id: 任務 ID
        worker_id: 執行此任務的 worker 編號

    回傳:
        True=成功, False=前置條件不滿足
    Exit code: 0=成功, 1=失敗
    """

def mark_pass(task_id: str) -> bool:
    """
    將任務標記為通過。

    前置條件: status 必須為 'running'
    副作用:
      - 更新 tasks.status = 'pass'
      - 更新對應 runs 記錄 (status='pass', finished_at=now)

    Exit code: 0=成功, 1=失敗
    """

def record_failure(task_id: str, failure_text: str) -> bool:
    """
    記錄任務失敗。

    前置條件: status 必須為 'running'
    副作用:
      - 若 attempt_count >= max_attempts → status='escalated'
      - 否則 → status='fail'
      - 更新 tasks.last_error = failure_text[:2000]
      - 更新對應 runs 記錄 (status='fail', verify_output=failure_text)

    Exit code: 0=成功, 1=失敗
    """

def next_batch(max_count: int = 4) -> list[dict]:
    """
    取得下一批可執行的任務。

    選擇邏輯:
      1. status 為 'pending' 或 'fail'（且 attempt_count < max_attempts）
      2. depends_on 中所有任務的 status 均為 'pass'
      3. touches 中的檔案與目前 status='running' 的任務無衝突
      4. 按 attempt_count ASC, created_at ASC 排序（優先新任務）

    參數:
        max_count: 最多回傳幾個任務（預設 4）

    回傳:
        任務字典列表（JSON array 輸出至 stdout）
    Exit code: 0（即使結果為空）
    """
```

**CLI 使用範例**:
```bash
# 匯入任務
python3 src/task_picker.py import tasks/my-project/

# 取得任務資訊
python3 src/task_picker.py get task-001

# 取得驗證指令
python3 src/task_picker.py get-verify task-001

# 標記為執行中
python3 src/task_picker.py mark-running task-001 1

# 標記通過
python3 src/task_picker.py mark-pass task-001

# 記錄失敗
python3 src/task_picker.py record-failure task-001 "test_login failed: AssertionError"

# 取得下一批任務
python3 src/task_picker.py next-batch --max 4
```

---

### 2.2 healer.py — 錯誤分類與修復策略

**位置**: `src/healer.py`
**CLI 介面**: `python3 healer.py <task_id> <failure_output_file>`

```python
"""
healer.py — 自我修復引擎

根據失敗輸出分類錯誤類型，產生修復策略。
連續失敗 3 次以上時，切換至根因分析模式。
"""

# ── 錯誤分類 ──────────────────────────────────────────────

ERROR_PATTERNS = {
    "rate_limit":     [r"rate.?limit", r"429", r"too many requests", r"quota exceeded"],
    "build_fail":     [r"SyntaxError", r"ImportError", r"ModuleNotFoundError",
                       r"compile.*(error|fail)", r"cannot find module"],
    "test_fail":      [r"FAILED", r"AssertionError", r"test.*fail",
                       r"Expected.*but.*got"],
    "merge_conflict": [r"CONFLICT", r"merge conflict", r"cannot merge"],
    "timeout":        [r"timeout", r"timed.?out", r"deadline exceeded"],
}
# 未匹配任何模式 → "unknown"

def classify_error(failure_text: str) -> str:
    """
    分類錯誤類型。

    逐一匹配 ERROR_PATTERNS，回傳第一個匹配的分類。
    無匹配時回傳 "unknown"。

    參數:
        failure_text: 失敗輸出文字

    回傳:
        錯誤分類字串
    """

def generate_strategy(task_id: str, error_class: str,
                       attempt_count: int, failure_text: str) -> dict:
    """
    根據錯誤分類與歷史資訊產生修復策略。

    策略邏輯:
      - rate_limit → {"action": "retry_after_cooldown", "cooldown_sec": 60}
      - build_fail → {"action": "retry_with_context",
                       "extra_prompt": "上次構建失敗: {摘要}。請修正語法/匯入錯誤。"}
      - test_fail  → {"action": "retry_with_context",
                       "extra_prompt": "測試失敗: {摘要}。請分析失敗原因並修正。"}
      - merge_conflict → {"action": "retry_with_context",
                          "extra_prompt": "合併衝突: 請先 pull 最新程式碼再重試。"}
      - timeout → {"action": "retry", "extra_prompt": ""}
      - unknown → {"action": "retry_with_context",
                    "extra_prompt": "未知錯誤: {前500字元}"}

      attempt_count >= 3 時，所有策略覆寫為:
        {"action": "retry_with_context",
         "extra_prompt": "已失敗 {N} 次。請先分析根本原因再動手修改。
                          最近錯誤: {摘要}"}

      attempt_count >= max_attempts 時:
        {"action": "escalate", "extra_prompt": "已達最大重試次數"}

    參數:
        task_id: 任務 ID（用於查詢歷史）
        error_class: 錯誤分類
        attempt_count: 目前嘗試次數
        failure_text: 完整失敗輸出

    回傳:
        策略字典 {"action": str, "extra_prompt": str, "cooldown_sec": int}
    輸出:
        JSON 格式輸出至 stdout
    Exit code: 0
    """

def heal(task_id: str, failure_output_file: str) -> dict:
    """
    主入口：讀取失敗檔案，分類錯誤，產生策略。

    流程:
      1. 讀取 failure_output_file 內容
      2. 呼叫 classify_error() 取得分類
      3. 從 DB 查詢 task 的 attempt_count 與 max_attempts
      4. 更新 tasks.error_class
      5. 呼叫 generate_strategy() 產生策略
      6. 輸出 JSON 至 stdout

    Exit code: 0=成功, 1=檔案不存在或任務不存在
    """
```

**輸出範例**:
```json
{
  "error_class": "test_fail",
  "action": "retry_with_context",
  "extra_prompt": "測試失敗: test_login AssertionError expected 200 got 401。請分析失敗原因並修正。",
  "cooldown_sec": 0
}
```

---

### 2.3 watchdog.py — 死鎖偵測與自動重派

**位置**: `src/watchdog.py`
**CLI 介面**: `python3 watchdog.py <check|auto-redispatch>`

```python
"""
watchdog.py — 系統健康監控

偵測三類異常:
  1. 卡住的任務 (running 但 worker 已死)
  2. 全域停滯 (連續 N 次失敗無通過)
  3. 長時間執行 (超過閾值)
"""

STUCK_THRESHOLD_MIN = 15       # 任務執行超過 15 分鐘視為卡住
GLOBAL_STALL_THRESHOLD = 10    # 連續 10 次失敗無通過視為停滯

def check() -> dict:
    """
    執行所有健康檢查。

    檢查項目:
      1. stuck_tasks: status='running' 且 runs.started_at 距今 > 15 分鐘
      2. global_stall: 檢查最近 N 筆 runs，若連續 10+ 筆為 fail 且無 pass
      3. exhausted_tasks: status='fail' 且 attempt_count >= max_attempts
                          但 status 尚未被設為 'escalated'

    回傳:
        {
            "stuck_tasks": [{"task_id": str, "worker_id": int, "running_min": float}],
            "global_stall": bool,
            "exhausted_tasks": [{"task_id": str, "attempts": int}],
            "healthy": bool
        }
    輸出:
        JSON 至 stdout（check 模式）
        人類可讀文字至 stderr（摘要）
    Exit code: 0=健康, 1=有問題
    """

def auto_redispatch() -> dict:
    """
    自動修復偵測到的問題。

    動作:
      1. stuck_tasks → 將 status 重設為 'fail'，清除 assigned_worker
      2. exhausted_tasks → 將 status 設為 'escalated'
      3. global_stall → 設定 control.global_state='paused'，呼叫 notify.sh

    回傳:
        {"redispatched": int, "escalated": int, "paused": bool}
    Exit code: 0
    """
```

---

### 2.4 memory.py — 跨 Session 記憶

**位置**: `src/memory.py`
**CLI 介面**: `python3 memory.py <read|write> <task_id> [output_file]`

```python
"""
memory.py — 任務記憶管理

為 Claude 提供先前執行的上下文，避免重複犯錯。
讀取最近 3 次執行記錄，格式化為 Markdown 供 prompt 使用。
"""

MAX_HISTORY = 3             # 最多讀取最近 3 次記錄
MAX_OUTPUT_CHARS = 3000     # 每次記錄最多保留的字元數

def read_memory(task_id: str) -> str:
    """
    讀取任務的歷史記憶。

    查詢 runs 表中該 task_id 最近 3 筆記錄，
    格式化為 Markdown：

    ```
    ## 先前執行記錄

    ### 嘗試 #1 (fail) — 2024-01-15 10:30
    **錯誤分類**: test_fail
    **Claude 輸出摘要**: (前 1000 字元)
    **驗證輸出**: (前 500 字元)

    ### 嘗試 #2 (fail) — 2024-01-15 10:45
    ...
    ```

    若無歷史記錄，回傳空字串。

    參數:
        task_id: 任務 ID

    回傳:
        Markdown 格式的記憶文字
    輸出:
        Markdown 至 stdout
    Exit code: 0
    """

def write_memory(task_id: str, output_file: str) -> bool:
    """
    儲存本次執行結果。

    讀取 output_file 的內容，更新最近一筆 runs 記錄的
    claude_output 欄位。

    參數:
        task_id: 任務 ID
        output_file: Claude 輸出檔案路徑

    回傳:
        True=成功
    Exit code: 0=成功, 1=檔案不存在
    """
```

---

### 2.5 merge-results.py — 合併成功分支

**位置**: `src/merge-results.py`
**CLI 介面**: `python3 merge-results.py`

```python
"""
merge-results.py — Git 分支合併管理

將所有通過驗證的 worker 分支合併回 main。
遇到合併衝突時，自動建立新任務處理。
"""

def merge_all() -> dict:
    """
    合併所有通過驗證的任務分支。

    流程:
      1. 查詢所有 status='pass' 且尚未合併的任務
      2. 對每個任務:
         a. 確認 worktree 中的分支存在
         b. 切換至 main 分支
         c. 執行 git merge --no-ff worker-{id}/{task_id}
         d. 若成功 → 記錄已合併
         e. 若衝突 → git merge --abort，建立新衝突解決任務
      3. 清理已合併的 worktree 分支

    回傳:
        {
            "merged": [str],           # 已合併的任務 ID
            "conflicts": [str],        # 衝突的任務 ID
            "new_tasks": [str],        # 新建的衝突解決任務 ID
            "errors": [str]            # 其他錯誤
        }
    輸出:
        JSON 至 stdout
    Exit code: 0=全部成功, 1=部分失敗
    """

def _create_conflict_task(task_id: str, conflict_files: list[str]) -> str:
    """
    為合併衝突建立新任務。

    新任務:
      - id: "resolve-conflict-{task_id}"
      - goal: "解決 {task_id} 合併衝突，衝突檔案: {files}"
      - depends_on: [task_id]
      - touches: conflict_files
      - verify: "git diff --check"

    回傳:
        新任務 ID
    """
```

---

### 2.6 orchestrator.sh — 單輪主迴圈

**位置**: `scripts/orchestrator.sh`

```bash
#!/usr/bin/env bash
# orchestrator.sh — 單輪編排迴圈
#
# 用法: ./scripts/orchestrator.sh [--worker-id N]
#
# 執行流程:
#   1. 檢查 control.global_state == 'running'，否則退出
#   2. 呼叫 watchdog.py check，若有問題則 auto-redispatch
#   3. 呼叫 task_picker.py next-batch --max 1 取得一個任務
#   4. 若無任務 → 嘗試 merge-results.py → 退出
#   5. 呼叫 task_picker.py mark-running <task_id> <worker_id>
#   6. 呼叫 run-task.sh <task_id>
#   7. 根據 run-task.sh 的 exit code:
#      - 0 → 成功，繼續
#      - 非 0 → 呼叫 healer.py，根據策略決定下一步
#   8. 呼叫 merge-results.py 合併通過的任務
#   9. 呼叫 notify.sh 發送狀態通知
#
# Exit codes:
#   0 — 正常完成
#   1 — 錯誤
#   2 — 系統已暫停
#
# 環境變數:
#   AGENT_DB     — 資料庫路徑 (預設: db/agent.db)
#   WORKER_ID    — Worker 編號 (預設: 0)
#   PROJECT_ROOT — 專案根目錄 (預設: 腳本所在目錄的上一層)
```

---

### 2.7 parallel-orchestrator.sh — 平行調度

**位置**: `scripts/parallel-orchestrator.sh`

```bash
#!/usr/bin/env bash
# parallel-orchestrator.sh — 平行 Worker 調度器
#
# 用法: ./scripts/parallel-orchestrator.sh [--workers N]
#
# 執行流程:
#   1. 讀取 control.max_parallel 決定 worker 數量（或用 --workers 覆蓋）
#   2. 呼叫 setup-worktrees.sh 確保 worktree 存在
#   3. 為每個 worker 在背景啟動 orchestrator.sh --worker-id N
#   4. 等待所有 worker 結束
#   5. 執行 merge-results.py
#   6. 輸出摘要
#
# 訊號處理:
#   SIGTERM/SIGINT → 設定 control.global_state='stopping'
#                  → 等待 worker 完成當前任務
#                  → 清理 PID 檔案
#
# PID 管理:
#   每個 worker 的 PID 寫入 .worker.pid.{N}
#   主程序 PID 寫入 .orchestrator.pid
```

---

### 2.8 run-task.sh — 單一任務執行

**位置**: `scripts/run-task.sh`

```bash
#!/usr/bin/env bash
# run-task.sh — 在隔離環境中執行單一任務
#
# 用法: ./scripts/run-task.sh <task_id>
#
# 執行流程:
#   1. python3 src/task_picker.py get <task_id> → 取得任務資訊
#   2. python3 src/memory.py read <task_id> → 取得歷史上下文
#   3. 組合 prompt:
#      - 系統指令（專案慣例、禁止事項）
#      - 歷史上下文（來自 memory.py）
#      - 任務目標（來自 task.goal）
#      - healer 的 extra_prompt（若有）
#   4. 切換至對應 worktree 目錄
#   5. 建立任務分支: git checkout -b worker-{worker_id}/{task_id}
#   6. 執行: claude -p "$PROMPT" --output-file /tmp/claude-out-{task_id}.txt
#   7. 儲存結果: python3 src/memory.py write <task_id> /tmp/claude-out-{task_id}.txt
#   8. 執行驗證: ./scripts/verify-task.sh <task_id>
#   9. 根據驗證結果:
#      - 通過 → python3 src/task_picker.py mark-pass <task_id>
#      - 失敗 → python3 src/task_picker.py record-failure <task_id> <failure>
#
# Exit codes:
#   0 — 任務通過驗證
#   1 — 任務失敗（已記錄）
#   2 — 系統錯誤（任務不存在等）
#
# 超時:
#   claude -p 執行設定 timeout 為 600 秒 (10 分鐘)
#   verify 設定 timeout 為 120 秒 (2 分鐘)
```

---

### 2.9 verify-task.sh — 任務驗證

**位置**: `scripts/verify-task.sh`

```bash
#!/usr/bin/env bash
# verify-task.sh — 執行任務的客觀驗證
#
# 用法: ./scripts/verify-task.sh <task_id>
#
# 執行流程:
#   1. python3 src/task_picker.py get-verify <task_id> → 取得 verify_cmd
#   2. 若 verify_cmd 為空 → 視為通過（exit 0）
#   3. 在對應 worktree 中執行 verify_cmd
#   4. 擷取 stdout + stderr 作為驗證輸出
#   5. 根據 exit code 決定結果
#
# Exit codes:
#   0 — 驗證通過
#   1 — 驗證失敗
#   2 — verify_cmd 無法執行（命令不存在等）
#
# 輸出:
#   驗證輸出寫入 /tmp/verify-out-{task_id}.txt
```

---

### 2.10 setup-worktrees.sh — 初始化 Git Worktree

**位置**: `scripts/setup-worktrees.sh`

```bash
#!/usr/bin/env bash
# setup-worktrees.sh — 建立 Git Worktree 工作環境
#
# 用法: ./scripts/setup-worktrees.sh [--workers N] [--project-repo PATH]
#
# 執行流程:
#   1. 驗證 --project-repo 是有效的 Git 倉庫
#   2. 為每個 worker (0..N-1) 建立 worktree:
#      git worktree add .worktrees/worker-{N} -b worker-{N}-base main
#   3. 在每個 worktree 中安裝依賴（若有 package.json / requirements.txt）
#   4. 輸出摘要
#
# 冪等性:
#   若 worktree 已存在，跳過建立。
#   若分支已存在，重用分支。
#
# Exit codes:
#   0 — 成功
#   1 — 目標不是 Git 倉庫
```

---

### 2.11 notify.sh — macOS 通知

**位置**: `scripts/notify.sh`

```bash
#!/usr/bin/env bash
# notify.sh — 發送 macOS 桌面通知
#
# 用法: ./scripts/notify.sh <message> [--title TITLE] [--sound SOUND]
#
# 實作:
#   osascript -e 'display notification "MESSAGE" with title "TITLE"'
#
# 預設值:
#   TITLE: "Agent Harness"
#   SOUND: "default"
#
# Exit code: 0（即使通知失敗也不中斷流程）
```

---

### 2.12 agent-ctl — 監控與控制 CLI

**位置**: `bin/agent-ctl`（Python with shebang `#!/usr/bin/env python3`）

```python
"""
agent-ctl — Agent Harness 控制面板

用法:
    agent-ctl status              # 系統狀態總覽
    agent-ctl tasks [project]     # 列出任務清單
    agent-ctl logs <task_id>      # 查看任務執行日誌
    agent-ctl pause               # 暫停系統
    agent-ctl resume              # 恢復系統
    agent-ctl stop                # 優雅停止（等待當前任務完成）
    agent-ctl kill [worker_id]    # 強制終止 worker
    agent-ctl skip <task_id>      # 跳過任務
    agent-ctl retry <task_id>     # 重試任務（重設 attempt_count）
"""

def cmd_status() -> None:
    """
    顯示系統狀態總覽。

    輸出:
        - global_state: running/paused/stopping
        - workers: 活躍/總數
        - tasks: pending/running/pass/fail/escalated 計數
        - 最近 5 筆執行記錄
        - 磁碟/DB 大小
    """

def cmd_tasks(project: str | None = None) -> None:
    """
    列出任務清單。

    以表格格式顯示:
        ID | Status | Attempts | Worker | Error Class | Goal (前40字)

    參數:
        project: 篩選特定專案（可選）
    """

def cmd_logs(task_id: str) -> None:
    """
    查看任務的完整執行日誌。

    輸出 runs 表中所有該任務的記錄，包含:
        - 每次嘗試的 claude_output 與 verify_output
        - 時間戳與耗時
    """

def cmd_pause() -> None:
    """暫停系統。設定 control.global_state='paused'。"""

def cmd_resume() -> None:
    """恢復系統。設定 control.global_state='running'。"""

def cmd_stop() -> None:
    """
    優雅停止。
    設定 control.global_state='stopping'。
    Worker 完成當前任務後自行退出。
    """

def cmd_kill(worker_id: int | None = None) -> None:
    """
    強制終止 worker。

    讀取 .worker.pid.{N} 檔案，發送 SIGTERM。
    若 worker_id 為 None，終止所有 worker。
    """

def cmd_skip(task_id: str) -> None:
    """
    跳過任務。設定 status='skipped'。
    注意: 依賴此任務的下游任務也將被標記為 skipped。
    """

def cmd_retry(task_id: str) -> None:
    """
    重試任務。
    重設 attempt_count=0，status='pending'。
    清除 error_class 與 last_error。
    """
```

---

## 3. 資料流

### 3.1 正常執行流

```
┌────────────┐
│ cron 觸發   │
└─────┬──────┘
      │
      ▼
parallel-orchestrator.sh
      │
      ├── setup-worktrees.sh (確保 worktree 就緒)
      │
      ├── [Worker 0] orchestrator.sh ──┐
      ├── [Worker 1] orchestrator.sh ──┤
      ├── [Worker 2] orchestrator.sh ──┤ 平行
      └── [Worker 3] orchestrator.sh ──┘
            │
            ▼
      task_picker.py next-batch
            │
            ▼ (取得 task_id)
      task_picker.py mark-running
            │
            ▼
      run-task.sh <task_id>
            │
            ├── memory.py read ──────→ 歷史上下文
            │
            ├── claude -p ───────────→ 程式碼變更
            │
            ├── memory.py write ─────→ 儲存輸出
            │
            └── verify-task.sh ──────→ 執行測試
                  │
                  ├── 通過 → task_picker.py mark-pass
                  │
                  └── 失敗 → task_picker.py record-failure
                              │
                              ▼
                        healer.py ──→ 修復策略
                              │
                              ├── retry → 重新排入佇列
                              ├── retry_with_context → 帶上下文重試
                              ├── retry_after_cooldown → 等待後重試
                              └── escalate → 標記為 escalated
      │
      ▼
merge-results.py (合併所有通過的分支)
      │
      ▼
notify.sh (發送結果通知)
```

### 3.2 SQLite 存取模式

```
寫入者 (需要 WAL 模式的原因):
  ┌─────────────────┐
  │  Worker 0       │──┐
  │  (orchestrator) │  │
  └─────────────────┘  │
  ┌─────────────────┐  │    ┌──────────────┐
  │  Worker 1       │──┼──→ │  db/agent.db │
  │  (orchestrator) │  │    │  (WAL mode)  │
  └─────────────────┘  │    └──────────────┘
  ┌─────────────────┐  │
  │  Worker N       │──┘
  │  (orchestrator) │
  └─────────────────┘

讀取者:
  agent-ctl (唯讀查詢)
  watchdog.py (讀取 + 條件寫入)
```

**交易隔離策略**:
- 所有寫入操作使用 `BEGIN IMMEDIATE` 防止寫入衝突
- `mark-running` 使用 CAS（Compare-And-Swap）模式:
  ```sql
  UPDATE tasks SET status='running', assigned_worker=?
  WHERE id=? AND status IN ('pending', 'fail');
  -- 檢查 changes() == 1 確認成功
  ```
- `next-batch` 為純讀操作，結果可能過時（由 mark-running 的 CAS 保護）

### 3.3 檔案系統佈局

```
agent-harness/
├── bin/
│   └── agent-ctl              # 控制面板 CLI (Python)
├── db/
│   └── agent.db               # SQLite 資料庫 (WAL mode)
├── docs/
│   └── architecture.md        # 本文件
├── logs/
│   ├── orchestrator.log       # 主迴圈日誌
│   ├── worker-0.log           # 各 Worker 日誌
│   ├── worker-1.log
│   └── ...
├── scripts/
│   ├── orchestrator.sh        # 單輪主迴圈
│   ├── parallel-orchestrator.sh  # 平行調度
│   ├── run-task.sh            # 任務執行
│   ├── verify-task.sh         # 任務驗證
│   ├── setup-worktrees.sh     # Worktree 初始化
│   └── notify.sh              # macOS 通知
├── src/
│   ├── task_picker.py         # DAG 管理
│   ├── healer.py              # 自我修復
│   ├── watchdog.py            # 健康監控
│   ├── memory.py              # 跨 Session 記憶
│   └── merge-results.py       # 分支合併
├── tasks/
│   └── {project}/             # 任務定義 JSON 檔案
│       ├── task-001.json
│       └── task-002.json
├── .worktrees/                # Git Worktrees (gitignored)
│   ├── worker-0/
│   ├── worker-1/
│   └── ...
├── schema.sql                 # 資料庫 Schema
└── .gitignore
```

---

## 4. 錯誤處理慣例

### 4.1 Exit Code 標準

| Exit Code | 意義 | 使用場景 |
|-----------|------|----------|
| 0 | 成功 | 所有正常完成的操作 |
| 1 | 業務錯誤 | 任務不存在、驗證失敗、前置條件不滿足 |
| 2 | 使用方式錯誤 | 參數不足、無效的子命令 |

### 4.2 輸出慣例

| 串流 | 用途 | 格式 |
|------|------|------|
| stdout | 機器可讀的結果 | JSON（Python 模組）或純文字（Shell 腳本） |
| stderr | 人類可讀的日誌 | `[TIMESTAMP] [LEVEL] message` |

### 4.3 日誌等級

```
ERROR — 需要人工介入的錯誤
WARN  — 自動修復的問題或潛在風險
INFO  — 正常操作記錄
DEBUG — 詳細除錯資訊（需 --verbose）
```

### 4.4 錯誤傳播鏈

```
claude -p 失敗
    → run-task.sh 擷取輸出 → exit 1
        → orchestrator.sh 呼叫 healer.py
            → healer.py 分類 + 策略 → JSON
                → orchestrator.sh 根據策略:
                    ├── retry → 放回佇列，下一輪重試
                    ├── retry_with_context → 將 extra_prompt 寫入暫存檔
                    ├── retry_after_cooldown → sleep N 秒後放回佇列
                    └── escalate → 標記 escalated + notify.sh
```

### 4.5 SQLite 錯誤處理

```python
# 所有 DB 操作的標準模式
def _db_execute(sql: str, params: tuple = ()) -> sqlite3.Cursor:
    """
    統一的資料庫存取包裝器。

    - 使用 PRAGMA busy_timeout=5000 避免鎖等待逾時
    - 寫入操作使用 BEGIN IMMEDIATE
    - 捕捉 sqlite3.OperationalError 並重試最多 3 次
    - 所有錯誤記錄至 stderr
    """
```

---

## 5. 設計缺口與安全疑慮

### 5.1 安全疑慮

#### 高風險

1. **verify_cmd 指令注入**
   - `verify_cmd` 由任務 JSON 定義，直接在 shell 中執行
   - 風險: 惡意的 verify_cmd 可以執行任意系統指令
   - 緩解措施: 限制 verify_cmd 為白名單指令（如 `pytest`, `npm test`, `go test`, `make`, `git diff --check`）
   - 或: 在沙箱中執行（如 Docker 容器），但會增加複雜度

2. **Claude 輸出的間接 Prompt Injection**
   - Claude 的輸出如果包含 shell 指令，可能在後續步驟中被執行
   - 緩解措施: Claude 輸出僅作為記錄儲存（memory.py write），不直接執行
   - 注意: run-task.sh 中，Claude 是在 worktree 中操作檔案，本身就有寫入權限

3. **任務 JSON 注入**
   - `goal` 欄位的內容直接成為 Claude 的 prompt
   - 若來源不受信任，可能包含惡意指令
   - 緩解措施: 任務 JSON 應僅從受信任的來源匯入

#### 中風險

4. **SQLite 參數化查詢**
   - 所有 SQL 查詢必須使用參數化查詢（`?` 占位符），絕不使用字串拼接
   - 實作中務必確保 `depends_on` 和 `touches` 的 JSON 解析結果用於 Python 邏輯判斷，而非直接嵌入 SQL

5. **檔案路徑遍歷**
   - `touches` 欄位中的路徑可能包含 `../` 等遍歷字元
   - 緩解措施: 在 `import_tasks()` 中驗證所有路徑為相對路徑且不含 `..`

6. **PID 檔案競爭條件**
   - `.worker.pid.{N}` 可能指向已結束的程序，新程序可能重用該 PID
   - 緩解措施: `agent-ctl kill` 前先驗證 PID 對應的程序確實是 orchestrator

### 5.2 設計缺口

#### 需要補充的機制

1. **任務優先順序**
   - 目前 `next-batch` 僅按 `attempt_count` 和 `created_at` 排序
   - 建議: 在 tasks 表新增 `priority INTEGER DEFAULT 0` 欄位
   - 或: 在任務 JSON 中加入 `priority` 欄位

2. **Worktree 清理機制**
   - 任務完成後 worktree 中的分支會累積
   - 建議: 在 `merge-results.py` 成功合併後，刪除對應的 worktree 分支
   - 或: 新增 `cleanup-worktrees.sh` 定期清理

3. **速率限制協調**
   - 多個 worker 同時呼叫 `claude -p` 可能觸發 API 速率限制
   - 目前僅在 healer.py 中被動處理（retry_after_cooldown）
   - 建議: 在 `parallel-orchestrator.sh` 中加入全域令牌桶（token bucket），
     用 `control` 表的 `last_api_call` 欄位實現簡易限流

4. **優雅關機傳播**
   - `agent-ctl stop` 設定 `global_state='stopping'`，但各 worker 需要主動輪詢
   - 建議: 除了 DB 旗標外，也發送 SIGTERM 訊號給 worker 程序

5. **合併失敗回滾**
   - `merge-results.py` 在合併多個分支時，若中間某個失敗，前面的合併不會回滾
   - 建議: 在合併前建立 `git tag pre-merge-{timestamp}`，失敗時可手動回滾

6. **任務依賴圖循環偵測**
   - `import_tasks()` 未檢查 `depends_on` 是否形成循環
   - 建議: 在匯入時執行拓撲排序驗證，拒絕含循環的任務定義

7. **DB 備份策略**
   - WAL 模式下的備份需要特殊處理（需要 checkpoint 後再複製）
   - 建議: 定期執行 `PRAGMA wal_checkpoint(TRUNCATE)` 並備份 .db 檔案

8. **Worker 身份驗證**
   - 目前 worker_id 僅為整數編號，無驗證機制
   - 若多個 parallel-orchestrator 實例同時執行，可能導致 worker_id 衝突
   - 建議: 使用 UUID 或 hostname + PID 作為 worker_id

---

## 附錄 A: 任務狀態機

```
                  import
                    │
                    ▼
              ┌──────────┐
              │ pending  │◄───────────────────────────┐
              └────┬─────┘                            │
                   │ mark-running                     │ retry (agent-ctl)
                   ▼                                  │
              ┌──────────┐                            │
              │ running  │                            │
              └──┬────┬──┘                            │
       通過      │    │ 失敗                           │
                 │    │                               │
       ┌─────┘    └──────┐                          │
       ▼                  ▼                          │
  ┌─────────┐       ┌──────────┐                     │
  │  pass   │       │  fail    │─────────────────────┘
  └─────────┘       └────┬─────┘
                         │ attempt_count >= max_attempts
                         ▼
                   ┌────────────┐
                   │ escalated  │
                   └────────────┘

                   ┌────────────┐
                   │  skipped   │ ← agent-ctl skip
                   └────────────┘
```

## 附錄 B: 任務 JSON 範例

```json
{
  "id": "auth-login-api",
  "project": "my-web-app",
  "goal": "實作 POST /api/auth/login endpoint。接受 {email, password} JSON body，驗證密碼後回傳 JWT token。使用 bcrypt 比對密碼，JWT 有效期 24 小時。",
  "touches": ["src/routes/auth.ts", "src/middleware/jwt.ts"],
  "verify": "npm test -- --grep 'auth/login'",
  "depends_on": ["setup-user-model"],
  "max_attempts": 5
}
```

## 附錄 C: DB 存取共用模組

建議所有 Python 模組共用一個 DB 存取層，避免重複程式碼:

**位置**: `src/db.py`

```python
"""
db.py — SQLite 存取共用模組

所有 Python 模組透過此模組存取資料庫，確保一致的:
  - WAL 模式設定
  - busy_timeout 設定
  - 交易管理
  - 錯誤處理
"""

import sqlite3
from pathlib import Path
from contextlib import contextmanager

DB_PATH = Path(__file__).parent.parent / "db" / "agent.db"

@contextmanager
def connect(readonly: bool = False):
    """
    取得資料庫連線。

    參數:
        readonly: 若為 True，以唯讀模式開啟

    用法:
        with connect() as conn:
            conn.execute("INSERT ...")
    """
    uri = f"file:{DB_PATH}"
    if readonly:
        uri += "?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        yield conn
        if not readonly:
            conn.commit()
    except Exception:
        if not readonly:
            conn.rollback()
        raise
    finally:
        conn.close()

def init_db() -> None:
    """
    初始化資料庫（執行 schema.sql）。
    冪等操作：使用 CREATE IF NOT EXISTS。
    """
```

---

*文件版本: 1.0 | 建立日期: 2026-04-01 | Agent Harness 架構設計*
