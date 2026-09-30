/// Acceptance tests for the Artifacts REST API.
///
/// Requests use the production route table and an in-memory database, then
/// assert both the HTTP contract and the persisted artifact rows.
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import gleam/option.{None}
import gleam/uri
import gleeunit
import sacrum_gleam/db/connection
import sacrum_gleam/db/migrations
import sacrum_gleam/domain/artifact
import sacrum_gleam/http/router
import sacrum_gleam/http/server
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

fn dispatch(conn: connection.DbConnection, req: wisp.Request) -> wisp.Response {
  router.match_route(server.all_routes(conn, "local"), req)
}

fn get(conn: connection.DbConnection, path: String) -> wisp.Response {
  dispatch(conn, sim.request(http.Get, path))
}

fn put_json(
  conn: connection.DbConnection,
  path: String,
  body: json.Json,
) -> wisp.Response {
  dispatch(conn, sim.json_body(sim.request(http.Put, path), body))
}

fn delete(conn: connection.DbConnection, path: String) -> wisp.Response {
  dispatch(conn, sim.request(http.Delete, path))
}

fn status(response: wisp.Response) -> Int {
  response.status
}

fn body(response: wisp.Response) -> String {
  sim.read_body(response)
}

fn string_field(key: String) -> decode.Decoder(String) {
  use value <- decode.field(key, decode.string)
  decode.success(value)
}

fn content_decoder() -> decode.Decoder(json.Json) {
  use content <- decode.field("content", artifact.json_decoder())
  decode.success(content)
}

fn artifact_id_decoder() -> decode.Decoder(String) {
  string_field("id")
}

fn artifact_content(response: wisp.Response) -> json.Json {
  let assert Ok(content) = json.parse(body(response), content_decoder())
  content
}

fn create_task(conn: connection.DbConnection, title: String) -> String {
  let response =
    dispatch(
      conn,
      sim.json_body(
        sim.request(http.Post, "/api/v1/tasks"),
        json.object([
          #("title", json.string(title)),
          #("level", json.string("ticket")),
          #("priority", json.string("medium")),
        ]),
      ),
    )
  assert status(response) == 201
  let assert Ok(id) = json.parse(body(response), string_field("id"))
  id
}

fn artifact_path(task_id: String, logical_name: String) -> String {
  "/api/v1/tasks/"
  <> task_id
  <> "/artifacts/"
  <> uri.percent_encode(logical_name)
}

fn assert_round_trip(
  conn: connection.DbConnection,
  task_id: String,
  logical_name: String,
  expected: json.Json,
) -> Nil {
  let path = artifact_path(task_id, logical_name)
  let put = put_json(conn, path, json.object([#("content", expected)]))
  assert status(put) == 200
  assert json.to_string(artifact_content(put)) == json.to_string(expected)

  let fetched = get(conn, path)
  assert status(fetched) == 200
  assert json.to_string(artifact_content(fetched)) == json.to_string(expected)
  Nil
}

fn artifact_count(conn: connection.DbConnection, task_id: String) -> Int {
  let assert Ok(row) =
    connection.query_one(
      conn,
      "SELECT COUNT(*) FROM artifacts WHERE task_id = ?",
      [connection.TextVal(task_id)],
    )
  case row {
    [connection.IntVal(count), ..] -> count
    _ -> 0
  }
}

fn artifact_updated_at(conn: connection.DbConnection, task_id: String) -> Int {
  let assert Ok(row) =
    connection.query_one(
      conn,
      "SELECT updated_at FROM artifacts WHERE task_id = ? AND logical_name = ?",
      [connection.TextVal(task_id), connection.TextVal("build/result")],
    )
  case row {
    [connection.IntVal(updated_at), ..] -> updated_at
    _ -> 0
  }
}

fn stored_content(
  conn: connection.DbConnection,
  task_id: String,
  logical_name: String,
) -> String {
  let assert Ok(row) =
    connection.query_one(
      conn,
      "SELECT content_json FROM artifacts WHERE task_id = ? AND logical_name = ?",
      [connection.TextVal(task_id), connection.TextVal(logical_name)],
    )
  case row {
    [connection.TextVal(content), ..] -> content
    _ -> ""
  }
}

pub fn put_and_get_round_trip_arbitrary_json_test() {
  let conn = new_conn()
  let task_id = create_task(conn, "Artifact round-trip")
  let object_value =
    json.object([
      #("nested", json.object([#("enabled", json.bool(True))])),
      #("items", json.array([1, 2], json.int)),
    ])
  let array_value =
    json.array(
      [
        json.string("text"),
        json.int(4),
        json.float(2.5),
        json.bool(False),
        json.null(),
      ],
      fn(value) { value },
    )

  assert_round_trip(conn, task_id, "design v1/approved", object_value)
  assert_round_trip(conn, task_id, "metadata", array_value)
  assert_round_trip(conn, task_id, "plain string", json.string("result"))
  assert_round_trip(conn, task_id, "integer", json.int(42))
  assert_round_trip(conn, task_id, "boolean", json.bool(True))
  assert_round_trip(conn, task_id, "nothing", json.null())

  assert stored_content(conn, task_id, "design v1/approved")
    == json.to_string(object_value)
  assert artifact_count(conn, task_id) == 6
}

pub fn put_updates_in_place_and_advances_updated_at_test() {
  let conn = new_conn()
  let task_id = create_task(conn, "Artifact update")
  let path = artifact_path(task_id, "build/result")
  let original = json.object([#("version", json.int(1))])
  let updated = json.object([#("version", json.int(2))])

  let first = put_json(conn, path, json.object([#("content", original)]))
  assert status(first) == 200
  let assert Ok(first_id) = json.parse(body(first), artifact_id_decoder())
  let first_updated_at = artifact_updated_at(conn, task_id)

  let second = put_json(conn, path, json.object([#("content", updated)]))
  assert status(second) == 200
  let assert Ok(second_id) = json.parse(body(second), artifact_id_decoder())

  assert first_id == second_id
  assert artifact_count(conn, task_id) == 1
  assert artifact_updated_at(conn, task_id) > first_updated_at
  assert stored_content(conn, task_id, "build/result")
    == json.to_string(updated)
  assert json.to_string(artifact_content(get(conn, path)))
    == json.to_string(updated)
}

pub fn logical_names_are_unique_per_task_test() {
  let conn = new_conn()
  let first_task = create_task(conn, "First artifact owner")
  let second_task = create_task(conn, "Second artifact owner")
  let first =
    put_json(
      conn,
      artifact_path(first_task, "shared/config"),
      json.object([#("content", json.string("first"))]),
    )
  let second =
    put_json(
      conn,
      artifact_path(second_task, "shared/config"),
      json.object([#("content", json.string("second"))]),
    )

  assert status(first) == 200
  assert status(second) == 200
  assert artifact_count(conn, first_task) == 1
  assert artifact_count(conn, second_task) == 1
  assert json.to_string(
      artifact_content(get(conn, artifact_path(first_task, "shared/config"))),
    )
    == json.to_string(json.string("first"))
  assert json.to_string(
      artifact_content(get(conn, artifact_path(second_task, "shared/config"))),
    )
    == json.to_string(json.string("second"))
}

pub fn delete_removes_only_the_targeted_artifact_test() {
  let conn = new_conn()
  let first_task = create_task(conn, "Delete target")
  let second_task = create_task(conn, "Delete neighbor")
  let logical_name = "same/name"
  let first_path = artifact_path(first_task, logical_name)
  let second_path = artifact_path(second_task, logical_name)
  let content = json.array([json.int(1)], fn(value) { value })

  assert status(put_json(conn, first_path, json.object([#("content", content)])))
    == 200
  assert status(put_json(
      conn,
      second_path,
      json.object([#("content", json.string("keep"))]),
    ))
    == 200

  assert status(delete(conn, first_path)) == 200
  assert artifact_count(conn, first_task) == 0
  assert artifact_count(conn, second_task) == 1
  let remaining = get(conn, second_path)
  assert status(remaining) == 200
  assert json.to_string(artifact_content(remaining))
    == json.to_string(json.string("keep"))
  assert status(delete(conn, first_path)) == 404
}

pub fn list_orders_by_logical_name_and_missing_artifacts_404_test() {
  let conn = new_conn()
  let task_id = create_task(conn, "Artifact listing")
  let _zeta =
    put_json(
      conn,
      artifact_path(task_id, "zeta"),
      json.object([#("content", json.int(1))]),
    )
  let _alpha =
    put_json(
      conn,
      artifact_path(task_id, "alpha"),
      json.object([#("content", json.int(2))]),
    )

  let listed = get(conn, "/api/v1/tasks/" <> task_id <> "/artifacts")
  assert status(listed) == 200
  let names_decoder = decode.list(string_field("logical_name"))
  let assert Ok(names) = json.parse(body(listed), names_decoder)
  assert names == ["alpha", "zeta"]

  assert status(get(conn, "/api/v1/tasks/missing-task/artifacts")) == 404
  assert status(get(conn, artifact_path(task_id, "absent"))) == 404
}

pub fn invalid_json_or_missing_content_returns_400_without_write_test() {
  let conn = new_conn()
  let task_id = create_task(conn, "Invalid artifact body")
  let path = artifact_path(task_id, "invalid")

  let missing_content =
    put_json(conn, path, json.object([#("value", json.int(1))]))
  assert status(missing_content) == 400
  assert artifact_count(conn, task_id) == 0

  let malformed_request =
    sim.request(http.Put, path)
    |> sim.string_body("{")
    |> request.set_header("content-type", "application/json")
  let malformed = dispatch(conn, malformed_request)
  assert status(malformed) == 400
  assert artifact_count(conn, task_id) == 0
}

pub fn deleting_task_row_cascades_to_artifacts_test() {
  let conn = new_conn()
  let task_id = create_task(conn, "Cascade artifact")
  let path = artifact_path(task_id, "to-delete")
  let response =
    put_json(conn, path, json.object([#("content", json.string("persisted"))]))
  assert status(response) == 200
  assert artifact_count(conn, task_id) == 1

  let assert Ok(_) =
    connection.execute(conn, "DELETE FROM tasks WHERE id = ?", [
      connection.TextVal(task_id),
    ])
  assert artifact_count(conn, task_id) == 0
  assert status(get(conn, path)) == 404
}
