import gleam/int
import gleam/list
import gleam/result
import gleam/string
import sacrum_gleam/db/connection.{type DbConnection, type DbError}

/// Embedded migration runner.
///
/// The migration SQL is compiled into the binary via `init_sql` (generated from
/// and kept in sync with `migrations/0001_init.sql`) so the engine stays
/// self-contained and does not need the filesystem at runtime.
pub type Migration {
  Migration(version: Int, name: String, sql: String)
}

pub type MigrationError {
  DbError(error: DbError)
  AlreadyApplied(version: Int)
  FailedAt(version: Int, message: String)
}

/// Table used to record which migrations have been applied.
const migrations_table: String = "schema_migrations"

/// Create the migrations bookkeeping table if it does not exist yet.
fn create_migrations_table(conn: DbConnection) -> Result(Nil, DbError) {
  connection.execute(
    conn,
    "CREATE TABLE IF NOT EXISTS "
      <> migrations_table
      <> " ("
      <> "version INTEGER PRIMARY KEY,"
      <> "name TEXT NOT NULL,"
      <> "applied_at INTEGER NOT NULL"
      <> ")",
    [],
  )
}

/// Highest applied migration version, or 0 when none has run yet.
///
/// `MAX(version)` returns NULL on an empty table, so `COALESCE` keeps the
/// result an integer that can be read straight out of the row value.
fn current_version(conn: DbConnection) -> Result(Int, DbError) {
  use rows <- result.try(
    connection.query(
      conn,
      "SELECT COALESCE(MAX(version), 0) AS version FROM " <> migrations_table,
      [],
    ),
  )

  Ok(case rows {
    [[connection.IntVal(version)], ..] -> version
    _ -> 0
  })
}

/// Apply every migration whose version is greater than the last applied one,
/// in ascending order. Returns the versions applied by this call.
pub fn migrate(
  conn: DbConnection,
  migrations: List(Migration),
) -> Result(List(Int), MigrationError) {
  use _ <- result.try(
    create_migrations_table(conn) |> result.map_error(DbError),
  )
  use current <- result.try(current_version(conn) |> result.map_error(DbError))

  let pending =
    migrations
    |> list.filter(fn(migration) { migration.version > current })
    |> list.sort(fn(a, b) { int.compare(a.version, b.version) })

  apply_pending(conn, pending, [])
}

/// Apply the built-in migrations. Convenience wrapper over `migrate`.
pub fn run_migrations(conn: DbConnection) -> Result(List(Int), MigrationError) {
  migrate(conn, builtin_migrations())
}

fn apply_pending(
  conn: DbConnection,
  remaining: List(Migration),
  applied: List(Int),
) -> Result(List(Int), MigrationError) {
  case remaining {
    [] -> Ok(list.reverse(applied))
    [migration, ..rest] -> {
      use _ <- result.try(apply_migration(conn, migration))
      apply_pending(conn, rest, [migration.version, ..applied])
    }
  }
}

/// Execute one migration and record it atomically.
///
/// The schema statements and the bookkeeping INSERT run in a single
/// transaction, so a failure can never leave a migration half-applied.
fn apply_migration(
  conn: DbConnection,
  migration: Migration,
) -> Result(Nil, MigrationError) {
  let record_applied =
    "INSERT INTO "
    <> migrations_table
    <> " (version, name, applied_at) VALUES ("
    <> int.to_string(migration.version)
    <> ", '"
    <> string.replace(migration.name, "'", "''")
    <> "', CAST(strftime('%s', 'now') AS INTEGER))"

  let statements =
    migration.sql
    |> split_statements
    |> list.append([record_applied])

  connection.transaction(conn, statements)
  |> result.map_error(fn(error) {
    FailedAt(
      version: migration.version,
      message: connection.error_to_string(error),
    )
  })
}

/// Split a migration script into individual statements.
///
/// The bundled schema never uses a semicolon inside a string literal or a
/// comment, so a plain split on `;` is sufficient and predictable.
fn split_statements(sql: String) -> List(String) {
  sql
  |> string.split(on: ";")
  |> list.map(string.trim)
  |> list.filter(fn(statement) { !string.is_empty(statement) })
}

/// The built-in migrations, embedded at compile time.
pub fn builtin_migrations() -> List(Migration) {
  [Migration(version: 1, name: "init", sql: init_sql)]
}

/// SQL from `migrations/0001_init.sql`, embedded at compile time.
const init_sql: String = "-- Migration 0001: Initial schema for embedded Sacrum
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
    \"order\"         INTEGER NOT NULL DEFAULT 0,
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
    event_type          TEXT NOT NULL,       -- e.g. \"text\", \"usage\", \"tool_use\"
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
CREATE INDEX IF NOT EXISTS idx_artifacts_name ON artifacts(logical_name);"
