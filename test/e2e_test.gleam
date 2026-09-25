/// Issue 13 acceptance: end-to-end tests for the task → completed flow path.
///
/// Every request is dispatched through the production route table
/// (`server.all_routes/2`) with `wisp/simulate`, following the existing
/// API-test convention (`tasks_api_test`, `flows_test`): no socket, no network,
/// no external binary. `server.start/1` mounts exactly that table, so a route
/// missing from `all_routes` fails here instead of only in production.
///
/// Scenario 1 drives `implement_review` to `flow_complete` over HTTP. Scenario 2
/// drives `design_implement` through `awaiting_input` → `/input` → completion,
/// pages its session logs over HTTP, and asserts referential integrity after the
/// flow-instance row is physically deleted (the task DELETE endpoint only
/// archives, so it cannot exercise the cascade). A stubbed `runtime.Harness`
/// with a libsql-backed `runtime.Store` covers the adapter leg, so no agent
/// process is spawned.
import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some, unwrap}
import gleam/result
import gleam/string
import gleeunit
import sacrum_gleam/db/connection
import sacrum_gleam/db/executions
import sacrum_gleam/db/migrations
import sacrum_gleam/db/session_logs
import sacrum_gleam/db/tasks as db_tasks
import sacrum_gleam/domain/execution.{
  type StepExecution, AwaitingInput, ExecutionState, StepCompleted,
}
import sacrum_gleam/domain/task
import sacrum_gleam/flow/engine as flow_engine
import sacrum_gleam/flow/templates
import sacrum_gleam/harness/contract
import sacrum_gleam/http/router
import sacrum_gleam/http/server
import sacrum_gleam/runtime/executor as runtime
import wisp
import wisp/simulate as sim

pub fn main() -> Nil {
  gleeunit.main()
}

// ─── Real HTTP surface ───────────────────────────────────────────────────

fn new_conn() -> connection.DbConnection {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok(_) = migrations.run_migrations(conn)
  conn
}

fn dispatch(
  conn: connection.DbConnection,
  request: wisp.Request,
) -> wisp.Response {
  router.match_route(server.all_routes(conn, "local"), request)
}

fn get(conn: connection.DbConnection, path: String) -> wisp.Response {
  dispatch(conn, sim.request(http.Get, path))
}

fn post(conn: connection.DbConnection, path: String) -> wisp.Response {
  dispatch(conn, sim.request(http.Post, path))
}

fn post_json(
  conn: connection.DbConnection,
  path: String,
  body: json.Json,
) -> wisp.Response {
  dispatch(conn, sim.json_body(sim.request(http.Post, path), body))
}

fn patch_json(
  conn: connection.DbConnection,
  path: String,
  body: json.Json,
) -> wisp.Response {
  dispatch(conn, sim.json_body(sim.request(http.Patch, path), body))
}

fn status(response: wisp.Response) -> Int {
  response.status
}

fn body(response: wisp.Response) -> String {
  sim.read_body(response)
}

// ─── JSON decoding ───────────────────────────────────────────────────────

fn string_field(key: String) -> decode.Decoder(String) {
  use value <- decode.field(key, decode.string)
  decode.success(value)
}

fn instance_id_decoder() -> decode.Decoder(String) {
  use id <- decode.field("instance", string_field("id"))
  decode.success(id)
}

fn execution_action_decoder() -> decode.Decoder(#(String, String)) {
  use status <- decode.field("execution", string_field("status"))
  use action <- decode.field("action", string_field("type"))
  decode.success(#(status, action))
}

fn execution_action(response: wisp.Response) -> #(String, String) {
  let assert Ok(progress) =
    json.parse(body(response), execution_action_decoder())
  progress
}

fn log_sequences_decoder() -> decode.Decoder(List(Int)) {
  decode.list(of: {
    use sequence <- decode.field("sequence", decode.int)
    decode.success(sequence)
  })
}

fn log_sequences(response: wisp.Response) -> List(Int) {
  let assert Ok(sequences) = json.parse(body(response), log_sequences_decoder())
  sequences
}

// ─── Shared flow helpers ─────────────────────────────────────────────────

fn seed_templates(conn: connection.DbConnection) -> Nil {
  let assert Ok(inserted) = templates.seed_to_db(conn, 1)
  assert inserted == 6
  Nil
}

fn create_task(conn: connection.DbConnection, title: String) -> String {
  let response =
    post_json(
      conn,
      "/api/v1/tasks",
      json.object([
        #("title", json.string(title)),
        #("level", json.string("ticket")),
        #("priority", json.string("medium")),
      ]),
    )
  assert status(response) == 201
  let assert Ok(id) = json.parse(body(response), string_field("id"))
  id
}

fn instantiate_flow(
  conn: connection.DbConnection,
  task_id: String,
  template_id: String,
) -> String {
  let response =
    post_json(
      conn,
      "/api/v1/tasks/" <> task_id <> "/flow",
      json.object([#("template_id", json.string(template_id))]),
    )
  assert status(response) == 201
  let assert Ok(instance_id) = json.parse(body(response), instance_id_decoder())
  instance_id
}

fn complete_until_flow_complete(
  conn: connection.DbConnection,
  instance_id: String,
  last_status: String,
  action: String,
  remaining_steps: Int,
) -> #(String, String) {
  case action {
    "flow_complete" -> #(last_status, action)
    "run_step" -> {
      case remaining_steps > 0 {
        False ->
          panic as {
            "Flow "
            <> instance_id
            <> " exceeded the completion bound without flow_complete; last status: "
            <> last_status
          }
        True -> {
          let response =
            post_json(
              conn,
              "/api/v1/flows/" <> instance_id <> "/complete",
              json.object([
                #("output", json.string("completed by the e2e client")),
              ]),
            )
          assert status(response) == 200
          let #(next_status, next_action) = execution_action(response)
          complete_until_flow_complete(
            conn,
            instance_id,
            next_status,
            next_action,
            remaining_steps - 1,
          )
        }
      }
    }
    _ ->
      panic as {
        "Flow "
        <> instance_id
        <> " stalled before flow_complete; last status: "
        <> last_status
        <> ", action: "
        <> action
      }
  }
}

fn assert_completed_nodes(
  steps: List(StepExecution),
  expected: List(String),
) -> Nil {
  let actual_nodes =
    steps |> list.map(fn(step) { step.node_id }) |> list.sort(string.compare)
  assert actual_nodes == list.sort(expected, string.compare)
  assert list.all(steps, fn(step) { step.status == StepCompleted })
  Nil
}

fn mark_task_done(conn: connection.DbConnection, task_id: String) -> Nil {
  let response =
    patch_json(
      conn,
      "/api/v1/tasks/" <> task_id,
      json.object([#("status", json.string("done"))]),
    )
  assert status(response) == 200
  let assert Ok(stored_task) = db_tasks.get_task(conn, task_id)
  assert stored_task.status == task.Done
  Nil
}

// ─── Runtime adapter and libsql store ────────────────────────────────────

fn stub_harness(
  request: contract.Request,
) -> Result(contract.Result, contract.AdapterError) {
  Ok(contract.Result(
    status: contract.Success,
    output: "e2e stub: " <> request.prompt,
    model_used: "e2e-stub-model",
    input_tokens: 17,
    output_tokens: 9,
    cost: 0.004,
    duration_ms: 23,
    session_id: Some("e2e-session"),
    error: None,
  ))
}

fn db_store() -> runtime.Store {
  runtime.Store(
    save_status: fn(conn, state, now) {
      use _ <- result.try(
        db_result(executions.update_execution_status(
          conn,
          state.id,
          state.status,
          state.current_node_id,
          now,
        )),
      )
      db_result(executions.update_execution_variables(
        conn,
        state.id,
        state.variables,
        state.loop_counters,
        now,
      ))
    },
    save_step: fn(conn, step, now) {
      executions.create_step_execution(conn, step, now)
      |> result.map(fn(_) { Nil })
      |> result.map_error(runtime_db_error)
    },
    append_log: fn(conn, step_id, task_id, event_type, payload, now) {
      session_logs.append_log(conn, step_id, task_id, event_type, payload, now)
      |> result.map(fn(_) { Nil })
      |> result.map_error(runtime_db_error)
    },
    workdir: fn(_conn, _task_id, fallback) { Ok(fallback) },
  )
}

fn db_result(
  result: Result(a, connection.DbError),
) -> Result(a, runtime.RuntimeError) {
  result |> result.map_error(runtime_db_error)
}

fn runtime_db_error(error: connection.DbError) -> runtime.RuntimeError {
  runtime.PersistenceFailure(connection.error_to_string(error))
}

/// Rehydrate the route-created execution into the pure flow engine so the
/// runtime harness drives that same persisted instance, not a test-only flow.
fn runtime_engine(
  conn: connection.DbConnection,
  instance_id: String,
) -> runtime.Engine {
  let #(flow, _seeded_count) =
    templates.seed_to_engine(flow_engine.new_engine())
  let assert Ok(_) = flow_engine.get_template(flow, "design_implement")

  let assert Ok(state) = executions.get_execution_by_instance(conn, instance_id)
  let assert Ok(steps) = executions.get_steps_for_instance(conn, instance_id)
  let state = ExecutionState(..state, step_history: steps)
  let flow =
    flow_engine.Engine(
      ..flow,
      executions: flow_engine.ExecutionRegistry(
        dict.from_list([#(instance_id, state)]),
      ),
    )

  runtime.new_engine(flow, stub_harness, db_store(), "/tmp/crystalline-e2e")
}

// ─── Direct SQL counts for cascade integrity ─────────────────────────────

fn task_row_count(
  conn: connection.DbConnection,
  table: String,
  task_id: String,
) -> Int {
  let assert Ok(rows) =
    connection.query(
      conn,
      "SELECT COUNT(*) FROM " <> table <> " WHERE task_id = ?",
      [connection.TextVal(task_id)],
    )
  case rows {
    [[connection.IntVal(count), ..], ..] -> count
    _ -> panic as { "Could not count rows in " <> table }
  }
}

fn orphan_row_count(conn: connection.DbConnection, query: String) -> Int {
  let assert Ok(rows) = connection.query(conn, query, [])
  case rows {
    [[connection.IntVal(count), ..], ..] -> count
    _ -> panic as "Could not count orphaned rows"
  }
}

fn orphan_counts(conn: connection.DbConnection) -> #(Int, Int, Int) {
  #(
    orphan_row_count(
      conn,
      "SELECT COUNT(*) FROM flow_instances fi "
        <> "LEFT JOIN tasks t ON t.id = fi.task_id WHERE t.id IS NULL",
    ),
    orphan_row_count(
      conn,
      "SELECT COUNT(*) FROM step_executions s "
        <> "LEFT JOIN flow_instances fi ON fi.id = s.flow_instance_id "
        <> "LEFT JOIN execution_states e ON e.id = s.execution_state_id "
        <> "LEFT JOIN tasks t ON t.id = s.task_id "
        <> "WHERE fi.id IS NULL OR e.id IS NULL OR t.id IS NULL",
    ),
    orphan_row_count(
      conn,
      "SELECT COUNT(*) FROM session_logs l "
        <> "LEFT JOIN step_executions s ON s.id = l.step_execution_id "
        <> "LEFT JOIN tasks t ON t.id = l.task_id "
        <> "WHERE s.id IS NULL OR t.id IS NULL",
    ),
  )
}

// ─── Scenario 1: implement_review to terminal completion ─────────────────

pub fn implement_review_task_flow_completes_over_http_test() {
  let conn = new_conn()
  seed_templates(conn)
  let task_id = create_task(conn, "Implement and review e2e")
  let instance_id = instantiate_flow(conn, task_id, "implement_review")

  let started = post(conn, "/api/v1/flows/" <> instance_id <> "/advance")
  assert status(started) == 200
  let #(start_status, start_action) = execution_action(started)
  assert start_status == "running"
  assert start_action == "run_step"

  let #(final_status, final_action) =
    complete_until_flow_complete(
      conn,
      instance_id,
      start_status,
      start_action,
      12,
    )
  assert final_action == "flow_complete"
  assert final_status == "completed"

  let assert Ok(steps) = executions.get_steps_for_instance(conn, instance_id)
  assert_completed_nodes(steps, ["research", "implement", "test", "review"])
  assert list.length(steps) == 4

  mark_task_done(conn, task_id)
}

// ─── Scenario 2: design_implement human input, logs, and archive integrity ─

pub fn design_implement_human_input_logs_and_archive_test() {
  let conn = new_conn()
  seed_templates(conn)
  let task_id = create_task(conn, "Design and implement e2e")
  let instance_id = instantiate_flow(conn, task_id, "design_implement")

  let started = post(conn, "/api/v1/flows/" <> instance_id <> "/advance")
  assert status(started) == 200
  let #(start_status, start_action) = execution_action(started)
  assert start_status == "running"
  assert start_action == "run_step"

  let assert Ok(runtime_state) =
    runtime.run_until_wait(conn, runtime_engine(conn, instance_id), instance_id)
  assert runtime_state.status == AwaitingInput
  let assert Ok(runtime_steps) =
    executions.get_steps_for_instance(conn, instance_id)
  assert_completed_nodes(runtime_steps, ["research", "design"])
  assert list.all(runtime_steps, fn(step) {
    step.model == Some("e2e-stub-model")
    && step.output == Some("e2e stub: " <> unwrap(step.prompt, ""))
  })

  let input_response =
    post_json(
      conn,
      "/api/v1/flows/" <> instance_id <> "/input",
      json.object([#("input", json.string("Approved by the e2e test"))]),
    )
  assert status(input_response) == 200
  let #(input_status, input_action) = execution_action(input_response)
  assert input_status == "running"
  assert input_action == "run_step"

  let #(final_status, final_action) =
    complete_until_flow_complete(
      conn,
      instance_id,
      input_status,
      input_action,
      12,
    )
  assert final_action == "flow_complete"
  assert final_status == "completed"

  let assert Ok(steps) = executions.get_steps_for_instance(conn, instance_id)
  assert_completed_nodes(steps, ["research", "design", "implement", "test"])
  assert list.length(steps) == 4
  mark_task_done(conn, task_id)

  let assert Ok(research_step) =
    list.find(steps, fn(step) { step.node_id == "research" })
  assert task_row_count(conn, "session_logs", task_id) == 4

  let page_one =
    get(conn, "/api/v1/executions/" <> research_step.id <> "/logs?limit=1")
  assert status(page_one) == 200
  let page_one_sequences = log_sequences(page_one)
  assert page_one_sequences == [2]
  let cursor = case page_one_sequences {
    [sequence, ..] -> sequence
    [] -> panic as "The first HTTP log page was empty"
  }

  let page_two =
    get(
      conn,
      "/api/v1/executions/"
        <> research_step.id
        <> "/logs?limit=1&before_sequence="
        <> int.to_string(cursor),
    )
  assert status(page_two) == 200
  let page_two_sequences = log_sequences(page_two)
  assert page_two_sequences == [1]
  assert list.all(page_two_sequences, fn(sequence) {
    list.contains(page_one_sequences, sequence) == False
  })

  let counts_before = #(
    task_row_count(conn, "flow_instances", task_id),
    task_row_count(conn, "execution_states", task_id),
    task_row_count(conn, "step_executions", task_id),
    task_row_count(conn, "session_logs", task_id),
  )
  assert counts_before == #(1, 1, 4, 4)
  assert orphan_counts(conn) == #(0, 0, 0)

  let assert Ok([[connection.IntVal(foreign_keys_enabled), ..], ..]) =
    connection.query(conn, "PRAGMA foreign_keys", [])
  assert foreign_keys_enabled == 1

  // The task DELETE endpoint archives, so its HTTP contract retains its rows.
  let deleted =
    dispatch(
      conn,
      sim.request(http.Delete, "/api/v1/tasks/" <> task_id <> "?cascade=true"),
    )
  assert status(deleted) == 200
  let assert Ok(archived_task) = db_tasks.get_task(conn, task_id)
  assert archived_task.archived
  assert archived_task.status == task.Done
  assert #(
      task_row_count(conn, "flow_instances", task_id),
      task_row_count(conn, "execution_states", task_id),
      task_row_count(conn, "step_executions", task_id),
      task_row_count(conn, "session_logs", task_id),
    )
    == counts_before

  let assert Ok(_) =
    connection.execute(conn, "DELETE FROM flow_instances WHERE id = ?", [
      connection.TextVal(instance_id),
    ])
  let counts_after = #(
    task_row_count(conn, "flow_instances", task_id),
    task_row_count(conn, "execution_states", task_id),
    task_row_count(conn, "step_executions", task_id),
    task_row_count(conn, "session_logs", task_id),
  )
  assert counts_after == #(0, 0, 0, 0)
  assert orphan_counts(conn) == #(0, 0, 0)
  let assert Ok(archived_task) = db_tasks.get_task(conn, task_id)
  assert archived_task.archived
  assert archived_task.status == task.Done
}
