#!/usr/bin/env python3
"""task_picker.py — DAG management and task selection for the Agent Harness.

Imports task definitions, queries task state, selects non-conflicting
ready tasks respecting dependency ordering.
"""

import argparse
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


def import_tasks(directory: str) -> int:
    """Import all .json task files from a directory into the database.

    Maps the 'verify' field in JSON to 'verify_cmd' in the schema.
    Returns the number of tasks imported.
    """
    task_dir = Path(directory)
    if not task_dir.is_dir():
        print(f"Error: not a directory: {directory}", file=sys.stderr)
        sys.exit(1)

    conn = get_connection()
    count = 0
    try:
        for fpath in sorted(task_dir.glob("*.json")):
            with open(fpath, encoding="utf-8") as f:
                data = json.load(f)

            task_id = data["id"]
            project = data.get("project", "default")
            project_dir = data.get("project_dir", None)
            goal = data["goal"]
            verify_cmd = data.get("verify", None)
            depends_on = json.dumps(data.get("depends_on", []))
            touches = json.dumps(data.get("touches", []))
            max_attempts = data.get("max_attempts", 5)

            conn.execute(
                """INSERT OR REPLACE INTO tasks
                   (id, project, project_dir, goal, verify_cmd, depends_on, touches,
                    status, attempt_count, max_attempts, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?, ?)""",
                (
                    task_id,
                    project,
                    project_dir,
                    goal,
                    verify_cmd,
                    depends_on,
                    touches,
                    max_attempts,
                    datetime.utcnow().isoformat(),
                    datetime.utcnow().isoformat(),
                ),
            )
            count += 1

        conn.commit()
        return count
    finally:
        conn.close()


def get_task(task_id: str) -> dict:
    """Fetch a single task as a dictionary. Returns None if not found."""
    conn = get_connection()
    try:
        row = conn.execute(
            "SELECT * FROM tasks WHERE id = ?", (task_id,)
        ).fetchone()
        if row is None:
            return None
        d = dict(row)
        d["depends_on"] = json.loads(d["depends_on"] or "[]")
        d["touches"] = json.loads(d["touches"] or "[]")
        return d
    finally:
        conn.close()


def get_verify_cmd(task_id: str) -> str:
    """Return the verify command for a task."""
    conn = get_connection()
    try:
        row = conn.execute(
            "SELECT verify_cmd FROM tasks WHERE id = ?", (task_id,)
        ).fetchone()
        if row is None:
            return None
        return row["verify_cmd"]
    finally:
        conn.close()


def mark_running(task_id: str, worker_id: int):
    """Set a task's status to 'running' and assign a worker."""
    conn = get_connection()
    try:
        conn.execute(
            """UPDATE tasks
               SET status = 'running',
                   assigned_worker = ?,
                   updated_at = ?
               WHERE id = ?""",
            (worker_id, datetime.utcnow().isoformat(), task_id),
        )
        conn.commit()
    finally:
        conn.close()


def mark_pass(task_id: str):
    """Set a task's status to 'pass'."""
    conn = get_connection()
    try:
        conn.execute(
            """UPDATE tasks
               SET status = 'pass',
                   updated_at = ?
               WHERE id = ?""",
            (datetime.utcnow().isoformat(), task_id),
        )
        conn.commit()
    finally:
        conn.close()


def record_failure(task_id: str, failure_text: str):
    """Record a failure: increment attempt_count, set status='fail', store error."""
    conn = get_connection()
    try:
        conn.execute(
            """UPDATE tasks
               SET status = 'fail',
                   attempt_count = attempt_count + 1,
                   last_error = ?,
                   updated_at = ?
               WHERE id = ?""",
            (failure_text[:2000], datetime.utcnow().isoformat(), task_id),
        )
        conn.commit()
    finally:
        conn.close()


def next_batch(max_workers: int) -> list:
    """Get up to max_workers non-conflicting ready tasks.

    A task is ready when:
    1. status = 'pending'
    2. All depends_on tasks have status = 'pass'
    3. Its touches don't overlap with any currently running task's touches

    Returns a list of task dicts.
    """
    conn = get_connection()
    try:
        # Get all pending tasks
        pending = conn.execute(
            "SELECT * FROM tasks WHERE status = 'pending'"
        ).fetchall()

        # Get currently running tasks' touched files
        running = conn.execute(
            "SELECT touches FROM tasks WHERE status = 'running'"
        ).fetchall()
        running_files = set()
        for r in running:
            running_files.update(json.loads(r["touches"] or "[]"))

        ready = []
        selected_files = set()

        for task in pending:
            # Check dependencies
            deps = json.loads(task["depends_on"] or "[]")
            if deps:
                dep_rows = conn.execute(
                    "SELECT id, status FROM tasks WHERE id IN ({})".format(
                        ",".join("?" for _ in deps)
                    ),
                    deps,
                ).fetchall()
                dep_statuses = {r["id"]: r["status"] for r in dep_rows}
                # All deps must be 'pass'
                if not all(dep_statuses.get(d) == "pass" for d in deps):
                    continue

            # Check file overlap with running + already selected
            task_files = set(json.loads(task["touches"] or "[]"))
            blocked = running_files | selected_files
            if task_files & blocked:
                continue

            # This task is ready
            t = dict(task)
            t["depends_on"] = json.loads(t["depends_on"] or "[]")
            t["touches"] = json.loads(t["touches"] or "[]")
            ready.append(t)
            selected_files.update(task_files)

            if len(ready) >= max_workers:
                break

        return ready
    finally:
        conn.close()


def escalate_task(task_id: str):
    """Mark a task as escalated (exceeded max attempts)."""
    conn = get_connection()
    try:
        conn.execute(
            """UPDATE tasks
               SET status = 'escalated',
                   updated_at = ?
               WHERE id = ?""",
            (datetime.utcnow().isoformat(), task_id),
        )
        conn.commit()
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(
        description="DAG management and task selection"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # import
    imp = sub.add_parser("import", help="Import task JSON files from directory")
    imp.add_argument("dir", help="Directory containing .json task files")

    # get
    get_p = sub.add_parser("get", help="Print task JSON")
    get_p.add_argument("task_id", help="Task ID")

    # get-verify
    gv = sub.add_parser("get-verify", help="Print verify command")
    gv.add_argument("task_id", help="Task ID")

    # mark-running
    mr = sub.add_parser("mark-running", help="Set task status to running")
    mr.add_argument("task_id", help="Task ID")
    mr.add_argument("worker_id", type=int, help="Worker ID")

    # mark-pass
    mp = sub.add_parser("mark-pass", help="Set task status to pass")
    mp.add_argument("task_id", help="Task ID")

    # record-failure
    rf = sub.add_parser("record-failure", help="Record a task failure")
    rf.add_argument("task_id", help="Task ID")
    rf.add_argument("failure_text", help="Failure output text")

    # next-batch
    nb = sub.add_parser("next-batch", help="Get next batch of ready tasks")
    nb.add_argument("--max", type=int, default=4, dest="max_workers",
                    help="Maximum number of tasks to return")

    # escalate
    esc = sub.add_parser("escalate", help="Mark task as escalated")
    esc.add_argument("task_id", help="Task ID")

    args = parser.parse_args()

    if args.command == "import":
        n = import_tasks(args.dir)
        print(f"Imported {n} tasks")

    elif args.command == "get":
        task = get_task(args.task_id)
        if task is None:
            print(f"Task not found: {args.task_id}", file=sys.stderr)
            sys.exit(1)
        print(json.dumps(task, indent=2, default=str))

    elif args.command == "get-verify":
        cmd = get_verify_cmd(args.task_id)
        if cmd is None:
            print(f"Task not found: {args.task_id}", file=sys.stderr)
            sys.exit(1)
        print(cmd)

    elif args.command == "mark-running":
        mark_running(args.task_id, args.worker_id)
        print(f"Task {args.task_id} → running (worker {args.worker_id})")

    elif args.command == "mark-pass":
        mark_pass(args.task_id)
        print(f"Task {args.task_id} → pass")

    elif args.command == "record-failure":
        record_failure(args.task_id, args.failure_text)
        print(f"Task {args.task_id} → fail (recorded)")

    elif args.command == "next-batch":
        batch = next_batch(args.max_workers)
        print(json.dumps(batch, indent=2, default=str))

    elif args.command == "escalate":
        escalate_task(args.task_id)
        print(f"Task {args.task_id} → escalated")


if __name__ == "__main__":
    main()
