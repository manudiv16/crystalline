//// Acceptance tests for production runtime persistence and daemon polling.
////
//// The store tests use an in-memory database. Daemon tests use two independent
//// connections to one temporary file because each `:memory:` connection has
//// private state; every test removes its database and temporary directory.

import envoy
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/db/executions
import sacrum_gleam/db/flows as db_flows
import sacrum_gleam/db/migrations
import sacrum_gleam/db/session_logs
import sacrum_gleam/db/tasks as db_tasks
import sacrum_gleam/domain/execution.{
  type ExecutionStatus, Completed, ExecutionState, Failed, Running,
  StepCompleted, StepExecution, StepFailed,
}
import sacrum_gleam/domain/flow
import sacrum_gleam/domain/task as task_domain
import sacrum_gleam/flow/engine as flow_engine
import sacrum_gleam/harness/contract
import sacrum_gleam/runtime/daemon
import sacrum_gleam/runtime/executor as runtime
import sacrum_gleam/runtime/store

pub fn main() -> Nil {
  gleeunit.main()
}

type Fixture {
  Fixture(
    task_id: String,
    instance_id: String,
    execution_id: String,
    node_id: String,
  )
}

type TempDatabase {
  TempDatabase(directory: String, path: String)
}

fn memory_connection() -> DbConnection {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok(_) = migrations.run_migrations(conn)
  conn
}

fn temp_database() -> TempDatabase {
  let directory =
    "/tmp/crystalline-runtime-daemon-" <> int.to_string(unique_integer())
  let _ = make_directory(directory)
  TempDatabase(directory: directory, path: directory <> "/runtime.sqlite")
}

fn file_connection(database: TempDatabase) -> DbConnection {
  let assert Ok(conn) = connection.connect("file:" <> database.path, None)
  conn
}

fn clean_temp_database(database: TempDatabase) -> Nil {
  let _ = delete_file(database.path)
  let _ = delete_file(database.path <> "-wal")
  let _ = delete_file(database.path <> "-shm")
  let _ = delete_directory(database.directory)
  Nil
}

fn seed_execution(
  conn: DbConnection,
  suffix: String,
  created_at: Int,
  worktree: Option(String),
) -> Fixture {
  let task_id = "task-" <> suffix
  let template_id = "template-" <> suffix
  let instance_id = "instance-" <> suffix
  let execution_id = "execution-" <> suffix
  let node_id = "step-" <> suffix
  let prompt = "prompt for " <> suffix

  let task =
    task_domain.Task(
      ..task_domain.new_task(
        "Task " <> suffix,
        task_domain.Ticket,
        task_domain.Medium,
      ),
      id: task_id,
      short_id: "short-" <> suffix,
      worktree: worktree,
      created_at: created_at,
      updated_at: created_at,
    )
  let assert Ok(_) = db_tasks.create_task(conn, task, created_at)

  let template =
    flow_engine.build_linear_flow("Flow " <> suffix, "daemon test", [
      #(node_id, prompt),
    ])
  let template = flow.FlowTemplate(..template, id: template_id)
  let assert Ok(_) = db_flows.create_flow_template(conn, template, created_at)

  let instance =
    flow.FlowInstance(
      id: instance_id,
      template_id: template_id,
      task_id: task_id,
      nodes: template.nodes,
      transitions: template.transitions,
      initial_node_id: template.initial_node_id,
      on_done_template_id: None,
      on_reject_template_id: None,
    )
  let assert Ok(_) = db_flows.create_flow_instance(conn, instance, created_at)

  let state = execution.new_execution_state(instance, task_id)
  let state = ExecutionState(..state, id: execution_id)
  let assert Ok(_) = executions.create_execution_state(conn, state, created_at)

  let assert Ok(_) =
    db_tasks.update_task(
      conn,
      task_id,
      db_tasks.TaskUpdates(
        title: None,
        description: None,
        priority: None,
        status: None,
        tags: None,
        worktree: None,
        flow_template_id: Some(template_id),
        flow_instance_id: Some(instance_id),
        current_node_id: None,
      ),
      created_at,
    )

  Fixture(task_id, instance_id, execution_id, node_id)
}

fn successful_harness() -> runtime.Harness {
  fn(request: contract.Request) -> Result(
    contract.Result,
    contract.AdapterError,
  ) {
    Ok(contract.Result(
      status: contract.Success,
      output: "stub output: " <> request.prompt,
      model_used: "stub-model-v1",
      input_tokens: 41,
      output_tokens: 17,
      cost: 0.025,
      duration_ms: 19,
      session_id: Some("stub-session"),
      error: None,
    ))
  }
}

fn counting_harness(key: String) -> runtime.Harness {
  let _ = process_dictionary_put(key, 0)
  fn(request: contract.Request) -> Result(
    contract.Result,
    contract.AdapterError,
  ) {
    let calls = process_dictionary_get(key)
    let _ = process_dictionary_put(key, calls + 1)
    let success = successful_harness()
    success(request)
  }
}

fn failing_harness(key: String) -> runtime.Harness {
  let _ = process_dictionary_put(key, 0)
  fn(_request: contract.Request) -> Result(
    contract.Result,
    contract.AdapterError,
  ) {
    let calls = process_dictionary_get(key)
    let _ = process_dictionary_put(key, calls + 1)
    Error(contract.ProcessError(7, "stub process failure"))
  }
}

fn call_count(key: String) -> Int {
  process_dictionary_get(key)
}

pub fn production_store_persists_state_steps_logs_and_workdirs_test() {
  let conn = memory_connection()
  let task =
    seed_execution(conn, "store-worktree", 100, Some("/tasks/worktree"))
  let fallback_task = seed_execution(conn, "store-fallback", 200, None)
  let production_store = store.new_store()

  let assert Ok(state) =
    executions.get_execution_by_instance(conn, task.instance_id)
  let changed_state =
    ExecutionState(
      ..state,
      status: Running,
      current_node_id: Some(task.node_id),
      loop_counters: dict.from_list([#("loop-a", 2)]),
      variables: dict.from_list([#("answer", "persisted")]),
      parallel_active: ["branch-a"],
      started_at: Some(150),
      completed_at: None,
    )
  let assert Ok(Nil) = production_store.save_status(conn, changed_state, 250)

  let assert Ok(saved_state) =
    executions.get_execution_by_instance(conn, task.instance_id)
  assert saved_state.status == Running
  assert saved_state.current_node_id == Some(task.node_id)
  assert saved_state.loop_counters == dict.from_list([#("loop-a", 2)])
  assert saved_state.variables == dict.from_list([#("answer", "persisted")])
  assert saved_state.parallel_active == ["branch-a"]
  assert saved_state.started_at == Some(150)
  assert saved_state.completed_at == None

  let step =
    StepExecution(
      id: "store-step-row",
      flow_instance_id: task.instance_id,
      execution_state_id: task.execution_id,
      node_id: task.node_id,
      task_id: task.task_id,
      status: StepCompleted,
      prompt: Some("stored prompt"),
      output: Some("stored output"),
      transition_result: None,
      model: Some("store-model"),
      input_tokens: 13,
      output_tokens: 8,
      cost: 0.125,
      duration_ms: 21,
      session_id: Some("store-session"),
      created_at: 260,
      completed_at: Some(281),
    )
  let assert Ok(Nil) = production_store.save_step(conn, step, 281)
  let assert Ok(saved_step) = executions.get_step_execution(conn, step.id)
  assert saved_step.status == StepCompleted
  assert saved_step.node_id == task.node_id
  assert saved_step.model == Some("store-model")
  assert saved_step.output == Some("stored output")
  assert saved_step.input_tokens == 13
  assert saved_step.output_tokens == 8
  assert saved_step.cost == 0.125
  assert saved_step.session_id == Some("store-session")

  let assert Ok(Nil) =
    production_store.append_log(
      conn,
      step.id,
      task.task_id,
      "outcome",
      "stored output",
      282,
    )
  let assert Ok(Nil) =
    production_store.append_log(
      conn,
      step.id,
      task.task_id,
      "usage",
      "{\"input_tokens\":13}",
      283,
    )
  let assert Ok(logs) = session_logs.list_logs(conn, step.id, 50, None)
  assert list.map(logs, fn(log) { log.sequence }) == [1, 2]
  assert list.map(logs, fn(log) { log.event_type }) == ["outcome", "usage"]
  assert list.map(logs, fn(log) { log.payload })
    == [
      "stored output",
      "{\"input_tokens\":13}",
    ]

  assert production_store.workdir(conn, task.task_id, "/project")
    == Ok("/tasks/worktree")
  assert production_store.workdir(conn, fallback_task.task_id, "/project")
    == Ok("/project")
  connection.close(conn)
}

pub fn daemon_executes_persists_and_does_not_double_run_test() {
  let database = temp_database()
  let setup_conn = file_connection(database)
  let assert Ok(_) = migrations.run_migrations(setup_conn)
  // Version recording makes startup migration runs idempotent.
  let assert Ok([]) = migrations.run_migrations(setup_conn)
  let fixture = seed_execution(setup_conn, "poll", 100, Some("/worktrees/poll"))
  let daemon_conn = file_connection(database)
  let key = "daemon-poll-harness"
  let harness = counting_harness(key)

  let assert Ok(daemon.Processed(processed_id, Ok(final_state))) =
    daemon.poll_once(daemon_conn, harness, "/project")
  assert processed_id == fixture.instance_id
  assert final_state.status == Completed
  assert call_count(key) == 1

  let assert Ok([step]) =
    executions.get_steps_for_instance(setup_conn, fixture.instance_id)
  assert step.status == StepCompleted
  assert step.node_id == fixture.node_id
  assert step.model == Some("stub-model-v1")
  assert step.output == Some("stub output: prompt for poll")
  assert step.input_tokens > 0
  assert step.output_tokens > 0
  assert step.cost == 0.025
  assert step.session_id == Some("stub-session")

  let assert Ok(logs) = session_logs.list_logs(setup_conn, step.id, 50, None)
  assert list.map(logs, fn(log) { log.sequence }) == [1, 2]
  assert list.map(logs, fn(log) { log.event_type }) == ["outcome", "usage"]
  assert list.map(logs, fn(log) { log.payload })
    == [
      "stub output: prompt for poll",
      "{\"model\":\"stub-model-v1\",\"input_tokens\":41,\"output_tokens\":17,\"cost\":0.025,\"duration_ms\":19}",
    ]

  let assert Ok(daemon.Idle) =
    daemon.poll_once(daemon_conn, harness, "/project")
  assert call_count(key) == 1
  let assert Ok(persisted) =
    executions.get_execution_by_instance(setup_conn, fixture.instance_id)
  assert persisted.status == Completed

  connection.close(daemon_conn)
  connection.close(setup_conn)
  clean_temp_database(database)
}

pub fn failed_harness_is_logged_and_next_poll_still_runs_test() {
  let database = temp_database()
  let setup_conn = file_connection(database)
  let assert Ok(_) = migrations.run_migrations(setup_conn)
  let failed = seed_execution(setup_conn, "failure", 100, None)
  let succeeding = seed_execution(setup_conn, "after-failure", 200, None)
  let daemon_conn = file_connection(database)
  let fail_key = "daemon-failing-harness"

  let assert Ok(daemon.Processed(
    failed_id,
    Error(runtime.AdapterFailure(_, 7, _)),
  )) = daemon.poll_once(daemon_conn, failing_harness(fail_key), "/project")
  assert failed_id == failed.instance_id
  assert call_count(fail_key) == 1

  let assert Ok([failed_step]) =
    executions.get_steps_for_instance(setup_conn, failed.instance_id)
  assert failed_step.status == StepFailed
  let assert Ok(error_logs) =
    session_logs.list_logs(setup_conn, failed_step.id, 50, None)
  assert list.map(error_logs, fn(log) { log.sequence }) == [1]
  assert list.map(error_logs, fn(log) { log.event_type }) == ["error"]
  assert list.map(error_logs, fn(log) { log.payload })
    == [
      "harness exited with code 7: stub process failure",
    ]
  let assert Ok(failed_state) =
    executions.get_execution_by_instance(setup_conn, failed.instance_id)
  assert failed_state.status == Failed

  let assert Ok(daemon.Processed(next_id, Ok(next_state))) =
    daemon.poll_once(daemon_conn, successful_harness(), "/project")
  assert next_id == succeeding.instance_id
  assert next_state.status == Completed
  let assert Ok([success_step]) =
    executions.get_steps_for_instance(setup_conn, succeeding.instance_id)
  assert success_step.status == StepCompleted

  connection.close(daemon_conn)
  connection.close(setup_conn)
  clean_temp_database(database)
}

pub fn claims_expire_and_release_only_for_their_owner_test() {
  let database = temp_database()
  let conn = file_connection(database)
  let assert Ok(_) = migrations.run_migrations(conn)
  let fixture = seed_execution(conn, "claim", 100, None)

  let assert Ok(Some(first_claim)) =
    executions.claim_execution(conn, "dead-daemon", 100, 10)
  assert first_claim.id == fixture.execution_id
  let assert Ok(None) =
    executions.claim_execution(conn, "waiting-daemon", 105, 10)

  let assert Ok(Some(reclaimed)) =
    executions.claim_execution(conn, "live-daemon", 111, 10)
  assert reclaimed.id == fixture.execution_id
  let assert Ok(Nil) =
    executions.release_claim(conn, fixture.execution_id, "dead-daemon")
  let assert Ok(None) =
    executions.claim_execution(conn, "third-daemon", 112, 10)

  let assert Ok(Nil) =
    executions.release_claim(conn, fixture.execution_id, "live-daemon")
  let assert Ok(Some(after_release)) =
    executions.claim_execution(conn, "restarted-daemon", 113, 10)
  assert after_release.id == fixture.execution_id
  let assert Ok(Nil) =
    executions.release_claim(conn, fixture.execution_id, "restarted-daemon")

  connection.close(conn)
  clean_temp_database(database)
}

pub fn daemon_can_be_disabled_without_opening_a_database_test() {
  let previous = envoy.get("CRYSTALLINE_DAEMON")
  envoy.set("CRYSTALLINE_DAEMON", "0")
  let start_result = daemon.start("/unused")

  case previous {
    Ok(value) -> envoy.set("CRYSTALLINE_DAEMON", value)
    Error(_) -> envoy.unset("CRYSTALLINE_DAEMON")
  }

  let assert Ok(None) = start_result
  Nil
}

pub fn daemon_actor_accepts_tick_and_stops_test() {
  let database = temp_database()
  let setup_conn = file_connection(database)
  let assert Ok(_) = migrations.run_migrations(setup_conn)
  let fixture = seed_execution(setup_conn, "actor", 100, None)
  let daemon_conn = file_connection(database)
  let assert Ok(actor) =
    daemon.start_with_connection(
      daemon_conn,
      successful_harness(),
      "/project",
      10_000,
    )

  daemon.tick(actor)
  assert wait_for_status(setup_conn, fixture.instance_id, Completed, 100)
  daemon.stop(actor)
  assert wait_for_exit(actor, 100)

  connection.close(setup_conn)
  clean_temp_database(database)
}

fn wait_for_status(
  conn: DbConnection,
  instance_id: String,
  expected: ExecutionStatus,
  remaining: Int,
) -> Bool {
  let assert Ok(state) = executions.get_execution_by_instance(conn, instance_id)
  case state.status == expected {
    True -> True
    False if remaining > 0 -> {
      process.sleep(10)
      wait_for_status(conn, instance_id, expected, remaining - 1)
    }
    False -> False
  }
}

fn wait_for_exit(actor: daemon.Daemon, remaining: Int) -> Bool {
  case daemon.is_alive(actor) {
    False -> True
    True if remaining > 0 -> {
      process.sleep(10)
      wait_for_exit(actor, remaining - 1)
    }
    True -> False
  }
}

@external(erlang, "erlang", "put")
fn process_dictionary_put(key: String, value: Int) -> Nil

@external(erlang, "erlang", "get")
fn process_dictionary_get(key: String) -> Int

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "file", "make_dir")
fn make_directory(path: String) -> Dynamic

@external(erlang, "file", "delete")
fn delete_file(path: String) -> Dynamic

@external(erlang, "file", "del_dir")
fn delete_directory(path: String) -> Dynamic
