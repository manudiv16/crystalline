import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sacrum_gleam/domain/execution.{
  type ExecutionState, type ExecutionStatus, type StepExecution,
}
import sacrum_gleam/domain/flow.{
  type FlowInstance, type FlowTemplate, type Transition, FlowInstance,
  FlowTemplate,
}
import sacrum_gleam/flow/executor.{type Action}
import sacrum_gleam/flow/validator

/// Public API for the flow engine.
///
/// The engine manages the full lifecycle:
/// 1. Create/validate FlowTemplates
/// 2. Instantiate a FlowInstance from a template + task
/// 3. Drive execution step by step
/// 4. Handle completion/rejection/chaining
pub type EngineError {
  ValidationError(errors: List(validator.ValidationError))
  NoSuchTemplate(id: String)
  NoSuchInstance(id: String)
  NoSuchStep(id: String)
  InvalidStateTransition(from: ExecutionStatus, to: ExecutionStatus)
}

/// Registry of known flow templates.
pub type TemplateRegistry {
  TemplateRegistry(templates: Dict(String, FlowTemplate))
}

/// Active execution states keyed by instance ID.
pub type ExecutionRegistry {
  ExecutionRegistry(states: Dict(String, ExecutionState))
}

/// The engine holds both registries.
pub type Engine {
  Engine(templates: TemplateRegistry, executions: ExecutionRegistry)
}

pub fn new_engine() -> Engine {
  Engine(
    templates: TemplateRegistry(dict.new()),
    executions: ExecutionRegistry(dict.new()),
  )
}

// ─── Template Management ────────────────────────────────────────────────

pub fn register_template(
  engine: Engine,
  template: FlowTemplate,
) -> Result(Engine, EngineError) {
  use _ <- result.try(
    validator.validate(template)
    |> result.map_error(fn(errors) { ValidationError(errors) }),
  )
  let templates = dict.insert(engine.templates.templates, template.id, template)
  Ok(Engine(..engine, templates: TemplateRegistry(templates)))
}

pub fn get_template(
  engine: Engine,
  id: String,
) -> Result(FlowTemplate, EngineError) {
  case dict.get(engine.templates.templates, id) {
    Ok(t) -> Ok(t)
    Error(Nil) -> Error(NoSuchTemplate(id))
  }
}

pub fn list_templates(engine: Engine) -> List(FlowTemplate) {
  engine.templates.templates |> dict.values
}

// ─── Flow Instantiation ─────────────────────────────────────────────────

/// Create a FlowInstance from a template and bind it to a task.
pub fn instantiate_flow(
  engine: Engine,
  template_id: String,
  task_id: String,
) -> Result(#(Engine, FlowInstance), EngineError) {
  use template <- result.try(get_template(engine, template_id))

  let instance =
    FlowInstance(
      id: "",
      // assigned by DB layer
      template_id: template_id,
      task_id: task_id,
      nodes: template.nodes,
      transitions: template.transitions,
      initial_node_id: template.initial_node_id,
      on_done_template_id: template.on_done_template_id,
      on_reject_template_id: template.on_reject_template_id,
    )

  let state = executor.start(instance, task_id)
  let states = dict.insert(engine.executions.states, instance.id, state)

  let engine = Engine(..engine, executions: ExecutionRegistry(states))

  Ok(#(engine, instance))
}

// ─── Execution Control ──────────────────────────────────────────────────

/// Advance execution by one step.
/// Returns updated engine, instance ID, and the action to perform.
pub fn advance_execution(
  engine: Engine,
  instance_id: String,
) -> Result(#(Engine, String, Action), EngineError) {
  use state <- result.try(case dict.get(engine.executions.states, instance_id) {
    Ok(s) -> Ok(s)
    Error(Nil) -> Error(NoSuchInstance(instance_id))
  })

  let execute_result = executor.advance(state)
  let states =
    dict.insert(engine.executions.states, instance_id, execute_result.state)

  Ok(#(
    Engine(..engine, executions: ExecutionRegistry(states)),
    instance_id,
    execute_result.action,
  ))
}

/// Report that a step execution completed.
pub fn complete_step(
  engine: Engine,
  instance_id: String,
  step_exec: StepExecution,
  output: String,
) -> Result(#(Engine, String, Action), EngineError) {
  use state <- result.try(case dict.get(engine.executions.states, instance_id) {
    Ok(s) -> Ok(s)
    Error(Nil) -> Error(NoSuchInstance(instance_id))
  })

  let execute_result = executor.complete_step(state, step_exec, output)
  let states =
    dict.insert(engine.executions.states, instance_id, execute_result.state)

  Ok(#(
    Engine(..engine, executions: ExecutionRegistry(states)),
    instance_id,
    execute_result.action,
  ))
}

/// Provide human input to resume from AwaitingInput.
pub fn provide_input(
  engine: Engine,
  instance_id: String,
  input: String,
) -> Result(#(Engine, String, Action), EngineError) {
  use state <- result.try(case dict.get(engine.executions.states, instance_id) {
    Ok(s) -> Ok(s)
    Error(Nil) -> Error(NoSuchInstance(instance_id))
  })

  let execute_result = executor.provide_input(state, input)
  let states =
    dict.insert(engine.executions.states, instance_id, execute_result.state)

  Ok(#(
    Engine(..engine, executions: ExecutionRegistry(states)),
    instance_id,
    execute_result.action,
  ))
}

/// Get current execution state for an instance.
pub fn get_execution(
  engine: Engine,
  instance_id: String,
) -> Result(ExecutionState, EngineError) {
  case dict.get(engine.executions.states, instance_id) {
    Ok(s) -> Ok(s)
    Error(Nil) -> Error(NoSuchInstance(instance_id))
  }
}

// ─── Flow Chaining ──────────────────────────────────────────────────────

/// When a flow completes, check if it chains to another flow.
pub fn handle_flow_complete(
  engine: Engine,
  instance_id: String,
  task_id: String,
) -> Result(#(Engine, Option(String)), EngineError) {
  use state <- result.try(get_execution(engine, instance_id))

  case state.flow_instance.on_done_template_id {
    Some(next_template_id) -> {
      // Instantiate the next flow
      let result = instantiate_flow(engine, next_template_id, task_id)
      case result {
        Ok(#(new_engine, next_instance)) ->
          Ok(#(new_engine, Some(next_instance.id)))
        Error(e) -> Error(e)
      }
    }
    None -> Ok(#(engine, None))
  }
}

/// When a flow is rejected, check if it chains to a rejection flow.
pub fn handle_flow_reject(
  engine: Engine,
  instance_id: String,
  task_id: String,
) -> Result(#(Engine, Option(String)), EngineError) {
  use state <- result.try(get_execution(engine, instance_id))

  case state.flow_instance.on_reject_template_id {
    Some(reject_template_id) -> {
      let result = instantiate_flow(engine, reject_template_id, task_id)
      case result {
        Ok(#(new_engine, next_instance)) ->
          Ok(#(new_engine, Some(next_instance.id)))
        Error(e) -> Error(e)
      }
    }
    None -> Ok(#(engine, None))
  }
}

// ─── Flow Builder Helpers ───────────────────────────────────────────────

/// Create a linear flow: step1 → step2 → step3 → done
pub fn build_linear_flow(
  name: String,
  description: String,
  steps: List(#(String, String)),
) -> FlowTemplate {
  // steps = #("step_id", "prompt")
  let node_ids = steps |> list.map(fn(s) { s.0 })
  let initial = case node_ids {
    [first, ..] -> first
    [] -> ""
  }

  let nodes =
    steps
    |> list.map(fn(pair) {
      let #(id, prompt) = pair
      let node =
        flow.Node(
          id: id,
          name: id,
          node_type: flow.Step,
          goal: prompt,
          prompt: Some(prompt),
          child_ids: [],
          branch_rules: [],
          loop_config: None,
          agent_config: None,
          output_schema: None,
        )
      #(id, node)
    })
    |> dict.from_list

  let transitions = build_chain_transitions(node_ids)

  FlowTemplate(
    id: "",
    name: name,
    description: description,
    initial_node_id: initial,
    nodes: nodes,
    transitions: transitions,
    on_done_template_id: None,
    on_reject_template_id: None,
  )
}

/// Create a flow with a loop: step → loop(step_a, step_b) → step_done
pub fn build_loop_flow(
  name: String,
  description: String,
  pre_loop_steps: List(#(String, String)),
  loop_steps: List(#(String, String)),
  post_loop_steps: List(#(String, String)),
  exit_condition: String,
  max_iterations: Int,
) -> FlowTemplate {
  let all_steps =
    list.append(
      pre_loop_steps,
      list.append(
        [#("loop_node", "Loop until " <> exit_condition)],
        list.append(loop_steps, post_loop_steps),
      ),
    )

  let loop_step_ids = loop_steps |> list.map(fn(s) { s.0 })
  let loop_node_id = "loop_node"

  let nodes_dict =
    all_steps
    |> list.map(fn(pair) {
      let #(id, prompt) = pair
      let node_type = case id {
        "loop_node" -> flow.Loop
        _ -> flow.Step
      }

      let loop_cfg = case id {
        "loop_node" ->
          Some(flow.LoopConfig(
            max_iterations: Some(max_iterations),
            exit_condition: Some(exit_condition),
            child_ids: loop_step_ids,
          ))
        _ -> None
      }

      let node =
        flow.Node(
          id: id,
          name: id,
          node_type: node_type,
          goal: prompt,
          prompt: case node_type {
            flow.Step -> Some(prompt)
            _ -> None
          },
          child_ids: case id {
            "loop_node" -> loop_step_ids
            _ -> []
          },
          branch_rules: [],
          loop_config: loop_cfg,
          agent_config: None,
          output_schema: None,
        )
      #(id, node)
    })
    |> dict.from_list

  // Build transitions: pre_loop → loop_node → post_loop
  let pre_ids = pre_loop_steps |> list.map(fn(s) { s.0 })
  let post_ids = post_loop_steps |> list.map(fn(s) { s.0 })

  let transitions =
    list.append(
      build_chain_transitions(pre_ids),
      build_chain_transitions([loop_node_id, ..post_ids]),
    )

  let initial = case pre_ids {
    [first, ..] -> first
    [] -> loop_node_id
  }

  FlowTemplate(
    id: "",
    name: name,
    description: description,
    initial_node_id: initial,
    nodes: nodes_dict,
    transitions: transitions,
    on_done_template_id: None,
    on_reject_template_id: None,
  )
}

/// Create a flow with a branch: step → branch(conditions) → step_a | step_b
pub fn build_branch_flow(
  name: String,
  description: String,
  initial_step: #(String, String),
  branch_rules: List(#(String, String)),
  fallback_step: Option(#(String, String)),
) -> FlowTemplate {
  let branch_id = "branch_" <> initial_step.0
  let branch_rules_typed =
    branch_rules
    |> list.map(fn(pair) {
      let #(condition, target_id) = pair
      flow.BranchRule(condition: condition, target_id: target_id)
    })

  let step_node =
    flow.Node(
      id: initial_step.0,
      name: initial_step.0,
      node_type: flow.Step,
      goal: initial_step.1,
      prompt: Some(initial_step.1),
      child_ids: [],
      branch_rules: [],
      loop_config: None,
      agent_config: None,
      output_schema: None,
    )

  let branch_node =
    flow.Node(
      id: branch_id,
      name: "Branch after " <> initial_step.0,
      node_type: flow.Branch,
      goal: "Route based on conditions",
      prompt: None,
      child_ids: [],
      branch_rules: branch_rules_typed,
      loop_config: None,
      agent_config: None,
      output_schema: None,
    )

  let target_nodes =
    branch_rules
    |> list.map(fn(pair) { pair.1 })
    |> list.append(case fallback_step {
      Some(s) -> [s.0]
      None -> []
    })

  let target_step_nodes =
    target_nodes
    |> list.unique
    |> list.map(fn(tid) {
      // Find if this target has a step definition
      let all_steps = [initial_step]
      case list.find(all_steps, fn(s) { s.0 == tid }) {
        Ok(s) -> #(
          tid,
          flow.Node(
            id: tid,
            name: tid,
            node_type: flow.Step,
            goal: s.1,
            prompt: Some(s.1),
            child_ids: [],
            branch_rules: [],
            loop_config: None,
            agent_config: None,
            output_schema: None,
          ),
        )
        Error(Nil) -> #(
          tid,
          flow.Node(
            id: tid,
            name: tid,
            node_type: flow.Step,
            goal: "Step " <> tid,
            prompt: Some("Execute " <> tid),
            child_ids: [],
            branch_rules: [],
            loop_config: None,
            agent_config: None,
            output_schema: None,
          ),
        )
      }
    })

  let all_nodes = [
    #(initial_step.0, step_node),
    #(branch_id, branch_node),
    ..target_step_nodes
  ]

  let transitions = [
    flow.Transition(
      id: "t1",
      from_id: initial_step.0,
      to_id: branch_id,
      condition: None,
      label: None,
    ),
  ]

  FlowTemplate(
    id: "",
    name: name,
    description: description,
    initial_node_id: initial_step.0,
    nodes: dict.from_list(all_nodes),
    transitions: transitions,
    on_done_template_id: None,
    on_reject_template_id: None,
  )
}

fn build_chain_transitions(ids: List(String)) -> List(Transition) {
  let pairs = list.zip(ids, list.drop(ids, 1))
  list.index_map(pairs, fn(pair, i) {
    let #(from, to) = pair
    flow.Transition(
      id: "t_" <> int.to_string(i),
      from_id: from,
      to_id: to,
      condition: None,
      label: None,
    )
  })
}
