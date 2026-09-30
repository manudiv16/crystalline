/// HTTP server bootstrap for Crystalline.
///
/// Runs a Wisp request handler on top of the Mist web server. After the
/// server starts, the listening address is logged by Mist (e.g.
/// `Listening on http://localhost:4920`).
///
/// The server connects to libsql at startup, applies pending migrations and
/// wires task, execution, flow-template and flow execution APIs in addition to
/// the health endpoint.
import envoy
import gleam/int
import gleam/list
import mist
import sacrum_gleam/config
import sacrum_gleam/db/connection
import sacrum_gleam/db/migrations
import sacrum_gleam/http/router
import sacrum_gleam/http/routes/artifacts
import sacrum_gleam/http/routes/executions
import sacrum_gleam/http/routes/flow_templates
import sacrum_gleam/http/routes/flows
import sacrum_gleam/http/routes/tasks
import wisp
import wisp/wisp_mist

/// Start the HTTP server on the given port. Returns once the listener is
/// bound; the caller is expected to keep the process alive (see
/// `crystalline.main`), otherwise the server supervision tree is torn down.
pub fn start(port: Int) -> Nil {
  let #(conn, db_mode) = connect_database()
  let routes = all_routes(conn, db_mode)

  let handler = fn(request: wisp.Request) -> wisp.Response {
    router.match_route(routes, request)
  }

  case
    handler
    |> wisp_mist.handler(secret_key_base())
    |> mist.new
    |> mist.port(port)
    |> mist.start
  {
    Ok(_) -> Nil
    // Typical causes: the port is already bound or the interface is invalid.
    Error(_) ->
      panic as {
        "Failed to start the HTTP server on port " <> int.to_string(port)
      }
  }
}

/// Complete production route table, shared by the live server and e2e tests.
pub fn all_routes(
  conn: connection.DbConnection,
  db_mode: String,
) -> List(router.Route) {
  router.health_routes(db_mode)
  |> list.append(tasks.task_routes(conn))
  |> list.append(executions.execution_routes(conn))
  |> list.append(flow_templates.flow_template_routes(conn))
  |> list.append(flows.flow_routes(conn))
  |> list.append(artifacts.artifact_routes(conn))
}

/// Resolve the database configuration from the environment, connect, and
/// apply any pending schema migrations.
fn connect_database() -> #(connection.DbConnection, String) {
  case config.resolve_db_config() {
    Error(error) ->
      panic as {
        "Invalid database configuration: "
        <> config.config_error_to_string(error)
      }
    Ok(cfg) ->
      case connection.connect(cfg.url, cfg.auth_token) {
        Error(error) ->
          panic as {
            "Failed to connect to database: "
            <> connection.error_to_string(error)
          }
        Ok(conn) ->
          case migrations.run_migrations(conn) {
            Ok(_) -> #(conn, config.mode_to_string(cfg.mode))
            Error(error) ->
              panic as {
                "Migration failed: " <> migrations_error_to_string(error)
              }
          }
      }
  }
}

fn migrations_error_to_string(error: migrations.MigrationError) -> String {
  case error {
    migrations.DbError(db_error) -> connection.error_to_string(db_error)
    migrations.AlreadyApplied(version) ->
      "migration already applied: " <> int.to_string(version)
    migrations.FailedAt(version, message) ->
      "migration failed at version "
      <> int.to_string(version)
      <> ": "
      <> message
  }
}

/// Secret key base used by Wisp for signing/encryption. Override in
/// production via `CRYSTALLINE_SECRET_KEY_BASE`; defaults to a dev-only
/// value so the bootstrap runs out of the box.
fn secret_key_base() -> String {
  case envoy.get("CRYSTALLINE_SECRET_KEY_BASE") {
    Ok(key) -> key
    Error(_) -> "crystalline-dev-secret-key-base-change-in-production"
  }
}
