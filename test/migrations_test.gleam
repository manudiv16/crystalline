import gleam/list
import gleam/option.{None}
import gleeunit/should
import sacrum_gleam/db/connection
import sacrum_gleam/db/migrations

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

/// Empty DB: first run creates the schema and applies both built-in versions.
pub fn first_run_applies_v1_test() {
  let assert Ok(conn) = connection.connect(":memory:", None)

  let assert Ok(applied) = migrations.run_migrations(conn)
  applied |> should.equal([1, 2])

  let names = db_table_names(conn)
  let expected_tables = [
    "artifacts",
    "execution_states",
    "flow_instances",
    "flow_templates",
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

/// A second run is a no-op: both built-in migrations are already applied.
pub fn second_run_is_noop_test() {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok([1, 2]) = migrations.run_migrations(conn)

  let assert Ok(applied) = migrations.run_migrations(conn)
  applied |> should.equal([])

  let assert Ok(row) =
    connection.query_one(conn, "SELECT COUNT(*) FROM schema_migrations", [])
  row |> should.equal([connection.IntVal(2)])
}

/// A database stopped at v1 receives only the additive daemon migration.
pub fn existing_schema_receives_daemon_claim_migration_test() {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert [initial, _claims] = migrations.builtin_migrations()
  let assert Ok([1]) = migrations.migrate(conn, [initial])

  let assert Ok([2]) = migrations.run_migrations(conn)
  let assert Ok(columns) =
    connection.query(conn, "PRAGMA table_info(execution_states)", [])
  let names =
    list.map(columns, fn(row) {
      case row {
        [_, connection.TextVal(name), ..] -> name
        _ -> ""
      }
    })
  assert list.contains(names, "claimed_by")
  assert list.contains(names, "claimed_at")
  connection.close(conn)
  Nil
}
