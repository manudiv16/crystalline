//// Acceptance tests for the step executor loop (C10).
////
//// These tests drive `run_until_wait` end to end against an in-memory flow
//// engine, a recording store (persistence contract of C8) and a stub harness
//// (C9 adapter contract). The database connection is only threaded through to
//// the injected store, so the libsql NIF is never touched by the executor.
////
//// The recorder uses the Erlang process dictionary so each test can capture
//// every `save_status` / `save_step` / `append_log` call the executor makes.
//// Gleam tests run in isolated processes; keys are scoped per test anyway.

import gleam/dict
import gleam/list
import gleam/option.{None, Some, unwrap}
import gleam/string
import gleeunit
import gleeunit/should
import libsql
import sacrum_gleam/db/connection.{type DbConnection, DbConnection}
import sacrum_gleam/domain/execution.{
  type ExecutionState, type StepExecution, AwaitingInput, Cancelled, Completed,
  Failed, StepCompleted, StepFailed,
}
import sacrum_gleam/domain/flow
import sacrum_gleam/flow/engine as flow_engine
import sacrum_gleam/harness/contract
import sacrum_gleam/runtime/executor as runtime

pub fn main() -> Nil {
  gleeunit.main()
}

// ─── Fixtures ───────────────────────────────────────────────────────────

const instance_id = ""

const task_id = "task-t1"

const model = "claude-sonnet-4-20250514"

/// The executor only threads the connection through to the injected store
/// (C8 persistence); it never runs SQL itself. The production wiring passes a
/// real `connect/2` result, while unit tests use a phantom `libsql.Connection`
/// so the loop can be exercised without the libsql NIF being available.
/// The store callbacks in these tests ignore the connection entirely.
pub fn test_conn() -> DbConnection {
  DbConnection(conn: phantom_libsql_connection())
}

@external(erlang, "erlang", "make_ref")
fn phantom_libsql_connection() -> libsql.Connection

/// A store that records every write the executor makes into the process dict,
/// so the persistence contract can be asserted on afterwards.
fn recording_store(key: String) -> runtime.Store {
  let _ = pd_erase(key <> ":statuses")
  let _ = pd_erase(key <> ":steps")
  let _ = pd_erase(key <> ":logs")
  let _ = pd_erase(key <> ":harness_calls")
  let _ = pd_put(key <> ":statuses", [])
  let _ = pd_put(key <> ":steps", [])
  let _ = pd_put(key <> ":logs", [])
  let _ = pd_put(key <> ":harness_calls", 0)

  runtime.Store(
    save_status: fn(_conn, execution_state, _now) {
      pd_put(key <> ":statuses", [execution_state, ..pd_get(key <> ":statuses")])
      Ok(Nil)
    },
    save_step: fn(_conn, step, _now) {
      pd_put(key <> ":steps", [step, ..pd_get(key <> ":steps")])
      Ok(Nil)
    },
    append_log: fn(_conn, _step_id, _task_id, event_type, payload, _now) {
      pd_put(key <> ":logs", [#(event_type, payload), ..pd_get(key <> ":logs")])
      Ok(Nil)
    },
    workdir: fn(_conn, _task_id, fallback) { Ok(fallback) },
  )
}

/// A harness stub that records how many times it was called and reports a
/// successful result echoing the request prompt.
fn counting_harness(key: String) -> runtime.Harness {
  fn(req: contract.Request) -> Result(contract.Result, contract.AdapterError) {
    pd_put(key <> ":harness_calls", harness_call_count(key) + 1)
    Ok(success_result("ran:" <> req.prompt))
  }
}

/// A harness stub that always fails with the given process exit code.
fn failing_harness(key: String, code: Int, stderr: String) -> runtime.Harness {
  fn(_req: contract.Request) -> Result(contract.Result, contract.AdapterError) {
    pd_put(key <> ":harness_calls", harness_call_count(key) + 1)
    Error(contract.ProcessError(code, stderr))
  }
}

fn success_result(output: String) -> contract.Result {
  contract.Result(
    status: contract.Success,
    output: output,
    model_used: model,
    input_tokens: 100,
    output_tokens: 50,
    cost: 0.0075,
    duration_ms: 120,
    session_id: None,
    error: None,
  )
}

/// An engine bound to a three-step linear flow (s1 → s2 → s3).
fn linear_engine(
  harness: runtime.Harness,
  store: runtime.Store,
) -> runtime.Engine {
  let template =
    flow_engine.build_linear_flow("linear", "three steps", [
      #("s1", "first step"),
      #("s2", "second step"),
      #("s3", "third step"),
    ])

  bind_engine(template, harness, store)
}

/// An engine bound to a flow whose only node is a HumanInput node.
fn human_input_engine(
  harness: runtime.Harness,
  store: runtime.Store,
) -> runtime.Engine {
  let nodes =
    dict.new()
    |> dict.insert(
      "ask",
      flow.Node(
        id: "ask",
        name: "Ask user",
        node_type: flow.HumanInput,
        goal: "ask for the colour",
        prompt: Some("Which colour?"),
        child_ids: [],
        branch_rules: [],
        loop_config: None,
        agent_config: None,
        output_schema: None,
      ),
    )

  let template =
    flow.FlowTemplate(
      id: "",
      name: "ask-flow",
      description: "waits for human input",
      initial_node_id: "ask",
      nodes: nodes,
      transitions: [],
      on_done_template_id: None,
      on_reject_template_id: None,
    )

  bind_engine(template, harness, store)
}

fn bind_engine(
  template: flow.FlowTemplate,
  harness: runtime.Harness,
  store: runtime.Store,
) -> runtime.Engine {
  let flow = flow_engine.new_engine()
  // The template registry key is the template id, which is "" for builders.
  let assert Ok(flow) = flow_engine.register_template(flow, template)
  let assert Ok(#(flow, _instance)) =
    flow_engine.instantiate_flow(flow, "", task_id)
  runtime.new_engine(flow, harness, store, "/tmp/crystalline")
}

/// An engine bound to a flow whose entry node is a Parallel composite with two
/// Step children (`both` → p1 + p2 → done).
fn parallel_engine(
  harness: runtime.Harness,
  store: runtime.Store,
) -> runtime.Engine {
  let nodes =
    dict.new()
    |> dict.insert(
      "both",
      flow.Node(
        id: "both",
        name: "Both branches",
        node_type: flow.Parallel,
        goal: "run both branches",
        prompt: None,
        child_ids: ["p1", "p2"],
        branch_rules: [],
        loop_config: None,
        agent_config: None,
        output_schema: None,
      ),
    )
    |> dict.insert(
      "p1",
      flow.Node(
        id: "p1",
        name: "Branch one",
        node_type: flow.Step,
        goal: "branch one",
        prompt: Some("branch one"),
        child_ids: [],
        branch_rules: [],
        loop_config: None,
        agent_config: None,
        output_schema: None,
      ),
    )
    |> dict.insert(
      "p2",
      flow.Node(
        id: "p2",
        name: "Branch two",
        node_type: flow.Step,
        goal: "branch two",
        prompt: Some("branch two"),
        child_ids: [],
        branch_rules: [],
        loop_config: None,
        agent_config: None,
        output_schema: None,
      ),
    )

  let template =
    flow.FlowTemplate(
      id: "",
      name: "parallel-flow",
      description: "runs two branches concurrently",
      initial_node_id: "both",
      nodes: nodes,
      transitions: [],
      on_done_template_id: None,
      on_reject_template_id: None,
    )

  bind_engine(template, harness, store)
}

/// A wall-clock source that advances `step_ms` on every read. Seeded per test
/// through the process dict so a single process can host several clocks.
fn stepping_clock(key: String, step_ms: Int) -> fn() -> Int {
  let _ = pd_erase(key <> ":clock")
  let _ = pd_put(key <> ":clock", 0)
  fn() {
    let now: Int = pd_get(key <> ":clock")
    pd_put(key <> ":clock", now + step_ms)
    now
  }
}

// ─── Process-dict recorders ─────────────────────────────────────────────

@external(erlang, "erlang", "put")
fn pd_put(key: String, value: a) -> Nil

@external(erlang, "erlang", "get")
fn pd_get(key: String) -> a

@external(erlang, "erlang", "erase")
fn pd_erase(key: String) -> Nil

fn saved_statuses(key: String) -> List(ExecutionState) {
  pd_get(key <> ":statuses")
}

fn saved_steps(key: String) -> List(StepExecution) {
  pd_get(key <> ":steps")
}

fn saved_logs(key: String) -> List(#(String, String)) {
  pd_get(key <> ":logs")
}

fn harness_call_count(key: String) -> Int {
  pd_get(key <> ":harness_calls")
}

// ─── Acceptance: 3-step linear ──────────────────────────────────────────

pub fn three_step_linear_flow_persists_all_steps_and_metrics_test() {
  let key = "linear"
  let engine = linear_engine(counting_harness(key), recording_store(key))
  let conn = test_conn()

  let assert Ok(state) = runtime.run_until_wait(conn, engine, instance_id)

  state.status |> should.equal(Completed)
  state.completed_at |> should.not_equal(None)
  harness_call_count(key) |> should.equal(3)

  // The returned state carries the full step history with metrics.
  state.step_history |> list.length |> should.equal(3)
  state.step_history
  |> list.all(fn(step) { step.status == StepCompleted })
  |> should.be_true
  state.step_history
  |> list.map(fn(step) { unwrap(step.output, "") })
  |> list.reverse
  |> should.equal(["ran:first step", "ran:second step", "ran:third step"])
  state.step_history
  |> list.all(fn(step) {
    step.model == Some(model)
    && step.input_tokens == 100
    && step.output_tokens == 50
    && step.cost == 0.0075
    && step.duration_ms == 120
  })
  |> should.be_true

  // The store received one execution per step, plus outcome/usage logs.
  saved_steps(key) |> list.length |> should.equal(3)
  saved_steps(key)
  |> list.all(fn(step) { step.status == StepCompleted })
  |> should.be_true
  saved_logs(key)
  |> list.filter(fn(log) { log.0 == "outcome" })
  |> list.length
  |> should.equal(3)
  saved_logs(key)
  |> list.filter(fn(log) { log.0 == "usage" })
  |> list.length
  |> should.equal(3)

  // The final persisted status is Completed.
  case saved_statuses(key) {
    [persisted] -> persisted.status |> should.equal(Completed)
    _ -> should.fail()
  }
}

// ─── Acceptance: non-zero exit → failed with stderr ─────────────────────

pub fn step_exit_nonzero_marks_failed_and_captures_stderr_test() {
  let key = "exit1"
  let engine =
    linear_engine(failing_harness(key, 1, "fatal boom"), recording_store(key))
  let conn = test_conn()

  let assert Error(error) = runtime.run_until_wait(conn, engine, instance_id)

  case error {
    runtime.AdapterFailure(node_id: node_id, code: code, output: output) -> {
      node_id |> should.equal("s1")
      code |> should.equal(1)
      output |> string.contains("fatal boom") |> should.be_true
      output |> string.contains("code 1") |> should.be_true
    }
    _ -> should.fail()
  }
  runtime.error_to_string(error)
  |> string.contains("fatal boom")
  |> should.be_true

  // The failure stopped at the first step: exactly one harness invocation,
  // one failed step execution persisted, status Failed.
  harness_call_count(key) |> should.equal(1)
  case saved_steps(key) {
    [failed_step] -> {
      failed_step.status |> should.equal(StepFailed)
      failed_step.node_id |> should.equal("s1")
      case failed_step.output {
        Some(output) ->
          output |> string.contains("fatal boom") |> should.be_true
        None -> should.fail()
      }
    }
    _ -> should.fail()
  }
  case saved_statuses(key) {
    [persisted] -> persisted.status |> should.equal(Failed)
    _ -> should.fail()
  }
  saved_logs(key)
  |> list.any(fn(log) {
    log.0 == "error" && string.contains(log.1, "fatal boom")
  })
  |> should.be_true
}

// ─── Acceptance: AwaitInput stops the loop ──────────────────────────────

pub fn await_input_stops_execution_and_resume_completes_test() {
  let key = "await"
  let engine = human_input_engine(counting_harness(key), recording_store(key))
  let conn = test_conn()

  let assert Ok(state) = runtime.run_until_wait(conn, engine, instance_id)

  // The loop pauses at the human-input node without touching the harness and
  // persists awaiting_input as the execution status.
  state.status |> should.equal(AwaitingInput)
  state.current_node_id |> should.equal(Some("ask"))
  harness_call_count(key) |> should.equal(0)
  case saved_statuses(key) {
    [persisted] -> persisted.status |> should.equal(AwaitingInput)
    _ -> should.fail()
  }

  // Feeding the input resumes the flow and runs it to completion.
  let assert Ok(finished) = runtime.resume(conn, engine, instance_id, "purple")
  finished.status |> should.equal(Completed)
}

// ─── Acceptance: wall-clock timeout → failed ────────────────────────────

pub fn wall_clock_timeout_marks_execution_failed_test() {
  let key = "timeout"
  let engine =
    linear_engine(counting_harness(key), recording_store(key))
    |> runtime.with_timeout(10)
    |> runtime.with_clock(stepping_clock(key, 100))
  let conn = test_conn()

  let assert Error(error) = runtime.run_until_wait(conn, engine, instance_id)

  case error {
    runtime.Timeout(
      instance_id: failed_instance,
      elapsed_ms: elapsed,
      limit_ms: limit,
    ) -> {
      failed_instance |> should.equal(instance_id)
      // The clock advanced 100ms between the start read and the guard read.
      elapsed |> should.equal(100)
      limit |> should.equal(10)
    }
    _ -> should.fail()
  }
  runtime.error_to_string(error)
  |> string.contains("timed out")
  |> should.be_true

  // The timeout was persisted as a failed execution with a diagnostic log and
  // no step was dispatched to the harness.
  harness_call_count(key) |> should.equal(0)
  case saved_statuses(key) {
    [persisted] -> persisted.status |> should.equal(Failed)
    _ -> should.fail()
  }
  saved_logs(key)
  |> list.any(fn(log) {
    log.0 == "error" && string.contains(log.1, "timed out")
  })
  |> should.be_true
}

// ─── Bonus: cancellation ────────────────────────────────────────────────

pub fn cancel_marks_execution_and_stops_a_pending_run_test() {
  let key = "cancel"
  let engine = linear_engine(counting_harness(key), recording_store(key))
  let conn = test_conn()

  // `cancel` returns the cancelled state and persists it through the store
  // (C8), so a DB-backed restart observes the cancellation.
  let assert Ok(cancelled) = runtime.cancel(conn, engine, instance_id)
  cancelled.status |> should.equal(Cancelled)
  case saved_statuses(key) {
    [persisted] -> persisted.status |> should.equal(Cancelled)
    _ -> should.fail()
  }

  // A run whose engine holds the cancelled execution must not dispatch any
  // step: the cancellation guard stops it before the harness is invoked.
  let cancelled_flow =
    flow_engine.Engine(
      ..engine.flow,
      executions: flow_engine.ExecutionRegistry(
        dict.new() |> dict.insert(instance_id, cancelled),
      ),
    )
  let stopped =
    runtime.new_engine(
      cancelled_flow,
      counting_harness(key),
      recording_store(key),
      "/tmp/crystalline",
    )
  let assert Error(error) = runtime.run_until_wait(conn, stopped, instance_id)
  case error {
    runtime.CancelledExecution(_) -> Nil
    _ -> should.fail()
  }
  harness_call_count(key) |> should.equal(0)
}

// ─── Bonus: parallel children ───────────────────────────────────────────

pub fn parallel_node_runs_all_children_and_joins_output_test() {
  let key = "parallel"
  let engine = parallel_engine(counting_harness(key), recording_store(key))
  let conn = test_conn()

  let assert Ok(state) = runtime.run_until_wait(conn, engine, instance_id)

  // Every child step was invoked once and the composite completed.
  state.status |> should.equal(Completed)
  harness_call_count(key) |> should.equal(2)

  // Each child step was persisted with its own metrics.
  let children =
    saved_steps(key)
    |> list.filter(fn(step) { step.node_id == "p1" || step.node_id == "p2" })
  children |> list.length |> should.equal(2)
  children
  |> list.all(fn(step) {
    step.status == StepCompleted && step.input_tokens == 100
  })
  |> should.be_true

  // The joined output from the parallel node carries both children's outputs.
  case
    saved_steps(key)
    |> list.find(fn(step) { step.node_id == "both" })
  {
    Ok(step) ->
      unwrap(step.output, "")
      |> string.contains("ran:branch one")
      |> should.be_true
    Error(Nil) -> should.fail()
  }
}
