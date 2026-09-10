import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Patch, Post}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/db/tasks
import sacrum_gleam/domain/task
import sacrum_gleam/http/helpers
import sacrum_gleam/http/router.{type Route, Route}
import wisp.{type Request, type Response}

// ─── Route Definitions ────────────────────────────────────────────────────

pub fn task_routes(conn: DbConnection) -> List(Route) {
  [
    Route(Post, "/api/v1/tasks", fn(req, _) { create_task(req, conn) }),
    Route(Get, "/api/v1/tasks/ready", fn(req, _) { list_ready_tasks(req, conn) }),
    Route(Get, "/api/v1/tasks", fn(req, _) { list_tasks(req, conn) }),
    Route(Get, "/api/v1/tasks/:id", fn(req, params) {
      get_task(req, params, conn)
    }),
    Route(Patch, "/api/v1/tasks/:id", fn(req, params) {
      update_task(req, params, conn)
    }),
    Route(Delete, "/api/v1/tasks/:id", fn(req, params) {
      delete_task(req, params, conn)
    }),
    Route(Post, "/api/v1/tasks/:id/dependencies", fn(req, params) {
      add_dependency(req, params, conn)
    }),
    Route(Delete, "/api/v1/tasks/:id/dependencies/:depends_on", fn(req, params) {
      remove_dependency(req, params, conn)
    }),
    Route(Get, "/api/v1/tasks/:id/blockers", fn(req, params) {
      get_blockers(req, params, conn)
    }),
  ]
}

// ─── POST /api/v1/tasks ───────────────────────────────────────────────────

fn create_task(req: Request, conn: DbConnection) -> Response {
  use body <- wisp.require_json(req)

  // Decode required fields
  let title_result = decode_string_field(body, "title")
  let level_result = decode_string_field(body, "level")
  let priority_result = decode_string_field(body, "priority")

  case title_result, level_result, priority_result {
    Error(msg), _, _ -> helpers.error_response(400, msg)
    _, Error(msg), _ -> helpers.error_response(400, msg)
    _, _, Error(msg) -> helpers.error_response(400, msg)
    Ok(title), Ok(level_str), Ok(priority_str) -> {
      case validate_create_input(title, level_str, priority_str) {
        Error(msg) -> helpers.error_response(400, msg)
        Ok(#(title, level, priority)) -> {
          // Decode optional fields
          let description = decode_optional_string(body, "description")
          let tags = decode_optional_string_array(body, "tags")
          let parent_id = decode_optional_string_option(body, "parent_id")

          // Generate IDs
          let id = generate_uuid()
          let short_id = generate_unique_short_id(conn)
          let now = get_current_timestamp()

          // Create task
          let new_task =
            task.Task(
              id: id,
              short_id: short_id,
              title: title,
              description: description,
              level: level,
              priority: priority,
              status: task.Todo,
              tags: tags,
              parent_id: parent_id,
              flow_template_id: None,
              flow_instance_id: None,
              current_node_id: None,
              worktree: None,
              archived: False,
              created_at: now,
              updated_at: now,
            )

          case tasks.create_task(conn, new_task, now) {
            Error(_) -> helpers.error_response(500, "Failed to create task")
            Ok(_) -> {
              let task_json = task_to_json(new_task)
              helpers.json_response(json.to_string(task_json), 201)
            }
          }
        }
      }
    }
  }
}

// ─── GET /api/v1/tasks ────────────────────────────────────────────────────

fn list_tasks(req: Request, conn: DbConnection) -> Response {
  let query = wisp.get_query(req)

  // Parse filters from query params
  let level = case list.key_find(query, "level") {
    Ok(level_str) ->
      case task.level_from_string(level_str) {
        Ok(l) -> Some(l)
        Error(_) -> None
      }
    Error(_) -> None
  }

  let status = case list.key_find(query, "status") {
    Ok(status_str) ->
      case task.status_from_string(status_str) {
        Ok(s) -> Some(s)
        Error(_) -> None
      }
    Error(_) -> None
  }

  let parent_id = case list.key_find(query, "parent_id") {
    Ok(pid) -> Some(pid)
    Error(_) -> None
  }

  let limit = case list.key_find(query, "limit") {
    Ok(limit_str) ->
      case int.parse(limit_str) {
        Ok(l) -> l
        Error(_) -> 100
      }
    Error(_) -> 100
  }

  let offset = case list.key_find(query, "offset") {
    Ok(offset_str) ->
      case int.parse(offset_str) {
        Ok(o) -> o
        Error(_) -> 0
      }
    Error(_) -> 0
  }

  let filter =
    tasks.TaskFilter(
      level: level,
      status: status,
      parent_id: parent_id,
      archived: False,
      limit: limit,
      offset: offset,
    )

  case tasks.list_tasks(conn, filter) {
    Error(_) -> helpers.error_response(500, "Failed to list tasks")
    Ok(ts) -> {
      let tasks_json = json.array(ts, task_to_json)
      helpers.json_response(json.to_string(tasks_json), 200)
    }
  }
}

// ─── GET /api/v1/tasks/:id ────────────────────────────────────────────────

fn get_task(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing task ID")
    Ok(id) -> {
      case tasks.get_task(conn, id) {
        Error(_) -> helpers.error_response(404, "Task not found")
        Ok(t) -> helpers.json_response(json.to_string(task_to_json(t)), 200)
      }
    }
  }
}

// ─── PATCH /api/v1/tasks/:id ──────────────────────────────────────────────

fn update_task(
  req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing task ID")
    Ok(id) -> {
      use body <- wisp.require_json(req)

      // Decode optional fields
      let title = decode_optional_string_option(body, "title")
      let description = decode_optional_string_option(body, "description")
      let priority = decode_optional_priority(body)
      let status = decode_optional_status(body)
      let tags = decode_optional_string_array_option(body, "tags")
      let worktree = decode_optional_string_option(body, "worktree")

      let updates =
        tasks.TaskUpdates(
          title: title,
          description: description,
          priority: priority,
          status: status,
          tags: tags,
          worktree: worktree,
          flow_template_id: None,
          flow_instance_id: None,
          current_node_id: None,
        )

      let now = get_current_timestamp()

      case tasks.update_task(conn, id, updates, now) {
        Error(_) -> helpers.error_response(500, "Failed to update task")
        Ok(updated_task) -> {
          helpers.json_response(json.to_string(task_to_json(updated_task)), 200)
        }
      }
    }
  }
}

// ─── DELETE /api/v1/tasks/:id ─────────────────────────────────────────────

fn delete_task(
  req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing task ID")
    Ok(id) -> {
      let query = wisp.get_query(req)
      let cascade = case list.key_find(query, "cascade") {
        Ok("true") -> True
        _ -> False
      }

      case tasks.delete_task(conn, id, cascade, get_current_timestamp()) {
        Error(_) -> helpers.error_response(500, "Failed to delete task")
        Ok(_) -> {
          let response_json =
            json.object([#("message", json.string("Task archived"))])
          helpers.json_response(json.to_string(response_json), 200)
        }
      }
    }
  }
}

// ─── POST /api/v1/tasks/:id/dependencies ──────────────────────────────────

fn add_dependency(
  req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing task ID")
    Ok(task_id) -> {
      use body <- wisp.require_json(req)

      case decode_string_field(body, "depends_on") {
        Error(msg) -> helpers.error_response(400, msg)
        Ok(depends_on) -> {
          // Validate no self-dependency
          case dependency_self_check(task_id, depends_on) {
            Some(message) -> helpers.error_response(400, message)
            None -> {
              // Check for cycles in a single recursive query.
              case tasks.would_create_cycle(conn, task_id, depends_on) {
                Error(_) ->
                  helpers.error_response(500, "Failed to check dependencies")
                Ok(True) ->
                  helpers.error_response(
                    400,
                    "Adding this dependency would create a cycle",
                  )
                Ok(False) -> {
                  case tasks.add_dependency(conn, task_id, depends_on) {
                    Error(_) ->
                      helpers.error_response(500, "Failed to add dependency")
                    Ok(_) -> {
                      let response_json =
                        json.object([
                          #("message", json.string("Dependency added")),
                        ])
                      helpers.json_response(json.to_string(response_json), 201)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

// ─── DELETE /api/v1/tasks/:id/dependencies/:depends_on ────────────────────

fn remove_dependency(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id"), dict.get(params, "depends_on") {
    Error(_), _ -> helpers.error_response(400, "Missing task ID")
    _, Error(_) -> helpers.error_response(400, "Missing depends_on ID")
    Ok(task_id), Ok(depends_on) -> {
      case tasks.remove_dependency(conn, task_id, depends_on) {
        Error(_) -> helpers.error_response(500, "Failed to remove dependency")
        Ok(_) -> {
          let response_json =
            json.object([#("message", json.string("Dependency removed"))])
          helpers.json_response(json.to_string(response_json), 200)
        }
      }
    }
  }
}

// ─── GET /api/v1/tasks/:id/blockers ───────────────────────────────────────

fn get_blockers(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing task ID")
    Ok(id) -> {
      case tasks.get_blockers(conn, id) {
        Error(_) -> helpers.error_response(500, "Failed to get blockers")
        Ok(blockers) -> {
          let blockers_json = json.array(blockers, task_to_json)
          helpers.json_response(json.to_string(blockers_json), 200)
        }
      }
    }
  }
}

// ─── GET /api/v1/tasks/ready ──────────────────────────────────────────────

fn list_ready_tasks(_req: Request, conn: DbConnection) -> Response {
  case tasks.list_ready(conn) {
    Error(_) -> helpers.error_response(500, "Failed to list ready tasks")
    Ok(ts) -> {
      let tasks_json = json.array(ts, task_to_json)
      helpers.json_response(json.to_string(tasks_json), 200)
    }
  }
}

// ─── Pure validation (no database access) ─────────────────────────────────

/// Validate the required `POST /api/v1/tasks` fields: title, level and
/// priority. Returns the parsed values or an error message suitable for a
/// 400 response.
pub fn validate_create_input(
  title: String,
  level: String,
  priority: String,
) -> Result(#(String, task.Level, task.Priority), String) {
  use parsed_level <- result.try(
    task.level_from_string(level)
    |> result.map_error(fn(_) { "Invalid level: " <> level }),
  )
  use parsed_priority <- result.try(
    task.priority_from_string(priority)
    |> result.map_error(fn(_) { "Invalid priority: " <> priority }),
  )
  Ok(#(title, parsed_level, parsed_priority))
}

/// Reject a dependency edge where a task depends on itself. Returns the 400
/// message or `None` when the edge is allowed.
pub fn dependency_self_check(
  task_id: String,
  depends_on: String,
) -> Option(String) {
  case task_id == depends_on {
    True -> Some("Task cannot depend on itself")
    False -> None
  }
}

// ─── JSON Helpers ─────────────────────────────────────────────────────────

fn task_to_json(t: task.Task) -> json.Json {
  json.object([
    #("id", json.string(t.id)),
    #("short_id", json.string(t.short_id)),
    #("title", json.string(t.title)),
    #("description", json.string(t.description)),
    #("level", json.string(task.level_to_string(t.level))),
    #("priority", json.string(task.priority_to_string(t.priority))),
    #("status", json.string(task.status_to_string(t.status))),
    #("tags", json.array(t.tags, json.string)),
    #("parent_id", option_to_json(t.parent_id)),
    #("flow_template_id", option_to_json(t.flow_template_id)),
    #("flow_instance_id", option_to_json(t.flow_instance_id)),
    #("current_node_id", option_to_json(t.current_node_id)),
    #("worktree", option_to_json(t.worktree)),
    #("archived", json.bool(t.archived)),
    #("created_at", json.int(t.created_at)),
    #("updated_at", json.int(t.updated_at)),
  ])
}

fn option_to_json(opt: Option(String)) -> json.Json {
  case opt {
    Some(v) -> json.string(v)
    None -> json.null()
  }
}

// ─── Decode Helpers ───────────────────────────────────────────────────────

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

fn decode_string_field(body: Dynamic, field: String) -> Result(String, String) {
  decode.run(body, required_field_decoder(field, decode.string))
  |> result.map_error(fn(_) { "Missing required field: " <> field })
}

fn decode_optional_string(body: Dynamic, field: String) -> String {
  case decode.run(body, optional_field_decoder(field, decode.string)) {
    Ok(Some(v)) -> v
    _ -> ""
  }
}

fn decode_optional_string_option(
  body: Dynamic,
  field: String,
) -> Option(String) {
  case decode.run(body, optional_field_decoder(field, decode.string)) {
    Ok(value) -> value
    _ -> None
  }
}

fn decode_optional_string_array(body: Dynamic, field: String) -> List(String) {
  case
    decode.run(body, optional_field_decoder(field, decode.list(decode.string)))
  {
    Ok(Some(v)) -> v
    _ -> []
  }
}

fn decode_optional_string_array_option(
  body: Dynamic,
  field: String,
) -> Option(List(String)) {
  case
    decode.run(body, optional_field_decoder(field, decode.list(decode.string)))
  {
    Ok(value) -> value
    _ -> None
  }
}

fn decode_optional_priority(body: Dynamic) -> Option(task.Priority) {
  case decode.run(body, optional_field_decoder("priority", decode.string)) {
    Ok(Some(s)) ->
      case task.priority_from_string(s) {
        Ok(p) -> Some(p)
        Error(_) -> None
      }
    _ -> None
  }
}

fn decode_optional_status(body: Dynamic) -> Option(task.TaskStatus) {
  case decode.run(body, optional_field_decoder("status", decode.string)) {
    Ok(Some(s)) ->
      case task.status_from_string(s) {
        Ok(st) -> Some(st)
        Error(_) -> None
      }
    _ -> None
  }
}

// ─── ID Generation ────────────────────────────────────────────────────────

fn generate_uuid() -> String {
  let random = int.random(999_999_999)
  "task-"
  <> int.to_string(random)
  <> "-"
  <> int.to_string(get_current_timestamp())
}

pub fn generate_short_id() -> String {
  let random = int.random(99_999_999)
  string.pad_start(int.to_string(random), 8, "0")
}

/// Generate an 8-digit short ID that does not collide with an existing task.
fn generate_unique_short_id(conn: DbConnection) -> String {
  let candidate = generate_short_id()
  case tasks.short_id_exists(conn, candidate) {
    Ok(True) -> generate_unique_short_id(conn)
    _ -> candidate
  }
}

fn get_current_timestamp() -> Int {
  // TODO: Use gleam_erlang system time for proper timestamps
  0
}
