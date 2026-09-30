//// Issue 22 acceptance tests: projects, request scoping and per-project
//// short-id uniqueness.
////
//// Requests go through the production route table (`server.all_routes/2`) with
//// `wisp/simulate`, against a fresh in-memory libsql database with migrations
//// applied. Isolation assertions read the persisted rows, not only status
//// codes, so a regression that silently widens a scope fails here.

import gleam/dynamic/decode
import gleam/http
import gleam/http/request as http_request
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import sacrum_gleam/db/connection
import sacrum_gleam/db/migrations
import sacrum_gleam/db/tasks as db_tasks
import sacrum_gleam/domain/project
import sacrum_gleam/domain/task
import sacrum_gleam/http/auth_gate
import sacrum_gleam/http/router
import sacrum_gleam/http/server
import wisp
import wisp/simulate as sim

pub fn main() -> Nil {
  gleeunit.main()
}

/// Header used to scope a request to a project (id or slug).
const project_header = "x-crystalline-project"

// ─── Request helpers ──────────────────────────────────────────────────────

fn new_conn() -> connection.DbConnection {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok(_) = migrations.run_migrations(conn)
  conn
}

fn dispatch(
  conn: connection.DbConnection,
  request: wisp.Request,
) -> wisp.Response {
  router.match_route(server.all_routes(conn, "local"), request)
}

fn with_project(request: wisp.Request, project: String) -> wisp.Request {
  http_request.set_header(request, project_header, project)
}

fn get(
  conn: connection.DbConnection,
  path: String,
  project: Option(String),
) -> wisp.Response {
  let request = case project {
    None -> sim.request(http.Get, path)
    Some(value) -> sim.request(http.Get, path) |> with_project(value)
  }
  dispatch(conn, request)
}

fn post_json(
  conn: connection.DbConnection,
  path: String,
  body: json.Json,
  project: Option(String),
) -> wisp.Response {
  let request = case project {
    None -> sim.request(http.Post, path) |> sim.json_body(body)
    Some(value) ->
      sim.request(http.Post, path)
      |> sim.json_body(body)
      |> with_project(value)
  }
  dispatch(conn, request)
}

fn put_json(
  conn: connection.DbConnection,
  path: String,
  body: json.Json,
) -> wisp.Response {
  dispatch(conn, sim.request(http.Put, path) |> sim.json_body(body))
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

fn ids(response: wisp.Response) -> List(String) {
  let assert Ok(found) =
    json.parse(body(response), decode.list(string_field("id")))
  found
}

fn task_short_id(response: wisp.Response) -> String {
  let assert Ok(found) =
    json.parse(body(response), decode.list(string_field("short_id")))
  case found {
    [first, ..] -> first
    [] -> ""
  }
}

/// Create a project over HTTP and return `#(id, slug)`.
fn create_project(
  conn: connection.DbConnection,
  slug: String,
) -> #(String, String) {
  let response =
    post_json(
      conn,
      "/api/v1/projects",
      json.object([
        #("slug", json.string(slug)),
        #("name", json.string("Project " <> slug)),
      ]),
      None,
    )
  let assert 201 = status(response)
  let assert Ok(id) = json.parse(body(response), string_field("id"))
  let assert Ok(created_slug) = json.parse(body(response), string_field("slug"))
  #(id, created_slug)
}

fn create_task(
  conn: connection.DbConnection,
  title: String,
  project: Option(String),
) -> String {
  let response =
    post_json(
      conn,
      "/api/v1/tasks",
      json.object([
        #("title", json.string(title)),
        #("level", json.string("ticket")),
        #("priority", json.string("medium")),
      ]),
      project,
    )
  let assert 201 = status(response)
  let assert Ok(id) = json.parse(body(response), string_field("id"))
  id
}

/// Seed a task with a chosen short id directly through the persistence layer,
/// which is the only way to force two projects onto the same user-visible id.
fn seed_task(
  conn: connection.DbConnection,
  id: String,
  project_id: String,
  short_id: String,
) -> Nil {
  let seed =
    task.Task(
      ..task.new_task("Seeded " <> id, task.Ticket, task.Medium),
      id: id,
      short_id: short_id,
      project_id: project_id,
    )
  let assert Ok(_) = db_tasks.create_task(conn, seed, 1)
  Nil
}

// ─── Projects API ─────────────────────────────────────────────────────────

pub fn create_project_persists_and_is_listed_test() {
  let conn = new_conn()
  let #(id, slug) = create_project(conn, "acme")

  // Persisted row, not just the response body.
  let assert Ok(row) =
    connection.query_one(conn, "SELECT slug, name FROM projects WHERE id = ?", [
      connection.TextVal(id),
    ])
  row
  |> should.equal([
    connection.TextVal("acme"),
    connection.TextVal("Project acme"),
  ])

  let fetched = get(conn, "/api/v1/projects/" <> id, None)
  assert status(fetched) == 200
  let assert Ok(fetched_slug) = json.parse(body(fetched), string_field("slug"))
  assert fetched_slug == slug

  // The id-or-slug handle works for by-id fetches too.
  let by_slug = get(conn, "/api/v1/projects/acme", None)
  assert status(by_slug) == 200
  let assert Ok(by_slug_id) = json.parse(body(by_slug), string_field("id"))
  assert by_slug_id == id

  let listed = get(conn, "/api/v1/projects", None)
  assert status(listed) == 200
  assert list.contains(ids(listed), id)

  let missing = get(conn, "/api/v1/projects/does-not-exist", None)
  assert status(missing) == 404
}

pub fn create_project_rejects_invalid_and_duplicate_slugs_test() {
  let conn = new_conn()
  let _ = create_project(conn, "acme")

  let duplicate =
    post_json(
      conn,
      "/api/v1/projects",
      json.object([
        #("slug", json.string("acme")),
        #("name", json.string("Duplicate")),
      ]),
      None,
    )
  assert status(duplicate) == 409

  let invalid =
    post_json(
      conn,
      "/api/v1/projects",
      json.object([
        #("slug", json.string("Not A Slug!")),
        #("name", json.string("Invalid")),
      ]),
      None,
    )
  assert status(invalid) == 400
  assert string.contains(body(invalid), "slug")

  let missing_name =
    post_json(
      conn,
      "/api/v1/projects",
      json.object([#("slug", json.string("no-name"))]),
      None,
    )
  assert status(missing_name) == 400
  assert string.contains(body(missing_name), "name")

  // No partial row for the rejected creations.
  let assert Ok([connection.IntVal(count)]) =
    connection.query_one(conn, "SELECT COUNT(*) FROM projects", [])
  assert count == 2
}

// ─── Short-id uniqueness per project ──────────────────────────────────────

pub fn two_projects_share_the_same_short_id_test() {
  let conn = new_conn()
  let #(first_id, first_slug) = create_project(conn, "first")
  let #(second_id, second_slug) = create_project(conn, "second")

  seed_task(conn, "task-first", first_id, "00000001")
  seed_task(conn, "task-second", second_id, "00000001")

  // Both rows exist, each with the same user-visible id and a project-scoped
  // stored value.
  let assert Ok([connection.IntVal(scoped)]) =
    connection.query_one(
      conn,
      "SELECT COUNT(*) FROM tasks WHERE short_id IN "
        <> "('"
        <> first_id
        <> ":00000001', '"
        <> second_id
        <> ":00000001')",
      [],
    )
  assert scoped == 2

  let first_list = get(conn, "/api/v1/tasks", Some(first_slug))
  assert status(first_list) == 200
  assert ids(first_list) == ["task-first"]
  assert task_short_id(first_list) == "00000001"

  let second_list = get(conn, "/api/v1/tasks", Some(second_slug))
  assert status(second_list) == 200
  assert ids(second_list) == ["task-second"]
  assert task_short_id(second_list) == "00000001"

  // The header accepts an id as well as a slug.
  let by_id = get(conn, "/api/v1/tasks", Some(first_id))
  assert ids(by_id) == ["task-first"]
}

// ─── List and ready-queue isolation ───────────────────────────────────────

pub fn task_lists_are_isolated_in_both_directions_test() {
  let conn = new_conn()
  let #(_, first_slug) = create_project(conn, "first")
  let #(_, second_slug) = create_project(conn, "second")

  let first_task = create_task(conn, "First project task", Some(first_slug))
  let second_task = create_task(conn, "Second project task", Some(second_slug))

  let first_list = ids(get(conn, "/api/v1/tasks", Some(first_slug)))
  assert list.contains(first_list, first_task)
  assert list.contains(first_list, second_task) == False

  let second_list = ids(get(conn, "/api/v1/tasks", Some(second_slug)))
  assert list.contains(second_list, second_task)
  assert list.contains(second_list, first_task) == False
}

pub fn ready_queue_is_isolated_per_project_test() {
  let conn = new_conn()
  let #(_, first_slug) = create_project(conn, "first")
  let #(_, second_slug) = create_project(conn, "second")

  let first_task = create_task(conn, "Ready first", Some(first_slug))
  let second_task = create_task(conn, "Ready second", Some(second_slug))

  let first_ready = ids(get(conn, "/api/v1/tasks/ready", Some(first_slug)))
  assert list.contains(first_ready, first_task)
  assert list.contains(first_ready, second_task) == False

  let second_ready = ids(get(conn, "/api/v1/tasks/ready", Some(second_slug)))
  assert list.contains(second_ready, second_task)
  assert list.contains(second_ready, first_task) == False
}

// ─── Nested resources ─────────────────────────────────────────────────────

pub fn sections_and_artifacts_of_another_project_are_unreachable_test() {
  let conn = new_conn()
  let #(_, first_slug) = create_project(conn, "first")
  let #(_, second_slug) = create_project(conn, "second")
  let task_id = create_task(conn, "Owner", Some(first_slug))

  // Section and artifact creation stay global (documented): they address an
  // explicit task id.
  let section =
    post_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/sections",
      json.object([
        #("section_type", json.string("goal")),
        #("content", json.string("scoped content")),
      ]),
      None,
    )
  assert status(section) == 201
  let artifact =
    put_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/artifacts/plan",
      json.object([#("content", json.object([#("step", json.int(1))]))]),
    )
  assert status(artifact) == 200

  // Own project: reachable.
  let own_sections =
    get(conn, "/api/v1/tasks/" <> task_id <> "/sections", Some(first_slug))
  assert status(own_sections) == 200
  assert string.contains(body(own_sections), "scoped content")
  let own_artifacts =
    get(conn, "/api/v1/tasks/" <> task_id <> "/artifacts", Some(first_slug))
  assert status(own_artifacts) == 200
  assert string.contains(body(own_artifacts), "plan")

  // Other project: the task must not be reachable through the scoped list,
  // even though the caller holds its id.
  let foreign_sections =
    get(conn, "/api/v1/tasks/" <> task_id <> "/sections", Some(second_slug))
  assert status(foreign_sections) == 404
  assert string.contains(body(foreign_sections), "Task not found")
  let foreign_artifacts =
    get(conn, "/api/v1/tasks/" <> task_id <> "/artifacts", Some(second_slug))
  assert status(foreign_artifacts) == 404
  assert string.contains(body(foreign_artifacts), "Task not found")
}

// ─── Default fallback and unknown projects ────────────────────────────────

pub fn missing_header_falls_back_to_the_default_project_test() {
  let conn = new_conn()

  // The sentinel project exists from migration 0003 and is addressable.
  let default_project = get(conn, "/api/v1/projects/default", None)
  assert status(default_project) == 200
  let assert Ok(slug) = json.parse(body(default_project), string_field("slug"))
  assert slug == project.default_project_slug

  let task_id = create_task(conn, "Unscoped task", None)
  let listed = ids(get(conn, "/api/v1/tasks", None))
  assert list.contains(listed, task_id)

  let response = get(conn, "/api/v1/tasks", None)
  let assert Ok([connection.TextVal(owner)]) =
    connection.query_one(conn, "SELECT project_id FROM tasks WHERE id = ?", [
      connection.TextVal(task_id),
    ])
  assert owner == project.default_project_id
  assert string.contains(body(response), project.default_project_id)

  // The default project is itself a project, so a header naming it is valid.
  assert status(get(conn, "/api/v1/tasks", Some(project.default_project_slug)))
    == 200
}

pub fn unknown_project_header_is_rejected_without_falling_back_test() {
  let conn = new_conn()
  let _ = create_task(conn, "Default task", None)

  let list_response = get(conn, "/api/v1/tasks", Some("ghost"))
  assert status(list_response) == 404
  assert string.contains(body(list_response), "ghost")

  let create_response =
    post_json(
      conn,
      "/api/v1/tasks",
      json.object([
        #("title", json.string("Should not exist")),
        #("level", json.string("ticket")),
        #("priority", json.string("medium")),
      ]),
      Some("ghost"),
    )
  assert status(create_response) == 404

  // Nothing was written into the default project on the rejected request.
  let assert Ok([connection.IntVal(count)]) =
    connection.query_one(
      conn,
      "SELECT COUNT(*) FROM tasks WHERE title = 'Should not exist'",
      [],
    )
  assert count == 0

  assert status(get(conn, "/api/v1/tasks/ready", Some("ghost"))) == 404
}

// ─── Interaction with the bearer-token gate ───────────────────────────────

pub fn project_header_does_not_bypass_the_token_gate_test() {
  let conn = new_conn()
  let token = Some("secret-token")

  let gated = fn(request: wisp.Request) -> wisp.Response {
    let routes =
      server.all_routes(conn, "local")
      |> auth_gate.protect_routes(token)
    router.match_route(routes, request)
  }

  // Header present, token absent → still 401.
  let no_token =
    gated(sim.request(http.Get, "/api/v1/tasks") |> with_project("default"))
  assert status(no_token) == 401

  // Token valid, project unknown → 4xx, not a silent fallback.
  let bad_project =
    gated(
      sim.request(http.Get, "/api/v1/tasks")
      |> with_project("ghost")
      |> http_request.set_header("authorization", "Bearer secret-token"),
    )
  assert status(bad_project) == 404

  // Token valid, project valid → handler runs.
  let ok =
    gated(
      sim.request(http.Get, "/api/v1/tasks")
      |> with_project("default")
      |> http_request.set_header("authorization", "Bearer secret-token"),
    )
  assert status(ok) == 200

  // A valid token without a project header still reaches the default project.
  let default_scope =
    gated(
      sim.request(http.Get, "/api/v1/tasks")
      |> http_request.set_header("authorization", "Bearer secret-token"),
    )
  assert status(default_scope) == 200
}
