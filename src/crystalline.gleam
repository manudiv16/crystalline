/// Crystalline application entrypoint.
///
/// The background executor starts by default; set `CRYSTALLINE_DAEMON=0` to
/// disable it while keeping the HTTP server available.
import envoy
import gleam/erlang/process
import gleam/int
import sacrum_gleam/http/server
import sacrum_gleam/runtime/daemon

/// Port used when the `PORT` environment variable is absent or invalid.
pub const default_port = 4920

pub fn main() -> Nil {
  server.start(parse_port())
  case daemon.start(".") {
    Ok(_) -> Nil
    Error(error) ->
      panic as {
        "Failed to start execution daemon: " <> daemon.error_to_string(error)
      }
  }
  process.sleep_forever()
}

fn parse_port() -> Int {
  case envoy.get("PORT") {
    Ok(value) -> {
      case int.parse(value) {
        Ok(port) if port > 0 -> port
        _ -> default_port
      }
    }
    Error(_) -> default_port
  }
}
