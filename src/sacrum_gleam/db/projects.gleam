import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sacrum_gleam/db/connection.{
  type DbConnection, type DbError, type Value, IntVal, QueryError, TextVal,
}
import sacrum_gleam/domain/project.{type Project, Project}

/// Project (workspace) persistence.
///
/// `find_project` is the single lookup used by request scoping: it accepts
/// either a project id or its slug, so the `X-Crystalline-Project` header can
/// carry whichever handle a client prefers.
const columns = "id, slug, name, description, created_at, updated_at"

/// Insert a project and return it as persisted.
pub fn create_project(
  conn: DbConnection,
  project: Project,
  now: Int,
) -> Result(Project, DbError) {
  use _ <- result.try(
    connection.execute(
      conn,
      "INSERT INTO projects (id, slug, name, description, created_at, updated_at) "
        <> "VALUES (?, ?, ?, ?, ?, ?)",
      [
        TextVal(project.id),
        TextVal(project.slug),
        TextVal(project.name),
        TextVal(project.description),
        IntVal(now),
        IntVal(now),
      ],
    ),
  )
  case get_project(conn, project.id) {
    Ok(Some(created)) -> Ok(created)
    Ok(None) -> Error(QueryError("Created project could not be read"))
    Error(error) -> Error(error)
  }
}

/// List every project, oldest first.
pub fn list_projects(conn: DbConnection) -> Result(List(Project), DbError) {
  use rows <- result.try(
    connection.query(
      conn,
      "SELECT " <> columns <> " FROM projects ORDER BY created_at, id",
      [],
    ),
  )
  rows |> list.map(row_to_project) |> result.all
}

/// Fetch a project by its id, returning `None` when it does not exist.
pub fn get_project(
  conn: DbConnection,
  id: String,
) -> Result(Option(Project), DbError) {
  find_one(conn, "id = ?", [TextVal(id)])
}

/// Fetch a project by id or slug — the lookup behind request scoping.
pub fn find_project(
  conn: DbConnection,
  key: String,
) -> Result(Option(Project), DbError) {
  find_one(conn, "id = ? OR slug = ?", [TextVal(key), TextVal(key)])
}

/// Whether a slug is already taken.
pub fn slug_exists(conn: DbConnection, slug: String) -> Result(Bool, DbError) {
  use row <- result.try(
    connection.query_one(conn, "SELECT COUNT(*) FROM projects WHERE slug = ?", [
      TextVal(slug),
    ]),
  )
  Ok(case row {
    [IntVal(count), ..] -> count > 0
    _ -> False
  })
}

fn find_one(
  conn: DbConnection,
  where_clause: String,
  params: List(Value),
) -> Result(Option(Project), DbError) {
  use rows <- result.try(connection.query(
    conn,
    "SELECT " <> columns <> " FROM projects WHERE " <> where_clause,
    params,
  ))
  case rows {
    [] -> Ok(None)
    [row, ..] -> row_to_project(row) |> result.map(Some)
  }
}

fn row_to_project(row: List(Value)) -> Result(Project, DbError) {
  case row {
    [
      TextVal(id),
      TextVal(slug),
      TextVal(name),
      TextVal(description),
      IntVal(created_at),
      IntVal(updated_at),
    ] ->
      Ok(Project(
        id: id,
        slug: slug,
        name: name,
        description: description,
        created_at: created_at,
        updated_at: updated_at,
      ))
    _ -> Error(QueryError("Invalid project row"))
  }
}
