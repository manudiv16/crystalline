import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import sacrum_gleam/db/connection

pub fn main() -> Nil {
  gleeunit.main()
}

// ─── URL classification ──────────────────────────────────────────────────

pub fn classifies_remote_urls_test() {
  "libsql://acme.turso.io" |> connection.is_remote_url |> should.be_true
  "https://acme.turso.io" |> connection.is_remote_url |> should.be_true
  "http://acme.turso.io" |> connection.is_remote_url |> should.be_true
  "wss://acme.turso.io" |> connection.is_remote_url |> should.be_true
}

pub fn classifies_local_urls_test() {
  "file:crystalline.db" |> connection.is_remote_url |> should.be_false
  ":memory:" |> connection.is_remote_url |> should.be_false
  "crystalline.db" |> connection.is_remote_url |> should.be_false
}

// ─── connect fail-fast (no network needed) ───────────────────────────────

/// A remote URL without a token fails fast with a ConnectionError instead of
/// attempting a network handshake and surfacing a low-level libsql error.
pub fn remote_url_without_token_fails_fast_test() {
  let assert Error(error) = connection.connect("libsql://acme.turso.io", None)

  case error {
    connection.ConnectionError(message) -> {
      message
      |> should.equal(
        "remote database URL 'libsql://acme.turso.io' requires an auth token; "
        <> "pass one to `connect` or set CRYSTALLINE_AUTH_TOKEN",
      )
      Nil
    }
    _ -> should.fail()
  }
}

/// A remote URL with a token is routed to open_remote (connection attempt).
/// The URL uses the reserved `.invalid` TLD, which is guaranteed to not
/// resolve, so the error must come from libsql itself — not our fail-fast
/// guard.
pub fn remote_url_with_token_attempts_connection_test() {
  let result = connection.connect("libsql://nonexistent.invalid", Some("token"))

  // The fail-fast guard must NOT trigger: this is a real open_remote attempt
  // against an unresolvable host. Both outcomes prove the token was used.
  case result {
    Error(connection.ConnectionError(message)) -> {
      let failed_fast = string.contains(message, "requires an auth token")
      failed_fast |> should.be_false
    }
    _ -> Nil
  }
}

/// Local in-memory connect works with no token.
pub fn local_memory_connect_succeeds_test() {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok(_) = connection.execute(conn, "SELECT 1", [])
  connection.close(conn)
  Nil
}

/// Local file connect (bare path) works with no token. Uses a throwaway
/// database in the build directory to avoid polluting the repo.
pub fn local_file_connect_succeeds_test() {
  let assert Ok(conn) =
    connection.connect("file:/tmp/crystalline-test-connect.db", None)
  connection.close(conn)
  Nil
}
