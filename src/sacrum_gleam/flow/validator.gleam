import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import sacrum_gleam/domain/flow.{
  type BranchRule, type FlowTemplate, type Node, type Transition,
}

/// Validates that a FlowTemplate is well-formed before it can be used.
///
/// Checks:
/// 1. All node IDs are unique
/// 2. initial_node_id references an existing node
/// 3. All child_ids reference existing nodes
/// 4. All transition from_id/to_id reference existing nodes
/// 5. No cycles in the graph (unless through a Loop node)
/// 6. Branch rules reference valid target nodes
/// 7. Loop config child_ids reference existing nodes
/// 8. Step nodes have a prompt
/// 9. Composite nodes have at least one child
pub type ValidationError {
  DuplicateNodeId(id: String)
  MissingInitialNode(id: String)
  MissingChildRef(node_id: String, child_id: String)
  MissingTransitionRef(transition_id: String, node_id: String)
  CycleDetected(path: List(String))
  MissingBranchTarget(rule: BranchRule)
  StepMissingPrompt(node_id: String)
  CompositeNodeHasNoChildren(node_id: String)
}

pub fn validate(template: FlowTemplate) -> Result(Nil, List(ValidationError)) {
  let nodes = template.nodes

  use _ <- result.try(validate_unique_ids(nodes))
  use _ <- result.try(validate_initial_node(template.initial_node_id, nodes))
  use _ <- result.try(validate_child_refs(nodes))
  use _ <- result.try(validate_transitions(template.transitions, nodes))
  use _ <- result.try(validate_branch_rules(nodes))
  use _ <- result.try(validate_step_prompts(nodes))
  use _ <- result.try(validate_composite_children(nodes))

  // Cycle detection: allow cycles only through Loop nodes
  case find_illegal_cycles(template) {
    Ok(Nil) -> Ok(Nil)
    Error(cycles) -> Error(cycles)
  }
}

fn validate_unique_ids(
  _nodes: Dict(String, Node),
) -> Result(Nil, List(ValidationError)) {
  // IDs are dict keys, so they're unique by construction
  Ok(Nil)
}

fn validate_initial_node(
  initial_id: String,
  nodes: Dict(String, Node),
) -> Result(Nil, List(ValidationError)) {
  case dict.get(nodes, initial_id) {
    Ok(_) -> Ok(Nil)
    Error(Nil) -> Error([MissingInitialNode(initial_id)])
  }
}

fn validate_child_refs(
  nodes: Dict(String, Node),
) -> Result(Nil, List(ValidationError)) {
  let errors =
    nodes
    |> dict.to_list
    |> list.flat_map(fn(pair) {
      let #(id, node) = pair
      node.child_ids
      |> list.filter(fn(cid) { dict.get(nodes, cid) == Error(Nil) })
      |> list.map(fn(cid) { MissingChildRef(id, cid) })
    })

  case errors {
    [] -> Ok(Nil)
    _ -> Error(errors)
  }
}

fn validate_transitions(
  transitions: List(Transition),
  nodes: Dict(String, Node),
) -> Result(Nil, List(ValidationError)) {
  let errors =
    transitions
    |> list.flat_map(fn(t) {
      let missing_from = case dict.get(nodes, t.from_id) {
        Ok(_) -> []
        Error(Nil) -> [MissingTransitionRef(t.id, t.from_id)]
      }
      let missing_to = case dict.get(nodes, t.to_id) {
        Ok(_) -> []
        Error(Nil) -> [MissingTransitionRef(t.id, t.to_id)]
      }
      list.append(missing_from, missing_to)
    })

  case errors {
    [] -> Ok(Nil)
    _ -> Error(errors)
  }
}

fn validate_branch_rules(
  nodes: Dict(String, Node),
) -> Result(Nil, List(ValidationError)) {
  let errors =
    nodes
    |> dict.values
    |> list.flat_map(fn(node) {
      node.branch_rules
      |> list.filter(fn(rule) { dict.get(nodes, rule.target_id) == Error(Nil) })
      |> list.map(fn(rule) { MissingBranchTarget(rule) })
    })

  case errors {
    [] -> Ok(Nil)
    _ -> Error(errors)
  }
}

fn validate_step_prompts(
  nodes: Dict(String, Node),
) -> Result(Nil, List(ValidationError)) {
  let errors =
    nodes
    |> dict.values
    |> list.filter(fn(n) { n.node_type == flow.Step })
    |> list.filter_map(fn(n) {
      case n.prompt {
        Some(_) -> Error(Nil)
        None -> Ok(StepMissingPrompt(n.id))
      }
    })

  case errors {
    [] -> Ok(Nil)
    _ -> Error(errors)
  }
}

fn validate_composite_children(
  nodes: Dict(String, Node),
) -> Result(Nil, List(ValidationError)) {
  let composite_types = [
    flow.Sequence,
    flow.Loop,
    flow.Parallel,
  ]

  let errors =
    nodes
    |> dict.values
    |> list.filter(fn(n) { list.contains(composite_types, n.node_type) })
    |> list.filter_map(fn(n) {
      case n.child_ids {
        [] -> Ok(CompositeNodeHasNoChildren(n.id))
        _ -> Error(Nil)
      }
    })

  case errors {
    [] -> Ok(Nil)
    _ -> Error(errors)
  }
}

fn find_illegal_cycles(
  template: FlowTemplate,
) -> Result(Nil, List(ValidationError)) {
  // Build adjacency from transitions + implicit composite edges
  let adj = build_adjacency(template)

  // DFS cycle detection, skipping edges from Loop nodes
  let all_ids = template.nodes |> dict.keys
  case detect_cycle_dfs(all_ids, adj, template.nodes) {
    [] -> Ok(Nil)
    cycles -> Error(cycles)
  }
}

fn build_adjacency(template: FlowTemplate) -> Dict(String, List(String)) {
  // From transitions
  let trans_edges =
    template.transitions
    |> list.map(fn(t) { #(t.from_id, t.to_id) })

  // From composite node child references (sequence order)
  let child_edges =
    template.nodes
    |> dict.values
    |> list.flat_map(fn(node) {
      // For Sequence/Parallel, add edges: child[i] → child[i+1]
      let is_composite =
        list.contains([flow.Sequence, flow.Parallel], node.node_type)

      case is_composite, node.child_ids {
        True, [first, ..rest] ->
          list.zip([first, ..rest], rest)
          |> list.append(
            node.child_ids |> list.take(1) |> list.map(fn(c) { #(node.id, c) }),
          )
        _, _ -> []
      }
    })

  let all_edges = list.append(trans_edges, child_edges)

  all_edges
  |> list.fold(dict.new(), fn(acc, edge) {
    let #(from, to) = edge
    let existing = dict.get(acc, from) |> result.unwrap([])
    dict.insert(acc, from, list.append(existing, [to]))
  })
}

fn detect_cycle_dfs(
  ids: List(String),
  adj: Dict(String, List(String)),
  nodes: Dict(String, Node),
) -> List(ValidationError) {
  ids
  |> list.filter_map(fn(id) { dfs_visit(id, adj, nodes, [], dict.new()) })
}

fn dfs_visit(
  node_id: String,
  adj: Dict(String, List(String)),
  nodes: Dict(String, Node),
  path: List(String),
  visited: Dict(String, Bool),
) -> Result(ValidationError, Nil) {
  case dict.get(nodes, node_id) {
    Error(Nil) -> Error(Nil)
    Ok(node) -> {
      // Do not revisit a node already explored by this DFS run.
      case dict.has_key(visited, node_id) {
        True -> Error(Nil)
        False -> {
          // Loop nodes are allowed to cycle back
          let is_loop = node.node_type == flow.Loop
          let new_path = [node_id, ..path]
          let new_visited = dict.insert(visited, node_id, True)

          let neighbors = dict.get(adj, node_id) |> result.unwrap([])
          neighbors
          |> list.find_map(fn(nid) {
            case list.contains(path, nid), is_loop {
              True, False -> Ok(CycleDetected(list.reverse([nid, ..new_path])))
              True, True -> Error(Nil)
              // Loop nodes can cycle
              False, _ -> dfs_visit(nid, adj, nodes, new_path, new_visited)
            }
          })
        }
      }
    }
  }
}
