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
| --- | --- |
| Language | Gleam 1.14+ (BEAM) |
| HTTP | Wisp + Mist |
| Database | `libsql_gleam` (Rust NIF over libsql) |

Persistence is one code path for two deployments:

```
Local:   libsql file:crystalline.db
Remote:  libsql libsql://<db>.turso.io
```

## Database modes

The mode is chosen once at startup, in this order:

1. `CRYSTALLINE_DB_URL` + `CRYSTALLINE_AUTH_TOKEN` — **remote** (Turso).
   `libsql://` and `https://` URLs are supported.
2. `CRYSTALLINE_DB` — local file path (or `:memory:`).
3. Default: `file:crystalline.db` in the working directory.

The connection is open through the same `connect` path for both modes, and the
embedded migration runner runs identically against local and remote databases
(`schema_migrations` table and all).

### Fail fast on a missing token

A remote URL without a token is a configuration error, not a flaky connection:

```sh
CRYSTALLINE_DB_URL=libsql://acme.turso.io gleam run
# → missing auth token for remote database: CRYSTALLINE_DB_URL=... is set but
#   CRYSTALLINE_AUTH_TOKEN is not set.
#   Set CRYSTALLINE_AUTH_TOKEN to connect to a remote database.
#   (exit code 1)
```

The process refuses to start rather than half-attaching to the network.

### `/health`

`GET /health` reports the resolved mode so operators can tell which database
is backing the instance:

```json
{ "status": "ok", "version": "1.0.0", "db_mode": "remote" }
```

`db_mode` is `local` or `remote`. The auth token is **never** echoed, neither
here nor in logs.

### ⚠️ Two-writer caveat for shared remote databases

Migrations are run by **every** Crystalline instance at startup. With a single
instance this is idempotent and safe; with several instances pointing at the
same Turso database (e.g. two laptops, CI and prod, or a hot-reloaded dev
server) you can hit two writers: both may apply a new migration at the same
instant, and concurrent writes can race `SQLITE_BUSY`.

Rules of thumb:

- Point one long-lived instance per shared remote database where practical
  (e.g. one server, and `:memory:` or a local file for ephemeral dev work).
- Treat the embedded runner as apply-on-boot: add a new migration, deploy one
  instance, then deploy the rest. Do not write migrations from a REPL or
  test runner against a shared database.
- libsql/Turso serializes writes at the primary, but it does not make two
  concurrent migration runners atomic.

### Root database configuration

Every `connect` call takes the URL and an optional token and routes to
`libsql.open` (local) or `libsql.open_remote` (remote) internally:

```gleam
let assert Ok(conn) = sacrum_gleam.connect("libsql://acme.turso.io", Some(token))
let assert Ok(conn) = sacrum_gleam.connect("file:crystalline.db", None)
```

A remote URL passed **without** a token fails fast with a `ConnectionError`
instead of surfacing a low-level libsql error.

## Moldable flows

A flow is a reusable graph of composable nodes, so a task can be given a loop, a branch,
a parallel fan-out or a human gate — or none of them.

| Node type | Semantics |
| --- | --- |
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
| --- | --- | --- |
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
bash scripts/build-libsql-nif.sh  # build the Rust NIF once (see below)
gleam run   # Start the HTTP server
gleam test  # Run the tests
gleam build # Compile
```

> **libsql NIF.** The `libsql_gleam` hex package does not ship a compiled NIF
> and its upstream release download is a placeholder, so the Rust NIF is built
> from source via `scripts/build-libsql-nif.sh` (pinned to a known-good
> upstream commit, `4f3d375`) and installed into Erlang's user cache where the
> FFI loads it. Run it once per machine (CI does it automatically).
>
> **Vendored `libsql_gleam`.** The pinned upstream release cannot load that NIF
> on OTP 26+: `libsql_ffi` asks `code:priv_dir/1` for an application named
> `libsql` (the OTP app is `libsql_gleam`, so the lookup returns
> `{error, bad_name}` and `on_load` crashes), and it derives the cache
> filename from `erlang:system_info(machine)`, which reports `"BEAM"` rather
> than a CPU architecture. The package is therefore vendored at
> `vendor/libsql_gleam/` with a patched `src/libsql_ffi.erl` that fixes both
> (see the patch note at the top of that file) and wired in as a path
> dependency in `gleam.toml`. The Rust NIF itself is still built from the
> pinned upstream commit. Re-vendoring from upstream will reintroduce both
> bugs unless the patch is carried over.

Environment:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `4920` | HTTP listen port |
| `CRYSTALLINE_DB` | `file:crystalline.db` | Local database URL (`file:` path or `:memory:`) |
| `CRYSTALLINE_DB_URL` | — | Remote `libsql://`/`https://` URL (takes precedence) |
| `CRYSTALLINE_AUTH_TOKEN` | — | Token for the remote URL (required when `CRYSTALLINE_DB_URL` is set) |
| `CRYSTALLINE_SECRET_KEY_BASE` | dev-only value | Wisp cookie/signing secret |

## Related

- [Facet](https://github.com/manudiv16/facet) — CLI + Tauri client
