/// Projects API — workspace creation and lookup.
///
/// `POST /api/v1/projects` creates a project (slug must be unique), `GET
/// /api/v1/projects` lists every project and `GET /api/v1/projects/:id` fetches
/// one by id or slug. Tasks, sections and artifacts are scoped to the project
/// named by the `X-Crystalline-Project` request header (see
/// `sacrum_gleam/http/project_scope`), which accepts the same id-or-slug pair.
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/db/projects
import sacrum_gleam/domain/project.{type Project, Project}
import sacrum_gleam/http/helpers
import sacrum_gleam/http/router.{type Route, Route}
import wisp.{type Request, type Response}

/// Routes for creating, listing and fetching projects.
pub fn project_routes(conn: DbConnection) -> List(Route) {
  [
    Route(Post, "/api/v1/projects", fn(req, _) { create_project(req, conn) }),
    Route(Get, "/api/v1/projects", fn(_req, _) { list_projects(conn) }),
    Route(Get, "/api/v1/projects/:id", fn(_req, params) {
      get_project(params, conn)
    }),
  ]
}

// ─── POST /api/v1/projects ────────────────────────────────────────────────

fn create_project(req: Request, conn: DbConnection) -> Response {
  use body <- wisp.require_json(req)

  case decode_required_string(body, "slug") {
    Error(message) -> helpers.error_response(400, message)
    Ok(raw_slug) ->
      case project.validate_slug(raw_slug) {
        Error(message) -> helpers.error_response(400, message)
        Ok(slug) ->
          case decode_required_string(body, "name") {
            Error(message) -> helpers.error_response(400, message)
            Ok(name) ->
              case projects.slug_exists(conn, slug) {
                Error(_) ->
                  helpers.error_response(500, "Failed to check project slug")
                Ok(True) ->
                  helpers.error_response(
                    409,
                    "Project slug already exists: " <> slug,
                  )
                Ok(False) -> {
                  let now = milliseconds_now()
                  let new_project =
                    Project(
                      id: new_project_id(),
                      slug: slug,
                      name: name,
                      description: decode_optional_string(body, "description"),
                      created_at: now,
                      updated_at: now,
                    )
                  case projects.create_project(conn, new_project, now) {
                    Error(_) ->
                      helpers.error_response(500, "Failed to create project")
                    Ok(created) ->
                      helpers.json_response(
                        json.to_string(project_to_json(created)),
                        201,
                      )
                  }
                }
              }
          }
      }
  }
}

// ─── GET /api/v1/projects ─────────────────────────────────────────────────

fn list_projects(conn: DbConnection) -> Response {
  case projects.list_projects(conn) {
    Error(_) -> helpers.error_response(500, "Failed to list projects")
    Ok(found) ->
      helpers.json_response(
        json.to_string(json.array(found, project_to_json)),
        200,
      )
  }
}

// ─── GET /api/v1/projects/:id ─────────────────────────────────────────────

fn get_project(params: Dict(String, String), conn: DbConnection) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing project ID")
    Ok(key) ->
      case projects.find_project(conn, key) {
        Error(_) -> helpers.error_response(500, "Failed to get project")
        Ok(None) -> helpers.error_response(404, "Project not found")
        Ok(Some(found)) ->
          helpers.json_response(json.to_string(project_to_json(found)), 200)
      }
  }
}

// ─── JSON / decode helpers ────────────────────────────────────────────────

fn project_to_json(value: Project) -> json.Json {
  json.object([
    #("id", json.string(value.id)),
    #("slug", json.string(value.slug)),
    #("name", json.string(value.name)),
    #("description", json.string(value.description)),
    #("created_at", json.int(value.created_at)),
    #("updated_at", json.int(value.updated_at)),
  ])
}

fn required_field_decoder(
  key: String,
  inner: decode.Decoder(a),
) -> decode.Decoder(a) {
  use value <- decode.field(key, inner)
  decode.success(value)
}

fn optional_field_decoder(
  key: String,
  inner: decode.Decoder(a),
) -> decode.Decoder(Option(a)) {
  use value <- decode.optional_field(key, None, decode.optional(inner))
  decode.success(value)
}

fn decode_required_string(
  body: Dynamic,
  field: String,
) -> Result(String, String) {
  decode.run(body, required_field_decoder(field, decode.string))
  |> result.map_error(fn(_) { "Missing required field: " <> field })
}

fn decode_optional_string(body: Dynamic, field: String) -> String {
  case decode.run(body, optional_field_decoder(field, decode.string)) {
    Ok(Some(value)) -> value
    _ -> ""
  }
}

fn new_project_id() -> String {
  "proj-"
  <> int.to_string(int.random(999_999_999))
  <> "-"
  <> int.to_string(milliseconds_now())
}

fn milliseconds_now() -> Int {
  erlang_system_time() / 1_000_000
}

@external(erlang, "erlang", "system_time")
fn erlang_system_time() -> Int
