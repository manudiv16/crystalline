import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sacrum_gleam/db/connection.{
  type DbConnection, type DbError, IntVal, QueryError, TextVal,
}
import sacrum_gleam/domain/artifact.{type Artifact, Artifact, json_decoder}

/// CRUD operations for task artifacts, stored as arbitrary JSON values.
const columns = "id, task_id, logical_name, content_json, created_at, updated_at"

/// List a task's artifacts in logical-name order.
pub fn list_artifacts(
  conn: DbConnection,
  task_id: String,
) -> Result(List(Artifact), DbError) {
  use rows <- result.try(
    connection.query(
      conn,
      "SELECT "
        <> columns
        <> " FROM artifacts WHERE task_id = ? ORDER BY logical_name",
      [TextVal(task_id)],
    ),
  )
  rows |> list.map(row_to_artifact) |> result.all
}

/// Find one artifact by its task and logical name.
pub fn get_artifact(
  conn: DbConnection,
  task_id: String,
  logical_name: String,
) -> Result(Option(Artifact), DbError) {
  use rows <- result.try(
    connection.query(
      conn,
      "SELECT "
        <> columns
        <> " FROM artifacts WHERE task_id = ? AND logical_name = ?",
      [TextVal(task_id), TextVal(logical_name)],
    ),
  )
  case rows {
    [] -> Ok(None)
    [row, ..] -> row_to_artifact(row) |> result.map(Some)
  }
}

/// Insert or replace an artifact's content while retaining its original ID and
/// creation time. Every update advances `updated_at`, including same-second PUTs.
pub fn upsert_artifact(
  conn: DbConnection,
  task_id: String,
  logical_name: String,
  content: json.Json,
) -> Result(Artifact, DbError) {
  use _ <- result.try(
    connection.execute(
      conn,
      "INSERT INTO artifacts "
        <> "(id, task_id, logical_name, content_json, created_at, updated_at) "
        <> "VALUES (lower(hex(randomblob(16))), ?, ?, ?, "
        <> "CAST(strftime('%s', 'now') AS INTEGER), "
        <> "CAST(strftime('%s', 'now') AS INTEGER)) "
        <> "ON CONFLICT(task_id, logical_name) DO UPDATE SET "
        <> "content_json = excluded.content_json, "
        <> "updated_at = MAX(CAST(strftime('%s', 'now') AS INTEGER), "
        <> "artifacts.updated_at + 1)",
      [
        TextVal(task_id),
        TextVal(logical_name),
        TextVal(json.to_string(content)),
      ],
    ),
  )
  use artifact <- result.try(get_artifact(conn, task_id, logical_name))
  case artifact {
    Some(artifact) -> Ok(artifact)
    None -> Error(QueryError("Artifact upsert completed without a stored row"))
  }
}

/// Delete one artifact and return the number of rows removed.
pub fn delete_artifact(
  conn: DbConnection,
  task_id: String,
  logical_name: String,
) -> Result(Int, DbError) {
  use _ <- result.try(
    connection.execute(
      conn,
      "DELETE FROM artifacts WHERE task_id = ? AND logical_name = ?",
      [TextVal(task_id), TextVal(logical_name)],
    ),
  )
  use row <- result.try(connection.query_one(conn, "SELECT changes()", []))
  Ok(case row {
    [IntVal(count), ..] -> count
    _ -> 0
  })
}

fn row_to_artifact(row: List(connection.Value)) -> Result(Artifact, DbError) {
  case row {
    [
      TextVal(id),
      TextVal(task_id),
      TextVal(logical_name),
      TextVal(raw_content),
      IntVal(created_at),
      IntVal(updated_at),
    ] ->
      case json.parse(raw_content, json_decoder()) {
        Ok(content) ->
          Ok(Artifact(
            id: id,
            task_id: task_id,
            logical_name: logical_name,
            content: content,
            created_at: created_at,
            updated_at: updated_at,
          ))
        Error(_) -> Error(QueryError("Invalid JSON in artifacts.content_json"))
      }
    _ -> Error(QueryError("Unexpected row shape in artifacts"))
  }
}
