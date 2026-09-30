/// Artifact records and codecs for their arbitrary JSON payloads.
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}

pub type Artifact {
  Artifact(
    id: String,
    task_id: String,
    logical_name: String,
    content: json.Json,
    created_at: Int,
    updated_at: Int,
  )
}

/// Decode any JSON value, including nested arrays, objects, and null.
pub fn json_decoder() -> decode.Decoder(json.Json) {
  use <- decode.recursive
  decode.one_of(decode.string |> decode.map(json.string), [
    decode.int |> decode.map(json.int),
    decode.float |> decode.map(json.float),
    decode.bool |> decode.map(json.bool),
    decode.list(json_decoder())
      |> decode.map(fn(values) { json.array(values, fn(value) { value }) }),
    decode.dict(decode.string, json_decoder())
      |> decode.map(fn(values) {
        json.dict(values, fn(key) { key }, fn(value) { value })
      }),
    decode.optional(decode.string)
      |> decode.map(fn(value) {
        case value {
          Some(value) -> json.string(value)
          None -> json.null()
        }
      }),
  ])
}
