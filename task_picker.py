#!/usr/bin/env python3
"""task_picker.py — DAG management and task selection for the Agent Harness.

Imports task definitions, queries task state, selects non-conflicting
ready tasks respecting dependency ordering.
"""

import argparse
import json
import os
import shutil
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

            role = data.get("role", "implementer")
            stage = data.get("stage", None)
            pipeline_id = data.get("pipeline_id", None)
            spawned_by = data.get("spawned_by", None)

            now = datetime.utcnow().isoformat()
            try:
                conn.execute(
                    """INSERT OR REPLACE INTO tasks
                       (id, project, project_dir, goal, verify_cmd, depends_on, touches,
                        status, attempt_count, max_attempts, role, stage, pipeline_id,
                        spawned_by, created_at, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        task_id, project, project_dir, goal, verify_cmd,
                        depends_on, touches, max_attempts,
                        role, stage, pipeline_id, spawned_by,
                        now, now,
                    ),
                )
            except sqlite3.OperationalError:
                # 舊 schema 沒有新欄位，退回原始寫法
                conn.execute(
                    """INSERT OR REPLACE INTO tasks
                       (id, project, project_dir, goal, verify_cmd, depends_on, touches,
                        status, attempt_count, max_attempts, created_at, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?, ?)""",
                    (
                        task_id, project, project_dir, goal, verify_cmd,
                        depends_on, touches, max_attempts,
                        now, now,
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
    """Set a task's status to 'pass'.

    若 task 目前為 blocked 狀態則不覆蓋，避免子任務完成前提早解鎖。
    """
    conn = get_connection()
    try:
        conn.execute(
            """UPDATE tasks
               SET status = 'pass',
                   updated_at = ?
               WHERE id = ? AND status != 'blocked'""",
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


def next_batch(max_workers: int, role_filter: str = None) -> list:
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
        if role_filter:
            pending = conn.execute(
                "SELECT * FROM tasks WHERE status = 'pending' AND role = ?",
                (role_filter,),
            ).fetchall()
        else:
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


def list_roles() -> dict:
    """查詢所有任務的角色分佈，回傳 {role: {total, passed}}。"""
    conn = get_connection()
    try:
        rows = conn.execute(
            """SELECT role,
                      COUNT(*) AS total,
                      SUM(CASE WHEN status='pass' THEN 1 ELSE 0 END) AS passed
               FROM tasks GROUP BY role"""
        ).fetchall()
        return {r["role"]: {"total": r["total"], "passed": r["passed"]} for r in rows}
    finally:
        conn.close()


def get_pipeline_status(pipeline_id: str) -> dict:
    """查詢某 pipeline 下所有任務的狀態統計。"""
    conn = get_connection()
    try:
        rows = conn.execute(
            """SELECT status, COUNT(*) AS cnt
               FROM tasks WHERE pipeline_id = ? GROUP BY status""",
            (pipeline_id,),
        ).fetchall()
        result = {"total": 0, "pending": 0, "running": 0, "pass": 0,
                  "fail": 0, "escalated": 0}
        for r in rows:
            s = r["status"]
            if s in result:
                result[s] = r["cnt"]
            result["total"] += r["cnt"]
        return result
    finally:
        conn.close()


def spawn_subtasks(parent_id: str, subtasks_json: str, context_file: str = None) -> list:
    """從 parent task 衍生子任務，並將 parent 設為 blocked。

    回傳建立的 subtask ID list。若 spawn 深度 >= 3 則拒絕。
    """
    conn = get_connection()
    try:
        # WHY: 整個操作需要在同一個事務內完成，失敗時不改 parent 狀態
        conn.execute("BEGIN")

        # 1. 讀取 parent task
        parent = conn.execute(
            "SELECT * FROM tasks WHERE id = ?", (parent_id,)
        ).fetchone()
        if parent is None:
            print(f"錯誤：找不到 parent task: {parent_id}", file=sys.stderr)
            return []

        # 2. 計算 spawn 深度：沿 spawned_by 鏈往上追溯
        depth = 0
        current_spawned_by = parent["spawned_by"]
        while current_spawned_by:
            depth += 1
            ancestor = conn.execute(
                "SELECT spawned_by FROM tasks WHERE id = ?",
                (current_spawned_by,),
            ).fetchone()
            if ancestor is None:
                break
            current_spawned_by = ancestor["spawned_by"]

        # CONSTRAINT: 最大 spawn 深度為 3，防止無限遞迴
        if depth >= 3:
            print(
                f"錯誤：spawn 深度已達 {depth}，超過上限 3",
                file=sys.stderr,
            )
            return []

        # 3. 解析 subtasks JSON
        try:
            subtasks = json.loads(subtasks_json)
        except json.JSONDecodeError as e:
            print(f"錯誤：無法解析 subtasks JSON: {e}", file=sys.stderr)
            return []

        if not isinstance(subtasks, list):
            print("錯誤：subtasks 必須是 JSON array", file=sys.stderr)
            return []

        # 4. 逐一建立 subtask
        now = datetime.utcnow().isoformat()
        created_ids = []

        for st in subtasks:
            if "id" not in st or "goal" not in st:
                print(
                    f"錯誤：subtask 缺少必填欄位 id 或 goal: {st}",
                    file=sys.stderr,
                )
                conn.execute("ROLLBACK")
                return []

            st_id = st["id"]
            st_goal = st["goal"]
            st_touches = json.dumps(st.get("touches", []))
            st_verify = st.get("verify", None)
            st_role = st.get("role", "implementer")
            st_depends = json.dumps(st.get("depends_on", []))
            st_max = st.get("max_attempts", 3)

            conn.execute(
                """INSERT INTO tasks
                   (id, project, project_dir, goal, verify_cmd, depends_on,
                    touches, status, attempt_count, max_attempts, role, stage,
                    pipeline_id, spawned_by, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?, NULL, ?, ?, ?, ?)""",
                (
                    st_id,
                    parent["project"],
                    parent["project_dir"],
                    st_goal,
                    st_verify,
                    st_depends,
                    st_touches,
                    st_max,
                    st_role,
                    parent["pipeline_id"],
                    parent_id,
                    now,
                    now,
                ),
            )
            created_ids.append(st_id)

        # 5. 如果有 context_file，複製到指定路徑
        if context_file and os.path.isfile(context_file):
            dest = f"/tmp/spawn-context-{parent_id}.md"
            shutil.copy2(context_file, dest)

        # 6. 更新 parent 為 blocked
        # CONSTRAINT: SQLite CHECK constraint 可能不包含 'blocked'，需要繞過
        conn.execute("PRAGMA ignore_check_constraints=ON")
        conn.execute(
            """UPDATE tasks
               SET status = 'blocked', updated_at = ?
               WHERE id = ?""",
            (now, parent_id),
        )
        conn.execute("PRAGMA ignore_check_constraints=OFF")

        conn.execute("COMMIT")
        return created_ids

    except Exception:
        conn.execute("ROLLBACK")
        raise
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
    nb.add_argument("--role", type=str, default=None, dest="role_filter",
                    help="Only return tasks with this role")

    # escalate
    esc = sub.add_parser("escalate", help="Mark task as escalated")
    esc.add_argument("task_id", help="Task ID")

    # list-roles
    sub.add_parser("list-roles", help="Print role distribution")

    # pipeline-status
    ps = sub.add_parser("pipeline-status", help="Print pipeline status")
    ps.add_argument("pipeline_id", help="Pipeline ID")

    # spawn-subtasks
    sp = sub.add_parser("spawn-subtasks", help="Spawn sub-tasks and block parent")
    sp.add_argument("--parent", required=True, help="Parent task ID")
    sp.add_argument("--subtasks", help="JSON array of subtask objects")
    sp.add_argument("--from-file", help="JSON file containing subtask array")
    sp.add_argument("--context-file", help="Context file to pass to sub-tasks")

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
        batch = next_batch(args.max_workers, role_filter=args.role_filter)
        print(json.dumps(batch, indent=2, default=str))

    elif args.command == "escalate":
        escalate_task(args.task_id)
        print(f"Task {args.task_id} → escalated")

    elif args.command == "list-roles":
        roles = list_roles()
        print(json.dumps(roles, indent=2, default=str))

    elif args.command == "pipeline-status":
        status = get_pipeline_status(args.pipeline_id)
        print(json.dumps(status, indent=2, default=str))

    elif args.command == "spawn-subtasks":
        # 從 --from-file 或 --subtasks 取得 JSON
        if args.from_file:
            with open(args.from_file, encoding="utf-8") as f:
                subtasks_data = f.read()
        elif args.subtasks:
            subtasks_data = args.subtasks
        else:
            print("錯誤：需要 --subtasks 或 --from-file", file=sys.stderr)
            sys.exit(1)

        ids = spawn_subtasks(args.parent, subtasks_data, args.context_file)
        if ids:
            print(f"已建立 {len(ids)} 個子任務: {ids}")
        else:
            print("未建立任何子任務", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
