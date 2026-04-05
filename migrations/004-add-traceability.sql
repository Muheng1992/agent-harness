-- 004-add-traceability.sql — 完整追蹤性：prompt 儲存 + audit log
-- 解決問題：實際送出的 prompt 從未被記錄，healer 決策和角色切換也無紀錄

-- 新增 prompt_text 到 runs 表（儲存實際送出的完整 prompt）
ALTER TABLE runs ADD COLUMN prompt_text TEXT;

-- 修正語意：原 prompt_hash 實際存的是 output hash，新增真正的 prompt hash
ALTER TABLE runs ADD COLUMN input_prompt_hash TEXT;

-- 審計日誌表：記錄所有系統級決策（healer 策略、角色切換、alignment 修正等）
CREATE TABLE IF NOT EXISTS audit_log (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id       TEXT,                -- 關聯的任務 ID
  event_type    TEXT NOT NULL,       -- healer_decision / role_switch / evaluator_verdict / alignment_correction / spawn_research
  event_data    TEXT DEFAULT '{}',   -- JSON: 決策的完整內容
  actor         TEXT,                -- 觸發者（orchestrator / watchdog / healer / evaluator）
  created_at    DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_audit_log_task_id ON audit_log(task_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_event_type ON audit_log(event_type);
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON audit_log(created_at);
