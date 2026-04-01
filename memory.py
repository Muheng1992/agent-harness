#!/usr/bin/env python3
"""memory.py — Cross-session memory for the Agent Harness.

Reads and writes run records so Claude agents can recall prior attempts.
"""

import argparse
import hashlib
import json
import os
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

DB_PATH = os.environ.get(
    "AGENT_DB_PATH",
    str(Path(__file__).resolve().parent / "db" / "agent.db"),
)


def get_connection() -> sqlite3.Connection:
    """Get SQLite connection with WAL mode and foreign keys."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def read_context(task_id: str) -> str:
    """Read last 3 runs for a task, return markdown-formatted context.

    The context includes task metadata plus the most recent run history
    so the agent can avoid repeating mistakes.
    """
    conn = get_connection()
    try:
        # Fetch task info
        task = conn.execute(
            "SELECT * FROM tasks WHERE id = ?", (task_id,)
        ).fetchone()
        if not task:
            return f"No task found with id: {task_id}"

        lines = [
            f"# Task: {task_id}",
            f"**Project:** {task['project']}",
            f"**Goal:** {task['goal']}",
            f"**Status:** {task['status']}",
            f"**Attempts:** {task['attempt_count']}/{task['max_attempts']}",
        ]

        if task["error_class"]:
            lines.append(f"**Last Error Class:** {task['error_class']}")
        if task["last_error"]:
            lines.append(f"**Last Error:** {task['last_error']}")

        touches = json.loads(task["touches"] or "[]")
        if touches:
            lines.append(f"**Files touched:** {', '.join(touches)}")

        depends = json.loads(task["depends_on"] or "[]")
        if depends:
            lines.append(f"**Depends on:** {', '.join(depends)}")

        # Fetch last 3 runs
        runs = conn.execute(
            "SELECT * FROM runs WHERE task_id = ? ORDER BY id DESC LIMIT 3",
            (task_id,),
        ).fetchall()

        if runs:
            lines.append("")
            lines.append("## Run History (most recent first)")
            for run in runs:
                lines.append("")
                lines.append(
                    f"### Attempt {run['attempt']} — {run['status']}"
                )
                lines.append(f"- Worker: {run['worker_id']}")
                if run["duration_sec"]:
                    lines.append(f"- Duration: {run['duration_sec']:.1f}s")
                if run["error_class"]:
                    lines.append(f"- Error class: {run['error_class']}")
                if run["started_at"]:
                    lines.append(f"- Started: {run['started_at']}")
                if run["finished_at"]:
                    lines.append(f"- Finished: {run['finished_at']}")
                if run["claude_output"]:
                    lines.append("- **Claude output:**")
                    lines.append(f"```\n{run['claude_output']}\n```")
                if run["verify_output"]:
                    lines.append("- **Verify output:**")
                    lines.append(f"```\n{run['verify_output']}\n```")
        else:
            lines.append("")
            lines.append("_No prior runs recorded._")

        return "\n".join(lines)
    finally:
        conn.close()


def write_run(
    task_id: str,
    claude_output: str,
    verify_output: str = None,
    error_class: str = None,
    duration: float = 0.0,
    worker_id: int = 0,
    attempt: int = 1,
    status: str = "running",
) -> int:
    """Insert a new run record.

    Returns the row id of the inserted run.
    """
    conn = get_connection()
    try:
        now = datetime.utcnow().isoformat()
        prompt_hash = hashlib.sha256(claude_output.encode()).hexdigest()[:16]

        finished = now if status in ("pass", "fail", "error") else None

        cur = conn.execute(
            """INSERT INTO runs
               (task_id, worker_id, attempt, status, prompt_hash,
                claude_output, verify_output, error_class, duration_sec,
                started_at, finished_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                task_id,
                worker_id,
                attempt,
                status,
                prompt_hash,
                claude_output,
                verify_output,
                error_class,
                duration,
                now,
                finished,
            ),
        )
        conn.commit()
        return cur.lastrowid
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(
        description="Cross-session memory for Agent Harness"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # read
    read_p = sub.add_parser("read", help="Print accumulated context for a task")
    read_p.add_argument("task_id", help="Task ID to read context for")

    # write
    write_p = sub.add_parser("write", help="Record a run for a task")
    write_p.add_argument("task_id", help="Task ID")
    write_p.add_argument(
        "--output-file",
        required=True,
        help="File containing Claude's output",
    )
    write_p.add_argument("--verify-output", default=None)
    write_p.add_argument("--error-class", default=None)
    write_p.add_argument("--duration", type=float, default=0.0)
    write_p.add_argument("--worker-id", type=int, default=0)
    write_p.add_argument("--attempt", type=int, default=1)
    write_p.add_argument("--status", default="running")

    args = parser.parse_args()

    if args.command == "read":
        print(read_context(args.task_id))

    elif args.command == "write":
        output_path = Path(args.output_file)
        if not output_path.exists():
            print(f"Error: output file not found: {args.output_file}", file=sys.stderr)
            sys.exit(1)
        claude_output = output_path.read_text(encoding="utf-8")

        run_id = write_run(
            task_id=args.task_id,
            claude_output=claude_output,
            verify_output=args.verify_output,
            error_class=args.error_class,
            duration=args.duration,
            worker_id=args.worker_id,
            attempt=args.attempt,
            status=args.status,
        )
        print(f"Recorded run {run_id} for task {args.task_id}")


if __name__ == "__main__":
    main()
