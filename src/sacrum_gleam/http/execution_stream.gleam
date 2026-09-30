//// Server-Sent Events stream for one execution.
////
//// `GET /api/v1/executions/:id/events` streams an execution's real-time
//// updates: session-log appends and status transitions, published by
//// `sacrum_gleam/runtime/events` from the persistence write points.
////
//// ## Why this route is not part of `server.all_routes`
////
//// Mist 6.0.3 (the pinned version) does support Server-Sent Events, so no new
//// HTTP framework is needed: `mist.server_sent_events`/`mist.send_event` stream
//// events over HTTP/1.1. The response body, however, is `mist.ResponseData`,
//// while Wisp responses can only carry `Text`, `Bytes` or `File` bodies and
//// `wisp_mist.handler` discards everything else. An SSE route therefore cannot
//// exist in the `Route(method, pattern, handler)` table: `server.start/1` gets a
//// dedicated Mist handler branch that serves this path and delegates every
//// other request to the unchanged Wisp handler over `all_routes`.
////
//// ## Protocol
////
//// Each frame is a normal SSE event: `event:` is the event kind, `id:` is the
//// event cursor and `data:` is a JSON object
//// (`{"event_sequence", "type", "execution_id", ...}`). The first frame is
//// always `stream_opened` (`{"execution_id", "latest_sequence"}`), sent once the
//// subscription is registered, so a client can tell "connected" from "not yet
//// subscribed" — and duplicated work from a reconnect. A client resumes by
//// sending the last `id:` back as `?after_sequence=N` or as the standard
//// `Last-Event-ID` header; the buffered events above `N` are replayed in
//// sequence order before live delivery, and duplicates are filtered, so an event
//// is observed exactly once. `?after_sequence=` omitted means "replay whatever
//// is still buffered". `GET /api/v1/executions/:id/logs` remains the
//// authoritative history: the replay buffer is in memory and bounded.
////
//// The `:id` is a step execution id (`step-*`, as in `/executions/:id/logs`) or
//// an execution state id (`exec-*`, as returned by `/flows/:id/advance`).
//// Session-log and step-status events are keyed by the step execution they
//// belong to; execution-state transitions are keyed by the execution state.
////
//// ## Authentication
////
//// The stream is served outside the bearer-token gate, which only reads the
//// `Authorization` header — and `EventSource` cannot set request headers. This
//// route therefore re-uses the same header check and additionally accepts
//// `?token=` for the stream path only (`auth_gate.stream_authorized`); other
//// `/api/v1` routes still reject `?token=`. The token is never logged, echoed or
//// put into an event payload. A rejected stream gets the same JSON 401 envelope
//// as the rest of the API.
////
//// ## Bounds
////
//// A stream never runs unbounded: `?max_ms=` (default `default_max_ms`, clamped
//// to `min_max_ms`..`max_max_ms`) stops the subscriber actor, which owns the
//// socket and therefore closes it. Heartbeats every `heartbeat_interval_ms`
//// keep intermediaries from dropping an idle connection and detect a client
//// that vanished.

import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process
import gleam/http.{Get}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some, from_result}
import gleam/otp/actor
import gleam/string
import gleam/string_tree
import gleam/uri
import mist
import sacrum_gleam/db/connection.{type DbConnection}
import sacrum_gleam/db/executions
import sacrum_gleam/http/auth_gate
import sacrum_gleam/http/router
import sacrum_gleam/runtime/events

/// Path pattern of the execution event stream.
pub const events_pattern = "/api/v1/executions/:id/events"

/// Keep-alive interval. Also the interval at which a client that closed its
/// socket is detected (the failed send stops the subscriber actor).
pub const heartbeat_interval_ms = 15_000

/// Stream lifetime used when the client does not ask for one.
pub const default_max_ms = 300_000

/// Accepted bounds for `?max_ms=`.
pub const min_max_ms = 1000

pub const max_max_ms = 3_600_000

/// The execution id (`:id` parameter) when `request` targets the stream route.
///
/// The method is part of the match: a `POST` to the same path is not a stream.
pub fn execution_id_for(request: Request(mist.Connection)) -> Option(String) {
  case request.method {
    Get ->
      case router.path_params(events_pattern, request.path) {
        Ok(params) -> from_result(dict.get(params, "id"))
        Error(_) -> None
      }
    _ -> None
  }
}

/// Serve `GET /api/v1/executions/:id/events`.
///
/// Returns the SSE stream for a known execution, or the API's JSON error
/// envelope: 401 when a token is configured and the request carries neither a
/// matching bearer header nor a matching `?token=`, 404 when `execution_id` is
/// neither a step execution nor an execution state.
pub fn serve(
  request: Request(mist.Connection),
  execution_id: String,
  conn: DbConnection,
  token: Option(String),
) -> Response(mist.ResponseData) {
  case auth_gate.stream_authorized(request, token) {
    False -> json_error(401, "Unauthorized")
    True ->
      case execution_known(conn, execution_id) {
        False -> json_error(404, "Execution not found")
        True -> stream(request, execution_id)
      }
  }
}

// ─── Stream ──────────────────────────────────────────────────────────────

type StreamState {
  StreamState(
    execution_id: String,
    subscriber: process.Subject(events.Delivery),
    /// Highest event sequence already written to the socket.
    last_sequence: Int,
    /// Highest sequence the registry had assigned at subscribe time; reported
    /// to the client in the opening frame.
    latest_sequence: Int,
    /// Buffered events captured at subscribe time, flushed before live ones.
    replayed: List(events.Event),
  )
}

fn stream(
  request: Request(mist.Connection),
  execution_id: String,
) -> Response(mist.ResponseData) {
  let after_sequence = resume_sequence(request)
  let max_ms = stream_lifetime_ms(request)
  mist.server_sent_events(
    request,
    response.new(200),
    fn(subscriber) {
      initialise(execution_id, subscriber, after_sequence, max_ms)
    },
    handle_message,
  )
}

fn initialise(
  execution_id: String,
  subscriber: process.Subject(events.Delivery),
  after_sequence: Option(Int),
  max_ms: Int,
) -> StreamState {
  // Queue the replay flush before subscribing. The registry only delivers
  // events published after the subscribe call, so `Opened` must sit behind the
  // snapshot in the mailbox to keep the stream in sequence order.
  process.send(subscriber, events.Opened)
  let snapshot = events.subscribe(execution_id, subscriber, after_sequence)
  let _ =
    process.send_after(subscriber, heartbeat_interval_ms, events.Heartbeat)
  let _ = process.send_after(subscriber, max_ms, events.Expired)
  StreamState(
    execution_id: execution_id,
    subscriber: subscriber,
    last_sequence: option_unwrap_sequence(after_sequence),
    latest_sequence: snapshot.latest_sequence,
    replayed: snapshot.events,
  )
}

/// One message of the subscriber protocol: flush the replay snapshot, write a
/// live event or heartbeat, or stop the bounded stream.
fn handle_message(
  state: StreamState,
  message: events.Delivery,
  conn: mist.SSEConnection,
) -> actor.Next(StreamState, events.Delivery) {
  case message {
    events.Opened ->
      case send_opened(conn, state) {
        Error(_) -> actor.stop()
        Ok(state) ->
          case
            list.try_fold(state.replayed, state, fn(state, event) {
              send_event(conn, state, event)
            })
          {
            Ok(state) -> actor.continue(StreamState(..state, replayed: []))
            Error(_) -> actor.stop()
          }
      }
    events.Deliver(event) ->
      case send_event(conn, state, event) {
        Ok(state) -> actor.continue(state)
        Error(_) -> actor.stop()
      }
    events.Heartbeat -> {
      let _ =
        process.send_after(
          state.subscriber,
          heartbeat_interval_ms,
          events.Heartbeat,
        )
      case
        mist.send_event(
          conn,
          mist.event(string_tree.from_string(""))
            |> mist.event_name("keep_alive"),
        )
      {
        Ok(_) -> actor.continue(state)
        // This actor owns the socket: stopping closes the connection and
        // releases the subscription, so a vanished client is not kept alive.
        Error(_) -> actor.stop()
      }
    }
    events.Expired -> {
      events.unsubscribe(state.execution_id, state.subscriber)
      actor.stop()
    }
  }
}

/// Announce the stream to the client: `stream_opened` carries the execution id
/// and the highest sequence assigned so far, so a client knows it is
/// registered and where a later resume will pick up. `retry` sets the
/// reconnection delay EventSource should use.
fn send_opened(
  conn: mist.SSEConnection,
  state: StreamState,
) -> Result(StreamState, Nil) {
  let data =
    json.object([
      #("execution_id", json.string(state.execution_id)),
      #("latest_sequence", json.int(state.latest_sequence)),
    ])
    |> json.to_string
  let payload =
    mist.event(string_tree.from_string(data))
    |> mist.event_name("stream_opened")
    |> mist.event_retry(3000)
  case mist.send_event(conn, payload) {
    Ok(_) -> Ok(state)
    Error(_) -> Error(Nil)
  }
}

fn send_event(
  conn: mist.SSEConnection,
  state: StreamState,
  event: events.Event,
) -> Result(StreamState, Nil) {
  case event.sequence <= state.last_sequence {
    // A resume can overlap with events published between the snapshot and the
    // subscription; the cursor makes the stream exactly-once per subscriber.
    True -> Ok(state)
    False -> {
      let payload =
        mist.event(string_tree.from_string(json.to_string(event.data)))
        |> mist.event_name(events.kind_to_string(event.kind))
        |> mist.event_id(int.to_string(event.sequence))
      case mist.send_event(conn, payload) {
        Ok(_) -> Ok(StreamState(..state, last_sequence: event.sequence))
        Error(_) -> Error(Nil)
      }
    }
  }
}

// ─── Request helpers ─────────────────────────────────────────────────────

fn resume_sequence(request: Request(a)) -> Option(Int) {
  let raw = case query_value(request, "after_sequence") {
    Some(value) -> Some(value)
    None -> from_result(request.get_header(request, "last-event-id"))
  }
  case raw {
    Some(value) -> from_result(int.parse(value))
    None -> None
  }
}

fn stream_lifetime_ms(request: Request(a)) -> Int {
  case query_value(request, "max_ms") {
    Some(raw) ->
      case int.parse(raw) {
        Ok(value) -> clamp_lifetime(value)
        Error(_) -> default_max_ms
      }
    None -> default_max_ms
  }
}

fn clamp_lifetime(value: Int) -> Int {
  case value {
    _ if value < min_max_ms -> min_max_ms
    _ if value > max_max_ms -> max_max_ms
    _ -> value
  }
}

fn option_unwrap_sequence(after_sequence: Option(Int)) -> Int {
  case after_sequence {
    Some(sequence) -> sequence
    None -> 0
  }
}

fn query_value(request: Request(a), name: String) -> Option(String) {
  case request.query {
    None -> None
    Some(raw) ->
      raw
      |> string.split("&")
      |> list.find_map(fn(pair) {
        case string.split_once(pair, "=") {
          Ok(#(key, value)) if key == name -> uri.percent_decode(value)
          _ -> Error(Nil)
        }
      })
      |> from_result()
  }
}

fn execution_known(conn: DbConnection, execution_id: String) -> Bool {
  // An unknown id and an unreachable database both fail the lookup and both
  // answer 404; the API's other read routes behave the same way.
  case executions.get_step_execution(conn, execution_id) {
    Ok(_) -> True
    Error(_) ->
      case executions.get_execution_state(conn, execution_id) {
        Ok(_) -> True
        Error(_) -> False
      }
  }
}

fn json_error(status: Int, message: String) -> Response(mist.ResponseData) {
  let body = json.object([#("error", json.string(message))]) |> json.to_string
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
