import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import sacrum_gleam/harness/claude
import sacrum_gleam/harness/contract

pub fn main() -> Nil {
  gleeunit.main()
}

// The fake CLI is committed under test/support and invoked via an absolute
// path, injected with `adapter_with` (the same seam production code uses for
// the CRYSTALLINE_CLAUDE_BIN override).
fn fake_bin() -> String {
  getenv_or("PWD", ".")
  |> string.append("/test/support/fake_claude.sh")
}

fn request(prompt: String) -> contract.Request {
  contract.default_request("/tmp", prompt, "claude-sonnet-4-20250514")
}

pub fn success_result_carries_output_tokens_and_cost_test() {
  let adapter = claude.adapter_with(fake_bin())

  case adapter.run(request("write a test")) {
    Ok(result) -> {
      should.equal(result.status, contract.Success)
      should.equal(result.output, "PONG")
      should.equal(result.model_used, "claude-sonnet-4-20250514")
      should.equal(result.input_tokens, 42)
      should.equal(result.output_tokens, 7)
      should.equal(result.cost, 0.012345)
      should.equal(result.duration_ms, 321)
      should.equal(result.session_id, Some("fake-session-123"))
      should.equal(result.error, None)
    }
    Error(_) -> should.fail()
  }
}

pub fn error_event_maps_to_failed_test() {
  let adapter = claude.adapter_with(fake_bin())

  case adapter.run(request("error please")) {
    Ok(result) -> {
      should.equal(result.status, contract.Failed)
      should.equal(result.error, Some("agent failed"))
    }
    Error(_) -> should.fail()
  }
}

pub fn nonzero_exit_is_process_error_test() {
  let adapter = claude.adapter_with(fake_bin())

  case adapter.run(request("crash now")) {
    Error(contract.ProcessError(code, output)) -> {
      should.equal(code, 3)
      should.equal(output, "boom")
    }
    _ -> should.fail()
  }
}

pub fn missing_binary_is_not_found_test() {
  let adapter = claude.adapter_with("/nonexistent/claude-missing")

  case adapter.run(request("hi")) {
    Error(contract.NotFound(command)) ->
      should.equal(command, "/nonexistent/claude-missing")
    _ -> should.fail()
  }
}

pub fn no_result_event_falls_back_to_raw_output_test() {
  let adapter = claude.adapter_with(fake_bin())

  case adapter.run(request("raw output")) {
    Ok(result) -> {
      should.equal(result.status, contract.Warning)
      should.equal(result.output, "plain text output")
      should.equal(result.input_tokens, 0)
      should.equal(result.output_tokens, 0)
      should.equal(result.cost, 0.0)
      should.equal(result.session_id, None)
    }
    Error(_) -> should.fail()
  }
}

pub fn timeout_exceeds_wall_clock_budget_test() {
  // Shorten the wall-clock budget for this test; other tests never sleep, so
  // a parallel runner cannot observe the override. Restored immediately.
  let _ = putenv("CRYSTALLINE_CLAUDE_TIMEOUT_MS", "400")
  let adapter = claude.adapter_with(fake_bin())

  case adapter.run(request("slow down")) {
    Error(contract.Timeout(ms)) -> should.equal(ms, 400)
    _ -> should.fail()
  }

  let _ = putenv("CRYSTALLINE_CLAUDE_TIMEOUT_MS", "")
}

pub fn is_available_reflects_executable_test() {
  should.be_true(claude.adapter_with(fake_bin()).is_available())
  should.be_false(claude.adapter_with("/nonexistent/claude-missing").is_available())
}

pub fn version_reports_cli_version_test() {
  let adapter = claude.adapter_with(fake_bin())
  should.equal(adapter.version(), Some("9.9.9 (fake claude)"))
}

// The adapter name is stable regardless of the injected executable.
pub fn adapter_name_is_claude_test() {
  should.equal(claude.adapter().name, "claude")
  should.equal(claude.adapter_with("/some/other/bin").name, "claude")
}

@external(erlang, "sacrum_gleam_harness_port", "getenv_or")
fn getenv_or(name: String, default: String) -> String

@external(erlang, "sacrum_gleam_harness_port", "putenv")
fn putenv(name: String, value: String) -> String
