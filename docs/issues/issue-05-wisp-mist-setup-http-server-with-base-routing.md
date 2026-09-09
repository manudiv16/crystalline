# Wisp + Mist setup: HTTP server with base routing

## Target
- `gleam.toml` (add dependencies)
- `src/sacrum_gleam/http/` (new directory)
- `src/sacrum_gleam/http/server.gleam`
- `src/sacrum_gleam/http/routes.gleam`

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
1. Add to gleam.toml:
   - `mist = ">= 1.0.0 and < 2.0.0"`
   - `wisp = ">= 1.0.0 and < 2.0.0"`
   - `gleam_http = ">= 3.0.0 and < 4.0.0"`
   - `gleam_http_server = ">= 1.0.0 and < 2.0.0"`
2. Create `http/server.gleam`:
   - Function `start(port: Int) -> Result(Nil, Error)`
   - Configure Mist server with Wisp router
   - Basic request logging
3. Create `http/routes.gleam`:
   - GET /health → 200 {"status": "ok"}
   - GET /api/v1/tasks → placeholder 200 []
   - POST placeholder for future APIs
4. Create `main.gleam` binary that:
   - Connects to DB (argv or env: DB_URL)
   - Runs migrations
   - Starts HTTP server

## Acceptance
- `gleam run` starts server on configurable port
- `curl http://localhost:PORT/health` → 200 JSON
- Clean `gleam build`

## Dependencies
- Blocked by: #1 Fix build
- Parallelizable with: #2 Tests, #3 Migrations (independent of HTTP)
