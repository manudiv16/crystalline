import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sacrum_gleam/domain/flow.{
  type AgentConfig, type BranchRule, type LoopConfig, type Node, type NodeType,
  type Transition, AgentConfig, BranchRule, LoopConfig, Node, Transition,
}

// JSON codecs for every structure persisted by the database layer.
//
// Each codec is a pair of functions:
//
// - `encode_*` renders the value as a JSON string via `gleam_json`
// - `decode_*` parses that string back into the value
//
// The codecs are lossless: `decode(encode(x)) == x` for every value they
// accept. No persisted structure is ever hand-assembled with string
// concatenation — that is what broke escaping for quotes/commas before.
//
// List/Dict codecs are generic over their element/value type; the concrete
// helpers used by the persistence layer (string lists, string/int dicts)
// are thin wrappers on top.

// ─── Generic list codecs ────────────────────────────────────────────────

/// Encode a list of values as a JSON array string using `encode_value`.
pub fn encode_list(
  values: List(a),
  encode_value: fn(a) -> json.Json,
) -> String {
  json.to_string(json.array(values, encode_value))
}

/// Decode a JSON array string into a list using `decoder`.
pub fn decode_list(
  raw: String,
  decoder: decode.Decoder(a),
) -> Result(List(a), String) {
  parse(raw, decode.list(decoder))
}

pub fn encode_string_list(values: List(String)) -> String {
  encode_list(values, json.string)
}

pub fn decode_string_list(raw: String) -> Result(List(String), String) {
  decode_list(raw, decode.string)
}

// ─── Generic dict codecs ────────────────────────────────────────────────

/// Encode a string-keyed dict as a JSON object string using `encode_value`.
pub fn encode_dict(
  values: Dict(String, a),
  encode_value: fn(a) -> json.Json,
) -> String {
  json.to_string(json.dict(values, fn(key) { key }, encode_value))
}

/// Decode a JSON object string into a string-keyed dict using `decoder`.
pub fn decode_dict(
  raw: String,
  decoder: decode.Decoder(a),
) -> Result(Dict(String, a), String) {
  parse(raw, decode.dict(decode.string, decoder))
}

/// Codec for `Dict(String, String)` — execution variables.
pub fn encode_string_dict(values: Dict(String, String)) -> String {
  encode_dict(values, json.string)
}

pub fn decode_string_dict(raw: String) -> Result(Dict(String, String), String) {
  decode_dict(raw, decode.string)
}

/// Codec for `Dict(String, Int)` — loop counters.
pub fn encode_int_dict(values: Dict(String, Int)) -> String {
  encode_dict(values, json.int)
}

pub fn decode_int_dict(raw: String) -> Result(Dict(String, Int), String) {
  decode_dict(raw, decode.int)
}

// ─── Flow graph codecs ──────────────────────────────────────────────────

/// Encode a node graph (`Dict(String, Node)` keyed by node id) as a JSON
/// array of node objects. The id is stored inside each node object; decoding
/// rebuilds the dict keyed by `node.id`.
pub fn encode_nodes(nodes: Dict(String, Node)) -> String {
  nodes
  |> dict.to_list
  |> list.map(fn(pair) { encode_node(pair.1) })
  |> json.preprocessed_array
  |> json.to_string
}

/// Decode a JSON array of node objects back into a `Dict(String, Node)`.
pub fn decode_nodes(raw: String) -> Result(Dict(String, Node), String) {
  use array <- result.try(parse(raw, decode.list(node_decoder())))
  Ok(dict.from_list(list.map(array, fn(node) { #(node.id, node) })))
}

/// Encode a transition list as a JSON array of transition objects.
pub fn encode_transitions(transitions: List(Transition)) -> String {
  transitions
  |> list.map(encode_transition)
  |> json.preprocessed_array
  |> json.to_string
}

/// Decode a JSON array of transition objects back into a list.
pub fn decode_transitions(raw: String) -> Result(List(Transition), String) {
  parse(raw, decode.list(transition_decoder()))
}

/// Encode a single node as a JSON object.
pub fn node_to_json(node: Node) -> json.Json {
  encode_node(node)
}

/// Encode a single transition as a JSON object.
pub fn transition_to_json(transition: Transition) -> json.Json {
  encode_transition(transition)
}

/// Decoder for a single node object. Exposed so HTTP routes can decode
/// `nodes` arrays from request bodies.
pub fn node_decoder() -> decode.Decoder(Node) {
  node_decoder_impl()
}

/// Decoder for a single transition object. Exposed so HTTP routes can
/// decode `transitions` arrays from request bodies.
pub fn transition_decoder() -> decode.Decoder(Transition) {
  transition_decoder_impl()
}

// ─── Node encoding ──────────────────────────────────────────────────────

fn encode_node(node: Node) -> json.Json {
  json.object([
    #("id", json.string(node.id)),
    #("name", json.string(node.name)),
    #("node_type", json.string(node_type_to_string(node.node_type))),
    #("goal", json.string(node.goal)),
    #("prompt", option_to_json(node.prompt, json.string)),
    #("child_ids", json.array(node.child_ids, json.string)),
    #("branch_rules", branch_rules_to_json(node.branch_rules)),
    #("loop_config", option_to_json(node.loop_config, encode_loop_config)),
    #("agent_config", option_to_json(node.agent_config, encode_agent_config)),
    #("output_schema", option_to_json(node.output_schema, json.string)),
  ])
}

fn encode_transition(transition: Transition) -> json.Json {
  json.object([
    #("id", json.string(transition.id)),
    #("from_id", json.string(transition.from_id)),
    #("to_id", json.string(transition.to_id)),
    #("condition", option_to_json(transition.condition, json.string)),
    #("label", option_to_json(transition.label, json.string)),
  ])
}

fn branch_rules_to_json(rules: List(BranchRule)) -> json.Json {
  rules
  |> list.map(fn(rule) {
    json.object([
      #("condition", json.string(rule.condition)),
      #("target_id", json.string(rule.target_id)),
    ])
  })
  |> json.preprocessed_array
}

fn encode_loop_config(config: LoopConfig) -> json.Json {
  json.object([
    #("max_iterations", option_to_json(config.max_iterations, json.int)),
    #("exit_condition", option_to_json(config.exit_condition, json.string)),
    #("child_ids", json.array(config.child_ids, json.string)),
  ])
}

fn encode_agent_config(config: AgentConfig) -> json.Json {
  json.object([
    #("model", json.string(config.model)),
    #("fallback_model", option_to_json(config.fallback_model, json.string)),
    #("system_prompt", option_to_json(config.system_prompt, json.string)),
    #("allowed_tools", json.array(config.allowed_tools, json.string)),
    #("disallowed_tools", json.array(config.disallowed_tools, json.string)),
    #("permission_mode", json.string(config.permission_mode)),
    #("max_budget_usd", json.float(config.max_budget_usd)),
  ])
}

fn option_to_json(option: Option(a), to_json: fn(a) -> json.Json) -> json.Json {
  case option {
    Some(value) -> to_json(value)
    None -> json.null()
  }
}

fn node_type_to_string(node_type: NodeType) -> String {
  case node_type {
    flow.Step -> "step"
    flow.Sequence -> "sequence"
    flow.Branch -> "branch"
    flow.Loop -> "loop"
    flow.Parallel -> "parallel"
    flow.HumanInput -> "human_input"
  }
}

// ─── Node decoding ──────────────────────────────────────────────────────

fn node_decoder_impl() -> decode.Decoder(Node) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use node_type <- decode.field("node_type", node_type_decoder())
  use goal <- decode.field("goal", decode.string)
  use prompt <- decode.optional_field(
    "prompt",
    None,
    decode.optional(decode.string),
  )
  use child_ids <- decode.field("child_ids", decode.list(decode.string))
  use branch_rules <- decode.field(
    "branch_rules",
    decode.list(branch_rule_decoder()),
  )
  use loop_config <- decode.optional_field(
    "loop_config",
    None,
    decode.optional(loop_config_decoder()),
  )
  use agent_config <- decode.optional_field(
    "agent_config",
    None,
    decode.optional(agent_config_decoder()),
  )
  use output_schema <- decode.optional_field(
    "output_schema",
    None,
    decode.optional(decode.string),
  )

  decode.success(Node(
    id: id,
    name: name,
    node_type: node_type,
    goal: goal,
    prompt: prompt,
    child_ids: child_ids,
    branch_rules: branch_rules,
    loop_config: loop_config,
    agent_config: agent_config,
    output_schema: output_schema,
  ))
}

fn transition_decoder_impl() -> decode.Decoder(Transition) {
  use id <- decode.field("id", decode.string)
  use from_id <- decode.field("from_id", decode.string)
  use to_id <- decode.field("to_id", decode.string)
  use condition <- decode.optional_field(
    "condition",
    None,
    decode.optional(decode.string),
  )
  use label <- decode.optional_field(
    "label",
    None,
    decode.optional(decode.string),
  )

  decode.success(Transition(
    id: id,
    from_id: from_id,
    to_id: to_id,
    condition: condition,
    label: label,
  ))
}

fn branch_rule_decoder() -> decode.Decoder(BranchRule) {
  use condition <- decode.field("condition", decode.string)
  use target_id <- decode.field("target_id", decode.string)

  decode.success(BranchRule(condition: condition, target_id: target_id))
}

fn loop_config_decoder() -> decode.Decoder(LoopConfig) {
  use max_iterations <- decode.optional_field(
    "max_iterations",
    None,
    decode.optional(decode.int),
  )
  use exit_condition <- decode.optional_field(
    "exit_condition",
    None,
    decode.optional(decode.string),
  )
  use child_ids <- decode.field("child_ids", decode.list(decode.string))

  decode.success(LoopConfig(
    max_iterations: max_iterations,
    exit_condition: exit_condition,
    child_ids: child_ids,
  ))
}

fn agent_config_decoder() -> decode.Decoder(AgentConfig) {
  use model <- decode.field("model", decode.string)
  use fallback_model <- decode.optional_field(
    "fallback_model",
    None,
    decode.optional(decode.string),
  )
  use system_prompt <- decode.optional_field(
    "system_prompt",
    None,
    decode.optional(decode.string),
  )
  use allowed_tools <- decode.field("allowed_tools", decode.list(decode.string))
  use disallowed_tools <- decode.field(
    "disallowed_tools",
    decode.list(decode.string),
  )
  use permission_mode <- decode.field("permission_mode", decode.string)
  use max_budget_usd <- decode.field("max_budget_usd", decode.float)

  decode.success(AgentConfig(
    model: model,
    fallback_model: fallback_model,
    system_prompt: system_prompt,
    allowed_tools: allowed_tools,
    disallowed_tools: disallowed_tools,
    permission_mode: permission_mode,
    max_budget_usd: max_budget_usd,
  ))
}

fn node_type_decoder() -> decode.Decoder(NodeType) {
  decode.then(decode.string, fn(raw) {
    case node_type_from_string(raw) {
      Ok(node_type) -> decode.success(node_type)
      Error(_) -> decode.failure(flow.Step, "node_type: " <> raw)
    }
  })
}

fn node_type_from_string(raw: String) -> Result(NodeType, String) {
  case raw {
    "step" -> Ok(flow.Step)
    "sequence" -> Ok(flow.Sequence)
    "branch" -> Ok(flow.Branch)
    "loop" -> Ok(flow.Loop)
    "parallel" -> Ok(flow.Parallel)
    "human_input" -> Ok(flow.HumanInput)
    _ -> Error("Unknown node type: " <> raw)
  }
}

// ─── Shared parse helper ────────────────────────────────────────────────

fn parse(raw: String, decoder: decode.Decoder(a)) -> Result(a, String) {
  case json.parse(raw, decoder) {
    Ok(value) -> Ok(value)
    Error(_) -> Error("Could not decode JSON: " <> raw)
  }
}
