/// Flows API — template CRUD, instantiation and execution control.
///
/// Endpoints:
///
///   Templates:
///     POST   /api/v1/flow-templates            create (201)
///     GET    /api/v1/flow-templates            list
///     GET    /api/v1/flow-templates/:id        get
///     PATCH  /api/v1/flow-templates/:id        update
///     DELETE /api/v1/flow-templates/:id        delete
///
///   Instances:
///     POST   /api/v1/tasks/:task_id/flow       instantiate (201, status pending)
///     GET    /api/v1/tasks/:task_id/flow       instance + execution state
///
///   Execution control:
///     POST   /api/v1/flows/:instance_id/advance   next engine step (Action)
///     POST   /api/v1/flows/:instance_id/complete  report step output (Action)
///     POST   /api/v1/flows/:instance_id/input     resume from awaiting_input (Action)
///     POST   /api/v1/flows/:instance_id/reject    mark execution rejected
///
/// The pure flow engine (`flow/engine`, `flow/executor`) is stateless per
/// request: the database owns the execution state, and each call hydrates a
/// single-instance engine from the persisted row before driving it one step
/// further. This keeps the API horizontally scalable — no in-memory registry
/// to shard.
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Patch, Post}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some, unwrap}
import gleam/result
import sacrum_gleam/db/connection.{type DbConnection, type DbError}
import sacrum_gleam/db/executions
import sacrum_gleam/db/flows
import sacrum_gleam/db/tasks
import sacrum_gleam/domain/execution.{
  type ExecutionState, AwaitingInput, Cancelled, Completed, ExecutionState,
  Failed, Pending, Rejected, Running, StepCompleted, StepExecution,
  execution_status_to_string, new_execution_state,
}
import sacrum_gleam/domain/flow.{
  type FlowInstance, type FlowTemplate, FlowInstance, FlowTemplate,
}
import sacrum_gleam/flow/executor.{
  type Action, AwaitInput, ExecutionError, FlowComplete, FlowReject, RunParallel,
  RunStep, advance as executor_advance, complete_step as executor_complete_step,
  provide_input as executor_provide_input, start as executor_start,
}
import sacrum_gleam/flow/validator
import sacrum_gleam/http/helpers
import sacrum_gleam/http/router.{type Route, Route}
import sacrum_gleam/json/codec
import wisp.{type Request, type Response}

// ─── Errors ────────────────────────────────────────────────────────────────

/// Errors returned by the execution-control services, mapped to HTTP status
/// codes by the route handlers.
pub type ExecutionError {
  /// No execution state exists for the instance id.
  NotFound(message: String)
  /// The request body is malformed (400).
  BadRequest(message: String)
  /// The requested transition is not valid for the current status (409).
  Conflict(message: String)
  /// A persistence layer failure (500).
  Internal(message: String)
}

// ─── Route Definitions ────────────────────────────────────────────────────

pub fn flow_routes(conn: DbConnection) -> List(Route) {
  [
    // Templates
    Route(Post, "/api/v1/flow-templates", fn(req, _) {
      create_template(req, conn)
    }),
    Route(Get, "/api/v1/flow-templates", fn(req, _) {
      list_templates(req, conn)
    }),
    Route(Get, "/api/v1/flow-templates/:id", fn(req, params) {
      get_template(req, params, conn)
    }),
    Route(Patch, "/api/v1/flow-templates/:id", fn(req, params) {
      update_template(req, params, conn)
    }),
    Route(Delete, "/api/v1/flow-templates/:id", fn(req, params) {
      delete_template(req, params, conn)
    }),
    // Instances
    Route(Post, "/api/v1/tasks/:task_id/flow", fn(req, params) {
      instantiate(req, params, conn)
    }),
    Route(Get, "/api/v1/tasks/:task_id/flow", fn(req, params) {
      get_task_flow(req, params, conn)
    }),
    // Execution control
    Route(Post, "/api/v1/flows/:instance_id/advance", fn(req, params) {
      advance(req, params, conn)
    }),
    Route(Post, "/api/v1/flows/:instance_id/complete", fn(req, params) {
      complete(req, params, conn)
    }),
    Route(Post, "/api/v1/flows/:instance_id/input", fn(req, params) {
      input(req, params, conn)
    }),
    Route(Post, "/api/v1/flows/:instance_id/reject", fn(req, params) {
      reject(req, params, conn)
    }),
  ]
}

// ─── Template handlers ────────────────────────────────────────────────────

fn create_template(req: Request, conn: DbConnection) -> Response {
  use body <- wisp.require_json(req)

  case create_template_service(conn, body) {
    Error(message) -> helpers.error_response(400, message)
    Ok(template) -> {
      let body = flow_templates_body(template)
      helpers.json_response(json.to_string(body), 201)
    }
  }
}

fn list_templates(_req: Request, conn: DbConnection) -> Response {
  case flows.list_flow_templates(conn) {
    Error(error) -> helpers.error_response(500, db_message(error))
    Ok(templates) -> {
      let body = json.array(templates, flow_templates_body)
      helpers.json_response(json.to_string(body), 200)
    }
  }
}

fn get_template(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(Nil) -> helpers.error_response(400, "Missing template ID")
    Ok(id) ->
      case flows.get_flow_template(conn, id) {
        Error(_) -> helpers.error_response(404, "Flow template not found")
        Ok(template) ->
          helpers.json_response(
            json.to_string(flow_templates_body(template)),
            200,
          )
      }
  }
}

fn update_template(
  req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  use body <- wisp.require_json(req)

  case dict.get(params, "id") {
    Error(Nil) -> helpers.error_response(400, "Missing template ID")
    Ok(id) ->
      case update_template_service(conn, id, body) {
        Error(message) -> helpers.error_response(400, message)
        Ok(template) ->
          helpers.json_response(
            json.to_string(flow_templates_body(template)),
            200,
          )
      }
  }
}

fn delete_template(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "id") {
    Error(Nil) -> helpers.error_response(400, "Missing template ID")
    Ok(id) ->
      case delete_template_service(conn, id) {
        Error(message) -> helpers.error_response(409, message)
        Ok(_) ->
          helpers.json_response(
            json.to_string(json.object([#("message", json.string("Deleted"))])),
            200,
          )
      }
  }
}

// ─── Instance handlers ────────────────────────────────────────────────────

fn instantiate(
  req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  use body <- wisp.require_json(req)

  case dict.get(params, "task_id") {
    Error(Nil) -> helpers.error_response(400, "Missing task ID")
    Ok(task_id) ->
      case decode_string_field(body, "template_id") {
        Error(message) -> helpers.error_response(400, message)
        Ok(template_id) ->
          case instantiate_service(conn, task_id, template_id) {
            Error(message) -> helpers.error_response(400, message)
            Ok(#(instance, state)) ->
              helpers.json_response(
                json.to_string(
                  json.object([
                    #("instance", instance_body(instance)),
                    #("execution", execution_body(state)),
                  ]),
                ),
                201,
              )
          }
      }
  }
}

fn get_task_flow(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "task_id") {
    Error(Nil) -> helpers.error_response(400, "Missing task ID")
    Ok(task_id) ->
      case flows.get_instance_by_task(conn, task_id) {
        Error(_) ->
          helpers.error_response(404, "No flow instance for this task")
        Ok(instance) ->
          case executions.get_execution_by_task(conn, task_id) {
            Error(_) ->
              helpers.error_response(404, "No execution state for this task")
            Ok([first, ..]) ->
              helpers.json_response(
                json.to_string(
                  json.object([
                    #("instance", instance_body(instance)),
                    #("execution", execution_body(first)),
                  ]),
                ),
                200,
              )
            Ok([]) ->
              helpers.error_response(404, "No execution state for this task")
          }
      }
  }
}

// ─── Execution control handlers ───────────────────────────────────────────

fn advance(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "instance_id") {
    Error(Nil) -> helpers.error_response(400, "Missing instance ID")
    Ok(instance_id) ->
      case advance_service(conn, instance_id) {
        Error(error) -> execution_error_response(error)
        Ok(#(state, action)) ->
          helpers.json_response(
            json.to_string(execution_step_body(state, action)),
            200,
          )
      }
  }
}

fn complete(
  req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  use body <- wisp.require_json(req)

  case dict.get(params, "instance_id") {
    Error(Nil) -> helpers.error_response(400, "Missing instance ID")
    Ok(instance_id) ->
      case decode_string_field(body, "output") {
        Error(message) -> helpers.error_response(400, message)
        Ok(output) ->
          case complete_service(conn, instance_id, output) {
            Error(error) -> execution_error_response(error)
            Ok(#(state, action)) ->
              helpers.json_response(
                json.to_string(execution_step_body(state, action)),
                200,
              )
          }
      }
  }
}

fn input(
  req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  use body <- wisp.require_json(req)

  case dict.get(params, "instance_id") {
    Error(Nil) -> helpers.error_response(400, "Missing instance ID")
    Ok(instance_id) ->
      case decode_string_field(body, "input") {
        Error(message) -> helpers.error_response(400, message)
        Ok(value) ->
          case input_service(conn, instance_id, value) {
            Error(error) -> execution_error_response(error)
            Ok(#(state, action)) ->
              helpers.json_response(
                json.to_string(execution_step_body(state, action)),
                200,
              )
          }
      }
  }
}

fn reject(
  _req: Request,
  params: Dict(String, String),
  conn: DbConnection,
) -> Response {
  case dict.get(params, "instance_id") {
    Error(Nil) -> helpers.error_response(400, "Missing instance ID")
    Ok(instance_id) ->
      case reject_service(conn, instance_id) {
        Error(error) -> execution_error_response(error)
        Ok(state) ->
          helpers.json_response(json.to_string(execution_body(state)), 200)
      }
  }
}

/// Map an `ExecutionError` to an HTTP error response.
fn execution_error_response(error: ExecutionError) -> Response {
  case error {
    NotFound(message) -> helpers.error_response(404, message)
    BadRequest(message) -> helpers.error_response(400, message)
    Conflict(message) -> helpers.error_response(409, message)
    Internal(message) -> helpers.error_response(500, message)
  }
}

// ─── Template services ────────────────────────────────────────────────────

/// Decode a template request body into a `FlowTemplate` (id assigned later).
/// `nodes` is a JSON array of node objects, decoded to a dict keyed by
/// `node.id`.
pub fn decode_template(body: decode.Dynamic) -> Result(FlowTemplate, String) {
  use name <- result.try(decode_string_field(body, "name"))
  use initial_node_id <- result.try(decode_string_field(body, "initial_node_id"))
  use description <- result.try(decode_optional_string(body, "description"))
  let description = unwrap(description, "")
  use node_list <- result.try(decode_field_decoded(
    body,
    "nodes",
    decode.list(codec.node_decoder()),
  ))
  use transitions <- result.try(decode_field_decoded(
    body,
    "transitions",
    decode.list(codec.transition_decoder()),
  ))
  use on_done <- result.try(decode_optional_string(body, "on_done_template_id"))
  use on_reject <- result.try(decode_optional_string(
    body,
    "on_reject_template_id",
  ))

  Ok(FlowTemplate(
    id: "",
    name: name,
    description: description,
    initial_node_id: initial_node_id,
    nodes: dict.from_list(list.map(node_list, fn(node) { #(node.id, node) })),
    transitions: transitions,
    on_done_template_id: on_done,
    on_reject_template_id: on_reject,
  ))
}

/// Validate a template and persist it. Returns the created template.
pub fn create_template_service(
  conn: DbConnection,
  body: decode.Dynamic,
) -> Result(FlowTemplate, String) {
  use template <- result.try(decode_template(body))
  use _ <- result.try(validate_template(template))

  let template = FlowTemplate(..template, id: new_id("tpl"))
  use _ <- result.try(
    flows.create_flow_template(conn, template, milliseconds_now())
    |> db_to_message,
  )
  Ok(template)
}

/// Validate and persist an update to an existing template. The path `id`
/// always wins over any id in the body.
pub fn update_template_service(
  conn: DbConnection,
  id: String,
  body: decode.Dynamic,
) -> Result(FlowTemplate, String) {
  use _ <- result.try(
    flows.get_flow_template(conn, id)
    |> db_to_message
    |> result.map(fn(_template) { Nil }),
  )
  use template <- result.try(decode_template(body))
  use _ <- result.try(validate_template(template))

  let template = FlowTemplate(..template, id: id)
  use _ <- result.try(
    flows.update_flow_template(conn, id, template, milliseconds_now())
    |> db_to_message,
  )
  Ok(template)
}

/// Delete a template, rejecting when instances already reference it.
pub fn delete_template_service(
  conn: DbConnection,
  id: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    flows.get_flow_template(conn, id)
    |> db_to_message
    |> result.map(fn(_template) { Nil }),
  )
  use count <- result.try(
    flows.count_instances_for_template(conn, id)
    |> db_to_message,
  )
  case count > 0 {
    True ->
      Error(
        "Flow template is in use by " <> int.to_string(count) <> " instance(s)",
      )
    False ->
      flows.delete_flow_template(conn, id)
      |> db_to_message
  }
}

// ─── Instance services ────────────────────────────────────────────────────

/// Instantiate a flow from a template and bind it to a task.
///
/// Validates that both the task and the template exist and that the task has
/// no flow instance yet. The instance and its execution state are persisted
/// with status `pending`; the first `advance` call starts execution.
pub fn instantiate_service(
  conn: DbConnection,
  task_id: String,
  template_id: String,
) -> Result(#(FlowInstance, ExecutionState), String) {
  use task_exists <- result.try(
    tasks.task_exists(conn, task_id)
    |> db_to_message,
  )
  use _ <- result.try(case task_exists {
    False -> Error("Task not found: " <> task_id)
    True -> Ok(Nil)
  })

  use template <- result.try(
    flows.get_flow_template(conn, template_id)
    |> db_to_message,
  )

  use _ <- result.try(case flows.get_instance_by_task(conn, task_id) {
    Ok(_) -> Error("Task already has a flow instance")
    Error(_) -> Ok(Nil)
  })

  let instance_id = new_id("flow")
  let instance =
    FlowInstance(
      id: instance_id,
      template_id: template_id,
      task_id: task_id,
      nodes: template.nodes,
      transitions: template.transitions,
      initial_node_id: template.initial_node_id,
      on_done_template_id: template.on_done_template_id,
      on_reject_template_id: template.on_reject_template_id,
    )

  let state = new_execution_state(instance, task_id)
  let state = ExecutionState(..state, id: new_id("exec"))

  use _ <- result.try(
    flows.create_flow_instance(conn, instance, milliseconds_now())
    |> db_to_message,
  )
  use _ <- result.try(
    executions.create_execution_state(conn, state, milliseconds_now())
    |> db_to_message,
  )
  use _ <- result.try(
    tasks.update_task(
      conn,
      task_id,
      tasks.TaskUpdates(
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
      milliseconds_now(),
    )
    |> db_to_message,
  )

  Ok(#(instance, state))
}

// ─── Execution services ───────────────────────────────────────────────────

/// Advance the execution by one step and return the action to perform.
///
/// A `pending` execution starts on the first advance (status becomes
/// `running`, the initial node is dispatched). Finished or failed executions
/// cannot be advanced.
pub fn advance_service(
  conn: DbConnection,
  instance_id: String,
) -> Result(#(ExecutionState, Action), ExecutionError) {
  use state <- result.try(load_execution(conn, instance_id))

  use _ <- result.try(transition_guard(state, "advance"))

  let #(new_state, action) = case state.status {
    Pending -> {
      let started = executor_start(state.flow_instance, state.task_id)
      let result = executor_advance(started)
      #(result.state, result.action)
    }
    _ -> {
      let result = executor_advance(state)
      #(result.state, result.action)
    }
  }

  use _ <- result.try(persist_state(conn, new_state))
  Ok(#(new_state, action))
}

/// Report the output of the currently running step and obtain the next
/// action. The completed step is recorded in `step_executions` so step
/// history survives across requests (composite nodes rely on it).
pub fn complete_service(
  conn: DbConnection,
  instance_id: String,
  output: String,
) -> Result(#(ExecutionState, Action), ExecutionError) {
  use state <- result.try(load_execution(conn, instance_id))

  use _ <- result.try(case state.status {
    Running -> Ok(Nil)
    Pending ->
      Error(Conflict("Execution has not started; call advance first"))
    _ ->
      Error(Conflict(
        "Cannot complete: execution is "
        <> execution_status_to_string(state.status),
      ))
  })

  use node_id <- result.try(case state.current_node_id {
    Some(id) -> Ok(id)
    None -> Error(Conflict("Execution has no current node"))
  })
  let now = milliseconds_now()
  let step =
    StepExecution(
      id: new_id("step"),
      flow_instance_id: instance_id,
      execution_state_id: state.id,
      node_id: node_id,
      task_id: state.task_id,
      status: StepCompleted,
      prompt: None,
      output: Some(output),
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

  let result = executor_complete_step(state, step, output)

  use _ <- result.try(internal_error(
    executions.create_step_execution(conn, step, now)
    |> db_to_message,
  ))
  use _ <- result.try(persist_state(conn, result.state))
  Ok(#(result.state, result.action))
}

/// Resume an execution parked at `awaiting_input` with the supplied input.
pub fn input_service(
  conn: DbConnection,
  instance_id: String,
  input_value: String,
) -> Result(#(ExecutionState, Action), ExecutionError) {
  use state <- result.try(load_execution(conn, instance_id))

  use _ <- result.try(case state.status {
    AwaitingInput -> Ok(Nil)
    _ ->
      Error(Conflict(
        "Execution is not awaiting input (status: "
        <> execution_status_to_string(state.status)
        <> ")",
      ))
  })

  let result = executor_provide_input(state, input_value)

  use _ <- result.try(persist_state(conn, result.state))
  Ok(#(result.state, result.action))
}

/// Mark an execution as rejected.
pub fn reject_service(
  conn: DbConnection,
  instance_id: String,
) -> Result(ExecutionState, ExecutionError) {
  use state <- result.try(load_execution(conn, instance_id))

  use _ <- result.try(case state.status {
    Rejected -> Error(Conflict("Execution is already rejected"))
    Completed -> Error(Conflict("Execution is already completed"))
    _ -> Ok(Nil)
  })

  let new_state =
    ExecutionState(
      ..state,
      status: Rejected,
      completed_at: Some(milliseconds_now()),
    )
  use _ <- result.try(persist_state(conn, new_state))
  Ok(new_state)
}

// ─── Persistence helpers ──────────────────────────────────────────────────

/// Load an execution state from the database (by flow instance id),
/// re-attaching the persisted step history so composite nodes can track
/// completed children.
fn load_execution(
  conn: DbConnection,
  instance_id: String,
) -> Result(ExecutionState, ExecutionError) {
  use state <- result.try(case executions.get_execution_by_instance(
    conn,
    instance_id,
  ) {
    Ok(state) -> Ok(state)
    Error(_) -> Error(NotFound("Flow instance not found: " <> instance_id))
  })
  use steps <- result.try(internal_error(
    executions.get_steps_for_instance(conn, instance_id)
    |> db_to_message,
  ))
  Ok(ExecutionState(..state, step_history: steps))
}

/// Persist status, current node, variables and loop counters after a step.
fn persist_state(
  conn: DbConnection,
  state: ExecutionState,
) -> Result(Nil, ExecutionError) {
  use _ <- result.try(internal_error(
    executions.update_execution_status(
      conn,
      state.id,
      state.status,
      state.current_node_id,
      milliseconds_now(),
    )
    |> db_to_message,
  ))
  use _ <- result.try(internal_error(
    executions.update_execution_variables(
      conn,
      state.id,
      state.variables,
      state.loop_counters,
      milliseconds_now(),
    )
    |> db_to_message,
  ))
  Ok(Nil)
}

/// Map a string error produced by the db layer to an `Internal` error.
fn internal_error(result: Result(a, String)) -> Result(a, ExecutionError) {
  result
  |> result.map_error(with: fn(message) { Internal(message) })
}

fn transition_guard(
  state: ExecutionState,
  operation: String,
) -> Result(Nil, ExecutionError) {
  case state.status {
    Completed ->
      Error(Conflict("Cannot " <> operation <> ": execution is completed"))
    Rejected ->
      Error(Conflict("Cannot " <> operation <> ": execution is rejected"))
    Failed ->
      Error(Conflict("Cannot " <> operation <> ": execution failed"))
    Cancelled ->
      Error(Conflict("Cannot " <> operation <> ": execution was cancelled"))
    AwaitingInput ->
      Error(Conflict(
        "Cannot "
        <> operation
        <> ": execution is awaiting input; use the input endpoint",
      ))
    _ -> Ok(Nil)
  }
}

/// Validate a template structure. Returns a human-readable message on error.
fn validate_template(template: FlowTemplate) -> Result(Nil, String) {
  case validator.validate(template) {
    Ok(Nil) -> Ok(Nil)
    Error(errors) ->
      Error(
        "Invalid flow template ("
        <> int.to_string(list.length(errors))
        <> " validation error(s))",
      )
  }
}

// ─── JSON bodies ──────────────────────────────────────────────────────────

fn flow_templates_body(template: FlowTemplate) -> json.Json {
  json.object([
    #("id", json.string(template.id)),
    #("name", json.string(template.name)),
    #("description", json.string(template.description)),
    #("initial_node_id", json.string(template.initial_node_id)),
    #(
      "nodes",
      json.array(
        template.nodes |> dict.to_list |> list.map(fn(pair) { pair.1 }),
        codec.node_to_json,
      ),
    ),
    #("transitions", json.array(template.transitions, codec.transition_to_json)),
    #("on_done_template_id", option_json(template.on_done_template_id)),
    #("on_reject_template_id", option_json(template.on_reject_template_id)),
  ])
}

fn instance_body(instance: FlowInstance) -> json.Json {
  json.object([
    #("id", json.string(instance.id)),
    #("template_id", json.string(instance.template_id)),
    #("task_id", json.string(instance.task_id)),
    #("initial_node_id", json.string(instance.initial_node_id)),
    #(
      "nodes",
      json.array(
        instance.nodes |> dict.to_list |> list.map(fn(pair) { pair.1 }),
        codec.node_to_json,
      ),
    ),
    #("transitions", json.array(instance.transitions, codec.transition_to_json)),
    #("on_done_template_id", option_json(instance.on_done_template_id)),
    #("on_reject_template_id", option_json(instance.on_reject_template_id)),
  ])
}

fn execution_body(state: ExecutionState) -> json.Json {
  json.object([
    #("id", json.string(state.id)),
    #("instance_id", json.string(state.flow_instance.id)),
    #("task_id", json.string(state.task_id)),
    #("status", json.string(execution_status_to_string(state.status))),
    #("current_node_id", option_json(state.current_node_id)),
    #("started_at", int_option_json(state.started_at)),
    #("completed_at", int_option_json(state.completed_at)),
  ])
}

fn execution_step_body(state: ExecutionState, action: Action) -> json.Json {
  json.object([
    #("execution", execution_body(state)),
    #("action", action_body(action)),
  ])
}

fn action_body(action: Action) -> json.Json {
  case action {
    RunStep(node, prompt) ->
      json.object([
        #("type", json.string("run_step")),
        #("node", codec.node_to_json(node)),
        #("prompt", json.string(prompt)),
      ])
    AwaitInput(node) ->
      json.object([
        #("type", json.string("await_input")),
        #("node", codec.node_to_json(node)),
      ])
    RunParallel(children) ->
      json.object([
        #("type", json.string("run_parallel")),
        #("children", json.array(children, codec.node_to_json)),
      ])
    FlowComplete -> json.object([#("type", json.string("flow_complete"))])
    FlowReject -> json.object([#("type", json.string("flow_reject"))])
    ExecutionError(message) ->
      json.object([
        #("type", json.string("execution_error")),
        #("message", json.string(message)),
      ])
  }
}

// ─── Decode helpers ───────────────────────────────────────────────────────

/// Build a decoder that requires a field of the given name.
fn required_field_decoder(
  key: String,
  inner: decode.Decoder(a),
) -> decode.Decoder(a) {
  use value <- decode.field(key, inner)
  decode.success(value)
}

/// Build a decoder for an optional string field (missing/null becomes `None`).
fn optional_string_decoder(key: String) -> decode.Decoder(Option(String)) {
  use value <- decode.optional_field(key, None, decode.optional(decode.string))
  decode.success(value)
}

fn decode_string_field(
  body: decode.Dynamic,
  field: String,
) -> Result(String, String) {
  decode.run(body, required_field_decoder(field, decode.string))
  |> result.map_error(fn(_errors) { "Missing or invalid field: " <> field })
}

fn decode_optional_string(
  body: decode.Dynamic,
  field: String,
) -> Result(Option(String), String) {
  decode.run(body, optional_string_decoder(field))
  |> result.map_error(fn(_errors) { "Missing or invalid field: " <> field })
}

fn decode_field_decoded(
  body: decode.Dynamic,
  field: String,
  decoder: decode.Decoder(a),
) -> Result(a, String) {
  decode.run(body, required_field_decoder(field, decoder))
  |> result.map_error(fn(_errors) { "Missing or invalid field: " <> field })
}

// ─── Small helpers ────────────────────────────────────────────────────────

fn option_json(value: Option(String)) -> json.Json {
  case value {
    Some(v) -> json.string(v)
    None -> json.null()
  }
}

fn int_option_json(value: Option(Int)) -> json.Json {
  case value {
    Some(v) -> json.int(v)
    None -> json.null()
  }
}

fn db_to_message(result: Result(a, DbError)) -> Result(a, String) {
  result
  |> result.map_error(with: db_message)
}

fn db_message(error: DbError) -> String {
  case error {
    connection.ConnectionError(message) -> message
    connection.QueryError(message) -> message
    connection.MigrationError(message) -> message
  }
}

fn new_id(prefix: String) -> String {
  prefix <> "-" <> int.to_string(int.random(99_999_999))
}

/// Current wall clock in milliseconds.
pub fn milliseconds_now() -> Int {
  erlang_system_time() / 1_000_000
}

@external(erlang, "erlang", "system_time")
fn erlang_system_time() -> Int
