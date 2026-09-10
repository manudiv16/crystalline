# Crystalline

Embedded AI-agent workflow orchestration engine, written in Gleam.

Crystalline is the engine: it owns tasks, flow definitions, execution state and persistence.
It replaces the Elixir/Phoenix `Sacrum` server with a self-contained, local-first backend
that can also run against a remote Turso database without any code change.

```
Facet CLI ──┐
            ├→ HTTP → Crystalline (Wisp + Mist) → libsql (file: | libsql://turso)
Facet Tauri ┘
```

See [Facet](https://github.com/manudiv16/facet) for the CLI and desktop client.

## Stack

| Layer | Technology |
|---|---|
| Language | Gleam 1.14+ (BEAM) |
| HTTP | Wisp + Mist |
| Database | `libsql_gleam` (Rust NIF over libsql) |

Persistence is one code path for two deployments:

```
Local:   libsql file:crystalline.db
Remote:  libsql libsql://<db>.turso.io
```

## Moldable flows

A flow is a reusable graph of composable nodes, so a task can be given a loop, a branch,
a parallel fan-out or a human gate — or none of them.

| Node type | Semantics |
|---|---|
| `Step` | Run an agent with a prompt and `AgentConfig` |
| `Sequence` | Run children in order |
| `Branch` | Evaluate conditions, pick a target |
| `Loop` | Repeat children until the exit condition or max iterations |
| `Parallel` | Run children concurrently |
| `HumanInput` | Pause execution and wait for external input |

Execution is a pure state machine: `advance(state) -> #(new_state, Action)`.
The caller performs the `Action` (run an agent, wait for a human, complete) and feeds the
result back, which keeps the engine deterministic and testable.

```gleam
let flow = crystalline.build_linear_flow(
  "implement_review",
  "Research, implement, then review",
  [#("research", "Research the codebase"), #("implement", "Implement the feature")],
)
```

## Status

Scaffolded: domain model, flow engine and database layer are written. The build is being
stabilized and the HTTP surface is not implemented yet.

Work is tracked as dependency-linked issues so it can be parallelized:

| # | Task | Blocked by |
|---|---|---|
| [#1](https://github.com/manudiv16/crystalline/issues/1) | Compile and stabilize core modules | — |
| [#2](https://github.com/manudiv16/crystalline/issues/2) | JSON codec module | #1 |
| [#3](https://github.com/manudiv16/crystalline/issues/3) | Migrations runner | #1 |
| [#4](https://github.com/manudiv16/crystalline/issues/4) | Repository layer | #1, #2, #3 |
| [#5](https://github.com/manudiv16/crystalline/issues/5) | HTTP server bootstrap | #1, #3 |
| [#6](https://github.com/manudiv16/crystalline/issues/6) | Tasks API | #4, #5 |
| [#7](https://github.com/manudiv16/crystalline/issues/7) | Flows API | #2, #4, #5 |
| [#8](https://github.com/manudiv16/crystalline/issues/8) | Executions and session log API | #4, #5, #7 |
| [#9](https://github.com/manudiv16/crystalline/issues/9) | Agent harness adapter | #1 |
| [#10](https://github.com/manudiv16/crystalline/issues/10) | Step executor loop | #8, #9 |
| [#11](https://github.com/manudiv16/crystalline/issues/11) | Prebuilt flow template registry | #2, #7 |
| [#12](https://github.com/manudiv16/crystalline/issues/12) | Turso remote mode | #4 |
| [#13](https://github.com/manudiv16/crystalline/issues/13) | End-to-end integration test | #6, #7, #8, #10 |

Architecture decision: [`docs/adr/001-embedded-crystalline-gleam-libsql.md`](docs/adr/001-embedded-crystalline-gleam-libsql.md).
Plan: [`docs/PLAN.md`](docs/PLAN.md).

## Development

```sh
gleam run   # Start the HTTP server
gleam test  # Run the tests
gleam build # Compile
```

Environment:

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `8787` | HTTP listen port |
| `CRYSTALLINE_DB` | `file:crystalline.db` | Local database URL |
| `CRYSTALLINE_DB_URL` | — | Remote `libsql://` URL |
| `CRYSTALLINE_AUTH_TOKEN` | — | Token for the remote URL |

## Related

- [Facet](https://github.com/manudiv16/facet) — CLI + Tauri client
