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
  role          TEXT DEFAULT 'implementer', -- 指派角色（對應 roles/*.md）
  stage         TEXT,                -- pipeline 階段（research/design/implement/test/review）
  pipeline_id   TEXT,                -- 所屬 pipeline 群組 ID
  spawned_by    TEXT,                -- 觸發此任務的上游任務 ID
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

CREATE TABLE IF NOT EXISTS pipelines (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  project       TEXT NOT NULL,
  template      TEXT,                -- 使用的 pipeline 模板名稱
  config        TEXT DEFAULT '{}',   -- JSON 配置（變數替換等）
  status        TEXT DEFAULT 'active'
                CHECK(status IN ('active','completed','failed','paused')),
  created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS router_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  action TEXT NOT NULL CHECK(action IN ('FIX','BUILD','REFACTOR','EXPLORE','IDLE','ESCALATE')),
  reason TEXT,
  feature_id TEXT,          -- BUILD 時對應的 roadmap feature ID
  task_ids TEXT DEFAULT '[]', -- JSON array of generated task IDs
  tech_debt_score INTEGER,
  test_status TEXT,          -- PASS / FAIL / NO_TESTS
  consecutive_fixes INTEGER DEFAULT 0,
  state_summary TEXT,        -- 精簡的狀態摘要
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project);
CREATE INDEX IF NOT EXISTS idx_runs_task_id ON runs(task_id);
CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);
CREATE INDEX IF NOT EXISTS idx_runs_finished_at ON runs(finished_at);
CREATE INDEX IF NOT EXISTS idx_tasks_role ON tasks(role);
CREATE INDEX IF NOT EXISTS idx_tasks_pipeline_id ON tasks(pipeline_id);
CREATE INDEX IF NOT EXISTS idx_pipelines_status ON pipelines(status);
CREATE INDEX IF NOT EXISTS idx_router_decisions_action ON router_decisions(action);
CREATE INDEX IF NOT EXISTS idx_router_decisions_created_at ON router_decisions(created_at);
