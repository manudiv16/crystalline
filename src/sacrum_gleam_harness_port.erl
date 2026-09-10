%% @private
%% Native bridge for the agent harness adapters (C9).
%%
%% Gleam >= 1.14 represents `String` as UTF-8 binaries on the Erlang target,
%% while most `os` functions expect (or return) charlists, so every call in
%% this module converts at the boundary. All functions return binaries, which
%% Gleam treats as `String`.
%%
%% `spawn_and_collect/4` spawns an executable through an Erlang port:
%%   - `binary` + `use_stdio` + `stderr_to_stdout` so stdout/stderr are merged
%%     into binary chunks,
%%   - `exit_status` so we observe the process exit code,
%%   - a hard wall-clock `after` budget, returning `timeout` when exceeded.
%%
%% The `claude` CLI has no `--cwd` flag, so a non-empty working directory is
%% applied by wrapping the spawn in `/bin/sh -c 'cd "$1"; shift; exec "$@"'`.
%% The directory and command travel as positional parameters (never string
%% interpolation), so there is no shell injection surface. When `Cwd` is the
%% empty string the executable is spawned directly.
%%
%% The outcome is returned to Gleam as a small JSON object:
%%   {"ok":true,"status":0,"output":"<escaped>"}        -> done, exit status
%%   {"ok":false,"reason":"not_found"}                  -> binary missing
%%   {"ok":false,"reason":"timeout"}                    -> budget exceeded
%%   {"ok":false,"reason":"spawn_failed"}               -> port died early

-module(sacrum_gleam_harness_port).
-export([spawn_and_collect/4, find_executable/1, getenv_or/2, putenv/2]).

-spec spawn_and_collect(binary(), binary(), [binary()], integer()) -> binary().
spawn_and_collect(Cwd0, Exe0, Args0, TimeoutMs) ->
    Cwd = binary_to_list(Cwd0),
    Exe = binary_to_list(Exe0),
    Args = [binary_to_list(A) || A <- Args0],
    case os:find_executable(Exe) of
        false ->
            enc_reason(<<"not_found">>);
        Path ->
            Port =
                case Cwd of
                    "" ->
                        open_port({spawn_executable, Path}, base_opts(Args));
                    _ ->
                        ShellArgs =
                            ["-c", "cd \"$1\"; shift; exec \"$@\"",
                             "sacrum-harness", Cwd, Path] ++
                                Args,
                        open_port(
                            {spawn_executable, "/bin/sh"},
                            base_opts(ShellArgs)
                        )
                end,
            case catch collect(Port, [], TimeoutMs) of
                {ok, Status, Output} ->
                    enc_ok(Status, Output);
                timeout ->
                    catch port_close(Port),
                    enc_reason(<<"timeout">>);
                _ ->
                    catch port_close(Port),
                    enc_reason(<<"spawn_failed">>)
            end
    end.

base_opts(Args) ->
    [{args, Args}, binary, use_stdio, stderr_to_stdout, exit_status].

collect(Port, Acc, TimeoutMs) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Data | Acc], TimeoutMs);
        {Port, {exit_status, Status}} ->
            {ok, Status, iolist_to_binary(lists:reverse(Acc))};
        {'EXIT', Port, _Reason} ->
            {error, exit}
    after TimeoutMs ->
        timeout
    end.

-spec find_executable(binary()) -> binary().
find_executable(Exe0) ->
    case os:find_executable(binary_to_list(Exe0)) of
        false -> <<"0">>;
        _ -> <<"1">>
    end.

-spec getenv_or(binary(), binary()) -> binary().
getenv_or(Name0, Default) ->
    case os:getenv(binary_to_list(Name0)) of
        false ->
            Default;
        Value ->
            to_bin(Value, Default)
    end.

-spec putenv(binary(), binary()) -> binary().
putenv(Name0, Value0) ->
    true = os:putenv(binary_to_list(Name0), binary_to_list(Value0)),
    <<"1">>.

%% ─── Encoding helpers ────────────────────────────────────────────────────

enc_ok(Status, Output) ->
    iolist_to_binary([
        <<"{\"ok\":true,\"status\":">>,
        integer_to_binary(Status),
        <<",\"output\":\"">>,
        escape(Output),
        <<"\"}">>
    ]).

enc_reason(Reason) ->
    iolist_to_binary([
        <<"{\"ok\":false,\"reason\":\"">>, Reason, <<"\"}">>
    ]).

%% Keep only valid UTF-8. When the stream contains stray bytes (ANSI escapes
%% and printable ASCII always survive) the string stays parseable as JSON
%% instead of crashing the decoder.
sanitize(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Valid when is_binary(Valid) -> Valid;
        _ -> << <<C>> || <<C>> <= Bin, C < 128 >>
    end.

escape(Bin) ->
    iolist_to_binary([esc(C) || <<C>> <= sanitize(Bin)]).

esc($\\ ) -> <<"\\\\">>;
esc($" ) -> <<"\\\"">>;
esc($\n) -> <<"\\n">>;
esc($\r) -> <<"\\r">>;
esc($\t) -> <<"\\t">>;
esc(C) when C < 32 ->
    <<"\\u", (hex4(C))/binary>>;
esc(C) ->
    <<C>>.

hex4(C) ->
    Hex = integer_to_binary(C, 16),
    Pad = 4 - byte_size(Hex),
    PadBytes = binary:copy(<<"0">>, Pad),
    <<PadBytes/binary, Hex/binary>>.

%% ─── Conversions ─────────────────────────────────────────────────────────

to_bin(Chars, _Default) when is_list(Chars) ->
    case unicode:characters_to_binary(Chars) of
        Bin when is_binary(Bin) -> Bin;
        _ -> _Default
    end.
