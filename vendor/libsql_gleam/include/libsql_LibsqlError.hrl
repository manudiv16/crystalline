-record(libsql_error, {
    code :: libsql:error_code(),
    message :: binary(),
    offset :: integer()
}).
