/// Unit tests for `sacrum_gleam/flow/validator`.
///
/// Acceptance criterion (issue #18): invalid DAGs are rejected before they can
/// be persisted or instantiated. Two-node cycles were already caught; a
/// transition from a node to itself was not, because the DFS cycle detector
/// short-circuits on the `visited` mark before it ever sees the back edge.
///
/// A self-transition is rejected for every node type, `Loop` included: the
/// executor iterates a loop through `loop_config.child_ids` and its iteration
/// counter (`src/sacrum_gleam/flow/executor.gleam`, `execute_loop`), and never
/// follows a self-edge. `find_next_node` follows the matching transition back
/// to the same node, so a self-transition can only re-dispatch it forever.
///
/// Cycles are legal while they cross a Loop (bounded by `loop_config`) or a
/// Branch (re-routes on every pass): the shipped `review_gate` template loops
/// `gate_branch → fix → re_review → gate_branch` and exits to `done` on
/// approval. Cycles built only from step/composite nodes have no exit and stay
/// rejected.
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import sacrum_gleam/domain/flow.{
  type FlowTemplate, type Node, type Transition, FlowTemplate, Node, Transition,
}
import sacrum_gleam/flow/validator

pub fn main() -> Nil {
  gleeunit.main()
}

// ─── Fixtures ─────────────────────────────────────────────────────────────

fn step(id: String) -> #(String, Node) {
  #(
    id,
    Node(
      id: id,
      name: id,
      node_type: flow.Step,
      goal: "goal of " <> id,
      prompt: Some("prompt of " <> id),
      child_ids: [],
      branch_rules: [],
      loop_config: None,
      agent_config: None,
      output_schema: None,
    ),
  )
}

/// A loop node with one `body` child, matching how the engine iterates it.
fn loop_with_child(id: String, body_id: String) -> #(String, Node) {
  #(
    id,
    Node(
      id: id,
      name: id,
      node_type: flow.Loop,
      goal: "loop until done",
      prompt: None,
      child_ids: [body_id],
      branch_rules: [],
      loop_config: Some(
        flow.LoopConfig(
          max_iterations: Some(3),
          exit_condition: Some("approved"),
          child_ids: [body_id],
        ),
      ),
      agent_config: None,
      output_schema: None,
    ),
  )
}

fn transition(id: String, from: String, to: String) -> Transition {
  Transition(id: id, from_id: from, to_id: to, condition: None, label: None)
}

/// A Branch router: the engine re-evaluates `branch_rules` on every visit.
fn branch(id: String, rules: List(#(String, String))) -> #(String, Node) {
  #(
    id,
    Node(
      id: id,
      name: id,
      node_type: flow.Branch,
      goal: "route on the current variables",
      prompt: None,
      child_ids: [],
      branch_rules: list.map(rules, fn(pair) {
        flow.BranchRule(condition: pair.0, target_id: pair.1)
      }),
      loop_config: None,
      agent_config: None,
      output_schema: None,
    ),
  )
}

fn template(
  initial_node_id: String,
  nodes: List(#(String, Node)),
  transitions: List(Transition),
) -> FlowTemplate {
  FlowTemplate(
    id: "tpl-test",
    name: "validator test",
    description: "",
    initial_node_id: initial_node_id,
    nodes: dict.from_list(nodes),
    transitions: transitions,
    on_done_template_id: None,
    on_reject_template_id: None,
  )
}

fn errors(template: FlowTemplate) -> List(validator.ValidationError) {
  let assert Error(errors) = validator.validate(template)
  errors
}

fn is_cycle(error: validator.ValidationError) -> Bool {
  case error {
    validator.CycleDetected(_) -> True
    _ -> False
  }
}

// ─── Self-transitions ─────────────────────────────────────────────────────

/// The live bug: `step_b → step_b` alongside `step_a → step_b` used to be
/// accepted, and the executor would re-dispatch `step_b` forever.
pub fn self_transition_on_step_node_is_rejected_test() {
  let graph =
    template("step_a", [step("step_a"), step("step_b")], [
      transition("t1", "step_a", "step_b"),
      transition("t2", "step_b", "step_b"),
    ])

  assert errors(graph) == [validator.SelfTransition("step_b")]
}

/// Loops advance through `loop_config.child_ids`; a self-edge is never the
/// engine's loop idiom, so it is rejected on a Loop node too.
pub fn self_transition_on_loop_node_is_rejected_test() {
  let graph =
    template("loop_node", [loop_with_child("loop_node", "body"), step("body")], [
      transition("t1", "loop_node", "loop_node"),
    ])

  assert errors(graph) == [validator.SelfTransition("loop_node")]
}

// ─── Existing cycle detection still works ─────────────────────────────────

pub fn two_node_cycle_is_rejected_test() {
  let graph =
    template("step_a", [step("step_a"), step("step_b")], [
      transition("t1", "step_a", "step_b"),
      transition("t2", "step_b", "step_a"),
    ])

  let found = errors(graph)
  // The detector runs one DFS per node, so a two-node cycle is reported once
  // per entry point; what matters is that it is reported and that no
  // self-transition verdict leaks in.
  assert list.length(found) >= 1
  assert list.all(found, is_cycle)
}

/// A three-node cycle of step nodes still has no way out: `find_next_node`
/// follows the same transition on every pass.
pub fn step_only_three_node_cycle_is_rejected_test() {
  let graph =
    template("step_a", [step("step_a"), step("step_b"), step("step_c")], [
      transition("t1", "step_a", "step_b"),
      transition("t2", "step_b", "step_c"),
      transition("t3", "step_c", "step_a"),
    ])

  let found = errors(graph)
  assert list.length(found) >= 1
  assert list.all(found, is_cycle)
}

/// The shipped `review_gate` shape: `gate → fix → re_review → gate` with a
/// Branch router at the top. The Branch re-evaluates its rules every pass, so
/// the cycle can exit (to `done` once the reviewer approves) — it is legal.
pub fn branch_mediated_cycle_is_accepted_test() {
  let graph =
    template(
      "gate",
      [
        branch("gate", [#("approved", "done"), #("changes", "fix")]),
        step("fix"),
        step("re_review"),
        step("done"),
      ],
      [
        transition("t1", "gate", "fix"),
        transition("t2", "gate", "done"),
        transition("t3", "fix", "re_review"),
        transition("t4", "re_review", "gate"),
      ],
    )

  assert validator.validate(graph) == Ok(Nil)
}

// ─── Valid graphs ─────────────────────────────────────────────────────────

pub fn valid_linear_dag_is_accepted_test() {
  let graph =
    template("step_a", [step("step_a"), step("step_b")], [
      transition("t1", "step_a", "step_b"),
    ])

  assert validator.validate(graph) == Ok(Nil)
}

/// A loop flow that exits to a following step (the shape
/// `flow_engine.build_loop_flow` emits) still validates.
pub fn valid_loop_flow_is_accepted_test() {
  let graph =
    template(
      "loop_node",
      [
        step("lead_in"),
        loop_with_child("loop_node", "body"),
        step("body"),
        step("done"),
      ],
      [
        transition("t1", "lead_in", "loop_node"),
        transition("t2", "loop_node", "done"),
      ],
    )

  assert validator.validate(graph) == Ok(Nil)
}
