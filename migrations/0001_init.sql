-- Migration 0001: Initial schema for embedded Sacrum
-- Designed for libsql/Turso compatibility.
-- All IDs are text (UUID strings). Timestamps are Unix epoch (INTEGER).

-- ─── Tasks ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tasks (
    id              TEXT PRIMARY KEY,
    short_id        TEXT NOT NULL UNIQUE,
    title           TEXT NOT NULL,
    description     TEXT NOT NULL DEFAULT '',
    level           TEXT NOT NULL CHECK (level IN ('epic', 'ticket', 'task')),
    priority        TEXT NOT NULL DEFAULT 'medium'
                        CHECK (priority IN ('low', 'medium', 'high', 'critical')),
    status          TEXT NOT NULL DEFAULT 'todo'
                        CHECK (status IN ('todo', 'in_progress', 'blocked', 'done', 'cancelled', 'archived')),
    tags            TEXT NOT NULL DEFAULT '[]',       -- JSON array of strings
    parent_id       TEXT REFERENCES tasks(id) ON DELETE SET NULL,
    flow_template_id TEXT REFERENCES flow_templates(id) ON DELETE SET NULL,
    flow_instance_id TEXT REFERENCES flow_instances(id) ON DELETE SET NULL,
    current_node_id TEXT,
    worktree        TEXT,
    archived        INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tasks_level ON tasks(level);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_id);
CREATE INDEX IF NOT EXISTS idx_tasks_flow_instance ON tasks(flow_instance_id);
CREATE INDEX IF NOT EXISTS idx_tasks_short_id ON tasks(short_id);

-- ─── Task Dependencies (DAG) ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS task_dependencies (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id     TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    depends_on  TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    UNIQUE(task_id, depends_on)
);

CREATE INDEX IF NOT EXISTS idx_task_deps_task ON task_dependencies(task_id);
CREATE INDEX IF NOT EXISTS idx_task_deps_depends_on ON task_dependencies(depends_on);

-- ─── Sections ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sections (
    id              TEXT PRIMARY KEY,
    task_id         TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    section_type    TEXT NOT NULL CHECK (section_type IN (
        'goal', 'context', 'current_behavior', 'desired_behavior',
        'checklist_item', 'testing_criterion', 'constraint',
        'anti_pattern', 'failure_test'
    )),
    content         TEXT NOT NULL,
    code_ref_path   TEXT,
    code_ref_line_start INTEGER,
    code_ref_line_end   INTEGER,
    code_ref_name       TEXT,
    code_ref_description TEXT,
    "order"         INTEGER NOT NULL DEFAULT 0,
    checklist_state TEXT CHECK (checklist_state IN ('done', 'undone')),
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sections_task ON sections(task_id);
CREATE INDEX IF NOT EXISTS idx_sections_type ON sections(section_type);

-- ─── Flow Templates ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS flow_templates (
    id                  TEXT PRIMARY KEY,
    name                TEXT NOT NULL,
    description         TEXT NOT NULL DEFAULT '',
    initial_node_id     TEXT NOT NULL,
    nodes_json          TEXT NOT NULL,   -- JSON object: node_id → Node
    transitions_json    TEXT NOT NULL DEFAULT '[]', -- JSON array of Transition
    on_done_template_id TEXT REFERENCES flow_templates(id) ON DELETE SET NULL,
    on_reject_template_id TEXT REFERENCES flow_templates(id) ON DELETE SET NULL,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_flow_templates_name ON flow_templates(name);

-- ─── Flow Instances ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS flow_instances (
    id                  TEXT PRIMARY KEY,
    template_id         TEXT NOT NULL REFERENCES flow_templates(id) ON DELETE RESTRICT,
    task_id             TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    initial_node_id     TEXT NOT NULL,
    nodes_json          TEXT NOT NULL,
    transitions_json    TEXT NOT NULL DEFAULT '[]',
    on_done_template_id TEXT,
    on_reject_template_id TEXT,
    created_at          INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_flow_instances_task ON flow_instances(task_id);
CREATE INDEX IF NOT EXISTS idx_flow_instances_template ON flow_instances(template_id);

-- ─── Execution State ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS execution_states (
    id                  TEXT PRIMARY KEY,
    flow_instance_id    TEXT NOT NULL REFERENCES flow_instances(id) ON DELETE CASCADE,
    task_id             TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    status              TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN (
                                'pending', 'running', 'awaiting_input',
                                'completed', 'rejected', 'failed', 'cancelled'
                            )),
    current_node_id     TEXT,
    loop_counters_json  TEXT NOT NULL DEFAULT '{}',  -- JSON object: loop_id → count
    variables_json      TEXT NOT NULL DEFAULT '{}',   -- JSON object: key → value
    parallel_active_json TEXT NOT NULL DEFAULT '[]',  -- JSON array of node IDs
    started_at          INTEGER,
    completed_at        INTEGER,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_exec_states_instance ON execution_states(flow_instance_id);
CREATE INDEX IF NOT EXISTS idx_exec_states_task ON execution_states(task_id);
CREATE INDEX IF NOT EXISTS idx_exec_states_status ON execution_states(status);

-- ─── Step Executions ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS step_executions (
    id                  TEXT PRIMARY KEY,
    flow_instance_id    TEXT NOT NULL REFERENCES flow_instances(id) ON DELETE CASCADE,
    execution_state_id  TEXT NOT NULL REFERENCES execution_states(id) ON DELETE CASCADE,
    node_id             TEXT NOT NULL,
    task_id             TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    status              TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN (
                                'pending', 'entered', 'in_progress',
                                'completed', 'failed', 'cancelled'
                            )),
    prompt              TEXT,
    output              TEXT,
    transition_result   TEXT,
    model               TEXT,
    input_tokens        INTEGER NOT NULL DEFAULT 0,
    output_tokens       INTEGER NOT NULL DEFAULT 0,
    cost                REAL NOT NULL DEFAULT 0.0,
    duration_ms         INTEGER NOT NULL DEFAULT 0,
    session_id          TEXT,
    created_at          INTEGER NOT NULL,
    completed_at        INTEGER
);

CREATE INDEX IF NOT EXISTS idx_step_exec_instance ON step_executions(flow_instance_id);
CREATE INDEX IF NOT EXISTS idx_step_exec_task ON step_executions(task_id);
CREATE INDEX IF NOT EXISTS idx_step_exec_status ON step_executions(status);

-- ─── Session Logs ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS session_logs (
    id                  TEXT PRIMARY KEY,
    step_execution_id   TEXT NOT NULL REFERENCES step_executions(id) ON DELETE CASCADE,
    task_id             TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    event_type          TEXT NOT NULL,       -- e.g. "text", "usage", "tool_use"
    payload_json        TEXT NOT NULL,        -- serialized HarnessEventV1
    sequence            INTEGER NOT NULL,     -- order within the session
    created_at          INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_session_logs_step ON session_logs(step_execution_id);
CREATE INDEX IF NOT EXISTS idx_session_logs_sequence ON session_logs(step_execution_id, sequence);

-- ─── Artifacts ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS artifacts (
    id                  TEXT PRIMARY KEY,
    task_id             TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    logical_name        TEXT NOT NULL,
    content_json        TEXT NOT NULL,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,
    UNIQUE(task_id, logical_name)
);

CREATE INDEX IF NOT EXISTS idx_artifacts_task ON artifacts(task_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_name ON artifacts(logical_name);
