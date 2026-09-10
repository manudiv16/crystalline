/// Acceptance tests for issue C11: prebuilt flow template registry.
///
/// Covers:
/// - each of the 6 templates passes seed validation
/// - seeding the database inserts 6 templates (HTTP 200 on first call)
/// - seeding again is idempotent (0 new inserts)
/// - GET /api/v1/flow-templates returns the 6 seeded slugs
/// - template shapes: loop max_iterations > 0, branch >= 2 rules, etc.
import gleam/dict
import gleam/http.{Get, Post}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import sacrum_gleam/db/connection
import sacrum_gleam/db/migrations
import sacrum_gleam/domain/flow.{type FlowTemplate, HumanInput}
import sacrum_gleam/flow/templates
import sacrum_gleam/http/router
import sacrum_gleam/http/routes/flow_templates
import wisp/simulate

pub fn main() {
  gleeunit.main()
}

// ─── Seed validation ──────────────────────────────────────────────────────

pub fn each_template_passes_seed_validation_test() {
  templates.all_template_specs()
  |> list.each(fn(spec) {
    let assert Ok(Nil) = templates.validate_for_seed(spec.build())
  })
}

// ─── Template shapes ─────────────────────────────────────────────────────

pub fn refactor_loop_has_max_fifty_iterations_test() {
  let template = spec_by_slug("refactor_loop")
  let assert Ok(loop_node) = dict.get(template.nodes, "refactor_loop")

  let assert Some(config) = loop_node.loop_config
  should.equal(config.max_iterations, Some(50))
}

pub fn review_gate_branch_has_three_rules_test() {
  let template = spec_by_slug("review_gate")
  let assert Ok(gate_node) = dict.get(template.nodes, "gate_branch")

  should.equal(list.length(gate_node.branch_rules), 3)
}

pub fn multi_file_analysis_runs_three_analyses_in_parallel_test() {
  let template = spec_by_slug("multi_file_analysis")
  let assert Ok(parallel_node) = dict.get(template.nodes, "parallel_analysis")

  should.equal(list.length(parallel_node.child_ids), 3)
}

pub fn design_implement_has_a_human_input_node_test() {
  let template = spec_by_slug("design_implement")

  let human_input_count =
    template.nodes
    |> dict.values
    |> list.count(fn(node) { node.node_type == HumanInput })

  should.equal(human_input_count, 1)
}

// ─── Seeding to the database ─────────────────────────────────────────────

pub fn seed_to_db_inserts_six_templates_test() {
  let conn = test_db()
  let assert Ok(inserted) = templates.seed_to_db(conn, 1)
  should.equal(inserted, 6)
}

pub fn seed_to_db_is_idempotent_test() {
  let conn = test_db()
  let assert Ok(first) = templates.seed_to_db(conn, 1)
  let assert Ok(second) = templates.seed_to_db(conn, 1)

  should.equal(first, 6)
  should.equal(second, 0)
}

// ─── HTTP endpoints ──────────────────────────────────────────────────────

pub fn seed_endpoint_returns_200_on_first_call_test() {
  let conn = test_db()
  let routes = flow_templates.flow_template_routes(conn)

  let response =
    router.match_route(
      routes,
      simulate.request(Post, "/api/v1/flow-templates/seed"),
    )

  should.equal(response.status, 200)
  should.equal(simulate.read_body(response), "{\"inserted\":6,\"total\":6}")
}

pub fn seed_endpoint_is_idempotent_test() {
  let conn = test_db()
  let routes = flow_templates.flow_template_routes(conn)

  let first =
    router.match_route(
      routes,
      simulate.request(Post, "/api/v1/flow-templates/seed"),
    )
  let second =
    router.match_route(
      routes,
      simulate.request(Post, "/api/v1/flow-templates/seed"),
    )

  should.equal(first.status, 200)
  should.equal(second.status, 200)
  should.equal(simulate.read_body(second), "{\"inserted\":0,\"total\":6}")
}

pub fn list_endpoint_returns_six_slugs_test() {
  let conn = test_db()
  let routes = flow_templates.flow_template_routes(conn)

  let assert Ok(_) = templates.seed_to_db(conn, 1)

  let response =
    router.match_route(routes, simulate.request(Get, "/api/v1/flow-templates"))

  should.equal(response.status, 200)

  let body = simulate.read_body(response)

  // Every prebuilt slug appears as its own JSON object in the response.
  templates.all_template_specs()
  |> list.each(fn(spec) {
    should.be_true(string.contains(body, "\"slug\":\"" <> spec.slug <> "\""))
  })

  // And exactly 6 summaries are returned (one `\"slug\":` marker each).
  let slug_markers =
    body
    |> string.split("\"slug\":")
    |> list.length
    |> int.subtract(1)
  should.equal(slug_markers, 6)
}

pub fn get_single_template_by_slug_test() {
  let conn = test_db()
  let routes = flow_templates.flow_template_routes(conn)

  let assert Ok(_) = templates.seed_to_db(conn, 1)

  let response =
    router.match_route(
      routes,
      simulate.request(Get, "/api/v1/flow-templates/implement_review"),
    )

  should.equal(response.status, 200)
  should.be_true(string.contains(
    simulate.read_body(response),
    "\"slug\":\"implement_review\"",
  ))
}

// ─── Helpers ─────────────────────────────────────────────────────────────

fn spec_by_slug(slug: String) -> FlowTemplate {
  let assert Ok(spec) =
    list.find(templates.all_template_specs(), fn(spec) { spec.slug == slug })
  spec.build()
}

fn test_db() -> connection.DbConnection {
  let assert Ok(conn) = connection.connect(":memory:", None)
  let assert Ok(_) = migrations.run_migrations(conn)
  conn
}
