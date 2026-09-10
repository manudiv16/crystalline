//// Step executor loop for Crystalline flows.
////
//// This is the only module allowed to talk to a provider harness: the pure
//// flow engine (C7) produces an `Action`, the executor performs it against a
//// C9 adapter, persists the result through the C8 store, and feeds the outcome
//// back into the engine. Nothing else in the codebase should import
//// `sacrum_gleam/harness/contract`.
////
//// Execution model
//// ---------------
//// `run_until_wait` advances the flow one node at a time until it must stop:
////
////   - `RunStep`      -> run the adapter, persist metrics + session logs,
////                       then `complete_step` and continue with the next action
////   - `RunParallel`  -> run every child step, join the outputs, complete the
////                       parallel node and continue
////   - `AwaitInput`   -> persist `awaiting_input` and return
////   - `FlowComplete` -> apply chaining, persist `completed` and return
////   - `FlowReject`   -> apply chaining, persist `rejected` and return
////   - `ExecutionError` -> persist `failed` and return the diagnostic
////
//// Guards: a hard per-invocation iteration cap, a 30 minute wall-clock
//// timeout, and a cancellation check. All three persist `failed` before
//// returning so an operator can see why the run stopped.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some, unwrap}
import gleam/result
import gleam/string
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/domain/execution.{
  type ExecutionState, type ExecutionStatus, type StepExecution, type StepStatus,
  AwaitingInput, Cancelled, Completed, ExecutionState, Failed, Rejected,
  StepCompleted, StepExecution, StepFailed, execution_status_to_string,
}
import sacrum_gleam/domain/flow.{type AgentConfig, type Node}
import sacrum_gleam/flow/engine as flow_engine
import sacrum_gleam/flow/executor.{
  type Action, AwaitInput, ExecutionError, FlowComplete, FlowReject, RunParallel,
  RunStep,
}
import sacrum_gleam/harness/contract

// ─── Configuration ───────────────────────────────────────────────────────

/// Default wall-clock budget for a single `run_until_wait` invocation: 30 min.
pub const default_timeout_ms: Int = 1_800_000

/// Default hard cap on node transitions per invocation. This is a safety net
/// against a misbehaving graph; a well-formed flow never comes close.
pub const default_max_iterations: Int = 1000

/// Default model when a node carries no `AgentConfig`.
const default_model = "claude-sonnet-4-20250514"

// ─── Public types ────────────────────────────────────────────────────────

/// A provider harness, as defined by the C9 contract. The executor is the only
/// caller; the type is re-exported here so tests can inject a stub.
pub type Harness =
  fn(contract.Request) -> Result(contract.Result, contract.AdapterError)

/// Persistence + worktree resolution, injected so the loop can be exercised
/// without touching libsql. The production implementation lives in
/// `sacrum_gleam/runtime/store`.
pub type Store {
  Store(
    /// Persist the execution status and its mutable state.
    save_status: fn(DbConnection, ExecutionState, Int) ->
      Result(Nil, RuntimeError),
    /// Persist one step execution.
    save_step: fn(DbConnection, StepExecution, Int) -> Result(Nil, RuntimeError),
    /// Append a session log event; the store assigns the per-step sequence.
    append_log: fn(DbConnection, String, String, String, String, Int) ->
      Result(Nil, RuntimeError),
    /// Resolve the working directory for a task, falling back to the project
    /// root when the task has no worktree.
    workdir: fn(DbConnection, String, String) -> Result(String, RuntimeError),
  )
}

/// Everything `run_until_wait` needs besides the database connection.
pub type Engine {
  Engine(
    flow: flow_engine.Engine,
    harness: Harness,
    store: Store,
    /// Directory the harness runs in when a task has no worktree.
    project_root: String,
    timeout_ms: Int,
    max_iterations: Int,
    /// Wall-clock source in milliseconds; injectable for deterministic tests.
    now: fn() -> Int,
  )
}

/// Errors that stop a run.
pub type RuntimeError {
  /// The pure engine rejected a transition.
  EngineFailure(message: String)
  /// The adapter binary was missing or unusable.
  HarnessUnavailable(node_id: String, reason: String)
  /// The adapter exited non-zero (or reported an error result).
  AdapterFailure(node_id: String, code: Int, output: String)
  /// The flow graph is broken (unknown node, missing config, ...).
  GraphError(message: String)
  /// Wall-clock budget exceeded.
  Timeout(instance_id: String, elapsed_ms: Int, limit_ms: Int)
  /// The per-invocation transition cap was hit.
  IterationCapExceeded(limit: Int)
  /// A database write failed.
  PersistenceFailure(message: String)
  /// The execution was cancelled externally.
  CancelledExecution(instance_id: String)
}

// ─── Construction ────────────────────────────────────────────────────────

/// Build an engine with production defaults.
pub fn new_engine(
  flow: flow_engine.Engine,
  harness: Harness,
  store: Store,
  project_root: String,
) -> Engine {
  Engine(
    flow: flow,
    harness: harness,
    store: store,
    project_root: project_root,
    timeout_ms: default_timeout_ms,
    max_iterations: default_max_iterations,
    now: system_time_ms,
  )
}

/// Override the per-invocation timeout.
pub fn with_timeout(engine: Engine, timeout_ms: Int) -> Engine {
  Engine(..engine, timeout_ms: timeout_ms)
}

/// Override the per-invocation iteration cap.
pub fn with_max_iterations(engine: Engine, max_iterations: Int) -> Engine {
  Engine(..engine, max_iterations: max_iterations)
}

/// Override the wall-clock source (tests).
pub fn with_clock(engine: Engine, now: fn() -> Int) -> Engine {
  Engine(..engine, now: now)
}

/// A store that drops every write. Useful for tests and for a dry run.
pub fn noop_store() -> Store {
  Store(
    save_status: fn(_conn, _state, _now) { Ok(Nil) },
    save_step: fn(_conn, _step, _now) { Ok(Nil) },
    append_log: fn(_conn, _step_id, _task_id, _kind, _payload, _now) { Ok(Nil) },
    workdir: fn(_conn, _task_id, fallback) { Ok(fallback) },
  )
}

/// Current wall clock in milliseconds.
pub fn system_time_ms() -> Int {
  erlang_system_time() / 1_000_000
}

@external(erlang, "erlang", "system_time")
fn erlang_system_time() -> Int

// ─── Entry points ────────────────────────────────────────────────────────

/// Drive an execution until it must wait for a human, completes, or fails.
///
/// Runs at most `engine.max_iterations` transitions within
/// `engine.timeout_ms` milliseconds. Every transition is persisted through the
/// engine's `Store`.
pub fn run_until_wait(
  conn: DbConnection,
  engine: Engine,
  instance_id: String,
) -> Result(ExecutionState, RuntimeError) {
  let started_at = engine.now()

  use state <- result.try(get_state(engine.flow, instance_id))

  case state.status {
    Cancelled -> Error(CancelledExecution(instance_id))
    _ ->
      case flow_engine.advance_execution(engine.flow, instance_id) {
        Error(e) -> Error(engine_failure(e))
        Ok(#(flow, _id, action)) -> {
          let engine = Engine(..engine, flow: flow)
          dispatch(conn, engine, instance_id, action, started_at, 0)
        }
      }
  }
}

/// Resume an execution parked at `AwaitInput` with the supplied input and keep
/// driving until the next stop condition.
pub fn resume(
  conn: DbConnection,
  engine: Engine,
  instance_id: String,
  input: String,
) -> Result(ExecutionState, RuntimeError) {
  let started_at = engine.now()

  case flow_engine.provide_input(engine.flow, instance_id, input) {
    Error(e) -> Error(engine_failure(e))
    Ok(#(flow, _id, action)) -> {
      let engine = Engine(..engine, flow: flow)
      dispatch(conn, engine, instance_id, action, started_at, 0)
    }
  }
}

/// Mark an execution as cancelled. A subsequent `run_until_wait` observes this
/// before dispatching any further step.
pub fn cancel(
  conn: DbConnection,
  engine: Engine,
  instance_id: String,
) -> Result(ExecutionState, RuntimeError) {
  use state <- result.try(get_state(engine.flow, instance_id))

  let now = engine.now()
  let state =
    ExecutionState(..state, status: Cancelled, completed_at: Some(now))
  use _ <- result.try(save_status(conn, engine.store, state, now))
  Ok(state)
}

// ─── Loop ────────────────────────────────────────────────────────────────

fn dispatch(
  conn: DbConnection,
  engine: Engine,
  instance_id: String,
  action: Action,
  started_at: Int,
  iterations: Int,
) -> Result(ExecutionState, RuntimeError) {
  case guard_error(engine, instance_id, started_at, iterations) {
    Error(err) -> {
      let _ = fail_execution(conn, engine, instance_id, error_to_string(err))
      Error(err)
    }
    Ok(_) -> {
      case action {
        RunStep(node, prompt) ->
          run_step(
            conn,
            engine,
            instance_id,
            node,
            prompt,
            started_at,
            iterations,
          )
        AwaitInput(_node) -> await_input(conn, engine, instance_id)
        RunParallel(children) ->
          run_parallel(
            conn,
            engine,
            instance_id,
            children,
            started_at,
            iterations,
          )
        FlowComplete -> flow_complete(conn, engine, instance_id)
        FlowReject -> flow_reject(conn, engine, instance_id)
        ExecutionError(message) ->
          execution_error(conn, engine, instance_id, message)
      }
    }
  }
}

fn guard_error(
  engine: Engine,
  instance_id: String,
  started_at: Int,
  iterations: Int,
) -> Result(Nil, RuntimeError) {
  use state <- result.try(get_state(engine.flow, instance_id))

  case state.status {
    Cancelled -> Error(CancelledExecution(instance_id))
    _ -> {
      let elapsed = engine.now() - started_at
      case elapsed > engine.timeout_ms {
        True ->
          Error(Timeout(
            instance_id: instance_id,
            elapsed_ms: elapsed,
            limit_ms: engine.timeout_ms,
          ))
        False ->
          case iterations > engine.max_iterations {
            True -> Error(IterationCapExceeded(engine.max_iterations))
            False -> Ok(Nil)
          }
      }
    }
  }
}

// ─── Action handlers ─────────────────────────────────────────────────────

fn run_step(
  conn: DbConnection,
  engine: Engine,
  instance_id: String,
  node: Node,
  prompt: String,
  started_at: Int,
  iterations: Int,
) -> Result(ExecutionState, RuntimeError) {
  use state <- result.try(get_state(engine.flow, instance_id))
  let now = engine.now()
  use workdir <- result.try(resolve_workdir(conn, engine, state.task_id))

  let request = build_request(node, prompt, workdir)

  case engine.harness(request) {
    Error(adapter_error) ->
      fail_step(
        conn,
        engine,
        instance_id,
        state,
        node,
        prompt,
        adapter_error_to_string(adapter_error),
        adapter_error_code(adapter_error),
        now,
      )
    Ok(result) -> {
      let step = build_step(state, node, prompt, result, now)
      use _ <- result.try(save_step(conn, engine.store, step, now))
      use _ <- result.try(append_log(
        conn,
        engine.store,
        step.id,
        state.task_id,
        "outcome",
        result.output,
        now,
      ))
      use _ <- result.try(append_log(
        conn,
        engine.store,
        step.id,
        state.task_id,
        "usage",
        usage_payload(result),
        now,
      ))

      case step.status {
        StepFailed -> {
          let failed =
            ExecutionState(..state, status: Failed, completed_at: Some(now))
          use _ <- result.try(save_status(conn, engine.store, failed, now))
          Error(AdapterFailure(node_id: node.id, code: 0, output: result.output))
        }
        _ -> {
          case
            flow_engine.complete_step(
              engine.flow,
              instance_id,
              step,
              result.output,
            )
          {
            Error(e) -> Error(engine_failure(e))
            Ok(#(flow, _id, next_action)) -> {
              let engine = Engine(..engine, flow: flow)
              dispatch(
                conn,
                engine,
                instance_id,
                next_action,
                started_at,
                iterations + 1,
              )
            }
          }
        }
      }
    }
  }
}

fn await_input(
  conn: DbConnection,
  engine: Engine,
  instance_id: String,
) -> Result(ExecutionState, RuntimeError) {
  use state <- result.try(get_state(engine.flow, instance_id))

  let now = engine.now()
  let state = ExecutionState(..state, status: AwaitingInput)
  use _ <- result.try(save_status(conn, engine.store, state, now))
  Ok(state)
}

fn run_parallel(
  conn: DbConnection,
  engine: Engine,
  instance_id: String,
  children: List(Node),
  started_at: Int,
  iterations: Int,
) -> Result(ExecutionState, RuntimeError) {
  use state <- result.try(get_state(engine.flow, instance_id))
  let now = engine.now()

  use child_steps <- result.try(run_children(conn, engine, state, children, now))

  let combined =
    child_steps
    |> list.map(fn(s) { unwrap(s.output, "") })
    |> string.join("\n")

  let parallel_node_id = unwrap(state.current_node_id, "_parallel")
  let step =
    StepExecution(
      id: generated_id(parallel_node_id, now),
      flow_instance_id: state.flow_instance.id,
      execution_state_id: state.id,
      node_id: parallel_node_id,
      task_id: state.task_id,
      status: StepCompleted,
      prompt: Some("parallel"),
      output: Some(combined),
      transition_result: None,
      model: None,
      input_tokens: 0,
      output_tokens: 0,
      cost: 0.0,
      duration_ms: 0,
      session_id: None,
      created_at: now,
      completed_at: Some(now),
    )

  use _ <- result.try(save_step(conn, engine.store, step, now))

  case flow_engine.complete_step(engine.flow, instance_id, step, combined) {
    Error(e) -> Error(engine_failure(e))
    Ok(#(flow, _id, next_action)) -> {
      let engine = Engine(..engine, flow: flow)
      dispatch(
        conn,
        engine,
        instance_id,
        next_action,
        started_at,
        iterations + 1,
      )
    }
  }
}

fn run_children(
  conn: DbConnection,
  engine: Engine,
  state: ExecutionState,
  children: List(Node),
  now: Int,
) -> Result(List(StepExecution), RuntimeError) {
  children
  |> list.try_fold([], fn(acc, node) {
    use workdir <- result.try(resolve_workdir(conn, engine, state.task_id))
    let prompt = prompt_for(node)
    let request = build_request(node, prompt, workdir)

    case engine.harness(request) {
      Error(adapter_error) ->
        Error(HarnessUnavailable(
          node_id: node.id,
          reason: adapter_error_to_string(adapter_error),
        ))
      Ok(result) -> {
        let step = build_step(state, node, prompt, result, now)
        use _ <- result.try(save_step(conn, engine.store, step, now))
        Ok([step, ..acc])
      }
    }
  })
  |> result.map(list.reverse)
}

fn flow_complete(
  conn: DbConnection,
  engine: Engine,
  instance_id: String,
) -> Result(ExecutionState, RuntimeError) {
  use state <- result.try(get_state(engine.flow, instance_id))
  let now = engine.now()

  case
    flow_engine.handle_flow_complete(engine.flow, instance_id, state.task_id)
  {
    Error(e) -> Error(engine_failure(e))
    Ok(#(_flow, _next_instance)) -> {
      let state =
        ExecutionState(..state, status: Completed, completed_at: Some(now))
      use _ <- result.try(save_status(conn, engine.store, state, now))
      Ok(state)
    }
  }
}

fn flow_reject(
  conn: DbConnection,
  engine: Engine,
  instance_id: String,
) -> Result(ExecutionState, RuntimeError) {
  use state <- result.try(get_state(engine.flow, instance_id))
  let now = engine.now()

  case flow_engine.handle_flow_reject(engine.flow, instance_id, state.task_id) {
    Error(e) -> Error(engine_failure(e))
    Ok(#(_flow, _next_instance)) -> {
      let state =
        ExecutionState(..state, status: Rejected, completed_at: Some(now))
      use _ <- result.try(save_status(conn, engine.store, state, now))
      Ok(state)
    }
  }
}

fn execution_error(
  conn: DbConnection,
  engine: Engine,
  instance_id: String,
  message: String,
) -> Result(ExecutionState, RuntimeError) {
  use state <- result.try(get_state(engine.flow, instance_id))
  let now = engine.now()
  let _ = fail_execution(conn, engine, instance_id, message)
  let state = ExecutionState(..state, status: Failed, completed_at: Some(now))
  Ok(state)
}

// ─── Failure helpers ─────────────────────────────────────────────────────

fn fail_step(
  conn: DbConnection,
  engine: Engine,
  _instance_id: String,
  state: ExecutionState,
  node: Node,
  prompt: String,
  message: String,
  code: Int,
  now: Int,
) -> Result(ExecutionState, RuntimeError) {
  let step =
    StepExecution(
      id: generated_id(node.id, now),
      flow_instance_id: state.flow_instance.id,
      execution_state_id: state.id,
      node_id: node.id,
      task_id: state.task_id,
      status: StepFailed,
      prompt: Some(prompt),
      output: Some(message),
      transition_result: None,
      model: None,
      input_tokens: 0,
      output_tokens: 0,
      cost: 0.0,
      duration_ms: 0,
      session_id: None,
      created_at: now,
      completed_at: Some(now),
    )

  use _ <- result.try(save_step(conn, engine.store, step, now))
  use _ <- result.try(append_log(
    conn,
    engine.store,
    step.id,
    state.task_id,
    "error",
    message,
    now,
  ))
  let failed = ExecutionState(..state, status: Failed, completed_at: Some(now))
  use _ <- result.try(save_status(conn, engine.store, failed, now))
  Error(AdapterFailure(node_id: node.id, code: code, output: message))
}

/// Persist a failure that is not tied to a specific adapter call (timeout,
/// iteration cap, engine error). A synthetic step execution anchors the session
/// log so the `session_logs.step_execution_id` foreign key stays valid.
fn fail_execution(
  conn: DbConnection,
  engine: Engine,
  instance_id: String,
  message: String,
) -> Result(Nil, RuntimeError) {
  use state <- result.try(get_state(engine.flow, instance_id))

  let now = engine.now()
  let node_id = unwrap(state.current_node_id, "_execution")
  let step =
    StepExecution(
      id: generated_id(node_id, now),
      flow_instance_id: state.flow_instance.id,
      execution_state_id: state.id,
      node_id: node_id,
      task_id: state.task_id,
      status: StepFailed,
      prompt: None,
      output: Some(message),
      transition_result: None,
      model: None,
      input_tokens: 0,
      output_tokens: 0,
      cost: 0.0,
      duration_ms: 0,
      session_id: None,
      created_at: now,
      completed_at: Some(now),
    )

  use _ <- result.try(save_step(conn, engine.store, step, now))
  use _ <- result.try(append_log(
    conn,
    engine.store,
    step.id,
    state.task_id,
    "error",
    message,
    now,
  ))
  let failed = ExecutionState(..state, status: Failed, completed_at: Some(now))
  save_status(conn, engine.store, failed, now)
}

// ─── Store adapters ──────────────────────────────────────────────────────

fn get_state(
  flow: flow_engine.Engine,
  instance_id: String,
) -> Result(ExecutionState, RuntimeError) {
  case flow_engine.get_execution(flow, instance_id) {
    Ok(state) -> Ok(state)
    Error(e) -> Error(engine_failure(e))
  }
}

fn save_status(
  conn: DbConnection,
  store: Store,
  state: ExecutionState,
  now: Int,
) -> Result(Nil, RuntimeError) {
  store.save_status(conn, state, now)
}

fn save_step(
  conn: DbConnection,
  store: Store,
  step: StepExecution,
  now: Int,
) -> Result(Nil, RuntimeError) {
  store.save_step(conn, step, now)
}

fn append_log(
  conn: DbConnection,
  store: Store,
  step_execution_id: String,
  task_id: String,
  event_type: String,
  payload: String,
  now: Int,
) -> Result(Nil, RuntimeError) {
  store.append_log(conn, step_execution_id, task_id, event_type, payload, now)
}

fn resolve_workdir(
  conn: DbConnection,
  engine: Engine,
  task_id: String,
) -> Result(String, RuntimeError) {
  engine.store.workdir(conn, task_id, engine.project_root)
}

// ─── Request building ────────────────────────────────────────────────────

fn build_request(
  node: Node,
  prompt: String,
  workdir: String,
) -> contract.Request {
  case node.agent_config {
    Some(config) -> agent_config_request(node, config, prompt, workdir)
    None -> contract.default_request(workdir, prompt, default_model)
  }
}

fn agent_config_request(
  node: Node,
  config: AgentConfig,
  prompt: String,
  workdir: String,
) -> contract.Request {
  contract.Request(
    cwd: workdir,
    prompt: prompt,
    model: config.model,
    fallback_model: config.fallback_model,
    system_prompt: config.system_prompt,
    allowed_tools: config.allowed_tools,
    disallowed_tools: config.disallowed_tools,
    permission_mode: config.permission_mode,
    max_budget_usd: config.max_budget_usd,
    output_schema: node.output_schema,
  )
}

fn prompt_for(node: Node) -> String {
  case node.prompt {
    Some(p) -> p
    None -> node.goal
  }
}

// ─── Result mapping ──────────────────────────────────────────────────────

fn build_step(
  state: ExecutionState,
  node: Node,
  prompt: String,
  result: contract.Result,
  now: Int,
) -> StepExecution {
  StepExecution(
    id: generated_id(node.id, now),
    flow_instance_id: state.flow_instance.id,
    execution_state_id: state.id,
    node_id: node.id,
    task_id: state.task_id,
    status: result_status_to_step_status(result.status),
    prompt: Some(prompt),
    output: Some(result.output),
    transition_result: None,
    model: Some(result.model_used),
    input_tokens: result.input_tokens,
    output_tokens: result.output_tokens,
    cost: result.cost,
    duration_ms: result.duration_ms,
    session_id: result.session_id,
    created_at: now,
    completed_at: Some(now),
  )
}

fn result_status_to_step_status(status: contract.ResultStatus) -> StepStatus {
  case status {
    contract.Success -> StepCompleted
    contract.Warning -> StepCompleted
    contract.Failed -> StepFailed
    contract.Cancelled -> StepFailed
  }
}

fn usage_payload(result: contract.Result) -> String {
  "{\"model\":"
  <> json_string(result.model_used)
  <> ",\"input_tokens\":"
  <> int.to_string(result.input_tokens)
  <> ",\"output_tokens\":"
  <> int.to_string(result.output_tokens)
  <> ",\"cost\":"
  <> float.to_string(result.cost)
  <> ",\"duration_ms\":"
  <> int.to_string(result.duration_ms)
  <> "}"
}

fn adapter_error_to_string(error: contract.AdapterError) -> String {
  case error {
    contract.NotFound(command) -> "harness binary not found: " <> command
    contract.ProcessError(code, stderr) ->
      "harness exited with code " <> int.to_string(code) <> ": " <> stderr
    contract.Timeout(ms) ->
      "harness timed out after " <> int.to_string(ms) <> "ms"
    contract.BudgetExceeded(limit, spent) ->
      "harness budget exceeded: limit="
      <> float.to_string(limit)
      <> " spent="
      <> float.to_string(spent)
    contract.InvalidRequest(reason) -> "invalid harness request: " <> reason
    contract.ParseError(reason) -> "harness output parse error: " <> reason
    contract.IoError(reason) -> "harness I/O error: " <> reason
    contract.ProviderError(reason) -> "harness provider error: " <> reason
  }
}

fn adapter_error_code(error: contract.AdapterError) -> Int {
  case error {
    contract.ProcessError(code, _) -> code
    _ -> 0
  }
}

fn engine_failure(error: flow_engine.EngineError) -> RuntimeError {
  GraphError(engine_error_to_string(error))
}

fn engine_error_to_string(error: flow_engine.EngineError) -> String {
  case error {
    flow_engine.ValidationError(_) -> "flow validation failed"
    flow_engine.NoSuchTemplate(id) -> "no such template: " <> id
    flow_engine.NoSuchInstance(id) -> "no such instance: " <> id
    flow_engine.NoSuchStep(id) -> "no such step: " <> id
    flow_engine.InvalidStateTransition(from, to) ->
      "invalid state transition: "
      <> execution_status_string(from)
      <> " -> "
      <> execution_status_string(to)
  }
}

fn execution_status_string(status: ExecutionStatus) -> String {
  execution_status_to_string(status)
}

/// Human-readable rendering used for persisted diagnostics.
pub fn error_to_string(error: RuntimeError) -> String {
  case error {
    EngineFailure(message) -> message
    HarnessUnavailable(node_id, reason) -> "[" <> node_id <> "] " <> reason
    AdapterFailure(node_id, code, output) ->
      "["
      <> node_id
      <> "] step failed (code "
      <> int.to_string(code)
      <> "): "
      <> output
    GraphError(message) -> message
    Timeout(instance_id, elapsed_ms, limit_ms) ->
      "["
      <> instance_id
      <> "] timed out after "
      <> int.to_string(elapsed_ms)
      <> "ms (limit "
      <> int.to_string(limit_ms)
      <> "ms)"
    IterationCapExceeded(limit) ->
      "iteration cap exceeded: " <> int.to_string(limit)
    PersistenceFailure(message) -> "persistence failure: " <> message
    CancelledExecution(instance_id) -> "execution cancelled: " <> instance_id
  }
}

// ─── Small helpers ───────────────────────────────────────────────────────

fn generated_id(seed: String, now: Int) -> String {
  seed <> "@" <> int.to_string(now)
}

fn json_string(value: String) -> String {
  "\""
  <> string.replace(string.replace(value, "\\", "\\\\"), "\"", "\\\"")
  <> "\""
}
