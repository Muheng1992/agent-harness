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


def check_all_done(conn: sqlite3.Connection) -> list:
    """Check if all work is complete (no pending/running/fail tasks).

    Returns a completion message or empty list.
    """
    remaining = conn.execute(
        """SELECT COUNT(*) as cnt FROM tasks
           WHERE status IN ('pending', 'running', 'fail')"""
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


if __name__ == "__main__":
    main()
