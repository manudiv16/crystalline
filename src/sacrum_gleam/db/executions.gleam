import gleam/dict.{Dict}
import gleam/option.{Option, Some, None}
import libsql_gleam
import sacrum_gleam/db/connection.{DbConnection, DbError}
import sacrum_gleam/domain/execution.{
  ExecutionState, ExecutionStatus, StepExecution, StepStatus,
  execution_status_to_string, step_status_to_string,
}
import sacrum_gleam/domain/flow.{FlowInstance}

/// Execution state and step execution persistence.

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
    libsql_gleam.TextVal(state.id),
    libsql_gleam.TextVal(state.flow_instance.id),
    libsql_gleam.TextVal(state.task_id),
    libsql_gleam.TextVal(execution_status_to_string(state.status)),
    option_to_text(state.current_node_id),
    libsql_gleam.TextVal("{}"),
    libsql_gleam.TextVal("{}"),
    libsql_gleam.TextVal("[]"),
    int_option_to_val(state.started_at),
    int_option_to_val(state.completed_at),
    libsql_gleam.IntVal(now),
    libsql_gleam.IntVal(now),
  ]

  use _ <- connection.query(conn, sql, params)
  Ok(state.id)
}

pub fn get_execution_state(
  conn: DbConnection,
  id: String,
) -> Result(ExecutionState, DbError) {
  let sql = "SELECT * FROM execution_states WHERE id = ?"
  use row <- connection.query_one(conn, sql, [libsql_gleam.TextVal(id)])
  row_to_execution_state(row)
}

pub fn get_execution_by_task(
  conn: DbConnection,
  task_id: String,
) -> Result(List(ExecutionState), DbError) {
  let sql = "SELECT * FROM execution_states WHERE task_id = ? ORDER BY created_at DESC"
  use rows <- connection.query(conn, sql, [libsql_gleam.TextVal(task_id)])
  list.map(rows, row_to_execution_state) |> result.all
}

pub fn get_active_executions(
  conn: DbConnection,
) -> Result(List(ExecutionState), DbError) {
  let sql = {
    "SELECT * FROM execution_states WHERE status IN ('running', 'awaiting_input')"
  }
  use rows <- connection.query(conn, sql, [])
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
    libsql_gleam.TextVal(execution_status_to_string(status)),
    option_to_text(current_node_id),
    libsql_gleam.IntVal(now),
    libsql_gleam.TextVal(id),
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
    libsql_gleam.TextVal("{}"), // serialized variables
    libsql_gleam.TextVal("{}"), // serialized loop_counters
    libsql_gleam.IntVal(now),
    libsql_gleam.TextVal(id),
  ]

  connection.execute(conn, sql, params)
}

// ─── Step Executions ─────────────────────────────────────────────────────

pub fn create_step_execution(
  conn: DbConnection,
  step: StepExecution,
  now: Int,
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
    libsql_gleam.TextVal(step.id),
    libsql_gleam.TextVal(step.flow_instance_id),
    libsql_gleam.TextVal(step.execution_state_id),
    libsql_gleam.TextVal(step.node_id),
    libsql_gleam.TextVal(step.task_id),
    libsql_gleam.TextVal(step_status_to_string(step.status)),
    option_to_text(step.prompt),
    option_to_text(step.output),
    option_to_text(step.transition_result),
    option_to_text(step.model),
    libsql_gleam.IntVal(step.input_tokens),
    libsql_gleam.IntVal(step.output_tokens),
    libsql_gleam.FloatVal(step.cost),
    libsql_gleam.IntVal(step.duration_ms),
    option_to_text(step.session_id),
    libsql_gleam.IntVal(step.created_at),
    int_option_to_val(step.completed_at),
  ]

  use _ <- connection.query(conn, sql, params)
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
    libsql_gleam.TextVal(step_status_to_string(step.status)),
    option_to_text(step.output),
    option_to_text(step.transition_result),
    option_to_text(step.model),
    libsql_gleam.IntVal(step.input_tokens),
    libsql_gleam.IntVal(step.output_tokens),
    libsql_gleam.FloatVal(step.cost),
    libsql_gleam.IntVal(step.duration_ms),
    option_to_text(step.session_id),
    int_option_to_val(step.completed_at),
    libsql_gleam.TextVal(step.id),
  ]

  connection.execute(conn, sql, params)
}

pub fn get_step_execution(
  conn: DbConnection,
  id: String,
) -> Result(StepExecution, DbError) {
  let sql = "SELECT * FROM step_executions WHERE id = ?"
  use row <- connection.query_one(conn, sql, [libsql_gleam.TextVal(id)])
  row_to_step(row)
}

pub fn get_steps_for_instance(
  conn: DbConnection,
  instance_id: String,
) -> Result(List(StepExecution), DbError) {
  let sql = {
    "SELECT * FROM step_executions WHERE flow_instance_id = ? "
    <> "ORDER BY created_at DESC"
  }
  use rows <- connection.query(conn, sql, [libsql_gleam.TextVal(instance_id)])
  list.map(rows, row_to_step) |> result.all
}

pub fn get_steps_for_task(
  conn: DbConnection,
  task_id: String,
) -> Result(List(StepExecution), DbError) {
  let sql = {
    "SELECT * FROM step_executions WHERE task_id = ? ORDER BY created_at DESC"
  }
  use rows <- connection.query(conn, sql, [libsql_gleam.TextVal(task_id)])
  list.map(rows, row_to_step) |> result.all
}

// ─── Row Mapping ─────────────────────────────────────────────────────────

fn row_to_execution_state(row: List(libsql_gleam.Value)) -> Result(ExecutionState, DbError) {
  case row {
    [
      libsql_gleam.TextVal(id),
      libsql_gleam.TextVal(_instance_id),
      libsql_gleam.TextVal(task_id),
      libsql_gleam.TextVal(status_str),
      current_node_raw,
      libsql_gleam.TextVal(_loop_counters_json),
      libsql_gleam.TextVal(_variables_json),
      libsql_gleam.TextVal(_parallel_json),
      started_raw,
      completed_raw,
      libsql_gleam.IntVal(_created_at),
      libsql_gleam.IntVal(_updated_at),
    ] -> {
      use status <- result.map_err(
        execution_status_from_string(status_str),
        fn(e) { connection.QueryError(e) },
      )

      // We'd need to load the FlowInstance separately
      // For now return a placeholder
      Error(connection.QueryError("ExecutionState requires FlowInstance join"))
    }
    _ -> Error(connection.QueryError("Invalid execution state row"))
  }
}

fn row_to_step(row: List(libsql_gleam.Value)) -> Result(StepExecution, DbError) {
  case row {
    [
      libsql_gleam.TextVal(id),
      libsql_gleam.TextVal(flow_instance_id),
      libsql_gleam.TextVal(_exec_state_id),
      libsql_gleam.TextVal(node_id),
      libsql_gleam.TextVal(task_id),
      libsql_gleam.TextVal(status_str),
      prompt_raw,
      output_raw,
      transition_raw,
      model_raw,
      libsql_gleam.IntVal(input_tokens),
      libsql_gleam.IntVal(output_tokens),
      libsql_gleam.FloatVal(cost),
      libsql_gleam.IntVal(duration_ms),
      session_raw,
      libsql_gleam.IntVal(created_at),
      completed_raw,
    ] -> {
      use status <- result.map_err(
        step_status_from_string(status_str),
        fn(e) { connection.QueryError(e) },
      )

      Ok(StepExecution(
        id: id,
        flow_instance_id: flow_instance_id,
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

fn option_to_text(opt: Option(String)) -> libsql_gleam.Value {
  case opt {
    Some(v) -> libsql_gleam.TextVal(v)
    None -> libsql_gleam.NullVal
  }
}

fn int_option_to_val(opt: Option(Int)) -> libsql_gleam.Value {
  case opt {
    Some(v) -> libsql_gleam.IntVal(v)
    None -> libsql_gleam.NullVal
  }
}

fn int_option(val: libsql_gleam.Value) -> Option(Int) {
  case val {
    libsql_gleam.IntVal(v) -> Some(v)
    _ -> None
  }
}

fn text_option(val: libsql_gleam.Value) -> Option(String) {
  case val {
    libsql_gleam.TextVal(v) -> Some(v)
    _ -> None
  }
}
