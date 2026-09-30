import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import sacrum_gleam/domain/flow.{type FlowInstance}

/// Execution state for a FlowInstance running against a Task.
///
/// The executor tracks:
/// - current_node: which node is being processed right now
/// - active_stack: for composite nodes (Sequence, Loop, Parallel),
///   which child indices are being worked on
/// - step_history: ordered log of every step execution
/// - loop_counters: track iteration counts per loop node
/// - variables: runtime variable store for condition evaluation
pub type ExecutionStatus {
  /// Flow hasn't started yet
  Pending
  /// Actively executing nodes
  Running
  /// Paused waiting for human input
  AwaitingInput
  /// All nodes completed successfully
  Completed
  /// Task was rejected/rolled back
  Rejected
  /// An error halted execution
  Failed
  /// Explicitly cancelled
  Cancelled
}

pub type StepStatus {
  StepPending
  StepEntered
  StepInProgress
  StepCompleted
  StepFailed
  StepCancelled
}

pub type StepExecution {
  StepExecution(
    id: String,
    flow_instance_id: String,
    execution_state_id: String,
    node_id: String,
    task_id: String,
    status: StepStatus,
    prompt: Option(String),
    output: Option(String),
    /// For evaluate/branch: which transition was taken
    transition_result: Option(String),
    model: Option(String),
    input_tokens: Int,
    output_tokens: Int,
    cost: Float,
    duration_ms: Int,
    session_id: Option(String),
    created_at: Int,
    completed_at: Option(Int),
  )
}

pub type ExecutionState {
  ExecutionState(
    id: String,
    flow_instance: FlowInstance,
    task_id: String,
    status: ExecutionStatus,
    /// Node currently being executed
    current_node_id: Option(String),
    /// Ordered log of step executions
    step_history: List(StepExecution),
    /// Loop node ID → iteration count
    loop_counters: Dict(String, Int),
    /// Runtime variables set by steps, read by conditions
    variables: Dict(String, String),
    /// For Parallel: child IDs still running
    parallel_active: List(String),
    started_at: Option(Int),
    completed_at: Option(Int),
  )
}

pub fn new_execution_state(
  flow_instance: FlowInstance,
  task_id: String,
) -> ExecutionState {
  ExecutionState(
    id: "",
    flow_instance: flow_instance,
    task_id: task_id,
    status: Pending,
    current_node_id: None,
    step_history: [],
    loop_counters: dict.new(),
    variables: dict.new(),
    parallel_active: [],
    started_at: None,
    completed_at: None,
  )
}

/// Whether an execution status represents a finished lifecycle.
pub fn is_terminal(status: ExecutionStatus) -> Bool {
  case status {
    Completed -> True
    Rejected -> True
    Failed -> True
    Cancelled -> True
    Pending -> False
    Running -> False
    AwaitingInput -> False
  }
}

/// Normalize persisted lifecycle timestamps using the same rules for every writer.
///
/// Pending executions have not started. Active executions retain a valid start
/// time or receive `now`; terminal executions likewise retain a valid completion
/// time or receive `now`. Non-terminal executions never have a completion time.
pub fn with_lifecycle(state: ExecutionState, now: Int) -> ExecutionState {
  let started_at = case state.status {
    Pending -> None
    _ ->
      case state.started_at {
        Some(timestamp) if timestamp > 0 -> Some(timestamp)
        _ -> Some(now)
      }
  }
  let completed_at = case is_terminal(state.status) {
    True ->
      case state.completed_at {
        Some(timestamp) if timestamp > 0 -> Some(timestamp)
        _ -> Some(now)
      }
    False -> None
  }
  ExecutionState(..state, started_at: started_at, completed_at: completed_at)
}

pub fn step_status_to_string(s: StepStatus) -> String {
  case s {
    StepPending -> "pending"
    StepEntered -> "entered"
    StepInProgress -> "in_progress"
    StepCompleted -> "completed"
    StepFailed -> "failed"
    StepCancelled -> "cancelled"
  }
}

pub fn execution_status_to_string(s: ExecutionStatus) -> String {
  case s {
    Pending -> "pending"
    Running -> "running"
    AwaitingInput -> "awaiting_input"
    Completed -> "completed"
    Rejected -> "rejected"
    Failed -> "failed"
    Cancelled -> "cancelled"
  }
}
