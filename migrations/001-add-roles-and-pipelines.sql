-- Migration 001: 新增 role/pipeline 相關欄位與 pipelines 表
-- 適用於已存在的資料庫，可安全重複執行（冪等）

-- 為 tasks 表新增欄位（先檢查欄位是否存在，不存在才加）
-- SQLite 不支援 ALTER TABLE ADD COLUMN IF NOT EXISTS，
-- 故透過 PRAGMA table_info 搭配 INSERT+SELECT 無法在純 SQL 實現。
-- 以下每條 ALTER TABLE 獨立執行；若欄位已存在，SQLite 會回傳
-- "duplicate column name" 錯誤，應用層應忽略此錯誤繼續執行。
--
-- 執行方式建議（bash）：
--   while IFS= read -r stmt; do
--     sqlite3 harness.db "$stmt" 2>/dev/null || true
--   done < <(grep -E '^ALTER TABLE' migrations/001-add-roles-and-pipelines.sql)
--   sqlite3 harness.db < <(grep -v '^ALTER TABLE' migrations/001-add-roles-and-pipelines.sql | grep -v '^--' | grep -v '^\s*$')

ALTER TABLE tasks ADD COLUMN role TEXT DEFAULT 'implementer';
ALTER TABLE tasks ADD COLUMN stage TEXT;
ALTER TABLE tasks ADD COLUMN pipeline_id TEXT;
ALTER TABLE tasks ADD COLUMN spawned_by TEXT;

-- 建立 pipelines 表（IF NOT EXISTS 確保冪等）
CREATE TABLE IF NOT EXISTS pipelines (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  project       TEXT NOT NULL,
  template      TEXT,
  config        TEXT DEFAULT '{}',
  status        TEXT DEFAULT 'active'
                CHECK(status IN ('active','completed','failed','paused')),
  created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- 新增索引（IF NOT EXISTS 確保冪等）
CREATE INDEX IF NOT EXISTS idx_tasks_role ON tasks(role);
CREATE INDEX IF NOT EXISTS idx_tasks_pipeline_id ON tasks(pipeline_id);
CREATE INDEX IF NOT EXISTS idx_pipelines_status ON pipelines(status);
