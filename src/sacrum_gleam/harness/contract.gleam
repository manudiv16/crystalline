/// Provider-neutral execution contract for agent harness adapters.
///
/// This module defines the canonical types and interface that every agent
/// provider adapter (Claude, Codex, Gemini, ...) implements. The flow engine
/// and the step executor depend on **this module only**, never on a concrete
/// provider, so new providers can be added without touching orchestration
/// code.
///
/// A single invocation is described by a [`Request`] and produces a [`Result`]
/// carrying the agent output plus token/cost/timing metrics.
import gleam
import gleam/dict.{type Dict}
import gleam/float
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Execution request sent to an agent provider.
///
/// Contains all context needed for a single agent invocation.
pub type Request {
  Request(
    /// Working directory for the agent process
    cwd: String,
    /// The prompt/task to execute
    prompt: String,
    /// Primary model identifier (e.g. "claude-sonnet-4-20250514")
    model: String,
    /// Fallback model if the primary is unavailable
    fallback_model: Option(String),
    /// Optional system prompt to prepend
    system_prompt: Option(String),
    /// Explicitly allowed tools (empty = provider default)
    allowed_tools: List(String),
    /// Explicitly disallowed tools
    disallowed_tools: List(String),
    /// Permission mode: "bypassPermissions", "acceptEdits", "plan", ...
    permission_mode: String,
    /// Maximum budget in USD for this execution
    max_budget_usd: Float,
    /// Optional JSON Schema for structured output
    output_schema: Option(String),
  )
}

/// Execution result returned by an agent provider.
///
/// Captures the outcome, agent output, token usage, cost and timing.
pub type Result {
  Result(
    /// Execution status
    status: ResultStatus,
    /// Agent output (final text, or raw output for failures)
    output: String,
    /// Model actually used (may differ from requested if a fallback triggered)
    model_used: String,
    /// Input tokens consumed
    input_tokens: Int,
    /// Output tokens generated
    output_tokens: Int,
    /// Cost in USD
    cost: Float,
    /// Wall-clock duration in milliseconds
    duration_ms: Int,
    /// Provider session identifier for resumption/debugging
    session_id: Option(String),
    /// Error message when status is not Success
    error: Option(String),
  )
}

/// Possible execution statuses.
pub type ResultStatus {
  /// Completed successfully
  Success
  /// Completed with warnings (e.g. a non-fatal provider limit)
  Warning
  /// Failed due to provider error, timeout, budget exceeded, etc.
  Failed
  /// Cancelled by user or orchestrator
  Cancelled
}

/// Error type returned by adapter implementations.
pub type AdapterError {
  /// Provider binary not found or not executable
  NotFound(command: String)
  /// Provider process exited with a non-zero code
  ProcessError(code: Int, output: String)
  /// Request timed out
  Timeout(ms: Int)
  /// Budget exceeded before completion
  BudgetExceeded(limit: Float, spent: Float)
  /// Invalid request parameters
  InvalidRequest(reason: String)
  /// Provider returned malformed output
  ParseError(reason: String)
  /// I/O error (pipe, spawn, ...)
  IoError(reason: String)
  /// Generic provider error
  ProviderError(reason: String)
}

/// The adapter interface that each provider implements.
///
/// A provider exposes a single value of this type; register it in
/// `sacrum_gleam/harness/registry` to make it resolvable by name.
pub type Adapter {
  Adapter(
    /// Unique provider name (e.g. "claude", "codex", "gemini")
    name: String,
    /// Human-readable display name
    display_name: String,
    /// Execute a request and return its result
    run: fn(Request) -> gleam.Result(Result, AdapterError),
    /// Whether the provider is available (binary exists, auth configured, ...)
    is_available: fn() -> Bool,
    /// Provider version string, when it can be determined
    version: fn() -> Option(String),
  )
}

/// Execute a request using the given adapter.
pub fn run(
  adapter: Adapter,
  request: Request,
) -> gleam.Result(Result, AdapterError) {
  adapter.run(request)
}

/// Build a request with sensible defaults.
pub fn default_request(cwd: String, prompt: String, model: String) -> Request {
  Request(
    cwd: cwd,
    prompt: prompt,
    model: model,
    fallback_model: None,
    system_prompt: None,
    allowed_tools: [],
    disallowed_tools: [],
    permission_mode: "bypassPermissions",
    max_budget_usd: 5.0,
    output_schema: None,
  )
}

/// Build a request from a node's `AgentConfig`-style key/value map.
///
/// Recognised keys: `model`, `fallback_model`, `system_prompt`,
/// `allowed_tools`, `disallowed_tools`, `permission_mode`, `max_budget_usd`,
/// `output_schema`. Unknown keys are ignored.
pub fn request_from_agent_config(
  cwd: String,
  prompt: String,
  config: Dict(String, String),
) -> Request {
  Request(
    cwd: cwd,
    prompt: prompt,
    model: get(config, "model", "claude-sonnet-4-20250514"),
    fallback_model: get_option(config, "fallback_model"),
    system_prompt: get_option(config, "system_prompt"),
    allowed_tools: get_tools(config, "allowed_tools"),
    disallowed_tools: get_tools(config, "disallowed_tools"),
    permission_mode: get(config, "permission_mode", "bypassPermissions"),
    max_budget_usd: get_float(config, "max_budget_usd", 5.0),
    output_schema: get_option(config, "output_schema"),
  )
}

/// Human-readable rendering of a status, useful for logs and the DB layer.
pub fn status_to_string(status: ResultStatus) -> String {
  case status {
    Success -> "success"
    Warning -> "warning"
    Failed -> "failed"
    Cancelled -> "cancelled"
  }
}

/// Human-readable rendering of an adapter error.
pub fn error_to_string(error: AdapterError) -> String {
  case error {
    NotFound(command) -> "provider not found: " <> command
    ProcessError(code, output) ->
      "provider exited with code " <> string.inspect(code) <> ": " <> output
    Timeout(ms) -> "provider timed out after " <> string.inspect(ms) <> "ms"
    BudgetExceeded(limit, spent) ->
      "budget exceeded (limit "
      <> string.inspect(limit)
      <> ", spent "
      <> string.inspect(spent)
      <> ")"
    InvalidRequest(reason) -> "invalid request: " <> reason
    ParseError(reason) -> "could not parse provider output: " <> reason
    IoError(reason) -> "i/o error: " <> reason
    ProviderError(reason) -> "provider error: " <> reason
  }
}

// ─── Config helpers ─────────────────────────────────────────────────────────

fn get(config: Dict(String, String), key: String, default: String) -> String {
  case dict.get(config, key) {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

fn get_option(config: Dict(String, String), key: String) -> Option(String) {
  case dict.get(config, key) {
    Ok(value) if value != "" -> Some(value)
    _ -> None
  }
}

fn get_float(
  config: Dict(String, String),
  key: String,
  default: Float,
) -> Float {
  case dict.get(config, key) {
    Ok(value) -> float.parse(value) |> result_unwrap(default)
    Error(Nil) -> default
  }
}

fn get_tools(config: Dict(String, String), key: String) -> List(String) {
  case dict.get(config, key) {
    Ok(value) ->
      value
      |> string.split(",")
      |> list_filter_trim
    Error(Nil) -> []
  }
}

fn list_filter_trim(values: List(String)) -> List(String) {
  values
  |> list.filter(fn(value) { string.trim(value) != "" })
  |> list.map(string.trim)
}

fn result_unwrap(value: gleam.Result(a, b), default: a) -> a {
  case value {
    Ok(inner) -> inner
    Error(_) -> default
  }
}
