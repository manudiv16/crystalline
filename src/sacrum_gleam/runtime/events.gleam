//// Real-time execution event fan-out.
////
//// The HTTP layer exposes `GET /api/v1/executions/:id/events` as a
//// Server-Sent Events stream (see `sacrum_gleam/http/execution_stream`). This
//// module owns the in-BEAM fan-out behind that stream: one registry process
//// holds, per execution id, the subscribed stream actors and a bounded replay
//// buffer of the events published so far.
////
//// ## Where events come from
////
//// Publishing happens at the real write points, after the write succeeded:
//// `db/session_logs.append_log`, `db/executions.update_step_execution`,
//// `db/executions.update_execution_status` and
//// `db/executions.save_execution_state`. Every caller — HTTP routes, the
//// runtime executor and the background daemon — goes through those functions,
//// so a stream sees work persisted by any of them.
////
//// ## Ordering and resumption
////
//// The registry assigns each event a `sequence`, `MAX + 1` per execution id.
//// Because the registry is the single writer, sequences are publication order
//// with no gaps. A subscriber that resumes with `after_sequence = N` receives
//// the buffered events above N in order, then live delivery; duplicates are
//// filtered by sequence, so an event is observed exactly once per subscriber.
////
//// ## Bounds and honesty
////
//// Delivery is best-effort and in-memory: only the newest
//// `max_replay_events` events per execution are retained, the registry keeps
//// at most `max_tracked_executions` executions without subscribers, and
//// anything published while the registry is not running is gone. The
//// authoritative history stays `GET /api/v1/executions/:id/logs`.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sacrum_gleam/domain/execution.{
  type ExecutionStatus, type StepExecution, execution_status_to_string,
  step_status_to_string,
}
import sacrum_gleam/domain/session.{type SessionLog}

/// Event kinds published on an execution stream. The string form of a kind is
/// the SSE `event:` name and the `type` field of the event payload.
pub type EventKind {
  /// A session-log row was appended for a step execution.
  SessionLogEvent
  /// A step execution moved to a new status (or was rewritten).
  StepStatusEvent
  /// An execution state was created or transitioned.
  ExecutionStatusEvent
}

pub fn kind_to_string(kind: EventKind) -> String {
  case kind {
    SessionLogEvent -> "session_log"
    StepStatusEvent -> "step_status"
    ExecutionStatusEvent -> "execution_status"
  }
}

/// One published event.
///
/// `sequence` is assigned by the registry when the event is published and is
/// strictly increasing per execution id. `data` is the SSE payload: a JSON
/// object carrying `event_sequence` (the same cursor), `type`, `execution_id`
/// and the kind-specific fields.
pub type Event {
  Event(sequence: Int, kind: EventKind, execution_id: String, data: json.Json)
}

/// Messages a stream subscriber actor receives.
///
/// The registry sends [`Deliver`](#Deliver). [`Opened`](#Opened),
/// [`Heartbeat`](#Heartbeat) and [`Expired`](#Expired) are sent by the stream
/// adapter itself to drive its own lifecycle: a subscriber flushes its replay
/// snapshot on `Opened`, keeps the connection alive (and notices a dead client
/// socket) on `Heartbeat`, and stops the stream on `Expired`.
pub type Delivery {
  Deliver(event: Event)
  Opened
  Heartbeat
  Expired
}

/// Newest events retained per execution for replay.
pub const max_replay_events: Int = 256

/// Executions tracked without subscribers before the registry drops the
/// excess. Executions with subscribers are never dropped.
pub const max_tracked_executions: Int = 1024

/// How often the registry prunes dead subscribers when idle.
const prune_interval_ms: Int = 5000

/// How long a subscriber waits for the registry to acknowledge a subscribe.
const subscribe_timeout_ms: Int = 5000

/// How long `start` waits for a freshly spawned registry to report ready.
const startup_timeout_ms: Int = 5000

// `persistent_term` holds the registry's subject so publishers and subscribers
// in any process can reach it without threading a handle through the DB layer.
// The key is a constant and the value is written once per registry lifetime.
const registry_key = "sacrum_gleam.runtime.events.registry"

@external(erlang, "persistent_term", "put")
fn persistent_put(
  key: String,
  value: Option(process.Subject(RegistryMessage)),
) -> Nil

@external(erlang, "persistent_term", "get")
fn persistent_get(
  key: String,
  default: Option(process.Subject(RegistryMessage)),
) -> Option(process.Subject(RegistryMessage))

type Stream {
  Stream(
    subscribers: List(process.Subject(Delivery)),
    /// Chronological, oldest first, newest last. Bounded by
    /// `max_replay_events`.
    buffered: List(Event),
    /// Sequence to assign to the next published event.
    next_sequence: Int,
  )
}

type RegistryMessage {
  PublishEvent(
    execution_id: String,
    kind: EventKind,
    fields: List(#(String, json.Json)),
  )
  SubscribeRequest(
    reply: process.Subject(SubscribeReply),
    execution_id: String,
    subscriber: process.Subject(Delivery),
    after_sequence: Option(Int),
  )
  Unsubscribe(execution_id: String, subscriber: process.Subject(Delivery))
}

// ─── Public API ──────────────────────────────────────────────────────────

/// Start the event registry if it is not already running.
///
/// Idempotent. `server.start/1` calls this at boot; publishers and subscribers
/// call it defensively so they never observe a half-started registry.
pub fn start() -> Nil {
  case registry_subject() {
    Some(_) -> Nil
    None -> {
      let ready = process.new_subject()
      let _ =
        process.spawn_unlinked(fn() {
          let subject = process.new_subject()
          process.send(ready, subject)
          registry_loop(dict.new(), subject)
        })
      case process.receive(ready, within: startup_timeout_ms) {
        Ok(subject) -> persistent_put(registry_key, Some(subject))
        Error(_) -> Nil
      }
    }
  }
}

/// Publish an event for `execution_id`.
///
/// The registry assigns the sequence and fans the event out to the subscribers
/// registered at that moment. A no-op when the registry is not running (no
/// subscriber can exist then, and the event is not durable).
pub fn publish(
  execution_id: String,
  kind: EventKind,
  fields: List(#(String, json.Json)),
) -> Nil {
  case registry_subject() {
    None -> Nil
    Some(registry) ->
      process.send(registry, PublishEvent(execution_id, kind, fields))
  }
}

/// Publish a session-log append, keyed by its step execution id.
pub fn publish_session_log(log: SessionLog) -> Nil {
  publish(log.step_execution_id, SessionLogEvent, [
    #(
      "session_log",
      json.object([
        #("id", json.string(log.id)),
        #("step_execution_id", json.string(log.step_execution_id)),
        #("task_id", json.string(log.task_id)),
        #("event_type", json.string(log.event_type)),
        #("payload", json.string(log.payload)),
        // The log's own per-step sequence, distinct from the event cursor.
        #("sequence", json.int(log.sequence)),
        #("created_at", json.int(log.created_at)),
      ]),
    ),
  ])
}

/// Publish a step-execution status change, keyed by its step execution id.
pub fn publish_step_status(step: StepExecution) -> Nil {
  publish(step.id, StepStatusEvent, [
    #("node_id", json.string(step.node_id)),
    #("status", json.string(step_status_to_string(step.status))),
    #("output", json.nullable(step.output, of: json.string)),
    #("session_id", json.nullable(step.session_id, of: json.string)),
    #("completed_at", json.nullable(step.completed_at, of: json.int)),
  ])
}

/// Publish an execution-state transition, keyed by the execution state id.
pub fn publish_execution_status(
  execution_state_id: String,
  status: ExecutionStatus,
  current_node_id: Option(String),
  now: Int,
) -> Nil {
  publish(execution_state_id, ExecutionStatusEvent, [
    #("status", json.string(execution_status_to_string(status))),
    #("current_node_id", json.nullable(current_node_id, of: json.string)),
    #("updated_at", json.int(now)),
  ])
}

/// Reply to a subscribe call: the buffered events the subscriber has not seen
/// yet (oldest first) and the highest sequence assigned for that execution.
pub type SubscribeReply {
  SubscribeReply(events: List(Event), latest_sequence: Int)
}

/// Register `subscriber` for `execution_id` and return the buffered events it
/// has not seen yet, oldest first.
///
/// `after_sequence` is the cursor the client resumed from; `None` means "send
/// everything still buffered". Registration and the snapshot happen in the
/// registry process, so events published before the call are replayed in order
/// and events published after it arrive as `Deliver` messages — never both.
pub fn subscribe(
  execution_id: String,
  subscriber: process.Subject(Delivery),
  after_sequence: Option(Int),
) -> SubscribeReply {
  start()
  case registry_subject() {
    Some(registry) ->
      process.call(registry, subscribe_timeout_ms, fn(reply) {
        SubscribeRequest(
          reply: reply,
          execution_id: execution_id,
          subscriber: subscriber,
          after_sequence: after_sequence,
        )
      })
    // Unreachable after `start`, but a stream must never crash the server.
    None -> SubscribeReply(events: [], latest_sequence: 0)
  }
}

/// Remove `subscriber` from `execution_id`'s fan-out list.
pub fn unsubscribe(
  execution_id: String,
  subscriber: process.Subject(Delivery),
) -> Nil {
  case registry_subject() {
    None -> Nil
    Some(registry) ->
      process.send(registry, Unsubscribe(execution_id, subscriber))
  }
}

// ─── Registry ────────────────────────────────────────────────────────────

fn registry_subject() -> Option(process.Subject(RegistryMessage)) {
  case persistent_get(registry_key, None) {
    Some(subject) ->
      case process.subject_owner(subject) {
        Ok(pid) ->
          case process.is_alive(pid) {
            True -> Some(subject)
            False -> None
          }
        Error(_) -> None
      }
    None -> None
  }
}

fn registry_loop(
  state: Dict(String, Stream),
  subject: process.Subject(RegistryMessage),
) -> Nil {
  case process.receive(subject, within: prune_interval_ms) {
    Ok(PublishEvent(execution_id, kind, fields)) ->
      registry_loop(handle_publish(state, execution_id, kind, fields), subject)
    Ok(SubscribeRequest(reply, execution_id, subscriber, after_sequence)) ->
      registry_loop(
        handle_subscribe(state, reply, execution_id, subscriber, after_sequence),
        subject,
      )
    Ok(Unsubscribe(execution_id, subscriber)) ->
      registry_loop(
        handle_unsubscribe(state, execution_id, subscriber),
        subject,
      )
    Error(_) -> registry_loop(prune(state), subject)
  }
}

fn handle_publish(
  state: Dict(String, Stream),
  execution_id: String,
  kind: EventKind,
  fields: List(#(String, json.Json)),
) -> Dict(String, Stream) {
  let stream = dict.get(state, execution_id) |> result.unwrap(empty_stream())
  let sequence = stream.next_sequence
  let data =
    json.object([
      #("event_sequence", json.int(sequence)),
      #("type", json.string(kind_to_string(kind))),
      #("execution_id", json.string(execution_id)),
      ..fields
    ])
  let event =
    Event(
      sequence: sequence,
      kind: kind,
      execution_id: execution_id,
      data: data,
    )
  let subscribers = list.filter(stream.subscribers, is_live)
  let _ =
    list.map(subscribers, fn(subscriber) {
      process.send(subscriber, Deliver(event))
    })
  let stream =
    Stream(
      subscribers: subscribers,
      buffered: keep_last(
        list.append(stream.buffered, [event]),
        max_replay_events,
      ),
      next_sequence: sequence + 1,
    )
  dict.insert(state, execution_id, stream)
}

fn handle_subscribe(
  state: Dict(String, Stream),
  reply: process.Subject(SubscribeReply),
  execution_id: String,
  subscriber: process.Subject(Delivery),
  after_sequence: Option(Int),
) -> Dict(String, Stream) {
  let stream = dict.get(state, execution_id) |> result.unwrap(empty_stream())
  let floor = option.unwrap(after_sequence, 0)
  let replay =
    list.filter(stream.buffered, fn(event) { event.sequence > floor })
  process.send(
    reply,
    SubscribeReply(events: replay, latest_sequence: stream.next_sequence - 1),
  )
  let stream =
    Stream(
      ..stream,
      subscribers: list.filter([subscriber, ..stream.subscribers], is_live),
    )
  dict.insert(state, execution_id, stream)
}

fn handle_unsubscribe(
  state: Dict(String, Stream),
  execution_id: String,
  subscriber: process.Subject(Delivery),
) -> Dict(String, Stream) {
  case dict.get(state, execution_id) {
    Error(_) -> state
    Ok(stream) ->
      dict.insert(
        state,
        execution_id,
        Stream(
          ..stream,
          subscribers: list.filter(stream.subscribers, fn(known) {
            known != subscriber
          }),
        ),
      )
  }
}

fn prune(state: Dict(String, Stream)) -> Dict(String, Stream) {
  let live =
    dict.map_values(state, fn(_execution_id, stream) {
      Stream(..stream, subscribers: list.filter(stream.subscribers, is_live))
    })
  case dict.size(live) > max_tracked_executions {
    True -> drop_excess(live)
    False -> live
  }
}

/// Keep every execution that still has subscribers and as many idling ones as
/// the cap allows, so a long-lived server cannot grow the registry without
/// bound.
fn drop_excess(state: Dict(String, Stream)) -> Dict(String, Stream) {
  let #(subscribed, idling) =
    state
    |> dict.to_list
    |> list.partition(fn(pair) { !list.is_empty(pair.1.subscribers) })
  let keep = int.max(0, max_tracked_executions - list.length(subscribed))
  list.append(subscribed, list.take(idling, keep)) |> dict.from_list
}

fn empty_stream() -> Stream {
  Stream(subscribers: [], buffered: [], next_sequence: 1)
}

fn is_live(subscriber: process.Subject(Delivery)) -> Bool {
  case process.subject_owner(subscriber) {
    Ok(pid) -> process.is_alive(pid)
    Error(_) -> False
  }
}

fn keep_last(items: List(a), maximum: Int) -> List(a) {
  let length = list.length(items)
  case length > maximum {
    True -> list.drop(items, length - maximum)
    False -> items
  }
}
