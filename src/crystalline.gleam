/// Crystalline application entrypoint.
///
/// Configures the HTTP server from the environment and blocks forever
/// while the Mist supervision tree serves requests.
import envoy
import gleam/erlang/process
import gleam/int
import sacrum_gleam/http/server

/// Port used when the `PORT` environment variable is absent or invalid.
pub const default_port = 4920

pub fn main() -> Nil {
  server.start(parse_port())
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
