//// Background polling loop for persisted flow executions.
////
//// Each poll claims at most one pending or running execution, rehydrates its
//// state, and drives the runtime until it waits or finishes. The production
//// starter opens a database connection separate from the HTTP server's.

import envoy
import gleam/erlang/process
import gleam/erlang/reference
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sacrum_gleam/config
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/db/executions
import sacrum_gleam/db/flows
import sacrum_gleam/db/migrations
import sacrum_gleam/db/session_logs
import sacrum_gleam/domain/execution.{
  type ExecutionState, ExecutionState, Failed, Pending, StepExecution,
  StepFailed,
}
import sacrum_gleam/flow/engine as flow_engine
import sacrum_gleam/flow/executor as flow_executor
import sacrum_gleam/harness/contract
import sacrum_gleam/harness/registry
import sacrum_gleam/runtime/executor as runtime
import sacrum_gleam/runtime/store

/// Poll interval used by the production daemon.
pub const default_poll_interval_ms = 1000

/// Maximum time a dead daemon's claim blocks another poller.
pub const default_claim_lease_ms = 3_600_000

/// Outcomes of one synchronous poll.
pub type PollOutcome {
  Idle
  Processed(
    instance_id: String,
    result: Result(ExecutionState, runtime.RuntimeError),
  )
}

/// Startup failures are returned to the application entry point.
pub type DaemonError {
  ConfigurationFailure(message: String)
  ConnectionFailure(message: String)
  MigrationFailure(message: String)
  DatabaseFailure(message: String)
  FlowFailure(message: String)
  StartupTimeout
}

/// Opaque handle used to tick or stop the unlinked daemon process.
pub opaque type Daemon {
  Daemon(pid: process.Pid, subject: process.Subject(DaemonMessage))
}

type DaemonMessage {
  Tick
  Stop
}

type StartedMessage {
  Started(subject: process.Subject(DaemonMessage))
}

/// Start the production daemon unless `CRYSTALLINE_DAEMON=0`.
///
/// The default is enabled. The daemon resolves the same database configuration
/// as the server, opens its own connection, and applies pending migrations.
pub fn start(project_root: String) -> Result(Option(Daemon), DaemonError) {
  case envoy.get("CRYSTALLINE_DAEMON") {
    Ok("0") -> Ok(None)
    _ -> {
      use db_config <- result.try(
        config.resolve_db_config()
        |> result.map_error(fn(error) {
          ConfigurationFailure(config.config_error_to_string(error))
        }),
      )
      use conn <- result.try(
        connection.connect(db_config.url, db_config.auth_token)
        |> result.map_error(fn(error) {
          ConnectionFailure(connection.error_to_string(error))
        }),
      )
      case migrations.run_migrations(conn) {
        Error(error) -> {
          connection.close(conn)
          Error(MigrationFailure(migration_error_to_string(error)))
        }
        Ok(_) -> {
          let provider_registry = registry.new()
          let harness = registry_harness(provider_registry)
          start_with_connection(
            conn,
            harness,
            project_root,
            default_poll_interval_ms,
          )
          |> result.map(Some)
        }
      }
    }
  }
}

/// Start the actor around an already-open daemon-owned connection.
///
/// Production calls this only with the separate connection opened by
/// `start`; tests use a second connection to a shared temporary file database.
pub fn start_with_connection(
  conn: DbConnection,
  harness: runtime.Harness,
  project_root: String,
  poll_interval_ms: Int,
) -> Result(Daemon, DaemonError) {
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      process.send(ready, Started(subject))
      actor_loop(
        conn,
        harness,
        project_root,
        owner_id(),
        normalized_interval(poll_interval_ms),
        subject,
      )
    })

  case process.receive(ready, within: 5000) {
    Ok(Started(subject)) -> Ok(Daemon(pid: pid, subject: subject))
    Error(_) -> Error(StartupTimeout)
  }
}

/// Ask the daemon to poll immediately.
pub fn tick(daemon: Daemon) -> Nil {
  process.send(daemon.subject, Tick)
}

/// Stop the daemon after any currently running poll returns.
pub fn stop(daemon: Daemon) -> Nil {
  process.send(daemon.subject, Stop)
}

/// Whether the daemon actor process is still alive.
pub fn is_alive(daemon: Daemon) -> Bool {
  process.is_alive(daemon.pid)
}

/// Claim and drive one unit of work synchronously, releasing the claim before
/// returning even when the runtime reports a harness or persistence failure.
pub fn poll_once(
  conn: DbConnection,
  harness: runtime.Harness,
  project_root: String,
) -> Result(PollOutcome, DaemonError) {
  poll_once_as(conn, harness, project_root, owner_id())
}

fn actor_loop(
  conn: DbConnection,
  harness: runtime.Harness,
  project_root: String,
  owner: String,
  poll_interval_ms: Int,
  subject: process.Subject(DaemonMessage),
) -> Nil {
  case process.receive(subject, within: poll_interval_ms) {
    Ok(Stop) -> connection.close(conn)
    Ok(Tick) -> {
      poll_and_report(conn, harness, project_root, owner)
      actor_loop(conn, harness, project_root, owner, poll_interval_ms, subject)
    }
    Error(_) -> {
      poll_and_report(conn, harness, project_root, owner)
      actor_loop(conn, harness, project_root, owner, poll_interval_ms, subject)
    }
  }
}

fn poll_and_report(
  conn: DbConnection,
  harness: runtime.Harness,
  project_root: String,
  owner: String,
) -> Nil {
  case poll_once_as(conn, harness, project_root, owner) {
    Error(error) ->
      io.println("Background executor poll failed: " <> error_to_string(error))
    Ok(Processed(instance_id, Error(error))) ->
      io.println(
        "Background execution "
        <> instance_id
        <> " failed: "
        <> runtime.error_to_string(error),
      )
    Ok(_) -> Nil
  }
}

fn poll_once_as(
  conn: DbConnection,
  harness: runtime.Harness,
  project_root: String,
  owner: String,
) -> Result(PollOutcome, DaemonError) {
  use claim <- result.try(
    executions.claim_execution(
      conn,
      owner,
      runtime.system_time_ms(),
      default_claim_lease_ms,
    )
    |> result.map_error(database_failure),
  )

  case claim {
    None -> Ok(Idle)
    Some(state) -> {
      let run_result = drive_claimed(conn, state, harness, project_root)
      case executions.release_claim(conn, state.id, owner) {
        Error(error) -> Error(database_failure(error))
        Ok(_) -> Ok(Processed(state.flow_instance.id, run_result))
      }
    }
  }
}

fn drive_claimed(
  conn: DbConnection,
  state: ExecutionState,
  harness: runtime.Harness,
  project_root: String,
) -> Result(ExecutionState, runtime.RuntimeError) {
  let run_result = case restore_flow_engine(conn, state) {
    Error(message) -> Error(runtime.GraphError(message))
    Ok(flow) -> {
      let engine =
        runtime.new_engine(flow, harness, store.new_store(), project_root)
      runtime.run_until_wait(conn, engine, state.flow_instance.id)
    }
  }

  case run_result {
    Ok(final_state) -> Ok(final_state)
    Error(error) -> {
      case record_failed_claim(conn, state, runtime.error_to_string(error)) {
        Ok(_) -> Error(error)
        Error(persistence_error) -> Error(persistence_error)
      }
    }
  }
}

fn restore_flow_engine(
  conn: DbConnection,
  state: ExecutionState,
) -> Result(flow_engine.Engine, String) {
  use templates <- result.try(
    flows.list_flow_templates(conn)
    |> result.map_error(fn(error) { connection.error_to_string(error) }),
  )
  let engine =
    list.fold(templates, flow_engine.new_engine(), fn(engine, template) {
      flow_engine.restore_template(engine, template)
    })

  let state = case state.status {
    Pending -> {
      let started = flow_executor.start(state.flow_instance, state.task_id)
      ExecutionState(
        ..started,
        id: state.id,
        step_history: state.step_history,
        variables: state.variables,
        loop_counters: state.loop_counters,
        parallel_active: state.parallel_active,
      )
    }
    _ -> state
  }

  Ok(flow_engine.restore_execution(engine, state))
}

fn record_failed_claim(
  conn: DbConnection,
  original_state: ExecutionState,
  reason: String,
) -> Result(Nil, runtime.RuntimeError) {
  let now = runtime.system_time_ms()
  let production_store = store.new_store()
  use has_error_log <- result.try(
    session_logs.has_error_log_for_instance(
      conn,
      original_state.flow_instance.id,
    )
    |> result.map_error(runtime_persistence_failure),
  )
  use latest_state <- result.try(
    executions.get_execution_by_instance(conn, original_state.flow_instance.id)
    |> result.map_error(runtime_persistence_failure),
  )
  let failed_state =
    ExecutionState(..latest_state, status: Failed, completed_at: Some(now))

  case has_error_log {
    True -> production_store.save_status(conn, failed_state, now)
    False -> {
      let node_id = case latest_state.current_node_id {
        Some(id) -> id
        None -> latest_state.flow_instance.initial_node_id
      }
      let step =
        StepExecution(
          id: "daemon-error-"
            <> latest_state.id
            <> "-"
            <> string.inspect(reference.new()),
          flow_instance_id: latest_state.flow_instance.id,
          execution_state_id: latest_state.id,
          node_id: node_id,
          task_id: latest_state.task_id,
          status: StepFailed,
          prompt: None,
          output: Some(reason),
          transition_result: None,
          model: None,
          input_tokens: 0,
          output_tokens: 0,
          cost: 0.0,
          duration_ms: 0,
          session_id: None,
          created_at: now,
          completed_at: Some(now),
        )
      use _ <- result.try(production_store.save_step(conn, step, now))
      use _ <- result.try(production_store.save_status(conn, failed_state, now))
      production_store.append_log(
        conn,
        step.id,
        latest_state.task_id,
        "error",
        reason,
        now,
      )
    }
  }
}

fn runtime_persistence_failure(
  error: connection.DbError,
) -> runtime.RuntimeError {
  runtime.PersistenceFailure(connection.error_to_string(error))
}

fn registry_harness(provider_registry: registry.Registry) -> runtime.Harness {
  fn(request: contract.Request) -> Result(
    contract.Result,
    contract.AdapterError,
  ) {
    case
      registry.run(
        provider_registry,
        registry.default_name(provider_registry),
        request,
      )
    {
      Ok(result) -> Ok(result)
      Error(registry.AdapterError(error)) -> Error(error)
      Error(error) ->
        Error(contract.ProviderError(registry.registry_error_to_string(error)))
    }
  }
}

/// Render a daemon startup or persistence failure for operator diagnostics.
pub fn error_to_string(error: DaemonError) -> String {
  case error {
    ConfigurationFailure(message) -> message
    ConnectionFailure(message) -> message
    MigrationFailure(message) -> message
    DatabaseFailure(message) -> message
    FlowFailure(message) -> message
    StartupTimeout -> "daemon actor did not start within 5000ms"
  }
}

fn owner_id() -> String {
  "crystalline-daemon-" <> string.inspect(process.self())
}

fn normalized_interval(interval_ms: Int) -> Int {
  case interval_ms > 0 {
    True -> interval_ms
    False -> default_poll_interval_ms
  }
}

fn database_failure(error: connection.DbError) -> DaemonError {
  DatabaseFailure(connection.error_to_string(error))
}

fn migration_error_to_string(error: migrations.MigrationError) -> String {
  case error {
    migrations.DbError(db_error) -> connection.error_to_string(db_error)
    migrations.AlreadyApplied(version) ->
      "migration already applied: " <> string.inspect(version)
    migrations.FailedAt(version, message) ->
      "migration failed at version "
      <> string.inspect(version)
      <> ": "
      <> message
  }
}
