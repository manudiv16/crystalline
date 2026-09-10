//// Provider registry for the C9 harness contract.
////
//// Maps adapter names (e.g. `"claude"`) to [`contract.Adapter`] values so
//// orchestration code can resolve a provider without importing a concrete
//// adapter module. [`new`] preloads the default provider (Claude Code);
//// additional adapters are added with [`register`].
////
//// Resolution rules:
////
//// - [`get`] prefers an explicit registration (including one that shadows the
////   default), then falls back to the default adapter when its name matches,
////   and returns [`Error`] with an [`UnknownAdapter`] for everything else
////   (e.g. `registry.get(reg, "unknown")`).

import gleam/dict.{type Dict}
import sacrum_gleam/harness/claude
import sacrum_gleam/harness/contract.{type Adapter}

/// A collection of named provider adapters plus the fallback default.
pub type Registry {
  Registry(adapters: Dict(String, Adapter), default: Adapter)
}

/// Errors produced when resolving or running an adapter from a registry.
pub type RegistryError {
  /// No adapter is registered under this name and it does not match the
  /// registry's default adapter name.
  UnknownAdapter(name: String)
  /// Resolving succeeded but the adapter itself failed to run.
  AdapterError(error: contract.AdapterError)
}

/// A registry preloaded with the default provider (`"claude"`).
pub fn new() -> Registry {
  let default = claude.adapter()
  Registry(
    adapters: dict.from_list([#(default.name, default)]),
    default: default,
  )
}

/// The default provider adapter (Claude Code). `new()` uses this as both the
/// initial entry and the fallback.
pub fn default_adapter() -> Adapter {
  claude.adapter()
}

/// Register an adapter, keyed by `adapter.name`. Registering under an
/// existing name replaces the previous entry.
pub fn register(registry: Registry, adapter: Adapter) -> Registry {
  Registry(
    ..registry,
    adapters: dict.insert(registry.adapters, adapter.name, adapter),
  )
}

/// Resolve an adapter by name.
///
/// An explicit registration wins; a missing key falls back to the default
/// adapter when `name` equals the default's name; anything else is an
/// [`UnknownAdapter`] error.
pub fn get(registry: Registry, name: String) -> Result(Adapter, RegistryError) {
  case dict.get(registry.adapters, name) {
    Ok(adapter) -> Ok(adapter)
    Error(Nil) if name == registry.default.name -> Ok(registry.default)
    Error(Nil) -> Error(UnknownAdapter(name))
  }
}

/// All registered adapter names (including the default when present).
pub fn names(registry: Registry) -> List(String) {
  dict.keys(registry.adapters)
}

/// Human-readable rendering of a registry error.
pub fn registry_error_to_string(error: RegistryError) -> String {
  case error {
    UnknownAdapter(name) -> "unknown provider adapter: " <> name
    AdapterError(err) -> "adapter error: " <> contract.error_to_string(err)
  }
}

/// Convenience: resolve `name` and run the resulting adapter against
/// `request` in one step.
pub fn run(
  registry: Registry,
  name: String,
  request: contract.Request,
) -> Result(contract.Result, RegistryError) {
  case get(registry, name) {
    Ok(adapter) ->
      case adapter.run(request) {
        Ok(result) -> Ok(result)
        Error(err) -> Error(AdapterError(err))
      }
    Error(err) -> Error(err)
  }
}

/// Convenience returning the adapter's name for the registry's default.
pub fn default_name(registry: Registry) -> String {
  registry.default.name
}
