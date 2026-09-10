import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import sacrum_gleam/domain/flow.{
  type Node, AgentConfig, BranchRule, LoopConfig, Node, Transition,
}
import sacrum_gleam/json/codec

pub fn main() -> Nil {
  gleeunit.main()
}

// ─── String lists ────────────────────────────────────────────────────────

pub fn empty_string_list_round_trips_test() {
  assert codec.encode_string_list([]) == "[]"
  assert codec.decode_string_list("[]") == Ok([])
  assert codec.decode_string_list(codec.encode_string_list([])) == Ok([])
}

/// The historical failure mode: tags with quotes, commas, and backslashes
/// were persisted unescaped via string concatenation and came back mangled.
/// The codec must escape and restore them exactly.
pub fn string_list_with_quotes_commas_round_trips_test() {
  let tags = ["dev,backend", "a\"quoted\"tag", "back\\slash", "тест", "x]y"]
  let encoded = codec.encode_string_list(tags)

  assert codec.decode_string_list(encoded) == Ok(tags)
}

pub fn string_list_escaping_is_valid_json_test() {
  // The serialized form must be a proper JSON array (escaped quotes),
  // not a comma-joined string like `["a,b","c"d"]`.
  assert codec.encode_string_list(["a,b", "c\"d"]) == "[\"a,b\",\"c\\\"d\"]"
}

pub fn string_list_rejects_non_array_test() {
  assert codec.decode_string_list("{}") |> is_error
  assert codec.decode_string_list("not json") |> is_error
}

// ─── String dicts (execution variables) ─────────────────────────────────

pub fn empty_string_dict_round_trips_test() {
  assert codec.encode_string_dict(dict.new()) == "{}"
  assert codec.decode_string_dict("{}") == Ok(dict.new())
}

pub fn string_dict_round_trips_test() {
  let variables =
    dict.from_list([
      #("attempts", "3"),
      #("branch", "feature/x"),
      #("note", "contains, commas \" and quotes"),
    ])

  let encoded = codec.encode_string_dict(variables)
  assert string.length(encoded) > 0
  assert codec.decode_string_dict(encoded) == Ok(variables)
}

// ─── Int dicts (loop counters) ──────────────────────────────────────────

pub fn int_dict_round_trips_test() {
  let loop_counters =
    dict.from_list([#("retry_loop", 4), #("refactor_loop", 0)])

  let encoded = codec.encode_int_dict(loop_counters)
  assert codec.decode_int_dict(encoded) == Ok(loop_counters)
}

pub fn empty_int_dict_round_trips_test() {
  assert codec.encode_int_dict(dict.new()) == "{}"
  assert codec.decode_int_dict("{}") == Ok(dict.new())
}

// ─── Flow nodes ──────────────────────────────────────────────────────────

fn sample_nodes() -> dict.Dict(String, Node) {
  dict.from_list([
    #(
      "step_a",
      Node(
        id: "step_a",
        name: "Step A",
        node_type: flow.Step,
        goal: "Do the thing",
        prompt: Some("Prompt with \"quotes\" and, commas"),
        child_ids: [],
        branch_rules: [],
        loop_config: None,
        agent_config: Some(AgentConfig(
          model: "claude-sonnet-4-20250514",
          fallback_model: Some("claude-haiku"),
          system_prompt: Some("Be strict"),
          allowed_tools: ["Bash", "Read"],
          disallowed_tools: ["Write"],
          permission_mode: "bypassPermissions",
          max_budget_usd: 5.0,
        )),
        output_schema: Some("{\"type\": \"object\"}"),
      ),
    ),
    #(
      "gate",
      Node(
        id: "gate",
        name: "Gate",
        node_type: flow.Branch,
        goal: "Route by condition",
        prompt: None,
        child_ids: [],
        branch_rules: [
          BranchRule(condition: "approved", target_id: "done"),
          BranchRule(condition: "rejected", target_id: "rollback"),
        ],
        loop_config: None,
        agent_config: None,
        output_schema: None,
      ),
    ),
    #(
      "loop_node",
      Node(
        id: "loop_node",
        name: "Loop",
        node_type: flow.Loop,
        goal: "Repeat until done",
        prompt: None,
        child_ids: ["step_a", "step_b"],
        branch_rules: [],
        loop_config: Some(
          LoopConfig(
            max_iterations: Some(50),
            exit_condition: Some("tests_pass"),
            child_ids: ["step_a", "step_b"],
          ),
        ),
        agent_config: None,
        output_schema: None,
      ),
    ),
  ])
}

pub fn nodes_round_trip_test() {
  let nodes = sample_nodes()
  let encoded = codec.encode_nodes(nodes)

  // The graph is persisted as a JSON array of node objects.
  assert string.starts_with(encoded, "[")

  assert codec.decode_nodes(encoded) == Ok(nodes)
}

pub fn empty_nodes_round_trip_test() {
  assert codec.encode_nodes(dict.new()) == "[]"
  assert codec.decode_nodes("[]") == Ok(dict.new())
}

pub fn nodes_reject_invalid_json_test() {
  assert codec.decode_nodes("[]]") |> is_error
}

// ─── Transitions ─────────────────────────────────────────────────────────

pub fn transitions_round_trip_test() {
  let transitions = [
    Transition(
      id: "t1",
      from_id: "step_a",
      to_id: "gate",
      condition: Some("result == \"ok\""),
      label: Some("on success"),
    ),
    Transition(
      id: "t2",
      from_id: "gate",
      to_id: "step_b",
      condition: None,
      label: None,
    ),
  ]

  let encoded = codec.encode_transitions(transitions)
  assert string.starts_with(encoded, "[")

  assert codec.decode_transitions(encoded) == Ok(transitions)
}

pub fn empty_transitions_round_trip_test() {
  assert codec.encode_transitions([]) == "[]"
  assert codec.decode_transitions("[]") == Ok([])
}

// ─── Parallel runner set ─────────────────────────────────────────────────

pub fn parallel_active_round_trip_test() {
  let active = ["child_a", "child_b", "child_c"]
  assert codec.decode_string_list(codec.encode_string_list(active))
    == Ok(active)
}

// ─── Helpers ─────────────────────────────────────────────────────────────

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Error(_) -> True
    Ok(_) -> False
  }
}
