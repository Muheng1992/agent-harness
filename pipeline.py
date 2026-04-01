#!/usr/bin/env python3
"""pipeline.py — Pipeline 引擎，負責多角色自動串接。

讀取 YAML 模板、實例化 pipeline（產生 tasks 鏈）、推進階段、查詢狀態。
"""

import argparse
import json
import os
import random
import sqlite3
import sys
import time
from datetime import datetime
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None

from task_picker import DB_PATH, get_connection

PIPELINE_DIR = Path(__file__).resolve().parent / "pipelines"


# ---------------------------------------------------------------------------
# 模板載入
# ---------------------------------------------------------------------------

def load_template(template_name: str) -> dict:
    """從 pipelines/ 目錄讀取模板，優先 YAML，fallback JSON。"""
    yaml_path = PIPELINE_DIR / f"{template_name}.yaml"
    yml_path = PIPELINE_DIR / f"{template_name}.yml"
    json_path = PIPELINE_DIR / f"{template_name}.json"

    if yaml is not None:
        for p in (yaml_path, yml_path):
            if p.exists():
                with open(p, encoding="utf-8") as f:
                    return yaml.safe_load(f)

    if json_path.exists():
        with open(json_path, encoding="utf-8") as f:
            return json.load(f)

    # 如果沒有 PyYAML 但 YAML 檔存在，給出提示
    if yaml is None:
        for p in (yaml_path, yml_path):
            if p.exists():
                print(
                    f"警告：找到 {p.name} 但未安裝 PyYAML，請 pip install pyyaml 或改用 .json 格式",
                    file=sys.stderr,
                )

    print(f"錯誤：找不到模板 '{template_name}'（搜尋路徑：{PIPELINE_DIR}）", file=sys.stderr)
    sys.exit(1)


def render_goal(template_str: str, variables: dict) -> str:
    """用 variables dict 替換 goal_template 中的 {placeholder}。"""
    result = template_str
    for key, value in variables.items():
        result = result.replace(f"{{{key}}}", str(value))
    return result


# ---------------------------------------------------------------------------
# Pipeline 實例化
# ---------------------------------------------------------------------------

def generate_pipeline_id() -> str:
    """產生 pipeline_id：pipe-{timestamp}-{random}。"""
    ts = int(time.time())
    rnd = random.randint(1000, 9999)
    return f"pipe-{ts}-{rnd}"


def create_pipeline(
    template_name: str,
    project: str,
    project_dir: str,
    variables: dict,
    verify_cmd: str = None,
) -> tuple:
    """實例化 pipeline：讀取模板、產生任務鏈、寫入資料庫。

    回傳 (pipeline_id, [task_ids])。
    """
    template = load_template(template_name)
    pipeline_id = generate_pipeline_id()
    stages = template.get("stages", [])
    fix_loops = template.get("fix_loops", {})
    now = datetime.utcnow().isoformat()

    config = {
        "variables": variables,
        "verify_cmd": verify_cmd,
        "fix_loops": fix_loops,
    }

    conn = get_connection()
    try:
        # 寫入 pipelines 表
        conn.execute(
            """INSERT INTO pipelines (id, name, project, template, config, status, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, 'active', ?, ?)""",
            (
                pipeline_id,
                template.get("name", template_name),
                project,
                template_name,
                json.dumps(config, ensure_ascii=False),
                now,
                now,
            ),
        )

        task_ids = []
        prev_task_id = None

        for idx, stage in enumerate(stages):
            task_id = f"{pipeline_id}-{stage['name']}"
            goal = render_goal(stage["goal_template"], variables)
            role = stage.get("role", "implementer")
            depends_on = [prev_task_id] if prev_task_id else []

            # 如果 stage 是 optional 且沒有相關變數，仍然建立但標記
            conn.execute(
                """INSERT INTO tasks
                   (id, project, project_dir, goal, verify_cmd, depends_on, touches,
                    status, attempt_count, max_attempts, role, stage, pipeline_id,
                    created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, '[]', 'pending', 0, 5, ?, ?, ?, ?, ?)""",
                (
                    task_id,
                    project,
                    project_dir,
                    goal,
                    verify_cmd,
                    json.dumps(depends_on),
                    role,
                    stage["name"],
                    pipeline_id,
                    now,
                    now,
                ),
            )

            task_ids.append(task_id)
            prev_task_id = task_id

        conn.commit()
        return pipeline_id, task_ids
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Pipeline 階段推進
# ---------------------------------------------------------------------------

def advance_pipeline(pipeline_id: str) -> dict:
    """推進 pipeline：檢查任務狀態、處理 fix-loop、標記完成/失敗。

    回傳 dict 描述推進結果。
    """
    conn = get_connection()
    try:
        # 取得 pipeline 資訊
        pipe = conn.execute(
            "SELECT * FROM pipelines WHERE id = ?", (pipeline_id,)
        ).fetchone()
        if pipe is None:
            return {"error": f"Pipeline 不存在：{pipeline_id}"}
        if pipe["status"] in ("completed", "failed"):
            return {"status": pipe["status"], "message": "Pipeline 已結束"}

        config = json.loads(pipe["config"] or "{}")
        fix_loops = config.get("fix_loops", {})
        variables = config.get("variables", {})
        verify_cmd = config.get("verify_cmd")

        # 取得此 pipeline 的所有任務（按建立時間排序）
        tasks = conn.execute(
            "SELECT * FROM tasks WHERE pipeline_id = ? ORDER BY created_at",
            (pipeline_id,),
        ).fetchall()

        actions = []
        all_passed = True
        has_escalated = False

        for task in tasks:
            status = task["status"]
            stage_name = task["stage"]

            if status == "escalated":
                has_escalated = True
                break

            if status == "pass":
                continue

            if status in ("pending", "running"):
                all_passed = False
                continue

            if status == "fail":
                all_passed = False
                # 檢查此 stage 是否有 on_fail 定義
                # 需要從模板中找到 stage 定義
                template = load_template(pipe["template"])
                stage_def = None
                for s in template.get("stages", []):
                    if s["name"] == stage_name:
                        stage_def = s
                        break

                if stage_def and stage_def.get("on_fail") and stage_def["on_fail"] in fix_loops:
                    loop_config = fix_loops[stage_def["on_fail"]]
                    max_iter = loop_config.get("max_iterations", 3)

                    # 計算已經執行了幾次 fix-loop
                    fix_count = conn.execute(
                        """SELECT COUNT(*) as cnt FROM tasks
                           WHERE pipeline_id = ? AND spawned_by = ? AND role = 'debugger'""",
                        (pipeline_id, task["id"]),
                    ).fetchone()["cnt"]

                    if fix_count >= max_iter:
                        # 超過最大修復次數，escalate
                        now = datetime.utcnow().isoformat()
                        conn.execute(
                            "UPDATE tasks SET status = 'escalated', updated_at = ? WHERE id = ?",
                            (now, task["id"]),
                        )
                        conn.commit()
                        actions.append(f"Stage '{stage_name}' 超過修復上限 ({max_iter})，已 escalate")
                        has_escalated = True
                        break

                    # 產生 debugger 任務
                    fail_output = task["last_error"] or "（無錯誤輸出）"
                    debug_vars = {**variables, "review_output": fail_output}
                    debugger_goal = render_goal(
                        loop_config.get("debugger_goal", "修復問題：{review_output}"),
                        debug_vars,
                    )
                    now = datetime.utcnow().isoformat()
                    debugger_id = f"{pipeline_id}-fix-{stage_name}-{fix_count + 1}"

                    conn.execute(
                        """INSERT OR IGNORE INTO tasks
                           (id, project, project_dir, goal, verify_cmd, depends_on, touches,
                            status, attempt_count, max_attempts, role, stage, pipeline_id,
                            spawned_by, created_at, updated_at)
                           VALUES (?, ?, ?, ?, ?, '[]', '[]', 'pending', 0, 5, 'debugger', ?, ?, ?, ?, ?)""",
                        (
                            debugger_id,
                            pipe["project"],
                            tasks[0]["project_dir"] if tasks else None,
                            debugger_goal,
                            verify_cmd,
                            f"fix-{stage_name}",
                            pipeline_id,
                            task["id"],
                            now,
                            now,
                        ),
                    )

                    # 在 debugger 完成後，需要重新產生該 stage 的任務
                    then_stage = loop_config.get("then", stage_name)
                    retry_id = f"{pipeline_id}-{then_stage}-retry-{fix_count + 1}"

                    # 找到原始 stage 定義
                    then_def = None
                    for s in template.get("stages", []):
                        if s["name"] == then_stage:
                            then_def = s
                            break

                    if then_def:
                        retry_goal = render_goal(then_def["goal_template"], variables)
                        conn.execute(
                            """INSERT OR IGNORE INTO tasks
                               (id, project, project_dir, goal, verify_cmd, depends_on, touches,
                                status, attempt_count, max_attempts, role, stage, pipeline_id,
                                spawned_by, created_at, updated_at)
                               VALUES (?, ?, ?, ?, ?, ?, '[]', 'pending', 0, 5, ?, ?, ?, ?, ?, ?)""",
                            (
                                retry_id,
                                pipe["project"],
                                tasks[0]["project_dir"] if tasks else None,
                                retry_goal,
                                verify_cmd,
                                json.dumps([debugger_id]),
                                then_def.get("role", "implementer"),
                                then_stage,
                                pipeline_id,
                                task["id"],
                                now,
                                now,
                            ),
                        )

                    conn.commit()
                    actions.append(
                        f"Stage '{stage_name}' 失敗，已產生修復任務 {debugger_id} → 重試 {retry_id}"
                    )
                    continue

        now = datetime.utcnow().isoformat()
        if has_escalated:
            conn.execute(
                "UPDATE pipelines SET status = 'failed', updated_at = ? WHERE id = ?",
                (now, pipeline_id),
            )
            conn.commit()
            actions.append("Pipeline 標記為 failed")
        elif all_passed and len(tasks) > 0:
            conn.execute(
                "UPDATE pipelines SET status = 'completed', updated_at = ? WHERE id = ?",
                (now, pipeline_id),
            )
            conn.commit()
            actions.append("Pipeline 所有階段完成，標記為 completed")

        return {
            "pipeline_id": pipeline_id,
            "status": "failed" if has_escalated else ("completed" if all_passed and tasks else "active"),
            "actions": actions,
        }
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 狀態查詢
# ---------------------------------------------------------------------------

def get_pipeline_status(pipeline_id: str) -> dict:
    """取得 pipeline 及其所有任務的狀態。"""
    conn = get_connection()
    try:
        pipe = conn.execute(
            "SELECT * FROM pipelines WHERE id = ?", (pipeline_id,)
        ).fetchone()
        if pipe is None:
            return None

        tasks = conn.execute(
            "SELECT id, stage, role, status, attempt_count, last_error, spawned_by FROM tasks WHERE pipeline_id = ? ORDER BY created_at",
            (pipeline_id,),
        ).fetchall()

        return {
            "pipeline_id": pipe["id"],
            "name": pipe["name"],
            "project": pipe["project"],
            "template": pipe["template"],
            "status": pipe["status"],
            "created_at": pipe["created_at"],
            "updated_at": pipe["updated_at"],
            "stages": [
                {
                    "task_id": t["id"],
                    "stage": t["stage"],
                    "role": t["role"],
                    "status": t["status"],
                    "attempts": t["attempt_count"],
                    "last_error": t["last_error"],
                    "spawned_by": t["spawned_by"],
                }
                for t in tasks
            ],
        }
    finally:
        conn.close()


def list_pipelines() -> list:
    """列出所有 pipeline。"""
    conn = get_connection()
    try:
        rows = conn.execute(
            "SELECT id, name, project, template, status, created_at, updated_at FROM pipelines ORDER BY created_at DESC"
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Pipeline 引擎 — 多角色自動串接"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # create
    cr = sub.add_parser("create", help="從模板建立 pipeline")
    cr.add_argument("template", help="模板名稱（pipelines/ 下的檔案名）")
    cr.add_argument("--project", required=True, help="專案名稱")
    cr.add_argument("--dir", required=True, dest="project_dir", help="專案目錄路徑")
    cr.add_argument("--var", action="append", default=[], help="變數 key=value（可多次使用）")
    cr.add_argument("--verify", default=None, help="驗證指令")

    # advance
    adv = sub.add_parser("advance", help="推進 pipeline 階段")
    adv.add_argument("pipeline_id", help="Pipeline ID")

    # status
    st = sub.add_parser("status", help="查看 pipeline 狀態")
    st.add_argument("pipeline_id", help="Pipeline ID")

    # list
    sub.add_parser("list", help="列出所有 pipeline")

    args = parser.parse_args()

    if args.command == "create":
        variables = {}
        for v in args.var:
            if "=" not in v:
                print(f"錯誤：變數格式應為 key=value，收到：{v}", file=sys.stderr)
                sys.exit(1)
            key, value = v.split("=", 1)
            variables[key] = value

        pipe_id, task_ids = create_pipeline(
            args.template, args.project, args.project_dir, variables, args.verify
        )
        print(f"Pipeline 已建立：{pipe_id}")
        print(f"產生 {len(task_ids)} 個任務：")
        for tid in task_ids:
            print(f"  - {tid}")

    elif args.command == "advance":
        result = advance_pipeline(args.pipeline_id)
        print(json.dumps(result, indent=2, ensure_ascii=False))

    elif args.command == "status":
        status = get_pipeline_status(args.pipeline_id)
        if status is None:
            print(f"Pipeline 不存在：{args.pipeline_id}", file=sys.stderr)
            sys.exit(1)
        print(json.dumps(status, indent=2, ensure_ascii=False, default=str))

    elif args.command == "list":
        pipes = list_pipelines()
        if not pipes:
            print("目前沒有任何 pipeline")
        else:
            print(json.dumps(pipes, indent=2, ensure_ascii=False, default=str))


if __name__ == "__main__":
    main()
