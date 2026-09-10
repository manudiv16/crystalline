import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sacrum_gleam/domain/execution.{
  type ExecutionState, type ExecutionStatus, type StepExecution, AwaitingInput,
  Completed, ExecutionState, Running, StepCompleted, StepExecution,
  new_execution_state,
}
import sacrum_gleam/domain/flow.{type BranchRule, type FlowInstance, type Node}

/// The flow executor drives a FlowInstance through its nodes.
///
/// Execution model:
///
/// 1. Load the flow's initial node
/// 2. Dispatch based on node type:
///    - Step:        prompt agent, record output, follow transition
///    - Sequence:    execute children in order, advance to next
///    - Branch:      evaluate conditions, pick target, jump
///    - Loop:        execute children, check exit condition, repeat or exit
///    - Parallel:    spawn children concurrently, wait for all
///    - HumanInput:  pause, return AwaitingInput status
/// 3. After node completes, determine next node via:
///    - Explicit transition (if condition matches)
///    - Next sibling in parent composite
///    - Loop back to start or exit
///    - Flow completion
///
/// The executor is pure-functional: it takes a state and returns a new state
/// plus an action to perform. The caller (daemon/Tauri) executes the action
/// and feeds the result back.
pub type Action {
  /// Execute an agent step with this prompt/config
  RunStep(node: Node, prompt: String)
  /// Wait for human input on this node
  AwaitInput(node: Node)
  /// Spawn parallel children
  RunParallel(children: List(Node))
  /// Flow has no more nodes to execute
  FlowComplete
  /// Flow rejected (branch to on_reject)
  FlowReject
  /// Error during execution
  ExecutionError(message: String)
}

pub type ExecuteResult {
  ExecuteResult(state: ExecutionState, action: Action)
}

/// Start executing a flow from its initial node.
pub fn start(instance: FlowInstance, task_id: String) -> ExecutionState {
  let state = new_execution_state(instance, task_id)

  {
    state
    |> set_status(Running)
    |> set_current_node(instance.initial_node_id)
    |> set_started_at
  }
}

/// Advance the execution by one step.
/// Returns updated state and the next action to perform.
pub fn advance(state: ExecutionState) -> ExecuteResult {
  let assert Some(node_id) = state.current_node_id

  case dict.get(state.flow_instance.nodes, node_id) {
    Error(Nil) ->
      ExecuteResult(state, ExecutionError("Node not found: " <> node_id))
    Ok(node) -> {
      let result = dispatch_node(state, node)

      // `advance` is what parks an execution on a human-input node. A step
      // that has just been completed reports the waiting node's action via
      // `complete_step`, but the caller is not waiting yet, so the status is
      // only flipped here.
      case result.action {
        AwaitInput(_) ->
          ExecuteResult(
            ExecutionState(..result.state, status: AwaitingInput),
            result.action,
          )
        _ -> result
      }
    }
  }
}

/// Record that a step execution completed.
pub fn complete_step(
  state: ExecutionState,
  step_exec: StepExecution,
  output: String,
) -> ExecuteResult {
  // Record the step execution
  let updated_step = step_exec |> set_step_output(output) |> set_step_completed

  let state =
    state
    |> add_step_history(updated_step)
    |> clear_current_node

  // Find next node from current completed node
  let completed_node_id = step_exec.node_id

  case dict.get(state.flow_instance.nodes, completed_node_id) {
    Error(Nil) ->
      ExecuteResult(
        state,
        ExecutionError("Node not found: " <> completed_node_id),
      )
    Ok(completed_node) -> find_next_node(state, completed_node)
  }
}

/// Provide human input to resume from an AwaitingInput state.
pub fn provide_input(state: ExecutionState, input: String) -> ExecuteResult {
  let state = state |> set_status(Running)

  let assert Some(node_id) = state.current_node_id
  case dict.get(state.flow_instance.nodes, node_id) {
    Error(Nil) ->
      ExecuteResult(state, ExecutionError("Node not found: " <> node_id))
    Ok(node) -> {
      // Store input as variable for downstream conditions
      let state = state |> set_variable("human_input", input)
      find_next_node(state, node)
    }
  }
}

/// Evaluate a condition expression against the current variable store.
/// This is a simple placeholder — in production, use a proper expression evaluator.
pub fn eval_condition(
  condition: String,
  variables: Dict(String, String),
) -> Bool {
  // Simple variable substitution: "${var_name}" → value
  // For now, just check if the condition is a variable that is set and truthy
  case dict.get(variables, condition) {
    Ok("true") -> True
    Ok("1") -> True
    Ok("yes") -> True
    Ok(_) -> False
    Error(Nil) -> {
      // Check for equality expressions: var=value
      case parse_equality(condition) {
        Some(#(var, val)) -> dict.get(variables, var) == Ok(val)
        None -> False
      }
    }
  }
}

fn parse_equality(expr: String) -> Option(#(String, String)) {
  case string.split(expr, "=") {
    [var, val] -> Some(#(string.trim(var), string.trim(val)))
    _ -> None
  }
}

// ─── Node Type Dispatch ─────────────────────────────────────────────────

fn dispatch_node(state: ExecutionState, node: Node) -> ExecuteResult {
  case node.node_type {
    flow.Step -> execute_step(state, node)
    flow.Sequence -> execute_sequence(state, node)
    flow.Branch -> execute_branch(state, node)
    flow.Loop -> execute_loop(state, node)
    flow.Parallel -> execute_parallel(state, node)
    flow.HumanInput -> execute_human_input(state, node)
  }
}

fn execute_step(state: ExecutionState, node: Node) -> ExecuteResult {
  let prompt = case node.prompt {
    Some(p) -> p
    None -> node.goal
  }

  let state = state |> set_current_node(node.id)
  ExecuteResult(state, RunStep(node, prompt))
}

fn execute_sequence(state: ExecutionState, node: Node) -> ExecuteResult {
  // Find first child that hasn't been completed yet
  let completed_children = get_completed_children(state, node.id)

  case node.child_ids {
    [] -> find_next_node(state, node)
    _ -> {
      let remaining =
        node.child_ids
        |> list.drop(list.length(completed_children))

      case remaining {
        [] -> find_next_node(state, node)
        [next, ..] -> {
          let state = state |> set_current_node(next)
          dispatch_for_node(state, next)
        }
      }
    }
  }
}

fn execute_branch(state: ExecutionState, node: Node) -> ExecuteResult {
  // Evaluate branch rules in order, first match wins
  case find_matching_rule(node.branch_rules, state.variables) {
    Ok(rule) -> {
      let state =
        state
        |> set_current_node(rule.target_id)
        |> set_variable("_last_branch", rule.target_id)
      dispatch_for_node(state, rule.target_id)
    }
    Error(Nil) -> {
      // No condition matched — follow default transition or next node
      find_next_node(state, node)
    }
  }
}

fn execute_loop(state: ExecutionState, node: Node) -> ExecuteResult {
  case node.loop_config {
    None -> {
      let state = state |> set_current_node(node.id)
      ExecuteResult(
        state,
        ExecutionError("Loop node missing loop_config: " <> node.id),
      )
    }
    Some(loop_config) -> {
      let iteration = dict.get(state.loop_counters, node.id) |> result.unwrap(0)

      // Check max iterations
      case loop_config.max_iterations {
        Some(max) if iteration >= max -> {
          // Loop exhausted — exit
          find_next_node(state, node)
        }
        _ -> {
          // Check exit condition
          let should_exit = case loop_config.exit_condition {
            Some(cond) -> eval_condition(cond, state.variables)
            None -> False
          }

          case should_exit {
            True -> find_next_node(state, node)
            False -> {
              // Execute first child of loop
              let state =
                state
                |> increment_loop_counter(node.id)
                |> set_current_node(node.id)

              case loop_config.child_ids {
                [] ->
                  ExecuteResult(
                    state,
                    ExecutionError("Loop has no children: " <> node.id),
                  )
                [first, ..] -> dispatch_for_node(state, first)
              }
            }
          }
        }
      }
    }
  }
}

fn execute_parallel(state: ExecutionState, node: Node) -> ExecuteResult {
  let state = state |> set_current_node(node.id)

  case node.child_ids {
    [] -> find_next_node(state, node)
    children -> {
      let child_nodes =
        children
        |> list.filter_map(fn(cid) { dict.get(state.flow_instance.nodes, cid) })

      let state = state |> set_parallel_active(children)
      ExecuteResult(state, RunParallel(child_nodes))
    }
  }
}

fn execute_human_input(state: ExecutionState, node: Node) -> ExecuteResult {
  // The status flip to `AwaitingInput` happens in `advance`, not here, so
  // that `complete_step` can report the pending action without parking.
  ExecuteResult(state |> set_current_node(node.id), AwaitInput(node))
}

// ─── Next Node Resolution ───────────────────────────────────────────────

fn find_next_node(
  state: ExecutionState,
  completed_node: Node,
) -> ExecuteResult {
  let instance = state.flow_instance

  // 1. Check for matching transition from completed node
  let matching_transition =
    instance.transitions
    |> list.filter(fn(t) { t.from_id == completed_node.id })
    |> list.find(fn(t) {
      case t.condition {
        Some(cond) -> eval_condition(cond, state.variables)
        None -> True
        // unconditional transition
      }
    })

  case matching_transition {
    Ok(t) -> {
      // Check if this leads to flow completion
      case dict.get(instance.nodes, t.to_id) {
        Error(Nil) -> {
          // No such node — flow complete
          let state =
            state
            |> set_status(Completed)
            |> set_completed_at
          ExecuteResult(state, FlowComplete)
        }
        Ok(_next_node) -> dispatch_for_node(state, t.to_id)
      }
    }
    Error(Nil) -> {
      // 2. No transition — check if this was the last node in a composite
      //    or if we should complete the flow
      case
        completed_node.id == instance.initial_node_id
        && instance.transitions == []
      {
        True -> {
          let state =
            state
            |> set_status(Completed)
            |> set_completed_at
          ExecuteResult(state, FlowComplete)
        }
        False -> {
          // 3. Try to find parent composite's next sibling
          find_sibling_or_complete(state, completed_node)
        }
      }
    }
  }
}

fn find_sibling_or_complete(
  state: ExecutionState,
  completed_node: Node,
) -> ExecuteResult {
  // Walk through all composite nodes to find which one contains completed_node
  let composites =
    state.flow_instance.nodes
    |> dict.values
    |> list.filter(fn(n) {
      list.contains([flow.Sequence, flow.Parallel], n.node_type)
      && list.contains(n.child_ids, completed_node.id)
    })

  case composites {
    [] -> {
      // Not in a composite — check if flow is done
      let state =
        state
        |> set_status(Completed)
        |> set_completed_at
      ExecuteResult(state, FlowComplete)
    }
    [parent, ..] -> {
      // Find next sibling
      let idx =
        parent.child_ids
        |> index_of(completed_node.id)

      case list.drop(parent.child_ids, idx + 1) {
        [] -> {
          // Last child — parent composite is done, find parent's next
          find_next_node(state, parent)
        }
        [next, ..] -> dispatch_for_node(state, next)
      }
    }
  }
}

fn dispatch_for_node(state: ExecutionState, node_id: String) -> ExecuteResult {
  case dict.get(state.flow_instance.nodes, node_id) {
    Error(Nil) -> {
      ExecuteResult(state, ExecutionError("Node not found: " <> node_id))
    }
    Ok(node) -> dispatch_node(state |> set_current_node(node_id), node)
  }
}

// ─── State Helpers ──────────────────────────────────────────────────────

fn set_status(
  state: ExecutionState,
  status: ExecutionStatus,
) -> ExecutionState {
  ExecutionState(..state, status: status)
}

fn set_current_node(state: ExecutionState, node_id: String) -> ExecutionState {
  ExecutionState(..state, current_node_id: Some(node_id))
}

fn clear_current_node(state: ExecutionState) -> ExecutionState {
  ExecutionState(..state, current_node_id: None)
}

fn set_started_at(state: ExecutionState) -> ExecutionState {
  ExecutionState(..state, started_at: Some(0))
}

fn set_completed_at(state: ExecutionState) -> ExecutionState {
  ExecutionState(..state, completed_at: Some(0))
}

fn set_variable(
  state: ExecutionState,
  key: String,
  value: String,
) -> ExecutionState {
  ExecutionState(..state, variables: dict.insert(state.variables, key, value))
}

fn add_step_history(
  state: ExecutionState,
  step: StepExecution,
) -> ExecutionState {
  ExecutionState(..state, step_history: [step, ..state.step_history])
}

fn increment_loop_counter(
  state: ExecutionState,
  loop_id: String,
) -> ExecutionState {
  let current = dict.get(state.loop_counters, loop_id) |> result.unwrap(0)
  ExecutionState(
    ..state,
    loop_counters: dict.insert(state.loop_counters, loop_id, current + 1),
  )
}

fn set_parallel_active(
  state: ExecutionState,
  ids: List(String),
) -> ExecutionState {
  ExecutionState(..state, parallel_active: ids)
}

fn get_completed_children(
  state: ExecutionState,
  parent_id: String,
) -> List(String) {
  state.step_history
  |> list.filter(fn(s) { s.status == StepCompleted })
  |> list.map(fn(s) { s.node_id })
  |> list.filter(fn(nid) {
    // Check if this node is a child of the parent
    case dict.get(state.flow_instance.nodes, parent_id) {
      Ok(parent) -> list.contains(parent.child_ids, nid)
      Error(Nil) -> False
    }
  })
}

fn set_step_output(step: StepExecution, output: String) -> StepExecution {
  StepExecution(..step, output: Some(output))
}

fn set_step_completed(step: StepExecution) -> StepExecution {
  StepExecution(..step, status: StepCompleted)
}

/// Find the first branch rule whose condition evaluates to true.
fn find_matching_rule(
  rules: List(BranchRule),
  variables: Dict(String, String),
) -> Result(BranchRule, Nil) {
  list.find(rules, fn(rule) { eval_condition(rule.condition, variables) })
}

/// Return the zero-based index of the first occurrence of `target`, or 0.
fn index_of(items: List(String), target: String) -> Int {
  case
    items
    |> list.index_map(fn(item, i) { #(item, i) })
    |> list.find(fn(pair) { pair.0 == target })
  {
    Ok(#(_, i)) -> i
    Error(Nil) -> 0
  }
}
