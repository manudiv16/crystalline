# Executions API: step history + session logs

## Target
- `src/sacrum_gleam/http/routes_executions.gleam` (new)
- `src/sacrum_gleam/db/executions.gleam`
- `src/sacrum_gleam/db/session_logs.gleam` (new)

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

### Step Executions
| Method | Path | Action |
|--------|------|--------|
| GET | /api/v1/tasks/:id/executions | Step execution history |
| GET | /api/v1/executions/:id | Execution detail |
| GET | /api/v1/executions/active | Active executions (running/awaiting_input) |

### Session Logs
| Method | Path | Action |
|--------|------|--------|
| GET | /api/v1/executions/:id/logs | Session logs (paginated, newest-first) |
| POST | /api/v1/executions/:id/logs | Append session event |

### Session Log format
```json
{
  "event_type": "text",
  "payload": {"content": "..."},
  "sequence": 42
}
```

## Acceptance
- List task executions ordered by date
- Paginated logs with cursor (newest-first like harness-core)
- Active executions filters correctly
- Append log increments sequence correctly

## Dependencies
- Blocked by: #4 Repository layer, #5 Wisp setup, #7 Flows API
