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


def read_upstream_context(task_id: str) -> str:
    """讀取前置任務（depends_on）的 handoff manifest。

    設計原則（基於 MetaGPT / Anthropic / LangGraph best practices）：
    - 不轉發原始 output（anti-pattern: Natural Language Telephone）
    - 提供結構化 manifest：檔案路徑 + 介面摘要
    - 告訴下游 agent「去讀哪些檔案」，而非把內容塞進 prompt
    - 每個上游預算 ~500 字元，總計最多 3000 字元
    """
    conn = get_connection()
    try:
        task = conn.execute(
            "SELECT * FROM tasks WHERE id = ?", (task_id,)
        ).fetchone()
        if not task:
            return ""

        depends = json.loads(task["depends_on"] or "[]")
        if not depends:
            return ""

        TOTAL_LIMIT = 3000
        lines = []
        total_chars = 0

        for dep_id in depends:
            if total_chars >= TOTAL_LIMIT:
                lines.append(f"\n(... 省略其餘上游任務，已達 context 上限)")
                break

            dep_task = conn.execute(
                "SELECT id, goal, touches, status, project_dir FROM tasks WHERE id = ?",
                (dep_id,),
            ).fetchone()
            if not dep_task:
                continue

            if dep_task["status"] != "pass":
                lines.append(f"\n### ⏳ {dep_id} — 尚未完成 (status={dep_task['status']})")
                continue

            touches = json.loads(dep_task["touches"] or "[]")

            # 嘗試讀取結構化 handoff manifest
            manifest = _read_handoff_manifest(dep_id)

            section = [f"\n### ✅ {dep_id}"]

            if manifest:
                # 有結構化 manifest — 最佳路徑
                if manifest.get("created_files"):
                    section.append(f"**建立的檔案（你必須 Read 這些檔案再動手）:**")
                    for f in manifest["created_files"]:
                        section.append(f"  - `{f}`")
                if manifest.get("interfaces"):
                    section.append(f"**Public Interfaces:**")
                    for iface in manifest["interfaces"][:10]:
                        section.append(f"  - `{iface}`")
                if manifest.get("decisions"):
                    section.append(f"**關鍵決策:**")
                    for d in manifest["decisions"][:5]:
                        section.append(f"  - {d}")
                if manifest.get("notes"):
                    section.append(f"**給下游的備註:** {manifest['notes']}")
                # 累積式祖先決策：帶上整條鏈的關鍵決策
                if manifest.get("ancestor_decisions"):
                    section.append(f"**祖先決策（影響整個專案）:**")
                    for ad in manifest["ancestor_decisions"][:10]:
                        section.append(f"  - {ad[:100]}")
            else:
                # 沒有 manifest — fallback 到 touches + 簡要 goal
                if touches:
                    section.append(f"**修改的檔案（你必須 Read 這些檔案再動手）:**")
                    for f in touches:
                        section.append(f"  - `{f}`")
                else:
                    goal_short = dep_task["goal"][:150]
                    section.append(f"**任務目標:** {goal_short}...")

            block = "\n".join(section)
            total_chars += len(block)
            lines.append(block)

        return "\n".join(lines) if lines else ""
    finally:
        conn.close()


def _read_handoff_manifest(task_id: str) -> dict:
    """讀取任務的 handoff manifest JSON。

    Manifest 存在兩個可能的位置：
    1. DB runs 表的 claude_output 中（如果 agent 輸出了 JSON manifest）
    2. 磁碟上的 /tmp/handoff-{task_id}.json
    """
    # 優先讀磁碟上的 manifest
    manifest_path = Path(f"/tmp/handoff-{task_id}.json")
    if manifest_path.exists():
        try:
            return json.loads(manifest_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            pass

    # Fallback: 嘗試從最後一次 pass 的 output 中解析
    conn = get_connection()
    try:
        last_run = conn.execute(
            """SELECT claude_output FROM runs
               WHERE task_id = ? AND status = 'pass'
               ORDER BY id DESC LIMIT 1""",
            (task_id,),
        ).fetchone()

        if not last_run or not last_run["claude_output"]:
            return None

        output = last_run["claude_output"]

        # 嘗試找 JSON manifest block（agent 可能用 ```json 包裝）
        manifest = _try_extract_json_manifest(output)
        if manifest:
            return manifest

        # 嘗試從結構化 markdown 摘要中提取資訊
        md_manifest = _parse_markdown_summary(output)
        if md_manifest:
            return md_manifest

        # 最後 fallback：從原始碼自動提取
        return _auto_extract_manifest_from_source(task_id)
    finally:
        conn.close()


def _try_extract_json_manifest(output: str) -> dict:
    """嘗試從 output 中找到 handoff manifest JSON。

    Claude 的 --output-format json 會把文字包在 {"result": "..."} 裡，
    所以要先解開外層 JSON，再從 result 欄位中找 manifest。
    """
    import re

    text = output

    # 如果外層是 Claude JSON wrapper，先解開取 result 欄位
    try:
        wrapper = json.loads(output)
        if isinstance(wrapper, dict) and "result" in wrapper:
            text = wrapper["result"]
    except (json.JSONDecodeError, TypeError):
        pass

    # 找 ```json ... ``` 中包含 handoff 關鍵字的 block
    json_blocks = re.findall(r'```json\s*\n(.*?)\n```', text, re.DOTALL)
    for block in json_blocks:
        try:
            data = json.loads(block)
            if isinstance(data, dict) and any(
                k in data for k in ("created_files", "interfaces", "decisions")
            ):
                return data
        except json.JSONDecodeError:
            continue
    return None


def _parse_markdown_summary(output: str) -> dict:
    """從 markdown 格式的實作摘要中提取結構化資訊。"""
    import re

    # 先解開 Claude JSON wrapper
    text = output
    try:
        wrapper = json.loads(output)
        if isinstance(wrapper, dict) and "result" in wrapper:
            text = wrapper["result"]
    except (json.JSONDecodeError, TypeError):
        pass

    manifest = {}

    # 提取「變更檔案」列表
    file_patterns = re.findall(r'[-*]\s+`([^`]+)`', text)
    if file_patterns:
        # 過濾出看起來像檔案路徑的
        files = [f for f in file_patterns if '/' in f or '.' in f]
        if files:
            manifest["created_files"] = files[:15]

    # 提取 protocol/interface/class 定義
    iface_patterns = re.findall(
        r'(?:protocol|class|struct|func|interface|def|function)\s+\w+[^;\n]{0,80}',
        text
    )
    if iface_patterns:
        manifest["interfaces"] = iface_patterns[:10]

    return manifest if manifest else None


def _collect_ancestor_decisions(task_id: str) -> list:
    """收集當前 task 的所有上游 decisions + ancestor_decisions。

    讀取 depends_on 的 manifest，合併所有 decisions 與 ancestor_decisions，
    去重後最多保留 10 條，每條限 100 字元。
    """
    conn = get_connection()
    try:
        task = conn.execute(
            "SELECT depends_on FROM tasks WHERE id = ?", (task_id,)
        ).fetchone()
        if not task:
            return []

        depends = json.loads(task["depends_on"] or "[]")
        if not depends:
            return []

        all_decisions = []
        seen = set()

        for dep_id in depends:
            manifest = _read_handoff_manifest(dep_id)
            if not manifest:
                continue
            # 收集直接 decisions
            for d in manifest.get("decisions", []):
                truncated = d[:100]
                if truncated not in seen:
                    seen.add(truncated)
                    all_decisions.append(truncated)
            # 收集已累積的 ancestor_decisions
            for ad in manifest.get("ancestor_decisions", []):
                truncated = ad[:100]
                if truncated not in seen:
                    seen.add(truncated)
                    all_decisions.append(truncated)

        return all_decisions[:10]
    finally:
        conn.close()


def _auto_extract_manifest_from_source(task_id: str) -> dict:
    """從原始碼自動提取 manifest（最後 fallback）。

    讀取 task 的 touches 檔案，用 regex 提取 protocol/class/func 等定義。
    """
    import re

    conn = get_connection()
    try:
        task = conn.execute(
            "SELECT touches, project_dir FROM tasks WHERE id = ?", (task_id,)
        ).fetchone()
        if not task:
            return None

        touches = json.loads(task["touches"] or "[]")
        project_dir = task["project_dir"] or ""
        if not touches:
            return None

        created_files = []
        interfaces = []

        # WHY: 針對不同語言使用不同的 regex 模式提取公開介面
        swift_pattern = re.compile(
            r'\b(protocol\s+\w+|class\s+\w+|struct\s+\w+|func\s+\w+\([^)]*\)|enum\s+\w+)'
        )
        js_ts_pattern = re.compile(
            r'\b(class\s+\w+|function\s+\w+|export\s+(?:const|let|function|class)\s+\w+|module\.exports)'
        )
        python_pattern = re.compile(
            r'\b(class\s+\w+|def\s+\w+)'
        )

        for file_rel in touches:
            file_path = Path(project_dir) / file_rel if project_dir else Path(file_rel)
            if not file_path.exists():
                continue

            created_files.append(file_rel)

            try:
                content = file_path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue

            suffix = file_path.suffix.lower()
            if suffix == ".swift":
                matches = swift_pattern.findall(content)
            elif suffix in (".js", ".ts", ".jsx", ".tsx", ".mjs"):
                matches = js_ts_pattern.findall(content)
            elif suffix == ".py":
                matches = python_pattern.findall(content)
            else:
                continue

            interfaces.extend(matches[:10])

        if not created_files and not interfaces:
            return None

        manifest = {}
        if created_files:
            manifest["created_files"] = created_files[:15]
        if interfaces:
            manifest["interfaces"] = interfaces[:10]
        return manifest
    finally:
        conn.close()


def read_project_brief(project_dir: str) -> str:
    """讀取專案的 project brief（所有已完成任務的介面與決策摘要）。

    Brief 存於 {project_dir}/.harness/project-brief.md。
    用於並行任務之間的語意同步，避免介面衝突。
    """
    brief_path = Path(project_dir) / ".harness" / "project-brief.md"
    if not brief_path.exists():
        return ""
    try:
        return brief_path.read_text(encoding="utf-8")
    except OSError:
        return ""


def update_project_brief(task_id: str):
    """將任務的 handoff manifest 追加或更新到 project brief。

    格式為 markdown 區塊，以 task_id 為標題。
    限制 brief 總大小不超過 8000 字元（超過時刪除最舊的區塊）。
    """
    import re

    conn = get_connection()
    try:
        task = conn.execute(
            "SELECT project_dir FROM tasks WHERE id = ?", (task_id,)
        ).fetchone()
        if not task or not task["project_dir"]:
            return

        project_dir = task["project_dir"]
        brief_path = Path(project_dir) / ".harness" / "project-brief.md"

        # 確保目錄存在
        brief_path.parent.mkdir(parents=True, exist_ok=True)

        # 讀取 manifest
        manifest = _read_handoff_manifest(task_id)
        if not manifest:
            return

        # 建立新區塊
        block_lines = [f"## {task_id}"]
        if manifest.get("interfaces"):
            block_lines.append("- **Interfaces:**")
            for iface in manifest["interfaces"][:10]:
                block_lines.append(f"  - `{iface}`")
        if manifest.get("decisions"):
            block_lines.append("- **Decisions:**")
            for d in manifest["decisions"][:5]:
                block_lines.append(f"  - {d}")
        new_block = "\n".join(block_lines) + "\n"

        # 讀取現有 brief
        existing = ""
        if brief_path.exists():
            try:
                existing = brief_path.read_text(encoding="utf-8")
            except OSError:
                existing = ""

        # 如果已有該 task_id 的區塊，替換之
        pattern = re.compile(
            rf'^## {re.escape(task_id)}\n(?:(?!^## ).)*',
            re.MULTILINE | re.DOTALL
        )
        if pattern.search(existing):
            existing = pattern.sub(new_block, existing)
        else:
            existing = existing.rstrip("\n") + "\n\n" + new_block if existing.strip() else new_block

        # 限制總大小 8000 字元（超過時刪除最舊的區塊）
        while len(existing) > 8000:
            # 找到第一個 ## 區塊並刪除
            first_block = re.search(r'^## .+?\n(?:(?!^## ).)*', existing, re.MULTILINE | re.DOTALL)
            if not first_block:
                break
            existing = existing[first_block.end():].lstrip("\n")

        brief_path.write_text(existing, encoding="utf-8")
    finally:
        conn.close()


def read_spawn_context(task_id: str) -> str:
    """讀取 spawned_by 父任務的 spawn context。

    Spawn context 存於 /tmp/spawn-context-{spawned_by}.md，
    由父任務在 spawn 子任務時寫入，包含執行時期的動態指令。
    """
    conn = get_connection()
    try:
        task = conn.execute(
            "SELECT spawned_by FROM tasks WHERE id = ?", (task_id,)
        ).fetchone()
        if not task:
            return ""

        spawned_by = task["spawned_by"] if task["spawned_by"] else None
        if not spawned_by:
            return ""

        context_path = Path(f"/tmp/spawn-context-{spawned_by}.md")
        if not context_path.exists():
            return ""

        try:
            content = context_path.read_text(encoding="utf-8")
            # 限制 4000 字元
            return content[:4000]
        except OSError:
            return ""
    finally:
        conn.close()


def compute_output_fingerprint(claude_output: str) -> str:
    """計算輸出內容的正規化指紋，用於偵測重複循環。

    移除時間戳記、UUID、連續空白等變動內容後計算 hash。
    取前 2000 字元的正規化內容作為指紋來源。
    """
    import re
    # 移除時間戳記格式（ISO 8601 等）
    normalized = re.sub(r'\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}', '', claude_output)
    # 移除 UUID 格式字串
    normalized = re.sub(
        r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
        '', normalized,
    )
    # 移除連續空白
    normalized = re.sub(r'\s+', ' ', normalized).strip()
    # 取前 2000 字元
    normalized = normalized[:2000]
    return hashlib.sha256(normalized.encode()).hexdigest()[:32]


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
        fingerprint = compute_output_fingerprint(claude_output)

        finished = now if status in ("pass", "fail", "error") else None

        try:
            cur = conn.execute(
                """INSERT INTO runs
                   (task_id, worker_id, attempt, status, prompt_hash,
                    claude_output, verify_output, error_class, duration_sec,
                    started_at, finished_at, output_fingerprint)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
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
                    fingerprint,
                ),
            )
        except sqlite3.OperationalError:
            # migration 尚未跑：降級到不存 fingerprint
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

    # read-upstream
    rup = sub.add_parser("read-upstream", help="Print upstream tasks' output summaries")
    rup.add_argument("task_id", help="Task ID to read upstream context for")

    # extract-handoff
    eh = sub.add_parser("extract-handoff", help="Extract handoff manifest from output")
    eh.add_argument("task_id", help="Task ID")
    eh.add_argument("output_file", help="Path to Claude output file")

    # read-brief
    rb = sub.add_parser("read-brief", help="Read project brief for a task's project")
    rb.add_argument("task_id", help="Task ID")

    # update-brief
    ub = sub.add_parser("update-brief", help="Update project brief with task's manifest")
    ub.add_argument("task_id", help="Task ID")

    # read-spawn-context
    rsc = sub.add_parser("read-spawn-context", help="Read spawn context for a task")
    rsc.add_argument("task_id", help="Task ID")

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

    elif args.command == "read-upstream":
        result = read_upstream_context(args.task_id)
        if result:
            print(result)

    elif args.command == "extract-handoff":
        output_path = Path(args.output_file)
        if not output_path.exists():
            print(f"No output file: {args.output_file}", file=sys.stderr)
            sys.exit(0)  # 不是致命錯誤
        output = output_path.read_text(encoding="utf-8")

        # 嘗試提取 JSON manifest
        manifest = _try_extract_json_manifest(output)
        if not manifest:
            manifest = _parse_markdown_summary(output)
        if not manifest:
            manifest = _auto_extract_manifest_from_source(args.task_id)

        if manifest:
            # 累積祖先決策：收集上游的 decisions + ancestor_decisions
            ancestor_decisions = _collect_ancestor_decisions(args.task_id)
            if ancestor_decisions:
                manifest["ancestor_decisions"] = ancestor_decisions

            manifest_path = Path(f"/tmp/handoff-{args.task_id}.json")
            manifest_path.write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            print(f"Handoff manifest saved to {manifest_path}")
        else:
            print(f"No manifest extracted for {args.task_id} (output will be parsed on-demand)")

    elif args.command == "read-brief":
        conn = get_connection()
        try:
            task = conn.execute(
                "SELECT project_dir FROM tasks WHERE id = ?", (args.task_id,)
            ).fetchone()
            if task and task["project_dir"]:
                result = read_project_brief(task["project_dir"])
                if result:
                    print(result)
        finally:
            conn.close()

    elif args.command == "update-brief":
        update_project_brief(args.task_id)
        print(f"Project brief updated for {args.task_id}")

    elif args.command == "read-spawn-context":
        result = read_spawn_context(args.task_id)
        if result:
            print(result)

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
