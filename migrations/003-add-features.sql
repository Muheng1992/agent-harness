-- 003-add-features.sql — 新增 output fingerprint + 控制參數
-- 用途：迴圈偵測（Loop Detection）、AI 評估器（Evaluator）、對齊檢查（Alignment Check）

-- 新增 output_fingerprint 到 runs 表（用於偵測重複輸出）
ALTER TABLE runs ADD COLUMN output_fingerprint TEXT;

-- 新增控制參數
INSERT OR IGNORE INTO control VALUES ('evaluate_roles', 'implementer,integrator', CURRENT_TIMESTAMP);
INSERT OR IGNORE INTO control VALUES ('evaluate_timeout', '300', CURRENT_TIMESTAMP);
INSERT OR IGNORE INTO control VALUES ('alignment_interval', '5', CURRENT_TIMESTAMP);

-- 索引：加速 fingerprint 比對查詢
CREATE INDEX IF NOT EXISTS idx_runs_output_fingerprint ON runs(task_id, output_fingerprint);
