//// Request-level project scoping.
////
//// Scoped endpoints resolve their target project from the
//// `X-Crystalline-Project` header, which accepts either a project id or its
//// slug. An absent (or empty) header falls back to the sentinel `default`
//// project so every existing local-first client keeps working; a header that
//// names no project is rejected with a 4xx instead of silently falling back.
////
//// Resolution runs inside the route handler, i.e. after
//// `auth_gate.protect_routes`, so a missing or invalid project header can
//// never bypass the bearer-token gate.

import gleam/http/request as http_request
import gleam/option.{None, Some}
import gleam/string
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/db/projects
import sacrum_gleam/domain/project
import sacrum_gleam/http/helpers
import wisp.{type Request, type Response}

/// Header carrying the project id or slug for scoped requests.
pub const project_header: String = "x-crystalline-project"

/// Resolve the project id a request is scoped to.
///
/// Returns the id on success, or the 4xx response to send back when the header
/// names an unknown project.
pub fn resolve(req: Request, conn: DbConnection) -> Result(String, Response) {
  let key = case http_request.get_header(req, project_header) {
    Ok(value) -> string.trim(value)
    Error(_) -> ""
  }

  case key {
    "" -> Ok(project.default_project_id)
    key ->
      case projects.find_project(conn, key) {
        Error(_) ->
          Error(helpers.error_response(500, "Failed to resolve project"))
        Ok(Some(found)) -> Ok(found.id)
        Ok(None) ->
          Error(helpers.error_response(404, "Unknown project: " <> key))
      }
  }
}
