import gleam/dict
import gleam/option.{Option, Some, None}
import gleam/list

/// The core innovation: moldable, composable agent control flows.
///
/// A Flow is a directed graph of Nodes. Each node has an execution type
/// that determines how the engine processes it:
///
/// - Step:        atomic agent action (prompt, tools, model config)
/// - Sequence:    ordered execution of child nodes
/// - Branch:      evaluate conditions to pick the next node
/// - Loop:        repeat child nodes until exit condition is met
/// - Parallel:    run child nodes concurrently
/// - HumanInput:  pause execution and wait for external input
///
/// Nodes can nest: a Sequence can contain a Loop, a Branch can contain
/// Steps, etc. The engine resolves the graph recursively at execution time.

// ─── Node Type ───────────────────────────────────────────────────────────

pub type NodeType {
  Step
  Sequence
  Branch
  Loop
  Parallel
  HumanInput
}

pub type BranchRule {
  BranchRule(condition: String, target_id: String)
}

pub type LoopConfig {
  LoopConfig(
    max_iterations: Option(Int),
    exit_condition: Option(String),
    child_ids: List(String),
  )
}

pub type AgentConfig {
  AgentConfig(
    model: String,
    fallback_model: Option(String),
    system_prompt: Option(String),
    allowed_tools: List(String),
    disallowed_tools: List(String),
    permission_mode: String,
    max_budget_usd: Float,
  )
}

pub type Node {
  Node(
    id: String,
    name: String,
    node_type: NodeType,
    /// What this step/branch/loop accomplishes
    goal: String,
    /// Prompt template for Step/HumanInput nodes
    prompt: Option(String),
    /// Child node IDs for composite nodes (Sequence, Loop, Parallel)
    child_ids: List(String),
    /// Branch rules: condition → target node
    branch_rules: List(BranchRule),
    /// Loop configuration
    loop_config: Option(LoopConfig),
    /// Agent LLM config for Step nodes
    agent_config: Option(AgentConfig),
    /// JSON Schema for structured output (Step/Evaluate)
    output_schema: Option(String),
  )
}

pub type Transition {
  Transition(
    id: String,
    from_id: String,
    to_id: String,
    /// Optional guard expression evaluated at runtime
    condition: Option(String),
    /// Human-readable label
    label: Option(String),
  )
}

// ─── Flow Template (reusable definition) ─────────────────────────────────

/// A FlowTemplate is a named, reusable flow definition.
/// When a task picks up a flow, a FlowInstance is created from this template.
pub type FlowTemplate {
  FlowTemplate(
    id: String,
    name: String,
    description: String,
    /// Entry point node ID
    initial_node_id: String,
    nodes: Dict(String, Node),
    transitions: List(Transition),
    /// When this flow completes, optionally chain to another
    on_done_template_id: Option(String),
    /// When rejected, chain to another flow
    on_reject_template_id: Option(String),
  )
}

// ─── Flow Instance (runtime binding to a task) ───────────────────────────

pub type FlowInstance {
  FlowInstance(
    id: String,
    template_id: String,
    task_id: String,
    /// Snapshot of nodes at instance creation time
    nodes: Dict(String, Node),
    transitions: List(Transition),
    initial_node_id: String,
    on_done_template_id: Option(String),
    on_reject_template_id: Option(String),
  )
}

pub fn new_flow_template(
  name: String,
  description: String,
  initial_node_id: String,
) -> FlowTemplate {
  FlowTemplate(
    id: "",
    name: name,
    description: description,
    initial_node_id: initial_node_id,
    nodes: dict.new(),
    transitions: [],
    on_done_template_id: None,
    on_reject_template_id: None,
  )
}

pub fn node_to_string(t: NodeType) -> String {
  case t {
    Step -> "step"
    Sequence -> "sequence"
    Branch -> "branch"
    Loop -> "loop"
    Parallel -> "parallel"
    HumanInput -> "human_input"
  }
}

pub fn node_type_from_string(s: String) -> Result(NodeType, String) {
  case s {
    "step" -> Ok(Step)
    "sequence" -> Ok(Sequence)
    "branch" -> Ok(Branch)
    "loop" -> Ok(Loop)
    "parallel" -> Ok(Parallel)
    "human_input" -> Ok(HumanInput)
    _ -> Error("Unknown node type: " <> s)
  }
}

pub fn default_agent_config() -> AgentConfig {
  AgentConfig(
    model: "claude-sonnet-4-20250514",
    fallback_model: None,
    system_prompt: None,
    allowed_tools: ["Bash", "Read", "Edit", "Write", "Glob", "Grep"],
    disallowed_tools: [],
    permission_mode: "bypassPermissions",
    max_budget_usd: 5.0,
  )
}
