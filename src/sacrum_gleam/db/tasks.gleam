import gleam/option.{Option, Some, None}
import libsql_gleam
import sacrum_gleam/db/connection.{DbConnection, DbError}
import sacrum_gleam/domain/task.{
  Task, Level, Priority, TaskStatus, CodeRef,
  level_from_string, level_to_string,
  priority_from_string, priority_to_string,
  status_from_string, status_to_string,
}

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

/// Create a new task. Returns the generated ID.
pub fn create_task(
  conn: DbConnection,
  task: Task,
  now: Int,
) -> Result(String, DbError) {
  let sql = {
    "INSERT INTO tasks (id, short_id, title, description, level, priority, "
    <> "status, tags, parent_id, flow_template_id, flow_instance_id, "
    <> "current_node_id, worktree, archived, created_at, updated_at) "
    <> "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  }

  let params = [
    libsql_gleam.TextVal(task.id),
    libsql_gleam.TextVal(task.short_id),
    libsql_gleam.TextVal(task.title),
    libsql_gleam.TextVal(task.description),
    libsql_gleam.TextVal(level_to_string(task.level)),
    libsql_gleam.TextVal(priority_to_string(task.priority)),
    libsql_gleam.TextVal(status_to_string(task.status)),
    libsql_gleam.TextVal(tags_to_json(task.tags)),
    option_to_text(task.parent_id),
    option_to_text(task.flow_template_id),
    option_to_text(task.flow_instance_id),
    option_to_text(task.current_node_id),
    option_to_text(task.worktree),
    libsql_gleam.IntVal(bool_to_int(task.archived)),
    libsql_gleam.IntVal(now),
    libsql_gleam.IntVal(now),
  ]

  use _ <- connection.query(conn, sql, params)
  Ok(task.id)
}

/// Get a task by ID.
pub fn get_task(conn: DbConnection, id: String) -> Result(Task, DbError) {
  let sql = "SELECT * FROM tasks WHERE id = ?"
  use row <- connection.query_one(conn, sql, [libsql_gleam.TextVal(id)])
  row_to_task(row)
}

/// List tasks with optional filtering.
pub fn list_tasks(
  conn: DbConnection,
  filter: TaskFilter,
) -> Result(List(Task), DbError) {
  let sql = build_list_query(filter)
  let params = build_list_params(filter)

  use rows <- connection.query(conn, sql, params)
  list.map(rows, row_to_task) |> result.all
}

/// Update a task's fields.
pub fn update_task(
  conn: DbConnection,
  id: String,
  updates: TaskUpdates,
  now: Int,
) -> Result(Task, DbError) {
  let set_clauses = build_update_set(updates, now)
  let params = build_update_params(updates, now, id)

  let sql = "UPDATE tasks SET " <> set_clauses <> " WHERE id = ?"
  use _ <- connection.query(conn, sql, params)
  get_task(conn, id)
}

/// Delete a task (soft-delete sets archived = true).
pub fn delete_task(
  conn: DbConnection,
  id: String,
  cascade: Bool,
) -> Result(Nil, DbError) {
  let sql = case cascade {
    True -> "UPDATE tasks SET archived = 1 WHERE id = ? OR parent_id = ?"
    False -> "UPDATE tasks SET archived = 1 WHERE id = ?"
  }

  let params = case cascade {
    True -> [libsql_gleam.TextVal(id), libsql_gleam.TextVal(id)]
    False -> [libsql_gleam.TextVal(id)]
  }

  connection.execute(conn, sql, params)
}

/// Add a dependency: task_id depends on depends_on_id.
pub fn add_dependency(
  conn: DbConnection,
  task_id: String,
  depends_on: String,
) -> Result(Nil, DbError) {
  let sql =
    "INSERT INTO task_dependencies (task_id, depends_on) VALUES (?, ?)"
  connection.execute(
    conn,
    sql,
    [libsql_gleam.TextVal(task_id), libsql_gleam.TextVal(depends_on)],
  )
}

/// Remove a dependency.
pub fn remove_dependency(
  conn: DbConnection,
  task_id: String,
  depends_on: String,
) -> Result(Nil, DbError) {
  let sql =
    "DELETE FROM task_dependencies WHERE task_id = ? AND depends_on = ?"
  connection.execute(
    conn,
    sql,
    [libsql_gleam.TextVal(task_id), libsql_gleam.TextVal(depends_on)],
  )
}

/// Get all blockers for a task.
pub fn get_blockers(
  conn: DbConnection,
  task_id: String,
) -> Result(List(Task), DbError) {
  let sql = {
    "SELECT t.* FROM tasks t "
    <> "JOIN task_dependencies d ON t.id = d.depends_on "
    <> "WHERE d.task_id = ? AND t.archived = 0 AND t.status != 'done'"
  }
  use rows <- connection.query(conn, sql, [libsql_gleam.TextVal(task_id)])
  list.map(rows, row_to_task) |> result.all
}

/// List tasks ready for work (no incomplete blockers).
pub fn list_ready(conn: DbConnection) -> Result(List(Task), DbError) {
  let sql = {
    "SELECT * FROM tasks WHERE id NOT IN ("
    <> "  SELECT d.task_id FROM task_dependencies d "
    <> "  JOIN tasks t ON d.depends_on = t.id "
    <> "  WHERE t.status != 'done' AND t.archived = 0"
    <> ") AND status != 'done' AND archived = 0"
  }
  use rows <- connection.query(conn, sql, [])
  list.map(rows, row_to_task) |> result.all
}

// ─── Helpers ──────────────────────────────────────────────────────────────

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

fn build_list_query(filter: TaskFilter) -> String {
  let base = "SELECT * FROM tasks WHERE archived = 0"
  let level_clause = case filter.level {
    Some(l) -> " AND level = '" <> level_to_string(l) <> "'"
    None -> ""
  }
  let status_clause = case filter.status {
    Some(s) -> " AND status = '" <> status_to_string(s) <> "'"
    None -> ""
  }
  let parent_clause = case filter.parent_id {
    Some(p) -> " AND parent_id = '" <> p <> "'"
    None -> ""
  }
  base <> level_clause <> status_clause <> parent_clause
    <> " ORDER BY created_at DESC LIMIT " <> int.to_string(filter.limit)
    <> " OFFSET " <> int.to_string(filter.offset)
}

fn build_list_params(filter: TaskFilter) -> List(libsql_gleam.Value) {
  []
}

fn build_update_set(updates: TaskUpdates, now: Int) -> String {
  let clauses = [
    case updates.title {
      Some(_) -> "title = ?"
      None -> ""
    },
    case updates.description {
      Some(_) -> "description = ?"
      None -> ""
    },
    case updates.priority {
      Some(_) -> "priority = ?"
      None -> ""
    },
    case updates.status {
      Some(_) -> "status = ?"
      None -> ""
    },
    case updates.tags {
      Some(_) -> "tags = ?"
      None -> ""
    },
    case updates.worktree {
      Some(_) -> "worktree = ?"
      None -> ""
    },
    case updates.flow_template_id {
      Some(_) -> "flow_template_id = ?"
      None -> ""
    },
    case updates.flow_instance_id {
      Some(_) -> "flow_instance_id = ?"
      None -> ""
    },
    case updates.current_node_id {
      Some(_) -> "current_node_id = ?"
      None -> ""
    },
    "updated_at = " <> int.to_string(now),
  ]
  clauses
  |> list.filter(fn(s) { s != "" })
  |> string.join(", ")
}

fn build_update_params(
  updates: TaskUpdates,
  now: Int,
  id: String,
) -> List(libsql_gleam.Value) {
  let values = [
    case updates.title {
      Some(v) -> [libsql_gleam.TextVal(v)]
      None -> []
    },
    case updates.description {
      Some(v) -> [libsql_gleam.TextVal(v)]
      None -> []
    },
    case updates.priority {
      Some(v) -> [libsql_gleam.TextVal(priority_to_string(v))]
      None -> []
    },
    case updates.status {
      Some(v) -> [libsql_gleam.TextVal(status_to_string(v))]
      None -> []
    },
    case updates.tags {
      Some(v) -> [libsql_gleam.TextVal(tags_to_json(v))]
      None -> []
    },
    case updates.worktree {
      Some(v) -> [libsql_gleam.TextVal(v)]
      None -> []
    },
    case updates.flow_template_id {
      Some(v) -> [libsql_gleam.TextVal(v)]
      None -> []
    },
    case updates.flow_instance_id {
      Some(v) -> [libsql_gleam.TextVal(v)]
      None -> []
    },
    case updates.current_node_id {
      Some(v) -> [libsql_gleam.TextVal(v)]
      None -> []
    },
  ]
  list.flatten(values)
}

fn row_to_task(row: List(libsql_gleam.Value)) -> Result(Task, DbError) {
  // This requires matching column order from SELECT *
  // In practice, use named columns and map by index
  case row {
    [
      libsql_gleam.TextVal(id),
      libsql_gleam.TextVal(short_id),
      libsql_gleam.TextVal(title),
      libsql_gleam.TextVal(description),
      libsql_gleam.TextVal(level_str),
      libsql_gleam.TextVal(priority_str),
      libsql_gleam.TextVal(status_str),
      libsql_gleam.TextVal(tags_json),
      parent_id_raw,
      flow_template_id_raw,
      flow_instance_id_raw,
      current_node_id_raw,
      worktree_raw,
      libsql_gleam.IntVal(archived_int),
      libsql_gleam.IntVal(created_at),
      libsql_gleam.IntVal(updated_at),
    ] -> {
      use level <- result.map_err(level_from_string(level_str), fn(e) {
        connection.QueryError(e)
      })
      use priority <- result.map_err(priority_from_string(priority_str), fn(e) {
        connection.QueryError(e)
      })
      use status <- result.map_err(status_from_string(status_str), fn(e) {
        connection.QueryError(e)
      })

      Ok(Task(
        id: id,
        short_id: short_id,
        title: title,
        description: description,
        level: level,
        priority: priority,
        status: status,
        tags: parse_string_array(tags_json),
        parent_id: text_option(parent_id_raw),
        flow_template_id: text_option(flow_template_id_raw),
        flow_instance_id: text_option(flow_instance_id_raw),
        current_node_id: text_option(current_node_id_raw),
        worktree: text_option(worktree_raw),
        archived: archived_int != 0,
        created_at: created_at,
        updated_at: updated_at,
      ))
    }
    _ -> Error(connection.QueryError("Invalid task row"))
  }
}

fn option_to_text(opt: Option(String)) -> libsql_gleam.Value {
  case opt {
    Some(v) -> libsql_gleam.TextVal(v)
    None -> libsql_gleam.NullVal
  }
}

fn text_option(val: libsql_gleam.Value) -> Option(String) {
  case val {
    libsql_gleam.TextVal(v) -> Some(v)
    _ -> None
  }
}

fn bool_to_int(b: Bool) -> Int {
  case b {
    True -> 1
    False -> 0
  }
}

fn parse_string_array(json_str: String) -> List(String) {
  // Parse JSON array of strings
  // In production, use gleam_json to decode
  []
}

fn tags_to_json(tags: List(String)) -> String {
  "[" <> string.join(list.map(tags, fn(t) { "\"" <> string.replace(t, "\"", "\\\"") <> "\"" }), ", ") <> "]"
}
