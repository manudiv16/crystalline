/// REST endpoints for task-scoped JSON artifacts.
///
/// Artifacts are listed by logical name, and PUT always returns 200 whether it
/// inserts or updates. Path parameters are percent-decoded before database use.
import gleam/dict
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Put}
import gleam/json
import gleam/option.{None, Some}
import gleam/uri
import sacrum_gleam/db/artifacts
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/db/tasks
import sacrum_gleam/domain/artifact.{type Artifact, json_decoder}
import sacrum_gleam/http/helpers
import sacrum_gleam/http/router.{type Route, Route}
import wisp.{type Request, type Response}

/// Return the artifact API routes for the supplied database connection.
pub fn artifact_routes(conn: DbConnection) -> List(Route) {
  [
    Route(
      Get,
      "/api/v1/tasks/:task_id/artifacts/:logical_name",
      fn(_req, params) { get_artifact(params, conn) },
    ),
    Route(
      Put,
      "/api/v1/tasks/:task_id/artifacts/:logical_name",
      fn(req, params) { put_artifact(req, params, conn) },
    ),
    Route(
      Delete,
      "/api/v1/tasks/:task_id/artifacts/:logical_name",
      fn(_req, params) { delete_artifact(params, conn) },
    ),
    Route(Get, "/api/v1/tasks/:task_id/artifacts", fn(_req, params) {
      list_artifacts(params, conn)
    }),
  ]
}

fn list_artifacts(
  params: dict.Dict(String, String),
  conn: DbConnection,
) -> Response {
  case task_id_param(params) {
    Error(response) -> response
    Ok(task_id) ->
      case require_task(conn, task_id) {
        Error(response) -> response
        Ok(Nil) ->
          case artifacts.list_artifacts(conn, task_id) {
            Error(_) -> helpers.error_response(500, "Failed to list artifacts")
            Ok(found) ->
              helpers.json_response(
                json.to_string(json.array(found, artifact_to_json)),
                200,
              )
          }
      }
  }
}

fn get_artifact(
  params: dict.Dict(String, String),
  conn: DbConnection,
) -> Response {
  case task_id_param(params), logical_name_param(params) {
    Error(response), _ -> response
    _, Error(response) -> response
    Ok(task_id), Ok(logical_name) ->
      case require_task(conn, task_id) {
        Error(response) -> response
        Ok(Nil) ->
          case artifacts.get_artifact(conn, task_id, logical_name) {
            Error(_) -> helpers.error_response(500, "Failed to get artifact")
            Ok(None) -> helpers.error_response(404, "Artifact not found")
            Ok(Some(artifact)) ->
              helpers.json_response(
                json.to_string(artifact_to_json(artifact)),
                200,
              )
          }
      }
  }
}

fn put_artifact(
  req: Request,
  params: dict.Dict(String, String),
  conn: DbConnection,
) -> Response {
  case task_id_param(params), logical_name_param(params) {
    Error(response), _ -> response
    _, Error(response) -> response
    Ok(task_id), Ok(logical_name) ->
      case require_task(conn, task_id) {
        Error(response) -> response
        Ok(Nil) -> {
          use body <- wisp.require_json(req)
          case decode.run(body, content_decoder()) {
            Error(_) ->
              helpers.error_response(
                400,
                "Request must contain a valid JSON content field",
              )
            Ok(content) ->
              case
                artifacts.upsert_artifact(conn, task_id, logical_name, content)
              {
                Error(_) ->
                  helpers.error_response(500, "Failed to save artifact")
                Ok(artifact) ->
                  helpers.json_response(
                    json.to_string(artifact_to_json(artifact)),
                    200,
                  )
              }
          }
        }
      }
  }
}

fn delete_artifact(
  params: dict.Dict(String, String),
  conn: DbConnection,
) -> Response {
  case task_id_param(params), logical_name_param(params) {
    Error(response), _ -> response
    _, Error(response) -> response
    Ok(task_id), Ok(logical_name) ->
      case require_task(conn, task_id) {
        Error(response) -> response
        Ok(Nil) ->
          case artifacts.delete_artifact(conn, task_id, logical_name) {
            Error(_) -> helpers.error_response(500, "Failed to delete artifact")
            Ok(0) -> helpers.error_response(404, "Artifact not found")
            Ok(_) ->
              helpers.json_response(
                json.to_string(
                  json.object([
                    #("message", json.string("Artifact deleted")),
                  ]),
                ),
                200,
              )
          }
      }
  }
}

fn task_id_param(
  params: dict.Dict(String, String),
) -> Result(String, Response) {
  case dict.get(params, "task_id") {
    Ok(task_id) -> Ok(task_id)
    Error(_) -> Error(helpers.error_response(400, "Missing task ID"))
  }
}

fn logical_name_param(
  params: dict.Dict(String, String),
) -> Result(String, Response) {
  case dict.get(params, "logical_name") {
    Error(_) ->
      Error(helpers.error_response(400, "Missing artifact logical name"))
    Ok(encoded) ->
      case uri.percent_decode(encoded) {
        Ok(logical_name) -> Ok(logical_name)
        Error(_) ->
          Error(helpers.error_response(400, "Invalid artifact logical name"))
      }
  }
}

fn require_task(conn: DbConnection, task_id: String) -> Result(Nil, Response) {
  case tasks.task_exists(conn, task_id) {
    Error(_) -> Error(helpers.error_response(500, "Failed to find task"))
    Ok(False) -> Error(helpers.error_response(404, "Task not found"))
    Ok(True) -> Ok(Nil)
  }
}

fn content_decoder() -> decode.Decoder(json.Json) {
  use content <- decode.field("content", json_decoder())
  decode.success(content)
}

fn artifact_to_json(artifact: Artifact) -> json.Json {
  json.object([
    #("id", json.string(artifact.id)),
    #("task_id", json.string(artifact.task_id)),
    #("logical_name", json.string(artifact.logical_name)),
    #("content", artifact.content),
    #("created_at", json.int(artifact.created_at)),
    #("updated_at", json.int(artifact.updated_at)),
  ])
}
