//// Claude Code provider adapter for the C9 harness contract.
////
//// This module implements [`contract.Adapter`] for the `claude` CLI
//// (Claude Code). It spawns the CLI in print mode (`-p`), feeds the prompt as
//// an argument, requests a single trailing JSON result event
//// (`--output-format json`) and decodes the output, token usage, cost,
//// duration and session id from it.
////
//// Request fields map to CLI flags as follows:
////
//// - `prompt`           -> `-p <prompt>`
//// - `model`            -> `--model <model>`
//// - `fallback_model`   -> `--fallback-model <model>`
//// - `system_prompt`    -> `--system-prompt <prompt>`
//// - `allowed_tools`    -> `--allowedTools a,b,...`
//// - `disallowed_tools` -> `--disallowedTools a,b,...`
//// - `permission_mode`  -> `--permission-mode <mode>`
//// - `max_budget_usd`   -> `--max-budget-usd <usd>`
//// - `output_schema`    -> `--json-schema <schema>` (CLI >= 2.1)
//// - `cwd`              -> launch directory (the CLI has no `--cwd` flag)
////
//// The executable defaults to `claude` (resolved through `PATH`) and can be
//// overridden for tests with the `CRYSTALLINE_CLAUDE_BIN` environment
//// variable or by building an adapter with [`adapter_with`]. The wall-clock
//// budget defaults to [`default_timeout_ms`] and can be shortened with
//// `CRYSTALLINE_CLAUDE_TIMEOUT_MS`.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sacrum_gleam/harness/contract

/// Default wall-clock budget for a single invocation: 30 minutes.
pub const default_timeout_ms: Int = 1_800_000

/// Build the adapter using the executable resolved from the environment
/// (`CRYSTALLINE_CLAUDE_BIN`, falling back to `claude`).
pub fn adapter() -> contract.Adapter {
  adapter_with(command_bin())
}

/// Build the adapter for an explicit executable path. `executable` is passed
/// to `os:find_executable/1`, so a plain name is resolved through `PATH` and
/// an absolute path is used directly. Tests inject a fake CLI this way.
pub fn adapter_with(executable: String) -> contract.Adapter {
  contract.Adapter(
    name: "claude",
    display_name: "Claude Code",
    run: run_with(executable),
    is_available: fn() { find_executable(executable) == "1" },
    version: version_with(executable),
  )
}

// ─── Execution ───────────────────────────────────────────────────────────

fn run_with(
  executable: String,
) -> fn(contract.Request) -> Result(contract.Result, contract.AdapterError) {
  fn(request: contract.Request) {
    case find_executable(executable) {
      "0" -> Error(contract.NotFound(executable))
      _ -> {
        let started_at = now_ms()
        let timeout = timeout_ms()
        let raw =
          spawn_and_collect(
            request.cwd,
            executable,
            build_args(request),
            timeout,
          )
        case parse_outcome(raw) {
          Error(_) ->
            Error(contract.ProviderError("harness bridge returned garbage"))
          Ok(outcome) if !outcome.ok ->
            case outcome.reason {
              "not_found" -> Error(contract.NotFound(executable))
              "timeout" -> Error(contract.Timeout(timeout))
              _ ->
                Error(contract.ProcessError(
                  outcome.status,
                  string.trim(outcome.output),
                ))
            }
          Ok(outcome) ->
            case outcome.status {
              0 -> build_result(request, outcome.output, now_ms() - started_at)
              code ->
                Error(contract.ProcessError(code, string.trim(outcome.output)))
            }
        }
      }
    }
  }
}

fn build_args(request: contract.Request) -> List(String) {
  let args = [
    "-p",
    request.prompt,
    "--output-format",
    "json",
    "--model",
    request.model,
    "--permission-mode",
    request.permission_mode,
    "--max-budget-usd",
    float.to_string(request.max_budget_usd),
  ]
  let args = case request.fallback_model {
    Some(model) -> list.append(args, ["--fallback-model", model])
    None -> args
  }
  let args = case request.system_prompt {
    Some(prompt) -> list.append(args, ["--system-prompt", prompt])
    None -> args
  }
  let args = case request.allowed_tools {
    [] -> args
    tools -> list.append(args, ["--allowedTools", string.join(tools, ",")])
  }
  let args = case request.disallowed_tools {
    [] -> args
    tools -> list.append(args, ["--disallowedTools", string.join(tools, ",")])
  }
  case request.output_schema {
    Some(schema) -> list.append(args, ["--json-schema", schema])
    None -> args
  }
}

/// Decode the trailing `result` JSON event emitted by `claude -p
/// --output-format json`. When no event is found (older CLI, degraded output)
/// the whole output is carried as the result with zeroed usage metrics and a
/// `Warning` status.
fn build_result(
  request: contract.Request,
  output: String,
  elapsed_ms: Int,
) -> Result(contract.Result, contract.AdapterError) {
  case find_result_event(output) {
    Error(_) ->
      Ok(contract.Result(
        status: contract.Warning,
        output: string.trim(output),
        model_used: request.model,
        input_tokens: 0,
        output_tokens: 0,
        cost: 0.0,
        duration_ms: elapsed_ms,
        session_id: None,
        error: None,
      ))
    Ok(event) -> {
      let duration = case event.duration_ms {
        0 -> elapsed_ms
        n -> n
      }
      let status = case event.is_error {
        True -> contract.Failed
        False -> contract.Success
      }
      let error = case status {
        contract.Failed ->
          Some(case event.text {
            "" -> "agent reported an error"
            text -> text
          })
        _ -> None
      }
      Ok(contract.Result(
        status: status,
        output: event.text,
        model_used: request.model,
        input_tokens: event.input_tokens,
        output_tokens: event.output_tokens,
        cost: event.cost,
        duration_ms: duration,
        session_id: event.session_id,
        error: error,
      ))
    }
  }
}

fn find_result_event(output: String) -> Result(Event, Nil) {
  find_in_lines(string.split(output, "\n"))
}

fn find_in_lines(lines: List(String)) -> Result(Event, Nil) {
  case lines {
    [] -> Error(Nil)
    [line, ..rest] ->
      case parse_event(line) {
        Ok(event) if event.kind == "result" -> Ok(event)
        _ -> find_in_lines(rest)
      }
  }
}

fn parse_event(line: String) -> Result(Event, Nil) {
  case string.trim(line) {
    "" -> Error(Nil)
    trimmed ->
      case json.parse(trimmed, decode.dynamic) {
        Error(_) -> Error(Nil)
        Ok(dynamic) -> event_from_dynamic(dynamic)
      }
  }
}

// ─── Version / availability ──────────────────────────────────────────────

fn version_with(executable: String) -> fn() -> Option(String) {
  fn() {
    let raw = spawn_and_collect("", executable, ["--version"], 5000)
    case parse_outcome(raw) {
      Ok(outcome) if outcome.ok && outcome.status == 0 ->
        case
          list.first(
            list.filter(outcome.output |> string.split("\n"), fn(line) {
              line != ""
            }),
          )
        {
          Ok(line) -> Some(line)
          Error(_) -> None
        }
      _ -> None
    }
  }
}

// ─── Bridge protocol ─────────────────────────────────────────────────────

type Outcome {
  Outcome(ok: Bool, status: Int, reason: String, output: String)
}

fn parse_outcome(raw: String) -> Result(Outcome, Nil) {
  case json.parse(raw, decode.dynamic) {
    Error(_) -> Error(Nil)
    Ok(dynamic) -> outcome_from_dynamic(dynamic)
  }
}

fn outcome_from_dynamic(data: Dynamic) -> Result(Outcome, Nil) {
  case decode.run(data, decode.at(["ok"], decode.bool)) {
    Error(_) -> Error(Nil)
    Ok(ok) ->
      Ok(Outcome(
        ok: ok,
        status: field(data, ["status"], -1, decode.int),
        reason: field(data, ["reason"], "", decode.string),
        output: field(data, ["output"], "", decode.string),
      ))
  }
}

// ─── Result event decoding ───────────────────────────────────────────────

type Event {
  Event(
    kind: String,
    text: String,
    session_id: Option(String),
    cost: Float,
    input_tokens: Int,
    output_tokens: Int,
    duration_ms: Int,
    is_error: Bool,
  )
}

fn event_from_dynamic(data: Dynamic) -> Result(Event, Nil) {
  case decode.run(data, decode.at(["type"], decode.string)) {
    Error(_) -> Error(Nil)
    Ok(kind) ->
      Ok(Event(
        kind: kind,
        text: field(data, ["result"], "", decode.string),
        session_id: field(
          data,
          ["session_id"],
          None,
          decode.optional(decode.string),
        ),
        cost: field(data, ["total_cost_usd"], 0.0, decode.float),
        input_tokens: field(data, ["usage", "input_tokens"], 0, decode.int),
        output_tokens: field(data, ["usage", "output_tokens"], 0, decode.int),
        duration_ms: field(data, ["duration_ms"], 0, decode.int),
        is_error: field(data, ["is_error"], False, decode.bool),
      ))
  }
}

/// Extract a field at `path`, falling back to `default` when it is missing or
/// has the wrong type. `decode.optionally_at` never fails, so this helper is
/// total.
fn field(
  data: Dynamic,
  path: List(a),
  default: t,
  decoder: decode.Decoder(t),
) -> t {
  case decode.run(data, decode.optionally_at(path, default, decoder)) {
    Ok(value) -> value
    Error(_) -> default
  }
}

// ─── Configuration ───────────────────────────────────────────────────────

fn command_bin() -> String {
  case getenv_or("CRYSTALLINE_CLAUDE_BIN", "") {
    "" -> "claude"
    bin -> bin
  }
}

fn timeout_ms() -> Int {
  case int.parse(getenv_or("CRYSTALLINE_CLAUDE_TIMEOUT_MS", "")) {
    Ok(ms) if ms > 0 -> ms
    _ -> default_timeout_ms
  }
}

/// Current wall clock in milliseconds (native Erlang time unit / 1000000).
pub fn now_ms() -> Int {
  erlang_system_time() / 1_000_000
}

@external(erlang, "erlang", "system_time")
fn erlang_system_time() -> Int

// ─── Native bridge ───────────────────────────────────────────────────────

@external(erlang, "sacrum_gleam_harness_port", "spawn_and_collect")
fn spawn_and_collect(
  cwd: String,
  executable: String,
  args: List(String),
  timeout_ms: Int,
) -> String

@external(erlang, "sacrum_gleam_harness_port", "find_executable")
fn find_executable(executable: String) -> String

@external(erlang, "sacrum_gleam_harness_port", "getenv_or")
fn getenv_or(name: String, default: String) -> String
