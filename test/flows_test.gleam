/// C7 acceptance tests for the Flows API.
///
/// Exercises the HTTP routes end-to-end against an in-memory libsql database
/// using `wisp/simulate` requests, mirroring `tasks_api_test`. Each test gets
/// a fresh connection so assertions never depend on shared state.
///
/// Acceptance criteria:
///   - template creation returns 201
///   - instantiation produces a `pending` execution
///   - advance returns an `Action`
///   - complete / input / reject drive the status transitions
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import sacrum_gleam/db/connection
import sacrum_gleam/db/migrations
import sacrum_gleam/http/router
import sacrum_gleam/http/routes/flows
import sacrum_gleam/http/routes/tasks
import wisp
import wisp/simulate as sim

pub fn main() -> Nil {
  gleeunit.main()
}

// ─── Request helpers ──────────────────────────────────────────────────────

/// Fresh in-memory database with the schema applied.
fn new_conn() -> connection.DbConnection {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok(_) = migrations.run_migrations(conn)
  conn
}

fn all_routes(conn: connection.DbConnection) -> List(router.Route) {
  list.append(tasks.task_routes(conn), flows.flow_routes(conn))
}

fn get(conn: connection.DbConnection, path: String) -> wisp.Response {
  router.match_route(all_routes(conn), sim.request(http.Get, path))
}

fn post_json(
  conn: connection.DbConnection,
  path: String,
  body: json.Json,
) -> wisp.Response {
  router.match_route(
    all_routes(conn),
    sim.json_body(sim.request(http.Post, path), body),
  )
}

fn patch_json(
  conn: connection.DbConnection,
  path: String,
  body: json.Json,
) -> wisp.Response {
  router.match_route(
    all_routes(conn),
    sim.json_body(sim.request(http.Patch, path), body),
  )
}

fn delete(conn: connection.DbConnection, path: String) -> wisp.Response {
  router.match_route(all_routes(conn), sim.request(http.Delete, path))
}

fn status(resp: wisp.Response) -> Int {
  resp.status
}

fn body(resp: wisp.Response) -> String {
  sim.read_body(resp)
}

// ─── Decoders ─────────────────────────────────────────────────────────────

fn field_decoder(key: String, inner: decode.Decoder(a)) -> decode.Decoder(a) {
  {
    use value <- decode.field(key, inner)
    decode.success(value)
  }
}

fn string_field(key: String) -> decode.Decoder(String) {
  field_decoder(key, decode.string)
}

fn action_type() -> decode.Decoder(String) {
  field_decoder("action", string_field("type"))
}

fn execution_status() -> decode.Decoder(String) {
  field_decoder("execution", string_field("status"))
}

fn instance_id_of() -> decode.Decoder(String) {
  field_decoder("instance", string_field("id"))
}

fn task_flow_instance_id() -> decode.Decoder(Option(String)) {
  field_decoder("flow_instance_id", decode.optional(decode.string))
}

// ─── Template builders ────────────────────────────────────────────────────

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

fn transition(id: String, from: String, to: String) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("from_id", json.string(from)),
    #("to_id", json.string(to)),
    #("condition", json.null()),
    #("label", json.null()),
  ])
}

/// Linear flow: step_a → step_b
fn linear_template(name: String) -> json.Json {
  json.object([
    #("name", json.string(name)),
    #("description", json.string("A linear two-step flow")),
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

/// Gate flow: step_a → human_input(approve) → step_b
fn gated_template(name: String) -> json.Json {
  json.object([
    #("name", json.string(name)),
    #("description", json.string("A human-gated flow")),
    #("initial_node_id", json.string("step_a")),
    #(
      "nodes",
      json.preprocessed_array([
        step_node("step_a", "Do step A"),
        human_input_node("approve", "Approve the result"),
        step_node("step_b", "Do step B"),
      ]),
    ),
    #(
      "transitions",
      json.preprocessed_array([
        transition("t1", "step_a", "approve"),
        transition("t2", "approve", "step_b"),
      ]),
    ),
    #("on_done_template_id", json.null()),
    #("on_reject_template_id", json.null()),
  ])
}

// ─── Shared helpers ───────────────────────────────────────────────────────

fn create_task(conn: connection.DbConnection, title: String) -> String {
  let resp =
    post_json(
      conn,
      "/api/v1/tasks",
      json.object([
        #("title", json.string(title)),
        #("level", json.string("ticket")),
        #("priority", json.string("medium")),
      ]),
    )
  let assert 201 = status(resp)
  let assert Ok(id) = json.parse(body(resp), string_field("id"))
  id
}

/// Create a template via the API and return its ID.
fn create_template(conn: connection.DbConnection, name: String) -> String {
  let resp = post_json(conn, "/api/v1/flow-templates", linear_template(name))
  let assert 201 = status(resp)
  let assert Ok(id) = json.parse(body(resp), string_field("id"))
  id
}

/// Instantiate a flow for a task and return the instance ID.
fn instantiate(
  conn: connection.DbConnection,
  task_id: String,
  template_id: String,
) -> String {
  let resp =
    post_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/flow",
      json.object([#("template_id", json.string(template_id))]),
    )
  let assert 201 = status(resp)
  let assert Ok(instance_id) = json.parse(body(resp), instance_id_of())
  instance_id
}

// ─── Acceptance tests ─────────────────────────────────────────────────────

/// POST /api/v1/flow-templates returns the created template with status 201.
pub fn create_template_returns_201_test() {
  let conn = new_conn()

  let resp = post_json(conn, "/api/v1/flow-templates", linear_template("Linear"))
  assert status(resp) == 201

  let response_body = body(resp)
  let assert Ok(id) = json.parse(response_body, string_field("id"))
  let assert Ok(name) = json.parse(response_body, string_field("name"))
  let assert Ok(initial) =
    json.parse(response_body, string_field("initial_node_id"))

  assert name == "Linear"
  assert initial == "step_a"
  assert string.contains(id, "tpl-")

  // The template is listed and fetchable by ID.
  let list_resp = get(conn, "/api/v1/flow-templates")
  assert status(list_resp) == 200
  assert string.contains(body(list_resp), name)

  let get_resp = get(conn, "/api/v1/flow-templates/" <> id)
  assert status(get_resp) == 200
  assert string.contains(body(get_resp), "step_a")
}

/// Invalid templates (missing prompt on a step) are rejected with 400.
pub fn invalid_template_is_rejected_test() {
  let conn = new_conn()

  // step node without a prompt falls through node_type check → not a valid
  // step (validator requires a prompt on Step nodes) → 400.
  let bad =
    json.object([
      #("name", json.string("Bad")),
      #("description", json.string("")),
      #("initial_node_id", json.string("missing")),
      #("nodes", json.preprocessed_array([])),
      #("transitions", json.preprocessed_array([])),
    ])

  let resp = post_json(conn, "/api/v1/flow-templates", bad)
  assert status(resp) == 400
}

/// PATCH + DELETE round-trip on templates.
pub fn update_and_delete_template_test() {
  let conn = new_conn()
  let id = create_template(conn, "Linear original")

  let resp =
    patch_json(
      conn,
      "/api/v1/flow-templates/" <> id,
      json.object([
        #("name", json.string("Linear renamed")),
        #("description", json.string("Renamed")),
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
      ]),
    )
  assert status(resp) == 200
  assert string.contains(body(resp), "Linear renamed")

  let del = delete(conn, "/api/v1/flow-templates/" <> id)
  assert status(del) == 200

  let after = get(conn, "/api/v1/flow-templates/" <> id)
  assert status(after) == 404
}

/// A template referenced by an instance cannot be deleted (409).
pub fn delete_template_in_use_returns_conflict_test() {
  let conn = new_conn()
  let template_id = create_template(conn, "In use")
  let task_id = create_task(conn, "Bound task")
  let _instance_id = instantiate(conn, task_id, template_id)

  let resp = delete(conn, "/api/v1/flow-templates/" <> template_id)
  assert status(resp) == 409
}

/// POST /api/v1/tasks/:task_id/flow creates a pending execution (201).
pub fn instantiate_creates_pending_execution_test() {
  let conn = new_conn()
  let template_id = create_template(conn, "Instantiate me")
  let task_id = create_task(conn, "Pending task")

  let resp =
    post_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/flow",
      json.object([#("template_id", json.string(template_id))]),
    )
  assert status(resp) == 201
  assert string.contains(body(resp), "\"status\":\"pending\"")

  let assert Ok(instance_id) = json.parse(body(resp), instance_id_of())
  assert string.contains(instance_id, "flow-")

  // The task is now bound to the instance.
  let task_resp = get(conn, "/api/v1/tasks/" <> task_id)
  assert status(task_resp) == 200
  let assert Ok(flow_instance_id) =
    json.parse(body(task_resp), task_flow_instance_id())
  assert flow_instance_id == Some(instance_id)

  // GET /api/v1/tasks/:task_id/flow reflects the same data.
  let flow_resp = get(conn, "/api/v1/tasks/" <> task_id <> "/flow")
  assert status(flow_resp) == 200
  let assert Ok(fetched_status) = json.parse(body(flow_resp), execution_status())
  assert fetched_status == "pending"
}

/// Instantiation validates both the task and the template and rejects a
/// second binding.
pub fn instantiate_validates_task_and_template_test() {
  let conn = new_conn()
  let template_id = create_template(conn, "Validator")
  let task_id = create_task(conn, "Bindable task")

  // Unknown template → 400.
  let resp =
    post_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/flow",
      json.object([#("template_id", json.string("tpl-missing"))]),
    )
  assert status(resp) == 400

  // Unknown task → 400.
  let resp =
    post_json(
      conn,
      "/api/v1/tasks/task-missing/flow",
      json.object([#("template_id", json.string(template_id))]),
    )
  assert status(resp) == 400

  // Second binding → 400.
  let _ = instantiate(conn, task_id, template_id)
  let resp =
    post_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/flow",
      json.object([#("template_id", json.string(template_id))]),
    )
  assert status(resp) == 400
}

/// Advance starts a pending execution and returns a run_step action.
pub fn advance_returns_run_step_action_test() {
  let conn = new_conn()
  let template_id = create_template(conn, "Advancer")
  let task_id = create_task(conn, "Advancing task")
  let instance_id = instantiate(conn, task_id, template_id)

  let resp = post_json(
    conn,
    "/api/v1/flows/" <> instance_id <> "/advance",
    json.object([]),
  )
  assert status(resp) == 200

  let response_body = body(resp)
  let assert Ok(kind) = json.parse(response_body, action_type())
  assert kind == "run_step"
  // The returned prompt is for the first node.
  assert string.contains(response_body, "Do step A")
  // The execution flipped to running.
  let assert Ok(exec_status) = json.parse(response_body, execution_status())
  assert exec_status == "running"
}

/// Completing every step drives the flow to flow_complete and status
/// completed.
pub fn complete_drives_flow_to_completion_test() {
  let conn = new_conn()
  let template_id = create_template(conn, "Completer")
  let task_id = create_task(conn, "Completing task")
  let instance_id = instantiate(conn, task_id, template_id)

  let _ = post_json(
    conn,
    "/api/v1/flows/" <> instance_id <> "/advance",
    json.object([]),
  )

  // Complete step A → next action runs step B.
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/complete",
      json.object([#("output", json.string("step A done"))]),
    )
  assert status(resp) == 200
  let response_body = body(resp)
  let assert Ok(kind) = json.parse(response_body, action_type())
  assert kind == "run_step"
  assert string.contains(response_body, "Do step B")
  let assert Ok(exec_status) = json.parse(response_body, execution_status())
  assert exec_status == "running"

  // Complete step B → flow completes.
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/complete",
      json.object([#("output", json.string("step B done"))]),
    )
  assert status(resp) == 200
  let response_body = body(resp)
  let assert Ok(kind) = json.parse(response_body, action_type())
  assert kind == "flow_complete"
  let assert Ok(exec_status) = json.parse(response_body, execution_status())
  assert exec_status == "completed"

  // A completed flow cannot advance again.
  let resp = post_json(
    conn,
    "/api/v1/flows/" <> instance_id <> "/advance",
    json.object([]),
  )
  assert status(resp) == 409
}

/// A human-input node parks at awaiting_input; /input resumes it.
pub fn input_resumes_awaiting_input_flow_test() {
  let conn = new_conn()
  let resp = post_json(conn, "/api/v1/flow-templates", gated_template("Gated"))
  let assert 201 = status(resp)
  let assert Ok(template_id) = json.parse(body(resp), string_field("id"))

  let task_id = create_task(conn, "Gated task")
  let instance_id = instantiate(conn, task_id, template_id)

  // Advance past the initial step.
  let _ = post_json(
    conn,
    "/api/v1/flows/" <> instance_id <> "/advance",
    json.object([]),
  )
  let _ = post_json(
    conn,
    "/api/v1/flows/" <> instance_id <> "/complete",
    json.object([#("output", json.string("step A done"))]),
  )

  // The human-input node parks the execution.
  let resp = post_json(
    conn,
    "/api/v1/flows/" <> instance_id <> "/advance",
    json.object([]),
  )
  assert status(resp) == 200
  let response_body = body(resp)
  let assert Ok(kind) = json.parse(response_body, action_type())
  assert kind == "await_input"
  let assert Ok(exec_status) = json.parse(response_body, execution_status())
  assert exec_status == "awaiting_input"

  // Advancing while awaiting input is rejected.
  let resp = post_json(
    conn,
    "/api/v1/flows/" <> instance_id <> "/advance",
    json.object([]),
  )
  assert status(resp) == 409

  // Providing input resumes execution toward the next step.
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/input",
      json.object([#("input", json.string("approved"))]),
    )
  assert status(resp) == 200
  let response_body = body(resp)
  let assert Ok(kind) = json.parse(response_body, action_type())
  assert kind == "run_step"
  assert string.contains(response_body, "Do step B")
}

/// Reject marks the execution rejected; further advances are rejected.
pub fn reject_marks_execution_rejected_test() {
  let conn = new_conn()
  let template_id = create_template(conn, "Rejectable")
  let task_id = create_task(conn, "Rejected task")
  let instance_id = instantiate(conn, task_id, template_id)

  let _ = post_json(
    conn,
    "/api/v1/flows/" <> instance_id <> "/advance",
    json.object([]),
  )

  let resp = post_json(
    conn,
    "/api/v1/flows/" <> instance_id <> "/reject",
    json.object([]),
  )
  assert status(resp) == 200
  let assert Ok(exec_status) = json.parse(body(resp), execution_status())
  assert exec_status == "rejected"

  let resp = post_json(
    conn,
    "/api/v1/flows/" <> instance_id <> "/advance",
    json.object([]),
  )
  assert status(resp) == 409
}

/// Flows on a task can be fetched before and after starting execution.
pub fn get_task_flow_reflects_current_state_test() {
  let conn = new_conn()
  let template_id = create_template(conn, "Fetchable")
  let task_id = create_task(conn, "Fetchable task")

  // Not instantiated yet → 404.
  let resp = get(conn, "/api/v1/tasks/" <> task_id <> "/flow")
  assert status(resp) == 404

  let instance_id = instantiate(conn, task_id, template_id)

  let resp = get(conn, "/api/v1/tasks/" <> task_id <> "/flow")
  assert status(resp) == 200
  assert string.contains(body(resp), instance_id)
  assert string.contains(body(resp), "\"status\":\"pending\"")
}