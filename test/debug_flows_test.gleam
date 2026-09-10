import gleam/dynamic
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
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

fn new_conn() -> connection.DbConnection {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok(_) = migrations.run_migrations(conn)
  conn
}

fn all_routes(conn: connection.DbConnection) -> List(router.Route) {
  list.append(tasks.task_routes(conn), flows.flow_routes(conn))
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

fn body(resp: wisp.Response) -> String {
  sim.read_body(resp)
}

pub fn debug_advance_test() {
  let conn = new_conn()

  // Create a task
  let task_resp =
    post_json(
      conn,
      "/api/v1/tasks",
      json.object([
        #("title", json.string("T")),
        #("level", json.string("ticket")),
        #("priority", json.string("medium")),
      ]),
    )
  let assert Ok(task_id) = json.parse(body(task_resp), string_decoder("id"))

  // Create a template
  let tpl_resp =
    post_json(
      conn,
      "/api/v1/flow-templates",
      json.object([
        #("name", json.string("Tpl")),
        #("description", json.string("")),
        #("initial_node_id", json.string("a")),
        #(
          "nodes",
          json.preprocessed_array([
            node("a", "Do A"),
            node("b", "Do B"),
          ]),
        ),
        #(
          "transitions",
          json.preprocessed_array([
            trans("t1", "a", "b"),
          ]),
        ),
      ]),
    )
  let assert Ok(tpl_id) = json.parse(body(tpl_resp), string_decoder("id"))

  let inst_resp =
    post_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/flow",
      json.object([#("template_id", json.string(tpl_id))]),
    )
  let inst_body = body(inst_resp)
  io_debug("INSTANTIATE STATUS: " <> int_to_string(inst_resp.status))
  io_debug("INSTANTIATE BODY: " <> inst_body)
  let assert Ok(instance_id) =
    json.parse(inst_body, nested_decoder("instance", string_decoder("id")))

  let adv_resp =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/advance",
      json.object([]),
    )
  io_debug("ADVANCE STATUS: " <> int_to_string(adv_resp.status))
  io_debug("ADVANCE BODY: " <> body(adv_resp))

  let adv2 =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/advance",
      json.object([]),
    )
  io_debug("ADVANCE2 STATUS: " <> int_to_string(adv2.status))

  assert adv_resp.status == 200
}

// ─── tiny helpers ─────────────────────────────────────────────────────────

fn node(id: String, prompt: String) -> json.Json {
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

fn trans(id: String, from: String, to: String) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("from_id", json.string(from)),
    #("to_id", json.string(to)),
    #("condition", json.null()),
    #("label", json.null()),
  ])
}

fn string_decoder(key: String) -> decode.Decoder(String) {
  {
    use value <- decode.field(key, decode.string)
    decode.success(value)
  }
}

fn nested_decoder(key: String, inner: decode.Decoder(a)) -> decode.Decoder(a) {
  {
    use value <- decode.field(key, inner)
    decode.success(value)
  }
}

@external(erlang, "io", "format")
fn io_format(format: String, args: List(dynamic.Dynamic)) -> Nil

fn io_debug(message: String) -> Nil {
  io_format("~s~n", [dynamic.string(message)])
}

fn int_to_string(value: Int) -> String {
  int.to_string(value)
}