import gleam/dict.{type Dict}
import gleam/http.{type Method, Get}
import gleam/json
import gleam/string
import sacrum_gleam/http/helpers
import wisp.{type Request, type Response}

pub type Route {
  Route(
    method: Method,
    pattern: String,
    handler: fn(Request, Dict(String, String)) -> Response,
  )
}

// Match request path against pattern, extracting parameters
// Pattern format: "/api/v1/tasks/:id" matches "/api/v1/tasks/123" with id="123"
pub fn match_route(routes: List(Route), request: Request) -> Response {
  let path = request.path
  let method = request.method

  case find_matching_route(routes, method, path) {
    Ok(#(route, params)) -> route.handler(request, params)
    // Unmatched requests return a JSON 404 so clients always get a
    // machine-readable error envelope.
    Error(_) -> helpers.error_response(404, "Not found")
  }
}

fn find_matching_route(
  routes: List(Route),
  method: Method,
  path: String,
) -> Result(#(Route, Dict(String, String)), Nil) {
  case routes {
    [] -> Error(Nil)
    [route, ..rest] -> {
      case route.method == method {
        True -> {
          case extract_params(route.pattern, path) {
            Ok(params) -> Ok(#(route, params))
            Error(_) -> find_matching_route(rest, method, path)
          }
        }
        False -> find_matching_route(rest, method, path)
      }
    }
  }
}

fn extract_params(
  pattern: String,
  path: String,
) -> Result(Dict(String, String), Nil) {
  let pattern_segments = string.split(pattern, "/")
  let path_segments = string.split(path, "/")

  extract_params_helper(pattern_segments, path_segments, dict.new())
}

fn extract_params_helper(
  pattern: List(String),
  path: List(String),
  params: Dict(String, String),
) -> Result(Dict(String, String), Nil) {
  case pattern, path {
    [], [] -> Ok(params)
    [":" <> param_name, ..pattern_rest], [value, ..path_rest] -> {
      let new_params = dict.insert(params, param_name, value)
      extract_params_helper(pattern_rest, path_rest, new_params)
    }
    [p, ..pattern_rest], [s, ..path_rest] if p == s ->
      extract_params_helper(pattern_rest, path_rest, params)
    _, _ -> Error(Nil)
  }
}

/// Application version reported by the health endpoint. Keep in sync with
/// the `version` in `gleam.toml`.
pub const version = "1.0.0"

/// Routes that are always available.
///
/// `db_mode` is the resolved database mode (`local` or `remote`, see
/// `sacrum_gleam/config`). Only the mode is reported — never the auth token.
pub fn health_routes(db_mode: String) -> List(Route) {
  [
    Route(Get, "/health", fn(_request, _params) { health_response(db_mode) }),
  ]
}

fn health_response(db_mode: String) -> Response {
  let body =
    json.object([
      #("status", json.string("ok")),
      #("version", json.string(version)),
      #("db_mode", json.string(db_mode)),
    ])
  helpers.json_response(json.to_string(body), 200)
}
