-- Migration 0003: projects and task project scoping
-- Additive, safe on an existing database: creates `projects`, inserts the
-- sentinel `default` project, attributes every existing task to it and
-- rewrites existing short ids to the scoped form `<project_id>:<short_id>`.
--
-- No table rebuild: tasks.short_id keeps the inline UNIQUE from 0001 (SQLite
-- cannot drop it in place) and this build enforces foreign keys, so the
-- required DROP TABLE would cascade over every child row.
CREATE TABLE IF NOT EXISTS projects (
    id          TEXT PRIMARY KEY,
    slug        TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_projects_slug ON projects(slug);

INSERT OR IGNORE INTO projects (id, slug, name, description, created_at, updated_at)
    VALUES ('default', 'default', 'Default Project', '',
            CAST(strftime('%s', 'now') AS INTEGER),
            CAST(strftime('%s', 'now') AS INTEGER));

ALTER TABLE tasks ADD COLUMN project_id TEXT NOT NULL DEFAULT 'default';

UPDATE tasks SET short_id = 'default:' || short_id;

CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id);
