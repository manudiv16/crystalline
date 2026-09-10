import gleam/option.{type Option}

pub type SectionType {
  Goal
  Context
  CurrentBehavior
  DesiredBehavior
  ChecklistItem
  TestingCriterion
  Constraint
  AntiPattern
  FailureTest
}

pub type ChecklistState {
  Done
  Undone
}

pub type Section {
  Section(
    id: String,
    task_id: String,
    section_type: SectionType,
    content: String,
    code_ref: Option(CodeRef),
    order: Int,
    checklist_state: Option(ChecklistState),
  )
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

pub fn section_type_to_string(t: SectionType) -> String {
  case t {
    Goal -> "goal"
    Context -> "context"
    CurrentBehavior -> "current_behavior"
    DesiredBehavior -> "desired_behavior"
    ChecklistItem -> "checklist_item"
    TestingCriterion -> "testing_criterion"
    Constraint -> "constraint"
    AntiPattern -> "anti_pattern"
    FailureTest -> "failure_test"
  }
}

pub fn section_type_from_string(s: String) -> Result(SectionType, String) {
  case s {
    "goal" -> Ok(Goal)
    "context" -> Ok(Context)
    "current_behavior" -> Ok(CurrentBehavior)
    "desired_behavior" -> Ok(DesiredBehavior)
    "checklist_item" -> Ok(ChecklistItem)
    "testing_criterion" -> Ok(TestingCriterion)
    "constraint" -> Ok(Constraint)
    "anti_pattern" -> Ok(AntiPattern)
    "failure_test" -> Ok(FailureTest)
    _ -> Error("Unknown section type: " <> s)
  }
}
