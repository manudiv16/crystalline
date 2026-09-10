import gleam/json
import wisp

// Helper to create JSON responses
pub fn json_response(data: String, status: Int) -> wisp.Response {
  wisp.json_response(data, status)
}

// Helper to create error responses
pub fn error_response(status: Int, message: String) -> wisp.Response {
  let error_json = json.object([#("error", json.string(message))])
  json_response(json.to_string(error_json), status)
}
