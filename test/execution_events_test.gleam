//// Acceptance tests for the real-time execution event stream (C20).
////
//// Two layers are covered:
////
//// - the in-BEAM event mechanism (`sacrum_gleam/runtime/events`) driven through
////   the real persistence write points on a fresh `:memory:` database, and
//// - the Server-Sent Events endpoint (`GET /api/v1/executions/:id/events`) on a
////   real Mist listener, opened with a raw socket probe (see
////   `sacrum_gleam_sse_probe`). Every read is bounded by an explicit timeout, so
////   the suite can never block on a stream.

import gleam/dict
import gleam/erlang/port
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/db/executions
import sacrum_gleam/db/flows
import sacrum_gleam/db/migrations
import sacrum_gleam/db/session_logs
import sacrum_gleam/db/tasks
import sacrum_gleam/domain/execution.{
  type StepStatus, Completed, ExecutionState, Running, StepCompleted,
  StepExecution, StepInProgress,
}
import sacrum_gleam/domain/flow.{type FlowInstance, FlowInstance, FlowTemplate}
import sacrum_gleam/domain/task.{Medium, Task, Ticket, new_task}
import sacrum_gleam/http/server
import sacrum_gleam/runtime/events

pub fn main() -> Nil {
  gleeunit.main()
}

// ─── Fixtures ────────────────────────────────────────────────────────────

fn new_conn() -> DbConnection {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok(_) = migrations.run_migrations(conn)
  conn
}

fn insert_task(conn: DbConnection, id: String, now: Int) -> Nil {
  let task =
    Task(
      ..new_task("Task " <> id, Ticket, Medium),
      id: id,
      short_id: "short-" <> id,

      created_at: now,
      updated_at: now,
    )
  let assert Ok(_) = tasks.create_task(conn, task, now)
  Nil
}

fn insert_template(conn: DbConnection, template_id: String) -> Nil {
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

/// Task + template + instance, so execution-state and step rows can hold their
/// foreign keys.
fn seed_task(conn: DbConnection, task_id: String) -> FlowInstance {
  insert_task(conn, task_id, 1)
  insert_template(conn, "tpl-" <> task_id)
  let instance =
    FlowInstance(
      id: "inst-" <> task_id,
      template_id: "tpl-" <> task_id,
      task_id: task_id,
      nodes: dict.new(),
      transitions: [],
      initial_node_id: "start",
      on_done_template_id: None,
      on_reject_template_id: None,
    )
  let assert Ok(_) = flows.create_flow_instance(conn, instance, 1)
  instance
}

fn insert_state(
  conn: DbConnection,
  instance: FlowInstance,
  task_id: String,
) -> String {
  let state_id = "state-" <> task_id
  let state =
    ExecutionState(
      id: state_id,
      flow_instance: instance,
      task_id: task_id,
      status: Running,
      current_node_id: None,
      step_history: [],
      loop_counters: dict.new(),
      variables: dict.new(),
      parallel_active: [],
      started_at: Some(1),
      completed_at: None,
    )
  let assert Ok(_) = executions.create_execution_state(conn, state, 1)
  state_id
}

fn insert_step(
  conn: DbConnection,
  step_id: String,
  instance: FlowInstance,
  execution_state_id: String,
  task_id: String,
  status: StepStatus,
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
      output: None,
      transition_result: None,
      model: None,
      input_tokens: 0,
      output_tokens: 0,
      cost: 0.0,
      duration_ms: 0,
      session_id: None,
      created_at: 1,
      completed_at: None,
    )
  let assert Ok(_) = executions.create_step_execution(conn, step, 1)
  Nil
}

/// Task + template + instance + execution state + step execution, the minimum
/// a session-log append needs to satisfy its foreign keys.
fn seed_step(
  conn: DbConnection,
  task_id: String,
  step_id: String,
  status: StepStatus,
) -> Nil {
  let instance = seed_task(conn, task_id)
  let state_id = insert_state(conn, instance, task_id)
  insert_step(conn, step_id, instance, state_id, task_id, status)
}

// ─── Event mechanism ─────────────────────────────────────────────────────

/// A session-log append reaches a subscriber with the log's payload and a
/// registry-assigned cursor, proving the `db/session_logs` write point is
/// wired into the stream.
pub fn session_log_append_is_published_test() -> Nil {
  let conn = new_conn()
  seed_step(conn, "evt-log", "step-hook-log", StepInProgress)
  let subject = process.new_subject()
  let assert events.SubscribeReply(events: [], latest_sequence: 0) =
    events.subscribe("step-hook-log", subject, None)

  let assert Ok(log) =
    session_logs.append_log(
      conn,
      "step-hook-log",
      "evt-log",
      "text",
      "hello world",
      1000,
    )

  let assert Ok(events.Deliver(event)) = process.receive(subject, within: 2000)
  event.sequence |> should.equal(1)
  event.kind |> should.equal(events.SessionLogEvent)
  event.execution_id |> should.equal("step-hook-log")

  let payload = json.to_string(event.data)
  string.contains(payload, "\"event_sequence\":1") |> should.be_true()
  string.contains(payload, "\"type\":\"session_log\"") |> should.be_true()
  string.contains(payload, "\"payload\":\"hello world\"") |> should.be_true()
  // The log id embeds the log's own per-step sequence, which is not the cursor.
  string.contains(payload, "\"id\":\"step-hook-log-1\"") |> should.be_true()
  log.sequence |> should.equal(1)
}

/// Events arrive in sequence order, an omitted cursor replays the whole
/// retained buffer, and a cursor resumes above itself without duplicates.
pub fn events_are_ordered_and_resumed_without_duplicates_test() -> Nil {
  let conn = new_conn()
  let execution_id = "step-order"
  seed_step(conn, "evt-order", execution_id, StepInProgress)
  let assert Ok(_) = append(conn, "evt-order", execution_id, "one", 1)
  let assert Ok(_) = append(conn, "evt-order", execution_id, "two", 2)
  let assert Ok(_) = append(conn, "evt-order", execution_id, "three", 3)

  let fresh = process.new_subject()
  let snapshot = events.subscribe(execution_id, fresh, None)
  snapshot.events
  |> list.map(fn(event) { event.sequence })
  |> should.equal([1, 2, 3])
  snapshot.latest_sequence |> should.equal(3)
  // Replay only: nothing is duplicated on the live path.
  process.receive(fresh, within: 150) |> should.be_error()

  let resumed = process.new_subject()
  let snapshot = events.subscribe(execution_id, resumed, Some(1))
  snapshot.events
  |> list.map(fn(event) { event.sequence })
  |> should.equal([2, 3])

  let assert Ok(_) = append(conn, "evt-order", execution_id, "four", 4)
  let assert Ok(events.Deliver(event)) = process.receive(resumed, within: 2000)
  event.sequence |> should.equal(4)
  process.receive(resumed, within: 100) |> should.be_error()
}

/// Every subscriber of an execution receives each event, and a subscriber whose
/// process died does not stop delivery to the live ones.
///
/// The dead subscriber is created by a process that exits immediately after
/// handing over its subject.
pub fn publish_fans_out_and_prunes_dead_subscribers_test() -> Nil {
  let conn = new_conn()
  let execution_id = "step-fanout"
  seed_step(conn, "evt-fanout", execution_id, StepInProgress)
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() { process.send(ready, process.new_subject()) })
  let assert Ok(dead_subject) = process.receive(ready, within: 1000)
  let assert events.SubscribeReply(events: [], latest_sequence: 0) =
    events.subscribe(execution_id, dead_subject, None)
  let live = process.new_subject()
  let assert events.SubscribeReply(events: [], latest_sequence: 0) =
    events.subscribe(execution_id, live, None)
  process.sleep(20)

  let assert Ok(_) = append(conn, "evt-fanout", execution_id, "fanout", 1)
  let assert Ok(events.Deliver(event)) = process.receive(live, within: 2000)
  event.sequence |> should.equal(1)
}

/// An unsubscribed stream stops receiving, even for events published from the
/// same process afterwards.
pub fn unsubscribe_stops_delivery_test() -> Nil {
  let conn = new_conn()
  let execution_id = "step-unsub"
  seed_step(conn, "evt-unsub", execution_id, StepInProgress)
  let subject = process.new_subject()
  let assert events.SubscribeReply(events: [], latest_sequence: 0) =
    events.subscribe(execution_id, subject, None)
  events.unsubscribe(execution_id, subject)

  let assert Ok(_) =
    append(conn, "evt-unsub", execution_id, "after-unsubscribe", 1)
  process.receive(subject, within: 200) |> should.be_error()
}

/// Step- and execution-status write points publish their transitions.
pub fn status_write_points_are_published_test() -> Nil {
  let conn = new_conn()
  let instance = seed_task(conn, "evt-status")
  let state_id = insert_state(conn, instance, "evt-status")
  insert_step(
    conn,
    "step-evt",
    instance,
    state_id,
    "evt-status",
    StepInProgress,
  )

  let step_subject = process.new_subject()
  let assert events.SubscribeReply(events: [], latest_sequence: 0) =
    events.subscribe("step-evt", step_subject, None)
  let step =
    StepExecution(
      id: "step-evt",
      flow_instance_id: instance.id,
      execution_state_id: state_id,
      node_id: "node-step-evt",
      task_id: "evt-status",
      status: StepCompleted,
      prompt: Some("prompt"),
      output: Some("done"),
      transition_result: None,
      model: None,
      input_tokens: 0,
      output_tokens: 0,
      cost: 0.0,
      duration_ms: 0,
      session_id: None,
      created_at: 1,
      completed_at: Some(9),
    )
  let assert Ok(_) = executions.update_step_execution(conn, step)
  let assert Ok(events.Deliver(step_event)) =
    process.receive(step_subject, within: 2000)
  step_event.kind |> should.equal(events.StepStatusEvent)
  let step_data = json.to_string(step_event.data)
  string.contains(step_data, "\"status\":\"completed\"") |> should.be_true()
  string.contains(step_data, "\"output\":\"done\"") |> should.be_true()

  let state_subject = process.new_subject()
  let assert events.SubscribeReply(events: [], latest_sequence: 0) =
    events.subscribe(state_id, state_subject, None)
  let assert Ok(_) =
    executions.update_execution_status(
      conn,
      state_id,
      Completed,
      Some("node-final"),
      42,
    )
  let assert Ok(events.Deliver(state_event)) =
    process.receive(state_subject, within: 2000)
  state_event.kind |> should.equal(events.ExecutionStatusEvent)
  let state_data = json.to_string(state_event.data)
  string.contains(state_data, "\"status\":\"completed\"") |> should.be_true()
  string.contains(state_data, "\"current_node_id\":\"node-final\"")
  |> should.be_true()
  string.contains(state_data, "\"updated_at\":42") |> should.be_true()
}

fn append(
  conn: DbConnection,
  task_id: String,
  execution_id: String,
  payload: String,
  now: Int,
) -> Result(Nil, Nil) {
  session_logs.append_log(conn, execution_id, task_id, "text", payload, now)
  |> result_ignore
}

fn result_ignore(result: Result(a, b)) -> Result(Nil, Nil) {
  case result {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(Nil)
  }
}

// ─── SSE endpoint on a real listener ─────────────────────────────────────

type RunningServer {
  RunningServer(pid: process.Pid, stop: process.Subject(Nil))
}

/// Run the real server on a free loopback port in its own process.
///
/// `mist.start` links the listener supervision tree to the calling process, so
/// the server must outlive the `start_with_connection` call. The process then
/// parks on `stop`; exiting normally takes the linked supervision tree (and the
/// port) down without a crash report.
fn start_server(
  port: Int,
  conn: DbConnection,
  token: Option(String),
) -> RunningServer {
  let ready = process.new_subject()
  let server_pid =
    process.spawn_unlinked(fn() {
      let outcome = server.start_with_connection(port, conn, "local", token)
      let stop = process.new_subject()
      process.send(ready, #(outcome, stop))
      // Returns (and exits normally) on either a stop message or the timeout.
      let _ = process.receive(stop, within: 30_000)
      Nil
    })
  let assert Ok(#(Ok(_started), stop)) = process.receive(ready, within: 5000)
  RunningServer(pid: server_pid, stop: stop)
}

fn stop_server(server: RunningServer) -> Nil {
  process.send(server.stop, Nil)
  process.sleep(100)
}

fn stream_url(execution_id: String, query: String) -> String {
  "/api/v1/executions/" <> execution_id <> "/events" <> query
}

/// End to end: a client opens the stream, a session log appended through the
/// real HTTP API shows up as a `session_log` frame with the right cursor and
/// payload.
pub fn sse_stream_delivers_log_appended_over_http_test() -> Nil {
  let conn = new_conn()
  let instance = seed_task(conn, "sse-e2e")
  let state_id = insert_state(conn, instance, "sse-e2e")
  insert_step(conn, "step-sse", instance, state_id, "sse-e2e", StepInProgress)

  let port = probe_free_port()
  let server = start_server(port, conn, None)
  let socket = probe_open(port, stream_url("step-sse", ""), "")

  // The opening frame is sent once the subscription is registered, so the log
  // below cannot race the subscribe.
  let opened = probe_recv_until(socket, "event: stream_opened", 3000)
  string.contains(opened, "HTTP/1.1 200") |> should.be_true()
  string.contains(opened, "\"execution_id\":\"step-sse\"") |> should.be_true()

  let posted =
    probe_request(
      port,
      "POST",
      "/api/v1/executions/step-sse/logs",
      "Content-Type: application/json\r\n",
      "{\"event_type\":\"text\",\"payload\":\"e2e-hello\"}",
    )
  string.contains(posted, "201") |> should.be_true()

  let frames = probe_recv_until(socket, "e2e-hello", 3000)
  string.contains(frames, "event: session_log") |> should.be_true()
  string.contains(frames, "id: 1") |> should.be_true()
  string.contains(frames, "\"payload\":\"e2e-hello\"") |> should.be_true()

  probe_close(socket)
  stop_server(server)
}

/// A stream is bounded: `?max_ms=` makes the server stop the subscriber, which
/// owns the socket, so the client observes a closed connection.
pub fn sse_stream_is_bounded_test() -> Nil {
  let conn = new_conn()
  let instance = seed_task(conn, "sse-bound")
  let state_id = insert_state(conn, instance, "sse-bound")
  insert_step(
    conn,
    "step-bound",
    instance,
    state_id,
    "sse-bound",
    StepInProgress,
  )

  let port = probe_free_port()
  let server = start_server(port, conn, None)
  let socket = probe_open(port, stream_url("step-bound", "?max_ms=1000"), "")

  let #(frames, closed) = probe_recv_until_closed(socket, 3000)
  string.contains(frames, "event: stream_opened") |> should.be_true()
  closed |> should.be_true()

  probe_close(socket)
  stop_server(server)
}

/// The stream accepts the bearer header or, because `EventSource` cannot send
/// headers, `?token=` — and `?token=` does not unlock the rest of the API.
pub fn sse_stream_token_test() -> Nil {
  let conn = new_conn()
  let instance = seed_task(conn, "sse-token")
  let state_id = insert_state(conn, instance, "sse-token")
  insert_step(
    conn,
    "step-token",
    instance,
    state_id,
    "sse-token",
    StepInProgress,
  )

  let port = probe_free_port()
  let server = start_server(port, conn, Some("s3cret"))

  let unauthorized =
    probe_request(port, "GET", stream_url("step-token", ""), "", "")
  string.contains(unauthorized, "401") |> should.be_true()
  string.contains(unauthorized, "Unauthorized") |> should.be_true()

  let socket = probe_open(port, stream_url("step-token", "?token=s3cret"), "")
  let opened = probe_recv_until(socket, "event: stream_opened", 3000)
  string.contains(opened, "HTTP/1.1 200") |> should.be_true()
  probe_close(socket)

  let via_header =
    probe_open(
      port,
      stream_url("step-token", ""),
      "Authorization: Bearer s3cret\r\n",
    )
  let opened = probe_recv_until(via_header, "event: stream_opened", 3000)
  string.contains(opened, "HTTP/1.1 200") |> should.be_true()
  probe_close(via_header)

  // The query parameter is a stream-only credential: a normal API route still
  // needs the header.
  let query_only =
    probe_request(port, "GET", "/api/v1/tasks?token=s3cret", "", "")
  string.contains(query_only, "401") |> should.be_true()
  let with_header =
    probe_request(
      port,
      "GET",
      "/api/v1/tasks",
      "Authorization: Bearer s3cret\r\n",
      "",
    )
  string.contains(with_header, "HTTP/1.1 200") |> should.be_true()

  stop_server(server)
}

/// Unknown execution ids get the API's JSON 404 instead of an empty stream.
pub fn sse_stream_unknown_execution_test() -> Nil {
  let conn = new_conn()
  let port = probe_free_port()
  let server = start_server(port, conn, None)

  let response =
    probe_request(port, "GET", stream_url("step-missing", ""), "", "")
  string.contains(response, "404") |> should.be_true()
  string.contains(response, "Execution not found") |> should.be_true()

  stop_server(server)
}

// ─── Socket probe bridge ─────────────────────────────────────────────────

type Probe =
  port.Port

@external(erlang, "sacrum_gleam_sse_probe", "free_port")
fn probe_free_port() -> Int

@external(erlang, "sacrum_gleam_sse_probe", "open")
fn probe_open(port: Int, path: String, headers: String) -> Probe

@external(erlang, "sacrum_gleam_sse_probe", "request")
fn probe_request(
  port: Int,
  method: String,
  path: String,
  headers: String,
  body: String,
) -> String

@external(erlang, "sacrum_gleam_sse_probe", "recv_until")
fn probe_recv_until(socket: Probe, needle: String, timeout_ms: Int) -> String

@external(erlang, "sacrum_gleam_sse_probe", "recv_until_closed")
fn probe_recv_until_closed(socket: Probe, timeout_ms: Int) -> #(String, Bool)

@external(erlang, "sacrum_gleam_sse_probe", "close")
fn probe_close(socket: Probe) -> Nil
