/// Acceptance tests for the Sections REST API.
///
/// Exercises the production route table with in-memory libsql connections and
/// verifies both HTTP responses and persisted section rows.
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import sacrum_gleam/db/connection
import sacrum_gleam/db/migrations
import sacrum_gleam/db/sections as db_sections
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

fn dispatch(
  conn: connection.DbConnection,
  request: wisp.Request,
) -> wisp.Response {
  router.match_route(list.append(server.all_routes(conn, "local"), []), request)
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

fn status(response: wisp.Response) -> Int {
  response.status
}

fn body(response: wisp.Response) -> String {
  sim.read_body(response)
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
  let assert 201 = status(response)
  let assert Ok(id) = json.parse(body(response), string_field("id"))
  id
}

fn create_section(
  conn: connection.DbConnection,
  task_id: String,
  section_type: String,
  content: String,
  order: Option(Int),
) -> String {
  let fields = [
    #("section_type", json.string(section_type)),
    #("content", json.string(content)),
  ]
  let fields = case order {
    Some(value) -> list.append(fields, [#("order", json.int(value))])
    None -> fields
  }
  let response =
    post_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/sections",
      json.object(fields),
    )
  let assert 201 = status(response)
  let assert Ok(id) = json.parse(body(response), string_field("id"))
  id
}

fn string_field(key: String) -> decode.Decoder(String) {
  use value <- decode.field(key, decode.string)
  decode.success(value)
}

fn ordered_sections_decoder() -> decode.Decoder(List(#(String, Int))) {
  decode.list(of: {
    use content <- decode.field("content", decode.string)
    use order <- decode.field("order", decode.int)
    decode.success(#(content, order))
  })
}

fn code_ref_decoder() -> decode.Decoder(
  Option(#(String, Option(Int), Option(Int), Option(String), Option(String))),
) {
  use code_ref <- decode.field(
    "code_ref",
    decode.optional({
      use path <- decode.field("path", decode.string)
      use line_start <- decode.field("line_start", decode.optional(decode.int))
      use line_end <- decode.field("line_end", decode.optional(decode.int))
      use name <- decode.field("name", decode.optional(decode.string))
      use description <- decode.field(
        "description",
        decode.optional(decode.string),
      )
      decode.success(#(path, line_start, line_end, name, description))
    }),
  )
  decode.success(code_ref)
}

fn section_count(conn: connection.DbConnection) -> Int {
  let assert Ok([[connection.IntVal(count), ..], ..]) =
    connection.query(conn, "SELECT COUNT(*) FROM sections", [])
  count
}

fn task_section_count(conn: connection.DbConnection, task_id: String) -> Int {
  let assert Ok([[connection.IntVal(count), ..], ..]) =
    connection.query(conn, "SELECT COUNT(*) FROM sections WHERE task_id = ?", [
      connection.TextVal(task_id),
    ])
  count
}

pub fn create_and_list_sections_orders_and_isolates_by_task_test() {
  let conn = new_conn()
  let first_task = create_task(conn, "Sections owner")
  let other_task = create_task(conn, "Other sections owner")

  let empty = get(conn, "/api/v1/tasks/" <> first_task <> "/sections")
  assert status(empty) == 200
  let assert Ok(empty_sections) =
    json.parse(body(empty), decode.list(decode.string))
  assert empty_sections == []

  let _later = create_section(conn, first_task, "goal", "Later", Some(8))
  let earlier = create_section(conn, first_task, "context", "Earlier", Some(2))
  let same_order =
    create_section(conn, first_task, "context", "First at same order", Some(2))
  let assert Ok(_) =
    connection.execute(
      conn,
      "UPDATE sections SET created_at = 20 WHERE id = ?",
      [connection.TextVal(earlier)],
    )
  let assert Ok(_) =
    connection.execute(
      conn,
      "UPDATE sections SET created_at = 10 WHERE id = ?",
      [connection.TextVal(same_order)],
    )
  let _appended =
    create_section(conn, first_task, "constraint", "Appended", None)
  let other_id = create_section(conn, other_task, "goal", "Private", Some(0))

  let response = get(conn, "/api/v1/tasks/" <> first_task <> "/sections")
  assert status(response) == 200
  let assert Ok(sections) =
    json.parse(body(response), ordered_sections_decoder())
  assert sections
    == [
      #("First at same order", 2),
      #("Earlier", 2),
      #("Later", 8),
      #("Appended", 9),
    ]
  assert task_section_count(conn, first_task) == 4

  let isolated = get(conn, "/api/v1/tasks/" <> other_task <> "/sections")
  assert status(isolated) == 200
  let assert Ok(other_sections) =
    json.parse(body(isolated), ordered_sections_decoder())
  assert other_sections == [#("Private", 0)]
  assert string.contains(body(isolated), other_id)
}

pub fn code_reference_round_trips_and_clears_test() {
  let conn = new_conn()
  let task_id = create_task(conn, "Code references")
  let response =
    post_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/sections",
      json.object([
        #("section_type", json.string("current_behavior")),
        #("content", json.string("Existing behavior")),
        #(
          "code_ref",
          json.object([
            #("path", json.string("src/login.gleam")),
            #("line_start", json.int(12)),
            #("line_end", json.int(28)),
            #("name", json.string("authenticate")),
            #("description", json.string("Token validation")),
          ]),
        ),
      ]),
    )
  assert status(response) == 201
  let assert Ok(id) = json.parse(body(response), string_field("id"))
  let assert Ok(code_ref) = json.parse(body(response), code_ref_decoder())
  assert code_ref
    == Some(#(
      "src/login.gleam",
      Some(12),
      Some(28),
      Some("authenticate"),
      Some("Token validation"),
    ))

  let stored = get(conn, "/api/v1/sections/" <> id)
  assert status(stored) == 200
  let assert Ok(stored_ref) = json.parse(body(stored), code_ref_decoder())
  assert stored_ref == code_ref
  let assert Ok([
    [
      connection.TextVal(path),
      connection.IntVal(line_start),
      connection.IntVal(line_end),
      connection.TextVal(name),
      connection.TextVal(description),
    ],
  ]) =
    connection.query(
      conn,
      "SELECT code_ref_path, code_ref_line_start, code_ref_line_end, "
        <> "code_ref_name, code_ref_description FROM sections WHERE id = ?",
      [connection.TextVal(id)],
    )
  assert #(path, line_start, line_end, name, description)
    == #("src/login.gleam", 12, 28, "authenticate", "Token validation")

  let cleared =
    patch_json(
      conn,
      "/api/v1/sections/" <> id,
      json.object([#("code_ref", json.null())]),
    )
  assert status(cleared) == 200
  let assert Ok(cleared_ref) = json.parse(body(cleared), code_ref_decoder())
  assert cleared_ref == None
  let assert Ok([
    [
      connection.NullVal,
      connection.NullVal,
      connection.NullVal,
      connection.NullVal,
      connection.NullVal,
    ],
  ]) =
    connection.query(
      conn,
      "SELECT code_ref_path, code_ref_line_start, code_ref_line_end, "
        <> "code_ref_name, code_ref_description FROM sections WHERE id = ?",
      [connection.TextVal(id)],
    )
  let partial =
    patch_json(
      conn,
      "/api/v1/sections/" <> id,
      json.object([
        #(
          "code_ref",
          json.object([
            #("path", json.string("src/auth.gleam")),
            #("line_start", json.int(7)),
          ]),
        ),
      ]),
    )
  assert status(partial) == 200
  let assert Ok(partial_ref) = json.parse(body(partial), code_ref_decoder())
  assert partial_ref == Some(#("src/auth.gleam", Some(7), None, None, None))
}

pub fn checklist_state_can_be_set_and_cleared_test() {
  let conn = new_conn()
  let task_id = create_task(conn, "Checklist state")
  let response =
    post_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/sections",
      json.object([
        #("section_type", json.string("checklist_item")),
        #("content", json.string("Run the suite")),
        #("checklist_state", json.string("done")),
      ]),
    )
  assert status(response) == 201
  let assert Ok(id) = json.parse(body(response), string_field("id"))
  let assert Ok([[connection.TextVal("done")]]) =
    connection.query(conn, "SELECT checklist_state FROM sections WHERE id = ?", [
      connection.TextVal(id),
    ])

  let updated =
    patch_json(
      conn,
      "/api/v1/sections/" <> id,
      json.object([#("checklist_state", json.string("undone"))]),
    )
  assert status(updated) == 200
  let assert Ok([[connection.TextVal("undone")]]) =
    connection.query(conn, "SELECT checklist_state FROM sections WHERE id = ?", [
      connection.TextVal(id),
    ])

  let cleared =
    patch_json(
      conn,
      "/api/v1/sections/" <> id,
      json.object([#("checklist_state", json.null())]),
    )
  assert status(cleared) == 200
  let assert Ok([[connection.NullVal]]) =
    connection.query(conn, "SELECT checklist_state FROM sections WHERE id = ?", [
      connection.TextVal(id),
    ])
}

pub fn invalid_section_input_returns_400_without_writing_rows_test() {
  let conn = new_conn()
  let task_id = create_task(conn, "Validation")
  let count_before = section_count(conn)
  let endpoint = "/api/v1/tasks/" <> task_id <> "/sections"

  let invalid_type =
    post_json(
      conn,
      endpoint,
      json.object([
        #("section_type", json.string("unknown")),
        #("content", json.string("No row")),
      ]),
    )
  assert status(invalid_type) == 400

  let missing_content =
    post_json(
      conn,
      endpoint,
      json.object([#("section_type", json.string("goal"))]),
    )
  assert status(missing_content) == 400

  let invalid_state =
    post_json(
      conn,
      endpoint,
      json.object([
        #("section_type", json.string("checklist_item")),
        #("content", json.string("No row")),
        #("checklist_state", json.string("pending")),
      ]),
    )
  assert status(invalid_state) == 400

  let unknown_task =
    post_json(
      conn,
      "/api/v1/tasks/missing-task/sections",
      json.object([
        #("section_type", json.string("goal")),
        #("content", json.string("No row")),
      ]),
    )
  assert status(unknown_task) == 400
  assert section_count(conn) == count_before

  let valid_id = create_section(conn, task_id, "checklist_item", "Keep", None)
  let invalid_type_patch =
    patch_json(
      conn,
      "/api/v1/sections/" <> valid_id,
      json.object([#("section_type", json.string("not_a_section"))]),
    )
  assert status(invalid_type_patch) == 400

  let invalid_state_patch =
    patch_json(
      conn,
      "/api/v1/sections/" <> valid_id,
      json.object([#("checklist_state", json.string("pending"))]),
    )
  assert status(invalid_state_patch) == 400
  assert section_count(conn) == count_before + 1
  let assert Ok([[connection.TextVal("checklist_item"), connection.NullVal]]) =
    connection.query(
      conn,
      "SELECT section_type, checklist_state FROM sections WHERE id = ?",
      [connection.TextVal(valid_id)],
    )
}

pub fn section_get_patch_delete_and_unknown_ids_test() {
  let conn = new_conn()
  let task_id = create_task(conn, "Section CRUD")
  let id = create_section(conn, task_id, "goal", "Original", Some(3))

  let updated =
    patch_json(
      conn,
      "/api/v1/sections/" <> id,
      json.object([
        #("content", json.string("Updated")),
        #("order", json.int(7)),
        #("section_type", json.string("desired_behavior")),
      ]),
    )
  assert status(updated) == 200
  let assert Ok([
    [
      connection.TextVal("desired_behavior"),
      connection.TextVal("Updated"),
      connection.IntVal(7),
    ],
  ]) =
    connection.query(
      conn,
      "SELECT section_type, content, \"order\" FROM sections WHERE id = ?",
      [connection.TextVal(id)],
    )

  let removed = delete(conn, "/api/v1/sections/" <> id)
  assert status(removed) == 200
  assert section_count(conn) == 0
  let assert Ok(None) = db_sections.get_section(conn, id)

  assert status(get(conn, "/api/v1/sections/missing-section")) == 404
  assert status(patch_json(
      conn,
      "/api/v1/sections/missing-section",
      json.object([#("content", json.string("Not written"))]),
    ))
    == 404
  assert status(delete(conn, "/api/v1/sections/missing-section")) == 404
}

pub fn deleting_task_cascades_to_its_sections_test() {
  let conn = new_conn()
  let task_id = create_task(conn, "Cascade owner")
  let _section_id =
    create_section(conn, task_id, "goal", "Removed with task", None)
  assert task_section_count(conn, task_id) == 1

  let assert Ok(_) =
    connection.execute(conn, "DELETE FROM tasks WHERE id = ?", [
      connection.TextVal(task_id),
    ])
  assert task_section_count(conn, task_id) == 0
  assert section_count(conn) == 0
}

pub fn listing_unknown_task_returns_404_test() {
  let conn = new_conn()
  assert status(get(conn, "/api/v1/tasks/missing-task/sections")) == 404
}
