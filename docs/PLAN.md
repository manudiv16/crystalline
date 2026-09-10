# Crystalline — Implementation Plan

## Vision

Crystalline is an embedded AI workflow orchestration engine in Gleam, with local libsql (later Turso remote).
Backend + [Facet](https://github.com/manudiv16/facet) client (CLI + Tauri GUI).
Moldable, reusable agent control flows.

## Current State

Project scaffolded with domain, flow engine, and DB layer implemented:
- ✅ Domain: Task, Section, Flow, Execution, Session types
- ✅ Flow Engine: validator, executor, engine with builders
- ✅ Database: connection, migrations, tasks/flows/executions CRUD
- ✅ SQL migration: 0001_init.sql
- ✅ Agent Harness (C9): provider-neutral contract, Claude Code adapter, provider registry

Build pending fix (gleam_json vs gleam_stdlib v1 incompatibility resolved, remaining imports and Gleam 1.14 semicolons).

## Phases

<!-- markdownlint-disable MD029 -->
### Phase 1: Foundation (sequential)
1. **Fix build**: resolve imports, semicolons, manual JSON encoding
2. **Unit tests**: domain types, flow validator, flow executor
3. **Migrations runner**: load embedded SQL, execute at startup
4. **Repository layer**: typed abstraction over connection

### Phase 2: REST API (parallelizable after Phase 1)
5. **Wisp + Mist setup**: HTTP server with routing
6. **Tasks API**: REST CRUD for tasks + dependencies
7. **Flows API**: REST CRUD for templates + instances
8. **Executions API**: advance flows, report results, human input

### Phase 3: Facet Integration (parallelizable after Phase 2)
9. **Facet Tauri scaffold**: shell + Crystalline as sidecar
10. **Frontend skeleton**: routes, layout, state management
11. **Task management UI**: list, detail, create/edit tasks
12. **Flow visualizer**: interactive flow graph

### Phase 4: Agent Integration (parallelizable)
13. **Harness adapter**: provider-neutral agent interface (Claude/Codex)
14. **Step executor**: run agents, capture output, report metrics
15. **Session logging**: normalized event stream

### Phase 5: Turso Remote (parallelizable)
16. **Remote connection mode**: URL auth token, no logic changes
17. **Sync/conflict resolution**: eventual consistency for offline→online
<!-- markdownlint-enable MD029 -->

## Dependency Diagram

```
Phase 1 (Foundation)
  ├── [1] Fix build ──→ [2] Tests ──→ [3] Migrations ──→ [4] Repository
  │                                                         │
Phase 2 (REST API)                                          │
  ├── [5] Wisp setup ←──────────────────────────────────────┘
  ├── [6] Tasks API ──→ parallel ──→ [7] Flows API
  └── [8] Executions API (depends on 6+7)

Phase 3 (Facet)
  ├── [9] Facet Tauri scaffold (independent)
  ├── [10] Frontend skeleton (depends on 9)
  ├── [11] Task UI (depends on 10, 6)
  └── [12] Flow visualizer (depends on 10, 7)

Phase 4 (Agents)
  ├── [13] Harness adapter (independent)
  ├── [14] Step executor (depends on 13, 8)
  └── [15] Session logging (depends on 14)

Phase 5 (Turso)
  └── [16] Remote mode (depends on 4)
```

## Related
- [Facet](https://github.com/manudiv16/facet) — CLI + Tauri client