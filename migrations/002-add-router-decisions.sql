-- Migration 002: Add router_decisions table
CREATE TABLE IF NOT EXISTS router_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  action TEXT NOT NULL,
  reason TEXT,
  feature_id TEXT,
  task_ids TEXT DEFAULT '[]',
  tech_debt_score INTEGER,
  test_status TEXT,
  consecutive_fixes INTEGER DEFAULT 0,
  state_summary TEXT,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_router_decisions_action ON router_decisions(action);
CREATE INDEX IF NOT EXISTS idx_router_decisions_created_at ON router_decisions(created_at);
