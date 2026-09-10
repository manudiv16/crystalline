import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sacrum_gleam/db/connection.{type DbConnection, type DbError}
import sacrum_gleam/domain/flow.{
  type FlowInstance, type FlowTemplate, FlowInstance, FlowTemplate,
}
import sacrum_gleam/json/codec

/// Flow template and instance persistence.
/// Explicit column list for the flow_templates table (matches schema order).
const flow_template_columns = [
  "id",
  "name",
  "description",
  "initial_node_id",
  "nodes_json",
  "transitions_json",
  "on_done_template_id",
  "on_reject_template_id",
  "created_at",
  "updated_at",
]

/// Explicit column list for the flow_instances table (matches schema order).
const flow_instance_columns = [
  "id",
  "template_id",
  "task_id",
  "initial_node_id",
  "nodes_json",
  "transitions_json",
  "on_done_template_id",
  "on_reject_template_id",
  "created_at",
]

fn template_columns_sql() -> String {
  string_join(flow_template_columns, ", ")
}

fn string_join(items: List(String), separator: String) -> String {
  case items {
    [] -> ""
    [first, ..rest] ->
      rest
      |> list.fold(first, fn(acc, item) { acc <> separator <> item })
  }
}

// ─── Flow Templates ──────────────────────────────────────────────────────

/// Create a flow template row. Returns the template ID.
pub fn create_flow_template(
  conn: DbConnection,
  template: FlowTemplate,
  now: Int,
) -> Result(String, DbError) {
  let sql = {
    "INSERT INTO flow_templates "
    <> "(id, name, description, initial_node_id, nodes_json, "
    <> "transitions_json, on_done_template_id, on_reject_template_id, "
    <> "created_at, updated_at) "
    <> "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  }

  let params = [
    connection.TextVal(template.id),
    connection.TextVal(template.name),
    connection.TextVal(template.description),
    connection.TextVal(template.initial_node_id),
    connection.TextVal(codec.encode_nodes(template.nodes)),
    connection.TextVal(codec.encode_transitions(template.transitions)),
    option_to_text(template.on_done_template_id),
    option_to_text(template.on_reject_template_id),
    connection.IntVal(now),
    connection.IntVal(now),
  ]

  use _ <- result.try(connection.query(conn, sql, params))
  Ok(template.id)
}

/// Get a flow template by ID.
pub fn get_flow_template(
  conn: DbConnection,
  id: String,
) -> Result(FlowTemplate, DbError) {
  let sql =
    "SELECT " <> template_columns_sql() <> " FROM flow_templates WHERE id = ?"
  use row <- result.try(
    connection.query_one(conn, sql, [connection.TextVal(id)]),
  )
  row_to_template(row)
}

/// List all flow templates ordered by name.
pub fn list_flow_templates(
  conn: DbConnection,
) -> Result(List(FlowTemplate), DbError) {
  let sql =
    "SELECT " <> template_columns_sql() <> " FROM flow_templates ORDER BY name"
  use rows <- result.try(connection.query(conn, sql, []))
  list.map(rows, row_to_template) |> result.all
}

/// Update a flow template. Returns the updated template.
pub fn update_flow_template(
  conn: DbConnection,
  id: String,
  template: FlowTemplate,
  now: Int,
) -> Result(FlowTemplate, DbError) {
  let sql = {
    "UPDATE flow_templates SET "
    <> "name = ?, description = ?, initial_node_id = ?, "
    <> "nodes_json = ?, transitions_json = ?, "
    <> "on_done_template_id = ?, on_reject_template_id = ?, "
    <> "updated_at = ? WHERE id = ?"
  }

  let params = [
    connection.TextVal(template.name),
    connection.TextVal(template.description),
    connection.TextVal(template.initial_node_id),
    connection.TextVal(codec.encode_nodes(template.nodes)),
    connection.TextVal(codec.encode_transitions(template.transitions)),
    option_to_text(template.on_done_template_id),
    option_to_text(template.on_reject_template_id),
    connection.IntVal(now),
    connection.TextVal(id),
  ]

  use _ <- result.try(connection.query(conn, sql, params))
  get_flow_template(conn, id)
}

/// Delete a flow template. Returns `Error` if the template is referenced by
/// a flow instance (the schema uses `ON DELETE RESTRICT`).
pub fn delete_flow_template(
  conn: DbConnection,
  id: String,
) -> Result(Nil, DbError) {
  let sql = "DELETE FROM flow_templates WHERE id = ?"
  connection.execute(conn, sql, [connection.TextVal(id)])
}

/// Number of flow instances created from a template. Used to decide whether
/// a template can be deleted.
pub fn count_instances_for_template(
  conn: DbConnection,
  template_id: String,
) -> Result(Int, DbError) {
  use row <- result.try(
    connection.query_one(
      conn,
      "SELECT COUNT(*) FROM flow_instances WHERE template_id = ?",
      [connection.TextVal(template_id)],
    ),
  )
  Ok(count_from_row(row))
}

// ─── Flow Instances ──────────────────────────────────────────────────────

/// Create a flow instance row. Returns the instance ID.
pub fn create_flow_instance(
  conn: DbConnection,
  instance: FlowInstance,
  now: Int,
) -> Result(String, DbError) {
  let sql = {
    "INSERT INTO flow_instances "
    <> "(id, template_id, task_id, initial_node_id, nodes_json, "
    <> "transitions_json, on_done_template_id, on_reject_template_id, "
    <> "created_at) "
    <> "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
  }

  let params = [
    connection.TextVal(instance.id),
    connection.TextVal(instance.template_id),
    connection.TextVal(instance.task_id),
    connection.TextVal(instance.initial_node_id),
    connection.TextVal(codec.encode_nodes(instance.nodes)),
    connection.TextVal(codec.encode_transitions(instance.transitions)),
    option_to_text(instance.on_done_template_id),
    option_to_text(instance.on_reject_template_id),
    connection.IntVal(now),
  ]

  use _ <- result.try(connection.query(conn, sql, params))
  Ok(instance.id)
}

/// Get a flow instance by ID.
pub fn get_flow_instance(
  conn: DbConnection,
  id: String,
) -> Result(FlowInstance, DbError) {
  let sql =
    "SELECT "
    <> flow_instance_columns_sql()
    <> " FROM flow_instances WHERE id = ?"
  use row <- result.try(
    connection.query_one(conn, sql, [connection.TextVal(id)]),
  )
  row_to_instance(row)
}

/// Get the flow instance bound to a task, if any.
pub fn get_instance_by_task(
  conn: DbConnection,
  task_id: String,
) -> Result(FlowInstance, DbError) {
  let sql =
    "SELECT "
    <> flow_instance_columns_sql()
    <> " FROM flow_instances WHERE task_id = ?"
  use row <- result.try(
    connection.query_one(conn, sql, [connection.TextVal(task_id)]),
  )
  row_to_instance(row)
}

/// List all flow instances.
pub fn list_flow_instances(
  conn: DbConnection,
) -> Result(List(FlowInstance), DbError) {
  let sql =
    "SELECT "
    <> flow_instance_columns_sql()
    <> " FROM flow_instances ORDER BY created_at DESC"
  use rows <- result.try(connection.query(conn, sql, []))
  list.map(rows, row_to_instance) |> result.all
}

fn flow_instance_columns_sql() -> String {
  string_join(flow_instance_columns, ", ")
}

// ─── Row Mapping ─────────────────────────────────────────────────────────

/// Decode a row of `flow_template_columns` (in column order) into a
/// `FlowTemplate`.
pub fn row_to_flow_template(
  row: List(connection.Value),
) -> Result(FlowTemplate, DbError) {
  case row {
    [
      connection.TextVal(id),
      connection.TextVal(name),
      connection.TextVal(description),
      connection.TextVal(initial_node_id),
      connection.TextVal(nodes_json),
      connection.TextVal(transitions_json),
      on_done_raw,
      on_reject_raw,
      connection.IntVal(_created_at),
      connection.IntVal(_updated_at),
    ] -> {
      use nodes <- result.try(
        codec.decode_nodes(nodes_json)
        |> result.map_error(fn(e) { connection.QueryError(e) }),
      )
      use transitions <- result.try(
        codec.decode_transitions(transitions_json)
        |> result.map_error(fn(e) { connection.QueryError(e) }),
      )

      Ok(FlowTemplate(
        id: id,
        name: name,
        description: description,
        initial_node_id: initial_node_id,
        nodes: nodes,
        transitions: transitions,
        on_done_template_id: text_option(on_done_raw),
        on_reject_template_id: text_option(on_reject_raw),
      ))
    }
    _ -> Error(connection.QueryError("Invalid flow template row"))
  }
}

/// Decode a row of `flow_instance_columns` (in column order) into a
/// `FlowInstance`. Exported so `db/executions` can hydrate execution states
/// from the joined `execution_states ⨝ flow_instances` row.
pub fn row_to_flow_instance(
  row: List(connection.Value),
) -> Result(FlowInstance, DbError) {
  case row {
    [
      connection.TextVal(id),
      connection.TextVal(template_id),
      connection.TextVal(task_id),
      connection.TextVal(initial_node_id),
      connection.TextVal(nodes_json),
      connection.TextVal(transitions_json),
      on_done_raw,
      on_reject_raw,
      connection.IntVal(_created_at),
    ] -> {
      use nodes <- result.try(
        codec.decode_nodes(nodes_json)
        |> result.map_error(fn(e) { connection.QueryError(e) }),
      )
      use transitions <- result.try(
        codec.decode_transitions(transitions_json)
        |> result.map_error(fn(e) { connection.QueryError(e) }),
      )

      Ok(FlowInstance(
        id: id,
        template_id: template_id,
        task_id: task_id,
        nodes: nodes,
        transitions: transitions,
        initial_node_id: initial_node_id,
        on_done_template_id: text_option(on_done_raw),
        on_reject_template_id: text_option(on_reject_raw),
      ))
    }
    _ -> Error(connection.QueryError("Invalid flow instance row"))
  }
}

// ─── Small helpers ───────────────────────────────────────────────────────

fn row_to_template(
  row: List(connection.Value),
) -> Result(FlowTemplate, DbError) {
  row_to_flow_template(row)
}

fn row_to_instance(
  row: List(connection.Value),
) -> Result(FlowInstance, DbError) {
  row_to_flow_instance(row)
}

fn count_from_row(row: List(connection.Value)) -> Int {
  case row {
    [connection.IntVal(count), ..] -> count
    _ -> 0
  }
}

fn option_to_text(opt: Option(String)) -> connection.Value {
  case opt {
    Some(v) -> connection.TextVal(v)
    None -> connection.NullVal
  }
}

fn text_option(val: connection.Value) -> Option(String) {
  case val {
    connection.TextVal(v) -> Some(v)
    _ -> None
  }
}
