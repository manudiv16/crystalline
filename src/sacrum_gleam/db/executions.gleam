import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sacrum_gleam/db/connection.{type DbConnection, type DbError, type Value}
import sacrum_gleam/db/flows
import sacrum_gleam/domain/execution.{
  type ExecutionState, type ExecutionStatus, type StepExecution, type StepStatus,
  AwaitingInput, Cancelled, Completed, ExecutionState, Failed, Pending, Rejected,
  Running, StepCancelled, StepCompleted, StepEntered, StepExecution, StepFailed,
  StepInProgress, StepPending, execution_status_to_string, step_status_to_string,
}

/// Execution state and step execution persistence.
/// Execution state columns (aliased to `es`) joined with the flow instance
/// columns (`fi`). The state part comes first so `row_to_execution_state` can
/// split the joined row at a fixed boundary and decode each half against its
/// own pinned column list.
const execution_state_columns = [
  "es.id",
  "es.flow_instance_id",
  "es.task_id",
  "es.status",
  "es.current_node_id",
  "es.loop_counters_json",
  "es.variables_json",
  "es.parallel_active_json",
  "es.started_at",
  "es.completed_at",
  "es.created_at",
  "es.updated_at",
]

const flow_instance_columns = [
  "fi.id",
  "fi.template_id",
  "fi.task_id",
  "fi.initial_node_id",
  "fi.nodes_json",
  "fi.transitions_json",
  "fi.on_done_template_id",
  "fi.on_reject_template_id",
  "fi.created_at",
]

/// Explicit column list for the step_executions table (matches schema order).
const step_columns = [
  "id",
  "flow_instance_id",
  "execution_state_id",
  "node_id",
  "task_id",
  "status",
  "prompt",
  "output",
  "transition_result",
  "model",
  "input_tokens",
  "output_tokens",
  "cost",
  "duration_ms",
  "session_id",
  "created_at",
  "completed_at",
]

fn joined_columns_sql() -> String {
  string.join(execution_state_columns, ", ")
  <> ", "
  <> string.join(flow_instance_columns, ", ")
}

fn execution_states_sql() -> String {
  "SELECT "
  <> joined_columns_sql()
  <> " FROM execution_states es "
  <> "JOIN flow_instances fi ON fi.id = es.flow_instance_id"
}

fn step_columns_sql() -> String {
  string.join(step_columns, ", ")
}

// ─── Execution States ────────────────────────────────────────────────────

pub fn create_execution_state(
  conn: DbConnection,
  state: ExecutionState,
  now: Int,
) -> Result(String, DbError) {
  let sql = {
    "INSERT INTO execution_states "
    <> "(id, flow_instance_id, task_id, status, current_node_id, "
    <> "loop_counters_json, variables_json, parallel_active_json, "
    <> "started_at, completed_at, created_at, updated_at) "
    <> "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  }

  let params = [
    connection.TextVal(state.id),
    connection.TextVal(state.flow_instance.id),
    connection.TextVal(state.task_id),
    connection.TextVal(execution_status_to_string(state.status)),
    option_to_text(state.current_node_id),
    connection.TextVal(encode_loop_counters(state.loop_counters)),
    connection.TextVal(encode_variables(state.variables)),
    connection.TextVal(encode_parallel_active(state.parallel_active)),
    int_option_to_val(state.started_at),
    int_option_to_val(state.completed_at),
    connection.IntVal(now),
    connection.IntVal(now),
  ]

  use _ <- result.try(connection.execute(conn, sql, params))
  Ok(state.id)
}

pub fn get_execution_state(
  conn: DbConnection,
  id: String,
) -> Result(ExecutionState, DbError) {
  let sql = execution_states_sql() <> " WHERE es.id = ?"
  use row <- result.try(
    connection.query_one(conn, sql, [connection.TextVal(id)]),
  )
  row_to_execution_state(row)
}

/// Get the execution state for a flow instance (one instance has exactly one
/// execution state). The API addresses instances by their flow instance id,
/// so this is the lookup used by the execution control endpoints.
pub fn get_execution_by_instance(
  conn: DbConnection,
  instance_id: String,
) -> Result(ExecutionState, DbError) {
  let sql = execution_states_sql() <> " WHERE es.flow_instance_id = ?"
  use row <- result.try(
    connection.query_one(conn, sql, [connection.TextVal(instance_id)]),
  )
  row_to_execution_state(row)
}

pub fn get_execution_by_task(
  conn: DbConnection,
  task_id: String,
) -> Result(List(ExecutionState), DbError) {
  let sql =
    execution_states_sql()
    <> " WHERE es.task_id = ? ORDER BY es.created_at DESC"
  use rows <- result.try(
    connection.query(conn, sql, [connection.TextVal(task_id)]),
  )
  list.map(rows, row_to_execution_state) |> result.all
}

pub fn get_active_executions(
  conn: DbConnection,
) -> Result(List(ExecutionState), DbError) {
  let sql =
    execution_states_sql()
    <> " WHERE es.status IN ('running', 'awaiting_input')"
  use rows <- result.try(connection.query(conn, sql, []))
  list.map(rows, row_to_execution_state) |> result.all
}

pub fn update_execution_status(
  conn: DbConnection,
  id: String,
  status: ExecutionStatus,
  current_node_id: Option(String),
  now: Int,
) -> Result(Nil, DbError) {
  let sql = {
    "UPDATE execution_states SET status = ?, current_node_id = ?, "
    <> "updated_at = ? WHERE id = ?"
  }

  let params = [
    connection.TextVal(execution_status_to_string(status)),
    option_to_text(current_node_id),
    connection.IntVal(now),
    connection.TextVal(id),
  ]

  connection.execute(conn, sql, params)
}

pub fn update_execution_variables(
  conn: DbConnection,
  id: String,
  variables: Dict(String, String),
  loop_counters: Dict(String, Int),
  now: Int,
) -> Result(Nil, DbError) {
  let sql = {
    "UPDATE execution_states SET "
    <> "variables_json = ?, loop_counters_json = ?, "
    <> "updated_at = ? WHERE id = ?"
  }

  let params = [
    connection.TextVal(encode_variables(variables)),
    connection.TextVal(encode_loop_counters(loop_counters)),
    connection.IntVal(now),
    connection.TextVal(id),
  ]

  connection.execute(conn, sql, params)
}

// ─── Step Executions ─────────────────────────────────────────────────────

pub fn create_step_execution(
  conn: DbConnection,
  step: StepExecution,
  _now: Int,
) -> Result(String, DbError) {
  let sql = {
    "INSERT INTO step_executions "
    <> "(id, flow_instance_id, execution_state_id, node_id, task_id, "
    <> "status, prompt, output, transition_result, model, "
    <> "input_tokens, output_tokens, cost, duration_ms, session_id, "
    <> "created_at, completed_at) "
    <> "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  }

  let params = [
    connection.TextVal(step.id),
    connection.TextVal(step.flow_instance_id),
    connection.TextVal(step.execution_state_id),
    connection.TextVal(step.node_id),
    connection.TextVal(step.task_id),
    connection.TextVal(step_status_to_string(step.status)),
    option_to_text(step.prompt),
    option_to_text(step.output),
    option_to_text(step.transition_result),
    option_to_text(step.model),
    connection.IntVal(step.input_tokens),
    connection.IntVal(step.output_tokens),
    connection.FloatVal(step.cost),
    connection.IntVal(step.duration_ms),
    option_to_text(step.session_id),
    connection.IntVal(step.created_at),
    int_option_to_val(step.completed_at),
  ]

  use _ <- result.try(connection.execute(conn, sql, params))
  Ok(step.id)
}

pub fn update_step_execution(
  conn: DbConnection,
  step: StepExecution,
) -> Result(Nil, DbError) {
  let sql = {
    "UPDATE step_executions SET "
    <> "status = ?, output = ?, transition_result = ?, model = ?, "
    <> "input_tokens = ?, output_tokens = ?, cost = ?, "
    <> "duration_ms = ?, session_id = ?, completed_at = ? "
    <> "WHERE id = ?"
  }

  let params = [
    connection.TextVal(step_status_to_string(step.status)),
    option_to_text(step.output),
    option_to_text(step.transition_result),
    option_to_text(step.model),
    connection.IntVal(step.input_tokens),
    connection.IntVal(step.output_tokens),
    connection.FloatVal(step.cost),
    connection.IntVal(step.duration_ms),
    option_to_text(step.session_id),
    int_option_to_val(step.completed_at),
    connection.TextVal(step.id),
  ]

  connection.execute(conn, sql, params)
}

pub fn get_step_execution(
  conn: DbConnection,
  id: String,
) -> Result(StepExecution, DbError) {
  let sql =
    "SELECT " <> step_columns_sql() <> " FROM step_executions WHERE id = ?"
  use row <- result.try(
    connection.query_one(conn, sql, [connection.TextVal(id)]),
  )
  row_to_step(row)
}

pub fn get_steps_for_instance(
  conn: DbConnection,
  instance_id: String,
) -> Result(List(StepExecution), DbError) {
  let sql = {
    "SELECT "
    <> step_columns_sql()
    <> " FROM step_executions WHERE flow_instance_id = ? "
    <> "ORDER BY created_at DESC"
  }
  use rows <- result.try(
    connection.query(conn, sql, [connection.TextVal(instance_id)]),
  )
  list.map(rows, row_to_step) |> result.all
}

pub fn get_steps_for_task(
  conn: DbConnection,
  task_id: String,
) -> Result(List(StepExecution), DbError) {
  let sql = {
    "SELECT "
    <> step_columns_sql()
    <> " FROM step_executions WHERE task_id = ? ORDER BY created_at DESC"
  }
  use rows <- result.try(
    connection.query(conn, sql, [connection.TextVal(task_id)]),
  )
  list.map(rows, row_to_step) |> result.all
}

// ─── Row Mapping ─────────────────────────────────────────────────────────

fn row_to_execution_state(row: List(Value)) -> Result(ExecutionState, DbError) {
  // Split the joined row at the boundary between the execution state columns
  // (12) and the flow instance columns (9).
  let #(state_row, instance_row) = list.split(row, at: 12)
  use instance <- result.try(flows.row_to_flow_instance(instance_row))

  case state_row {
    [
      connection.TextVal(id),
      connection.TextVal(_flow_instance_id),
      connection.TextVal(task_id),
      connection.TextVal(status_str),
      current_node_raw,
      connection.TextVal(loop_counters_json),
      connection.TextVal(variables_json),
      connection.TextVal(parallel_json),
      started_raw,
      completed_raw,
      connection.IntVal(_created_at),
      connection.IntVal(_updated_at),
    ] -> {
      use status <- result.try(
        execution_status_from_string(status_str)
        |> result.map_error(fn(message) { connection.QueryError(message) }),
      )
      use loop_counters <- result.try(
        decode_loop_counters(loop_counters_json)
        |> result.map_error(fn(message) { connection.QueryError(message) }),
      )
      use variables <- result.try(
        decode_variables(variables_json)
        |> result.map_error(fn(message) { connection.QueryError(message) }),
      )
      use parallel_active <- result.try(
        decode_parallel_active(parallel_json)
        |> result.map_error(fn(message) { connection.QueryError(message) }),
      )

      Ok(ExecutionState(
        id: id,
        flow_instance: instance,
        task_id: task_id,
        status: status,
        current_node_id: text_option(current_node_raw),
        // Step history lives in step_executions; load it separately via
        // `get_steps_for_instance`.
        step_history: [],
        loop_counters: loop_counters,
        variables: variables,
        parallel_active: parallel_active,
        started_at: int_option(started_raw),
        completed_at: int_option(completed_raw),
      ))
    }
    _ -> Error(connection.QueryError("Invalid execution state row"))
  }
}

fn row_to_step(row: List(Value)) -> Result(StepExecution, DbError) {
  case row {
    [
      connection.TextVal(id),
      connection.TextVal(flow_instance_id),
      connection.TextVal(execution_state_id),
      connection.TextVal(node_id),
      connection.TextVal(task_id),
      connection.TextVal(status_str),
      prompt_raw,
      output_raw,
      transition_raw,
      model_raw,
      connection.IntVal(input_tokens),
      connection.IntVal(output_tokens),
      connection.FloatVal(cost),
      connection.IntVal(duration_ms),
      session_raw,
      connection.IntVal(created_at),
      completed_raw,
    ] -> {
      use status <- result.try(
        step_status_from_string(status_str)
        |> result.map_error(fn(message) { connection.QueryError(message) }),
      )

      Ok(StepExecution(
        id: id,
        flow_instance_id: flow_instance_id,
        execution_state_id: execution_state_id,
        node_id: node_id,
        task_id: task_id,
        status: status,
        prompt: text_option(prompt_raw),
        output: text_option(output_raw),
        transition_result: text_option(transition_raw),
        model: text_option(model_raw),
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cost: cost,
        duration_ms: duration_ms,
        session_id: text_option(session_raw),
        created_at: created_at,
        completed_at: int_option(completed_raw),
      ))
    }
    _ -> Error(connection.QueryError("Invalid step execution row"))
  }
}

// ─── JSON Encoding Helpers ───────────────────────────────────────────────

fn encode_variables(variables: Dict(String, String)) -> String {
  variables
  |> dict.to_list
  |> list.map(fn(pair) {
    let #(key, value) = pair
    #(key, json.string(value))
  })
  |> json.object
  |> json.to_string
}

fn encode_loop_counters(loop_counters: Dict(String, Int)) -> String {
  loop_counters
  |> dict.to_list
  |> list.map(fn(pair) {
    let #(key, count) = pair
    #(key, json.int(count))
  })
  |> json.object
  |> json.to_string
}

fn encode_parallel_active(active: List(String)) -> String {
  active
  |> json.array(json.string)
  |> json.to_string
}

fn decode_variables(raw: String) -> Result(Dict(String, String), String) {
  json.parse(raw, decode.dict(decode.string, decode.string))
  |> result.map_error(executions_error_to_string)
}

fn decode_loop_counters(raw: String) -> Result(Dict(String, Int), String) {
  json.parse(raw, decode.dict(decode.string, decode.int))
  |> result.map_error(executions_error_to_string)
}

fn decode_parallel_active(raw: String) -> Result(List(String), String) {
  json.parse(raw, decode.list(decode.string))
  |> result.map_error(executions_error_to_string)
}

fn executions_error_to_string(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "Unexpected end of JSON input"
    json.UnexpectedByte(byte) -> "Unexpected byte: " <> byte
    json.UnexpectedSequence(sequence) -> "Unexpected sequence: " <> sequence
    json.UnableToDecode(errors) ->
      errors
      |> list.map(fn(decode_error) {
        case decode_error {
          decode.DecodeError(expected: expected, found: found, path: path) ->
            "expected "
            <> expected
            <> ", found "
            <> found
            <> " at "
            <> string.join(path, ".")
        }
      })
      |> string.join("; ")
  }
}

fn execution_status_from_string(s: String) -> Result(ExecutionStatus, String) {
  case s {
    "pending" -> Ok(Pending)
    "running" -> Ok(Running)
    "awaiting_input" -> Ok(AwaitingInput)
    "completed" -> Ok(Completed)
    "rejected" -> Ok(Rejected)
    "failed" -> Ok(Failed)
    "cancelled" -> Ok(Cancelled)
    _ -> Error("Unknown execution status: " <> s)
  }
}

fn step_status_from_string(s: String) -> Result(StepStatus, String) {
  case s {
    "pending" -> Ok(StepPending)
    "entered" -> Ok(StepEntered)
    "in_progress" -> Ok(StepInProgress)
    "completed" -> Ok(StepCompleted)
    "failed" -> Ok(StepFailed)
    "cancelled" -> Ok(StepCancelled)
    _ -> Error("Unknown step status: " <> s)
  }
}

fn option_to_text(opt: Option(String)) -> Value {
  case opt {
    Some(v) -> connection.TextVal(v)
    None -> connection.NullVal
  }
}

fn int_option_to_val(opt: Option(Int)) -> Value {
  case opt {
    Some(v) -> connection.IntVal(v)
    None -> connection.NullVal
  }
}

fn int_option(val: Value) -> Option(Int) {
  case val {
    connection.IntVal(v) -> Some(v)
    _ -> None
  }
}

fn text_option(val: Value) -> Option(String) {
  case val {
    connection.TextVal(v) -> Some(v)
    _ -> None
  }
}
