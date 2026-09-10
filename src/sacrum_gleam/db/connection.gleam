import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libsql

pub type DbConnection {
  DbConnection(conn: libsql.Connection)
}

pub type DbError {
  ConnectionError(message: String)
  QueryError(message: String)
  MigrationError(message: String)
}

/// A dynamically-typed SQL value.
///
/// `libsql` exposes opaque values and a decoder-first query API. The rest of
/// the persistence layer works with this small tagged union instead, which
/// keeps row mapping and parameter building explicit and testable.
pub type Value {
  TextVal(String)
  IntVal(Int)
  FloatVal(Float)
  BlobVal(BitArray)
  NullVal
}

fn to_libsql(value: Value) -> libsql.Value {
  case value {
    TextVal(v) -> libsql.text(v)
    IntVal(v) -> libsql.int(v)
    FloatVal(v) -> libsql.float(v)
    BlobVal(v) -> libsql.blob(v)
    NullVal -> libsql.null()
  }
}

fn to_libsql_params(params: List(Value)) -> List(libsql.Value) {
  list.map(params, to_libsql)
}

fn cell_decoder() -> decode.Decoder(Value) {
  decode.optional(
    decode.one_of(decode.string |> decode.map(TextVal), [
      decode.int |> decode.map(IntVal),
      decode.float |> decode.map(FloatVal),
      decode.bit_array |> decode.map(BlobVal),
    ]),
  )
  |> decode.map(fn(value) {
    case value {
      Some(value) -> value
      None -> NullVal
    }
  })
}

fn row_decoder() -> decode.Decoder(List(Value)) {
  decode.list(cell_decoder())
}

/// Connect to a libsql database. One entry point for local and remote.
///
/// `db_url` is either:
/// - A local path: "file:/path/to/db.sqlite", ":memory:", or a bare path
/// - A Turso remote URL: "libsql://db.turso.io" or "https://db.turso.io"
///
/// When `auth_token` is `Some`, the connection is opened in remote mode
/// (Turso). A remote-looking URL **without** a token fails fast with a clear
/// error instead of surfacing a confusing libsql error.
pub fn connect(
  db_url: String,
  auth_token: Option(String),
) -> Result(DbConnection, DbError) {
  case auth_token {
    Some(token) -> {
      case libsql.open_remote(db_url, token) {
        Ok(conn) -> Ok(DbConnection(conn: conn))
        Error(err) -> Error(ConnectionError(err.message))
      }
    }
    None -> {
      case is_remote_url(db_url) {
        True ->
          Error(ConnectionError(
            "remote database URL '"
            <> db_url
            <> "' requires an auth token; pass one to `connect` or set "
            <> "CRYSTALLINE_AUTH_TOKEN",
          ))
        False -> {
          case libsql.open(db_url) {
            Ok(conn) -> Ok(DbConnection(conn: conn))
            Error(err) -> Error(ConnectionError(err.message))
          }
        }
      }
    }
  }
}

/// Whether a database URL refers to a remote (Turso) database.
///
/// Local SQLite paths and `:memory:` are never remote.
pub fn is_remote_url(db_url: String) -> Bool {
  string.starts_with(db_url, "libsql://")
  || string.starts_with(db_url, "https://")
  || string.starts_with(db_url, "http://")
  || string.starts_with(db_url, "wss://")
}

/// Execute a SQL statement with optional parameters.
pub fn execute(
  conn: DbConnection,
  sql: String,
  params: List(Value),
) -> Result(Nil, DbError) {
  case params {
    [] -> {
      case libsql.exec(sql, on: conn.conn) {
        Ok(_) -> Ok(Nil)
        Error(err) -> Error(QueryError(err.message))
      }
    }
    _ -> {
      case
        libsql.with_statement(sql, on: conn.conn, run: fn(stmt) {
          libsql.exec_prepared(on: stmt, with: to_libsql_params(params))
        })
      {
        Ok(_) -> Ok(Nil)
        Error(err) -> Error(QueryError(err.message))
      }
    }
  }
}

/// Execute a query with parameters and return the raw rows.
pub fn query(
  conn: DbConnection,
  sql: String,
  params: List(Value),
) -> Result(List(List(Value)), DbError) {
  case
    libsql.query(
      sql,
      on: conn.conn,
      with: to_libsql_params(params),
      expecting: row_decoder(),
    )
  {
    Ok(rows) -> Ok(rows)
    Error(err) -> Error(QueryError(err.message))
  }
}

/// Execute a query that returns a single row.
pub fn query_one(
  conn: DbConnection,
  sql: String,
  params: List(Value),
) -> Result(List(Value), DbError) {
  use rows <- result.try(query(conn, sql, params))
  case rows {
    [row, ..] -> Ok(row)
    [] -> Error(QueryError("No rows returned"))
  }
}

/// Run a transaction.
pub fn transaction(
  conn: DbConnection,
  statements: List(String),
) -> Result(Nil, DbError) {
  use _ <- result.try(execute(conn, "BEGIN", []))

  let result = run_batch(conn, statements)

  case result {
    Ok(_) -> execute(conn, "COMMIT", [])
    Error(e) -> {
      let _ = execute(conn, "ROLLBACK", [])
      Error(e)
    }
  }
}

/// Convert a DbError to a human-readable string.
pub fn error_to_string(error: DbError) -> String {
  case error {
    ConnectionError(message) -> message
    QueryError(message) -> message
    MigrationError(message) -> message
  }
}

/// Close the database connection.
pub fn close(conn: DbConnection) -> Nil {
  let _ = libsql.close(conn.conn)
  Nil
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
      case execute(conn, sql, []) {
        Ok(_) -> run_batch_inner(conn, rest)
        Error(e) -> Error(e)
      }
    }
  }
}
