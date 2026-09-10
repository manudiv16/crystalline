import envoy
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import sacrum_gleam/config

pub fn main() -> Nil {
  gleeunit.main()
}

/// Run `func` with a clean Crystalline database environment, then restore the
/// caller's environment afterwards so tests do not leak into each other.
fn with_clean_env(func: fn() -> Nil) -> Nil {
  let saved = #(
    envoy.get("CRYSTALLINE_DB_URL"),
    envoy.get("CRYSTALLINE_AUTH_TOKEN"),
    envoy.get("CRYSTALLINE_DB"),
  )

  clear_env()
  func()

  // Restore whatever was there before this test ran.
  restore(saved)
}

fn clear_env() -> Nil {
  envoy.unset("CRYSTALLINE_DB_URL")
  envoy.unset("CRYSTALLINE_AUTH_TOKEN")
  envoy.unset("CRYSTALLINE_DB")
}

fn restore(
  saved: #(Result(String, Nil), Result(String, Nil), Result(String, Nil)),
) -> Nil {
  let #(url, token, db) = saved
  case url {
    Ok(value) -> envoy.set("CRYSTALLINE_DB_URL", value)
    Error(_) -> envoy.unset("CRYSTALLINE_DB_URL")
  }
  case token {
    Ok(value) -> envoy.set("CRYSTALLINE_AUTH_TOKEN", value)
    Error(_) -> envoy.unset("CRYSTALLINE_AUTH_TOKEN")
  }
  case db {
    Ok(value) -> envoy.set("CRYSTALLINE_DB", value)
    Error(_) -> envoy.unset("CRYSTALLINE_DB")
  }
}

// ─── Resolution tests ────────────────────────────────────────────────────

/// No environment at all: local mode against the default file.
pub fn no_env_defaults_to_local_file_test() {
  with_clean_env(fn() {
    let assert Ok(cfg) = config.resolve_db_config()

    cfg.mode |> should.equal(config.Local)
    cfg.auth_token |> should.equal(None)
    cfg.url |> should.equal("file:crystalline.db")
  })
}

/// `CRYSTALLINE_DB` alone picks a local file/memory database.
pub fn crystaline_db_env_selects_local_test() {
  with_clean_env(fn() {
    envoy.set("CRYSTALLINE_DB", ":memory:")

    let assert Ok(cfg) = config.resolve_db_config()

    cfg.mode |> should.equal(config.Local)
    cfg.auth_token |> should.equal(None)
    cfg.url |> should.equal(":memory:")
  })
}

/// URL + token selects remote mode and carries the token.
pub fn url_and_token_select_remote_test() {
  with_clean_env(fn() {
    envoy.set("CRYSTALLINE_DB_URL", "libsql://acme.turso.io")
    envoy.set("CRYSTALLINE_AUTH_TOKEN", "secret-token")

    let assert Ok(cfg) = config.resolve_db_config()

    cfg.mode |> should.equal(config.Remote)
    cfg.auth_token |> should.equal(Some("secret-token"))
    cfg.url |> should.equal("libsql://acme.turso.io")
  })
}

/// A remote URL without a token fails fast with MissingAuthToken.
pub fn remote_url_without_token_fails_fast_test() {
  with_clean_env(fn() {
    envoy.set("CRYSTALLINE_DB_URL", "libsql://acme.turso.io")

    let assert Error(error) = config.resolve_db_config()

    case error {
      config.MissingAuthToken(url) ->
        url |> should.equal("libsql://acme.turso.io")
    }
  })
}

/// An explicitly empty token is treated as missing: fail fast.
pub fn empty_token_fails_fast_test() {
  with_clean_env(fn() {
    envoy.set("CRYSTALLINE_DB_URL", "https://acme.turso.io")
    envoy.set("CRYSTALLINE_AUTH_TOKEN", "")

    let assert Error(config.MissingAuthToken(_)) = config.resolve_db_config()
    Nil
  })
}

/// URL + token wins over CRYSTALLINE_DB (order matters).
pub fn remote_wins_over_crystal_line_db_test() {
  with_clean_env(fn() {
    envoy.set("CRYSTALLINE_DB_URL", "libsql://acme.turso.io")
    envoy.set("CRYSTALLINE_AUTH_TOKEN", "secret-token")
    envoy.set("CRYSTALLINE_DB", ":memory:")

    let assert Ok(cfg) = config.resolve_db_config()

    cfg.mode |> should.equal(config.Remote)
    cfg.url |> should.equal("libsql://acme.turso.io")
  })
}

// ─── Mode rendering ──────────────────────────────────────────────────────

pub fn mode_to_string_renders_health_values_test() {
  config.Local |> config.mode_to_string |> should.equal("local")
  config.Remote |> config.mode_to_string |> should.equal("remote")
}
