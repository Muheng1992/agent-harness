#!/usr/bin/env python3
"""router.py — Router 核心引擎，自主開發系統的大腦。

收集專案狀態 → 呼叫 Claude 決策 → 驗證 JSON → 寫入任務到 DB。
"""

import argparse
import json
import os
import random
import re
import sqlite3
import string
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

DB_PATH = os.environ.get(
    "AGENT_DB_PATH",
    str(SCRIPT_DIR / "db" / "agent.db"),
)

VALID_ACTIONS = {"FIX", "BUILD", "REFACTOR", "EXPLORE", "IDLE", "ESCALATE"}
DEFAULT_TECH_DEBT_THRESHOLD = 60

# ---------------------------------------------------------------------------
# 設定檔載入
# ---------------------------------------------------------------------------

DEFAULT_CONFIG = {
    "max_consecutive_fixes": 5,
    "max_tasks_per_day": 50,
    "tech_debt_threshold": DEFAULT_TECH_DEBT_THRESHOLD,
    "checkpoint_interval": 5,
    "cooldown_after_fix": 10,
    "cooldown_after_build": 5,
    "cooldown_after_idle": 60,
    "notify_on_escalate": True,
    "notify_on_milestone": True,
}


def load_config(config_path: str = None, project_dir: str = None) -> dict:
    """載入 router 設定。搜尋順序：
    CLI 參數 > project_dir/.harness/router-config.yaml > harness_dir/router-config.yaml > 預設值
    """
    config = dict(DEFAULT_CONFIG)

    # 候選設定檔路徑（後面的優先）
    candidates = [
        SCRIPT_DIR / "router-config.yaml",
    ]
    if project_dir:
        candidates.append(Path(project_dir) / ".harness" / "router-config.yaml")
    if config_path:
        candidates.append(Path(config_path))

    for path in candidates:
        if path.exists():
            try:
                import yaml
                with open(path, encoding="utf-8") as f:
                    file_config = yaml.safe_load(f) or {}
            except ImportError:
                # yaml 不可用，嘗試 JSON fallback
                try:
                    with open(path, encoding="utf-8") as f:
                        file_config = json.load(f)
                except (json.JSONDecodeError, ValueError):
                    continue
            config.update(file_config)

    # 環境變數覆蓋（向下相容）
    if os.environ.get("ROUTER_MAX_FIXES"):
        config["max_consecutive_fixes"] = int(os.environ["ROUTER_MAX_FIXES"])

    return config


# 全域設定（啟動時載入，可由 main() 重新載入）
_config = load_config()
MAX_CONSECUTIVE_FIXES = _config["max_consecutive_fixes"]
MAX_TASKS_PER_DAY = _config["max_tasks_per_day"]


# ---------------------------------------------------------------------------
# DB 連線
# ---------------------------------------------------------------------------

def get_connection(db_path: str = None) -> sqlite3.Connection:
    """取得 SQLite 連線，WAL 模式 + foreign keys。"""
    conn = sqlite3.connect(db_path or DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def ensure_router_table(db_path: str = None):
    """建立 router_decisions 表（如果不存在）。"""
    conn = get_connection(db_path)
    try:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS router_decisions (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                action        TEXT NOT NULL,
                reason        TEXT,
                feature_id    TEXT,
                task_ids      TEXT DEFAULT '[]',
                state_snapshot TEXT,
                created_at    DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)
        conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_router_decisions_created
            ON router_decisions(created_at)
        """)
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 狀態收集
# ---------------------------------------------------------------------------

def collect_state(project_dir: str, test_cmd: str = None,
                  db_path: str = None) -> str:
    """呼叫 state-collector.sh，回傳 Markdown 狀態報告。"""
    cmd = ["bash", str(SCRIPT_DIR / "state-collector.sh"), project_dir]
    if test_cmd:
        cmd += ["--test-cmd", test_cmd]
    if db_path:
        cmd += ["--db-path", db_path]

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0:
            return f"# State Collection Error\n\n```\n{result.stderr[:2000]}\n```"
        return result.stdout
    except subprocess.TimeoutExpired:
        return "# State Collection Error\n\nTimeout（超過 120 秒）"
    except Exception as e:
        return f"# State Collection Error\n\n{e}"


def get_tech_debt_score(project_dir: str) -> int:
    """呼叫 tech-debt.py --score-only，回傳分數（0-100）。"""
    try:
        result = subprocess.run(
            ["python3", str(SCRIPT_DIR / "tech-debt.py"), project_dir,
             "--score-only"],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode == 0:
            return int(result.stdout.strip())
    except (subprocess.TimeoutExpired, ValueError, Exception):
        pass
    return 0


def get_roadmap_status(project_dir: str) -> dict:
    """匯入 roadmap.py 模組，回傳 roadmap 狀態。無 roadmap 時回傳 None。"""
    try:
        # 動態 import — 避免啟動時依賴 yaml
        sys.path.insert(0, str(SCRIPT_DIR))
        import roadmap as rm

        roadmap_path = rm.find_roadmap(project_dir=project_dir)
        if roadmap_path is None:
            return None
        data = rm.load_roadmap(roadmap_path)
        status = rm.get_status(data)
        status["_path"] = roadmap_path
        return status
    except Exception:
        return None


# ---------------------------------------------------------------------------
# DB 查詢
# ---------------------------------------------------------------------------

def count_consecutive_fixes(db_path: str = None) -> int:
    """計算最近連續 FIX 動作的次數。"""
    conn = get_connection(db_path)
    try:
        rows = conn.execute(
            "SELECT action FROM router_decisions ORDER BY created_at DESC"
        ).fetchall()
        count = 0
        for row in rows:
            if row["action"] == "FIX":
                count += 1
            else:
                break
        return count
    except sqlite3.OperationalError:
        # 表可能尚未存在
        return 0
    finally:
        conn.close()


def count_tasks_today(db_path: str = None) -> int:
    """計算今天建立的任務數。"""
    conn = get_connection(db_path)
    try:
        row = conn.execute(
            "SELECT COUNT(*) FROM tasks WHERE created_at >= date('now')"
        ).fetchone()
        return row[0] if row else 0
    except sqlite3.OperationalError:
        return 0
    finally:
        conn.close()


def check_regression(db_path: str = None) -> dict | None:
    """偵測回歸：最近的 FIX 任務是否重複修相同問題。"""
    conn = get_connection(db_path)
    try:
        rows = conn.execute(
            """SELECT goal FROM tasks
               WHERE role='debugger' AND status='pass'
               ORDER BY updated_at DESC LIMIT 10"""
        ).fetchall()
        if len(rows) < 2:
            return None
        goals = [r[0].lower() for r in rows]
        # 簡單重複偵測：如果最近 5 筆 FIX 中有 goal 關鍵字高度重疊
        from collections import Counter
        words = Counter()
        for g in goals[:5]:
            for w in g.split():
                if len(w) > 3:  # 過濾太短的詞
                    words[w] += 1
        # 某個關鍵字出現 >= 3 次 → 可能在反覆修同一個問題
        repeated = [w for w, c in words.items() if c >= 3]
        if repeated:
            return {
                "action": "ESCALATE",
                "reason": f"偵測到可能的回歸：最近 FIX 任務反覆出現關鍵字 {repeated[:3]}",
                "tasks": [],
            }
        return None
    except sqlite3.OperationalError:
        return None
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 安全閥
# ---------------------------------------------------------------------------

def check_fix_loop(db_path: str = None, config: dict = None) -> dict | None:
    """連續 FIX 上限檢查。"""
    max_fixes = (config or _config).get("max_consecutive_fixes", MAX_CONSECUTIVE_FIXES)
    consecutive = count_consecutive_fixes(db_path)
    if consecutive >= max_fixes:
        return {
            "action": "ESCALATE",
            "reason": f"已連續 {consecutive} 輪 FIX，可能陷入修復迴圈",
            "tasks": [],
        }
    return None


def check_daily_limit(db_path: str = None, config: dict = None) -> dict | None:
    """每日任務數上限檢查。"""
    max_tasks = (config or _config).get("max_tasks_per_day", MAX_TASKS_PER_DAY)
    today_count = count_tasks_today(db_path)
    if today_count >= max_tasks:
        return {
            "action": "IDLE",
            "reason": f"已達每日上限 {max_tasks} 個任務（今日已建立 {today_count} 個）",
            "tasks": [],
        }
    return None


def run_safety_checks(db_path: str = None, config: dict = None) -> dict | None:
    """依序執行所有安全閥檢查。回傳第一個觸發的結果，或 None。"""
    for check_fn in (check_fix_loop, check_daily_limit):
        result = check_fn(db_path, config)
        if result:
            return result

    # 回歸偵測（獨立邏輯，不需要 config）
    result = check_regression(db_path)
    if result:
        return result

    return None


def send_notification(message: str):
    """透過 notify.sh 發送通知。"""
    notify_script = SCRIPT_DIR / "notify.sh"
    if notify_script.exists():
        try:
            subprocess.run(
                ["bash", str(notify_script), message],
                timeout=10, capture_output=True,
            )
        except (subprocess.TimeoutExpired, Exception):
            pass


# ---------------------------------------------------------------------------
# JSON 解析 / 驗證
# ---------------------------------------------------------------------------

def extract_json(text: str) -> dict:
    """從文字中提取 JSON 物件。容錯處理 Claude 有時在 JSON 前後加的文字。"""
    text = text.strip()

    # 嘗試直接 parse
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # 找 ```json ... ``` 區塊
    m = re.search(r"```(?:json)?\s*\n?(.*?)\n?\s*```", text, re.DOTALL)
    if m:
        try:
            return json.loads(m.group(1).strip())
        except json.JSONDecodeError:
            pass

    # 找第一個 { ... } 區塊（貪婪匹配最外層）
    m = re.search(r"\{.*\}", text, re.DOTALL)
    if m:
        try:
            return json.loads(m.group(0))
        except json.JSONDecodeError:
            pass

    raise ValueError(f"無法從回應中提取 JSON：{text[:500]}")


def validate_decision(decision: dict):
    """驗證決策 JSON schema。不通過時 raise ValueError。"""
    action = decision.get("action")
    if action not in VALID_ACTIONS:
        raise ValueError(
            f"action 不合法：{action}（合法值：{VALID_ACTIONS}）"
        )

    if action in ("IDLE", "ESCALATE"):
        return

    tasks = decision.get("tasks", [])
    if not tasks:
        raise ValueError(f"action={action} 時 tasks 不能為空")

    for i, task in enumerate(tasks):
        if not task.get("goal"):
            raise ValueError(f"tasks[{i}] 缺少 goal")
        if action != "EXPLORE" and not task.get("verify"):
            raise ValueError(f"tasks[{i}] 缺少 verify（action={action}）")

    if action == "BUILD" and not decision.get("feature_id"):
        raise ValueError("action=BUILD 時必須提供 feature_id")


# ---------------------------------------------------------------------------
# 核心決策
# ---------------------------------------------------------------------------

def decide(state_report: str, project_name: str, project_dir: str,
           test_cmd: str, consecutive_fixes: int, tech_debt_score: int,
           tech_debt_threshold: int = DEFAULT_TECH_DEBT_THRESHOLD) -> dict:
    """組合 prompt，呼叫 Claude CLI，解析 JSON 回應。"""
    # 1. 讀取 prompt 模板
    system_path = SCRIPT_DIR / "prompts" / "router-system.md"
    user_path = SCRIPT_DIR / "prompts" / "router-user.md"

    system_prompt = system_path.read_text(encoding="utf-8")
    user_template = user_path.read_text(encoding="utf-8")

    # 填充安全規則中的 max_consecutive_fixes
    system_prompt = system_prompt.replace(
        "{max_consecutive_fixes}", str(MAX_CONSECUTIVE_FIXES)
    )

    # 2. 填充 user prompt 變數
    user_prompt = user_template.format(
        state_report=state_report,
        project_name=project_name,
        project_dir=project_dir,
        test_cmd=test_cmd or "(auto-detect)",
        consecutive_fixes=consecutive_fixes,
        tech_debt_score=tech_debt_score,
        tech_debt_threshold=tech_debt_threshold,
    )

    # 3. 呼叫 Claude CLI
    try:
        result = subprocess.run(
            [
                "claude", "-p", user_prompt,
                "--system-prompt", system_prompt,
                "--output-format", "json",
                "--dangerously-skip-permissions",
                "--allowedTools", "none",
            ],
            capture_output=True, text=True, timeout=120,
        )
    except subprocess.TimeoutExpired:
        print("警告：Claude CLI 呼叫逾時，fallback 到 IDLE", file=sys.stderr)
        return {"action": "IDLE", "reason": "Router Claude 呼叫逾時", "tasks": []}
    except FileNotFoundError:
        print("錯誤：找不到 claude CLI 指令", file=sys.stderr)
        return {"action": "IDLE", "reason": "claude CLI 不可用", "tasks": []}

    if result.returncode != 0:
        print(f"警告：Claude CLI 回傳非零退出碼 {result.returncode}",
              file=sys.stderr)
        print(f"stderr: {result.stderr[:500]}", file=sys.stderr)
        return {"action": "IDLE", "reason": f"Claude CLI 錯誤：{result.stderr[:200]}", "tasks": []}

    # 4. 解析 JSON（Claude --output-format json 回傳 {"type":"result","result":"..."}）
    try:
        claude_output = json.loads(result.stdout)
        decision_text = claude_output.get("result", result.stdout)
    except json.JSONDecodeError:
        decision_text = result.stdout

    # 5. 提取 JSON 物件
    try:
        decision = extract_json(decision_text)
    except ValueError as e:
        print(f"警告：JSON 解析失敗 — {e}", file=sys.stderr)
        return {"action": "IDLE", "reason": f"JSON 解析失敗：{e}", "tasks": []}

    # 6. 驗證 schema
    try:
        validate_decision(decision)
    except ValueError as e:
        print(f"警告：決策驗證失敗 — {e}", file=sys.stderr)
        return {"action": "IDLE", "reason": f"決策驗證失敗：{e}", "tasks": []}

    return decision


# ---------------------------------------------------------------------------
# 執行決策
# ---------------------------------------------------------------------------

def _random_suffix(length: int = 4) -> str:
    return "".join(random.choices(string.ascii_lowercase + string.digits, k=length))


def execute_decision(decision: dict, project: str, project_dir: str,
                     db_path: str = None, test_cmd: str = None) -> list:
    """將決策轉換為實際任務並寫入 DB。回傳 task_id 列表。"""
    action = decision.get("action", "IDLE")

    if action == "IDLE":
        return []

    if action == "ESCALATE":
        reason = decision.get("reason", "需要人類介入")
        print(f"🚨 ESCALATE: {reason}", file=sys.stderr)
        return []

    tasks = decision.get("tasks", [])
    if not tasks:
        return []

    conn = get_connection(db_path)
    task_ids = []
    now = datetime.utcnow().isoformat()

    try:
        for task_spec in tasks:
            task_id = task_spec.get(
                "id", f"router-{int(time.time())}-{_random_suffix()}"
            )
            role = task_spec.get("role", "implementer")
            goal = task_spec["goal"]
            verify_cmd = task_spec.get("verify", test_cmd or "")
            depends_on = json.dumps(task_spec.get("depends_on", []))
            touches = json.dumps(task_spec.get("touches", []))

            try:
                conn.execute(
                    """INSERT OR REPLACE INTO tasks
                       (id, project, project_dir, goal, verify_cmd, depends_on,
                        touches, status, attempt_count, max_attempts, role,
                        created_at, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, 5, ?, ?, ?)""",
                    (task_id, project, project_dir, goal, verify_cmd,
                     depends_on, touches, role, now, now),
                )
            except sqlite3.OperationalError:
                # 舊 schema 不含 role 欄位
                conn.execute(
                    """INSERT OR REPLACE INTO tasks
                       (id, project, project_dir, goal, verify_cmd, depends_on,
                        touches, status, attempt_count, max_attempts,
                        created_at, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, 5, ?, ?)""",
                    (task_id, project, project_dir, goal, verify_cmd,
                     depends_on, touches, now, now),
                )
            task_ids.append(task_id)

        conn.commit()
    finally:
        conn.close()

    return task_ids


def record_decision(db_path: str, action: str, reason: str,
                    task_ids: list, feature_id: str = None,
                    state_snapshot: str = None):
    """記錄 Router 決策到 router_decisions 表。"""
    conn = get_connection(db_path)
    try:
        conn.execute(
            """INSERT INTO router_decisions
               (action, reason, feature_id, task_ids, state_snapshot)
               VALUES (?, ?, ?, ?, ?)""",
            (action, reason, feature_id,
             json.dumps(task_ids), state_snapshot),
        )
        conn.commit()
    finally:
        conn.close()


def update_roadmap_if_needed(decision: dict, project_dir: str):
    """如果決策完成了某個 feature，更新 roadmap。"""
    # 這裡只在有 feature_id 且 action=BUILD 時觸發
    # 實際 mark-done 在 task 通過後由 orchestrator 處理
    # router 本身不標記 done，但可用於未來擴充
    pass


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_decide(args):
    """執行一次 Router 決策。"""
    db = args.db_path or DB_PATH
    ensure_router_table(db)

    project = args.project
    project_dir = os.path.abspath(args.dir)
    test_cmd = args.test_cmd

    # 載入設定（CLI 參數 > 專案設定 > harness 設定 > 預設值）
    config = load_config(
        config_path=getattr(args, "config", None),
        project_dir=project_dir,
    )

    # 安全閥檢查（優先於 Claude 決策）
    safety = run_safety_checks(db, config)
    if safety:
        action = safety.get("action", "IDLE")
        reason = safety.get("reason", "")
        print(f"安全閥觸發：{reason}", file=sys.stderr)
        if config.get("notify_on_escalate") and action == "ESCALATE":
            send_notification(f"ESCALATE: {reason}")
        print(json.dumps(safety, ensure_ascii=False, indent=2))
        if not args.dry_run:
            record_decision(
                db_path=db, action=action, reason=reason,
                task_ids=[], state_snapshot="safety_valve",
            )
        return

    # 收集狀態
    print("收集專案狀態...", file=sys.stderr)
    state_report = collect_state(project_dir, test_cmd, db)

    # 額外指標
    consecutive_fixes = count_consecutive_fixes(db)
    tech_debt_score = get_tech_debt_score(project_dir)
    tech_debt_threshold = config.get("tech_debt_threshold", args.tech_debt_threshold)

    # 決策
    print("呼叫 Claude 決策...", file=sys.stderr)
    decision = decide(
        state_report=state_report,
        project_name=project,
        project_dir=project_dir,
        test_cmd=test_cmd or "",
        consecutive_fixes=consecutive_fixes,
        tech_debt_score=tech_debt_score,
        tech_debt_threshold=tech_debt_threshold,
    )

    # 輸出決策
    print(json.dumps(decision, ensure_ascii=False, indent=2))

    if args.dry_run:
        print("\n(dry-run 模式，不寫入 DB)", file=sys.stderr)
        return

    # 執行決策：寫入任務到 DB
    task_ids = execute_decision(decision, project, project_dir, db, test_cmd)

    # 記錄決策
    state_summary = (
        f"tech_debt={tech_debt_score}, "
        f"consecutive_fixes={consecutive_fixes}"
    )
    record_decision(
        db_path=db,
        action=decision.get("action", "IDLE"),
        reason=decision.get("reason", ""),
        task_ids=task_ids,
        feature_id=decision.get("feature_id"),
        state_snapshot=state_summary,
    )

    # 通知機制
    action = decision.get("action", "IDLE")
    if config.get("notify_on_escalate") and action == "ESCALATE":
        send_notification(f"ESCALATE: {decision.get('reason', '未知')}")
    if consecutive_fixes >= 3 and action == "FIX":
        send_notification(f"警告：已連續 {consecutive_fixes + 1} 次 FIX")

    if task_ids:
        print(f"\n已建立 {len(task_ids)} 個任務：{task_ids}", file=sys.stderr)


def cmd_history(args):
    """查看 Router 決策歷史。"""
    db = args.db_path or DB_PATH
    ensure_router_table(db)

    conn = get_connection(db)
    try:
        rows = conn.execute(
            "SELECT * FROM router_decisions ORDER BY created_at DESC LIMIT ?",
            (args.limit,),
        ).fetchall()
        results = [dict(r) for r in rows]
        print(json.dumps(results, ensure_ascii=False, indent=2, default=str))
    finally:
        conn.close()


def cmd_fix_count(args):
    """查看連續 FIX 次數。"""
    db = args.db_path or DB_PATH
    ensure_router_table(db)

    count = count_consecutive_fixes(db)
    print(count)


def main():
    parser = argparse.ArgumentParser(
        description="Router 核心引擎 — 自主開發系統的大腦"
    )
    parser.add_argument("--db-path", default=None, help="資料庫路徑")
    sub = parser.add_subparsers(dest="command", required=True)

    # decide
    dec = sub.add_parser("decide", help="執行一次 Router 決策")
    dec.add_argument("--project", required=True, help="專案名稱")
    dec.add_argument("--dir", required=True, help="專案目錄路徑")
    dec.add_argument("--test-cmd", default=None, help="測試指令")
    dec.add_argument("--dry-run", action="store_true",
                     help="只印決策，不寫入 DB")
    dec.add_argument("--tech-debt-threshold", type=int,
                     default=DEFAULT_TECH_DEBT_THRESHOLD,
                     help="技術債閾值（預設 60）")
    dec.add_argument("--config", default=None,
                     help="設定檔路徑（覆蓋自動搜尋）")

    # history
    hist = sub.add_parser("history", help="查看 Router 決策歷史")
    hist.add_argument("--limit", type=int, default=20, help="顯示筆數")

    # fix-count
    sub.add_parser("fix-count", help="查看連續 FIX 次數")

    args = parser.parse_args()

    if args.command == "decide":
        cmd_decide(args)
    elif args.command == "history":
        cmd_history(args)
    elif args.command == "fix-count":
        cmd_fix_count(args)


if __name__ == "__main__":
    main()
