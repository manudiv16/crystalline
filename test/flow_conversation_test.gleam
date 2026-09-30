/// Acceptance tests for the conversational human-input channel (issue #21).
///
/// `POST /api/v1/flows/:instance_id/reply` turns the single-shot `awaiting_input`
/// primitive into a conversation: one request records the human turn, feeds it
/// through the `/input` path and reports the next `{execution, action}`, so a
/// client loop never calls `advance` itself.
///
/// Requests go through the production route table (`server.all_routes/2`) with
/// `wisp/simulate` against a fresh `:memory:` database, the convention of
/// `flows_test`/`e2e_test`: a route missing from `all_routes` fails here instead
/// of only in production. Every assertion reads persisted rows (or the published
/// stream events), never just status codes, and only public API/service calls
/// drive the flow — the test never inserts a step or a log by hand.
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import sacrum_gleam/db/connection
import sacrum_gleam/db/executions
import sacrum_gleam/db/migrations
import sacrum_gleam/db/session_logs
import sacrum_gleam/domain/execution.{type StepExecution, StepInProgress}
import sacrum_gleam/domain/session.{type SessionLog}
import sacrum_gleam/flow/templates
import sacrum_gleam/http/router
import sacrum_gleam/http/server
import sacrum_gleam/runtime/events
import wisp
import wisp/simulate as sim

pub fn main() -> Nil {
  gleeunit.main()
}

// ─── Fixtures ─────────────────────────────────────────────────────────────

/// Fresh in-memory database with the schema applied.
fn new_conn() -> connection.DbConnection {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok(_) = migrations.run_migrations(conn)
  conn
}

/// Dispatch through the production route table so a route missing from
/// `server.all_routes` fails here instead of only in production.
fn dispatch(
  conn: connection.DbConnection,
  request: wisp.Request,
) -> wisp.Response {
  router.match_route(server.all_routes(conn, "local"), request)
}

fn get(conn: connection.DbConnection, path: String) -> wisp.Response {
  dispatch(conn, sim.request(http.Get, path))
}

fn post_json(
  conn: connection.DbConnection,
  path: String,
  body: json.Json,
) -> wisp.Response {
  dispatch(conn, sim.json_body(sim.request(http.Post, path), body))
}

fn status(response: wisp.Response) -> Int {
  response.status
}

fn body(response: wisp.Response) -> String {
  sim.read_body(response)
}

// ─── Decoders ─────────────────────────────────────────────────────────────

fn field(key: String, inner: decode.Decoder(a)) -> decode.Decoder(a) {
  use value <- decode.field(key, inner)
  decode.success(value)
}

fn string_field(key: String) -> decode.Decoder(String) {
  field(key, decode.string)
}

fn action_type() -> decode.Decoder(String) {
  field("action", string_field("type"))
}

fn execution_status() -> decode.Decoder(String) {
  field("execution", string_field("status"))
}

fn execution_state_id() -> decode.Decoder(String) {
  field("execution", string_field("id"))
}

fn instance_id_of() -> decode.Decoder(String) {
  field("instance", string_field("id"))
}

/// One conversation entry as returned by `GET …/conversation`.
type Turn {
  Turn(
    step_execution_id: String,
    node_id: String,
    event_type: String,
    payload: String,
    sequence: Int,
  )
}

fn turn_decoder() -> decode.Decoder(Turn) {
  use step_execution_id <- decode.field("step_execution_id", decode.string)
  use node_id <- decode.field("node_id", decode.string)
  use event_type <- decode.field("event_type", decode.string)
  use payload <- decode.field("payload", decode.string)
  use sequence <- decode.field("sequence", decode.int)
  decode.success(Turn(
    step_execution_id: step_execution_id,
    node_id: node_id,
    event_type: event_type,
    payload: payload,
    sequence: sequence,
  ))
}

fn conversation(conn: connection.DbConnection, instance_id: String) {
  let response = get(conn, "/api/v1/flows/" <> instance_id <> "/conversation")
  assert status(response) == 200
  let assert Ok(turns) = json.parse(body(response), decode.list(turn_decoder()))
  turns
}

fn turn_kinds(turns: List(Turn)) -> List(#(String, String)) {
  list.map(turns, fn(turn) { #(turn.node_id, turn.event_type) })
}

fn turn_payloads(turns: List(Turn)) -> List(String) {
  list.map(turns, fn(turn) { turn.payload })
}

// ─── Template builders ────────────────────────────────────────────────────

fn human_input_node(id: String, prompt: String) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("name", json.string(id)),
    #("node_type", json.string("human_input")),
    #("goal", json.string(prompt)),
    #("prompt", json.string(prompt)),
    #("child_ids", json.preprocessed_array([])),
    #("branch_rules", json.preprocessed_array([])),
    #("loop_config", json.null()),
    #("agent_config", json.null()),
    #("output_schema", json.null()),
  ])
}

fn step_node(id: String, prompt: String) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("name", json.string(id)),
    #("node_type", json.string("step")),
    #("goal", json.string(prompt)),
    #("prompt", json.string(prompt)),
    #("child_ids", json.preprocessed_array([])),
    #("branch_rules", json.preprocessed_array([])),
    #("loop_config", json.null()),
    #("agent_config", json.null()),
    #("output_schema", json.null()),
  ])
}

fn transition(id: String, from: String, to: String) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("from_id", json.string(from)),
    #("to_id", json.string(to)),
    #("condition", json.null()),
    #("label", json.null()),
  ])
}

/// `step_a → step_b`: a flow that starts on an agent step, so it can be left
/// `running` while a reply is attempted.
fn linear_template() -> json.Json {
  json.object([
    #("name", json.string("Linear")),
    #("description", json.string("Two agent steps")),
    #("initial_node_id", json.string("step_a")),
    #(
      "nodes",
      json.preprocessed_array([
        step_node("step_a", "Do step A"),
        step_node("step_b", "Do step B"),
      ]),
    ),
    #(
      "transitions",
      json.preprocessed_array([transition("t1", "step_a", "step_b")]),
    ),
    #("on_done_template_id", json.null()),
    #("on_reject_template_id", json.null()),
  ])
}

/// `ask → confirm`: two consecutive human gates, so a client that only posts
/// replies walks the whole flow to `flow_complete`.
fn two_gate_template() -> json.Json {
  json.object([
    #("name", json.string("Two gates")),
    #("description", json.string("Two consecutive human gates")),
    #("initial_node_id", json.string("ask")),
    #(
      "nodes",
      json.preprocessed_array([
        human_input_node("ask", "Ask the first question"),
        human_input_node("confirm", "Ask the confirming question"),
      ]),
    ),
    #(
      "transitions",
      json.preprocessed_array([transition("t1", "ask", "confirm")]),
    ),
    #("on_done_template_id", json.null()),
    #("on_reject_template_id", json.null()),
  ])
}

// ─── Flow helpers (HTTP only) ─────────────────────────────────────────────

fn seed_templates(conn: connection.DbConnection) -> Nil {
  let assert Ok(inserted) = templates.seed_to_db(conn, 1)
  assert inserted == 6
  Nil
}

fn create_template(
  conn: connection.DbConnection,
  template: json.Json,
) -> String {
  let response = post_json(conn, "/api/v1/flow-templates", template)
  assert status(response) == 201
  let assert Ok(id) = json.parse(body(response), string_field("id"))
  id
}

fn create_task(conn: connection.DbConnection, title: String) -> String {
  let response =
    post_json(
      conn,
      "/api/v1/tasks",
      json.object([
        #("title", json.string(title)),
        #("level", json.string("ticket")),
        #("priority", json.string("medium")),
      ]),
    )
  assert status(response) == 201
  let assert Ok(id) = json.parse(body(response), string_field("id"))
  id
}

/// Instantiate a flow and return `#(instance_id, execution_state_id)`.
fn instantiate(
  conn: connection.DbConnection,
  task_id: String,
  template_id: String,
) -> #(String, String) {
  let response =
    post_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/flow",
      json.object([#("template_id", json.string(template_id))]),
    )
  assert status(response) == 201
  let raw = body(response)
  let assert Ok(instance_id) = json.parse(raw, instance_id_of())
  let assert Ok(state_id) = json.parse(raw, execution_state_id())
  #(instance_id, state_id)
}

fn advance(
  conn: connection.DbConnection,
  instance_id: String,
) -> #(String, String) {
  let response =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/advance",
      json.object([]),
    )
  assert status(response) == 200
  let raw = body(response)
  let assert Ok(action) = json.parse(raw, action_type())
  let assert Ok(exec_status) = json.parse(raw, execution_status())
  #(exec_status, action)
}

fn complete(
  conn: connection.DbConnection,
  instance_id: String,
  output: String,
) -> #(String, String) {
  let response =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/complete",
      json.object([#("output", json.string(output))]),
    )
  assert status(response) == 200
  let raw = body(response)
  let assert Ok(action) = json.parse(raw, action_type())
  let assert Ok(exec_status) = json.parse(raw, execution_status())
  #(exec_status, action)
}

fn reply(
  conn: connection.DbConnection,
  instance_id: String,
  message: String,
) -> wisp.Response {
  post_json(
    conn,
    "/api/v1/flows/" <> instance_id <> "/reply",
    json.object([#("message", json.string(message))]),
  )
}

fn reply_ok(
  conn: connection.DbConnection,
  instance_id: String,
  message: String,
) -> #(String, String) {
  let response = reply(conn, instance_id, message)
  assert status(response) == 200
  let raw = body(response)
  let assert Ok(action) = json.parse(raw, action_type())
  let assert Ok(exec_status) = json.parse(raw, execution_status())
  #(exec_status, action)
}

// ─── Persisted-row readers ────────────────────────────────────────────────

fn persisted_execution_status(
  conn: connection.DbConnection,
  instance_id: String,
) -> String {
  let assert Ok([[connection.TextVal(exec_status), ..], ..]) =
    connection.query(
      conn,
      "SELECT status FROM execution_states WHERE flow_instance_id = ?",
      [connection.TextVal(instance_id)],
    )
  exec_status
}

fn persisted_current_node(
  conn: connection.DbConnection,
  instance_id: String,
) -> Option(String) {
  let assert Ok([[connection.TextVal(node_id), ..], ..]) =
    connection.query(
      conn,
      "SELECT current_node_id FROM execution_states WHERE flow_instance_id = ?",
      [connection.TextVal(instance_id)],
    )
  Some(node_id)
}

fn instance_steps(
  conn: connection.DbConnection,
  instance_id: String,
) -> List(StepExecution) {
  let assert Ok(steps) = executions.get_steps_for_instance(conn, instance_id)
  steps
}

/// The gate step recorded for a human-input node; panics when the reply path
/// never created one.
fn gate_step(
  conn: connection.DbConnection,
  instance_id: String,
  node_id: String,
) -> StepExecution {
  let assert Ok(step) =
    instance_steps(conn, instance_id)
    |> list.find(fn(step) { step.node_id == node_id })
  step
}

fn instance_log_count(
  conn: connection.DbConnection,
  instance_id: String,
) -> Int {
  let assert Ok([[connection.IntVal(count), ..], ..]) =
    connection.query(
      conn,
      "SELECT COUNT(*) FROM session_logs sl "
        <> "JOIN step_executions se ON se.id = sl.step_execution_id "
        <> "WHERE se.flow_instance_id = ?",
      [connection.TextVal(instance_id)],
    )
  count
}

/// The step's logs, chronological (the paged view the API exposes).
fn step_logs(
  conn: connection.DbConnection,
  step_execution_id: String,
) -> List(SessionLog) {
  let assert Ok(logs) =
    session_logs.list_logs(conn, step_execution_id, 50, None)
  logs
}

// ─── Tests ────────────────────────────────────────────────────────────────

/// A client that only posts replies walks two consecutive human gates to
/// `flow_complete`: each reply persists its turn and parks the execution back
/// at `awaiting_input` while another gate follows.
pub fn replies_drive_the_conversation_to_flow_complete_test() {
  let conn = new_conn()
  let template_id = create_template(conn, two_gate_template())
  let task_id = create_task(conn, "Two-gate conversation")
  let #(instance_id, state_id) = instantiate(conn, task_id, template_id)

  // Advance into the first gate; nothing human is recorded yet.
  let assert #("awaiting_input", "await_input") = advance(conn, instance_id)
  assert persisted_execution_status(conn, instance_id) == "awaiting_input"
  assert persisted_current_node(conn, instance_id) == Some("ask")
  assert instance_steps(conn, instance_id) == []
  assert instance_log_count(conn, instance_id) == 0

  // First turn: the reply is persisted and the flow parks on the second gate.
  let assert #("awaiting_input", "await_input") =
    reply_ok(conn, instance_id, "first answer")
  assert persisted_execution_status(conn, instance_id) == "awaiting_input"
  assert persisted_current_node(conn, instance_id) == Some("confirm")

  let ask_step = gate_step(conn, instance_id, "ask")
  assert ask_step.status == StepInProgress
  assert ask_step.prompt == Some("Ask the first question")
  assert ask_step.flow_instance_id == instance_id
  assert ask_step.execution_state_id == state_id
  assert ask_step.completed_at == None

  let ask_logs = step_logs(conn, ask_step.id)
  assert list.map(ask_logs, fn(log) {
      #(log.event_type, log.sequence, log.payload, log.task_id)
    })
    == [
      #("prompt", 1, "Ask the first question", task_id),
      #("human_input", 2, "first answer", task_id),
    ]

  // Mid-conversation the transcript already shows the first turn only.
  let first_turn = conversation(conn, instance_id)
  assert turn_kinds(first_turn) == [#("ask", "prompt"), #("ask", "human_input")]
  assert turn_payloads(first_turn) == ["Ask the first question", "first answer"]

  // Second turn: no gate left, so the reply completes the flow.
  let assert #("completed", "flow_complete") =
    reply_ok(conn, instance_id, "second answer")
  assert persisted_execution_status(conn, instance_id) == "completed"

  let confirm_step = gate_step(conn, instance_id, "confirm")
  assert confirm_step.status == StepInProgress
  assert list.map(step_logs(conn, confirm_step.id), fn(log) {
      #(log.event_type, log.sequence, log.payload)
    })
    == [
      #("prompt", 1, "Ask the confirming question"),
      #("human_input", 2, "second answer"),
    ]

  // Two gates, two turns: one gate step and two logs each.
  assert list.length(instance_steps(conn, instance_id)) == 2
  assert instance_log_count(conn, instance_id) == 4

  // The transcript comes back in conversation order.
  let turns = conversation(conn, instance_id)
  assert turn_kinds(turns)
    == [
      #("ask", "prompt"),
      #("ask", "human_input"),
      #("confirm", "prompt"),
      #("confirm", "human_input"),
    ]
  assert turn_payloads(turns)
    == [
      "Ask the first question",
      "first answer",
      "Ask the confirming question",
      "second answer",
    ]
  assert list.map(turns, fn(turn) { turn.sequence }) == [1, 2, 1, 2]
  assert list.all(turns, fn(turn) {
    turn.step_execution_id == ask_step.id
    || turn.step_execution_id == confirm_step.id
  })

  // A terminal execution cannot take another turn, and the refusal writes
  // nothing.
  let refused = reply(conn, instance_id, "one more thought")
  assert status(refused) == 409
  assert string.contains(body(refused), "completed")
  assert instance_log_count(conn, instance_id) == 4
}

/// A reply to a shipped `design_implement` gate resumes on the next agent step
/// (`run_step`, `running`): the reply drives the flow as far as it can without
/// an agent, exactly like `/input` followed by `/advance`.
pub fn reply_resumes_a_shipped_flow_onto_the_next_step_test() {
  let conn = new_conn()
  seed_templates(conn)
  let task_id = create_task(conn, "Design and implement reply")
  let #(instance_id, _state_id) = instantiate(conn, task_id, "design_implement")

  let assert #("running", "run_step") = advance(conn, instance_id)
  let assert #("running", "run_step") = complete(conn, instance_id, "research")
  let assert #("running", "await_input") = complete(conn, instance_id, "design")
  // `complete` reports the human gate but does not park; `advance` does.
  let assert #("awaiting_input", "await_input") = advance(conn, instance_id)

  let assert #("running", "run_step") =
    reply_ok(conn, instance_id, "approve the design")
  assert persisted_execution_status(conn, instance_id) == "running"
  assert persisted_current_node(conn, instance_id) == Some("implement")

  let gate = gate_step(conn, instance_id, "design_review")
  assert gate.prompt
    == Some(
      "Review the proposed design. Reply with 'approve' to proceed or provide feedback.",
    )
  assert list.map(step_logs(conn, gate.id), fn(log) {
      #(log.event_type, log.sequence, log.payload)
    })
    == [
      #(
        "prompt",
        1,
        "Review the proposed design. Reply with 'approve' to proceed or provide feedback.",
      ),
      #("human_input", 2, "approve the design"),
    ]

  // The turn is visible through the transcript endpoint and the per-step page.
  let turns = conversation(conn, instance_id)
  assert turn_kinds(turns)
    == [#("design_review", "prompt"), #("design_review", "human_input")]
  let paged = get(conn, "/api/v1/executions/" <> gate.id <> "/logs")
  assert status(paged) == 200
  assert string.contains(body(paged), "\"event_type\":\"human_input\"")
  assert string.contains(body(paged), "approve the design")
}

/// Wrong id (404), wrong state (409 naming it) and invalid bodies (400) all
/// leave the conversation untouched.
pub fn reply_errors_persist_nothing_test() {
  let conn = new_conn()
  let template_id = create_template(conn, two_gate_template())
  let task_id = create_task(conn, "Reply errors")
  let #(instance_id, _state_id) = instantiate(conn, task_id, template_id)

  let unknown =
    post_json(
      conn,
      "/api/v1/flows/no-such-instance/reply",
      json.object([#("message", json.string("hello"))]),
    )
  assert status(unknown) == 404
  assert string.contains(body(unknown), "no-such-instance")

  // Not started: `pending` is not an awaiting_input execution.
  let pending = reply(conn, instance_id, "hello")
  assert status(pending) == 409
  assert string.contains(body(pending), "pending")

  let missing =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/reply",
      json.object([]),
    )
  assert status(missing) == 400
  assert string.contains(body(missing), "message")

  let empty = reply(conn, instance_id, "")
  assert status(empty) == 400
  assert string.contains(body(empty), "empty")

  let blank = reply(conn, instance_id, "   \n ")
  assert status(blank) == 400
  assert instance_log_count(conn, instance_id) == 0
  assert instance_steps(conn, instance_id) == []

  // An unknown instance has no transcript either.
  let unknown_conversation =
    get(conn, "/api/v1/flows/no-such-instance/conversation")
  assert status(unknown_conversation) == 404

  // A running execution is refused too, with its status named. (`advance` on
  // the two-gate flow would park it, so this uses a step-first flow.)
  let linear_id = create_template(conn, linear_template())
  let linear_task = create_task(conn, "Reply errors while running")
  let #(running_instance, _running_state) =
    instantiate(conn, linear_task, linear_id)
  let assert #("running", "run_step") = advance(conn, running_instance)
  let running = reply(conn, running_instance, "too early")
  assert status(running) == 409
  assert string.contains(body(running), "running")
  assert instance_log_count(conn, running_instance) == 0
  assert instance_steps(conn, running_instance) == []
}

/// The reply is observable on the execution event stream: the status change is
/// delivered live on the execution state's stream, and the turn's session-log
/// appends replay from the gate step's stream (the write point exports them, so
/// no second publish path exists).
pub fn reply_is_published_on_the_event_stream_test() {
  let conn = new_conn()
  let template_id = create_template(conn, two_gate_template())
  let task_id = create_task(conn, "Streamed reply")
  let #(instance_id, state_id) = instantiate(conn, task_id, template_id)
  let assert #("awaiting_input", "await_input") = advance(conn, instance_id)

  // Subscribe to the execution state before replying: the reply's transition
  // arrives as a live delivery, not as replay.
  let state_subject = process.new_subject()
  let snapshot = events.subscribe(state_id, state_subject, None)
  let assert #("awaiting_input", "await_input") =
    reply_ok(conn, instance_id, "streamed answer")

  let assert Ok(events.Deliver(state_event)) =
    process.receive(state_subject, within: 2000)
  assert state_event.kind == events.ExecutionStatusEvent
  assert state_event.execution_id == state_id
  assert state_event.sequence == snapshot.latest_sequence + 1
  let state_payload = json.to_string(state_event.data)
  assert string.contains(state_payload, "\"status\":\"awaiting_input\"")
  assert string.contains(state_payload, "\"type\":\"execution_status\"")

  // The gate step's stream replays the two appends, cursor-ordered.
  let gate = gate_step(conn, instance_id, "ask")
  let step_subject = process.new_subject()
  let assert events.SubscribeReply(events: step_events, latest_sequence: 2) =
    events.subscribe(gate.id, step_subject, None)
  assert list.map(step_events, fn(event) { event.sequence }) == [1, 2]
  assert list.all(step_events, fn(event) {
    event.kind == events.SessionLogEvent && event.execution_id == gate.id
  })

  let assert Ok(first_event) = list.first(step_events)
  let assert Ok(last_event) = list.last(step_events)
  let prompt_payload = json.to_string(first_event.data)
  assert string.contains(prompt_payload, "\"event_type\":\"prompt\"")
  assert string.contains(prompt_payload, "Ask the first question")

  let reply_payload = json.to_string(last_event.data)
  assert string.contains(reply_payload, "\"type\":\"session_log\"")
  assert string.contains(reply_payload, "\"event_type\":\"human_input\"")
  assert string.contains(reply_payload, "\"payload\":\"streamed answer\"")
  assert string.contains(reply_payload, "\"sequence\":2")

  // Resuming after the prompt returns exactly the human reply.
  let resumed = process.new_subject()
  let assert events.SubscribeReply(events: resumed_events, latest_sequence: 2) =
    events.subscribe(gate.id, resumed, Some(1))
  assert list.map(resumed_events, fn(event) { event.sequence }) == [2]
}
