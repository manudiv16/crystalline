import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import sacrum_gleam/db/connection
import sacrum_gleam/db/executions
import sacrum_gleam/db/flows
import sacrum_gleam/db/migrations
import sacrum_gleam/db/session_logs
import sacrum_gleam/db/tasks
import sacrum_gleam/domain/execution.{
  type ExecutionStatus, type StepStatus, AwaitingInput, Completed,
  ExecutionState, Failed, Pending, Running, StepCompleted, StepExecution,
  StepFailed, StepInProgress,
}
import sacrum_gleam/domain/flow.{type FlowInstance, FlowInstance, FlowTemplate}
import sacrum_gleam/domain/task.{Medium, Task, Ticket, Todo}
import sacrum_gleam/http/router
import sacrum_gleam/http/routes/executions as execution_routes
import wisp
import wisp/simulate

pub fn main() -> Nil {
  gleeunit.main()
}

// ─── Helpers ─────────────────────────────────────────────────────────────

fn new_conn() -> connection.DbConnection {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok(_) = migrations.run_migrations(conn)
  conn
}

fn insert_task(conn: connection.DbConnection, id: String, now: Int) -> Nil {
  let task =
    Task(
      id: id,
      short_id: "short-" <> id,
      title: "Task " <> id,
      description: "",
      level: Ticket,
      priority: Medium,
      status: Todo,
      tags: [],
      parent_id: None,
      flow_template_id: None,
      flow_instance_id: None,
      current_node_id: None,
      worktree: None,
      archived: False,
      created_at: now,
      updated_at: now,
    )
  let assert Ok(_) = tasks.create_task(conn, task, now)
  Nil
}

fn insert_template(conn: connection.DbConnection, template_id: String) -> Nil {
  let template =
    FlowTemplate(
      id: template_id,
      name: "template-" <> template_id,
      description: "",
      initial_node_id: "start",
      nodes: dict.new(),
      transitions: [],
      on_done_template_id: None,
      on_reject_template_id: None,
    )
  let assert Ok(_) = flows.create_flow_template(conn, template, 1)
  Nil
}

fn make_instance(
  instance_id: String,
  template_id: String,
  task_id: String,
) -> FlowInstance {
  FlowInstance(
    id: instance_id,
    template_id: template_id,
    task_id: task_id,
    nodes: dict.new(),
    transitions: [],
    initial_node_id: "start",
    on_done_template_id: None,
    on_reject_template_id: None,
  )
}

fn insert_execution_state(
  conn: connection.DbConnection,
  id: String,
  instance: FlowInstance,
  task_id: String,
  status: ExecutionStatus,
  now: Int,
) -> Nil {
  let state =
    ExecutionState(
      id: id,
      flow_instance: instance,
      task_id: task_id,
      status: status,
      current_node_id: None,
      step_history: [],
      loop_counters: dict.new(),
      variables: dict.new(),
      parallel_active: [],
      started_at: Some(now),
      completed_at: None,
    )
  let assert Ok(_) = executions.create_execution_state(conn, state, now)
  Nil
}

fn insert_step(
  conn: connection.DbConnection,
  step_id: String,
  instance: FlowInstance,
  execution_state_id: String,
  task_id: String,
  status: StepStatus,
  created_at: Int,
) -> Nil {
  let step =
    StepExecution(
      id: step_id,
      flow_instance_id: instance.id,
      execution_state_id: execution_state_id,
      node_id: "node-" <> step_id,
      task_id: task_id,
      status: status,
      prompt: Some("prompt"),
      output: Some("output"),
      transition_result: None,
      model: Some("test-model"),
      input_tokens: 10,
      output_tokens: 5,
      cost: 0.01,
      duration_ms: 100,
      session_id: None,
      created_at: created_at,
      completed_at: Some(created_at),
    )
  let assert Ok(_) = executions.create_step_execution(conn, step, created_at)
  Nil
}

/// Insert a task + flow template + instance, returning the instance.
fn seed_task(conn: connection.DbConnection, task_id: String) -> FlowInstance {
  insert_task(conn, task_id, 1)
  insert_template(conn, "tpl-" <> task_id)
  let instance = make_instance("inst-" <> task_id, "tpl-" <> task_id, task_id)
  let assert Ok(_) = flows.create_flow_instance(conn, instance, 1)
  instance
}

/// Insert an execution state row so `insert_step`'s FK holds, returning its id.
fn insert_state(
  conn: connection.DbConnection,
  instance: FlowInstance,
  task_id: String,
) -> String {
  let state_id = "state-" <> task_id
  insert_execution_state(conn, state_id, instance, task_id, Running, 1)
  state_id
}

fn handle(
  conn: connection.DbConnection,
  method: http.Method,
  path: String,
) -> wisp.Response {
  let request = simulate.request(method, path)
  router.match_route(execution_routes.execution_routes(conn), request)
}

fn handle_json(
  conn: connection.DbConnection,
  method: http.Method,
  path: String,
  body: json.Json,
) -> wisp.Response {
  let request = simulate.request(method, path) |> simulate.json_body(body)
  router.match_route(execution_routes.execution_routes(conn), request)
}

fn status_of(response: wisp.Response) -> Int {
  response.status
}

fn body_of(response: wisp.Response) -> String {
  simulate.read_body(response)
}

fn decode_log_sequences(raw: String) -> List(Int) {
  let decoder =
    decode.list(of: {
      use sequence <- decode.field("sequence", decode.int)
      decode.success(sequence)
    })
  case json.parse(from: raw, using: decoder) {
    Ok(sequences) -> sequences
    Error(_) -> []
  }
}

fn decode_execution_ids(raw: String) -> List(String) {
  let decoder =
    decode.list(of: {
      use id <- decode.field("id", decode.string)
      decode.success(id)
    })
  case json.parse(from: raw, using: decoder) {
    Ok(ids) -> ids
    Error(_) -> []
  }
}

fn decode_execution_statuses(raw: String) -> List(String) {
  let decoder =
    decode.list(of: {
      use status <- decode.field("status", decode.string)
      decode.success(status)
    })
  case json.parse(from: raw, using: decoder) {
    Ok(statuses) -> statuses
    Error(_) -> []
  }
}

fn append_event_json(event_type: String, payload: String) -> json.Json {
  json.object([
    #("event_type", json.string(event_type)),
    #("payload", json.string(payload)),
  ])
}

// ─── Acceptance: step execution history is newest first ──────────────────

pub fn task_executions_newest_first_test() {
  let conn = new_conn()
  let instance = seed_task(conn, "task-1")
  let state_id = insert_state(conn, instance, "task-1")

  insert_step(conn, "step-1", instance, state_id, "task-1", StepCompleted, 100)
  insert_step(conn, "step-2", instance, state_id, "task-1", StepCompleted, 200)
  insert_step(conn, "step-3", instance, state_id, "task-1", StepFailed, 300)

  let response = handle(conn, http.Get, "/api/v1/tasks/task-1/executions")

  status_of(response) |> should.equal(200)
  decode_execution_ids(body_of(response))
  |> should.equal(["step-3", "step-2", "step-1"])
}

pub fn task_executions_unknown_task_test() {
  let conn = new_conn()
  let response = handle(conn, http.Get, "/api/v1/tasks/ghost/executions")
  status_of(response) |> should.equal(404)
}

// ─── Acceptance: append assigns a server sequence and returns 201 ────────

pub fn append_log_assigns_sequence_201_test() {
  let conn = new_conn()
  let instance = seed_task(conn, "task-1")
  let state_id = insert_state(conn, instance, "task-1")
  insert_step(conn, "step-1", instance, state_id, "task-1", StepInProgress, 100)

  let first =
    handle_json(
      conn,
      http.Post,
      "/api/v1/executions/step-1/logs",
      append_event_json("text", "hello"),
    )
  let second =
    handle_json(
      conn,
      http.Post,
      "/api/v1/executions/step-1/logs",
      append_event_json("text", "world"),
    )

  status_of(first) |> should.equal(201)
  status_of(second) |> should.equal(201)

  // The client never sends a sequence; the server assigns it monotonically.
  let decode_sequence = fn(raw: String) {
    let decoder: decode.Decoder(Int) = {
      use sequence <- decode.field("sequence", decode.int)
      decode.success(sequence)
    }
    json.parse(from: raw, using: decoder)
  }
  case decode_sequence(body_of(first)) {
    Ok(sequence) -> sequence |> should.equal(1)
    Error(_) -> should.fail()
  }
  case decode_sequence(body_of(second)) {
    Ok(sequence) -> sequence |> should.equal(2)
    Error(_) -> should.fail()
  }
}

// ─── Acceptance: logs paging ─────────────────────────────────────────────

fn append_n_logs(
  conn: connection.DbConnection,
  step_id: String,
  count: Int,
  start_at: Int,
) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      let assert Ok(_) =
        session_logs.append_log(
          conn,
          step_id,
          "task-1",
          "text",
          "event",
          start_at + count,
        )
      append_n_logs(conn, step_id, count - 1, start_at)
    }
  }
}

/// limit=10 returns the last 10 events, in chronological order.
pub fn logs_limit_returns_last_10_test() {
  let conn = new_conn()
  let instance = seed_task(conn, "task-1")
  let state_id = insert_state(conn, instance, "task-1")
  insert_step(conn, "step-1", instance, state_id, "task-1", StepInProgress, 100)
  append_n_logs(conn, "step-1", 12, 100)

  let response =
    handle(conn, http.Get, "/api/v1/executions/step-1/logs?limit=10")

  status_of(response) |> should.equal(200)
  decode_log_sequences(body_of(response))
  |> should.equal([3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
}

/// before_sequence=5 returns only events with sequence < 5.
pub fn logs_before_sequence_filters_test() {
  let conn = new_conn()
  let instance = seed_task(conn, "task-1")
  let state_id = insert_state(conn, instance, "task-1")
  insert_step(conn, "step-1", instance, state_id, "task-1", StepInProgress, 100)
  append_n_logs(conn, "step-1", 5, 100)

  let response =
    handle(conn, http.Get, "/api/v1/executions/step-1/logs?before_sequence=5")

  status_of(response) |> should.equal(200)
  decode_log_sequences(body_of(response)) |> should.equal([1, 2, 3, 4])
}

/// Default page size is 50.
pub fn logs_default_limit_is_50_test() {
  let conn = new_conn()
  let instance = seed_task(conn, "task-1")
  let state_id = insert_state(conn, instance, "task-1")
  insert_step(conn, "step-1", instance, state_id, "task-1", StepInProgress, 100)
  append_n_logs(conn, "step-1", 60, 100)

  let response = handle(conn, http.Get, "/api/v1/executions/step-1/logs")

  status_of(response) |> should.equal(200)
  decode_log_sequences(body_of(response)) |> list.length |> should.equal(50)
}

/// The issue's paging acceptance: 10 events paged with limit=4 yields
/// 4/4/2 pages, strictly decreasing sequence ranges, no gaps or duplicates.
pub fn logs_paging_4_4_2_no_gaps_test() {
  let conn = new_conn()
  let instance = seed_task(conn, "task-1")
  let state_id = insert_state(conn, instance, "task-1")
  insert_step(conn, "step-1", instance, state_id, "task-1", StepInProgress, 100)
  append_n_logs(conn, "step-1", 10, 100)

  let assert Ok(page1) = session_logs.list_logs(conn, "step-1", 4, None)
  page1
  |> list.map(fn(log) { log.sequence })
  |> should.equal([7, 8, 9, 10])

  let assert Ok(page2) = session_logs.list_logs(conn, "step-1", 4, Some(7))
  page2
  |> list.map(fn(log) { log.sequence })
  |> should.equal([3, 4, 5, 6])

  let assert Ok(page3) = session_logs.list_logs(conn, "step-1", 4, Some(3))
  page3
  |> list.map(fn(log) { log.sequence })
  |> should.equal([1, 2])

  // No gaps or duplicates across the three pages.
  let all =
    list.append(list.append(page1, page2), page3)
    |> list.map(fn(log) { log.sequence })
    |> list.sort(int.compare)
  all |> should.equal([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
}

// ─── Acceptance: active executions are running + awaiting_input only ─────

pub fn active_only_running_and_awaiting_test() {
  let conn = new_conn()
  let instance = seed_task(conn, "task-1")
  insert_task(conn, "task-2", 1)
  insert_template(conn, "tpl-task-2")
  let instance2 = make_instance("inst-task-2", "tpl-task-2", "task-2")
  let assert Ok(_) = flows.create_flow_instance(conn, instance2, 1)

  insert_execution_state(conn, "state-running", instance, "task-1", Running, 1)
  insert_execution_state(
    conn,
    "state-awaiting",
    instance,
    "task-1",
    AwaitingInput,
    2,
  )
  insert_execution_state(conn, "state-pending", instance, "task-2", Pending, 3)
  insert_execution_state(
    conn,
    "state-completed",
    instance,
    "task-2",
    Completed,
    4,
  )
  insert_execution_state(conn, "state-failed", instance, "task-2", Failed, 5)

  let response = handle(conn, http.Get, "/api/v1/executions/active")

  status_of(response) |> should.equal(200)
  decode_execution_statuses(body_of(response))
  |> list.sort(string.compare)
  |> should.equal(["awaiting_input", "running"])
}

// ─── Acceptance: append guards ───────────────────────────────────────────

pub fn append_to_completed_returns_409_test() {
  let conn = new_conn()
  let instance = seed_task(conn, "task-1")
  let state_id = insert_state(conn, instance, "task-1")
  insert_step(conn, "step-1", instance, state_id, "task-1", StepCompleted, 100)

  let response =
    handle_json(
      conn,
      http.Post,
      "/api/v1/executions/step-1/logs",
      append_event_json("text", "hello"),
    )

  status_of(response) |> should.equal(409)
}

pub fn append_unknown_execution_returns_404_test() {
  let conn = new_conn()
  let response =
    handle_json(
      conn,
      http.Post,
      "/api/v1/executions/ghost/logs",
      append_event_json("text", "hello"),
    )
  status_of(response) |> should.equal(404)
}

pub fn append_invalid_event_type_returns_400_test() {
  let conn = new_conn()
  let instance = seed_task(conn, "task-1")
  let state_id = insert_state(conn, instance, "task-1")
  insert_step(conn, "step-1", instance, state_id, "task-1", StepInProgress, 100)

  let response =
    handle_json(
      conn,
      http.Post,
      "/api/v1/executions/step-1/logs",
      append_event_json("bogus", "hello"),
    )

  status_of(response) |> should.equal(400)
}

// ─── Misc ────────────────────────────────────────────────────────────────

pub fn get_execution_returns_metrics_test() {
  let conn = new_conn()
  let instance = seed_task(conn, "task-1")
  let state_id = insert_state(conn, instance, "task-1")
  insert_step(conn, "step-1", instance, state_id, "task-1", StepCompleted, 100)

  let response = handle(conn, http.Get, "/api/v1/executions/step-1")

  status_of(response) |> should.equal(200)
  let body = body_of(response)
  string.contains(body, "\"id\":\"step-1\"") |> should.be_true
  string.contains(body, "\"status\":\"completed\"") |> should.be_true
  string.contains(body, "\"input_tokens\":10") |> should.be_true
  string.contains(body, "\"cost\":0.01") |> should.be_true
}

pub fn get_unknown_execution_returns_404_test() {
  let conn = new_conn()
  let response = handle(conn, http.Get, "/api/v1/executions/ghost")
  status_of(response) |> should.equal(404)
}
