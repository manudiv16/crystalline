import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sacrum_gleam/db/connection.{
  type DbConnection, type DbError, type Value, IntVal, NullVal, QueryError,
  TextVal,
}
import sacrum_gleam/domain/task.{
  type Level, type Priority, type Task, type TaskStatus, Task, level_from_string,
  level_to_string, priority_from_string, priority_to_string, status_from_string,
  status_to_string,
}
import sacrum_gleam/json/codec

/// Task CRUD operations against libsql.
pub type TaskFilter {
  TaskFilter(
    level: Option(Level),
    status: Option(TaskStatus),
    parent_id: Option(String),
    archived: Bool,
    limit: Int,
    offset: Int,
  )
}

pub type TaskUpdates {
  TaskUpdates(
    title: Option(String),
    description: Option(String),
    priority: Option(Priority),
    status: Option(TaskStatus),
    tags: Option(List(String)),
    worktree: Option(String),
    flow_template_id: Option(String),
    flow_instance_id: Option(String),
    current_node_id: Option(String),
  )
}

pub fn default_filter() -> TaskFilter {
  TaskFilter(
    level: None,
    status: None,
    parent_id: None,
    archived: False,
    limit: 100,
    offset: 0,
  )
}

pub fn empty_updates() -> TaskUpdates {
  TaskUpdates(
    title: None,
    description: None,
    priority: None,
    status: None,
    tags: None,
    worktree: None,
    flow_template_id: None,
    flow_instance_id: None,
    current_node_id: None,
  )
}

/// Explicit column list for the tasks table (matches schema order).
const task_columns = [
  "id",
  "short_id",
  "title",
  "description",
  "level",
  "priority",
  "status",
  "tags",
  "parent_id",
  "flow_template_id",
  "flow_instance_id",
  "current_node_id",
  "worktree",
  "archived",
  "created_at",
  "updated_at",
]

fn columns_sql() -> String {
  string.join(task_columns, ", ")
}

fn prefixed_columns_sql(prefix: String) -> String {
  task_columns
  |> list.map(fn(column) { prefix <> column })
  |> string.join(", ")
}

// ─── Create / Read ────────────────────────────────────────────────────────

/// Create a new task. Returns the generated ID.
pub fn create_task(
  conn: DbConnection,
  task: Task,
  now: Int,
) -> Result(String, DbError) {
  let statement = {
    "INSERT INTO tasks "
    <> "(id, short_id, title, description, level, priority, status, tags, "
    <> "parent_id, flow_template_id, flow_instance_id, current_node_id, "
    <> "worktree, archived, created_at, updated_at) "
    <> "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  }

  let params = [
    TextVal(task.id),
    TextVal(task.short_id),
    TextVal(task.title),
    TextVal(task.description),
    TextVal(level_to_string(task.level)),
    TextVal(priority_to_string(task.priority)),
    TextVal(status_to_string(task.status)),
    TextVal(codec.encode_string_list(task.tags)),
    text_value(task.parent_id),
    text_value(task.flow_template_id),
    text_value(task.flow_instance_id),
    text_value(task.current_node_id),
    text_value(task.worktree),
    IntVal(bool_to_int(task.archived)),
    IntVal(now),
    IntVal(now),
  ]

  connection.execute(conn, statement, params)
  |> result.map(fn(_) { task.id })
}

/// Get a task by ID.
pub fn get_task(conn: DbConnection, id: String) -> Result(Task, DbError) {
  let statement = "SELECT " <> columns_sql() <> " FROM tasks WHERE id = ?"
  use row <- result.try(connection.query_one(conn, statement, [TextVal(id)]))
  row_to_task(row)
}

/// Return whether a task with the given ID exists (including archived tasks).
pub fn task_exists(conn: DbConnection, id: String) -> Result(Bool, DbError) {
  use row <- result.try(
    connection.query_one(conn, "SELECT COUNT(*) FROM tasks WHERE id = ?", [
      TextVal(id),
    ]),
  )
  Ok(count_from_row(row) > 0)
}

/// Return whether a task with the given short ID already exists.
pub fn short_id_exists(
  conn: DbConnection,
  short_id: String,
) -> Result(Bool, DbError) {
  use row <- result.try(
    connection.query_one(conn, "SELECT COUNT(*) FROM tasks WHERE short_id = ?", [
      TextVal(short_id),
    ]),
  )
  Ok(count_from_row(row) > 0)
}

/// List tasks with optional filtering.
pub fn list_tasks(
  conn: DbConnection,
  filter: TaskFilter,
) -> Result(List(Task), DbError) {
  let statement =
    "SELECT "
    <> columns_sql()
    <> " FROM tasks WHERE "
    <> list_filter_sql(filter)
    <> " ORDER BY created_at DESC LIMIT ? OFFSET ?"

  let params =
    list_filter_params(filter)
    |> list.append([IntVal(filter.limit), IntVal(filter.offset)])

  use rows <- result.try(connection.query(conn, statement, params))
  list.map(rows, row_to_task) |> result.all
}

// ─── Update / Delete ──────────────────────────────────────────────────────

/// Update a task's fields and return the updated task.
pub fn update_task(
  conn: DbConnection,
  id: String,
  updates: TaskUpdates,
  now: Int,
) -> Result(Task, DbError) {
  let #(set_clause, params) = build_update(updates, now, id)
  let statement = "UPDATE tasks SET " <> set_clause <> " WHERE id = ?"

  use _ <- result.try(connection.execute(conn, statement, params))
  get_task(conn, id)
}

/// Archive a task. When `cascade` is true, every descendant (all levels) is
/// archived too. Returns the number of tasks archived.
pub fn delete_task(
  conn: DbConnection,
  id: String,
  cascade: Bool,
  now: Int,
) -> Result(Int, DbError) {
  let result = case cascade {
    False ->
      connection.execute(
        conn,
        "UPDATE tasks SET archived = 1, updated_at = ? WHERE id = ?",
        [IntVal(now), TextVal(id)],
      )
    True ->
      connection.execute(
        conn,
        "WITH RECURSIVE descendants(id) AS ("
          <> " SELECT ? "
          <> " UNION ALL "
          <> " SELECT t.id FROM tasks t JOIN descendants d ON t.parent_id = d.id"
          <> ") "
          <> "UPDATE tasks SET archived = 1, updated_at = ? "
          <> "WHERE id IN (SELECT id FROM descendants)",
        [TextVal(id), IntVal(now)],
      )
  }

  case result {
    Error(error) -> Error(error)
    Ok(_) -> changes(conn)
  }
}

/// Number of rows changed by the most recent INSERT/UPDATE/DELETE.
fn changes(conn: DbConnection) -> Result(Int, DbError) {
  use row <- result.try(connection.query_one(conn, "SELECT changes()", []))
  Ok(count_from_row(row))
}

// ─── Dependencies ─────────────────────────────────────────────────────────

/// Add a dependency: `task_id` depends on `depends_on`.
///
/// Idempotent: adding an already-existing edge is a no-op instead of a
/// constraint error.
pub fn add_dependency(
  conn: DbConnection,
  task_id: String,
  depends_on: String,
) -> Result(Nil, DbError) {
  connection.execute(
    conn,
    "INSERT OR IGNORE INTO task_dependencies (task_id, depends_on) VALUES (?, ?)",
    [TextVal(task_id), TextVal(depends_on)],
  )
}

/// Remove a dependency.
pub fn remove_dependency(
  conn: DbConnection,
  task_id: String,
  depends_on: String,
) -> Result(Nil, DbError) {
  connection.execute(
    conn,
    "DELETE FROM task_dependencies WHERE task_id = ? AND depends_on = ?",
    [TextVal(task_id), TextVal(depends_on)],
  )
}

/// Return whether `task_id` directly depends on `depends_on`.
pub fn dependency_exists(
  conn: DbConnection,
  task_id: String,
  depends_on: String,
) -> Result(Bool, DbError) {
  use row <- result.try(
    connection.query_one(
      conn,
      "SELECT COUNT(*) FROM task_dependencies "
        <> "WHERE task_id = ? AND depends_on = ?",
      [TextVal(task_id), TextVal(depends_on)],
    ),
  )
  Ok(count_from_row(row) > 0)
}

/// Direct dependencies of a task (the tasks it depends on).
pub fn get_dependencies(
  conn: DbConnection,
  task_id: String,
) -> Result(List(String), DbError) {
  use rows <- result.try(
    connection.query(
      conn,
      "SELECT depends_on FROM task_dependencies WHERE task_id = ?",
      [TextVal(task_id)],
    ),
  )

  Ok(
    list.filter_map(rows, fn(row) {
      case row {
        [TextVal(depends_on), ..] -> Ok(depends_on)
        _ -> Error(Nil)
      }
    }),
  )
}

/// Detect whether adding `task_id -> depends_on` would create a cycle, by
/// walking the transitive dependency closure of `depends_on`.
pub fn would_create_cycle(
  conn: DbConnection,
  task_id: String,
  depends_on: String,
) -> Result(Bool, DbError) {
  let statement =
    "WITH RECURSIVE deps(id) AS ("
    <> " SELECT depends_on FROM task_dependencies WHERE task_id = ? "
    <> " UNION "
    <> " SELECT d.depends_on FROM task_dependencies d "
    <> " JOIN deps ON d.task_id = deps.id"
    <> ") "
    <> "SELECT COUNT(*) FROM deps WHERE id = ?"

  use row <- result.try(
    connection.query_one(conn, statement, [
      TextVal(depends_on),
      TextVal(task_id),
    ]),
  )
  Ok(count_from_row(row) > 0)
}

/// All incomplete blockers for a task.
pub fn get_blockers(
  conn: DbConnection,
  task_id: String,
) -> Result(List(Task), DbError) {
  let statement =
    "SELECT "
    <> prefixed_columns_sql("t.")
    <> " FROM task_dependencies d "
    <> "JOIN tasks t ON t.id = d.depends_on "
    <> "WHERE d.task_id = ? AND t.archived = 0 AND t.status != 'done' "
    <> "ORDER BY t.created_at DESC"

  use rows <- result.try(connection.query(conn, statement, [TextVal(task_id)]))
  list.map(rows, row_to_task) |> result.all
}

/// Tasks ready for work: not done, not archived and with no incomplete blockers.
pub fn list_ready(conn: DbConnection) -> Result(List(Task), DbError) {
  let statement =
    "SELECT "
    <> columns_sql()
    <> " FROM tasks "
    <> "WHERE archived = 0 AND status != 'done' "
    <> "AND id NOT IN ("
    <> "  SELECT d.task_id FROM task_dependencies d "
    <> "  JOIN tasks dep ON dep.id = d.depends_on "
    <> "  WHERE dep.status != 'done' AND dep.archived = 0"
    <> ") "
    <> "ORDER BY created_at DESC"

  use rows <- result.try(connection.query(conn, statement, []))
  list.map(rows, row_to_task) |> result.all
}

// ─── Internal helpers ─────────────────────────────────────────────────────

fn count_from_row(row: List(Value)) -> Int {
  case row {
    [IntVal(count), ..] -> count
    _ -> 0
  }
}

fn bool_to_int(value: Bool) -> Int {
  case value {
    True -> 1
    False -> 0
  }
}

fn text_value(value: Option(String)) -> Value {
  case value {
    Some(text) -> TextVal(text)
    None -> NullVal
  }
}

fn text_option(value: Value) -> Option(String) {
  case value {
    TextVal(text) -> Some(text)
    _ -> None
  }
}

fn list_filter_sql(filter: TaskFilter) -> String {
  let clauses = [
    case filter.archived {
      True -> "archived = 1"
      False -> "archived = 0"
    },
    case filter.level {
      Some(_) -> "level = ?"
      None -> ""
    },
    case filter.status {
      Some(_) -> "status = ?"
      None -> ""
    },
    case filter.parent_id {
      Some(_) -> "parent_id = ?"
      None -> ""
    },
  ]

  clauses
  |> list.filter(fn(clause) { clause != "" })
  |> string.join(" AND ")
}

fn list_filter_params(filter: TaskFilter) -> List(Value) {
  list.flatten([
    case filter.level {
      Some(level) -> [TextVal(level_to_string(level))]
      None -> []
    },
    case filter.status {
      Some(status) -> [TextVal(status_to_string(status))]
      None -> []
    },
    case filter.parent_id {
      Some(parent_id) -> [TextVal(parent_id)]
      None -> []
    },
  ])
}

/// Build the SET clause and parameter list for an update. The final parameter
/// is always the row ID used by the WHERE clause.
fn build_update(
  updates: TaskUpdates,
  now: Int,
  id: String,
) -> #(String, List(Value)) {
  let fields = [
    #("title", option.map(updates.title, TextVal)),
    #("description", option.map(updates.description, TextVal)),
    #(
      "priority",
      option.map(updates.priority, fn(priority) {
        TextVal(priority_to_string(priority))
      }),
    ),
    #(
      "status",
      option.map(updates.status, fn(status) {
        TextVal(status_to_string(status))
      }),
    ),
    #(
      "tags",
      option.map(updates.tags, codec.encode_string_list)
        |> option.map(TextVal),
    ),
    #("worktree", option.map(updates.worktree, TextVal)),
    #("flow_template_id", option.map(updates.flow_template_id, TextVal)),
    #("flow_instance_id", option.map(updates.flow_instance_id, TextVal)),
    #("current_node_id", option.map(updates.current_node_id, TextVal)),
  ]

  let present =
    list.filter_map(fields, fn(field) {
      let #(column, value) = field
      case value {
        Some(value) -> Ok(#(column, value))
        None -> Error(Nil)
      }
    })

  let set_clause =
    present
    |> list.map(fn(field) { field.0 <> " = ?" })
    |> string.join(", ")
    |> fn(clause) { clause <> ", updated_at = ?" }

  let params =
    present
    |> list.map(fn(field) { field.1 })
    |> list.append([IntVal(now), TextVal(id)])

  #(set_clause, params)
}

/// Decode a row selected in `task_columns` order into a `Task`.
fn row_to_task(row: List(Value)) -> Result(Task, DbError) {
  case row {
    [
      TextVal(id),
      TextVal(short_id),
      TextVal(title),
      TextVal(description),
      TextVal(level_raw),
      TextVal(priority_raw),
      TextVal(status_raw),
      TextVal(tags_raw),
      parent_raw,
      flow_template_raw,
      flow_instance_raw,
      current_node_raw,
      worktree_raw,
      archived_raw,
      IntVal(created_at),
      IntVal(updated_at),
    ] -> {
      use level <- result.try(
        level_from_string(level_raw)
        |> result.map_error(fn(message) { QueryError(message) }),
      )
      use priority <- result.try(
        priority_from_string(priority_raw)
        |> result.map_error(fn(message) { QueryError(message) }),
      )
      use status <- result.try(
        status_from_string(status_raw)
        |> result.map_error(fn(message) { QueryError(message) }),
      )

      Ok(Task(
        id: id,
        short_id: short_id,
        title: title,
        description: description,
        level: level,
        priority: priority,
        status: status,
        tags: case codec.decode_string_list(tags_raw) {
          Ok(tags) -> tags
          Error(_) -> []
        },
        parent_id: text_option(parent_raw),
        flow_template_id: text_option(flow_template_raw),
        flow_instance_id: text_option(flow_instance_raw),
        current_node_id: text_option(current_node_raw),
        worktree: text_option(worktree_raw),
        archived: archived_raw == IntVal(1),
        created_at: created_at,
        updated_at: updated_at,
      ))
    }
    _ -> Error(QueryError("Invalid task row"))
  }
}
