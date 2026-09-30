import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sacrum_gleam/db/connection.{
  type DbConnection, type DbError, type Value, IntVal, NullVal, QueryError,
  TextVal,
}
import sacrum_gleam/domain/section.{
  type ChecklistState, type Section, type SectionType, CodeRef, Section,
  checklist_state_from_string, checklist_state_to_string,
  section_type_from_string, section_type_to_string,
}

/// Section CRUD operations and partial updates against libsql.
pub type CodeRefUpdates {
  CodeRefUpdates(
    path: Option(Option(String)),
    line_start: Option(Option(Int)),
    line_end: Option(Option(Int)),
    name: Option(Option(String)),
    description: Option(Option(String)),
  )
}

pub type SectionUpdates {
  SectionUpdates(
    section_type: Option(SectionType),
    content: Option(String),
    order: Option(Int),
    checklist_state: Option(Option(ChecklistState)),
    code_ref: Option(Option(CodeRefUpdates)),
  )
}

/// Return the next append order for a task, starting at zero when it has no sections.
pub fn next_order(conn: DbConnection, task_id: String) -> Result(Int, DbError) {
  use row <- result.try(
    connection.query_one(
      conn,
      "SELECT COALESCE(MAX(\"order\"), -1) + 1 FROM sections WHERE task_id = ?",
      [TextVal(task_id)],
    ),
  )
  case row {
    [IntVal(order), ..] -> Ok(order)
    _ -> Error(QueryError("Invalid section order row"))
  }
}

/// Insert a section and return the persisted domain value.
pub fn create_section(
  conn: DbConnection,
  section: Section,
  now: Int,
) -> Result(Section, DbError) {
  let #(
    code_ref_path,
    code_ref_line_start,
    code_ref_line_end,
    code_ref_name,
    code_ref_description,
  ) = code_ref_values(section.code_ref)
  let params = [
    TextVal(section.id),
    TextVal(section.task_id),
    TextVal(section_type_to_string(section.section_type)),
    TextVal(section.content),
    code_ref_path,
    code_ref_line_start,
    code_ref_line_end,
    code_ref_name,
    code_ref_description,
    IntVal(section.order),
    checklist_value(section.checklist_state),
    IntVal(now),
    IntVal(now),
  ]
  use _ <- result.try(connection.execute(
    conn,
    "INSERT INTO sections (id, task_id, section_type, content, "
      <> "code_ref_path, code_ref_line_start, code_ref_line_end, "
      <> "code_ref_name, code_ref_description, \"order\", checklist_state, "
      <> "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    params,
  ))
  case get_section(conn, section.id) {
    Ok(Some(created)) -> Ok(created)
    Ok(None) -> Error(QueryError("Created section could not be read"))
    Error(error) -> Error(error)
  }
}

/// Fetch one section by ID, returning `None` when it does not exist.
pub fn get_section(
  conn: DbConnection,
  id: String,
) -> Result(Option(Section), DbError) {
  use rows <- result.try(
    connection.query(conn, section_select() <> " WHERE id = ?", [TextVal(id)]),
  )
  case rows {
    [] -> Ok(None)
    [row, ..] -> row_to_section(row) |> result.map(Some)
  }
}

/// List a task's sections by order and creation time.
pub fn list_sections(
  conn: DbConnection,
  task_id: String,
) -> Result(List(Section), DbError) {
  use rows <- result.try(
    connection.query(
      conn,
      section_select() <> " WHERE task_id = ? ORDER BY \"order\", created_at",
      [TextVal(task_id)],
    ),
  )
  list.map(rows, row_to_section) |> result.all
}

/// Apply a partial update and return the updated section, or `None` if absent.
pub fn update_section(
  conn: DbConnection,
  id: String,
  updates: SectionUpdates,
  now: Int,
) -> Result(Option(Section), DbError) {
  let code_ref_updates = case updates.code_ref {
    None -> CodeRefUpdates(None, None, None, None, None)
    Some(None) ->
      CodeRefUpdates(Some(None), Some(None), Some(None), Some(None), Some(None))
    Some(Some(value)) -> value
  }
  let fields: List(#(String, Option(Value))) = [
    #(
      "section_type",
      option.map(updates.section_type, fn(value) {
        TextVal(section_type_to_string(value))
      }),
    ),
    #("content", option.map(updates.content, TextVal)),
    #("\"order\"", option.map(updates.order, IntVal)),
    #(
      "checklist_state",
      option.map(updates.checklist_state, nullable_checklist_value),
    ),
    #("code_ref_path", option.map(code_ref_updates.path, nullable_text_value)),
    #(
      "code_ref_line_start",
      option.map(code_ref_updates.line_start, nullable_int_value),
    ),
    #(
      "code_ref_line_end",
      option.map(code_ref_updates.line_end, nullable_int_value),
    ),
    #("code_ref_name", option.map(code_ref_updates.name, nullable_text_value)),
    #(
      "code_ref_description",
      option.map(code_ref_updates.description, nullable_text_value),
    ),
  ]
  let present =
    list.filter_map(fields, fn(field) {
      let #(column, value) = field
      case value {
        Some(value) -> Ok(#(column, value))
        None -> Error(Nil)
      }
    })
  let set_clause = case present {
    [] -> "updated_at = ?"
    _ ->
      present
      |> list.map(fn(field) { field.0 <> " = ?" })
      |> string.join(", ")
      |> fn(clause) { clause <> ", updated_at = ?" }
  }
  let params =
    present
    |> list.map(fn(field) { field.1 })
    |> list.append([IntVal(now), TextVal(id)])
  use _ <- result.try(connection.execute(
    conn,
    "UPDATE sections SET " <> set_clause <> " WHERE id = ?",
    params,
  ))
  get_section(conn, id)
}

/// Delete one section and report whether a row existed.
pub fn delete_section(conn: DbConnection, id: String) -> Result(Bool, DbError) {
  use _ <- result.try(
    connection.execute(conn, "DELETE FROM sections WHERE id = ?", [TextVal(id)]),
  )
  use row <- result.try(connection.query_one(conn, "SELECT changes()", []))
  case row {
    [IntVal(count), ..] -> Ok(count > 0)
    _ -> Error(QueryError("Invalid section delete count"))
  }
}

fn section_select() -> String {
  "SELECT id, task_id, section_type, content, code_ref_path, "
  <> "code_ref_line_start, code_ref_line_end, code_ref_name, "
  <> "code_ref_description, \"order\", checklist_state FROM sections"
}

fn code_ref_values(
  code_ref: Option(section.CodeRef),
) -> #(Value, Value, Value, Value, Value) {
  case code_ref {
    Some(value) -> #(
      TextVal(value.path),
      int_value(value.line_start),
      int_value(value.line_end),
      text_value(value.name),
      text_value(value.description),
    )
    None -> #(NullVal, NullVal, NullVal, NullVal, NullVal)
  }
}

fn row_to_section(row: List(Value)) -> Result(Section, DbError) {
  case row {
    [
      TextVal(id),
      TextVal(task_id),
      TextVal(section_type_raw),
      TextVal(content),
      code_ref_path,
      code_ref_line_start,
      code_ref_line_end,
      code_ref_name,
      code_ref_description,
      IntVal(order),
      checklist_state_raw,
    ] -> {
      use section_type <- result.try(
        section_type_from_string(section_type_raw)
        |> result.map_error(QueryError),
      )
      use checklist_state <- result.try(checklist_from_value(
        checklist_state_raw,
      ))
      Ok(Section(
        id: id,
        task_id: task_id,
        section_type: section_type,
        content: content,
        code_ref: code_ref_from_values(
          code_ref_path,
          code_ref_line_start,
          code_ref_line_end,
          code_ref_name,
          code_ref_description,
        ),
        order: order,
        checklist_state: checklist_state,
      ))
    }
    _ -> Error(QueryError("Invalid section row"))
  }
}

fn code_ref_from_values(
  path: Value,
  line_start: Value,
  line_end: Value,
  name: Value,
  description: Value,
) -> Option(section.CodeRef) {
  case path {
    TextVal(path) ->
      Some(CodeRef(
        path: path,
        line_start: int_option(line_start),
        line_end: int_option(line_end),
        name: text_option(name),
        description: text_option(description),
      ))
    _ -> None
  }
}

fn checklist_from_value(
  value: Value,
) -> Result(Option(ChecklistState), DbError) {
  case value {
    NullVal -> Ok(None)
    TextVal(raw) ->
      checklist_state_from_string(raw)
      |> result.map(Some)
      |> result.map_error(QueryError)
    _ -> Error(QueryError("Invalid section checklist state"))
  }
}

fn checklist_value(value: Option(ChecklistState)) -> Value {
  case value {
    Some(state) -> TextVal(checklist_state_to_string(state))
    None -> NullVal
  }
}

fn nullable_checklist_value(value: Option(ChecklistState)) -> Value {
  checklist_value(value)
}

fn nullable_text_value(value: Option(String)) -> Value {
  text_value(value)
}

fn nullable_int_value(value: Option(Int)) -> Value {
  int_value(value)
}

fn text_value(value: Option(String)) -> Value {
  case value {
    Some(text) -> TextVal(text)
    None -> NullVal
  }
}

fn int_value(value: Option(Int)) -> Value {
  case value {
    Some(number) -> IntVal(number)
    None -> NullVal
  }
}

fn text_option(value: Value) -> Option(String) {
  case value {
    TextVal(text) -> Some(text)
    _ -> None
  }
}

fn int_option(value: Value) -> Option(Int) {
  case value {
    IntVal(number) -> Some(number)
    _ -> None
  }
}
