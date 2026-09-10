/// Sacrum Gleam — Embedded AI workflow orchestration with libsql.
///
/// This is an embedded version of Sacrum: no Phoenix server, no remote PostgreSQL.
/// The backend runs in-process with libsql (SQLite-compatible, Turso-ready).
///
/// Architecture:
/// - **Domain**: Task, Section, Flow, Execution types
/// - **Flow Engine**: Moldable, composable agent control flows
///   - Step, Sequence, Branch, Loop, Parallel, HumanInput nodes
///   - Pure-functional execution: state → action → new state
/// - **Database**: libsql-backed CRUD with Turso remote support
///
/// ## Quick Start
///
/// ```gleam
/// import sacrum_gleam
///
/// // Connect to embedded DB
/// let conn = sacrum_gleam.connect(":memory:", None)
///
/// // Create a linear flow
/// let flow = sacrum_gleam.build_linear_flow(
///   "implement_review",
///   "Implement then review",
///   [
///     #("research", "Research the codebase"),
///     #("implement", "Implement the feature"),
///     #("review", "Review the changes"),
///   ],
/// )
///
/// // Register and execute
/// let engine = sacrum_gleam.new_engine()
/// let assert Ok(engine) = sacrum_gleam.register_template(engine, flow)
/// let assert #(engine, instance) = sacrum_gleam.instantiate_flow(engine, flow.id, "task-1")
/// let assert #(engine, _, action) = sacrum_gleam.advance_execution(engine, instance.id)
/// ```
import crystalline
import gleam/option.{type Option}
import sacrum_gleam/db/connection
import sacrum_gleam/domain/execution
import sacrum_gleam/domain/flow
import sacrum_gleam/domain/section
import sacrum_gleam/domain/session
import sacrum_gleam/domain/task
import sacrum_gleam/flow/engine
import sacrum_gleam/flow/executor
import sacrum_gleam/flow/validator

// Domain type aliases for convenience
pub type Task =
  task.Task

pub type Level =
  task.Level

pub type Priority =
  task.Priority

pub type TaskStatus =
  task.TaskStatus

pub type CodeRef =
  task.CodeRef

pub type Section =
  section.Section

pub type SectionType =
  section.SectionType

pub type FlowTemplate =
  flow.FlowTemplate

pub type FlowInstance =
  flow.FlowInstance

pub type Node =
  flow.Node

pub type NodeType =
  flow.NodeType

pub type Transition =
  flow.Transition

pub type BranchRule =
  flow.BranchRule

pub type LoopConfig =
  flow.LoopConfig

pub type AgentConfig =
  flow.AgentConfig

pub type ExecutionState =
  execution.ExecutionState

pub type ExecutionStatus =
  execution.ExecutionStatus

pub type StepExecution =
  execution.StepExecution

pub type StepStatus =
  execution.StepStatus

pub type SessionLog =
  session.SessionLog

// Flow engine types
pub type Engine =
  engine.Engine

pub type EngineError =
  engine.EngineError

pub type Action =
  executor.Action

// Database types
pub type DbConnection =
  connection.DbConnection

pub type DbError =
  connection.DbError

// ─── Constructors ─────────────────────────────────────────────────────────

pub fn new_engine() -> Engine {
  engine.new_engine()
}

pub fn new_task(title: String, level: Level, priority: Priority) -> Task {
  task.new_task(title, level, priority)
}

pub fn default_agent_config() -> AgentConfig {
  flow.default_agent_config()
}

// ─── Serialization helpers ───────────────────────────────────────────────

pub fn level_to_string(level: Level) -> String {
  task.level_to_string(level)
}

pub fn level_from_string(s: String) -> Result(Level, String) {
  task.level_from_string(s)
}

pub fn priority_to_string(p: Priority) -> String {
  task.priority_to_string(p)
}

pub fn priority_from_string(s: String) -> Result(Priority, String) {
  task.priority_from_string(s)
}

pub fn status_to_string(s: TaskStatus) -> String {
  task.status_to_string(s)
}

pub fn status_from_string(s: String) -> Result(TaskStatus, String) {
  task.status_from_string(s)
}

pub fn node_type_to_string(t: NodeType) -> String {
  flow.node_to_string(t)
}

pub fn node_type_from_string(s: String) -> Result(NodeType, String) {
  flow.node_type_from_string(s)
}

pub fn section_type_to_string(t: SectionType) -> String {
  section.section_type_to_string(t)
}

pub fn section_type_from_string(s: String) -> Result(SectionType, String) {
  section.section_type_from_string(s)
}

pub fn step_status_to_string(s: StepStatus) -> String {
  execution.step_status_to_string(s)
}

pub fn execution_status_to_string(s: ExecutionStatus) -> String {
  execution.execution_status_to_string(s)
}

// ─── Flow Engine ─────────────────────────────────────────────────────────

pub fn register_template(
  e: Engine,
  t: FlowTemplate,
) -> Result(Engine, EngineError) {
  engine.register_template(e, t)
}

pub fn get_template(
  e: Engine,
  id: String,
) -> Result(FlowTemplate, EngineError) {
  engine.get_template(e, id)
}

pub fn list_templates(e: Engine) -> List(FlowTemplate) {
  engine.list_templates(e)
}

pub fn instantiate_flow(
  e: Engine,
  template_id: String,
  task_id: String,
) -> Result(#(Engine, FlowInstance), EngineError) {
  engine.instantiate_flow(e, template_id, task_id)
}

pub fn advance_execution(
  e: Engine,
  instance_id: String,
) -> Result(#(Engine, String, Action), EngineError) {
  engine.advance_execution(e, instance_id)
}

pub fn complete_step(
  e: Engine,
  instance_id: String,
  step: StepExecution,
  output: String,
) -> Result(#(Engine, String, Action), EngineError) {
  engine.complete_step(e, instance_id, step, output)
}

pub fn provide_input(
  e: Engine,
  instance_id: String,
  input: String,
) -> Result(#(Engine, String, Action), EngineError) {
  engine.provide_input(e, instance_id, input)
}

pub fn get_execution(
  e: Engine,
  id: String,
) -> Result(ExecutionState, EngineError) {
  engine.get_execution(e, id)
}

pub fn handle_flow_complete(
  e: Engine,
  instance_id: String,
  task_id: String,
) -> Result(#(Engine, Option(String)), EngineError) {
  engine.handle_flow_complete(e, instance_id, task_id)
}

pub fn handle_flow_reject(
  e: Engine,
  instance_id: String,
  task_id: String,
) -> Result(#(Engine, Option(String)), EngineError) {
  engine.handle_flow_reject(e, instance_id, task_id)
}

// ─── Flow Builders ───────────────────────────────────────────────────────

pub fn build_linear_flow(
  name: String,
  description: String,
  steps: List(#(String, String)),
) -> FlowTemplate {
  engine.build_linear_flow(name, description, steps)
}

pub fn build_loop_flow(
  name: String,
  description: String,
  pre_loop: List(#(String, String)),
  loop_steps: List(#(String, String)),
  post_loop: List(#(String, String)),
  exit_condition: String,
  max_iterations: Int,
) -> FlowTemplate {
  engine.build_loop_flow(
    name,
    description,
    pre_loop,
    loop_steps,
    post_loop,
    exit_condition,
    max_iterations,
  )
}

pub fn build_branch_flow(
  name: String,
  description: String,
  initial_step: #(String, String),
  branch_rules: List(#(String, String)),
  fallback_step: Option(#(String, String)),
) -> FlowTemplate {
  engine.build_branch_flow(
    name,
    description,
    initial_step,
    branch_rules,
    fallback_step,
  )
}

pub fn validate_flow(
  t: FlowTemplate,
) -> Result(Nil, List(validator.ValidationError)) {
  validator.validate(t)
}

// ─── Database ─────────────────────────────────────────────────────────────

pub fn connect(
  db_url: String,
  auth_token: Option(String),
) -> Result(DbConnection, DbError) {
  connection.connect(db_url, auth_token)
}

// ─── Application entrypoint ───────────────────────────────────────────────

/// Entry point used by `gleam run`. The actual bootstrap (PORT resolution,
/// server start, blocking) lives in `crystalline.main`.
pub fn main() -> Nil {
  crystalline.main()
}
