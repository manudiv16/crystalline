# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Build and test

- `gleam test` fails at module load (`libsql_ffi` `on_load`) until the Rust NIF is
  installed. Run `bash scripts/build-libsql-nif.sh` once per machine first; CI does
  it before the suite. The NIF lands in `<user_cache>/libsql/`.
- `libsql_gleam` is vendored at `vendor/libsql_gleam/` (path dependency in
  `gleam.toml`) because the 0.1.0 release cannot load its own NIF on OTP 26+. The
  patched loader carries a patch note; re-vendoring upstream reintroduces both
  bugs. Rationale and details: README "Development" and
  `docs/adr/001-embedded-crystalline-gleam-libsql.md`.
- `gleam format --check src test` reports pre-existing drift in
  `src/sacrum_gleam/http/routes/flows.gleam`, `test/flows_test.gleam` and
  `test/debug_flows_test.gleam`.
- The live server and the test suite share one route table,
  `server.all_routes(conn, db_mode)` (`src/sacrum_gleam/http/server.gleam`).
  A new HTTP route MUST be added there, not only to its
  `http/routes/*` module: routes that are missing from the table exist as
  handlers but 404 on a live server. `test/e2e_test.gleam` drives
  `implement_review` / `design_implement` to completion through that table, so
  the omission fails the suite.

## Flow graph rules

- `flow/validator.validate` rejects a transition whose `from_id == to_id` for
  every node type, `Loop` and `Branch` included: the engine never follows a
  self-edge (loops iterate `loop_config.child_ids` + their iteration counter,
  branches dispatch their `branch_rules`), so one can only make
  `find_next_node` re-dispatch the same node forever. Do not re-add a `Loop`/
  `Branch` exception without changing `flow/executor.gleam` first.
- A cycle is legal only while it crosses a `Branch` (rules are re-evaluated on
  every pass — the shipped `review_gate` loops `gate_branch → fix → re_review →
  gate_branch` and exits to `done`) or a `Loop` (bounded by `loop_config`).
  Cycles made only of step/composite nodes stay rejected.
- Every shipped template must pass `validator.validate`: the daemon restores
  persisted templates through `flow_engine.register_template`, which runs that
  validator and silently skips what it rejects. Guarded by
  `test/flow_templates_test.gleam` (spec-by-spec, plus `seed_to_engine`).

## Project scoping

- Task `short_id`s are unique per project, not globally: migration 0003 keeps the
  0001 inline `short_id UNIQUE` and stores the scoped value
  `db/tasks.scoped_short_id(project_id, short_id)` (`"<project_id>:<short_id>"`).
  `Task.short_id` (domain/API) is always the 8-digit display part; do not
  "simplify" the storage to the display value or inserts collide globally.
- Do NOT rebuild `tasks` to drop that inline `UNIQUE`: this libsql build enforces
  foreign keys (`PRAGMA foreign_keys` = 1), so the required `DROP TABLE` cascades
  over sections/artifacts/flow rows, and `PRAGMA foreign_keys=OFF` is a no-op
  inside the runner's transaction.
- Requests resolve their project in `http/project_scope.resolve/2` from
  `X-Crystalline-Project` (id or slug; absent → `default`; unknown → 404), inside
  the auth-gated handler. Scoped: task create/list, ready list, sections list,
  artifacts list. Everything else by-id stays global.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
