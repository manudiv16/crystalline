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
  `test/flows_test.gleam` and `test/debug_flows_test.gleam`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
