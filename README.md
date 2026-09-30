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

## Real-time execution updates

`GET /api/v1/executions/:id/events` streams one execution's updates as
Server-Sent Events: session-log appends and status transitions, published from
the persistence write points so the HTTP routes, the step runtime and the
background daemon all feed the same stream.

- `:id` is a step execution id (`step-*`, as in `/api/v1/executions/:id/logs`)
  or an execution state id (`exec-*`, as returned by `/flows/:id/advance`).
- Frames carry `event:` (the event kind — `session_log`, `step_status`,
  `execution_status`), `id:` (the event cursor) and `data:` (a JSON object with
  `event_sequence`, `type`, `execution_id` and the kind-specific fields). The
  first frame is always `stream_opened`.
- Resume with `?after_sequence=N` or the standard `Last-Event-ID` header: the
  buffered events above `N` are replayed in order before live delivery, each
  event exactly once. The replay buffer is in memory and bounded; the
  authoritative history stays `/api/v1/executions/:id/logs`.
- `EventSource` cannot send request headers, so the stream additionally accepts
  the API token as `?token=` (stream route only — every other `/api/v1` route
  still requires `Authorization: Bearer`). Prefer the header where the client
  can set one, since query strings are logged more readily than headers.
- Streams are bounded: `?max_ms=` (default 300000, max 3600000) closes the
  stream, and heartbeats every 15s keep idle connections alive and detect a
  client that went away.

## Conversational human input

A flow that parks on a `HumanInput` node (`awaiting_input`) can be driven turn
by turn instead of by one-shot text:

- `POST /api/v1/flows/:instance_id/reply` with `{"message": "<human text>"}`
  records the turn, feeds it through the same path as
  `POST /api/v1/flows/:instance_id/input` and answers the usual
  `{"execution", "action"}` envelope. No `advance` call is needed: the reply
  itself walks the flow to its next actionable node. Another gate comes back as
  `action.type = "await_input"` with the execution persisted as
  `awaiting_input`; an agent step comes back as `"run_step"` (`running`), and a
  reply on the last gate returns `"flow_complete"` (`completed`).
- Unknown instance → 404, an execution that is not `awaiting_input` (pending,
  running or terminal) → 409 naming its status, a missing or blank `message` →
  400. A refused reply writes nothing.
- `GET /api/v1/flows/:instance_id/conversation` returns the instance's human
  turns in order: one `prompt` entry (the gate's prompt) then one `human_input`
  entry (the reply) per turn, each with `step_execution_id`, `node_id`,
  `payload`, `sequence` and `created_at`.

Turns are ordinary session logs on the gate's step execution — event types
`prompt` and `human_input`, sequences `n`/`n + 1` — so `GET /api/v1/executions/
:step_execution_id/logs` pages them per turn, and `POST /input`/`POST /reject`
are unchanged. Because the appends go through `db/session_logs.append_log`, a
reply also appears on the SSE stream as a `session_log` event keyed by the gate
step execution id (use the `step_execution_id` from the transcript to subscribe
or resume).

## Task hierarchy and flow cancellation

`GET /api/v1/tasks/:id/path` returns a `path` array ordered from the root task
through the requested task. Missing task IDs return 404; malformed cyclic or
excessively deep parent chains return 500 rather than looping indefinitely.

`POST /api/v1/flows/:instance_id/cancel` cancels executions in `running` or
`awaiting_input` and returns the updated execution. Pending and terminal states
return 409 with the current status; unknown instances return 404. A cancelled
execution cannot be advanced.

## Projects and scoping

Projects make several workspaces coexist in one database. Every database has a
sentinel `default` project (id and slug `default`), created by migration 0003,
which also attributes pre-existing tasks to it.

- `POST /api/v1/projects` creates a project from `slug` and `name`
  (`description` optional). Slugs are lowercase `[a-z0-9_-]`, at most 64
  characters, and unique; duplicates return 409 and malformed slugs 400.
- `GET /api/v1/projects` lists projects; `GET /api/v1/projects/:id` fetches one
  by id **or** slug (unknown → 404).

Requests choose a project with the `X-Crystalline-Project` header, carrying
either a project id or its slug. An absent/empty header falls back to the
`default` project; a header naming no project is rejected with 404 instead of
falling back. Scoped routes are `POST /api/v1/tasks`, `GET /api/v1/tasks`,
`GET /api/v1/tasks/ready`, `GET /api/v1/tasks/:task_id/sections` and
`GET /api/v1/tasks/:task_id/artifacts`. Other task, section and artifact paths
stay global — they address an explicit id — so clients that only know an id keep
working. The optional bearer token gate is unchanged and still runs first.

Task `short_id`s are unique **per project**: the same 8-digit id may exist in
two projects. The stored column keeps the 0001 inline `UNIQUE` and holds the
scoped form `<project_id>:<short_id>`; the API always returns the 8-digit part.

## Sections API

Sections belong to a task and are available through these endpoints:

- `GET /api/v1/tasks/:task_id/sections` lists by `order`, then creation time; an
  existing task with no sections returns `[]`.
- `POST /api/v1/tasks/:task_id/sections` creates a section. `section_type` and
  `content` are required; `code_ref` and `checklist_state` are optional. An
  omitted `order` appends after the task's current maximum.
- `GET /api/v1/sections/:id`, `PATCH /api/v1/sections/:id`, and
  `DELETE /api/v1/sections/:id` fetch, partially update, and remove a section.
  PATCH accepts `content`, `section_type`, `order`, `checklist_state`, and
  individual `code_ref` fields; `code_ref: null` clears the reference and
  `checklist_state: null` clears the state.

`section_type` is one of `goal`, `context`, `current_behavior`,
`desired_behavior`, `checklist_item`, `testing_criterion`, `constraint`,
`anti_pattern`, or `failure_test`. A code reference contains `path`,
`line_start`, `line_end`, `name`, and `description`; optional values are null
when unset. Checklist state is `done`, `undone`, or null.

## Status

Implemented: the domain model, flow engine, database layer, and task, project,
flow, execution, and sections HTTP APIs, plus the real-time execution event
stream.

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

The application starts a background step-execution daemon by default on a
separate connection to the configured database. Set `CRYSTALLINE_DAEMON=0` to
disable it while keeping the HTTP server available.

Environment:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `4920` | HTTP listen port |
| `CRYSTALLINE_DB` | `file:crystalline.db` | Local database URL (`file:` path or `:memory:`) |
| `CRYSTALLINE_DB_URL` | — | Remote `libsql://`/`https://` URL (takes precedence) |
| `CRYSTALLINE_AUTH_TOKEN` | — | Token for the remote URL (required when `CRYSTALLINE_DB_URL` is set) |
| `CRYSTALLINE_API_TOKEN` | — | Optional bearer token for `/api/v1/*`; unset or empty disables auth. Send `Authorization: Bearer <token>` (the event stream also accepts `?token=` — see above). `/health` remains public. |
| `CRYSTALLINE_DAEMON` | enabled | Background step executor; set to `0` to disable |
| `CRYSTALLINE_SECRET_KEY_BASE` | dev-only value | Wisp cookie/signing secret |

## Related

- [Facet](https://github.com/manudiv16/facet) — CLI + Tauri client
