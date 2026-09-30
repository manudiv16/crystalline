import gleam/int
import gleam/list
import gleam/string

/// A project (workspace) that scopes tasks.
///
/// Projects exist so several workspaces can coexist in one database: task
/// `short_id`s are only unique inside their project, and the list endpoints
/// never return another project's rows. `slug` is the stable, human-readable
/// handle accepted by the `X-Crystalline-Project` request header.
pub type Project {
  Project(
    id: String,
    slug: String,
    name: String,
    description: String,
    created_at: Int,
    updated_at: Int,
  )
}

/// Id of the project every unscoped request resolves to.
///
/// Migration 0003 inserts the matching `projects` row and backfills existing
/// tasks with it, so a request without `X-Crystalline-Project` keeps the
/// pre-projects local-first behaviour.
pub const default_project_id = "default"

pub const default_project_slug = "default"

/// Longest accepted slug, matching the header/app client expectations.
pub const max_slug_length = 64

/// Characters allowed in a slug. `:` is deliberately absent: stored task
/// short ids are `<project_id>:<short_id>`, so a slug can never break that
/// split, and slugs stay safe in URLs and headers.
const slug_chars = "abcdefghijklmnopqrstuvwxyz0123456789-_"

/// Validate a project slug, returning it unchanged when acceptable.
pub fn validate_slug(slug: String) -> Result(String, String) {
  case string.length(slug) {
    0 -> Error("Project slug must not be empty")
    length if length > max_slug_length ->
      Error(
        "Project slug must be at most "
        <> int.to_string(max_slug_length)
        <> " characters",
      )
    _ ->
      case list.all(string.to_graphemes(slug), is_slug_char) {
        True -> Ok(slug)
        False ->
          Error(
            "Project slug must contain only lowercase letters, digits, '-' and '_'",
          )
      }
  }
}

fn is_slug_char(char: String) -> Bool {
  string.contains(slug_chars, char)
}
