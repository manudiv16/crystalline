/// Configuration resolution for Crystalline database connections.
///
/// ## Resolution order
/// 1. `CRYSTALLINE_DB_URL` + `CRYSTALLINE_AUTH_TOKEN` (remote mode)
/// 2. `CRYSTALLINE_DB` (local file path or `:memory:`)
/// 3. `file:crystalline.db` (default local)
///
/// When a remote URL is configured without an auth token, the application
/// fails fast with a clear error message instead of starting an unusable
/// database connection.
import envoy
import gleam/option.{type Option, None, Some}

/// Configuration for connecting to the database.
pub type DbConfig {
  DbConfig(
    /// The database URL or file path.
    url: String,
    /// Auth token for remote connections. `None` for local mode.
    auth_token: Option(String),
    /// Whether this is a remote (Turso) or local connection.
    mode: DbMode,
  )
}

pub type DbMode {
  Local
  Remote
}

/// Configuration errors resolved from environment variables.
pub type ConfigError {
  /// A remote URL was set but the auth token is missing.
  MissingAuthToken(url: String)
}

/// Local database used when no environment variable is set. The file is
/// created next to the working directory when Crystalline first runs.
pub const default_db_url = "file:crystalline.db"

/// Read the database configuration from environment variables.
///
/// Resolution order:
/// 1. `CRYSTALLINE_DB_URL` + `CRYSTALLINE_AUTH_TOKEN`
/// 2. `CRYSTALLINE_DB`
/// 3. `file:crystalline.db` (default)
pub fn resolve_db_config() -> Result(DbConfig, ConfigError) {
  case envoy.get("CRYSTALLINE_DB_URL") {
    Ok(remote_url) ->
      // Remote URL is set — require the auth token.
      //
      // envoy returns the raw value, so an explicitly empty token is
      // treated the same as a missing one: fail fast.
      case envoy.get("CRYSTALLINE_AUTH_TOKEN") {
        Ok(token) if token != "" ->
          Ok(DbConfig(url: remote_url, auth_token: Some(token), mode: Remote))
        _ -> Error(MissingAuthToken(url: remote_url))
      }
    Error(_) -> {
      // No remote URL — local mode.
      let local_url = case envoy.get("CRYSTALLINE_DB") {
        Ok(path) if path != "" -> path
        _ -> default_db_url
      }
      Ok(DbConfig(url: local_url, auth_token: None, mode: Local))
    }
  }
}

/// Convert a ConfigError to a human-readable string.
pub fn config_error_to_string(error: ConfigError) -> String {
  case error {
    MissingAuthToken(url: url) ->
      "missing auth token for remote database: CRYSTALLINE_DB_URL="
      <> url
      <> " is set but CRYSTALLINE_AUTH_TOKEN is not set. "
      <> "Set CRYSTALLINE_AUTH_TOKEN to connect to a remote database."
  }
}

/// Convert DbMode to a string for the health endpoint.
///
/// The mode is intentionally disconnected from the auth token: `/health`
/// reports `local` or `remote`, never the token itself.
pub fn mode_to_string(mode: DbMode) -> String {
  case mode {
    Local -> "local"
    Remote -> "remote"
  }
}
