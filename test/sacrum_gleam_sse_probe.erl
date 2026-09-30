%% Minimal socket probe used by the execution-stream tests.
%%
%% The suite otherwise drives HTTP through `wisp/simulate`; a Server-Sent
%% Events stream cannot be exercised that way, so this module gives a test a
%% real socket against a real Mist listener. Everything is bounded: each read
%% takes an explicit timeout and returns whatever has arrived, and no function
%% blocks forever.
-module(sacrum_gleam_sse_probe).

-export([
    free_port/0,
    open/3,
    request/5,
    recv_until/3,
    recv_until_closed/2,
    close/1
]).

%% Reserve a loopback port by binding to port 0 and releasing it.
free_port() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}}, {active, false}]),
    {ok, Port} = inet:port(Listen),
    ok = gen_tcp:close(Listen),
    Port.

%% Open a streaming GET and return the socket. `Headers` is a raw header block
%% (each line ending in CRLF) or the empty binary.
open(Port, Path, Headers) ->
    {ok, Socket} = gen_tcp:connect(
        {127, 0, 0, 1},
        Port,
        [binary, {active, false}, {packet, raw}],
        2000
    ),
    ok = gen_tcp:send(Socket, [
        <<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
        <<"Host: 127.0.0.1\r\n">>,
        <<"Accept: text/event-stream\r\n">>,
        <<"Connection: keep-alive\r\n">>,
        Headers,
        <<"\r\n">>
    ]),
    Socket.

%% Send a one-shot request and read until the server closes the connection (or
%% the timeout expires), returning the raw response bytes.
request(Port, Method, Path, Headers, Body) ->
    {ok, Socket} = gen_tcp:connect(
        {127, 0, 0, 1},
        Port,
        [binary, {active, false}, {packet, raw}],
        2000
    ),
    ok = gen_tcp:send(Socket, [
        Method, <<" ">>, Path, <<" HTTP/1.1\r\n">>,
        <<"Host: 127.0.0.1\r\n">>,
        <<"Connection: close\r\n">>,
        Headers,
        <<"Content-Length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n\r\n">>,
        Body
    ]),
    Data = read_response(Socket, 3000, <<>>),
    ok = gen_tcp:close(Socket),
    Data.

%% Read a one-shot response: return as soon as the body promised by
%% content-length has arrived, otherwise fall back to the timeout. This keeps
%% the suite fast because Mist ignores a client's `connection: close` and holds
%% the keep-alive socket open.
read_response(Socket, TimeoutMs, Acc) ->
    case response_complete(Acc) of
        true ->
            Acc;
        false ->
            case gen_tcp:recv(Socket, 0, TimeoutMs) of
                {ok, Data} ->
                    read_response(Socket, TimeoutMs, <<Acc/binary, Data/binary>>);
                {error, _Reason} ->
                    Acc
            end
    end.

response_complete(Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Body] ->
            case content_length(Head) of
                undefined -> false;
                Length -> byte_size(Body) >= Length
            end;
        [_Head] ->
            false
    end.

content_length(Head) ->
    content_length_of(binary:split(Head, <<"\r\n">>, [global])).

content_length_of([]) ->
    undefined;
content_length_of([Line | Rest]) ->
    case binary:split(string:lowercase(Line), <<":">>) of
        [<<"content-length">>, Value] -> binary_to_integer(string:trim(Value));
        _ -> content_length_of(Rest)
    end.

%% Read until `Needle` appears, the peer closes, or the timeout expires. The
%% accumulated bytes are returned either way, so a failing assertion can show
%% what the stream actually sent.
recv_until(Socket, Needle, TimeoutMs) ->
    recv_until(Socket, Needle, TimeoutMs, <<>>).

recv_until(Socket, Needle, TimeoutMs, Acc) ->
    case binary:match(Acc, Needle) of
        {_, _} ->
            Acc;
        nomatch ->
            case gen_tcp:recv(Socket, 0, TimeoutMs) of
                {ok, Data} ->
                    recv_until(Socket, Needle, TimeoutMs, <<Acc/binary, Data/binary>>);
                {error, _Reason} ->
                    Acc
            end
    end.

%% Read until the peer closes the connection, returning the bytes read and
%% whether the close was observed (as opposed to the timeout expiring).
recv_until_closed(Socket, TimeoutMs) ->
    recv_until_closed(Socket, TimeoutMs, <<>>).

recv_until_closed(Socket, TimeoutMs, Acc) ->
    case gen_tcp:recv(Socket, 0, TimeoutMs) of
        {ok, Data} ->
            recv_until_closed(Socket, TimeoutMs, <<Acc/binary, Data/binary>>);
        {error, closed} ->
            {Acc, true};
        {error, _Reason} ->
            {Acc, false}
    end.

close(Socket) ->
    gen_tcp:close(Socket).
