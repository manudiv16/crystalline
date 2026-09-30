-- Migration 0002: daemon execution claims
-- Additive lease columns; schema_migrations records version 2 atomically.
ALTER TABLE execution_states ADD COLUMN claimed_by TEXT;
ALTER TABLE execution_states ADD COLUMN claimed_at INTEGER;
CREATE INDEX IF NOT EXISTS idx_exec_states_claim
    ON execution_states(status, claimed_at, created_at);
