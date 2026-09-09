# Repository layer: typed abstraction over connection

## Target
- `src/sacrum_gleam/db/` (refactor)
- `src/sacrum_gleam/db/connection.gleam`

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


## Problem
Current CRUD modules (`tasks.gleam`, `flows.gleam`, `executions.gleam`) 
use `libsql_gleam` directly with inline SQL. Missing:
- Repository abstraction wrapping connection + queries
- Robust row parsing with explicit column indices (not relying on SELECT * order)
- `error_to_string` function in connection.gleam
- Real JSON decode for tags, nodes_json, transitions_json

## Change
1. Add `error_to_string(DbError) -> String` in connection.gleam
2. Create `Repository` type wrapping DbConnection
3. Refactor row parsing: use explicit indices, not fragile positional pattern match
4. Implement minimal JSON decode for string arrays and flat objects
5. Add helpers `row_text(row, idx)`, `row_int(row, idx)`, etc.
6. Fix `TaskUpdates` in tasks.gleam to use parameterized SQL correctly
   (currently params don't include the WHERE id)

## Acceptance
- `Repository` type exported from db module
- CRUD operations use Repository, not raw DbConnection
- Clean `gleam build`
- Test: create_task + get_task round-trip in memory

## Dependencies
- Blocked by: #1 Fix build, #3 Migrations runner
- Blocks: #6 Tasks API, #7 Flows API
