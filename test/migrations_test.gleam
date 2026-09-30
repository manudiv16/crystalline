import gleam/list
import gleam/option.{None}
import gleeunit/should
import sacrum_gleam/db/connection
import sacrum_gleam/db/migrations
import sacrum_gleam/db/tasks as db_tasks
import sacrum_gleam/domain/task

// ─── Helpers ──────────────────────────────────────────────────────────────

fn db_table_names(conn: connection.DbConnection) -> List(String) {
  case
    connection.query(
      conn,
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
      [],
    )
  {
    Ok(rows) ->
      rows
      |> list.map(fn(row) {
        case row {
          [connection.TextVal(name), ..] -> name
          _ -> ""
        }
      })
    Error(_) -> []
  }
}

// ─── Acceptance tests ─────────────────────────────────────────────────────

/// Empty DB: first run creates the schema and applies all built-in versions.
pub fn first_run_applies_v1_test() {
  let assert Ok(conn) = connection.connect(":memory:", None)

  let assert Ok(applied) = migrations.run_migrations(conn)
  applied |> should.equal([1, 2, 3])

  let names = db_table_names(conn)
  let expected_tables = [
    "artifacts",
    "execution_states",
    "flow_instances",
    "flow_templates",
    "projects",
    "schema_migrations",
    "sections",
    "session_logs",
    "step_executions",
    "task_dependencies",
    "tasks",
  ]
  let missing =
    expected_tables
    |> list.filter(fn(name) { !list.contains(names, name) })
  missing |> should.equal([])
}

/// The bookkeeping row records version 1 with a real Unix timestamp.
pub fn first_run_records_v1_with_timestamp_test() {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok(_) = migrations.run_migrations(conn)

  let assert Ok(row) =
    connection.query_one(
      conn,
      "SELECT version, name, applied_at FROM schema_migrations WHERE version = 1",
      [],
    )
  let ok = case row {
    [
      connection.IntVal(1),
      connection.TextVal("init"),
      connection.IntVal(timestamp),
    ]
      if timestamp > 0
    -> True
    _ -> False
  }
  ok |> should.be_true
}

/// A second run is a no-op: every built-in migration is already applied.
pub fn second_run_is_noop_test() {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok([1, 2, 3]) = migrations.run_migrations(conn)

  let assert Ok(applied) = migrations.run_migrations(conn)
  applied |> should.equal([])

  let assert Ok(row) =
    connection.query_one(conn, "SELECT COUNT(*) FROM schema_migrations", [])
  row |> should.equal([connection.IntVal(3)])
}

/// A database stopped at v2 receives only the additive projects migration.
pub fn existing_schema_receives_projects_migration_test() {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert [init, claims, _projects] = migrations.builtin_migrations()
  let assert Ok([1, 2]) = migrations.migrate(conn, [init, claims])

  let assert Ok([3]) = migrations.run_migrations(conn)
  let assert Ok(columns) =
    connection.query(conn, "PRAGMA table_info(tasks)", [])
  let names =
    list.map(columns, fn(row) {
      case row {
        [_, connection.TextVal(name), ..] -> name
        _ -> ""
      }
    })
  assert list.contains(names, "project_id")
  connection.close(conn)
  Nil
}

/// Migration 0003 over a populated pre-projects database: existing tasks and
/// their child rows survive, tasks are attributed to the default project, the
/// stored short id is rewritten to the scoped form, and a second project can
/// then reuse the same user-visible short id through the real write path.
pub fn migration_0003_backfills_existing_rows_into_default_project_test() {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert [init, claims, _projects] = migrations.builtin_migrations()
  let assert Ok([1, 2]) = migrations.migrate(conn, [init, claims])

  // Rows as they exist before 0003, written through raw SQL so the v1/v2
  // schema (no `project_id`, unscoped `short_id`) is what is exercised.
  let assert Ok(_) =
    connection.execute(
      conn,
      "INSERT INTO tasks (id, short_id, title, description, level, priority, "
        <> "status, tags, archived, created_at, updated_at) VALUES "
        <> "('t-old', '00000001', 'Old task', '', 'ticket', 'medium', 'todo', "
        <> "'[]', 0, 1, 1)",
      [],
    )
  let assert Ok(_) =
    connection.execute(
      conn,
      "INSERT INTO sections (id, task_id, section_type, content, \"order\", "
        <> "created_at, updated_at) VALUES ('s-old', 't-old', 'goal', "
        <> "'keep me', 0, 1, 1)",
      [],
    )
  let assert Ok(_) =
    connection.execute(
      conn,
      "INSERT INTO artifacts (id, task_id, logical_name, content_json, "
        <> "created_at, updated_at) VALUES ('a-old', 't-old', 'plan', '{}', 1, 1)",
      [],
    )

  let assert Ok([3]) = migrations.run_migrations(conn)

  let assert Ok(row) =
    connection.query_one(
      conn,
      "SELECT short_id, project_id FROM tasks WHERE id = 't-old'",
      [],
    )
  row
  |> should.equal([
    connection.TextVal("default:00000001"),
    connection.TextVal("default"),
  ])

  let assert Ok(project_row) =
    connection.query_one(
      conn,
      "SELECT slug FROM projects WHERE id = 'default'",
      [],
    )
  project_row |> should.equal([connection.TextVal("default")])

  // Child rows must survive: the migration must not rebuild `tasks` (a DROP
  // TABLE under this build's foreign-key enforcement cascades them away).
  let assert Ok([connection.IntVal(sections)]) =
    connection.query_one(
      conn,
      "SELECT COUNT(*) FROM sections WHERE id = 's-old'",
      [],
    )
  sections |> should.equal(1)
  let assert Ok([connection.IntVal(found_artifacts)]) =
    connection.query_one(
      conn,
      "SELECT COUNT(*) FROM artifacts WHERE id = 'a-old'",
      [],
    )
  found_artifacts |> should.equal(1)

  // A second project now holds the same user-visible short id.
  let assert Ok(_) =
    connection.execute(
      conn,
      "INSERT INTO projects (id, slug, name, description, created_at, updated_at) "
        <> "VALUES ('p2', 'p2', 'Project two', '', 1, 1)",
      [],
    )
  let second =
    task.Task(
      ..task.new_task("Second project task", task.Ticket, task.Medium),
      id: "t-new",
      short_id: "00000001",
      project_id: "p2",
    )
  let assert Ok(_) = db_tasks.create_task(conn, second, 1)

  let assert Ok([connection.IntVal(scoped)]) =
    connection.query_one(
      conn,
      "SELECT COUNT(*) FROM tasks WHERE short_id IN "
        <> "('default:00000001', 'p2:00000001')",
      [],
    )
  scoped |> should.equal(2)
  connection.close(conn)
  Nil
}
