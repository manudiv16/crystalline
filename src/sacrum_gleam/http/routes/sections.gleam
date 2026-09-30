/// Sections API — task-scoped section CRUD and code references.
///
/// Sections are persisted independently from tasks, ordered within their task,
/// and removed through the task foreign-key cascade.
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Patch, Post}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/db/sections as db_sections
import sacrum_gleam/db/tasks
import sacrum_gleam/domain/section
import sacrum_gleam/http/helpers
import sacrum_gleam/http/router.{type Route, Route}
import wisp.{type Request, type Response}

type FieldValue(a) {
  MissingField
  PresentField(a)
}

/// Routes for listing, creating, fetching, updating, and deleting sections.
pub fn section_routes(conn: DbConnection) -> List(Route) {
  [
    Route(Get, "/api/v1/tasks/:task_id/sections", fn(req, params) {
      list_task_sections(req, params, conn)
    }),
    Route(Post, "/api/v1/tasks/:task_id/sections", fn(req, params) {
      create_task_section(req, params, conn)
    }),
    Route(Get, "/api/v1/sections/:id", fn(req, params) {
      get_section(req, params, conn)
    }),
    Route(Patch, "/api/v1/sections/:id", fn(req, params) {
      update_section(req, params, conn)
    }),
    Route(Delete, "/api/v1/sections/:id", fn(req, params) {
      delete_section(req, params, conn)
    }),
  ]
}

fn list_task_sections(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "task_id") {
    Error(_) -> helpers.error_response(400, "Missing task ID")
    Ok(task_id) ->
      case tasks.task_exists(conn, task_id) {
        Error(_) -> helpers.error_response(500, "Failed to check task")
        Ok(False) -> helpers.error_response(404, "Task not found")
        Ok(True) ->
          case db_sections.list_sections(conn, task_id) {
            Error(_) -> helpers.error_response(500, "Failed to list sections")
            Ok(sections) -> {
              let body = json.array(sections, section_to_json)
              helpers.json_response(json.to_string(body), 200)
            }
          }
      }
  }
}

fn create_task_section(
  req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "task_id") {
    Error(_) -> helpers.error_response(400, "Missing task ID")
    Ok(task_id) -> {
      use body <- wisp.require_json(req)
      case decode_create_input(body) {
        Error(message) -> helpers.error_response(400, message)
        Ok(input) ->
          case tasks.task_exists(conn, task_id) {
            Error(_) -> helpers.error_response(500, "Failed to check task")
            Ok(False) -> helpers.error_response(400, "Task not found")
            Ok(True) -> {
              let #(section_type, content, code_ref, order, checklist_state) =
                input
              let order_result = case order {
                Some(order) -> Ok(order)
                None -> db_sections.next_order(conn, task_id)
              }
              case order_result {
                Error(_) ->
                  helpers.error_response(500, "Failed to find section order")
                Ok(order) -> {
                  let now = milliseconds_now()
                  let section =
                    section.Section(
                      id: new_section_id(),
                      task_id: task_id,
                      section_type: section_type,
                      content: content,
                      code_ref: code_ref,
                      order: order,
                      checklist_state: checklist_state,
                    )
                  case db_sections.create_section(conn, section, now) {
                    Error(_) ->
                      helpers.error_response(500, "Failed to create section")
                    Ok(created) ->
                      helpers.json_response(
                        json.to_string(section_to_json(created)),
                        201,
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

fn get_section(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing section ID")
    Ok(id) ->
      case db_sections.get_section(conn, id) {
        Error(_) -> helpers.error_response(500, "Failed to get section")
        Ok(None) -> helpers.error_response(404, "Section not found")
        Ok(Some(section)) ->
          helpers.json_response(json.to_string(section_to_json(section)), 200)
      }
  }
}

fn update_section(
  req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing section ID")
    Ok(id) -> {
      use body <- wisp.require_json(req)
      case decode_section_updates(body) {
        Error(message) -> helpers.error_response(400, message)
        Ok(updates) ->
          case
            db_sections.update_section(conn, id, updates, milliseconds_now())
          {
            Error(_) -> helpers.error_response(500, "Failed to update section")
            Ok(None) -> helpers.error_response(404, "Section not found")
            Ok(Some(section)) ->
              helpers.json_response(
                json.to_string(section_to_json(section)),
                200,
              )
          }
      }
    }
  }
}

fn delete_section(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(_) -> helpers.error_response(400, "Missing section ID")
    Ok(id) ->
      case db_sections.delete_section(conn, id) {
        Error(_) -> helpers.error_response(500, "Failed to delete section")
        Ok(False) -> helpers.error_response(404, "Section not found")
        Ok(True) ->
          helpers.json_response(
            json.to_string(
              json.object([#("message", json.string("Section deleted"))]),
            ),
            200,
          )
      }
  }
}

fn decode_create_input(
  body: Dynamic,
) -> Result(
  #(
    section.SectionType,
    String,
    Option(section.CodeRef),
    Option(Int),
    Option(section.ChecklistState),
  ),
  String,
) {
  use section_type_raw <- result.try(decode_string_field(body, "section_type"))
  use section_type <- result.try(section.section_type_from_string(
    section_type_raw,
  ))
  use content <- result.try(decode_string_field(body, "content"))
  use code_ref <- result.try(decode_optional_field(
    body,
    "code_ref",
    code_ref_decoder(),
  ))
  use order <- result.try(decode_optional_field(body, "order", decode.int))
  use checklist_state_raw <- result.try(decode_optional_field(
    body,
    "checklist_state",
    decode.string,
  ))
  let checklist_state = case checklist_state_raw {
    None -> Ok(None)
    Some(raw) ->
      section.checklist_state_from_string(raw)
      |> result.map(Some)
  }
  use checklist_state <- result.try(checklist_state)
  Ok(#(section_type, content, code_ref, order, checklist_state))
}

fn decode_section_updates(
  body: Dynamic,
) -> Result(db_sections.SectionUpdates, String) {
  use section_type_raw <- result.try(decode_patch_field(
    body,
    "section_type",
    decode.string,
  ))
  let section_type = case section_type_raw {
    None -> Ok(None)
    Some(raw) -> section.section_type_from_string(raw) |> result.map(Some)
  }
  use section_type <- result.try(section_type)
  use content <- result.try(decode_patch_field(body, "content", decode.string))
  use order <- result.try(decode_patch_field(body, "order", decode.int))
  use checklist_state_raw <- result.try(decode_nullable_field(
    body,
    "checklist_state",
    decode.string,
  ))
  let checklist_state = case checklist_state_raw {
    None -> Ok(None)
    Some(None) -> Ok(Some(None))
    Some(Some(raw)) ->
      section.checklist_state_from_string(raw)
      |> result.map(fn(value) { Some(Some(value)) })
  }
  use checklist_state <- result.try(checklist_state)
  use code_ref <- result.try(decode_nullable_field(
    body,
    "code_ref",
    code_ref_updates_decoder(),
  ))
  Ok(db_sections.SectionUpdates(
    section_type: section_type,
    content: content,
    order: order,
    checklist_state: checklist_state,
    code_ref: code_ref,
  ))
}

fn code_ref_decoder() -> decode.Decoder(section.CodeRef) {
  use path <- decode.field("path", decode.string)
  use line_start <- decode.optional_field(
    "line_start",
    None,
    decode.optional(decode.int),
  )
  use line_end <- decode.optional_field(
    "line_end",
    None,
    decode.optional(decode.int),
  )
  use name <- decode.optional_field(
    "name",
    None,
    decode.optional(decode.string),
  )
  use description <- decode.optional_field(
    "description",
    None,
    decode.optional(decode.string),
  )
  decode.success(section.CodeRef(
    path: path,
    line_start: line_start,
    line_end: line_end,
    name: name,
    description: description,
  ))
}

fn code_ref_updates_decoder() -> decode.Decoder(db_sections.CodeRefUpdates) {
  use path <- decode.optional_field(
    "path",
    MissingField,
    decode.optional(decode.string) |> decode.map(PresentField),
  )
  use line_start <- decode.optional_field(
    "line_start",
    MissingField,
    decode.optional(decode.int) |> decode.map(PresentField),
  )
  use line_end <- decode.optional_field(
    "line_end",
    MissingField,
    decode.optional(decode.int) |> decode.map(PresentField),
  )
  use name <- decode.optional_field(
    "name",
    MissingField,
    decode.optional(decode.string) |> decode.map(PresentField),
  )
  use description <- decode.optional_field(
    "description",
    MissingField,
    decode.optional(decode.string) |> decode.map(PresentField),
  )
  decode.success(db_sections.CodeRefUpdates(
    path: field_value_to_option(path),
    line_start: field_value_to_option(line_start),
    line_end: field_value_to_option(line_end),
    name: field_value_to_option(name),
    description: field_value_to_option(description),
  ))
}

fn decode_string_field(body: Dynamic, key: String) -> Result(String, String) {
  decode.run(body, required_field_decoder(key, decode.string))
  |> result.map_error(fn(_) { "Missing or invalid field: " <> key })
}

fn decode_optional_field(
  body: Dynamic,
  key: String,
  inner: decode.Decoder(a),
) -> Result(Option(a), String) {
  decode.run(body, optional_field_decoder(key, inner))
  |> result.map_error(fn(_) { "Invalid field: " <> key })
}

fn decode_patch_field(
  body: Dynamic,
  key: String,
  inner: decode.Decoder(a),
) -> Result(Option(a), String) {
  use value <- result.try(decode_nullable_field(body, key, inner))
  case value {
    None -> Ok(None)
    Some(None) -> Error("Field cannot be null: " <> key)
    Some(Some(value)) -> Ok(Some(value))
  }
}

fn decode_nullable_field(
  body: Dynamic,
  key: String,
  inner: decode.Decoder(a),
) -> Result(Option(Option(a)), String) {
  decode.run(body, nullable_field_decoder(key, inner))
  |> result.map_error(fn(_) { "Invalid field: " <> key })
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

fn nullable_field_decoder(
  key: String,
  inner: decode.Decoder(a),
) -> decode.Decoder(Option(Option(a))) {
  use value <- decode.optional_field(
    key,
    MissingField,
    decode.optional(inner) |> decode.map(PresentField),
  )
  decode.success(field_value_to_option(value))
}

fn field_value_to_option(value: FieldValue(a)) -> Option(a) {
  case value {
    MissingField -> None
    PresentField(value) -> Some(value)
  }
}

fn section_to_json(value: section.Section) -> json.Json {
  json.object([
    #("id", json.string(value.id)),
    #("task_id", json.string(value.task_id)),
    #(
      "section_type",
      json.string(section.section_type_to_string(value.section_type)),
    ),
    #("content", json.string(value.content)),
    #("code_ref", code_ref_to_json(value.code_ref)),
    #("order", json.int(value.order)),
    #("checklist_state", checklist_state_to_json(value.checklist_state)),
  ])
}

fn code_ref_to_json(value: Option(section.CodeRef)) -> json.Json {
  case value {
    None -> json.null()
    Some(code_ref) ->
      json.object([
        #("path", json.string(code_ref.path)),
        #("line_start", nullable_int_json(code_ref.line_start)),
        #("line_end", nullable_int_json(code_ref.line_end)),
        #("name", nullable_string_json(code_ref.name)),
        #("description", nullable_string_json(code_ref.description)),
      ])
  }
}

fn checklist_state_to_json(value: Option(section.ChecklistState)) -> json.Json {
  case value {
    None -> json.null()
    Some(state) -> json.string(section.checklist_state_to_string(state))
  }
}

fn nullable_string_json(value: Option(String)) -> json.Json {
  case value {
    None -> json.null()
    Some(text) -> json.string(text)
  }
}

fn nullable_int_json(value: Option(Int)) -> json.Json {
  case value {
    None -> json.null()
    Some(number) -> json.int(number)
  }
}

fn new_section_id() -> String {
  "section-"
  <> int.to_string(int.random(999_999_999))
  <> "-"
  <> int.to_string(milliseconds_now())
}

fn milliseconds_now() -> Int {
  erlang_system_time() / 1_000_000
}

@external(erlang, "erlang", "system_time")
fn erlang_system_time() -> Int
