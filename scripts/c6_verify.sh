#!/bin/bash
# C6 acceptance verification against real SQLite (the libsql:memory: driver is
# unavailable in this environment, so we validate the exact SQL from
# db/tasks.gleam against a SQLite database).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DB=/tmp/c6_verify.db
rm -f "$DB"
sqlite3 "$DB" < migrations/0001_init.sql

fail=0
note() { printf '%s\n' "$*"; }
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then note "PASS: $1"; else note "FAIL: $1 (expected [$2], got [$3])"; fail=1; fi
}

# Helper to insert a task row exactly as db/tasks.gleam create_task does.
insert_task() { # id short_id title level priority parent
  sqlite3 "$DB" "INSERT INTO tasks (id, short_id, title, description, level, priority, status, tags, parent_id, flow_template_id, flow_instance_id, current_node_id, worktree, archived, created_at, updated_at)
  VALUES ('$1','$2','$3','','$4','$5','todo','[]', $( [ -n "${6:-}" ] && echo "'$6'" || echo NULL ), NULL,NULL,NULL,NULL,0,0,0);"
}

# ─── 1. POST /api/v1/tasks equivalent: insert returns the new task ────────
insert_task "t1" "00000001" "Foundation" "ticket" "high" ""
check "1. create task row (short_id stored)" "00000001" "$(sqlite3 "$DB" "SELECT short_id FROM tasks WHERE id='t1'")"

# ─── 2. Missing title → NOT NULL constraint (route returns 400) ───────────
# (route-level 400 handled by validate_create_input; DB enforces NOT NULL)
if sqlite3 "$DB" "INSERT INTO tasks (id, short_id, title, level, priority, created_at, updated_at) VALUES ('bad','00000009',NULL,'ticket','high',0,0)" 2>/dev/null; then
  note "UNEXPECTED: null title insert succeeded"; fail=1
else
  note "PASS: 2. missing title rejected by schema (route maps to 400)"
fi

# ─── 3. /ready excludes tasks with incomplete deps ────────────────────────
insert_task "t2" "00000002" "Depends on foundation" "ticket" "high" ""
sqlite3 "$DB" "INSERT INTO task_dependencies (task_id, depends_on) VALUES ('t2','t1')" 

READY_BEFORE=$(sqlite3 "$DB" "
SELECT id FROM tasks
WHERE archived = 0 AND status != 'done'
AND id NOT IN (
  SELECT d.task_id FROM task_dependencies d
  JOIN tasks dep ON dep.id = d.depends_on
  WHERE dep.status != 'done' AND dep.archived = 0
)
ORDER BY created_at DESC")
check "3a. ready list contains only the unblocked task (t1)" "t1" "$READY_BEFORE"

# block t1 itself (create cycle chain) → nothing ready
sqlite3 "$DB" "INSERT INTO task_dependencies (task_id, depends_on) VALUES ('t1','t2')"
READY_CYCLE=$(sqlite3 "$DB" "
SELECT id FROM tasks
WHERE archived = 0 AND status != 'done'
AND id NOT IN (
  SELECT d.task_id FROM task_dependencies d
  JOIN tasks dep ON dep.id = d.depends_on
  WHERE dep.status != 'done' AND dep.archived = 0
)
ORDER BY created_at DESC")
check "3b. ready list empty when all have blockers" "" "$READY_CYCLE"

# complete t1 → t2 becomes ready
sqlite3 "$DB" "DELETE FROM task_dependencies WHERE task_id='t1' AND depends_on='t2'"
sqlite3 "$DB" "UPDATE tasks SET status='done' WHERE id='t1'"
READY_AFTER=$(sqlite3 "$DB" "
SELECT id FROM tasks
WHERE archived = 0 AND status != 'done'
AND id NOT IN (
  SELECT d.task_id FROM task_dependencies d
  JOIN tasks dep ON dep.id = d.depends_on
  WHERE dep.status != 'done' AND dep.archived = 0
)
ORDER BY created_at DESC")
check "3c. t2 becomes ready after t1 is done" "t2" "$READY_AFTER"

# ─── 4. Cycle detection CTE (would_create_cycle) ──────────────────────────
# Currently: t2 depends_on t1. Adding t1 depends_on t2 would create a cycle:
# would_create_cycle(task_id='t1', depends_on='t2') walks the dependency
# closure of 't2' and asks whether 't1' is reachable.
CYCLE=$(sqlite3 "$DB" "
WITH RECURSIVE deps(id) AS (
  SELECT depends_on FROM task_dependencies WHERE task_id = 't2'
  UNION
  SELECT d.depends_on FROM task_dependencies d
  JOIN deps ON d.task_id = deps.id
)
SELECT COUNT(*) FROM deps WHERE id = 't1'")
check "4. would_create_cycle detects t1→t2 edge as a cycle (1)" "1" "$CYCLE"

# would_create_cycle(task_id='t2', depends_on='t1'): closure of 't1' is empty
# (t1 has no dependencies), so no cycle → route returns 201.
NOCYCLE=$(sqlite3 "$DB" "
WITH RECURSIVE deps(id) AS (
  SELECT depends_on FROM task_dependencies WHERE task_id = 't1'
  UNION
  SELECT d.depends_on FROM task_dependencies d
  JOIN deps ON d.task_id = deps.id
)
SELECT COUNT(*) FROM deps WHERE id = 't2'")
check "4b. would_create_cycle allows acyclic edges (0)" "0" "$NOCYCLE"

# ─── 5. Cascade archive count (delete_task) ───────────────────────────────
insert_task "p1" "00000003" "Parent epic" "epic" "high" ""
insert_task "c1" "00000004" "Child" "ticket" "medium" "p1"
insert_task "gc1" "00000005" "Grandchild" "task" "low" "c1"

# non-cascade
sqlite3 "$DB" "UPDATE tasks SET archived = 1, updated_at = 0 WHERE id = 'p1'"
check "5a. non-cascade archives only the row (1)" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM tasks WHERE archived=1 AND id IN ('p1','c1','gc1')")"

# reset, then cascade
sqlite3 "$DB" "UPDATE tasks SET archived = 0 WHERE id IN ('p1','c1','gc1')"
sqlite3 "$DB" "
WITH RECURSIVE descendants(id) AS (
  SELECT 'p1'
  UNION ALL
  SELECT t.id FROM tasks t JOIN descendants d ON t.parent_id = d.id
)
UPDATE tasks SET archived = 1, updated_at = 0
WHERE id IN (SELECT id FROM descendants)"
check "5b. cascade archives parent + child + grandchild (3)" "3" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM tasks WHERE archived=1 AND id IN ('p1','c1','gc1')")"

# ─── Bonus: blockers query (get_blockers) ────────────────────────────────
insert_task "t3" "00000006" "Blocking task" "ticket" "medium" ""
insert_task "t4" "00000007" "Blocked task" "ticket" "medium" ""
sqlite3 "$DB" "INSERT INTO task_dependencies (task_id, depends_on) VALUES ('t4','t3')"
BLOCKERS=$(sqlite3 "$DB" "
SELECT t.id FROM task_dependencies d
JOIN tasks t ON t.id = d.depends_on
WHERE d.task_id = 't4' AND t.archived = 0 AND t.status != 'done'
ORDER BY t.created_at DESC")
check "6. get_blockers returns incomplete non-archived deps" "t3" "$BLOCKERS"

sqlite3 "$DB" "UPDATE tasks SET status='done' WHERE id='t3'"
BLOCKERS_AFTER=$(sqlite3 "$DB" "
SELECT t.id FROM task_dependencies d
JOIN tasks t ON t.id = d.depends_on
WHERE d.task_id = 't4' AND t.archived = 0 AND t.status != 'done'
ORDER BY t.created_at DESC")
check "6b. completed blockers are dropped from the list" "" "$BLOCKERS_AFTER"

if [ $fail -eq 0 ]; then
  note ""
  note "ALL C6 DB-LAYER CHECKS PASSED"
else
  note ""
  note "SOME CHECKS FAILED"
fi
rm -f "$DB"
exit $fail
