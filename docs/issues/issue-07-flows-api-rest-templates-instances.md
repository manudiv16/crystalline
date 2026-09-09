# Flows API REST: templates + instances

## Target
- `src/sacrum_gleam/http/routes_flows.gleam` (new)
- `src/sacrum_gleam/http/routes.gleam` (modify)
- `src/sacrum_gleam/db/flows.gleam`

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

### Flow Templates
| Method | Path | Action |
|--------|------|--------|
| POST | /api/v1/flows/templates | Create template |
| GET | /api/v1/flows/templates | List templates |
| GET | /api/v1/flows/templates/:id | Get template |
| PATCH | /api/v1/flows/templates/:id | Update template |
| DELETE | /api/v1/flows/templates/:id | Delete template |

### Flow Instances
| Method | Path | Action |
|--------|------|--------|
| POST | /api/v1/flows/templates/:id/instantiate | Instantiate flow for a task |
| GET | /api/v1/flows/instances/:id | Get instance |
| GET | /api/v1/tasks/:id/flow | Get flow instance of a task |

### Flow Execution
| Method | Path | Action |
|--------|------|--------|
| POST | /api/v1/flows/instances/:id/advance | Advance execution one step |
| POST | /api/v1/flows/instances/:id/complete | Complete step execution |
| POST | /api/v1/flows/instances/:id/input | Provide human input |
| POST | /api/v1/flows/instances/:id/complete-flow | Mark flow complete (chaining) |
| POST | /api/v1/flows/instances/:id/reject | Reject flow (on_reject chaining) |

### JSON format for templates
```json
{
  "name": "implement_review",
  "description": "Implement then review",
  "initial_node_id": "research",
  "nodes": {
    "research": {
      "id": "research",
      "name": "Research",
      "node_type": "step",
      "goal": "Research the codebase",
      "prompt": "Research...",
      "child_ids": [],
      "branch_rules": [],
      "agent_config": {"model": "claude-sonnet-4-20250514"}
    }
  },
  "transitions": [
    {"from_id": "research", "to_id": "implement"}
  ]
}
```

## Acceptance
- Create template → validate → save
- Instantiate flow → creates FlowInstance + ExecutionState
- Advance → returns action to execute (RunStep, AwaitInput, FlowComplete)
- Complete step → updates state, determines next node
- Human input → resumes from AwaitingInput
- Chaining on_done/on_reject works

## Dependencies
- Blocked by: #4 Repository layer, #5 Wisp setup
- Parallelizable with: #6 Tasks API
