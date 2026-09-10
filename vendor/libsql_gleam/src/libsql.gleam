import gleam/dynamic/decode.{type Decoder, type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Connection

pub type Statement

pub type Value

pub type Error {
  LibsqlError(
    code: ErrorCode,
    message: String,
    offset: Int,
  )
}

pub type ErrorCode {
  Abort
  Auth
  Busy
  Cantopen
  Constraint
  Corrupt
  Done
  Empty
  GenericError
  Format
  Full
  Internal
  Interrupt
  Ioerr
  Locked
  Mismatch
  Misuse
  Nolfs
  Nomem
  Notadb
  Notfound
  Notice
  GenericOk
  Perm
  Protocol
  Range
  Readonly
  Row
  Schema
  Toobig
  Warning
  AbortRollback
  AuthUser
  BusyRecovery
  BusySnapshot
  BusyTimeout
  CantopenConvpath
  CantopenDirtywal
  CantopenFullpath
  CantopenIsdir
  CantopenNotempdir
  CantopenSymlink
  ConstraintCheck
  ConstraintCommithook
  ConstraintDatatype
  ConstraintForeignkey
  ConstraintFunction
  ConstraintNotnull
  ConstraintPinned
  ConstraintPrimarykey
  ConstraintRowid
  ConstraintTrigger
  ConstraintUnique
  ConstraintVtab
  CorruptIndex
  CorruptSequence
  CorruptVtab
  ErrorMissingCollseq
  ErrorRetry
  ErrorSnapshot
  IoerrAccess
  IoerrAuth
  IoerrBeginAtomic
  IoerrBlocked
  IoerrCheckreservedlock
  IoerrClose
  IoerrCommitAtomic
  IoerrConvpath
  IoerrCorruptfs
  IoerrData
  IoerrDelete
  IoerrDeleteNoent
  IoerrDirClose
  IoerrDirFsync
  IoerrFstat
  IoerrFsync
  IoerrGettemppath
  IoerrLock
  IoerrMmap
  IoerrNomem
  IoerrRdlock
}

pub fn error_code_to_int(error: ErrorCode) -> Int {
  case error {
    GenericError -> 1
    Abort -> 4
    Auth -> 23
    Busy -> 5
    Cantopen -> 14
    Constraint -> 19
    Corrupt -> 11
    Done -> 101
    Empty -> 16
    Format -> 24
    Full -> 13
    Internal -> 2
    Interrupt -> 9
    Ioerr -> 10
    Locked -> 6
    Mismatch -> 20
    Misuse -> 21
    Nolfs -> 22
    Nomem -> 7
    Notadb -> 26
    Notfound -> 12
    Notice -> 27
    GenericOk -> 0
    Perm -> 3
    Protocol -> 15
    Range -> 25
    Readonly -> 8
    Row -> 100
    Schema -> 17
    Toobig -> 18
    Warning -> 28
    AbortRollback -> 516
    AuthUser -> 279
    BusyRecovery -> 261
    BusySnapshot -> 517
    BusyTimeout -> 773
    CantopenConvpath -> 1038
    CantopenDirtywal -> 1294
    CantopenFullpath -> 782
    CantopenIsdir -> 526
    CantopenNotempdir -> 270
    CantopenSymlink -> 1550
    ConstraintCheck -> 275
    ConstraintCommithook -> 531
    ConstraintDatatype -> 3091
    ConstraintForeignkey -> 787
    ConstraintFunction -> 1043
    ConstraintNotnull -> 1299
    ConstraintPinned -> 2835
    ConstraintPrimarykey -> 1555
    ConstraintRowid -> 2579
    ConstraintTrigger -> 1811
    ConstraintUnique -> 2067
    ConstraintVtab -> 2323
    CorruptIndex -> 779
    CorruptSequence -> 523
    CorruptVtab -> 267
    ErrorMissingCollseq -> 257
    ErrorRetry -> 513
    ErrorSnapshot -> 769
    IoerrAccess -> 3338
    IoerrAuth -> 7178
    IoerrBeginAtomic -> 7434
    IoerrBlocked -> 2826
    IoerrCheckreservedlock -> 3594
    IoerrClose -> 4106
    IoerrCommitAtomic -> 7690
    IoerrConvpath -> 6666
    IoerrCorruptfs -> 8458
    IoerrData -> 8202
    IoerrDelete -> 2570
    IoerrDeleteNoent -> 5898
    IoerrDirClose -> 4362
    IoerrDirFsync -> 1290
    IoerrFstat -> 1802
    IoerrFsync -> 1034
    IoerrGettemppath -> 6410
    IoerrLock -> 3850
    IoerrMmap -> 6154
    IoerrNomem -> 3082
    IoerrRdlock -> 2314
  }
}

pub fn error_code_from_int(code: Int) -> ErrorCode {
  case code {
    4 -> Abort
    23 -> Auth
    5 -> Busy
    14 -> Cantopen
    19 -> Constraint
    11 -> Corrupt
    101 -> Done
    16 -> Empty
    1 -> GenericError
    24 -> Format
    13 -> Full
    2 -> Internal
    9 -> Interrupt
    10 -> Ioerr
    6 -> Locked
    20 -> Mismatch
    21 -> Misuse
    22 -> Nolfs
    7 -> Nomem
    26 -> Notadb
    12 -> Notfound
    27 -> Notice
    0 -> GenericOk
    3 -> Perm
    15 -> Protocol
    25 -> Range
    8 -> Readonly
    100 -> Row
    17 -> Schema
    18 -> Toobig
    28 -> Warning
    516 -> AbortRollback
    279 -> AuthUser
    261 -> BusyRecovery
    517 -> BusySnapshot
    773 -> BusyTimeout
    1038 -> CantopenConvpath
    1294 -> CantopenDirtywal
    782 -> CantopenFullpath
    526 -> CantopenIsdir
    270 -> CantopenNotempdir
    1550 -> CantopenSymlink
    275 -> ConstraintCheck
    531 -> ConstraintCommithook
    3091 -> ConstraintDatatype
    787 -> ConstraintForeignkey
    1043 -> ConstraintFunction
    1299 -> ConstraintNotnull
    2835 -> ConstraintPinned
    1555 -> ConstraintPrimarykey
    2579 -> ConstraintRowid
    1811 -> ConstraintTrigger
    2067 -> ConstraintUnique
    2323 -> ConstraintVtab
    779 -> CorruptIndex
    523 -> CorruptSequence
    267 -> CorruptVtab
    257 -> ErrorMissingCollseq
    513 -> ErrorRetry
    769 -> ErrorSnapshot
    3338 -> IoerrAccess
    7178 -> IoerrAuth
    7434 -> IoerrBeginAtomic
    2826 -> IoerrBlocked
    3594 -> IoerrCheckreservedlock
    4106 -> IoerrClose
    7690 -> IoerrCommitAtomic
    6666 -> IoerrConvpath
    8458 -> IoerrCorruptfs
    8202 -> IoerrData
    2570 -> IoerrDelete
    5898 -> IoerrDeleteNoent
    4362 -> IoerrDirClose
    1290 -> IoerrDirFsync
    1802 -> IoerrFstat
    1034 -> IoerrFsync
    6410 -> IoerrGettemppath
    3850 -> IoerrLock
    6154 -> IoerrMmap
    3082 -> IoerrNomem
    2314 -> IoerrRdlock
    _ -> GenericError
  }
}

@external(erlang, "libsql_ffi", "open")
fn open_(a: String) -> Result(Connection, Error)

@external(erlang, "libsql_ffi", "open_remote")
fn open_remote_(a: String, b: String) -> Result(Connection, Error)

@external(erlang, "libsql_ffi", "close")
fn close_(a: Connection) -> Result(Nil, Error)

pub fn open(path: String) -> Result(Connection, Error) {
  open_(path)
}

pub fn open_remote(url: String, token: String) -> Result(Connection, Error) {
  open_remote_(url, token)
}

pub fn close(connection: Connection) -> Result(Nil, Error) {
  close_(connection)
}

pub fn with_connection(path: String, f: fn(Connection) -> a) -> a {
  let assert Ok(connection) = open(path)
  let value = f(connection)
  let assert Ok(_) = close(connection)
  value
}

pub fn with_remote_connection(url: String, token: String, f: fn(Connection) -> a) -> a {
  let assert Ok(connection) = open_remote(url, token)
  let value = f(connection)
  let assert Ok(_) = close(connection)
  value
}

@external(erlang, "libsql_ffi", "open_replica")
fn open_replica_(a: String, b: String, c: String) -> Result(Connection, Error)

pub fn open_replica(
  path: String,
  url: String,
  token: String,
) -> Result(Connection, Error) {
  open_replica_(path, url, token)
}

pub fn with_replica_connection(
  path: String,
  url: String,
  token: String,
  f: fn(Connection) -> a,
) -> a {
  let assert Ok(connection) = open_replica(path, url, token)
  let value = f(connection)
  let assert Ok(_) = close(connection)
  value
}

@external(erlang, "libsql_ffi", "open_synced_database")
fn open_synced_database_(a: String, b: String, c: String) -> Result(Connection, Error)

pub fn open_synced_database(path: String, url: String, token: String) -> Result(Connection, Error) {
  open_synced_database_(path, url, token)
}

pub fn with_synced_database(
  path: String,
  url: String,
  token: String,
  f: fn(Connection) -> a,
) -> a {
  let assert Ok(connection) = open_synced_database(path, url, token)
  let value = f(connection)
  let assert Ok(_) = close(connection)
  value
}

pub type Replicated {
  Replicated(frame_no: Option(Int), frames_synced: Int)
}

@external(erlang, "libsql_ffi", "sync")
fn sync_(a: Connection) -> Result(#(Int, Int), Error)

@external(erlang, "libsql_ffi", "replication_index")
fn replication_index_(a: Connection) -> Result(Dynamic, Error)

pub fn sync(connection: Connection) -> Result(Replicated, Error) {
  use result <- result.try(sync_(connection))
  let #(frame_no_raw, frames_synced) = result
  let frame_no = case frame_no_raw {
    -1 -> option.None
    n -> option.Some(n)
  }
  Ok(Replicated(frame_no: frame_no, frames_synced: frames_synced))
}

pub fn replication_index(
  connection: Connection,
) -> Result(Option(Int), Error) {
  use raw <- result.try(replication_index_(connection))
  case decode.run(raw, decode.optional(decode.int)) {
    Ok(val) -> Ok(val)
    Error(_) -> Ok(option.None)
  }
}

pub fn exec(sql: String, on connection: Connection) -> Result(Nil, Error) {
  exec_(sql, connection)
}

@external(erlang, "libsql_ffi", "exec_batch")
fn exec_batch_(a: String, b: Connection, c: List(List(Value))) -> Result(Nil, Error)

pub fn exec_batch(
  sql: String,
  on connection: Connection,
  with batches: List(List(Value)),
) -> Result(Nil, Error) {
  exec_batch_(sql, connection, batches)
}

pub fn begin(on connection: Connection) -> Result(Nil, Error) {
  exec("BEGIN", connection)
}

pub fn commit(on connection: Connection) -> Result(Nil, Error) {
  exec("COMMIT", connection)
}

pub fn rollback(on connection: Connection) -> Result(Nil, Error) {
  exec("ROLLBACK", connection)
}

pub fn transaction(
  on connection: Connection,
  run f: fn() -> Result(a, Error),
) -> Result(a, Error) {
  use _ <- result.try(begin(connection))
  case f() {
    Ok(value) -> {
      use _ <- result.try(commit(connection))
      Ok(value)
    }
    Error(e) -> {
      let _ = rollback(connection)
      Error(e)
    }
  }
}

pub fn query(
  sql: String,
  on connection: Connection,
  with arguments: List(Value),
  expecting decoder: Decoder(t),
) -> Result(List(t), Error) {
  use rows <- result.try(run_query(sql, connection, arguments))
  use rows <- result.try(
    list.try_map(over: rows, with: fn(row) { decode.run(row, decoder) })
    |> result.map_error(decode_error),
  )
  Ok(rows)
}

pub fn query_named(
  sql: String,
  on connection: Connection,
  with arguments: List(#(String, Value)),
  expecting decoder: Decoder(t),
) -> Result(List(t), Error) {
  use rows <- result.try(run_query_named(sql, connection, arguments))
  use rows <- result.try(
    list.try_map(over: rows, with: fn(row) { decode.run(row, decoder) })
    |> result.map_error(decode_error),
  )
  Ok(rows)
}

pub fn query_first(
  sql: String,
  on connection: Connection,
  with arguments: List(Value),
  expecting decoder: Decoder(t),
) -> Result(Option(t), Error) {
  use rows <- result.try(query(sql, connection, arguments, decoder))
  case rows {
    [] -> Ok(None)
    [first, ..] -> Ok(Some(first))
  }
}

pub fn query_first_named(
  sql: String,
  on connection: Connection,
  with arguments: List(#(String, Value)),
  expecting decoder: Decoder(t),
) -> Result(Option(t), Error) {
  use rows <- result.try(query_named(sql, connection, arguments, decoder))
  case rows {
    [] -> Ok(None)
    [first, ..] -> Ok(Some(first))
  }
}

pub fn query_one(
  sql: String,
  on connection: Connection,
  with arguments: List(Value),
  expecting decoder: Decoder(t),
) -> Result(t, Error) {
  use rows <- result.try(query(sql, connection, arguments, decoder))
  case rows {
    [one] -> Ok(one)
    [] ->
      Error(LibsqlError(
        GenericError,
        "Query returned 0 rows, expected exactly 1",
        -1,
      ))
    _ ->
      Error(LibsqlError(
        GenericError,
        "Query returned multiple rows, expected exactly 1",
        -1,
      ))
  }
}

pub fn query_one_named(
  sql: String,
  on connection: Connection,
  with arguments: List(#(String, Value)),
  expecting decoder: Decoder(t),
) -> Result(t, Error) {
  use rows <- result.try(query_named(sql, connection, arguments, decoder))
  case rows {
    [one] -> Ok(one)
    [] ->
      Error(LibsqlError(
        GenericError,
        "Query returned 0 rows, expected exactly 1",
        -1,
      ))
    _ ->
      Error(LibsqlError(
        GenericError,
        "Query returned multiple rows, expected exactly 1",
        -1,
      ))
  }
}

@external(erlang, "libsql_ffi", "changes")
fn changes_(a: Connection) -> Result(Int, Error)

@external(erlang, "libsql_ffi", "total_changes")
fn total_changes_(a: Connection) -> Result(Int, Error)

@external(erlang, "libsql_ffi", "last_insert_rowid")
fn last_insert_rowid_(a: Connection) -> Result(Int, Error)

@external(erlang, "libsql_ffi", "interrupt")
fn interrupt_(a: Connection) -> Result(Nil, Error)

pub fn changes(connection: Connection) -> Result(Int, Error) {
  changes_(connection)
}

pub fn total_changes(connection: Connection) -> Result(Int, Error) {
  total_changes_(connection)
}

pub fn last_insert_rowid(connection: Connection) -> Result(Int, Error) {
  last_insert_rowid_(connection)
}

pub fn interrupt(connection: Connection) -> Result(Nil, Error) {
  interrupt_(connection)
}

@external(erlang, "libsql_ffi", "prepare")
fn prepare_(a: String, b: Connection) -> Result(Statement, Error)

@external(erlang, "libsql_ffi", "exec_prepared")
fn exec_prepared_(a: List(Value), b: Statement) -> Result(Nil, Error)

@external(erlang, "libsql_ffi", "query_prepared")
fn run_query_prepared(
  a: List(Value),
  b: Statement,
) -> Result(List(Dynamic), Error)

@external(erlang, "libsql_ffi", "finalize")
fn finalize_(a: Statement) -> Result(Nil, Error)

pub fn prepare(sql: String, on connection: Connection) -> Result(Statement, Error) {
  prepare_(sql, connection)
}

pub fn exec_prepared(
  on statement: Statement,
  with params: List(Value),
) -> Result(Nil, Error) {
  exec_prepared_(params, statement)
}

pub fn query_prepared(
  on statement: Statement,
  with params: List(Value),
  expecting decoder: Decoder(t),
) -> Result(List(t), Error) {
  use rows <- result.try(run_query_prepared(params, statement))
  use rows <- result.try(
    list.try_map(over: rows, with: fn(row) { decode.run(row, decoder) })
    |> result.map_error(decode_error),
  )
  Ok(rows)
}

pub fn finalize(statement: Statement) -> Result(Nil, Error) {
  finalize_(statement)
}

pub fn with_statement(
  sql: String,
  on connection: Connection,
  run f: fn(Statement) -> a,
) -> a {
  let assert Ok(statement) = prepare(sql, connection)
  let value = f(statement)
  let assert Ok(_) = finalize(statement)
  value
}

@external(erlang, "libsql_ffi", "query")
fn run_query(
  a: String,
  b: Connection,
  c: List(Value),
) -> Result(List(Dynamic), Error)

@external(erlang, "libsql_ffi", "query_named")
fn run_query_named(
  a: String,
  b: Connection,
  c: List(#(String, Value)),
) -> Result(List(Dynamic), Error)

@external(erlang, "libsql_ffi", "coerce_value")
fn coerce_value(a: a) -> Value

@external(erlang, "libsql_ffi", "exec")
fn exec_(a: String, b: Connection) -> Result(Nil, Error)

pub fn nullable(inner_type: fn(t) -> Value, value: Option(t)) -> Value {
  case value {
    Some(value) -> inner_type(value)
    None -> null()
  }
}

pub fn int(value: Int) -> Value {
  coerce_value(value)
}

pub fn float(value: Float) -> Value {
  coerce_value(value)
}

pub fn text(value: String) -> Value {
  coerce_value(value)
}

@external(erlang, "libsql_ffi", "coerce_blob")
fn coerce_blob(a: BitArray) -> Value

pub fn blob(value: BitArray) -> Value {
  coerce_blob(value)
}

pub fn bool(value: Bool) -> Value {
  int(case value {
    True -> 1
    False -> 0
  })
}

@external(erlang, "libsql_ffi", "null")
fn null_() -> Value

pub fn null() -> Value {
  null_()
}

pub fn decode_bool() -> Decoder(Bool) {
  use b <- decode.then(decode.int)

  case b {
    0 -> decode.success(False)
    _ -> decode.success(True)
  }
}

fn decode_error(errors: List(decode.DecodeError)) -> Error {
  let assert [decode.DecodeError(expected, actual, path), ..] = errors
  let path = string.join(path, ".")
  let message =
    "Decoder failed, expected "
    <> expected
    <> ", got "
    <> actual
    <> " in "
    <> path
  LibsqlError(code: GenericError, message: message, offset: -1)
}
