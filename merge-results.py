#!/usr/bin/env python3
"""merge-results.py — Merge successful worker branches back to main.

Scans .worktrees/w* directories, checks if corresponding tasks passed,
and merges their branches into main.
"""

import argparse
import glob
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

PROJECT_ROOT = Path(__file__).resolve().parent


def get_connection() -> sqlite3.Connection:
    """Get SQLite connection with WAL mode and foreign keys."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def run_git(*args, cwd=None) -> subprocess.CompletedProcess:
    """Run a git command, returning the CompletedProcess result."""
    cmd = ["git"] + list(args)
    return subprocess.run(
        cmd,
        cwd=cwd or str(PROJECT_ROOT),
        capture_output=True,
        text=True,
    )


def get_worktree_branch(worktree_path: Path) -> str:
    """Get the branch name of a git worktree."""
    result = run_git("rev-parse", "--abbrev-ref", "HEAD", cwd=str(worktree_path))
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def get_passed_task_for_worker(conn: sqlite3.Connection, worker_id: int) -> list:
    """Find tasks assigned to this worker that have passed."""
    rows = conn.execute(
        """SELECT id FROM tasks
           WHERE assigned_worker = ? AND status = 'pass'""",
        (worker_id,),
    ).fetchall()
    return [r["id"] for r in rows]


def create_conflict_task(conn: sqlite3.Connection, branch: str, conflict_output: str):
    """Create a new task in the DB to resolve a merge conflict."""
    task_id = f"resolve-conflict-{branch}-{int(datetime.utcnow().timestamp())}"
    now = datetime.utcnow().isoformat()
    conn.execute(
        """INSERT INTO tasks
           (id, project, goal, verify_cmd, depends_on, touches,
            status, attempt_count, max_attempts, created_at, updated_at)
           VALUES (?, 'merge', ?, NULL, '[]', '[]',
                   'pending', 0, 5, ?, ?)""",
        (
            task_id,
            f"Resolve merge conflict for branch {branch}:\n{conflict_output[:2000]}",
            now,
            now,
        ),
    )
    conn.commit()
    return task_id


def merge_worker_branches():
    """Merge all passed worker branches back to main.

    For each .worktrees/w* directory:
    1. Extract worker ID from directory name
    2. Check if the worker's task has status 'pass'
    3. Attempt git merge
    4. On conflict: create a resolve-conflict task
    5. On success: remove worktree and delete branch
    """
    worktrees_dir = PROJECT_ROOT / ".worktrees"
    if not worktrees_dir.exists():
        print("No .worktrees directory found. Nothing to merge.")
        return

    worktree_dirs = sorted(worktrees_dir.glob("w*"))
    if not worktree_dirs:
        print("No worker worktrees found.")
        return

    conn = get_connection()
    merged = 0
    conflicts = 0
    skipped = 0

    try:
        for wt_path in worktree_dirs:
            if not wt_path.is_dir():
                continue

            # Extract worker ID from directory name (e.g., w0, w1, w2)
            wt_name = wt_path.name
            match = re.match(r"w(\d+)", wt_name)
            if not match:
                print(f"Skipping {wt_name}: cannot parse worker ID")
                skipped += 1
                continue

            worker_id = int(match.group(1))
            branch = get_worktree_branch(wt_path)
            if not branch:
                print(f"Skipping {wt_name}: cannot determine branch")
                skipped += 1
                continue

            # Check if any task assigned to this worker has passed
            passed_tasks = get_passed_task_for_worker(conn, worker_id)
            if not passed_tasks:
                print(f"Skipping {wt_name}: no passed tasks for worker {worker_id}")
                skipped += 1
                continue

            print(f"Merging {branch} (worker {worker_id}, tasks: {passed_tasks})...")

            # Attempt merge
            result = run_git("merge", "--no-ff", branch, "-m",
                             f"Merge worker {worker_id} branch {branch}")

            if result.returncode != 0:
                if "CONFLICT" in result.stdout or "CONFLICT" in result.stderr:
                    # Abort the failed merge
                    run_git("merge", "--abort")
                    conflict_output = result.stdout + "\n" + result.stderr
                    task_id = create_conflict_task(conn, branch, conflict_output)
                    print(f"  CONFLICT: created task {task_id}")
                    conflicts += 1
                else:
                    print(f"  MERGE FAILED: {result.stderr.strip()}")
                    skipped += 1
                continue

            # Success: remove worktree and delete branch
            remove_result = run_git("worktree", "remove", str(wt_path))
            if remove_result.returncode != 0:
                print(f"  Warning: failed to remove worktree: {remove_result.stderr.strip()}")

            delete_result = run_git("branch", "-d", branch)
            if delete_result.returncode != 0:
                print(f"  Warning: failed to delete branch: {delete_result.stderr.strip()}")

            print(f"  Merged and cleaned up {branch}")
            merged += 1

    finally:
        conn.close()

    print(f"\nSummary: {merged} merged, {conflicts} conflicts, {skipped} skipped")


def main():
    parser = argparse.ArgumentParser(
        description="Merge successful worker branches back to main"
    )
    # No subcommands needed — the script just runs
    args = parser.parse_args()
    merge_worker_branches()


if __name__ == "__main__":
    main()
