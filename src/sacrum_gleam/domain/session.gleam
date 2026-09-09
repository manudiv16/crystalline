import gleam/option.{Option, Some, None}

/// Session logs for step executions.
/// Each step execution produces a stream of events (text, tool use, usage).

pub type SessionLog {
  SessionLog(
    id: String,
    step_execution_id: String,
    task_id: String,
    event_type: String,
    payload: String,
    sequence: Int,
    created_at: Int,
  )
}

/// Append an event to a session log.
pub fn new_session_log(
  step_execution_id: String,
  task_id: String,
  event_type: String,
  payload: String,
  sequence: Int,
) -> SessionLog {
  SessionLog(
    id: "",
    step_execution_id: step_execution_id,
    task_id: task_id,
    event_type: event_type,
    payload: payload,
    sequence: sequence,
    created_at: 0,
  )
}
