import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sacrum_gleam/db/connection.{type DbConnection, type DbError}
import sacrum_gleam/domain/session.{type SessionLog, SessionLog}
import sacrum_gleam/runtime/events

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
///
/// The conversational human-input channel ([`human_turn_event_types`]) adds
/// `prompt` and `human_input`: one human turn appends the gate node's prompt
/// and then the human's reply to the same step execution, so a step's log
/// stream replays a turn in order (prompt at sequence `n`, reply at `n + 1`).
/// The payload of both types is the plain text, not JSON.
pub const allowed_event_types: List(String) = [
  "text",
  "usage",
  "tool_use",
  "outcome",
  "error",
  "prompt",
  "human_input",
]

/// The subset of [`allowed_event_types`](#allowed_event_types) that carries a
/// conversational human turn (see `http/routes/flows.reply_service`).
pub const human_turn_event_types: List(String) = ["prompt", "human_input"]

pub const prompt_event_type: String = "prompt"

pub const human_input_event_type: String = "human_input"

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
      // Publish only after the row is committed, so a stream never sees an
      // append that the database rejected or rolled back.
      events.publish_session_log(log)
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

/// One human-turn log row plus the gate node it belongs to.
///
/// The node id is not on `SessionLog` (the log only knows its step execution);
/// it is joined in so a client can name the gate a prompt or reply came from.
pub type TurnLog {
  TurnLog(log: SessionLog, node_id: String)
}

/// List every human-turn log of a flow instance, in conversation order.
///
/// Both `prompt` and `human_input` rows are returned (see
/// [`human_turn_event_types`](#human_turn_event_types)); other event types —
/// agent `outcome`/`usage`/`text` rows — are excluded, so the result is the
/// transcript of the gates and not the whole step history.
///
/// Order is `step_executions.rowid`, then the per-step `sequence`: rowid is the
/// insertion order of the gate step executions, which is the order the turns
/// happened in. `created_at` alone cannot carry that order — two turns taken in
/// the same millisecond would be indistinguishable — and the per-step sequence
/// is assigned inside the append transaction.
pub fn list_human_turns(
  conn: DbConnection,
  flow_instance_id: String,
) -> Result(List(TurnLog), DbError) {
  let sql = {
    "SELECT sl.id, sl.step_execution_id, sl.task_id, sl.event_type, "
    <> "sl.payload_json, sl.sequence, sl.created_at, se.node_id "
    <> "FROM session_logs sl "
    <> "JOIN step_executions se ON se.id = sl.step_execution_id "
    <> "WHERE se.flow_instance_id = ? "
    <> "AND sl.event_type IN ('prompt', 'human_input') "
    <> "ORDER BY se.rowid, sl.sequence"
  }

  use rows <- result.try(
    connection.query(conn, sql, [connection.TextVal(flow_instance_id)]),
  )
  use turns <- result.try(list.map(rows, row_to_turn_log) |> result.all)
  Ok(turns)
}

fn row_to_turn_log(row: List(connection.Value)) -> Result(TurnLog, DbError) {
  case row {
    [
      connection.TextVal(id),
      connection.TextVal(step_execution_id),
      connection.TextVal(task_id),
      connection.TextVal(event_type),
      connection.TextVal(payload_json),
      connection.IntVal(sequence),
      connection.IntVal(created_at),
      connection.TextVal(node_id),
    ] ->
      Ok(TurnLog(
        log: SessionLog(
          id: id,
          step_execution_id: step_execution_id,
          task_id: task_id,
          event_type: event_type,
          payload: payload_json,
          sequence: sequence,
          created_at: created_at,
        ),
        node_id: node_id,
      ))
    _ -> Error(connection.QueryError("Invalid human turn log row"))
  }
}

/// Whether any step in a flow instance already has a durable error event.
pub fn has_error_log_for_instance(
  conn: DbConnection,
  flow_instance_id: String,
) -> Result(Bool, DbError) {
  use row <- result.try(
    connection.query_one(
      conn,
      "SELECT COUNT(*) FROM session_logs sl "
        <> "JOIN step_executions se ON se.id = sl.step_execution_id "
        <> "WHERE se.flow_instance_id = ? AND sl.event_type = 'error'",
      [connection.TextVal(flow_instance_id)],
    ),
  )
  case row {
    [connection.IntVal(count), ..] -> Ok(count > 0)
    _ -> Error(connection.QueryError("Could not count execution error logs"))
  }
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
