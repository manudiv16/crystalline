# ADR-001: Embedded Crystalline in Gleam with libsql/Turso

## Status

Proposed

## Context

Current Sacrum is an Elixir/Phoenix server with PostgreSQL, GraphQL API, and Phoenix Channels.
Vertebrae (Rust) acts as the client with CLI, Tauri GUI, and daemon.

**Problem:** The architecture requires a separate remote server. For embedded/local-first use
with later migration to Turso (remote access), we need a self-contained backend.

**User requirements:**

- Tauri + Gleam (not Rust backend + React frontend)
- Embedded backend in Gleam
- libsql local → Turso remote (same code, no changes)
- Moldable, reusable agent control flows
- Different flow types: with loops, without loops, with human inputs between steps
- When assigning a task to an agent, be able to choose which flow type to use
- Emulate Sacrum functionality (workflow engine, task management, execution tracking)

## Decision

### Stack

| Layer | Technology | Rationale |
| --- | --- | --- |
| Backend | **Gleam** (BEAM) | Static typing, OTP concurrency, Erlang interop |
| HTTP Server | **Mist** | Native Gleam HTTP server |
| Web Framework | **Wisp** | Practical Gleam web framework |
| Database | **libsql_gleam** (Rust NIF) | Local SQLite → remote Turso without code changes |
| GUI Shell | **Facet** (TBD) | Tauri desktop client |
| Frontend Web | **Lustre** (TBD) | Gleam UI framework if SPA needed |

### Moldable Flow Architecture

Flows are modeled as **directed graphs of composable nodes**:

```
FlowTemplate (reusable definition)
  └── Node (type determines behavior)
        ├── Step          → Execute agent with prompt/config
        ├── Sequence      → Execute children in order
        ├── Branch        → Evaluate conditions, pick target
        ├── Loop          → Repeat children until exit condition
        ├── Parallel      → Execute children concurrently
        └── HumanInput    → Pause, wait for external input
  └── Transition (with optional condition)
```

**Execution mechanism:**

1. `FlowTemplate` is validated (DAG, refs, cycles)
2. Instantiated as `FlowInstance` bound to a `Task`
3. `ExecutionState` traverses the graph node by node
4. Each `advance()` returns `(new_state, action_to_execute)`
5. Caller executes the action (agent prompt, human input, etc.) and reports result

**Prebuilt patterns:**

- `build_linear_flow()`: step1 → step2 → step3
- `build_loop_flow()`: pre → loop(condition) → post
- `build_branch_flow()`: step → branch(conditions) → branches

### Persistence

```
Local:    libsql file:crystalline.db (same process)
Remote:   libsql libsql://db.turso.io (no code changes)
```

SQL migrations embedded in the binary for filesystem-free deployment.

**Connection resolution (one code path):**

1. `CRYSTALLINE_DB_URL` + `CRYSTALLINE_AUTH_TOKEN` → remote (`libsql://` or
   `https://`), opened with `libsql.open_remote(url, token)`.
2. `CRYSTALLINE_DB` → local file path or `:memory:`, `libsql.open`.
3. Default `file:crystalline.db`.

A remote URL without a token fails fast (`MissingAuthToken` → exit 1) rather
than half-initializing. `/health` reports `db_mode` (`local`/`remote`) and
never echoes the token.

**Migrations:** the same embedded runner executes against local and remote
databases — `schema_migrations` bookkeeping and all — so a schema shipped once
applies to both.

**Two-writer caveat:** every instance applies pending migrations at startup.
Pointing several instances at one shared Turso database (dev laptop + prod,
CI, hot reload) creates concurrent migration writers; migrations are applied
with the same transaction envelope as local, but cross-instance racing can
hit `SQLITE_BUSY` at the primary. Prefer one long-lived writer per shared
remote database and roll schema changes out from a single instance first.

## Consequences

### Positive

- **Zero-config local**: single binary with embedded DB
- **Transparent migration**: same code for local and remote
- **Reusable flows**: flow templates are composable
- **Strong typing**: Gleam catches errors at compile time
- **OTP concurrency**: executor is purely functional, easy to parallelize

### Negative

- **Young ecosystem**: fewer libraries than Rust/Elixir
- **libsql_gleam**: unofficial NIF, depends on external maintenance (the
  0.1.0 release cannot load its NIF on OTP 26+, so it is vendored under
  `vendor/libsql_gleam/` with a patched loader — see README "Development")
- **JSON**: no mature library (gleam_json incompatible with stdlib v1)
- **Learning curve**: Gleam is less known than Rust/Elixir

### Mitigatable risks

- Manual JSON → use `gleam_experimental` or custom wrapper
- libsql_gleam → keep abstraction layer for swap if needed
- Gleam HTTP → Wisp/Mist are stable but young

## Alternatives considered

### A) Keep Sacrum Elixir + Vertebrae Rust

- Pros: mature, proven
- Cons: not embedded, requires separate server

### B) Tauri + Rust backend (current crates/local-backend/)

- Pros: same ecosystem as Vertebrae
- Cons: no BEAM/OTP, less natural for stateful workflows

### C) Gleam + PostgreSQL

- Pros: compatible with current Sacrum
- Cons: not embedded, loses local-first advantage
