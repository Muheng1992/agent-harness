#!/usr/bin/env python3
"""healer.py — Error classification and repair strategy for the Agent Harness.

Reads failure output, classifies the error, and outputs a JSON action
that tells the orchestrator how to proceed.
"""

import argparse
import json
import os
import re
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


def classify_error(failure_text: str) -> tuple:
    """Classify failure text into an error class.

    Returns (error_class, pattern_matched).
    """
    text_lower = failure_text.lower()

    if "evaluator:" in text_lower or "request_changes" in text_lower:
        return "evaluator_reject", "evaluator_reject"
    if "429" in text_lower or "rate limit" in text_lower:
        return "rate_limit", "rate_limit"
    if "merge conflict" in text_lower:
        return "merge_conflict", "merge_conflict"
    if "build failed" in text_lower:
        return "build_fail", "build_fail"
    if "test failed" in text_lower:
        return "test_fail", "test_fail"
    return "unknown", None


def decide_action(
    error_class: str,
    failure_text: str,
    attempt_count: int,
    max_attempts: int,
) -> dict:
    """Decide the repair action based on error class and attempt history.

    Returns a dict with action, extra_prompt, and cooldown_sec.
    """
    # Exhausted retries => escalate
    if attempt_count >= max_attempts:
        return {
            "action": "escalate",
            "extra_prompt": "This task has exhausted all retry attempts. Manual intervention required.",
            "cooldown_sec": 0,
        }

    # High attempt count => force root cause analysis
    root_cause_prefix = ""
    if attempt_count >= 3:
        root_cause_prefix = (
            "IMPORTANT: This task has failed multiple times. "
            "Before attempting a fix, analyze the root cause of the failures "
            "by reviewing the error history. Do NOT repeat previous approaches. "
        )

    tail = failure_text[-2000:] if len(failure_text) > 2000 else failure_text

    if error_class == "looping":
        # 策略輪替：根據嘗試次數選擇不同策略
        strategy_index = attempt_count % 3
        if strategy_index == 0:
            # 策略 1：切換角色（implementer → debugger）
            return {
                "action": "retry_with_role_switch",
                "new_role": "debugger",
                "extra_prompt": (
                    "前幾次嘗試都產出相同的結果，表示方法有根本性問題。"
                    "請用除錯專家的思維，先分析根因再嘗試完全不同的實作方式。\n"
                    + tail
                ),
                "cooldown_sec": 0,
            }
        elif strategy_index == 1:
            # 策略 2：強制不同方法
            return {
                "action": "retry_with_context",
                "extra_prompt": (
                    "嚴禁使用與之前相同的方法。列出 3 種完全不同的替代方案，"
                    "選擇最可行的一種實施。先前失敗的嘗試：\n"
                    + tail
                ),
                "cooldown_sec": 0,
            }
        else:
            # 策略 3：生成研究子任務
            return {
                "action": "spawn_research",
                "extra_prompt": "反覆失敗，需要先研究問題再重試。",
                "cooldown_sec": 0,
            }

    if error_class == "evaluator_reject":
        return {
            "action": "retry_with_context",
            "extra_prompt": (
                root_cause_prefix
                + "AI 評審員要求修改。以下是具體問題：\n"
                + tail
            ),
            "cooldown_sec": 0,
        }

    if error_class == "rate_limit":
        return {
            "action": "retry_after_cooldown",
            "extra_prompt": root_cause_prefix + "Rate limit hit. Retrying after cooldown.",
            "cooldown_sec": 120,
        }

    if error_class == "build_fail":
        return {
            "action": "retry_with_context",
            "extra_prompt": (
                root_cause_prefix
                + "Build failed. Here is the tail of the build output:\n"
                + tail
            ),
            "cooldown_sec": 0,
        }

    if error_class == "test_fail":
        return {
            "action": "retry_with_context",
            "extra_prompt": (
                root_cause_prefix
                + "Tests failed. Here is the tail of the test output:\n"
                + tail
            ),
            "cooldown_sec": 0,
        }

    if error_class == "merge_conflict":
        return {
            "action": "retry_with_context",
            "extra_prompt": (
                root_cause_prefix
                + "Merge conflict detected. Resolve conflicts before proceeding:\n"
                + tail
            ),
            "cooldown_sec": 0,
        }

    # Default: unknown error
    return {
        "action": "retry",
        "extra_prompt": root_cause_prefix or "",
        "cooldown_sec": 0,
    }


def heal(task_id: str, failure_file: str) -> dict:
    """Main healing logic: classify error, decide action, update DB.

    Returns the action dict.
    """
    failure_path = Path(failure_file)
    if not failure_path.exists():
        print(f"Error: failure file not found: {failure_file}", file=sys.stderr)
        sys.exit(1)

    failure_text = failure_path.read_text(encoding="utf-8")

    conn = get_connection()
    try:
        task = conn.execute(
            "SELECT * FROM tasks WHERE id = ?", (task_id,)
        ).fetchone()
        if task is None:
            print(f"Error: task not found: {task_id}", file=sys.stderr)
            sys.exit(1)

        attempt_count = task["attempt_count"]
        max_attempts = task["max_attempts"]

        # 先檢查 watchdog 是否已標記為 looping（優先於文字分類）
        current_error_class = task["error_class"]
        if current_error_class == "looping":
            error_class = "looping"
        else:
            error_class, _ = classify_error(failure_text)
        action = decide_action(error_class, failure_text, attempt_count, max_attempts)

        # Update error_class in the database
        conn.execute(
            """UPDATE tasks
               SET error_class = ?,
                   updated_at = ?
               WHERE id = ?""",
            (error_class, datetime.utcnow().isoformat(), task_id),
        )
        conn.commit()

        return action
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(
        description="Error classification and repair strategy"
    )
    parser.add_argument("task_id", help="Task ID to heal")
    parser.add_argument("failure_output_file", help="File containing failure output")

    args = parser.parse_args()
    action = heal(args.task_id, args.failure_output_file)
    print(json.dumps(action, indent=2))


if __name__ == "__main__":
    main()
