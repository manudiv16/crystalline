# Tauri shell: scaffold + Gleam sidecar

## Target
- `/crates/gui/` or root Tauri directory
- `gleam.toml` (sidecar binary)

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
We need a Tauri desktop app that packages the Gleam backend as a sidecar
and has a WebView frontend.

## Change
1. Create Tauri structure:
   ```
   tauri/
   ├── src-tauri/
   │   ├── Cargo.toml
   │   ├── tauri.conf.json
   │   ├── build.rs
   │   └── src/main.rs
   ├── package.json
   └── src/ (frontend)
   ```
2. Configure sidecar: compile Gleam binary as `sacrum-backend`
3. Tauri.conf: define sidecar command, args (DB path, port)
4. Main.rs: launch sidecar, wait for ready, communicate via localhost HTTP
5. Minimal frontend: page showing "Sacrum Gleam — Connected"

## Acceptance
- `cargo tauri dev` launches app with backend running
- Frontend can fetch /health from sidecar
- App packageable (at least on macOS)

## Dependencies
- Blocked by: #5 Wisp setup (needs functional HTTP backend)
- Parallelizable with: #6 Tasks API, #7 Flows API (shell doesn't need the routes)
