/// C6 acceptance tests for the Tasks API.
///
/// Exercises the HTTP routes end-to-end against an in-memory libsql database
/// using `wisp/simulate` requests. Each test gets a fresh connection so the
/// assertions never depend on shared state.
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import sacrum_gleam/db/connection
import sacrum_gleam/db/migrations
import sacrum_gleam/domain/task
import sacrum_gleam/http/router
import sacrum_gleam/http/routes/tasks as tasks_routes
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

fn task_routes(conn: connection.DbConnection) -> List(router.Route) {
  tasks_routes.task_routes(conn)
}

fn get(conn: connection.DbConnection, path: String) -> wisp.Response {
  router.match_route(task_routes(conn), sim.request(http.Get, path))
}

fn post_json(
  conn: connection.DbConnection,
  path: String,
  body: json.Json,
) -> wisp.Response {
  router.match_route(
    task_routes(conn),
    sim.json_body(sim.request(http.Post, path), body),
  )
}

fn patch_json(
  conn: connection.DbConnection,
  path: String,
  body: json.Json,
) -> wisp.Response {
  router.match_route(
    task_routes(conn),
    sim.json_body(sim.request(http.Patch, path), body),
  )
}

fn delete(conn: connection.DbConnection, path: String) -> wisp.Response {
  router.match_route(task_routes(conn), sim.request(http.Delete, path))
}

fn status(resp: wisp.Response) -> Int {
  resp.status
}

fn body(resp: wisp.Response) -> String {
  sim.read_body(resp)
}

/// Decoder for a required string field of a JSON object.
fn string_field(key: String) -> decode.Decoder(String) {
  {
    use value <- decode.field(key, decode.string)
    decode.success(value)
  }
}

fn task_json(
  title: String,
  level: String,
  priority: String,
  parent_id: Option(String),
) -> json.Json {
  json.object([
    #("title", json.string(title)),
    #("level", json.string(level)),
    #("priority", json.string(priority)),
    #("parent_id", json.nullable(parent_id, json.string)),
  ])
}

/// Create a task via the API and return its ID.
fn create_task(
  conn: connection.DbConnection,
  title: String,
  level: String,
  priority: String,
  parent_id: Option(String),
) -> String {
  let resp =
    post_json(
      conn,
      "/api/v1/tasks",
      task_json(title, level, priority, parent_id),
    )
  let assert 201 = status(resp)
  let assert Ok(id) = json.parse(body(resp), string_field("id"))
  id
}

/// Number of archived rows in the whole tasks table.
fn archived_count(conn: connection.DbConnection) -> Int {
  let assert Ok(rows) =
    connection.query(conn, "SELECT COUNT(*) FROM tasks WHERE archived = 1", [])
  case rows {
    [[connection.IntVal(count)], ..] -> count
    _ -> 0
  }
}

// ─── Pure validation tests (no database required) ─────────────────────────

pub fn validate_create_input_accepts_valid_values_test() {
  let assert Ok(#(title, level, priority)) =
    tasks_routes.validate_create_input("Write tests", "ticket", "high")

  assert title == "Write tests"
  assert level == task.Ticket
  assert priority == task.High
}

pub fn validate_create_input_rejects_bad_level_and_priority_test() {
  let assert Error(level_msg) =
    tasks_routes.validate_create_input("T", "saga", "medium")
  assert string.contains(level_msg, "saga")

  let assert Error(priority_msg) =
    tasks_routes.validate_create_input("T", "ticket", "urgent")
  assert string.contains(priority_msg, "urgent")
}

pub fn dependency_self_check_rejects_self_dependencies_test() {
  assert tasks_routes.dependency_self_check("task-a", "task-a")
    == Some("Task cannot depend on itself")
  assert tasks_routes.dependency_self_check("task-a", "task-b") == None
}

pub fn short_ids_are_eight_digit_numbers_test() {
  let short_id = tasks_routes.generate_short_id()
  assert string.length(short_id) == 8
  // All characters are digits.
  let digits = "0123456789"
  assert list.all(string.to_graphemes(short_id), fn(char) {
    string.contains(digits, char)
  })
}

// ─── Acceptance tests (require a database connection) ─────────────────────

pub fn create_task_returns_201_with_short_id_test() {
  let conn = new_conn()

  let resp =
    post_json(
      conn,
      "/api/v1/tasks",
      json.object([
        #("title", json.string("Fix the flaky login test")),
        #("level", json.string("ticket")),
        #("priority", json.string("high")),
      ]),
    )

  assert status(resp) == 201
  let body = body(resp)
  let assert Ok(id) = json.parse(body, string_field("id"))
  let assert Ok(short_id) = json.parse(body, string_field("short_id"))
  let assert Ok(status_field) = json.parse(body, string_field("status"))
  let assert Ok(level) = json.parse(body, string_field("level"))

  assert string.length(short_id) == 8
  assert status_field == "todo"
  assert level == "ticket"
  // The created task is retrievable by ID.
  assert status(get(conn, "/api/v1/tasks/" <> id)) == 200
}

pub fn create_task_requires_title_level_and_priority_test() {
  let conn = new_conn()

  // Missing title → 400
  let resp =
    post_json(
      conn,
      "/api/v1/tasks",
      json.object([
        #("level", json.string("ticket")),
        #("priority", json.string("medium")),
      ]),
    )
  assert status(resp) == 400
  assert string.contains(body(resp), "Missing required field: title")

  // Missing level → 400
  let resp =
    post_json(
      conn,
      "/api/v1/tasks",
      json.object([
        #("title", json.string("T")),
        #("priority", json.string("medium")),
      ]),
    )
  assert status(resp) == 400

  // Invalid level value → 400
  let resp =
    post_json(
      conn,
      "/api/v1/tasks",
      json.object([
        #("title", json.string("T")),
        #("level", json.string("saga")),
        #("priority", json.string("medium")),
      ]),
    )
  assert status(resp) == 400
}

pub fn list_tasks_filters_by_level_and_status_test() {
  let conn = new_conn()
  let _epic = create_task(conn, "Epic one", "epic", "high", None)
  let ticket = create_task(conn, "Ticket one", "ticket", "medium", None)
  let _ignored = create_task(conn, "Ticket two", "ticket", "low", None)

  let resp = get(conn, "/api/v1/tasks?level=ticket")
  assert status(resp) == 200
  let assert Ok(ids) = json.parse(body(resp), decode.list(string_field("id")))
  assert list.contains(ids, ticket)

  let resp = get(conn, "/api/v1/tasks?level=epic")
  assert status(resp) == 200
  let assert Ok(ids) = json.parse(body(resp), decode.list(string_field("id")))
  assert list.contains(ids, ticket) == False
}

pub fn ready_list_excludes_tasks_with_incomplete_dependencies_test() {
  let conn = new_conn()
  let a = create_task(conn, "Foundation", "ticket", "high", None)
  let b = create_task(conn, "Depends on foundation", "ticket", "high", None)

  // B depends on A
  let resp =
    post_json(
      conn,
      "/api/v1/tasks/" <> b <> "/dependencies",
      json.object([#("depends_on", json.string(a))]),
    )
  assert status(resp) == 201

  // A is unblocked, B is blocked by A → only A is ready.
  let ready = get(conn, "/api/v1/tasks/ready")
  assert status(ready) == 200
  let assert Ok(ready_ids) =
    json.parse(body(ready), decode.list(string_field("id")))
  assert list.contains(ready_ids, a)
  assert list.contains(ready_ids, b) == False

  // The blockers endpoint reports A as blocking B.
  let blockers = get(conn, "/api/v1/tasks/" <> b <> "/blockers")
  assert status(blockers) == 200
  let assert Ok(blocker_ids) =
    json.parse(body(blockers), decode.list(string_field("id")))
  assert list.contains(blocker_ids, a)

  // Once A is done, B becomes ready.
  let resp =
    patch_json(
      conn,
      "/api/v1/tasks/" <> a,
      json.object([#("status", json.string("done"))]),
    )
  assert status(resp) == 200

  let ready = get(conn, "/api/v1/tasks/ready")
  let assert Ok(ready_ids) =
    json.parse(body(ready), decode.list(string_field("id")))
  assert list.contains(ready_ids, b)
}

pub fn dependency_cycles_are_rejected_test() {
  let conn = new_conn()
  let a = create_task(conn, "A", "ticket", "medium", None)
  let b = create_task(conn, "B", "ticket", "medium", None)

  // A depends on B — fine.
  let resp =
    post_json(
      conn,
      "/api/v1/tasks/" <> a <> "/dependencies",
      json.object([#("depends_on", json.string(b))]),
    )
  assert status(resp) == 201

  // B depends on A — would form a cycle → 400.
  let resp =
    post_json(
      conn,
      "/api/v1/tasks/" <> b <> "/dependencies",
      json.object([#("depends_on", json.string(a))]),
    )
  assert status(resp) == 400

  // Self-dependency → 400.
  let resp =
    post_json(
      conn,
      "/api/v1/tasks/" <> a <> "/dependencies",
      json.object([#("depends_on", json.string(a))]),
    )
  assert status(resp) == 400

  // Removing the dependency works.
  let resp = delete(conn, "/api/v1/tasks/" <> a <> "/dependencies/" <> b)
  assert status(resp) == 200
}

pub fn delete_without_cascade_archives_only_the_task_test() {
  let conn = new_conn()
  let parent = create_task(conn, "Parent", "epic", "high", None)
  let _child = create_task(conn, "Child", "ticket", "medium", Some(parent))

  let resp = delete(conn, "/api/v1/tasks/" <> parent)
  assert status(resp) == 200

  // Only the parent row is archived; the child keeps its archived = 0.
  assert archived_count(conn) == 1
}

pub fn delete_with_cascade_archives_all_descendants_test() {
  let conn = new_conn()
  let parent = create_task(conn, "Parent", "epic", "high", None)
  let child = create_task(conn, "Child", "ticket", "medium", Some(parent))
  let _grandchild = create_task(conn, "Grandchild", "task", "low", Some(child))

  let resp = delete(conn, "/api/v1/tasks/" <> parent <> "?cascade=true")
  assert status(resp) == 200

  // Parent + child + grandchild are all archived.
  assert archived_count(conn) == 3
}
