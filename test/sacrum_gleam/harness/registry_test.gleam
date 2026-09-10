import gleam/option.{None}
import gleeunit
import gleeunit/should
import sacrum_gleam/harness/contract
import sacrum_gleam/harness/registry

pub fn main() -> Nil {
  gleeunit.main()
}

/// A tiny stub adapter that never spawns a process, used to prove the
/// registry accepts and resolves third-party providers.
fn stub_adapter(name: String) -> contract.Adapter {
  contract.Adapter(
    name: name,
    display_name: "Stub " <> name,
    run: fn(_request) {
      Ok(contract.Result(
        status: contract.Success,
        output: "stub:" <> name,
        model_used: name,
        input_tokens: 1,
        output_tokens: 1,
        cost: 0.0,
        duration_ms: 1,
        session_id: None,
        error: None,
      ))
    },
    is_available: fn() { True },
    version: fn() { None },
  )
}

// Acceptance: registry.get("unknown") -> Error.
pub fn get_unknown_name_is_error_test() {
  let reg = registry.new()
  should.equal(
    registry.get(reg, "unknown"),
    Error(registry.UnknownAdapter("unknown")),
  )
}

pub fn get_unknown_renders_message_test() {
  let err = registry.UnknownAdapter("codex")
  should.equal(
    registry.registry_error_to_string(err),
    "unknown provider adapter: codex",
  )
}

// Acceptance: a default provider entry exists and resolves by name.
pub fn default_entry_resolves_by_name_test() {
  let reg = registry.new()
  case registry.get(reg, "claude") {
    Ok(adapter) -> {
      should.equal(adapter.name, "claude")
      should.equal(adapter.display_name, "Claude Code")
      should.be_true(adapter.is_available())
    }
    Error(_) -> should.fail()
  }
}

pub fn new_registry_lists_default_name_test() {
  should.equal(registry.names(registry.new()), ["claude"])
  should.equal(registry.default_name(registry.new()), "claude")
}

// Acceptance: new provider modules register and resolve.
pub fn registered_adapter_resolves_test() {
  let reg = registry.new() |> registry.register(stub_adapter("codex"))
  should.equal(registry.names(reg), ["claude", "codex"])

  case registry.get(reg, "codex") {
    Ok(adapter) -> should.equal(adapter.display_name, "Stub codex")
    Error(_) -> should.fail()
  }
}

pub fn registering_same_name_replaces_entry_test() {
  let reg = registry.new() |> registry.register(stub_adapter("claude"))

  case registry.get(reg, "claude") {
    Ok(adapter) -> should.equal(adapter.display_name, "Stub claude")
    Error(_) -> should.fail()
  }
}

pub fn registry_run_dispatches_to_adapter_test() {
  let reg = registry.new() |> registry.register(stub_adapter("codex"))
  let req = contract.default_request("/tmp", "hi", "codex")

  case registry.run(reg, "codex", req) {
    Ok(result) -> {
      should.equal(result.status, contract.Success)
      should.equal(result.output, "stub:codex")
      should.equal(result.model_used, "codex")
    }
    Error(_) -> should.fail()
  }
}

pub fn registry_run_unknown_name_is_error_test() {
  let reg = registry.new()
  let req = contract.default_request("/tmp", "hi", "whatever")

  case registry.run(reg, "unknown", req) {
    Error(registry.UnknownAdapter("unknown")) -> Nil
    _ -> should.fail()
  }
}

// contract.run adopts the adapter's run for the acceptance path:
// run(adapter, request) -> tokens/cost/output.
pub fn contract_run_adopts_adapter_test() {
  let req = contract.default_request("/tmp", "hi", "codex")
  case contract.run(stub_adapter("codex"), req) {
    Ok(result) -> {
      should.equal(result.output, "stub:codex")
      should.equal(result.input_tokens, 1)
      should.equal(result.cost, 0.0)
    }
    Error(_) -> should.fail()
  }
}
