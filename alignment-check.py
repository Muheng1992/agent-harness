#!/usr/bin/env python3
"""alignment-check.py — 對齊檢查：偵測專案漂移並自動修正。

定期檢查已完成任務數量，自動注入 alignment-check 任務，
並在 alignment-check 完成後套用修正（修改 goal、新增任務、通知）。
"""

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime
from pathlib import Path

DB_PATH = os.environ.get(
    "AGENT_DB_PATH",
    str(Path(__file__).resolve().parent / "db" / "agent.db"),
)

SCRIPT_DIR = Path(__file__).resolve().parent


def get_connection() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def should_run() -> bool:
    """檢查是否需要執行對齊檢查。

    計算上次 alignment-check 以來通過的任務數，
    若 >= alignment_interval 則回傳 True。
    """
    conn = get_connection()
    try:
        # 讀取 interval 設定
        row = conn.execute(
            "SELECT value FROM control WHERE key='alignment_interval'"
        ).fetchone()
        interval = int(row["value"]) if row else 5

        # 找上次 alignment-check 的時間
        last_check = conn.execute(
            """SELECT MAX(created_at) as last_at FROM tasks
               WHERE role='alignment-checker'"""
        ).fetchone()

        if last_check and last_check["last_at"]:
            count = conn.execute(
                """SELECT COUNT(*) as cnt FROM tasks
                   WHERE status='pass' AND updated_at > ?
                     AND role != 'alignment-checker'""",
                (last_check["last_at"],),
            ).fetchone()["cnt"]
        else:
            count = conn.execute(
                """SELECT COUNT(*) as cnt FROM tasks
                   WHERE status='pass' AND role != 'alignment-checker'"""
            ).fetchone()["cnt"]

        return count >= interval
    finally:
        conn.close()


def inject_check(project: str = None) -> str:
    """注入一個 alignment-check 任務到 DB。

    回傳建立的任務 ID，或空字串（若已存在近期的 check）。
    """
    conn = get_connection()
    try:
        now = datetime.utcnow()
        task_id = f"alignment-check-{now.strftime('%Y%m%d-%H%M%S')}"

        # 防重複：1 分鐘內不重複注入
        recent = conn.execute(
            """SELECT id FROM tasks
               WHERE role='alignment-checker'
                 AND created_at > datetime('now', '-1 minutes')"""
        ).fetchone()
        if recent:
            return ""

        # 取得 project_dir（從最近一個有 project_dir 的任務）
        project_dir = None
        if project:
            row = conn.execute(
                """SELECT project_dir FROM tasks
                   WHERE project = ? AND project_dir IS NOT NULL
                   LIMIT 1""",
                (project,),
            ).fetchone()
            if row:
                project_dir = row["project_dir"]
        else:
            row = conn.execute(
                """SELECT project, project_dir FROM tasks
                   WHERE project_dir IS NOT NULL
                   ORDER BY updated_at DESC LIMIT 1"""
            ).fetchone()
            if row:
                project = row["project"]
                project_dir = row["project_dir"]

        if not project:
            project = "default"

        # 組裝 goal
        brief_path = ""
        if project_dir:
            brief_path = f"{project_dir}/.harness/project-brief.md"

        goal = f"""對齊檢查：比對專案 '{project}' 目前狀態與原始規格。

## 步驟

1. 讀取 project brief{f'（`{brief_path}`）' if brief_path else ''}
2. 用 Glob 和 Grep 掃描主要目錄結構和核心檔案
3. 檢查已完成的任務是否偏離架構決策
4. 比對尚未執行的 pending 任務 goal 是否仍然合理
5. 輸出結構化判定 JSON

## 注意
- 不要修改任何檔案
- corrections 最多 3 個
- 如果一切正常，回報 ON_TRACK"""

        conn.execute(
            """INSERT OR IGNORE INTO tasks
               (id, project, project_dir, goal, verify_cmd, depends_on, touches,
                status, attempt_count, max_attempts, role, created_at, updated_at)
               VALUES (?, ?, ?, ?, NULL, '[]', '[]', 'pending', 0, 2,
                       'alignment-checker', ?, ?)""",
            (task_id, project, project_dir, goal,
             now.isoformat(), now.isoformat()),
        )
        conn.commit()
        return task_id
    finally:
        conn.close()


def apply_corrections(task_id: str) -> int:
    """從已完成的 alignment-check 任務讀取修正並套用。

    回傳套用的修正數量。
    """
    conn = get_connection()
    try:
        # 讀取最後一次 pass 的 output
        run = conn.execute(
            """SELECT claude_output FROM runs
               WHERE task_id = ? AND status = 'pass'
               ORDER BY id DESC LIMIT 1""",
            (task_id,),
        ).fetchone()

        if not run or not run["claude_output"]:
            return 0

        output = run["claude_output"]

        # 解開 Claude JSON wrapper
        try:
            wrapper = json.loads(output)
            if isinstance(wrapper, dict) and "result" in wrapper:
                output = wrapper["result"]
        except (json.JSONDecodeError, TypeError):
            pass

        # 找 alignment JSON
        alignment_data = _extract_alignment_json(output)
        if not alignment_data:
            return 0

        alignment = alignment_data.get("alignment", "ON_TRACK")
        corrections = alignment_data.get("corrections", [])
        drift_areas = alignment_data.get("drift_areas", [])

        if alignment == "ON_TRACK" or not corrections:
            print(f"[alignment] {task_id}: {alignment}，無需修正")
            return 0

        # 通知漂移
        if drift_areas:
            drift_msg = f"對齊檢查偵測到漂移: {', '.join(drift_areas[:3])}"
            subprocess.run(
                [str(SCRIPT_DIR / "notify.sh"), drift_msg, "--level", "error"],
                capture_output=True,
            )

        # 套用 corrections（最多 3 個）
        applied = 0
        task = conn.execute(
            "SELECT project, project_dir FROM tasks WHERE id = ?",
            (task_id,),
        ).fetchone()

        for correction in corrections[:3]:
            ctype = correction.get("type", "")
            now = datetime.utcnow().isoformat()

            if ctype == "modify_goal":
                target_id = correction.get("task_id", "")
                new_goal = correction.get("new_goal", "")
                if target_id and new_goal:
                    cur = conn.execute(
                        """UPDATE tasks SET goal = ?, updated_at = ?
                           WHERE id = ? AND status = 'pending'""",
                        (new_goal, now, target_id),
                    )
                    if cur.rowcount > 0:
                        print(f"[alignment] 修改任務 {target_id} 的 goal")
                        applied += 1

            elif ctype == "add_task":
                new_goal = correction.get("goal", "")
                new_role = correction.get("role", "implementer")
                depends = json.dumps(correction.get("depends_on", []))
                if new_goal:
                    new_id = f"alignment-fix-{datetime.utcnow().strftime('%H%M%S')}-{applied}"
                    conn.execute(
                        """INSERT OR IGNORE INTO tasks
                           (id, project, project_dir, goal, verify_cmd,
                            depends_on, touches, status, attempt_count,
                            max_attempts, role, spawned_by,
                            created_at, updated_at)
                           VALUES (?, ?, ?, ?, NULL, ?, '[]', 'pending',
                                   0, 3, ?, ?, ?, ?)""",
                        (new_id, task["project"], task["project_dir"],
                         new_goal, depends, new_role, task_id,
                         now, now),
                    )
                    print(f"[alignment] 新增任務 {new_id}")
                    applied += 1

            elif ctype == "flag":
                desc = correction.get("description", "未知問題")
                subprocess.run(
                    [str(SCRIPT_DIR / "notify.sh"),
                     f"對齊警告: {desc}", "--level", "escalated"],
                    capture_output=True,
                )
                print(f"[alignment] 已通知: {desc}")
                applied += 1

        conn.commit()
        return applied
    finally:
        conn.close()


def _extract_alignment_json(text: str) -> dict:
    """從 output 中提取 alignment 判定 JSON。"""
    # 找 ```json ... ``` blocks
    blocks = re.findall(r'```json\s*\n(.*?)\n```', text, re.DOTALL)
    for block in blocks:
        try:
            data = json.loads(block)
            if isinstance(data, dict) and "alignment" in data:
                return data
        except json.JSONDecodeError:
            continue

    # 直接找含 alignment 的 JSON object
    matches = re.findall(r'\{[^{}]*"alignment"\s*:[^{}]*\}', text)
    for match in matches:
        try:
            data = json.loads(match)
            if "alignment" in data:
                return data
        except json.JSONDecodeError:
            continue

    return None


def main():
    parser = argparse.ArgumentParser(
        description="對齊檢查：偵測專案漂移並自動修正"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # check
    ch = sub.add_parser("check", help="檢查是否需要執行對齊檢查")
    ch.add_argument("--auto-inject", action="store_true",
                    help="若需要，自動注入 alignment-check 任務")
    ch.add_argument("--project", type=str, default=None,
                    help="指定專案名稱")

    # inject
    inj = sub.add_parser("inject", help="手動注入 alignment-check 任務")
    inj.add_argument("--project", type=str, default=None,
                     help="專案名稱")

    # apply
    app = sub.add_parser("apply", help="套用已完成 alignment-check 的修正")
    app.add_argument("task_id", help="Alignment-check 任務 ID")

    args = parser.parse_args()

    if args.command == "check":
        needed = should_run()
        if needed:
            print("YES")
            if args.auto_inject:
                task_id = inject_check(args.project)
                if task_id:
                    print(f"已注入: {task_id}")
                else:
                    print("近期已有 alignment-check，跳過")
        else:
            print("NO")

    elif args.command == "inject":
        task_id = inject_check(args.project)
        if task_id:
            print(f"已注入: {task_id}")
        else:
            print("近期已有 alignment-check，跳過")

    elif args.command == "apply":
        count = apply_corrections(args.task_id)
        print(f"已套用 {count} 個修正")


if __name__ == "__main__":
    main()
