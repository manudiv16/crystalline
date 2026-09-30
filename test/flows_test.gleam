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
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import sacrum_gleam/db/connection
import sacrum_gleam/db/migrations
import sacrum_gleam/db/session_logs
import sacrum_gleam/db/tasks as db_tasks
import sacrum_gleam/http/router
import sacrum_gleam/http/server
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

fn patch_json(
  conn: connection.DbConnection,
  path: String,
  body: json.Json,
) -> wisp.Response {
  dispatch(conn, sim.json_body(sim.request(http.Patch, path), body))
}

fn delete(conn: connection.DbConnection, path: String) -> wisp.Response {
  dispatch(conn, sim.request(http.Delete, path))
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

fn action_node_id() -> decode.Decoder(String) {
  field_decoder("action", field_decoder("node", string_field("id")))
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

/// A loop node with one step child, matching the engine's iteration idiom
/// (`loop_config.child_ids`, not a self-edge).
fn loop_node(id: String, child_ids: List(String)) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("name", json.string(id)),
    #("node_type", json.string("loop")),
    #("goal", json.string("loop until done")),
    #("prompt", json.null()),
    #("child_ids", json.array(child_ids, json.string)),
    #("branch_rules", json.preprocessed_array([])),
    #(
      "loop_config",
      json.object([
        #("max_iterations", json.int(3)),
        #("exit_condition", json.null()),
        #("child_ids", json.array(child_ids, json.string)),
      ]),
    ),
    #("agent_config", json.null()),
    #("output_schema", json.null()),
  ])
}

/// A Branch node: the engine re-evaluates `branch_rules` on every visit, so a
/// cycle that crosses it can exit on a later pass.
fn branch_node(id: String, rules: List(#(String, String))) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("name", json.string(id)),
    #("node_type", json.string("branch")),
    #("goal", json.string("route on the current variables")),
    #("prompt", json.null()),
    #("child_ids", json.preprocessed_array([])),
    #(
      "branch_rules",
      json.array(rules, fn(rule) {
        json.object([
          #("condition", json.string(rule.0)),
          #("target_id", json.string(rule.1)),
        ])
      }),
    ),
    #("loop_config", json.null()),
    #("agent_config", json.null()),
    #("output_schema", json.null()),
  ])
}

/// The shipped `review_gate` shape: `ask (input) → gate → {done | fix}`,
/// `fix → re_review → gate`. `gate → fix → re_review → gate` is a cycle that
/// crosses the Branch, which re-routes once `human_input` changes.
fn branch_cycle_template(name: String) -> json.Json {
  json.object([
    #("name", json.string(name)),
    #("description", json.string("Branch-mediated cycle")),
    #("initial_node_id", json.string("ask")),
    #(
      "nodes",
      json.preprocessed_array([
        human_input_node("ask", "Ask for the review verdict"),
        branch_node("gate", [
          #("human_input=approved", "done"),
          #("human_input=changes", "fix"),
        ]),
        step_node("fix", "Address review comments"),
        human_input_node("re_review", "Re-review after the fixes"),
        step_node("done", "Mark as approved"),
      ]),
    ),
    #(
      "transitions",
      json.preprocessed_array([
        transition("t1", "ask", "gate"),
        transition("t2", "gate", "fix"),
        transition("t3", "gate", "done"),
        transition("t4", "fix", "re_review"),
        transition("t5", "re_review", "gate"),
      ]),
    ),
    #("on_done_template_id", json.null()),
    #("on_reject_template_id", json.null()),
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

/// Count rows for a persisted-state assertion.
fn count_rows(
  conn: connection.DbConnection,
  sql: String,
  params: List(connection.Value),
) -> Int {
  let assert Ok([[connection.IntVal(count)], ..]) =
    connection.query(conn, sql, params)
  count
}

/// Count completed `step_executions` rows for one node of a task.
fn completed_step_rows(
  conn: connection.DbConnection,
  task_id: String,
  node_id: String,
) -> Int {
  count_rows(
    conn,
    "SELECT COUNT(*) FROM step_executions "
    <> "WHERE task_id = ? AND node_id = ? AND status = 'completed'",
    [connection.TextVal(task_id), connection.TextVal(node_id)],
  )
}

/// Complete the current step repeatedly until the flow reports
/// `flow_complete`; fails if the bound is exceeded.
fn complete_until_flow_complete(
  conn: connection.DbConnection,
  instance_id: String,
  remaining_steps: Int,
) -> Nil {
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/complete",
      json.object([#("output", json.string("done"))]),
    )
  assert status(resp) == 200
  let assert Ok(kind) = json.parse(body(resp), action_type())
  case kind {
    "flow_complete" -> Nil
    "run_step" -> {
      assert remaining_steps > 0
      complete_until_flow_complete(conn, instance_id, remaining_steps - 1)
    }
    _ -> panic as { "unexpected action before flow_complete: " <> kind }
  }
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
  assert string.contains(body(resp), "in use by 1 instance(s)")
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

// ─── Issue #18: template authoring, transitions, unassign ─────────────────

/// Invalid DAGs are rejected with 400 and no template row is persisted:
/// a cycle across two step nodes, and a transition to a non-existent node.
pub fn invalid_dag_templates_are_rejected_without_persisting_test() {
  let conn = new_conn()

  // Cycle step_a → step_b → step_a.
  let cyclic =
    json.object([
      #("name", json.string("Cyclic")),
      #("description", json.string("")),
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
        json.preprocessed_array([
          transition("t1", "step_a", "step_b"),
          transition("t2", "step_b", "step_a"),
        ]),
      ),
    ])
  let resp = post_json(conn, "/api/v1/flow-templates", cyclic)
  assert status(resp) == 400
  assert string.contains(body(resp), "cycle detected")
  assert count_rows(conn, "SELECT COUNT(*) FROM flow_templates", []) == 0

  // Transition targeting a node that does not exist.
  let dangling =
    json.object([
      #("name", json.string("Dangling")),
      #("description", json.string("")),
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
        json.preprocessed_array([transition("t1", "step_a", "ghost")]),
      ),
    ])
  let resp = post_json(conn, "/api/v1/flow-templates", dangling)
  assert status(resp) == 400
  assert string.contains(body(resp), "references unknown node: ghost")
  assert count_rows(conn, "SELECT COUNT(*) FROM flow_templates", []) == 0
}

/// The live validator gap: `step_a → step_b` plus the self-loop `step_b →
/// step_b` used to be accepted with 201, so an execution would re-dispatch
/// `step_b` forever. It is now a 400 and nothing is persisted.
pub fn self_transition_template_is_rejected_without_persisting_test() {
  let conn = new_conn()

  let self_loop =
    json.object([
      #("name", json.string("Self loop")),
      #("description", json.string("")),
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
        json.preprocessed_array([
          transition("t1", "step_a", "step_b"),
          transition("t2", "step_b", "step_b"),
        ]),
      ),
    ])
  let resp = post_json(conn, "/api/v1/flow-templates", self_loop)
  assert status(resp) == 400
  assert string.contains(body(resp), "self-transition: step_b -> step_b")
  assert count_rows(conn, "SELECT COUNT(*) FROM flow_templates", []) == 0

  // The same shape on a Loop node is rejected too: loops iterate through
  // loop_config.child_ids, never through a self-edge.
  let loop_self_loop =
    json.object([
      #("name", json.string("Loop self loop")),
      #("description", json.string("")),
      #("initial_node_id", json.string("loop_node")),
      #(
        "nodes",
        json.preprocessed_array([
          loop_node("loop_node", ["body"]),
          step_node("body", "Loop body"),
        ]),
      ),
      #(
        "transitions",
        json.preprocessed_array([transition("t1", "loop_node", "loop_node")]),
      ),
    ])
  let resp = post_json(conn, "/api/v1/flow-templates", loop_self_loop)
  assert status(resp) == 400
  assert string.contains(body(resp), "self-transition: loop_node -> loop_node")
  assert count_rows(conn, "SELECT COUNT(*) FROM flow_templates", []) == 0
}

/// A Branch-mediated back-edge (`gate → fix → re_review → gate`) is the loop
/// idiom the product ships in `review_gate`. It must be accepted at creation
/// (201) and be genuinely runnable: the Branch re-evaluates its rules on the
/// second pass and routes out of the cycle.
pub fn branch_mediated_cycle_is_runnable_test() {
  let conn = new_conn()
  let task_id = create_task(conn, "Branch cycle task")

  let resp =
    post_json(
      conn,
      "/api/v1/flow-templates",
      branch_cycle_template("Branch cycle"),
    )
  assert status(resp) == 201
  let assert Ok(template_id) = json.parse(body(resp), string_field("id"))

  let instance_id = instantiate(conn, task_id, template_id)

  // The flow opens on the human-input node.
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/advance",
      json.object([]),
    )
  assert status(resp) == 200
  let assert Ok(kind) = json.parse(body(resp), action_type())
  assert kind == "await_input"

  // "changes" → the gate routes into the cycle body.
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/input",
      json.object([#("input", json.string("changes"))]),
    )
  assert status(resp) == 200
  let assert Ok(node) = json.parse(body(resp), action_node_id())
  assert node == "fix"

  // Complete the cycle body → re-review (human input again).
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/complete",
      json.object([#("output", json.string("comments addressed"))]),
    )
  assert status(resp) == 200
  let assert Ok(kind) = json.parse(body(resp), action_type())
  assert kind == "await_input"
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/advance",
      json.object([]),
    )
  assert status(resp) == 200

  // Second pass through the same gate: "approved" now exits the cycle.
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/input",
      json.object([#("input", json.string("approved"))]),
    )
  assert status(resp) == 200
  let assert Ok(node) = json.parse(body(resp), action_node_id())
  assert node == "done"

  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/complete",
      json.object([#("output", json.string("approved"))]),
    )
  assert status(resp) == 200
  let assert Ok(kind) = json.parse(body(resp), action_type())
  assert kind == "flow_complete"

  // Persisted: the cycle body ran once, the exit node ran, the execution is
  // terminal — "accepted" means "runnable".
  assert completed_step_rows(conn, task_id, "fix") == 1
  assert completed_step_rows(conn, task_id, "done") == 1
  let resp = get(conn, "/api/v1/tasks/" <> task_id <> "/flow")
  assert status(resp) == 200
  let assert Ok(exec_status) = json.parse(body(resp), execution_status())
  assert exec_status == "completed"
}

/// The transitions sub-resource re-runs the validator against the full
/// candidate graph, so a self-loop added after creation is a 400 and the
/// stored transitions are unchanged.
pub fn self_transition_added_via_subresource_is_rejected_test() {
  let conn = new_conn()
  let template_id = create_template(conn, "Self loop via sub-resource")
  let transitions_path =
    "/api/v1/flow-templates/" <> template_id <> "/transitions"
  let transition_ids = decode.list(string_field("id"))

  let resp =
    post_json(conn, transitions_path, transition("t2", "step_b", "step_b"))
  assert status(resp) == 400
  assert string.contains(body(resp), "self-transition: step_b -> step_b")

  // Re-read the stored row: the rejected transition was not persisted.
  let assert Ok(ids) =
    json.parse(body(get(conn, transitions_path)), transition_ids)
  assert ids == ["t1"]
  assert count_rows(
      conn,
      "SELECT COUNT(*) FROM flow_templates WHERE id = ?",
      [connection.TextVal(template_id)],
    )
    == 1
}

/// PATCHing a template after instantiation does not rewrite the instance's
/// snapshot: the template row shows the new shape while the instance keeps
/// the old nodes and completes on them.
pub fn update_while_instantiated_keeps_instance_snapshot_test() {
  let conn = new_conn()
  let template_id = create_template(conn, "Snapshot source")
  let task_id = create_task(conn, "Snapshot task")
  let instance_id = instantiate(conn, task_id, template_id)

  // Rename step_b's prompt on the template.
  let resp =
    patch_json(
      conn,
      "/api/v1/flow-templates/" <> template_id,
      json.object([
        #("name", json.string("Snapshot source v2")),
        #("description", json.string("")),
        #("initial_node_id", json.string("step_a")),
        #(
          "nodes",
          json.preprocessed_array([
            step_node("step_a", "Do step A"),
            step_node("step_b", "Rewritten second step"),
          ]),
        ),
        #(
          "transitions",
          json.preprocessed_array([transition("t1", "step_a", "step_b")]),
        ),
      ]),
    )
  assert status(resp) == 200

  // The template row shows the new shape...
  let resp = get(conn, "/api/v1/flow-templates/" <> template_id)
  assert status(resp) == 200
  assert string.contains(body(resp), "Rewritten second step")

  // ...while the instance snapshot keeps the old nodes.
  let resp = get(conn, "/api/v1/tasks/" <> task_id <> "/flow")
  assert status(resp) == 200
  assert string.contains(body(resp), "Do step B")
  assert string.contains(body(resp), "Rewritten second step") == False

  // The instance completes on the old graph: advance → complete → advance
  // until flow_complete.
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/advance",
      json.object([]),
    )
  assert status(resp) == 200
  let assert Ok(kind) = json.parse(body(resp), action_type())
  assert kind == "run_step"

  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/complete",
      json.object([#("output", json.string("step A done"))]),
    )
  assert status(resp) == 200
  let assert Ok(kind) = json.parse(body(resp), action_type())
  assert kind == "run_step"
  assert string.contains(body(resp), "Do step B")

  complete_until_flow_complete(conn, instance_id, 10)
  let resp = get(conn, "/api/v1/tasks/" <> task_id <> "/flow")
  let assert Ok(exec_status) = json.parse(body(resp), execution_status())
  assert exec_status == "completed"
}

/// The transitions sub-resource lists, adds and removes transitions with the
/// right status codes, and never persists an invalid graph.
pub fn transitions_subresource_crud_test() {
  let conn = new_conn()
  let template_id = create_template(conn, "Transition editing")
  let transitions_path =
    "/api/v1/flow-templates/" <> template_id <> "/transitions"
  let transition_ids = decode.list(string_field("id"))

  // List the transition stored at creation.
  let resp = get(conn, transitions_path)
  assert status(resp) == 200
  let assert Ok(ids) = json.parse(body(resp), transition_ids)
  assert ids == ["t1"]

  // Duplicate id → 409, nothing persisted.
  let resp =
    post_json(conn, transitions_path, transition("t1", "step_a", "step_b"))
  assert status(resp) == 409
  let assert Ok(ids) = json.parse(body(get(conn, transitions_path)), transition_ids)
  assert ids == ["t1"]

  // Dangling reference → 400 naming the validator verdict, nothing persisted.
  let resp =
    post_json(conn, transitions_path, transition("t9", "step_a", "ghost"))
  assert status(resp) == 400
  assert string.contains(body(resp), "references unknown node: ghost")
  let assert Ok(ids) = json.parse(body(get(conn, transitions_path)), transition_ids)
  assert ids == ["t1"]

  // A valid second transition is stored and returned.
  let resp =
    post_json(conn, transitions_path, transition("t2", "step_a", "step_b"))
  assert status(resp) == 201
  let assert Ok(stored_id) = json.parse(body(resp), string_field("id"))
  assert stored_id == "t2"
  let assert Ok(ids) = json.parse(body(get(conn, transitions_path)), transition_ids)
  assert ids == ["t1", "t2"]

  // Unknown transition id → 404; known id → 200 and it is gone.
  let resp = delete(conn, transitions_path <> "/t-missing")
  assert status(resp) == 404
  let resp = delete(conn, transitions_path <> "/t2")
  assert status(resp) == 200
  let assert Ok(ids) = json.parse(body(get(conn, transitions_path)), transition_ids)
  assert ids == ["t1"]

  // Unknown template id → 404 on all three verbs.
  let missing_path = "/api/v1/flow-templates/tpl-missing/transitions"
  assert status(get(conn, missing_path)) == 404
  let resp =
    post_json(conn, missing_path, transition("t1", "step_a", "step_b"))
  assert status(resp) == 404
  assert status(delete(conn, missing_path <> "/t1")) == 404
}

/// Removal re-validates the *remaining* graph: deleting the invalid edge of
/// a legacy (pre-validation) row succeeds instead of 400-ing on the old
/// state, which a validate-before-remove implementation would do.
pub fn remove_transition_revalidates_remaining_graph_test() {
  let conn = new_conn()
  let nodes_json =
    "[{\"id\":\"step_a\",\"name\":\"step_a\",\"node_type\":\"step\","
    <> "\"goal\":\"Do step A\",\"prompt\":\"Do step A\",\"child_ids\":[],"
    <> "\"branch_rules\":[]},"
    <> "{\"id\":\"step_b\",\"name\":\"step_b\",\"node_type\":\"step\","
    <> "\"goal\":\"Do step B\",\"prompt\":\"Do step B\",\"child_ids\":[],"
    <> "\"branch_rules\":[]}]"
  let transitions_json =
    "[{\"id\":\"t1\",\"from_id\":\"step_a\",\"to_id\":\"step_b\"},"
    <> "{\"id\":\"t2\",\"from_id\":\"step_b\",\"to_id\":\"ghost\"}]"
  let assert Ok(_) =
    connection.execute(
      conn,
      "INSERT INTO flow_templates "
        <> "(id, name, description, initial_node_id, nodes_json, "
        <> "transitions_json, on_done_template_id, on_reject_template_id, "
        <> "created_at, updated_at) "
        <> "VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, 0, 0)",
      [
        connection.TextVal("tpl-legacy"),
        connection.TextVal("Legacy"),
        connection.TextVal(""),
        connection.TextVal("step_a"),
        connection.TextVal(nodes_json),
        connection.TextVal(transitions_json),
      ],
    )

  let resp =
    delete(conn, "/api/v1/flow-templates/tpl-legacy/transitions/t2")
  assert status(resp) == 200

  let resp = get(conn, "/api/v1/flow-templates/tpl-legacy/transitions")
  let assert Ok(ids) = json.parse(body(resp), decode.list(string_field("id")))
  assert ids == ["t1"]
}

/// DELETE on an unknown template is 404; only in-use templates conflict.
pub fn delete_template_unknown_returns_404_test() {
  let conn = new_conn()
  let resp = delete(conn, "/api/v1/flow-templates/tpl-missing")
  assert status(resp) == 404
}

/// Unassign is refused while the execution is pending, running or
/// awaiting_input, and refused deletes never remove any rows.
pub fn unassign_refused_while_execution_is_active_test() {
  let conn = new_conn()
  let resp =
    post_json(conn, "/api/v1/flow-templates", gated_template("Gated unassign"))
  let assert 201 = status(resp)
  let assert Ok(template_id) = json.parse(body(resp), string_field("id"))
  let task_id = create_task(conn, "Active flow task")

  // A task with no instance → 404.
  let resp = delete(conn, "/api/v1/tasks/" <> task_id <> "/flow")
  assert status(resp) == 404

  let instance_id = instantiate(conn, task_id, template_id)

  // pending → 409.
  let resp = delete(conn, "/api/v1/tasks/" <> task_id <> "/flow")
  assert status(resp) == 409
  assert string.contains(body(resp), "pending")

  // running → 409.
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/advance",
      json.object([]),
    )
  assert status(resp) == 200
  let resp = delete(conn, "/api/v1/tasks/" <> task_id <> "/flow")
  assert status(resp) == 409
  assert string.contains(body(resp), "running")

  // Drive to the human-input node: awaiting_input → 409.
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/complete",
      json.object([#("output", json.string("step A done"))]),
    )
  assert status(resp) == 200
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/advance",
      json.object([]),
    )
  assert status(resp) == 200
  let assert Ok(exec_status) = json.parse(body(resp), execution_status())
  assert exec_status == "awaiting_input"
  let resp = delete(conn, "/api/v1/tasks/" <> task_id <> "/flow")
  assert status(resp) == 409
  assert string.contains(body(resp), "awaiting_input")

  // The refused deletes never removed anything.
  let task_filter = [connection.TextVal(task_id)]
  assert count_rows(
      conn,
      "SELECT COUNT(*) FROM flow_instances WHERE task_id = ?",
      task_filter,
    )
    == 1
  assert count_rows(
      conn,
      "SELECT COUNT(*) FROM execution_states WHERE task_id = ?",
      task_filter,
    )
    == 1
}

/// Unassigning a completed execution deletes the instance (cascading to
/// execution state, steps and session logs), clears the task binding, and
/// lets the task be instantiated again.
pub fn unassign_completed_flow_cascades_and_rebinds_test() {
  let conn = new_conn()
  let template_id = create_template(conn, "Unassignable")
  let task_id = create_task(conn, "Terminal flow task")
  let instance_id = instantiate(conn, task_id, template_id)

  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/advance",
      json.object([]),
    )
  assert status(resp) == 200
  let resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/complete",
      json.object([#("output", json.string("step A done"))]),
    )
  assert status(resp) == 200

  // Attach a session log to the recorded step so the cascade assertions can
  // fail if session_logs ever stop cascading from flow_instances.
  let assert Ok([[connection.TextVal(step_id)], ..]) =
    connection.query(
      conn,
      "SELECT id FROM step_executions WHERE task_id = ?",
      [connection.TextVal(task_id)],
    )
  let assert Ok(_) =
    session_logs.append_log(conn, step_id, task_id, "text", "{}", 0)

  let task_filter = [connection.TextVal(task_id)]
  assert count_rows(
      conn,
      "SELECT COUNT(*) FROM flow_instances WHERE task_id = ?",
      task_filter,
    )
    == 1
  assert count_rows(
      conn,
      "SELECT COUNT(*) FROM execution_states WHERE task_id = ?",
      task_filter,
    )
    == 1
  assert count_rows(
      conn,
      "SELECT COUNT(*) FROM step_executions WHERE task_id = ?",
      task_filter,
    )
    == 1
  assert count_rows(
      conn,
      "SELECT COUNT(*) FROM session_logs WHERE task_id = ?",
      task_filter,
    )
    == 1

  // Finish the flow so the execution is terminal.
  complete_until_flow_complete(conn, instance_id, 10)

  let resp = delete(conn, "/api/v1/tasks/" <> task_id <> "/flow")
  assert status(resp) == 200

  // The instance row is gone and the schema cascaded to its children.
  assert count_rows(
      conn,
      "SELECT COUNT(*) FROM flow_instances WHERE task_id = ?",
      task_filter,
    )
    == 0
  assert count_rows(
      conn,
      "SELECT COUNT(*) FROM execution_states WHERE task_id = ?",
      task_filter,
    )
    == 0
  assert count_rows(
      conn,
      "SELECT COUNT(*) FROM step_executions WHERE task_id = ?",
      task_filter,
    )
    == 0
  assert count_rows(
      conn,
      "SELECT COUNT(*) FROM session_logs WHERE task_id = ?",
      task_filter,
    )
    == 0

  // The task binding is cleared on the persisted row...
  let assert Ok(stored_task) = db_tasks.get_task(conn, task_id)
  assert stored_task.flow_template_id == None
  assert stored_task.flow_instance_id == None
  assert stored_task.current_node_id == None

  // ...and the task can be instantiated again.
  let resp =
    post_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/flow",
      json.object([#("template_id", json.string(template_id))]),
    )
  assert status(resp) == 201
}