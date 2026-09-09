# Tasks API REST: CRUD + dependencies

## Target
- `src/sacrum_gleam/http/routes_tasks.gleam` (new)
- `src/sacrum_gleam/http/routes.gleam` (modify)
- `src/sacrum_gleam/db/tasks.gleam`

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
Implement REST endpoints:

| Method | Path | Action |
|--------|------|--------|
| POST | /api/v1/tasks | Create task |
| GET | /api/v1/tasks | List tasks (query params: level, status, parent, limit, offset) |
| GET | /api/v1/tasks/:id | Get task |
| PATCH | /api/v1/tasks/:id | Update task |
| DELETE | /api/v1/tasks/:id | Archive task (?cascade=true) |
| POST | /api/v1/tasks/:id/depend | Add dependency |
| DELETE | /api/v1/tasks/:id/depend/:depends_on | Remove dependency |
| GET | /api/v1/tasks/:id/blockers | Get blockers |
| GET | /api/v1/tasks/ready | Ready tasks (no incomplete blockers) |

### Request/Response format
- Content-Type: application/json
- Task create: `{"title", "level", "priority", "parent_id"?, "tags"?, "description"?}`
- Task update: optional fields
- Responses: `{"id", "short_id", "title", ...}` with snake_case

### Short ID generation
- Generate 6-character unique short_id (alphanumeric)
- Collision → retry with suffix

## Acceptance
- Full CRUD tested with curl/httpie
- Dependencies: depend/undepend/blockers/ready functional
- Invalid requests → 400 with error message
- Non-existent task → 404

## Dependencies
- Blocked by: #4 Repository layer, #5 Wisp setup
- Parallelizable with: #7 Flows API
