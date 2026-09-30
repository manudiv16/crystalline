//// Acceptance tests for the optional API bearer-token gate.
////
//// Requests use the production route table with an explicit gate token and
//// `wisp/simulate`; each test exercises persisted behavior through a fresh
//// in-memory database. The Bearer scheme is accepted case-insensitively per
//// RFC 7235.

import gleam/http
import gleam/http/request as http_request
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import sacrum_gleam/db/connection
import sacrum_gleam/db/migrations
import sacrum_gleam/http/auth_gate
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
  token: Option(String),
  request: wisp.Request,
) -> wisp.Response {
  let routes =
    server.all_routes(conn, "local")
    |> auth_gate.protect_routes(token)
  router.match_route(routes, request)
}

fn with_authorization(
  request: wisp.Request,
  authorization: Option(String),
) -> wisp.Request {
  case authorization {
    None -> request
    Some(value) -> http_request.set_header(request, "authorization", value)
  }
}

fn get(
  conn: connection.DbConnection,
  token: Option(String),
  path: String,
  authorization: Option(String),
) -> wisp.Response {
  let request =
    sim.request(http.Get, path)
    |> with_authorization(authorization)
  dispatch(conn, token, request)
}

fn post_task(
  conn: connection.DbConnection,
  token: Option(String),
  authorization: Option(String),
) -> wisp.Response {
  let body =
    json.object([
      #("title", json.string("gate test task")),
      #("level", json.string("ticket")),
      #("priority", json.string("medium")),
    ])
  let request =
    sim.request(http.Post, "/api/v1/tasks")
    |> sim.json_body(body)
    |> with_authorization(authorization)
  dispatch(conn, token, request)
}

fn status(response: wisp.Response) -> Int {
  response.status
}

fn body(response: wisp.Response) -> String {
  sim.read_body(response)
}

fn task_count(conn: connection.DbConnection) -> Int {
  let assert Ok(rows) = connection.query(conn, "SELECT COUNT(*) FROM tasks", [])
  case rows {
    [[connection.IntVal(count), ..], ..] -> count
    _ -> panic as "Could not count persisted tasks"
  }
}

pub fn missing_authorization_rejects_without_creating_task_test() {
  let conn = new_conn()
  let token = "test-secret-token"

  let response = post_task(conn, Some(token), None)

  assert status(response) == 401
  assert string.contains(body(response), "\"error\":\"Unauthorized\"")
  assert string.contains(body(response), token) == False
  assert task_count(conn) == 0
}

pub fn wrong_token_and_basic_scheme_are_rejected_test() {
  let conn = new_conn()
  let token = "test-secret-token"

  let wrong_token =
    get(conn, Some(token), "/api/v1/tasks", Some("Bearer wrong-token"))
  assert status(wrong_token) == 401

  let wrong_scheme =
    get(conn, Some(token), "/api/v1/tasks", Some("Basic dGVzdA=="))
  assert status(wrong_scheme) == 401
  assert task_count(conn) == 0
}

pub fn bearer_scheme_is_case_insensitive_test() {
  let conn = new_conn()

  let response =
    get(
      conn,
      Some("test-secret-token"),
      "/api/v1/tasks",
      Some("bearer test-secret-token"),
    )

  assert status(response) == 200
}

pub fn matching_token_allows_persisted_api_mutation_test() {
  let conn = new_conn()
  let token = "test-secret-token"

  let response = post_task(conn, Some(token), Some("Bearer " <> token))

  assert status(response) == 201
  assert task_count(conn) == 1
  let list_response =
    get(conn, Some(token), "/api/v1/tasks", Some("Bearer " <> token))
  assert status(list_response) == 200
  assert string.contains(body(list_response), "gate test task")
}

pub fn health_and_unmatched_paths_keep_public_router_behavior_test() {
  let conn = new_conn()
  let token = Some("test-secret-token")

  let health = get(conn, token, "/health", None)
  assert status(health) == 200

  let unmatched = get(conn, token, "/api/v1/not-a-route", None)
  assert status(unmatched) == 404
  assert string.contains(body(unmatched), "\"error\":\"Not found\"")
}

pub fn no_configured_token_keeps_api_unauthenticated_test() {
  let conn = new_conn()

  let created = post_task(conn, None, None)
  assert status(created) == 201
  assert task_count(conn) == 1

  let listed = get(conn, None, "/api/v1/tasks", None)
  assert status(listed) == 200
  assert string.contains(body(listed), "gate test task")
}
