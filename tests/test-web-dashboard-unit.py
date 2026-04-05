#!/usr/bin/env python3
"""test-web-dashboard-unit.py — Web Dashboard Python Unit Test

用 unittest 模組測試 web-dashboard 內部函式：
- DB 連線、safe_query、URL routing、JSON 回傳格式、篩選邏輯、Graph 建構
"""

import importlib
import importlib.machinery
import importlib.util
import json
import os
import re
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

# ── 載入 web-dashboard 模組（檔名含 hyphen，需用 importlib）────

HARNESS_DIR = Path(__file__).resolve().parent.parent
DASHBOARD_PATH = HARNESS_DIR / "web-dashboard"

spec = importlib.util.spec_from_file_location(
    "web_dashboard", DASHBOARD_PATH,
    submodule_search_locations=[],
    loader=importlib.machinery.SourceFileLoader("web_dashboard", str(DASHBOARD_PATH)),
)
wd = importlib.util.module_from_spec(spec)
# 防止 main() 被執行
sys.argv = ["web-dashboard"]
spec.loader.exec_module(wd)


def create_test_db(with_data=False):
    """建立臨時測試 DB，回傳路徑。"""
    fd, db_path = tempfile.mkstemp(suffix=".db")
    os.close(fd)

    conn = sqlite3.connect(db_path)
    # 載入 schema
    schema_path = HARNESS_DIR / "schema.sql"
    conn.executescript(schema_path.read_text())

    # 載入 migrations
    migrations_dir = HARNESS_DIR / "migrations"
    if migrations_dir.exists():
        for mig in sorted(migrations_dir.glob("*.sql")):
            try:
                conn.executescript(mig.read_text())
            except sqlite3.OperationalError:
                pass  # 忽略重複 ALTER 等

    if with_data:
        conn.executescript("""
            INSERT INTO tasks (id, project, goal, status, role, attempt_count, max_attempts, spawned_by)
            VALUES
              ('task-001', 'proj-a', '實作功能 A', 'pass', 'implementer', 2, 5, NULL),
              ('task-002', 'proj-a', '撰寫測試 B', 'fail', 'tester', 1, 5, 'task-001'),
              ('task-003', 'proj-b', '設計 API C', 'pending', 'architect', 0, 5, NULL),
              ('task-004', 'proj-a', '子任務 D', 'running', 'implementer', 1, 5, 'task-001');

            INSERT INTO runs (task_id, attempt, status, duration_sec, started_at, finished_at)
            VALUES
              ('task-001', 1, 'fail', 12.5, '2025-01-01 10:00:00', '2025-01-01 10:00:12'),
              ('task-001', 2, 'pass', 8.3, '2025-01-01 10:01:00', '2025-01-01 10:01:08'),
              ('task-002', 1, 'fail', 5.0, '2025-01-01 11:00:00', '2025-01-01 11:00:05');

            INSERT INTO pipelines (id, name, project, status)
            VALUES ('pipe-001', '測試 Pipeline', 'proj-a', 'active');

            INSERT INTO router_decisions (action, reason, task_ids, tech_debt_score, test_status)
            VALUES ('BUILD', '功能 A 需要建構', '["task-001"]', 3, 'PASS');

            INSERT INTO audit_log (task_id, event_type, event_data, actor)
            VALUES
              ('task-001', 'healer_decision', '{"action":"retry"}', 'healer'),
              ('task-002', 'role_switch', '{"from":"implementer","to":"tester"}', 'orchestrator');
        """)
    conn.commit()
    conn.close()
    return db_path


class TestGetConnection(unittest.TestCase):
    """測試 get_connection() 函式。"""

    def test_connection_success(self):
        """DB 存在時應成功回傳連線物件。"""
        db_path = create_test_db()
        try:
            original = wd.DB_PATH
            wd.DB_PATH = db_path
            conn = wd.get_connection()
            self.assertIsNotNone(conn)
            conn.close()
        finally:
            wd.DB_PATH = original
            os.unlink(db_path)

    def test_connection_nonexistent_db(self):
        """DB 不存在時應回傳 None。"""
        original = wd.DB_PATH
        try:
            wd.DB_PATH = "/tmp/nonexistent-db-12345.db"
            conn = wd.get_connection()
            self.assertIsNone(conn)
        finally:
            wd.DB_PATH = original

    def test_connection_row_factory(self):
        """連線應設定 row_factory 為 sqlite3.Row。"""
        db_path = create_test_db()
        try:
            original = wd.DB_PATH
            wd.DB_PATH = db_path
            conn = wd.get_connection()
            self.assertEqual(conn.row_factory, sqlite3.Row)
            conn.close()
        finally:
            wd.DB_PATH = original
            os.unlink(db_path)


class TestSafeQuery(unittest.TestCase):
    """測試 safe_query() 函式。"""

    def setUp(self):
        self.db_path = create_test_db(with_data=True)
        self.original = wd.DB_PATH
        wd.DB_PATH = self.db_path

    def tearDown(self):
        wd.DB_PATH = self.original
        os.unlink(self.db_path)

    def test_normal_query(self):
        """正常查詢應回傳結果。"""
        conn = wd.get_connection()
        rows = wd.safe_query(conn, "SELECT * FROM tasks")
        self.assertEqual(len(rows), 4)
        conn.close()

    def test_query_with_params(self):
        """帶參數查詢應正確篩選。"""
        conn = wd.get_connection()
        rows = wd.safe_query(conn, "SELECT * FROM tasks WHERE status = ?", ("pass",))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], "task-001")
        conn.close()

    def test_nonexistent_table(self):
        """查詢不存在的 table 應回傳空 list。"""
        conn = wd.get_connection()
        rows = wd.safe_query(conn, "SELECT * FROM nonexistent_table")
        self.assertEqual(rows, [])
        conn.close()

    def test_invalid_sql(self):
        """無效 SQL 應回傳空 list 而非拋出例外。"""
        conn = wd.get_connection()
        rows = wd.safe_query(conn, "INVALID SQL SYNTAX")
        self.assertEqual(rows, [])
        conn.close()


class TestSafeQueryOne(unittest.TestCase):
    """測試 safe_query_one() 函式。"""

    def setUp(self):
        self.db_path = create_test_db(with_data=True)
        self.original = wd.DB_PATH
        wd.DB_PATH = self.db_path

    def tearDown(self):
        wd.DB_PATH = self.original
        os.unlink(self.db_path)

    def test_returns_single_row(self):
        """應回傳單一 Row 物件。"""
        conn = wd.get_connection()
        row = wd.safe_query_one(conn, "SELECT * FROM tasks WHERE id = ?", ("task-001",))
        self.assertIsNotNone(row)
        self.assertEqual(row["id"], "task-001")
        conn.close()

    def test_nonexistent_table_returns_none(self):
        """不存在的 table 應回傳 None。"""
        conn = wd.get_connection()
        row = wd.safe_query_one(conn, "SELECT * FROM no_such_table")
        self.assertIsNone(row)
        conn.close()


class TestHelperFunctions(unittest.TestCase):
    """測試 row_to_dict、rows_to_list、parse_json_field 等工具函式。"""

    def test_row_to_dict_none(self):
        """row_to_dict(None) 應回傳 None。"""
        self.assertIsNone(wd.row_to_dict(None))

    def test_row_to_dict_converts(self):
        """row_to_dict 應將 sqlite3.Row 轉為 dict。"""
        db_path = create_test_db(with_data=True)
        try:
            conn = sqlite3.connect(db_path)
            conn.row_factory = sqlite3.Row
            row = conn.execute("SELECT * FROM tasks WHERE id = 'task-001'").fetchone()
            d = wd.row_to_dict(row)
            self.assertIsInstance(d, dict)
            self.assertEqual(d["id"], "task-001")
            conn.close()
        finally:
            os.unlink(db_path)

    def test_rows_to_list(self):
        """rows_to_list 應將 Row list 轉為 dict list。"""
        db_path = create_test_db(with_data=True)
        try:
            conn = sqlite3.connect(db_path)
            conn.row_factory = sqlite3.Row
            rows = conn.execute("SELECT * FROM tasks").fetchall()
            result = wd.rows_to_list(rows)
            self.assertIsInstance(result, list)
            self.assertTrue(all(isinstance(r, dict) for r in result))
            self.assertEqual(len(result), 4)
            conn.close()
        finally:
            os.unlink(db_path)

    def test_parse_json_field_valid(self):
        """有效 JSON 字串應正確 parse。"""
        self.assertEqual(wd.parse_json_field('["a","b"]'), ["a", "b"])
        self.assertEqual(wd.parse_json_field('{"k":"v"}'), {"k": "v"})

    def test_parse_json_field_invalid(self):
        """無效 JSON 應回傳原值。"""
        self.assertEqual(wd.parse_json_field("not json"), "not json")

    def test_parse_json_field_none(self):
        """None 應回傳 None。"""
        self.assertIsNone(wd.parse_json_field(None))


class TestURLRouting(unittest.TestCase):
    """測試 ROUTES 中的 URL pattern 是否正確 match。"""

    def test_stats_route(self):
        """/api/stats 應 match。"""
        matched = self._match("/api/stats")
        self.assertIsNotNone(matched)
        self.assertEqual(matched[2], wd.handle_stats)

    def test_tasks_route(self):
        """/api/tasks 應 match。"""
        matched = self._match("/api/tasks")
        self.assertIsNotNone(matched)
        self.assertEqual(matched[2], wd.handle_tasks)

    def test_task_runs_route(self):
        """/api/tasks/task-001/runs 應 match 並擷取 task_id。"""
        matched = self._match("/api/tasks/task-001/runs")
        self.assertIsNotNone(matched)
        self.assertEqual(matched[2], wd.handle_task_runs)
        self.assertEqual(matched[0].match("/api/tasks/task-001/runs").group(1), "task-001")

    def test_task_detail_route(self):
        """/api/tasks/task-001 應 match handle_task_detail。"""
        matched = self._match("/api/tasks/task-001")
        self.assertIsNotNone(matched)
        self.assertEqual(matched[2], wd.handle_task_detail)

    def test_graph_route(self):
        """/api/graph 應 match。"""
        matched = self._match("/api/graph")
        self.assertIsNotNone(matched)
        self.assertEqual(matched[2], wd.handle_graph)

    def test_audit_route(self):
        """/api/audit 應 match。"""
        matched = self._match("/api/audit")
        self.assertIsNotNone(matched)
        self.assertEqual(matched[2], wd.handle_audit)

    def test_pipelines_route(self):
        """/api/pipelines 應 match。"""
        matched = self._match("/api/pipelines")
        self.assertIsNotNone(matched)
        self.assertEqual(matched[2], wd.handle_pipelines)

    def test_router_decisions_route(self):
        """/api/router-decisions 應 match。"""
        matched = self._match("/api/router-decisions")
        self.assertIsNotNone(matched)
        self.assertEqual(matched[2], wd.handle_router_decisions)

    def test_no_match(self):
        """/api/nonexistent 不應 match 任何 route。"""
        matched = self._match("/api/nonexistent")
        self.assertIsNone(matched)

    def test_tasks_runs_before_detail(self):
        """/api/tasks/x/runs 應優先 match handle_task_runs 而非 handle_task_detail。"""
        for pattern, method, handler in wd.ROUTES:
            m = pattern.match("/api/tasks/task-001/runs")
            if m:
                self.assertEqual(handler, wd.handle_task_runs)
                break

    def _match(self, path):
        """找到第一個 match 的 route，回傳 (pattern, method, handler) 或 None。"""
        for pattern, method, handler in wd.ROUTES:
            if pattern.match(path):
                return (pattern, method, handler)
        return None


class TestHandleStats(unittest.TestCase):
    """測試 handle_stats() 回傳格式。"""

    def setUp(self):
        self.db_path = create_test_db(with_data=True)
        self.original = wd.DB_PATH
        wd.DB_PATH = self.db_path

    def tearDown(self):
        wd.DB_PATH = self.original
        os.unlink(self.db_path)

    def test_returns_correct_structure(self):
        """應包含 counts, pass_rate, total_runs, total_duration。"""
        result = wd.handle_stats()
        self.assertIn("counts", result)
        self.assertIn("pass_rate", result)
        self.assertIn("total_runs", result)
        self.assertIn("total_duration", result)

    def test_counts_values(self):
        """counts 應正確統計各 status。"""
        result = wd.handle_stats()
        counts = result["counts"]
        self.assertEqual(counts["pass"], 1)
        self.assertEqual(counts["fail"], 1)
        self.assertEqual(counts["pending"], 1)
        self.assertEqual(counts["running"], 1)

    def test_total_runs(self):
        """total_runs 應為 3。"""
        result = wd.handle_stats()
        self.assertEqual(result["total_runs"], 3)

    def test_no_db_returns_empty(self):
        """DB 不存在時應回傳空預設值。"""
        wd.DB_PATH = "/tmp/nonexistent.db"
        result = wd.handle_stats()
        self.assertEqual(result["counts"], {})
        self.assertEqual(result["pass_rate"], 0)


class TestHandleTasks(unittest.TestCase):
    """測試 handle_tasks() 篩選邏輯。"""

    def setUp(self):
        self.db_path = create_test_db(with_data=True)
        self.original = wd.DB_PATH
        wd.DB_PATH = self.db_path

    def tearDown(self):
        wd.DB_PATH = self.original
        os.unlink(self.db_path)

    def test_all_tasks(self):
        """無篩選時應回傳全部 4 筆。"""
        result = wd.handle_tasks({})
        self.assertEqual(len(result), 4)

    def test_filter_by_status(self):
        """依 status 篩選應回傳正確結果。"""
        result = wd.handle_tasks({"status": ["pass"]})
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["id"], "task-001")

    def test_filter_by_project(self):
        """依 project 篩選應回傳正確結果。"""
        result = wd.handle_tasks({"project": ["proj-a"]})
        self.assertEqual(len(result), 3)
        self.assertTrue(all(t["project"] == "proj-a" for t in result))

    def test_filter_by_role(self):
        """依 role 篩選應回傳正確結果。"""
        result = wd.handle_tasks({"role": ["tester"]})
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["id"], "task-002")

    def test_combined_filters(self):
        """多重篩選應同時生效。"""
        result = wd.handle_tasks({"project": ["proj-a"], "status": ["fail"]})
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["id"], "task-002")

    def test_json_fields_parsed(self):
        """depends_on 和 touches 應被 parse 為 Python 物件。"""
        result = wd.handle_tasks({})
        for task in result:
            # 預設值為 '[]'，parse 後應為 list
            self.assertIsInstance(task["depends_on"], list)
            self.assertIsInstance(task["touches"], list)

    def test_no_db_returns_empty(self):
        """DB 不存在時應回傳空 list。"""
        wd.DB_PATH = "/tmp/nonexistent.db"
        result = wd.handle_tasks({})
        self.assertEqual(result, [])


class TestHandleTaskRuns(unittest.TestCase):
    """測試 handle_task_runs() 回傳格式。"""

    def setUp(self):
        self.db_path = create_test_db(with_data=True)
        self.original = wd.DB_PATH
        wd.DB_PATH = self.db_path

    def tearDown(self):
        wd.DB_PATH = self.original
        os.unlink(self.db_path)

    def test_returns_runs_for_task(self):
        """應回傳指定任務的 runs。"""
        result = wd.handle_task_runs("task-001")
        self.assertEqual(len(result), 2)

    def test_empty_for_unknown_task(self):
        """不存在的 task 應回傳空 list。"""
        result = wd.handle_task_runs("nonexistent")
        self.assertEqual(result, [])

    def test_runs_ordered_by_attempt(self):
        """runs 應依 attempt 升序排列。"""
        result = wd.handle_task_runs("task-001")
        attempts = [r["attempt"] for r in result]
        self.assertEqual(attempts, sorted(attempts))


class TestHandleGraph(unittest.TestCase):
    """測試 handle_graph() spawned_by 關係圖建構。"""

    def setUp(self):
        self.db_path = create_test_db(with_data=True)
        self.original = wd.DB_PATH
        wd.DB_PATH = self.db_path

    def tearDown(self):
        wd.DB_PATH = self.original
        os.unlink(self.db_path)

    def test_returns_nodes_and_edges(self):
        """應回傳包含 nodes 和 edges 的 dict。"""
        result = wd.handle_graph()
        self.assertIn("nodes", result)
        self.assertIn("edges", result)

    def test_edges_reflect_spawned_by(self):
        """edges 應反映 spawned_by 關係。"""
        result = wd.handle_graph()
        edges = result["edges"]
        # task-002 和 task-004 都由 task-001 spawn
        edge_pairs = [(e["from"], e["to"]) for e in edges]
        self.assertIn(("task-001", "task-002"), edge_pairs)
        self.assertIn(("task-001", "task-004"), edge_pairs)

    def test_parent_included_in_nodes(self):
        """parent 節點（task-001）應在 nodes 中。"""
        result = wd.handle_graph()
        node_ids = [n["id"] for n in result["nodes"]]
        self.assertIn("task-001", node_ids)

    def test_children_included_in_nodes(self):
        """子節點應在 nodes 中。"""
        result = wd.handle_graph()
        node_ids = [n["id"] for n in result["nodes"]]
        self.assertIn("task-002", node_ids)
        self.assertIn("task-004", node_ids)

    def test_no_spawned_returns_empty(self):
        """無 spawned_by 關係時應回傳空 nodes/edges。"""
        # 建一個只有無 parent 任務的 DB
        db_path = create_test_db(with_data=False)
        original = wd.DB_PATH
        try:
            wd.DB_PATH = db_path
            conn = sqlite3.connect(db_path)
            conn.execute(
                "INSERT INTO tasks (id, project, goal, status) VALUES ('t1', 'p', 'g', 'pass')"
            )
            conn.commit()
            conn.close()

            result = wd.handle_graph()
            self.assertEqual(result["nodes"], [])
            self.assertEqual(result["edges"], [])
        finally:
            wd.DB_PATH = original
            os.unlink(db_path)

    def test_no_db_returns_empty(self):
        """DB 不存在時應回傳空 nodes/edges。"""
        wd.DB_PATH = "/tmp/nonexistent.db"
        result = wd.handle_graph()
        self.assertEqual(result, {"nodes": [], "edges": []})


class TestHandleAudit(unittest.TestCase):
    """測試 handle_audit() 回傳格式。"""

    def setUp(self):
        self.db_path = create_test_db(with_data=True)
        self.original = wd.DB_PATH
        wd.DB_PATH = self.db_path

    def tearDown(self):
        wd.DB_PATH = self.original
        os.unlink(self.db_path)

    def test_returns_all_logs(self):
        """無篩選時應回傳全部 audit log。"""
        result = wd.handle_audit({})
        self.assertEqual(len(result), 2)

    def test_filter_by_task_id(self):
        """依 task_id 篩選應回傳正確結果。"""
        result = wd.handle_audit({"task_id": ["task-001"]})
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["task_id"], "task-001")

    def test_filter_by_event_type(self):
        """依 event_type 篩選應回傳正確結果。"""
        result = wd.handle_audit({"event_type": ["role_switch"]})
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["event_type"], "role_switch")

    def test_event_data_parsed(self):
        """event_data 應被 parse 為 Python 物件。"""
        result = wd.handle_audit({})
        for log in result:
            if log["event_type"] == "healer_decision":
                self.assertIsInstance(log["event_data"], dict)
                self.assertEqual(log["event_data"]["action"], "retry")


class TestHandlePipelines(unittest.TestCase):
    """測試 handle_pipelines() 回傳格式。"""

    def setUp(self):
        self.db_path = create_test_db(with_data=True)
        self.original = wd.DB_PATH
        wd.DB_PATH = self.db_path

    def tearDown(self):
        wd.DB_PATH = self.original
        os.unlink(self.db_path)

    def test_returns_pipelines(self):
        """應回傳 pipeline 列表。"""
        result = wd.handle_pipelines()
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["id"], "pipe-001")


class TestHandleRouterDecisions(unittest.TestCase):
    """測試 handle_router_decisions() 回傳格式。"""

    def setUp(self):
        self.db_path = create_test_db(with_data=True)
        self.original = wd.DB_PATH
        wd.DB_PATH = self.db_path

    def tearDown(self):
        wd.DB_PATH = self.original
        os.unlink(self.db_path)

    def test_returns_decisions(self):
        """應回傳 router decision 列表。"""
        result = wd.handle_router_decisions()
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["action"], "BUILD")

    def test_task_ids_parsed(self):
        """task_ids 應被 parse 為 list。"""
        result = wd.handle_router_decisions()
        self.assertIsInstance(result[0]["task_ids"], list)
        self.assertEqual(result[0]["task_ids"], ["task-001"])


if __name__ == "__main__":
    unittest.main()
