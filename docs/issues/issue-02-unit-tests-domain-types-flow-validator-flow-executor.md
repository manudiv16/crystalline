# Unit tests: domain types, flow validator, flow executor

## Target
- `src/sacrum_gleam/domain/task.gleam`
- `src/sacrum_gleam/domain/flow.gleam`
- `src/sacrum_gleam/flow/validator.gleam`
- `src/sacrum_gleam/flow/executor.gleam`
- `test/` directory

## Project Context

Sacrum Gleam is an embedded AI agent workflow orchestration engine, written in Gleam with libsql (local → Turso remote without code changes).

### Architecture
- **Backend**: Gleam (BEAM) + Wisp (web framework) + Mist (HTTP server)
- **Database**: libsql_gleam (NIF over libsql Rust) — local SQLite or remote Turso
- **GUI**: Tauri (pending)

### Current Code State
Project scaffolded at `git@github.com:manudiv16/sacrum.git` with:
- ✅ Domain models: Task, Section, Flow, Execution, Session
- ✅ Flow Engine: validator (DAG, refs, cycles), executor (node type dispatch),
  engine (templates, instances, step-by-step execution, chaining)
- ✅ Database layer: connection wrapper, migrations, CRUD tasks/flows/executions
- ✅ SQL migration: 0001_init.sql (tasks, sections, flow_templates, flow_instances,
  execution_states, step_executions, session_logs, artifacts, task_dependencies)
- ⚠️ Build pending fix (gleam_json incompatibility resolved, remaining imports and
  Gleam 1.14 semicolons)

### Moldable Flow Model
Flows are directed graphs of composable nodes:
- **Step**: executes agent with prompt/config
- **Sequence**: executes children in order
- **Branch**: evaluates conditions, picks target
- **Loop**: repeats children until exit condition
- **Parallel**: executes children concurrently
- **HumanInput**: pauses, waits for external input

Execution is purely functional: `advance(state) → (new_state, action)`

### Key Files
```
src/sacrum_gleam/
├── domain/
│   ├── task.gleam          # Task, Level, Priority, TaskStatus, CodeRef
│   ├── section.gleam       # Section, SectionType
│   ├── flow.gleam          # FlowTemplate, FlowInstance, Node, NodeType, Transition
│   ├── execution.gleam     # ExecutionState, StepExecution
│   └── session.gleam       # SessionLog
├── flow/
│   ├── engine.gleam        # Public engine: register, instantiate, advance, builders
│   ├── executor.gleam      # Node dispatch, next-node resolution
│   └── validator.gleam     # FlowTemplate validation (DAG, refs, cycles)
├── db/
│   ├── connection.gleam    # libsql wrapper: connect, execute, query, transaction
│   ├── migrations.gleam    # Embedded migration runner
│   ├── tasks.gleam         # CRUD tasks + dependencies
│   ├── flows.gleam         # CRUD flow templates + instances
│   └── executions.gleam    # CRUD execution states + step executions
└── sacrum_gleam.gleam      # Main lib with type aliases + functional re-exports
```

### Conventions
- Gleam 1.14+, no semicolons
- No gleam_json (incompatible with stdlib v1) — manual JSON for now
- Commits: `[<uuid-prefix>] description` or `[no-ref] description`


## Change
Create tests with gleeunit for:

### Domain (task.gleam, flow.gleam)
- `level_to_string` / `level_from_string` round-trip
- `priority_to_string` / `priority_from_string` round-trip
- `status_to_string` / `status_from_string` round-trip
- `node_type_to_string` / `node_type_from_string` round-trip
- `new_task` produces correct defaults
- `default_agent_config` has expected defaults

### Flow Validator (validator.gleam)
- Valid flow passes validation
- Missing initial node → error
- Missing child refs → error
- Missing transition refs → error
- Step without prompt → error
- Composite node without children → error
- Cycle detection (non-loop nodes)

### Flow Executor (executor.gleam)
- `start()` initializes state correctly
- Linear flow: Step → complete → next Step → complete → FlowComplete
- Sequence: executes children in order
- Branch: evaluates conditions, picks correct target
- Loop: iterates until max_iterations or exit_condition
- HumanInput: pauses with AwaitingInput status
- `provide_input()` resumes execution
- Flow chaining: on_done_template_id instantiates next flow

## Acceptance
- All tests pass with `gleam test`
- Coverage of domain serializers, validator happy path + 3 error cases, executor linear + branch

## Dependencies
- Blocked by: #1 Fix build
- Blocks: #5 Wisp setup (indirect)
