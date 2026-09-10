-module(libsql_ffi).

-export([
    open/1, open_remote/2, open_replica/3, open_synced_database/3, close/1,
    changes/1, total_changes/1, last_insert_rowid/1, interrupt/1,
    sync/1, replication_index/1,
    exec/2, exec_batch/3, query/3, query_named/3,
    prepare/2, exec_prepared/2, query_prepared/2, finalize/1,
    coerce_value/1, coerce_blob/1, null/0
]).

-export([
    open_nif/1, open_remote_nif/2, open_replica_nif/3, open_synced_database_nif/3, close_nif/1,
    changes_nif/1, total_changes_nif/1, last_insert_rowid_nif/1, interrupt_nif/1,
    sync_nif/1, replication_index_nif/1,
    exec_nif/2, exec_batch_nif/3, query_nif/3, query_named_nif/3,
    prepare_nif/2, exec_prepared_nif/2, query_prepared_nif/2, finalize_nif/1
]).

-on_load(init/0).

%% ── Crystalline local patch ─────────────────────────────────────────────
%% Vendored from libsql_gleam 0.1.0 (github.com/felstormrage/libsql-gleam,
%% commit 4f3d375d04aaf4696da1d3e1595a89e52aff29d8). Only the NIF loader is
%% changed; the NIF itself is still built from that pinned upstream commit by
%% scripts/build-libsql-nif.sh.
%%
%% Upstream bugs fixed here (both make the library unusable on OTP 26+):
%%   1. `code:priv_dir(libsql)` raised a function_clause, because the OTP
%%      application is named `libsql_gleam`, so the lookup returns
%%      `{error, bad_name}` and `filename:join/2` crashed inside `on_load`.
%%   2. `erlang:system_info(machine)` returns "BEAM", not a CPU architecture,
%%      so the platform tag degraded to "macos-unknown"/"linux-unknown" and
%%      the cache lookup missed the installed NIF.
%% ────────────────────────────────────────────────────────────────────────

%% Configuration for precompiled NIF downloads
-define(GITHUB_REPO, "yourusername/libsql-gleam").
-define(NIF_VERSION, "0.1.0").

init() ->
    %% Ensure inets is started for httpc
    case application:ensure_all_started(inets) of
        {ok, _} -> ok;
        _ -> ok
    end,
    PrivDir = priv_dir(),
    LocalSo = filename:join(PrivDir, "libsql_nif"),
    case erlang:load_nif(LocalSo, 0) of
        ok -> ok;
        _ -> load_precompiled_or_fail(PrivDir)
    end.

priv_dir() ->
    case code:priv_dir(libsql_gleam) of
        {error, _} ->
            case code:priv_dir(libsql) of
                {error, _} ->
                    filename:join([filename:dirname(code:which(?MODULE)), "..", "priv"]);
                Dir -> Dir
            end;
        Dir -> Dir
    end.

load_precompiled_or_fail(_PrivDir) ->
    case load_precompiled() of
        ok -> ok;
        _ ->
            {error,
                "Failed to load the libsql NIF. Build and install it with: "
                "bash scripts/build-libsql-nif.sh"}
    end.

load_precompiled() ->
    Platform = get_platform(),
    CacheDir = filename:basedir(user_cache, "libsql"),
    ok = filelib:ensure_dir(filename:join(CacheDir, ".")),
    SoFile = filename:join(CacheDir, "libsql_nif-" ++ ?NIF_VERSION ++ "-" ++ Platform),
    case filelib:is_file(SoFile) of
        true -> erlang:load_nif(SoFile, 0);
        false -> download_and_load(SoFile, Platform)
    end.

download_and_load(SoFile, Platform) ->
    AssetName = case Platform of
        "linux-x86_64" -> "libsql_nif-linux-x86_64.so";
        "macos-aarch64" -> "libsql_nif-macos-aarch64.dylib";
        "macos-x86_64" -> "libsql_nif-macos-x86_64.dylib";
        _ -> "unsupported"
    end,
    case AssetName of
        "unsupported" -> {error, unsupported_platform};
        _ ->
            Url = "https://github.com/" ++ ?GITHUB_REPO ++ "/releases/download/v" ++ ?NIF_VERSION ++ "/" ++ AssetName,
            case download(Url, SoFile) of
                ok -> erlang:load_nif(SoFile, 0);
                Error -> Error
            end
    end.

download(Url, Dest) ->
    case httpc:request(get, {Url, []}, [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            ok = filelib:ensure_dir(Dest),
            ok = file:write_file(Dest, Body),
            %% Make executable on Unix
            case os:type() of
                {unix, _} -> ok = file:change_mode(Dest, 8#755);
                _ -> ok
            end,
            ok;
        {ok, {{_, Status, _}, _, _}} ->
            {error, {http_error, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

get_platform() ->
    Os = case os:type() of
        {unix, linux} -> "linux";
        {unix, darwin} -> "macos";
        {win32, _} -> "windows";
        _ -> "unknown"
    end,
    %% `erlang:system_info(machine)` reports the VM ("BEAM"), not the CPU, so
    %% derive the architecture from `system_architecture` instead
    %% (e.g. "aarch64-apple-darwin25.6.0").
    Arch = case string:split(erlang:system_info(system_architecture), "-", leading) of
        ["x86_64" | _] -> "x86_64";
        ["amd64" | _] -> "x86_64";
        ["aarch64" | _] -> "aarch64";
        ["arm64" | _] -> "aarch64";
        ["i386" | _] -> "x86_64";
        ["i686" | _] -> "x86_64";
        _ -> "unknown"
    end,
    Os ++ "-" ++ Arch.

%% NIF stubs
open_nif(_Name) -> erlang:nif_error(nif_library_not_loaded).
open_remote_nif(_Url, _Token) -> erlang:nif_error(nif_library_not_loaded).
open_replica_nif(_Path, _Url, _Token) -> erlang:nif_error(nif_library_not_loaded).
open_synced_database_nif(_Path, _Url, _Token) -> erlang:nif_error(nif_library_not_loaded).
close_nif(_Connection) -> erlang:nif_error(nif_library_not_loaded).
changes_nif(_Connection) -> erlang:nif_error(nif_library_not_loaded).
total_changes_nif(_Connection) -> erlang:nif_error(nif_library_not_loaded).
last_insert_rowid_nif(_Connection) -> erlang:nif_error(nif_library_not_loaded).
interrupt_nif(_Connection) -> erlang:nif_error(nif_library_not_loaded).
sync_nif(_Connection) -> erlang:nif_error(nif_library_not_loaded).
replication_index_nif(_Connection) -> erlang:nif_error(nif_library_not_loaded).
exec_nif(_Sql, _Connection) -> erlang:nif_error(nif_library_not_loaded).
exec_batch_nif(_Sql, _Batches, _Connection) -> erlang:nif_error(nif_library_not_loaded).
query_nif(_Sql, _Arguments, _Connection) -> erlang:nif_error(nif_library_not_loaded).
query_named_nif(_Sql, _Arguments, _Connection) -> erlang:nif_error(nif_library_not_loaded).
prepare_nif(_Sql, _Connection) -> erlang:nif_error(nif_library_not_loaded).
exec_prepared_nif(_Arguments, _Statement) -> erlang:nif_error(nif_library_not_loaded).
query_prepared_nif(_Arguments, _Statement) -> erlang:nif_error(nif_library_not_loaded).
finalize_nif(_Statement) -> erlang:nif_error(nif_library_not_loaded).

open(Name) ->
    case open_nif(unicode:characters_to_binary(Name)) of
        {ok, Connection} -> {ok, Connection};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

open_remote(Url, Token) ->
    case open_remote_nif(unicode:characters_to_binary(Url), unicode:characters_to_binary(Token)) of
        {ok, Connection} -> {ok, Connection};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

open_replica(Path, Url, Token) ->
    case open_replica_nif(unicode:characters_to_binary(Path), unicode:characters_to_binary(Url), unicode:characters_to_binary(Token)) of
        {ok, Connection} -> {ok, Connection};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

open_synced_database(Path, Url, Token) ->
    case open_synced_database_nif(unicode:characters_to_binary(Path), unicode:characters_to_binary(Url), unicode:characters_to_binary(Token)) of
        {ok, Connection} -> {ok, Connection};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

close(Connection) ->
    case close_nif(Connection) of
        {ok, nil} -> {ok, nil};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

changes(Connection) ->
    case changes_nif(Connection) of
        {ok, Count} -> {ok, Count};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

total_changes(Connection) ->
    case total_changes_nif(Connection) of
        {ok, Count} -> {ok, Count};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

last_insert_rowid(Connection) ->
    case last_insert_rowid_nif(Connection) of
        {ok, Id} -> {ok, Id};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

interrupt(Connection) ->
    case interrupt_nif(Connection) of
        {ok, nil} -> {ok, nil};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

sync(Connection) ->
    case sync_nif(Connection) of
        {ok, {FrameNo, FramesSynced}} -> {ok, {FrameNo, FramesSynced}};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

replication_index(Connection) ->
    case replication_index_nif(Connection) of
        {ok, Index} -> {ok, Index};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

query(Sql, Connection, Arguments) when is_binary(Sql) ->
    case query_nif(Sql, Arguments, Connection) of
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}};
        {ok, Rows} ->
            {ok, lists:map(fun erlang:list_to_tuple/1, Rows)}
    end.

query_named(Sql, Connection, Arguments) when is_binary(Sql) ->
    case query_named_nif(Sql, Arguments, Connection) of
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}};
        {ok, Rows} ->
            {ok, lists:map(fun erlang:list_to_tuple/1, Rows)}
    end.

exec(Sql, Connection) when is_binary(Sql) ->
    case exec_nif(Sql, Connection) of
        {ok, nil} -> {ok, nil};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

exec_batch(Sql, Connection, Batches) when is_binary(Sql) ->
    case exec_batch_nif(Sql, Batches, Connection) of
        {ok, nil} -> {ok, nil};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

prepare(Sql, Connection) when is_binary(Sql) ->
    case prepare_nif(Sql, Connection) of
        {ok, Statement} -> {ok, Statement};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

exec_prepared(Arguments, Statement) ->
    case exec_prepared_nif(Arguments, Statement) of
        {ok, nil} -> {ok, nil};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

query_prepared(Arguments, Statement) ->
    case query_prepared_nif(Arguments, Statement) of
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}};
        {ok, Rows} ->
            {ok, lists:map(fun erlang:list_to_tuple/1, Rows)}
    end.

finalize(Statement) ->
    case finalize_nif(Statement) of
        {ok, nil} -> {ok, nil};
        {error, {libsql_error, Code, Message, Offset}} ->
            {error, {libsql_error, libsql:error_code_from_int(Code), Message, Offset}}
    end.

coerce_value(X) -> X.
coerce_blob(Bin) -> {blob, Bin}.
null() -> undefined.
