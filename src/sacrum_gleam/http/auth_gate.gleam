//// Optional bearer-token authentication for Crystalline API routes.
////
//// The server resolves `CRYSTALLINE_API_TOKEN` once at startup and passes it
//// here as a parameter. An unset or empty token leaves the local-first API
//// unchanged. Bearer scheme names are case-insensitive per RFC 7235; the
//// supplied credential must exactly match the configured token.

import gleam/dict.{type Dict}
import gleam/http/request as http_request
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import sacrum_gleam/http/helpers
import sacrum_gleam/http/router.{type Route, Route}
import wisp.{type Request, type Response}

/// Apply the optional token gate to every `/api/v1` route.
///
/// Other routes, including `/health`, are unchanged. Since this transforms
/// matched route handlers rather than wrapping the router, unmatched requests
/// retain the router's existing JSON 404 response.
///
/// Only the `Authorization: Bearer` header is accepted here: `?token=` is
/// **not** honoured on these routes. The query parameter exists solely for the
/// Server-Sent Events stream, which is served outside this table because
/// `EventSource` cannot set request headers — see `stream_authorized`.
pub fn protect_routes(
  routes: List(Route),
  token: Option(String),
) -> List(Route) {
  case token {
    None -> routes
    Some(_) ->
      list.map(routes, fn(route) {
        case is_api_route(route.pattern) {
          True -> Route(..route, handler: gate(token, route.handler))
          False -> route
        }
      })
  }
}

/// Wrap a matched route handler with an optional bearer-token check.
///
/// When configured, requests without a matching `Authorization: Bearer`
/// credential receive a generic JSON 401 response before the handler runs.
pub fn gate(
  token: Option(String),
  handler: fn(Request, Dict(String, String)) -> Response,
) -> fn(Request, Dict(String, String)) -> Response {
  fn(request, params) {
    case token {
      None -> handler(request, params)
      Some(expected_token) ->
        case has_matching_bearer_token(request, expected_token) {
          True -> handler(request, params)
          False -> helpers.error_response(401, "Unauthorized")
        }
    }
  }
}

fn is_api_route(pattern: String) -> Bool {
  pattern == "/api/v1" || string.starts_with(pattern, "/api/v1/")
}

/// Authorization check for the Server-Sent Events stream route.
///
/// `EventSource` cannot attach request headers, so the stream — and only the
/// stream — additionally accepts the token as a `token=` query parameter. The
/// header path is identical to `protect_routes`, so an operator that only
/// configures reverse-proxy header auth keeps working. The tradeoff is
/// documented where the stream is served: query strings can end up in proxy
/// and browser histories, so a stream token is best treated as a read-only
/// credential for a local-first API.
///
/// The token value is never logged, stored or echoed by this module or by
/// `sacrum_gleam/http/execution_stream`.
pub fn stream_authorized(
  request: http_request.Request(body),
  token: Option(String),
) -> Bool {
  case token {
    None -> True
    Some(expected) ->
      has_matching_bearer_token(request, expected)
      || has_matching_query_token(request.query, expected)
  }
}

fn has_matching_query_token(query: Option(String), expected: String) -> Bool {
  query
  |> option.unwrap("")
  |> string.split("&")
  |> list.find_map(fn(pair) {
    case string.split_once(pair, "=") {
      Ok(#("token", value)) -> uri.percent_decode(value)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap("")
  == expected
}

fn has_matching_bearer_token(
  request: http_request.Request(body),
  expected_token: String,
) -> Bool {
  case http_request.get_header(request, "authorization") {
    Ok(value) ->
      case string.split(value, " ") {
        [scheme, supplied_token] ->
          string.lowercase(scheme) == "bearer"
          && supplied_token == expected_token
        _ -> False
      }
    Error(_) -> False
  }
}
