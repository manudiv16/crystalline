/// HTTP routes for the prebuilt flow template registry (issue C11).
///
/// - `POST /api/v1/flow-templates/seed` — idempotently seed the 6 prebuilt
///   templates into the database; responds `{ "inserted": N, "total": 6 }`.
/// - `GET  /api/v1/flow-templates` — list all seeded templates (with slug).
/// - `GET  /api/v1/flow-templates/:slug` — fetch a single template detail.
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/http.{Get, Post}
import gleam/list
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/db/flows as db_flows
import sacrum_gleam/flow/templates
import sacrum_gleam/http/helpers
import sacrum_gleam/http/router.{type Route, Route}
import wisp.{type Request, type Response}

// ─── Route Definitions ────────────────────────────────────────────────────

pub fn flow_template_routes(conn: DbConnection) -> List(Route) {
  [
    Route(Post, "/api/v1/flow-templates/seed", fn(req, _) {
      seed_templates(req, conn)
    }),
    Route(Get, "/api/v1/flow-templates", fn(req, _) {
      list_templates(req, conn)
    }),
    Route(Get, "/api/v1/flow-templates/:slug", fn(req, params) {
      get_template(req, params, conn)
    }),
  ]
}

// ─── POST /api/v1/flow-templates/seed ─────────────────────────────────────

/// Seed all 6 prebuilt templates into the database. Idempotent: templates
/// that already exist are skipped, so a second call inserts nothing.
fn seed_templates(_req: Request, conn: DbConnection) -> Response {
  let total = list.length(templates.all_template_specs())

  case templates.seed_to_db(conn, now_timestamp()) {
    Ok(inserted) ->
      helpers.json_response(templates.seed_result_to_json(inserted, total), 200)
    Error(_) -> helpers.error_response(500, "Failed to seed flow templates")
  }
}

// ─── GET /api/v1/flow-templates ───────────────────────────────────────────

/// List all seeded flow templates (id/slug, name, description and shape).
fn list_templates(_req: Request, conn: DbConnection) -> Response {
  case db_flows.list_flow_templates(conn) {
    Ok(templates_list) ->
      helpers.json_response(
        templates.templates_list_to_json(templates_list),
        200,
      )
    Error(_) -> helpers.error_response(500, "Failed to list flow templates")
  }
}

// ─── GET /api/v1/flow-templates/:slug ─────────────────────────────────────

/// Fetch a single template by its slug/id.
fn get_template(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "slug") {
    Error(_) -> helpers.error_response(400, "Missing template slug")
    Ok(slug) -> {
      case db_flows.get_flow_template(conn, slug) {
        Ok(template) ->
          helpers.json_response(templates.template_to_json(template), 200)
        Error(_) ->
          helpers.error_response(404, "Flow template not found: " <> slug)
      }
    }
  }
}

// ─── Timestamp ───────────────────────────────────────────────────────────

/// Milliseconds since the Unix epoch via `erlang:system_time/1`.
fn now_timestamp() -> Int {
  system_time(atom.create("millisecond"))
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: atom.Atom) -> Int
