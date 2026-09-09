import gleam/string
import sacrum_gleam/db/connection.{DbConnection, DbError}

/// Embedded migration runner.
/// Migrations live in the `migrations/` directory and are compiled into
/// the binary. Each migration file is named `NNNN_description.sql`.
///
/// For embedded use, migrations are passed as strings at build time or
/// loaded from a bundled source.

pub type Migration {
  Migration(
    version: Int,
    name: String,
    sql: String,
  )
}

pub type MigrationError {
  DbError(error: DbError)
  AlreadyApplied(version: Int)
  FailedAt(version: Int, message: String)
}

/// Track which migrations have been applied.
fn create_migrations_table(conn: DbConnection) -> Result(Nil, DbError) {
  connection.execute(conn, {
    "CREATE TABLE IF NOT EXISTS schema_migrations ("
    <> "version INTEGER PRIMARY KEY,"
    <> "name TEXT NOT NULL,"
    <> "applied_at INTEGER NOT NULL"
    <> ")"
  })
}

/// Get the highest applied migration version.
fn current_version(conn: DbConnection) -> Result(Int, DbError) {
  use rows <- connection.query(conn,
    "SELECT MAX(version) FROM schema_migrations", [],
  )
  case rows {
    [[val]] -> {
      // libsql returns values; parse as int
      case val {
        libsql_gleam.IntVal(v) -> Ok(v)
        _ -> Ok(0)
      }
    }
    _ -> Ok(0)
  }
}

/// Run all pending migrations in order.
pub fn migrate(
  conn: DbConnection,
  migrations: List(Migration),
) -> Result(List(Int), MigrationError) {
  use _ <- result.map_err(create_migrations_table(conn), DbError)

  use current <- result.map_err(current_version(conn), DbError)

  let pending =
    migrations
    |> list.filter(fn(m) { m.version > current })
    |> list.sort(fn(a, b) { int.compare(a.version, b.version) })

  run_migrations(conn, pending, [])
}

fn run_migrations(
  conn: DbConnection,
  remaining: List(Migration),
  applied: List(Int),
) -> Result(List(Int), MigrationError) {
  case remaining {
    [] -> Ok(list.reverse(applied))
    [m, ..rest] -> {
      use _ <- result.map_err(
        connection.execute(conn, m.sql),
        fn(e) { FailedAt(m.version, connection.error_to_string(e)) },
      )

      let now = 0 // Should be timestamp
      let insert_sql =
        "INSERT INTO schema_migrations (version, name, applied_at) VALUES ("
        <> int.to_string(m.version) <> ", '"
        <> string.replace(m.name, "'", "''") <> "', "
        <> int.to_string(now) <> ")"

      use _ <- result.map_err(
        connection.execute(conn, insert_sql),
        fn(e) { FailedAt(m.version, connection.error_to_string(e)) },
      )

      run_migrations(conn, rest, [m.version, ..applied])
    }
  }
}

/// The built-in migration for this version.
/// In a real build, this would be generated from the migrations/ directory.
pub fn builtin_migrations() -> List(Migration) {
  [
    Migration(
      version: 1,
      name: "init",
      sql: embedded_init_sql(),
    ),
  ]
}

fn embedded_init_sql() -> String {
  // This would be the content of migrations/0001_init.sql
  // Inlined here for embedded deployment
  ""
}
