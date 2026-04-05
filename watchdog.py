#!/usr/bin/env python3
"""watchdog.py — Deadlock detection and auto-redispatch for the Agent Harness.

Detects stuck tasks, global stalls, long-running tasks, and can
redispatch failed tasks that still have retry budget.
"""

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta
from pathlib import Path

DB_PATH = os.environ.get(
    "AGENT_DB_PATH",
    str(Path(__file__).resolve().parent / "db" / "agent.db"),
)

LONG_RUNNING_MINUTES = 15
GLOBAL_STALL_THRESHOLD = 10


def get_connection() -> sqlite3.Connection:
    """Get SQLite connection with WAL mode and foreign keys."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def check_stuck_tasks(conn: sqlite3.Connection) -> list:
    """Find tasks where attempt_count >= max_attempts and mark as escalated.

    Returns list of issue descriptions.
    """
    issues = []
    stuck = conn.execute(
        """SELECT id, attempt_count, max_attempts FROM tasks
           WHERE attempt_count >= max_attempts
             AND status NOT IN ('pass', 'escalated', 'skipped')"""
    ).fetchall()

    for t in stuck:
        conn.execute(
            """UPDATE tasks
               SET status = 'escalated', updated_at = ?
               WHERE id = ?""",
            (datetime.utcnow().isoformat(), t["id"]),
        )
        issues.append(
            f"ESCALATED: {t['id']} — exhausted retries "
            f"({t['attempt_count']}/{t['max_attempts']})"
        )

    if stuck:
        conn.commit()

    return issues


def check_global_stall(conn: sqlite3.Connection) -> list:
    """Detect global stall: 10+ consecutive fails since last pass.

    Returns list of warnings.
    """
    issues = []
    # Get last N finished runs ordered by id descending
    recent = conn.execute(
        """SELECT status FROM runs
           WHERE status IN ('pass', 'fail', 'error')
           ORDER BY id DESC
           LIMIT ?""",
        (GLOBAL_STALL_THRESHOLD,),
    ).fetchall()

    if len(recent) >= GLOBAL_STALL_THRESHOLD:
        if all(r["status"] in ("fail", "error") for r in recent):
            issues.append(
                f"GLOBAL STALL: Last {GLOBAL_STALL_THRESHOLD} runs all failed. "
                "Consider pausing and investigating."
            )

    return issues


def check_long_runners(conn: sqlite3.Connection) -> list:
    """Warn about tasks running longer than the threshold.

    Returns list of warnings.
    """
    issues = []
    cutoff = (
        datetime.utcnow() - timedelta(minutes=LONG_RUNNING_MINUTES)
    ).isoformat()

    long_running = conn.execute(
        """SELECT id, assigned_worker, updated_at FROM tasks
           WHERE status = 'running'
             AND updated_at < ?""",
        (cutoff,),
    ).fetchall()

    for t in long_running:
        issues.append(
            f"LONG RUNNING: {t['id']} — worker {t['assigned_worker']}, "
            f"last update {t['updated_at']}"
        )

    return issues


def check_blocked_parents(conn: sqlite3.Connection) -> list:
    """檢查 blocked 狀態的父任務，看子任務是否都完成了。"""
    issues = []
    blocked = conn.execute(
        "SELECT id, verify_cmd FROM tasks WHERE status = 'blocked'"
    ).fetchall()

    for parent in blocked:
        parent_id = parent["id"]
        children = conn.execute(
            "SELECT id, status FROM tasks WHERE spawned_by = ?",
            (parent_id,),
        ).fetchall()

        # 沒有子任務（孤兒 blocked），設回 pending
        if not children:
            conn.execute(
                "UPDATE tasks SET status = 'pending', updated_at = ? WHERE id = ?",
                (datetime.utcnow().isoformat(), parent_id),
            )
            conn.commit()
            issues.append(
                f"UNBLOCKED: {parent_id} — 無子任務，設回 pending"
            )
            continue

        statuses = [c["status"] for c in children]

        if all(s == "pass" for s in statuses):
            # 全部子任務通過
            if parent["verify_cmd"]:
                # 有驗證指令，設為 pending 讓它重跑驗證
                new_status = "pending"
            else:
                new_status = "pass"
            conn.execute(
                "UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?",
                (new_status, datetime.utcnow().isoformat(), parent_id),
            )
            conn.commit()
            issues.append(
                f"UNBLOCKED: {parent_id} — 所有子任務通過，設為 {new_status}"
            )
        elif any(s == "escalated" for s in statuses):
            # 有子任務升級，父任務也升級
            conn.execute(
                "UPDATE tasks SET status = 'escalated', updated_at = ? WHERE id = ?",
                (datetime.utcnow().isoformat(), parent_id),
            )
            conn.commit()
            issues.append(
                f"ESCALATED: {parent_id} — 子任務中有 escalated"
            )
        # 其他情況（仍有 pending/running/fail/blocked）保持 blocked

    return issues


def check_looping_tasks(conn: sqlite3.Connection) -> list:
    """偵測連續產出相同結果的任務（循環卡住）。

    比較同一 task 最近 2 次 run 的 output_fingerprint。
    若相同，標記 error_class 為 looping 並減少剩餘嘗試次數以加速 escalate。
    """
    issues = []

    # 找所有 fail 狀態且 attempt >= 2 的任務
    tasks = conn.execute(
        """SELECT id, attempt_count, max_attempts, error_class FROM tasks
           WHERE status IN ('fail', 'pending')
             AND attempt_count >= 2
             AND (error_class IS NULL OR error_class != 'looping')"""
    ).fetchall()

    for task in tasks:
        try:
            runs = conn.execute(
                """SELECT output_fingerprint FROM runs
                   WHERE task_id = ? AND output_fingerprint IS NOT NULL
                   ORDER BY id DESC LIMIT 2""",
                (task["id"],),
            ).fetchall()
        except Exception:
            # output_fingerprint 欄位不存在（migration 未跑）
            break

        if len(runs) < 2:
            continue
        if runs[0]["output_fingerprint"] != runs[1]["output_fingerprint"]:
            continue

        # 偵測到迴圈：標記 + 減少嘗試上限
        now = datetime.utcnow().isoformat()
        conn.execute(
            """UPDATE tasks SET error_class = 'looping', updated_at = ?
               WHERE id = ?""",
            (now, task["id"]),
        )
        conn.execute(
            """UPDATE tasks
               SET max_attempts = MIN(max_attempts, attempt_count + 1),
                   updated_at = ?
               WHERE id = ?""",
            (now, task["id"]),
        )
        issues.append(
            f"LOOPING: {task['id']} — 連續 2 次相同輸出，"
            f"已減少剩餘嘗試 ({task['attempt_count']}/{task['max_attempts']})"
        )

        # 寫入 audit log
        try:
            conn.execute(
                """INSERT INTO audit_log (task_id, event_type, event_data, actor)
                   VALUES (?, 'looping_detected', ?, 'watchdog')""",
                (task["id"], json.dumps({
                    "fingerprint": runs[0]["output_fingerprint"],
                    "attempt_count": task["attempt_count"],
                    "max_attempts": task["max_attempts"],
                })),
            )
        except sqlite3.OperationalError:
            pass  # audit_log 表不存在

    if issues:
        conn.commit()
    return issues


def check_all_done(conn: sqlite3.Connection) -> list:
    """Check if all work is complete (no pending/running/fail/blocked tasks).

    Returns a completion message or empty list.
    """
    remaining = conn.execute(
        """SELECT COUNT(*) as cnt FROM tasks
           WHERE status IN ('pending', 'running', 'fail', 'blocked')"""
    ).fetchone()

    if remaining["cnt"] == 0:
        total = conn.execute("SELECT COUNT(*) as cnt FROM tasks").fetchone()
        if total["cnt"] > 0:
            return ["ALL DONE: No pending, running, or failed tasks remain."]
    return []


def run_check() -> list:
    """Run all watchdog checks. Returns list of issues/warnings."""
    conn = get_connection()
    try:
        issues = []
        issues.extend(check_stuck_tasks(conn))
        issues.extend(check_global_stall(conn))
        issues.extend(check_long_runners(conn))
        issues.extend(check_blocked_parents(conn))
        issues.extend(check_looping_tasks(conn))
        issues.extend(check_all_done(conn))
        return issues
    finally:
        conn.close()


def auto_redispatch() -> int:
    """Redispatch failed tasks that still have retry budget.

    Sets status back to 'pending' for tasks where
    status='fail' AND attempt_count < max_attempts.

    Returns the count of redispatched tasks.
    """
    conn = get_connection()
    try:
        now = datetime.utcnow().isoformat()
        cur = conn.execute(
            """UPDATE tasks
               SET status = 'pending',
                   assigned_worker = NULL,
                   updated_at = ?
               WHERE status = 'fail'
                 AND attempt_count < max_attempts""",
            (now,),
        )
        conn.commit()
        return cur.rowcount
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(
        description="Deadlock detection and auto-redispatch"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("check", help="Run all watchdog checks")
    sub.add_parser("auto-redispatch", help="Redispatch failed tasks with remaining budget")
    sub.add_parser("check-blocked", help="Check and unblock parent tasks whose sub-tasks completed")
    sub.add_parser("check-looping", help="Detect tasks stuck in output loops")

    args = parser.parse_args()

    if args.command == "check":
        issues = run_check()
        if issues:
            for issue in issues:
                print(issue)
        else:
            print("No issues detected.")

    elif args.command == "auto-redispatch":
        count = auto_redispatch()
        print(f"Redispatched {count} tasks")

    elif args.command == "check-blocked":
        conn = get_connection()
        try:
            issues = check_blocked_parents(conn)
            if issues:
                for issue in issues:
                    print(issue)
            else:
                print("No blocked parents to unblock.")
        finally:
            conn.close()

    elif args.command == "check-looping":
        conn = get_connection()
        try:
            issues = check_looping_tasks(conn)
            if issues:
                for issue in issues:
                    print(issue)
            else:
                print("No looping tasks detected.")
        finally:
            conn.close()


if __name__ == "__main__":
    main()
