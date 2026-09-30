//// Production libsql store for the step runtime.
////
//// Persists execution state, step results, and session-log events through the
//// database layer and resolves a task worktree before falling back to the
//// configured project root.

import gleam/option.{Some}
import gleam/result
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/db/executions
import sacrum_gleam/db/session_logs
import sacrum_gleam/db/tasks
import sacrum_gleam/domain/execution.{type ExecutionState, type StepExecution}
import sacrum_gleam/runtime/executor as runtime

/// Build the production store used by the daemon.
pub fn new_store() -> runtime.Store {
  runtime.Store(
    save_status: save_status,
    save_step: save_step,
    append_log: append_log,
    workdir: workdir,
  )
}

fn save_status(
  conn: DbConnection,
  state: ExecutionState,
  now: Int,
) -> Result(Nil, runtime.RuntimeError) {
  executions.save_execution_state(conn, state, now)
  |> result.map_error(persistence_failure)
}

fn save_step(
  conn: DbConnection,
  step: StepExecution,
  now: Int,
) -> Result(Nil, runtime.RuntimeError) {
  executions.create_step_execution(conn, step, now)
  |> result.map(fn(_) { Nil })
  |> result.map_error(persistence_failure)
}

fn append_log(
  conn: DbConnection,
  step_id: String,
  task_id: String,
  event_type: String,
  payload: String,
  now: Int,
) -> Result(Nil, runtime.RuntimeError) {
  session_logs.append_log(conn, step_id, task_id, event_type, payload, now)
  |> result.map(fn(_) { Nil })
  |> result.map_error(persistence_failure)
}

fn workdir(
  conn: DbConnection,
  task_id: String,
  project_root: String,
) -> Result(String, runtime.RuntimeError) {
  case tasks.get_task(conn, task_id) {
    Ok(task) ->
      case task.worktree {
        Some(path) if path != "" -> Ok(path)
        _ -> Ok(project_root)
      }
    Error(error) -> Error(persistence_failure(error))
  }
}

fn persistence_failure(error: connection.DbError) -> runtime.RuntimeError {
  runtime.PersistenceFailure(connection.error_to_string(error))
}
