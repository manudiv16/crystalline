import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/db/executions
import sacrum_gleam/db/session_logs
import sacrum_gleam/db/tasks
import sacrum_gleam/domain/execution.{
  type ExecutionState, type StepExecution, StepInProgress,
  execution_status_to_string, step_status_to_string,
}
import sacrum_gleam/domain/flow.{type FlowInstance}
import sacrum_gleam/domain/session.{type SessionLog}
import sacrum_gleam/http/helpers
import sacrum_gleam/http/router.{type Route, Route}
import wisp.{type Request, type Response}

/// Executions and session log API (C8).
///
/// Endpoints:
/// - `GET    /api/v1/tasks/:id/executions`  — step execution history, newest first
/// - `GET    /api/v1/executions/:id`        — one step execution with metrics
/// - `GET    /api/v1/executions/active`     — execution states running or awaiting input
/// - `GET    /api/v1/executions/:id/logs`   — session log page (`?limit=`, `?before_sequence=`)
/// - `POST   /api/v1/executions/:id/logs`   — append `{"event_type", "payload"}`
///
/// Log paging is newest-first with a `before_sequence` cursor, and each page is
/// returned in chronological order (mirrors the harness replay contract). The
/// next page cursor is the sequence of the *first* element of the current page.
pub fn execution_routes(conn: DbConnection) -> List(Route) {
  [
    // Static segment must precede "/:id" so "active" is never captured as an id.
    Route(Get, "/api/v1/executions/active", fn(req, _params) {
      list_active_executions(req, conn)
    }),
    Route(Get, "/api/v1/tasks/:id/executions", fn(req, params) {
      list_task_executions(req, params, conn)
    }),
    Route(Get, "/api/v1/executions/:id", fn(req, params) {
      get_execution(req, params, conn)
    }),
    Route(Get, "/api/v1/executions/:id/logs", fn(req, params) {
      get_logs(req, params, conn)
    }),
    Route(Post, "/api/v1/executions/:id/logs", fn(req, params) {
      append_log(req, params, conn)
    }),
  ]
}

// ─── GET /api/v1/tasks/:id/executions ────────────────────────────────────

fn list_task_executions(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing task ID")
    Ok(task_id) -> {
      case tasks.get_task(conn, task_id) {
        Error(_) -> helpers.error_response(404, "Task not found")
        Ok(_) -> {
          case executions.get_steps_for_task(conn, task_id) {
            Error(_) -> helpers.error_response(500, "Failed to list executions")
            Ok(steps) -> {
              let body = json.array(steps, of: step_execution_to_json)
              helpers.json_response(json.to_string(body), 200)
            }
          }
        }
      }
    }
  }
}

// ─── GET /api/v1/executions/:id ─────────────────────────────────────────

fn get_execution(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing execution ID")
    Ok(id) -> {
      case executions.get_step_execution(conn, id) {
        Error(_) -> helpers.error_response(404, "Execution not found")
        Ok(step) -> {
          helpers.json_response(
            json.to_string(step_execution_to_json(step)),
            200,
          )
        }
      }
    }
  }
}

// ─── GET /api/v1/executions/active ──────────────────────────────────────

fn list_active_executions(_req: Request, conn: DbConnection) -> Response {
  case executions.get_active_executions(conn) {
    Error(_) -> helpers.error_response(500, "Failed to list active executions")
    Ok(states) -> {
      let body = json.array(states, of: execution_state_to_json)
      helpers.json_response(json.to_string(body), 200)
    }
  }
}

// ─── GET /api/v1/executions/:id/logs ────────────────────────────────────

fn get_logs(
  req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing execution ID")
    Ok(id) -> {
      let query = wisp.get_query(req)
      let limit = parse_limit(query)
      let before_sequence = parse_before_sequence(query)

      case session_logs.list_logs(conn, id, limit, before_sequence) {
        Error(_) -> helpers.error_response(500, "Failed to list logs")
        Ok(logs) -> {
          let body = json.array(logs, of: session_log_to_json)
          helpers.json_response(json.to_string(body), 200)
        }
      }
    }
  }
}

// ─── POST /api/v1/executions/:id/logs ───────────────────────────────────

fn append_log(
  req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing execution ID")
    Ok(execution_id) -> {
      use body <- wisp.require_json(req)

      case decode_append(body) {
        Error(_) ->
          helpers.error_response(
            400,
            "Invalid body: expected {\"event_type\": string, \"payload\": string}",
          )
        Ok(#(event_type, payload)) -> {
          case session_logs.is_valid_event_type(event_type) {
            False ->
              helpers.error_response(400, "Invalid event_type: " <> event_type)
            True -> {
              case executions.get_step_execution(conn, execution_id) {
                Error(_) -> helpers.error_response(404, "Execution not found")
                Ok(step) ->
                  case step.status {
                    StepInProgress -> {
                      let now = now_ms()

                      case
                        session_logs.append_log(
                          conn,
                          step.id,
                          step.task_id,
                          event_type,
                          payload,
                          now,
                        )
                      {
                        Error(_) ->
                          helpers.error_response(500, "Failed to append log")
                        Ok(log) ->
                          helpers.json_response(
                            json.to_string(session_log_to_json(log)),
                            201,
                          )
                      }
                    }
                    _ ->
                      helpers.error_response(
                        409,
                        "Execution is not in progress",
                      )
                  }
              }
            }
          }
        }
      }
    }
  }
}

fn decode_append(
  body: Dynamic,
) -> Result(#(String, String), List(decode.DecodeError)) {
  let decoder = {
    use event_type <- decode.field("event_type", decode.string)
    use payload <- decode.field("payload", decode.string)
    decode.success(#(event_type, payload))
  }
  decode.run(body, decoder)
}

// ─── Query helpers ──────────────────────────────────────────────────────

/// Default (and maximum) page size is `session_logs.default_limit`.
fn parse_limit(query: List(#(String, String))) -> Int {
  case list.key_find(query, "limit") {
    Ok(raw) ->
      case int.parse(raw) {
        Ok(n) -> clamp_limit(n)
        Error(_) -> session_logs.default_limit
      }
    Error(_) -> session_logs.default_limit
  }
}

fn clamp_limit(n: Int) -> Int {
  case n {
    _ if n < 1 -> 1
    _ if n > session_logs.default_limit -> session_logs.default_limit
    _ -> n
  }
}

fn parse_before_sequence(query: List(#(String, String))) -> Option(Int) {
  case list.key_find(query, "before_sequence") {
    Ok(raw) ->
      case int.parse(raw) {
        Ok(sequence) -> Some(sequence)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

// ─── JSON encoders ──────────────────────────────────────────────────────

fn step_execution_to_json(step: StepExecution) -> json.Json {
  json.object([
    #("id", json.string(step.id)),
    #("flow_instance_id", json.string(step.flow_instance_id)),
    #("execution_state_id", json.string(step.execution_state_id)),
    #("node_id", json.string(step.node_id)),
    #("task_id", json.string(step.task_id)),
    #("status", json.string(step_status_to_string(step.status))),
    #("prompt", json.nullable(step.prompt, of: json.string)),
    #("output", json.nullable(step.output, of: json.string)),
    #(
      "transition_result",
      json.nullable(step.transition_result, of: json.string),
    ),
    #("model", json.nullable(step.model, of: json.string)),
    #("input_tokens", json.int(step.input_tokens)),
    #("output_tokens", json.int(step.output_tokens)),
    #("cost", json.float(step.cost)),
    #("duration_ms", json.int(step.duration_ms)),
    #("session_id", json.nullable(step.session_id, of: json.string)),
    #("created_at", json.int(step.created_at)),
    #("completed_at", json.nullable(step.completed_at, of: json.int)),
  ])
}

fn execution_state_to_json(state: ExecutionState) -> json.Json {
  json.object([
    #("id", json.string(state.id)),
    #("task_id", json.string(state.task_id)),
    #("status", json.string(execution_status_to_string(state.status))),
    #("current_node_id", json.nullable(state.current_node_id, of: json.string)),
    #("started_at", json.nullable(state.started_at, of: json.int)),
    #("completed_at", json.nullable(state.completed_at, of: json.int)),
    #("flow_instance", flow_instance_to_json(state.flow_instance)),
  ])
}

fn flow_instance_to_json(instance: FlowInstance) -> json.Json {
  json.object([
    #("id", json.string(instance.id)),
    #("template_id", json.string(instance.template_id)),
    #("task_id", json.string(instance.task_id)),
    #("initial_node_id", json.string(instance.initial_node_id)),
  ])
}

fn session_log_to_json(log: SessionLog) -> json.Json {
  json.object([
    #("id", json.string(log.id)),
    #("step_execution_id", json.string(log.step_execution_id)),
    #("task_id", json.string(log.task_id)),
    #("event_type", json.string(log.event_type)),
    #("payload", json.string(log.payload)),
    #("sequence", json.int(log.sequence)),
    #("created_at", json.int(log.created_at)),
  ])
}

// ─── Clock ──────────────────────────────────────────────────────────────

/// Current wall clock in milliseconds (Unix epoch), matching the timestamps
/// used by the rest of the persistence layer.
fn now_ms() -> Int {
  erlang_system_time() / 1_000_000
}

@external(erlang, "erlang", "system_time")
fn erlang_system_time() -> Int
