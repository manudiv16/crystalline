import gleam/dict.{Dict}
import gleam/option.{Option, Some, None}
import libsql_gleam
import sacrum_gleam/db/connection.{DbConnection, DbError}
import sacrum_gleam/domain/flow.{
  FlowTemplate, FlowInstance, Node, Transition,
}

/// Flow template and instance persistence.

// ─── Flow Templates ──────────────────────────────────────────────────────

pub fn create_flow_template(
  conn: DbConnection,
  template: FlowTemplate,
  now: Int,
) -> Result(String, DbError) {
  let nodes_json = encode_nodes(template.nodes)
  let transitions_json = encode_transitions(template.transitions)

  let sql = {
    "INSERT INTO flow_templates "
    <> "(id, name, description, initial_node_id, nodes_json, "
    <> "transitions_json, on_done_template_id, on_reject_template_id, "
    <> "created_at, updated_at) "
    <> "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  }

  let params = [
    libsql_gleam.TextVal(template.id),
    libsql_gleam.TextVal(template.name),
    libsql_gleam.TextVal(template.description),
    libsql_gleam.TextVal(template.initial_node_id),
    libsql_gleam.TextVal(nodes_json),
    libsql_gleam.TextVal(transitions_json),
    option_to_text(template.on_done_template_id),
    option_to_text(template.on_reject_template_id),
    libsql_gleam.IntVal(now),
    libsql_gleam.IntVal(now),
  ]

  use _ <- connection.query(conn, sql, params)
  Ok(template.id)
}

pub fn get_flow_template(
  conn: DbConnection,
  id: String,
) -> Result(FlowTemplate, DbError) {
  let sql = "SELECT * FROM flow_templates WHERE id = ?"
  use row <- connection.query_one(conn, sql, [libsql_gleam.TextVal(id)])
  row_to_template(row)
}

pub fn list_flow_templates(
  conn: DbConnection,
) -> Result(List(FlowTemplate), DbError) {
  let sql = "SELECT * FROM flow_templates ORDER BY name"
  use rows <- connection.query(conn, sql, [])
  list.map(rows, row_to_template) |> result.all
}

pub fn update_flow_template(
  conn: DbConnection,
  id: String,
  template: FlowTemplate,
  now: Int,
) -> Result(FlowTemplate, DbError) {
  let nodes_json = encode_nodes(template.nodes)
  let transitions_json = encode_transitions(template.transitions)

  let sql = {
    "UPDATE flow_templates SET "
    <> "name = ?, description = ?, initial_node_id = ?, "
    <> "nodes_json = ?, transitions_json = ?, "
    <> "on_done_template_id = ?, on_reject_template_id = ?, "
    <> "updated_at = ? WHERE id = ?"
  }

  let params = [
    libsql_gleam.TextVal(template.name),
    libsql_gleam.TextVal(template.description),
    libsql_gleam.TextVal(template.initial_node_id),
    libsql_gleam.TextVal(nodes_json),
    libsql_gleam.TextVal(transitions_json),
    option_to_text(template.on_done_template_id),
    option_to_text(template.on_reject_template_id),
    libsql_gleam.IntVal(now),
    libsql_gleam.TextVal(id),
  ]

  use _ <- connection.query(conn, sql, params)
  get_flow_template(conn, id)
}

pub fn delete_flow_template(
  conn: DbConnection,
  id: String,
) -> Result(Nil, DbError) {
  let sql = "DELETE FROM flow_templates WHERE id = ?"
  connection.execute(conn, sql, [libsql_gleam.TextVal(id)])
}

// ─── Flow Instances ──────────────────────────────────────────────────────

pub fn create_flow_instance(
  conn: DbConnection,
  instance: FlowInstance,
  now: Int,
) -> Result(String, DbError) {
  let nodes_json = encode_nodes(instance.nodes)
  let transitions_json = encode_transitions(instance.transitions)

  let sql = {
    "INSERT INTO flow_instances "
    <> "(id, template_id, task_id, initial_node_id, nodes_json, "
    <> "transitions_json, on_done_template_id, on_reject_template_id, "
    <> "created_at) "
    <> "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
  }

  let params = [
    libsql_gleam.TextVal(instance.id),
    libsql_gleam.TextVal(instance.template_id),
    libsql_gleam.TextVal(instance.task_id),
    libsql_gleam.TextVal(instance.initial_node_id),
    libsql_gleam.TextVal(nodes_json),
    libsql_gleam.TextVal(transitions_json),
    option_to_text(instance.on_done_template_id),
    option_to_text(instance.on_reject_template_id),
    libsql_gleam.IntVal(now),
  ]

  use _ <- connection.query(conn, sql, params)
  Ok(instance.id)
}

pub fn get_flow_instance(
  conn: DbConnection,
  id: String,
) -> Result(FlowInstance, DbError) {
  let sql = "SELECT * FROM flow_instances WHERE id = ?"
  use row <- connection.query_one(conn, sql, [libsql_gleam.TextVal(id)])
  row_to_instance(row)
}

pub fn get_instance_by_task(
  conn: DbConnection,
  task_id: String,
) -> Result(FlowInstance, DbError) {
  let sql = "SELECT * FROM flow_instances WHERE task_id = ?"
  use row <- connection.query_one(conn, sql, [libsql_gleam.TextVal(task_id)])
  row_to_instance(row)
}

// ─── JSON Encoding Helpers ───────────────────────────────────────────────

fn encode_nodes(nodes: Dict(String, Node)) -> String {
  // Serialize nodes dict to JSON
  // In production, use gleam_json.encode
  "{}"
}

fn encode_transitions(transitions: List(Transition)) -> String {
  // Serialize transitions list to JSON
  // In production, use gleam_json.encode
  "[]"
}

fn row_to_template(row: List(libsql_gleam.Value)) -> Result(FlowTemplate, DbError) {
  case row {
    [
      libsql_gleam.TextVal(id),
      libsql_gleam.TextVal(name),
      libsql_gleam.TextVal(description),
      libsql_gleam.TextVal(initial_node_id),
      libsql_gleam.TextVal(nodes_json),
      libsql_gleam.TextVal(transitions_json),
      on_done_raw,
      on_reject_raw,
      libsql_gleam.IntVal(_created_at),
      libsql_gleam.IntVal(_updated_at),
    ] -> {
      // Parse nodes_json and transitions_json from JSON
      let nodes = decode_nodes(nodes_json)
      let transitions = decode_transitions(transitions_json)

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

fn row_to_instance(row: List(libsql_gleam.Value)) -> Result(FlowInstance, DbError) {
  case row {
    [
      libsql_gleam.TextVal(id),
      libsql_gleam.TextVal(template_id),
      libsql_gleam.TextVal(task_id),
      libsql_gleam.TextVal(initial_node_id),
      libsql_gleam.TextVal(nodes_json),
      libsql_gleam.TextVal(transitions_json),
      on_done_raw,
      on_reject_raw,
      libsql_gleam.IntVal(_created_at),
    ] -> {
      let nodes = decode_nodes(nodes_json)
      let transitions = decode_transitions(transitions_json)

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

fn decode_nodes(json_str: String) -> Dict(String, Node) {
  // Parse JSON back to nodes dict
  // In production, use gleam_json to decode
  dict.new()
}

fn decode_transitions(json_str: String) -> List(Transition) {
  // Parse JSON back to transitions list
  // In production, use gleam_json to decode
  []
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
