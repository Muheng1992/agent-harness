-- schema.sql — Agent Harness Database Schema
-- SQLite WAL mode for concurrent read/write

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS tasks (
  id            TEXT PRIMARY KEY,
  project       TEXT NOT NULL,
  project_dir   TEXT,                -- 目標專案的絕對路徑（跨專案執行用）
  goal          TEXT NOT NULL,
  verify_cmd    TEXT,
  depends_on    TEXT DEFAULT '[]',   -- JSON array of task IDs
  touches       TEXT DEFAULT '[]',   -- JSON array of file paths
  status        TEXT DEFAULT 'pending'
                CHECK(status IN ('pending','running','pass','fail','escalated','skipped')),
  attempt_count INTEGER DEFAULT 0,
  max_attempts  INTEGER DEFAULT 5,
  assigned_worker INTEGER,
  error_class   TEXT,                -- 最近一次錯誤分類
  last_error    TEXT,                -- 最近一次錯誤摘要
  created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS runs (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id       TEXT REFERENCES tasks(id),
  worker_id     INTEGER,
  attempt       INTEGER,
  status        TEXT CHECK(status IN ('running','pass','fail','error')),
  prompt_hash   TEXT,
  claude_output TEXT,
  verify_output TEXT,
  error_class   TEXT,                -- build_fail / test_fail / timeout / rate_limit / merge_conflict / unknown
  duration_sec  REAL,
  started_at    DATETIME,
  finished_at   DATETIME
);

CREATE TABLE IF NOT EXISTS control (
  key           TEXT PRIMARY KEY,
  value         TEXT,
  updated_at    DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Default control values
INSERT OR IGNORE INTO control VALUES ('global_state', 'running', CURRENT_TIMESTAMP);
INSERT OR IGNORE INTO control VALUES ('max_parallel', '4', CURRENT_TIMESTAMP);
INSERT OR IGNORE INTO control VALUES ('cooldown_sec', '30', CURRENT_TIMESTAMP);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project);
CREATE INDEX IF NOT EXISTS idx_runs_task_id ON runs(task_id);
CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);
CREATE INDEX IF NOT EXISTS idx_runs_finished_at ON runs(finished_at);
