import libsql_gleam
import gleam/result
import gleam/io

pub type DbConnection {
  DbConnection(conn: libsql_gleam.Connection)
}

pub type DbError {
  ConnectionError(message: String)
  QueryError(message: String)
  MigrationError(message: String)
}

/// Connect to a libsql database.
/// Path can be:
/// - A file path for local SQLite: "file:/path/to/db.sqlite"
/// - An in-memory database: ":memory:"
/// - A Turso remote URL: "libsql://db.turso.io"
pub fn connect(db_url: String) -> Result(DbConnection, DbError) {
  case libsql_gleam.connect(db_url) {
    Ok(conn) -> Ok(DbConnection(conn: conn))
    Error(err) -> Error(ConnectionError(libsql_gleam.error_message(err)))
  }
}

/// Execute a raw SQL statement.
pub fn execute(
  conn: DbConnection,
  sql: String,
) -> Result(Nil, DbError) {
  case libsql_gleam.execute(conn.conn, sql, []) {
    Ok(_) -> Ok(Nil)
    Error(err) -> Error(QueryError(libsql_gleam.error_message(err)))
  }
}

/// Execute a query that returns rows.
pub fn query(
  conn: DbConnection,
  sql: String,
  params: List(libsql_gleam.Value),
) -> Result(List(List(libsql_gleam.Value)), DbError) {
  case libsql_gleam.query(conn.conn, sql, params) {
    Ok(rows) -> Ok(rows)
    Error(err) -> Error(QueryError(libsql_gleam.error_message(err)))
  }
}

/// Execute a query that returns a single row.
pub fn query_one(
  conn: DbConnection,
  sql: String,
  params: List(libsql_gleam.Value),
) -> Result(List(libsql_gleam.Value), DbError) {
  case query(conn, sql, params) {
    Ok([row, ..]) -> Ok(row)
    Ok([]) -> Error(QueryError("No rows returned"))
    Error(e) -> Error(e)
  }
}

/// Run a transaction.
pub fn transaction(
  conn: DbConnection,
  statements: List(String),
) -> Result(Nil, DbError) {
  use _ <- result.try(execute(conn, "BEGIN"))

  let result = run_batch(conn, statements)

  case result {
    Ok(_) -> execute(conn, "COMMIT")
    Error(e) -> {
      let _ = execute(conn, "ROLLBACK")
      Error(e)
    }
  }
}

/// Close the database connection.
pub fn close(conn: DbConnection) -> Nil {
  libsql_gleam.close(conn.conn)
}

/// Run multiple statements in sequence, stopping on first error.
pub fn run_batch(
  conn: DbConnection,
  statements: List(String),
) -> Result(Nil, DbError) {
  run_batch_inner(conn, statements)
}

fn run_batch_inner(
  conn: DbConnection,
  remaining: List(String),
) -> Result(Nil, DbError) {
  case remaining {
    [] -> Ok(Nil)
    [sql, ..rest] -> {
      case execute(conn, sql) {
        Ok(_) -> run_batch_inner(conn, rest)
        Error(e) -> Error(e)
      }
    }
  }
}
