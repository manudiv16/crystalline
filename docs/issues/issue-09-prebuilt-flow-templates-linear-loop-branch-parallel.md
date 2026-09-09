# Prebuilt flow templates: define reusable flows

## Target
- `src/sacrum_gleam/flow/templates.gleam` (new)
- `src/sacrum_gleam/http/routes_flows.gleam` (seed endpoint)

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
Create a module with **prebuilt flow templates** that users can instantiate directly:

### 1. Linear: "implement_review"
```
research → implement → test → review → done
```

### 2. Linear: "bugfix"
```
reproduce → diagnose → fix → verify → done
```

### 3. Loop: "refactor_loop"
```
analyze → loop(refactor_one_file, run_tests) [exit: tests pass, max 50] → done
```

### 4. Branch: "review_gate"
```
implement → branch:
  - if approved → done
  - if changes_requested → fix → re-review
  - if rejected → rollback
```

### 5. Parallel: "multi_file_analysis"
```
scope → parallel(analyze_module_a, analyze_module_b, analyze_module_c) → synthesize → done
```

### 6. Human-in-loop: "design_implement"
```
research → design_proposal → human_input → implement → review → done
```

Each template has:
- Unique ID (slug)
- Name and description
- Default AgentConfig per step
- Output schema where applicable

### API
Endpoint `POST /api/v1/flows/templates/seed` that inserts all prebuilt templates
if they don't already exist.

## Acceptance
- 6 prebuilt templates defined in code
- Each template passes `validator.validate()`
- Templates can be instantiated and executed
- Seed endpoint is idempotent

## Dependencies
- Blocked by: #7 Flows API (needs routes for seed)
- Parallelizable with: #8 Executions API
