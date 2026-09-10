import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sacrum_gleam/db/connection.{type DbConnection, type DbError}
import sacrum_gleam/domain/session.{type SessionLog, SessionLog}

/// Session log persistence for step executions.
///
/// Every log event belongs to exactly one step execution and carries a
/// monotonically increasing `sequence`, computed **server-side** on append —
/// the client never supplies it, so two appends can not collide or produce a
/// gap in the replay stream.
///
/// Paging mirrors the harness replay contract: the caller asks for the newest
/// `limit` events below a `before_sequence` cursor, and the page is returned in
/// chronological (ascending sequence) order. The next page cursor is the
/// sequence of the **first** element of the current page.
/// Default page size when the client omits `?limit=`; also the maximum page
/// size accepted by the API.
pub const default_limit: Int = 50

/// Event types accepted on append. The runtime step executor emits
/// `outcome`, `usage` and `error`; `text` and `tool_use` are part of the
/// harness event vocabulary (see `migrations/0001_init.sql`).
pub const allowed_event_types: List(String) = [
  "text",
  "usage",
  "tool_use",
  "outcome",
  "error",
]

/// Whether `event_type` is one of the accepted log event types.
pub fn is_valid_event_type(event_type: String) -> Bool {
  list.contains(allowed_event_types, event_type)
}

/// Append one log event to a step execution's stream.
///
/// The sequence is computed inside a transaction as
/// `MAX(sequence) + 1` for that step execution, so it is strictly monotonic
/// and gap-free for sequential appends, and never comes from the client.
/// Returns the stored log (including its server-assigned sequence).
pub fn append_log(
  conn: DbConnection,
  step_execution_id: String,
  task_id: String,
  event_type: String,
  payload: String,
  now: Int,
) -> Result(SessionLog, DbError) {
  use _ <- result.try(connection.execute(conn, "BEGIN", []))

  let outcome = {
    use sequence <- result.try(next_sequence(conn, step_execution_id))

    let log =
      SessionLog(
        id: step_execution_id <> "-" <> int.to_string(sequence),
        step_execution_id: step_execution_id,
        task_id: task_id,
        event_type: event_type,
        payload: payload,
        sequence: sequence,
        created_at: now,
      )

    let sql = {
      "INSERT INTO session_logs "
      <> "(id, step_execution_id, task_id, event_type, payload_json, "
      <> "sequence, created_at) "
      <> "VALUES (?, ?, ?, ?, ?, ?, ?)"
    }

    let params = [
      connection.TextVal(log.id),
      connection.TextVal(log.step_execution_id),
      connection.TextVal(log.task_id),
      connection.TextVal(log.event_type),
      connection.TextVal(log.payload),
      connection.IntVal(log.sequence),
      connection.IntVal(log.created_at),
    ]

    case connection.execute(conn, sql, params) {
      Ok(_) -> Ok(log)
      Error(error) -> Error(error)
    }
  }

  case outcome {
    Ok(log) -> {
      use _ <- result.try(connection.execute(conn, "COMMIT", []))
      Ok(log)
    }
    Error(error) -> {
      let _ = connection.execute(conn, "ROLLBACK", [])
      Error(error)
    }
  }
}

/// List a step execution's log events, newest page first.
///
/// Returns the newest `limit` events with `sequence < before_sequence`
/// (or the newest `limit` events when `before_sequence` is `None`), ordered
/// chronologically so the page reads as a replay stream. Page forward by
/// passing the first element's sequence as the next `before_sequence`.
pub fn list_logs(
  conn: DbConnection,
  step_execution_id: String,
  limit: Int,
  before_sequence: Option(Int),
) -> Result(List(SessionLog), DbError) {
  let columns = {
    "id, step_execution_id, task_id, event_type, payload_json, "
    <> "sequence, created_at"
  }

  let sql = case before_sequence {
    Some(_) -> {
      "SELECT "
      <> columns
      <> " FROM session_logs WHERE step_execution_id = ? "
      <> "AND sequence < ? ORDER BY sequence DESC LIMIT ?"
    }
    None -> {
      "SELECT "
      <> columns
      <> " FROM session_logs WHERE step_execution_id = ? "
      <> "ORDER BY sequence DESC LIMIT ?"
    }
  }

  let params = case before_sequence {
    Some(sequence) -> [
      connection.TextVal(step_execution_id),
      connection.IntVal(sequence),
      connection.IntVal(limit),
    ]
    None -> [
      connection.TextVal(step_execution_id),
      connection.IntVal(limit),
    ]
  }

  use rows <- result.try(connection.query(conn, sql, params))
  use logs <- result.try(list.map(rows, row_to_log) |> result.all)
  // Newest-first selection, but the page itself keeps chronological order.
  Ok(list.reverse(logs))
}

/// Delete every log event belonging to a step execution.
pub fn delete_logs_for_execution(
  conn: DbConnection,
  step_execution_id: String,
) -> Result(Nil, DbError) {
  connection.execute(
    conn,
    "DELETE FROM session_logs WHERE step_execution_id = ?",
    [connection.TextVal(step_execution_id)],
  )
}

/// The next monotonic sequence for a step execution: one past the current
/// maximum, or 1 for an empty stream.
fn next_sequence(
  conn: DbConnection,
  step_execution_id: String,
) -> Result(Int, DbError) {
  let sql = {
    "SELECT COALESCE(MAX(sequence), 0) + 1 FROM session_logs "
    <> "WHERE step_execution_id = ?"
  }

  use rows <- result.try(
    connection.query(conn, sql, [connection.TextVal(step_execution_id)]),
  )

  case rows {
    [[connection.IntVal(sequence), ..], ..] -> Ok(sequence)
    _ -> Error(connection.QueryError("Could not determine next log sequence"))
  }
}

fn row_to_log(row: List(connection.Value)) -> Result(SessionLog, DbError) {
  case row {
    [
      connection.TextVal(id),
      connection.TextVal(step_execution_id),
      connection.TextVal(task_id),
      connection.TextVal(event_type),
      connection.TextVal(payload_json),
      connection.IntVal(sequence),
      connection.IntVal(created_at),
    ] ->
      Ok(SessionLog(
        id: id,
        step_execution_id: step_execution_id,
        task_id: task_id,
        event_type: event_type,
        payload: payload_json,
        sequence: sequence,
        created_at: created_at,
      ))
    _ -> Error(connection.QueryError("Invalid session log row"))
  }
}
