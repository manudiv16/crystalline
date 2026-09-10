/// Prebuilt flow template registry — the core of "moldable flows".
///
/// Provides 6 reusable, validated FlowTemplate definitions that can be
/// seeded into the database or registered with the in-memory engine.
///
/// Templates:
/// - implement_review:  linear research → implement → test → review
/// - bugfix:            linear reproduce → diagnose → fix → verify
/// - refactor_loop:     loop(refactor_file, run_tests) until tests pass, max 50
/// - review_gate:       branch on approval: approved/done, changes/fix/re-review, rejected/rollback
/// - multi_file_analysis: parallel(analyze_a, analyze_b, analyze_c) → synthesize
/// - design_implement:  research → design → human_input → implement → test
import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sacrum_gleam/db/connection.{type DbConnection, type DbError}
import sacrum_gleam/db/flows as db_flows
import sacrum_gleam/domain/flow.{
  type AgentConfig, type BranchRule, type FlowTemplate, type LoopConfig,
  type Node, type NodeType, type Transition, Branch, BranchRule, FlowTemplate,
  HumanInput, Loop, LoopConfig, Node, Parallel, Sequence, Step, Transition,
}
import sacrum_gleam/flow/engine.{type Engine, register_template}

// ─── Template Spec ───────────────────────────────────────────────────────

/// Lightweight descriptor for a prebuilt template.
pub type TemplateSpec {
  TemplateSpec(
    slug: String,
    name: String,
    description: String,
    /// Builds the full FlowTemplate from this spec
    build: fn() -> FlowTemplate,
  )
}

/// Returns all 6 prebuilt template specs.
pub fn all_template_specs() -> List(TemplateSpec) {
  [
    implement_review_spec(),
    bugfix_spec(),
    refactor_loop_spec(),
    review_gate_spec(),
    multi_file_analysis_spec(),
    design_implement_spec(),
  ]
}

// ─── Template Specs ──────────────────────────────────────────────────────

fn implement_review_spec() -> TemplateSpec {
  TemplateSpec(
    slug: "implement_review",
    name: "Implement & Review",
    description: "Linear flow: research the codebase, implement changes, write tests, then review the result.",
    build: build_implement_review,
  )
}

fn bugfix_spec() -> TemplateSpec {
  TemplateSpec(
    slug: "bugfix",
    name: "Bug Fix",
    description: "Linear flow: reproduce the bug, diagnose the root cause, implement a fix, then verify it's resolved.",
    build: build_bugfix,
  )
}

fn refactor_loop_spec() -> TemplateSpec {
  TemplateSpec(
    slug: "refactor_loop",
    name: "Refactor Loop",
    description: "Loop-based flow: refactor a file and run tests repeatedly until all tests pass (max 50 iterations).",
    build: build_refactor_loop,
  )
}

fn review_gate_spec() -> TemplateSpec {
  TemplateSpec(
    slug: "review_gate",
    name: "Review Gate",
    description: "Branching flow: on review approval mark done, on changes request fix then re-review, on rejection rollback.",
    build: build_review_gate,
  )
}

fn multi_file_analysis_spec() -> TemplateSpec {
  TemplateSpec(
    slug: "multi_file_analysis",
    name: "Multi-File Analysis",
    description: "Parallel flow: analyze multiple files concurrently then synthesize findings into a unified report.",
    build: build_multi_file_analysis,
  )
}

fn design_implement_spec() -> TemplateSpec {
  TemplateSpec(
    slug: "design_implement",
    name: "Design & Implement",
    description: "Flow with human input: research, design, get human approval, implement, then test.",
    build: build_design_implement,
  )
}

// ─── Template Builders ───────────────────────────────────────────────────

/// implement_review: research → implement → test → review
fn build_implement_review() -> FlowTemplate {
  let nodes =
    dict.from_list([
      node_step(
        "research",
        "Research the codebase",
        "Explore the relevant codebase areas, understand existing patterns and architecture before making changes.",
      ),
      node_step(
        "implement",
        "Implement the changes",
        "Make the required code changes following the patterns discovered during research.",
      ),
      node_step(
        "test",
        "Write and run tests",
        "Create tests that validate the implementation and run them to confirm correctness.",
      ),
      node_step(
        "review",
        "Review the result",
        "Perform a final review of all changes, check for edge cases, and ensure code quality standards.",
      ),
    ])

  let transitions = [
    mk_trans("t1", "research", "implement", None, None),
    mk_trans("t2", "implement", "test", None, None),
    mk_trans("t3", "test", "review", None, None),
  ]

  FlowTemplate(
    id: "implement_review",
    name: "Implement & Review",
    description: "Linear flow: research the codebase, implement changes, write tests, then review the result.",
    initial_node_id: "research",
    nodes: nodes,
    transitions: transitions,
    on_done_template_id: None,
    on_reject_template_id: None,
  )
}

/// bugfix: reproduce → diagnose → fix → verify
fn build_bugfix() -> FlowTemplate {
  let nodes =
    dict.from_list([
      node_step(
        "reproduce",
        "Reproduce the bug",
        "Create a minimal reproduction of the bug to understand the failure mode and confirm it exists.",
      ),
      node_step(
        "diagnose",
        "Diagnose root cause",
        "Trace through the code to identify the root cause of the bug. Determine which component is at fault.",
      ),
      node_step(
        "fix",
        "Implement the fix",
        "Write a targeted fix for the identified root cause. Minimise the change surface area.",
      ),
      node_step(
        "verify",
        "Verify the fix",
        "Run the reproduction case to confirm the bug is resolved. Run related tests to ensure no regressions.",
      ),
    ])

  let transitions = [
    mk_trans("t1", "reproduce", "diagnose", None, None),
    mk_trans("t2", "diagnose", "fix", None, None),
    mk_trans("t3", "fix", "verify", None, None),
  ]

  FlowTemplate(
    id: "bugfix",
    name: "Bug Fix",
    description: "Linear flow: reproduce the bug, diagnose the root cause, implement a fix, then verify it's resolved.",
    initial_node_id: "reproduce",
    nodes: nodes,
    transitions: transitions,
    on_done_template_id: None,
    on_reject_template_id: None,
  )
}

/// refactor_loop: loop(refactor_file, run_tests) until tests pass, max 50
fn build_refactor_loop() -> FlowTemplate {
  let nodes =
    dict.from_list([
      node_step(
        "identify_file",
        "Identify file to refactor",
        "Determine which file or module needs refactoring based on complexity, code smells, or explicit request.",
      ),
      #(
        "refactor_loop",
        Node(
          id: "refactor_loop",
          name: "Refactor & Test Loop",
          node_type: Loop,
          goal: "Refactor the file and run tests repeatedly until all tests pass",
          prompt: None,
          child_ids: ["refactor_file", "run_tests"],
          branch_rules: [],
          loop_config: Some(
            LoopConfig(
              max_iterations: Some(50),
              exit_condition: Some("tests_pass"),
              child_ids: ["refactor_file", "run_tests"],
            ),
          ),
          agent_config: None,
          output_schema: None,
        ),
      ),
      node_step(
        "refactor_file",
        "Refactor the file",
        "Apply refactoring improvements to the identified file: extract functions, simplify logic, improve naming.",
      ),
      node_step(
        "run_tests",
        "Run the test suite",
        "Execute the test suite and report results. Set tests_pass=true if all tests pass.",
      ),
      node_step(
        "summarize",
        "Summarize refactoring results",
        "Provide a summary of what was refactored, how many iterations it took, and the final test status.",
      ),
    ])

  let transitions = [
    mk_trans("t1", "identify_file", "refactor_loop", None, None),
    mk_trans("t2", "refactor_loop", "summarize", None, Some("loop_exit")),
  ]

  FlowTemplate(
    id: "refactor_loop",
    name: "Refactor Loop",
    description: "Loop-based flow: refactor a file and run tests repeatedly until all tests pass (max 50 iterations).",
    initial_node_id: "identify_file",
    nodes: nodes,
    transitions: transitions,
    on_done_template_id: None,
    on_reject_template_id: None,
  )
}

/// review_gate: branch on approval
fn build_review_gate() -> FlowTemplate {
  let nodes =
    dict.from_list([
      node_step(
        "review",
        "Review the changes",
        "Examine the proposed changes for correctness, completeness, code quality, and adherence to standards.",
      ),
      #(
        "gate_branch",
        Node(
          id: "gate_branch",
          name: "Approval Gate",
          node_type: Branch,
          goal: "Route based on review decision: approved, changes requested, or rejected",
          prompt: None,
          child_ids: [],
          branch_rules: [
            BranchRule(condition: "approved", target_id: "done"),
            BranchRule(condition: "changes_requested", target_id: "fix"),
            BranchRule(condition: "rejected", target_id: "rollback"),
          ],
          loop_config: None,
          agent_config: None,
          output_schema: None,
        ),
      ),
      node_step(
        "done",
        "Mark as approved",
        "The changes are approved. Mark the task as complete.",
      ),
      node_step(
        "fix",
        "Address review comments",
        "Fix the issues identified during review. Make targeted changes to address each comment.",
      ),
      node_step(
        "re_review",
        "Re-review after fixes",
        "Review the updated changes to verify all review comments have been addressed.",
      ),
      node_step(
        "rollback",
        "Rollback changes",
        "The changes are rejected. Revert or rollback the changes and document the reason.",
      ),
    ])

  let transitions = [
    mk_trans("t1", "review", "gate_branch", None, None),
    mk_trans("t2", "gate_branch", "done", Some("approved"), Some("approved")),
    mk_trans(
      "t3",
      "gate_branch",
      "fix",
      Some("changes_requested"),
      Some("changes requested"),
    ),
    mk_trans(
      "t4",
      "gate_branch",
      "rollback",
      Some("rejected"),
      Some("rejected"),
    ),
    mk_trans("t5", "fix", "re_review", None, None),
    mk_trans("t6", "re_review", "gate_branch", None, Some("re-evaluate")),
  ]

  FlowTemplate(
    id: "review_gate",
    name: "Review Gate",
    description: "Branching flow: on review approval mark done, on changes request fix then re-review, on rejection rollback.",
    initial_node_id: "review",
    nodes: nodes,
    transitions: transitions,
    on_done_template_id: None,
    on_reject_template_id: None,
  )
}

/// multi_file_analysis: parallel(analyze_a, analyze_b, analyze_c) → synthesize
fn build_multi_file_analysis() -> FlowTemplate {
  let nodes =
    dict.from_list([
      node_step(
        "identify_files",
        "Identify files to analyze",
        "Determine which files or modules need to be analyzed based on the task context.",
      ),
      #(
        "parallel_analysis",
        Node(
          id: "parallel_analysis",
          name: "Parallel File Analysis",
          node_type: Parallel,
          goal: "Analyze multiple files concurrently for dependencies, complexity, and issues",
          prompt: None,
          child_ids: ["analyze_file_a", "analyze_file_b", "analyze_file_c"],
          branch_rules: [],
          loop_config: None,
          agent_config: None,
          output_schema: None,
        ),
      ),
      node_step(
        "analyze_file_a",
        "Analyze file A",
        "Analyze the first identified file: check structure, dependencies, complexity, and potential issues.",
      ),
      node_step(
        "analyze_file_b",
        "Analyze file B",
        "Analyze the second identified file: check structure, dependencies, complexity, and potential issues.",
      ),
      node_step(
        "analyze_file_c",
        "Analyze file C",
        "Analyze the third identified file: check structure, dependencies, complexity, and potential issues.",
      ),
      node_step(
        "synthesize",
        "Synthesize findings",
        "Combine all analysis results into a unified report with cross-file insights and recommendations.",
      ),
    ])

  let transitions = [
    mk_trans("t1", "identify_files", "parallel_analysis", None, None),
    mk_trans("t2", "parallel_analysis", "synthesize", None, None),
  ]

  FlowTemplate(
    id: "multi_file_analysis",
    name: "Multi-File Analysis",
    description: "Parallel flow: analyze multiple files concurrently then synthesize findings into a unified report.",
    initial_node_id: "identify_files",
    nodes: nodes,
    transitions: transitions,
    on_done_template_id: None,
    on_reject_template_id: None,
  )
}

/// design_implement: research → design → human_input → implement → test
fn build_design_implement() -> FlowTemplate {
  let nodes =
    dict.from_list([
      node_step(
        "research",
        "Research requirements",
        "Understand the requirements, existing codebase patterns, and constraints before designing a solution.",
      ),
      node_step(
        "design",
        "Design the solution",
        "Create a detailed design document outlining the approach, file changes, data flow, and trade-offs.",
      ),
      #(
        "design_review",
        Node(
          id: "design_review",
          name: "Design Review",
          node_type: HumanInput,
          goal: "Get human approval on the design before implementation",
          prompt: Some(
            "Review the proposed design. Reply with 'approve' to proceed or provide feedback.",
          ),
          child_ids: [],
          branch_rules: [],
          loop_config: None,
          agent_config: None,
          output_schema: None,
        ),
      ),
      node_step(
        "implement",
        "Implement the solution",
        "Implement the approved design. Follow the design document closely and maintain code quality.",
      ),
      node_step(
        "test",
        "Test the implementation",
        "Write and run tests to validate the implementation matches the design and requirements.",
      ),
    ])

  let transitions = [
    mk_trans("t1", "research", "design", None, None),
    mk_trans("t2", "design", "design_review", None, None),
    mk_trans("t3", "design_review", "implement", None, None),
    mk_trans("t4", "implement", "test", None, None),
  ]

  FlowTemplate(
    id: "design_implement",
    name: "Design & Implement",
    description: "Flow with human input: research, design, get human approval, implement, then test.",
    initial_node_id: "research",
    nodes: nodes,
    transitions: transitions,
    on_done_template_id: None,
    on_reject_template_id: None,
  )
}

// ─── Node Builders ───────────────────────────────────────────────────────

fn node_step(id: String, name: String, prompt: String) -> #(String, Node) {
  #(
    id,
    Node(
      id: id,
      name: name,
      node_type: Step,
      goal: prompt,
      prompt: Some(prompt),
      child_ids: [],
      branch_rules: [],
      loop_config: None,
      agent_config: None,
      output_schema: None,
    ),
  )
}

fn mk_trans(
  id: String,
  from: String,
  to: String,
  condition: Option(String),
  label: Option(String),
) -> Transition {
  Transition(
    id: id,
    from_id: from,
    to_id: to,
    condition: condition,
    label: label,
  )
}

// ─── Validation for seed ─────────────────────────────────────────────────

/// Extended validation specific to seeding requirements:
/// 1. All node IDs are unique
/// 2. All transitions reference valid nodes
/// 3. Loop nodes have max_iterations > 0
/// 4. Branch nodes have at least 2 outgoing transitions (branch rules)
pub type SeedValidationError {
  DuplicateNodeId(id: String)
  MissingTransitionFrom(transition_id: String, node_id: String)
  MissingTransitionTo(transition_id: String, node_id: String)
  LoopMaxIterationsZero(node_id: String)
  BranchTooFewRules(node_id: String, count: Int)
}

pub fn validate_for_seed(
  template: FlowTemplate,
) -> Result(Nil, List(SeedValidationError)) {
  let errors =
    list.append(
      check_unique_node_ids(template),
      list.append(
        check_transition_refs(template),
        list.append(
          check_loop_max_iterations(template),
          check_branch_rules(template),
        ),
      ),
    )

  case errors {
    [] -> Ok(Nil)
    _ -> Error(errors)
  }
}

fn check_unique_node_ids(template: FlowTemplate) -> List(SeedValidationError) {
  // Node IDs are dict keys so they're unique by construction,
  // but we verify by comparing count of keys vs values
  let node_ids = template.nodes |> dict.keys
  let unique_ids = node_ids |> list.unique
  case list.length(node_ids) == list.length(unique_ids) {
    True -> []
    False -> {
      let duplicates =
        node_ids
        |> list.filter(fn(id) {
          list.count(unique_ids, fn(uid) { uid == id }) > 1
        })
        |> list.unique
      duplicates
      |> list.map(fn(id) { DuplicateNodeId(id) })
    }
  }
}

fn check_transition_refs(template: FlowTemplate) -> List(SeedValidationError) {
  let node_ids = template.nodes |> dict.keys

  template.transitions
  |> list.flat_map(fn(t) {
    let from_err = case list.contains(node_ids, t.from_id) {
      True -> []
      False -> [MissingTransitionFrom(t.id, t.from_id)]
    }
    let to_err = case list.contains(node_ids, t.to_id) {
      True -> []
      False -> [MissingTransitionTo(t.id, t.to_id)]
    }
    list.append(from_err, to_err)
  })
}

fn check_loop_max_iterations(
  template: FlowTemplate,
) -> List(SeedValidationError) {
  template.nodes
  |> dict.values
  |> list.filter(fn(n) { n.node_type == Loop })
  |> list.filter_map(fn(n) {
    case n.loop_config {
      Some(cfg) ->
        case cfg.max_iterations {
          Some(max) if max > 0 -> Error(Nil)
          _ -> Ok(LoopMaxIterationsZero(n.id))
        }
      None -> Ok(LoopMaxIterationsZero(n.id))
    }
  })
}

fn check_branch_rules(template: FlowTemplate) -> List(SeedValidationError) {
  template.nodes
  |> dict.values
  |> list.filter(fn(n) { n.node_type == Branch })
  |> list.filter_map(fn(n) {
    let count = list.length(n.branch_rules)
    case count >= 2 {
      True -> Error(Nil)
      False -> Ok(BranchTooFewRules(n.id, count))
    }
  })
}

// ─── Seed to Engine ──────────────────────────────────────────────────────

/// Register all prebuilt templates into the in-memory engine.
/// Returns the updated engine and the count of successfully registered templates.
pub fn seed_to_engine(engine: Engine) -> #(Engine, Int) {
  all_template_specs()
  |> list.fold(#(engine, 0), fn(acc, spec) {
    let #(eng, count) = acc
    let template = spec.build()
    case register_template(eng, template) {
      Ok(new_eng) -> #(new_eng, count + 1)
      Error(_) -> acc
    }
  })
}

// ─── Seed to Database ────────────────────────────────────────────────────

/// Seed all prebuilt templates into the database idempotently.
///
/// Each template is validated with `validate_for_seed` before insertion and
/// templates that already exist (matched by their id/slug) are skipped, so
/// a second call inserts nothing.
/// Returns the number of templates newly inserted (0 if all already exist).
pub fn seed_to_db(conn: DbConnection, now: Int) -> Result(Int, DbError) {
  let specs = all_template_specs()
  seed_loop(conn, specs, 0, now)
}

fn seed_loop(
  conn: DbConnection,
  remaining: List(TemplateSpec),
  inserted: Int,
  now: Int,
) -> Result(Int, DbError) {
  case remaining {
    [] -> Ok(inserted)
    [spec, ..rest] -> {
      let template = spec.build()

      // Only seed templates that pass seed validation (unique ids,
      // valid transitions, loop max_iterations > 0, branch >= 2 rules).
      case validate_for_seed(template) {
        Error(_) -> seed_loop(conn, rest, inserted, now)
        Ok(Nil) -> {
          // Idempotency: skip templates that are already present.
          case db_flows.get_flow_template(conn, spec.slug) {
            Ok(_) -> seed_loop(conn, rest, inserted, now)
            Error(_) -> {
              use _ <- result.try(db_flows.create_flow_template(
                conn,
                template,
                now,
              ))
              seed_loop(conn, rest, inserted + 1, now)
            }
          }
        }
      }
    }
  }
}

// ─── JSON Encoding ───────────────────────────────────────────────────────

/// Encode a FlowTemplate to a JSON string for storage or API responses.
pub fn template_to_json(template: FlowTemplate) -> String {
  json.object(template_to_pairs(template))
  |> json.to_string
}

fn template_to_pairs(template: FlowTemplate) -> List(#(String, json.Json)) {
  [
    #("id", json.string(template.id)),
    #("slug", json.string(template.id)),
    #("name", json.string(template.name)),
    #("description", json.string(template.description)),
    #("initial_node_id", json.string(template.initial_node_id)),
    #("nodes", encode_nodes(template.nodes)),
    #("transitions", encode_transitions(template.transitions)),
    #("on_done_template_id", case template.on_done_template_id {
      Some(v) -> json.string(v)
      None -> json.null()
    }),
    #("on_reject_template_id", case template.on_reject_template_id {
      Some(v) -> json.string(v)
      None -> json.null()
    }),
  ]
}

/// Encode a template summary (id/slug, name, description, shape counts)
/// as a JSON object for list responses.
pub fn template_summary_to_json_value(template: FlowTemplate) -> json.Json {
  json.object([
    #("id", json.string(template.id)),
    #("slug", json.string(template.id)),
    #("name", json.string(template.name)),
    #("description", json.string(template.description)),
    #("initial_node_id", json.string(template.initial_node_id)),
    #("node_count", json.int(dict.size(template.nodes))),
    #("transition_count", json.int(list.length(template.transitions))),
  ])
}

/// Encode a template summary string for a single-template response.
pub fn template_summary_to_json(template: FlowTemplate) -> String {
  template_summary_to_json_value(template) |> json.to_string
}

fn encode_nodes(nodes: Dict(String, Node)) -> json.Json {
  nodes
  |> dict.to_list
  |> list.map(fn(pair) {
    let #(_id, node) = pair
    encode_node(node)
  })
  |> json.preprocessed_array
}

fn encode_node(node: Node) -> json.Json {
  json.object([
    #("id", json.string(node.id)),
    #("name", json.string(node.name)),
    #("node_type", json.string(node_type_to_string(node.node_type))),
    #("goal", json.string(node.goal)),
    #("prompt", case node.prompt {
      Some(v) -> json.string(v)
      None -> json.null()
    }),
    #(
      "child_ids",
      json.preprocessed_array(list.map(node.child_ids, json.string)),
    ),
    #("branch_rules", encode_branch_rules(node.branch_rules)),
    #("loop_config", case node.loop_config {
      Some(cfg) -> encode_loop_config(cfg)
      None -> json.null()
    }),
    #("agent_config", case node.agent_config {
      Some(cfg) -> encode_agent_config(cfg)
      None -> json.null()
    }),
    #("output_schema", case node.output_schema {
      Some(v) -> json.string(v)
      None -> json.null()
    }),
  ])
}

fn encode_branch_rules(rules: List(BranchRule)) -> json.Json {
  rules
  |> list.map(fn(rule) {
    json.object([
      #("condition", json.string(rule.condition)),
      #("target_id", json.string(rule.target_id)),
    ])
  })
  |> json.preprocessed_array
}

fn encode_loop_config(cfg: LoopConfig) -> json.Json {
  json.object([
    #("max_iterations", case cfg.max_iterations {
      Some(v) -> json.int(v)
      None -> json.null()
    }),
    #("exit_condition", case cfg.exit_condition {
      Some(v) -> json.string(v)
      None -> json.null()
    }),
    #(
      "child_ids",
      json.preprocessed_array(list.map(cfg.child_ids, json.string)),
    ),
  ])
}

fn encode_agent_config(cfg: AgentConfig) -> json.Json {
  json.object([
    #("model", json.string(cfg.model)),
    #("fallback_model", case cfg.fallback_model {
      Some(v) -> json.string(v)
      None -> json.null()
    }),
    #("system_prompt", case cfg.system_prompt {
      Some(v) -> json.string(v)
      None -> json.null()
    }),
    #(
      "allowed_tools",
      json.preprocessed_array(list.map(cfg.allowed_tools, json.string)),
    ),
    #(
      "disallowed_tools",
      json.preprocessed_array(list.map(cfg.disallowed_tools, json.string)),
    ),
    #("permission_mode", json.string(cfg.permission_mode)),
    #("max_budget_usd", json.float(cfg.max_budget_usd)),
  ])
}

fn encode_transitions(transitions: List(Transition)) -> json.Json {
  transitions
  |> list.map(fn(t) {
    json.object([
      #("id", json.string(t.id)),
      #("from_id", json.string(t.from_id)),
      #("to_id", json.string(t.to_id)),
      #("condition", case t.condition {
        Some(v) -> json.string(v)
        None -> json.null()
      }),
      #("label", case t.label {
        Some(v) -> json.string(v)
        None -> json.null()
      }),
    ])
  })
  |> json.preprocessed_array
}

fn node_type_to_string(t: NodeType) -> String {
  case t {
    Step -> "step"
    Sequence -> "sequence"
    Branch -> "branch"
    Loop -> "loop"
    Parallel -> "parallel"
    HumanInput -> "human_input"
  }
}

/// Encode all templates as a JSON array of summaries for the list API.
pub fn templates_list_to_json(templates: List(FlowTemplate)) -> String {
  templates
  |> list.map(template_summary_to_json_value)
  |> json.preprocessed_array
  |> json.to_string
}

/// Encode seed result as JSON: { "inserted": N, "total": M }
pub fn seed_result_to_json(inserted: Int, total: Int) -> String {
  json.object([
    #("inserted", json.int(inserted)),
    #("total", json.int(total)),
  ])
  |> json.to_string
}
