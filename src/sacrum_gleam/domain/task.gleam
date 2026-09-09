import gleam/option.{Option, Some, None}
import gleam/result

pub type Level {
  Epic
  Ticket
  TaskUnit
}

pub type Priority {
  Low
  Medium
  High
  Critical
}

pub type TaskStatus {
  Todo
  InProgress
  Blocked
  Done
  Cancelled
  Archived
}

pub type CodeRef {
  CodeRef(
    path: String,
    line_start: Option(Int),
    line_end: Option(Int),
    name: Option(String),
    description: Option(String),
  )
}

pub type Task {
  Task(
    id: String,
    short_id: String,
    title: String,
    description: String,
    level: Level,
    priority: Priority,
    status: TaskStatus,
    tags: List(String),
    parent_id: Option(String),
    flow_template_id: Option(String),
    flow_instance_id: Option(String),
    current_node_id: Option(String),
    worktree: Option(String),
    archived: Bool,
    created_at: Int,
    updated_at: Int,
  )
}

pub fn new_task(
  title: String,
  level: Level,
  priority: Priority,
) -> Task {
  Task(
    id: "",
    short_id: "",
    title: title,
    description: "",
    level: level,
    priority: priority,
    status: Todo,
    tags: [],
    parent_id: None,
    flow_template_id: None,
    flow_instance_id: None,
    current_node_id: None,
    worktree: None,
    archived: False,
    created_at: 0,
    updated_at: 0,
  )
}

pub fn level_to_string(level: Level) -> String {
  case level {
    Epic -> "epic"
    Ticket -> "ticket"
    TaskUnit -> "task"
  }
}

pub fn level_from_string(s: String) -> Result(Level, String) {
  case s {
    "epic" -> Ok(Epic)
    "ticket" -> Ok(Ticket)
    "task" -> Ok(TaskUnit)
    _ -> Error("Unknown level: " <> s)
  }
}

pub fn priority_to_string(p: Priority) -> String {
  case p {
    Low -> "low"
    Medium -> "medium"
    High -> "high"
    Critical -> "critical"
  }
}

pub fn priority_from_string(s: String) -> Result(Priority, String) {
  case s {
    "low" -> Ok(Low)
    "medium" -> Ok(Medium)
    "high" -> Ok(High)
    "critical" -> Ok(Critical)
    _ -> Error("Unknown priority: " <> s)
  }
}

pub fn status_to_string(s: TaskStatus) -> String {
  case s {
    Todo -> "todo"
    InProgress -> "in_progress"
    Blocked -> "blocked"
    Done -> "done"
    Cancelled -> "cancelled"
    Archived -> "archived"
  }
}

pub fn status_from_string(s: String) -> Result(TaskStatus, String) {
  case s {
    "todo" -> Ok(Todo)
    "in_progress" -> Ok(InProgress)
    "blocked" -> Ok(Blocked)
    "done" -> Ok(Done)
    "cancelled" -> Ok(Cancelled)
    "archived" -> Ok(Archived)
    _ -> Error("Unknown status: " <> s)
  }
}
