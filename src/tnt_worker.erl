-module(tnt_worker).

-include_lib("kernel/include/logger.hrl").
-include("tnt.hrl").

-behaviour(gen_statem).

%% API
-export([
    start/2,
    stop/1,
    request/2,
    request_sync/2
]).

%% gen_statem callbacks
-export([
    callback_mode/0,
    init/1,
    terminate/3
]).

-export([
    disconnected/3,
    connected/3
]).

-export_type([
    client/0,
    host/0,
    portnum/0,
    options/0
]).

%%-- Macros and Types ---------------------------------------------------------

%% Constants
-define(NOW, 0).
-define(DEFAULT_PORT, 3301).
-define(DEFAULT_TIMEOUT, 5000).
-define(FIRST_RECONNECT_INT, 100).
-define(MAX_RECONNECT_INT, 30000).
-define(DEFAULT_RECONNECT_POLICY, {
    infinity, {exponential, ?FIRST_RECONNECT_INT, ?MAX_RECONNECT_INT}
}).
-define(TCP_OPTS, [
    binary,
    {active, false},
    {packet, raw},
    {keepalive, true},
    {nodelay, true},
    {delay_send, false},
    {buffer, 16#010000}
]).

%% Records

-record(request, {
    ref   :: reference(),
    msg   :: tnt_proto:request(),
    owner :: mayhap(pid() | {call, gen_statem:from()}),
    timer :: mayhap(reference())
}).

-record(data, {
    host :: host(),
    port :: portnum(),
    credits :: mayhap(credits()),
    pending :: pending(),
    connect_timeout :: timeout(),
    response_timeout :: timeout(),
    socket :: mayhap(gen_tcp:socket()),
    holders = maps:new() :: holders(),
    sync = ?INITIAL_SYNC :: tnt_proto:sync(),
    buffer = <<>> :: binary(),
    reconnect_policy :: tnt_retry:policy()
}).

%% Types

-type linkage() :: monitor | link | nolink.

-type data() :: #data{}.
-type request() :: #request{}.

-type state() :: disconnected | connected.

-type maybe_strategy() :: mayhap(tnt_retry:strategy()).
-type connect_event() :: {connect, maybe_strategy()}.
-type timeout_event() :: connect.
-type internal_event() :: connect_event() | process_queue | {finish, timeout_event()}.

-type reply_action() :: {reply, gen_statem:from(), Reply :: any()}.
-type internal_event_action() :: {next_event, internal, internal_event()}.
-type timeout_action() :: {{timeout, timeout_event()}, timeout(), EventContent :: any()}.

-type pending() :: queue:queue(request()).
-type holders() :: #{tnt_proto:sync() := request()}.
-type credits() :: {Username :: binary(), Password :: binary()}.
-type host() :: string() | atom() | inet:ip_address().
-type portnum() :: non_neg_integer().
-type client() :: pid().
-type mayhap(T) :: T | undefined.
-type decode_result() :: {ok, tuple(), binary()} | {error, any()}.
-type options() :: [
    {host, host()} |
    {port, portnum()} |
    {username, binary()} |
    {password, binary()} |
    {connect_timeout, timeout()} |
    {response_timeout, timeout()} |
    {reconnect_policy, tnt_retry:policy()}
].

%%-- API ----------------------------------------------------------------------

-spec start(linkage(), options()) -> gen_statem:start_ret().
start(link, Options) ->
    gen_statem:start_link(?MODULE, Options, []);
start(monitor, Options) ->
    gen_statem:start_monitor(?MODULE, Options, []);
start(nolink, Options) ->
    gen_statem:start(?MODULE, Options, []).

-spec stop(client()) -> ok.
stop(Client) ->
    gen_statem:stop(Client).

-spec request(client(), tnt_proto:request()) -> {ok, reference()}.
request(Client, Msg) ->
    Req = new_request(Msg, self()),
    ok = gen_statem:cast(Client, {request, Req}),
    {ok, Req#request.ref}.

-spec request_sync(client(), tnt_proto:request()) -> {ok | error, any()}.
request_sync(Client, Msg) ->
    Req = new_request(Msg, undefined),
    gen_statem:call(Client, {request, Req}).

%%-- gen_statem callbacks -----------------------------------------------------

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() ->
    [state_functions, state_enter].

-spec init(options()) -> gen_statem:init_result(state(), data()).
init(Options) ->
    Host            = proplists:get_value(host, Options, "localhost"),
    Port            = proplists:get_value(port, Options, ?DEFAULT_PORT),
    Username        = proplists:get_value(username, Options, undefined),
    Password        = proplists:get_value(password, Options, <<>>),
    ConnectTimeout  = proplists:get_value(connect_timeout, Options, ?DEFAULT_TIMEOUT),
    ResponseTimeout = proplists:get_value(response_timeout, Options, ?DEFAULT_TIMEOUT),
    ReconnectPolicy = proplists:get_value(reconnect_policy, Options, ?DEFAULT_RECONNECT_POLICY),
    Data = #data{
        host = Host,
        port = Port,
        credits = credits_build(Username, Password),
        connect_timeout = ConnectTimeout,
        response_timeout = ResponseTimeout,
        pending = queue:new(),
        reconnect_policy = ReconnectPolicy
    },
    {ok, disconnected, Data}.

-spec terminate(any(), state(), data()) -> ok.
terminate(Reason, State, Data) ->
    ?LOG_DEBUG("stopped with: ~p, state: ~p, data: ~p", [Reason, State, Data]),
    ok.

%%-- Disconnected state -------------------------------------------------------

-spec disconnected
    (enter, state(), data()) ->
        keep_state_and_data |
        {keep_state, data(), internal_event_action()};
    (internal, connect_event(), data()) ->
        {keep_state, data(), timeout_action()} |
        {next_state, state(), data()};
    ({timeout, connect}, tnt_retry:strategy(), data()) ->
        {keep_state_and_data, timeout_action()};
    (info, any(), data()) ->
        {keep_state, data()};
    (cast, {request, request()}, data()) ->
        {keep_state, data()}.

disconnected(enter, disconnected, _Data) ->
    {keep_state_and_data, timeout_action(connect, ?NOW)};

disconnected(enter, connected, Data = #data{host = Host, port = Port, socket = Socket}) ->
    ?LOG_WARNING("Connection to ~ts:~tp closed! Reconnecting...", [Host, Port]),
    ok = gen_tcp:close(Socket),
    Action = timeout_action(connect, ?NOW),
    DataUpd = Data#data{
        socket = undefined,
        holders = maps:new(),
        sync = ?INITIAL_SYNC
    },
    {keep_state, DataUpd, Action};

disconnected(internal, {connect, Strategy}, #data{host = Host, port = Port} = Data) ->
    ?LOG_DEBUG("Connecting to ~ts:~tp...", [Host, Port]),
    case gen_tcp:connect(Host, Port, ?TCP_OPTS, Data#data.connect_timeout) of
        {ok, Socket} ->
            ?LOG_INFO("Connection to ~ts:~tp is established", [Host, Port]),
            case handshake(Socket, Data) of
                {ok, DataUpd} ->
                    {next_state, connected, DataUpd#data{
                        socket = Socket
                    }};
                {error, DataUpd} ->
                    Action = retry_action(connect, build_strategy(Strategy, DataUpd)),
                    {keep_state, DataUpd, Action}
            end;
        {error, What} ->
            ?LOG_ERROR("Failed to connect to ~ts:~tp with: ~ts", [
                Host, Port, inet:format_error(What)
            ]),
            Action = retry_action(connect, build_strategy(Strategy, Data)),
            {keep_state, Data, Action}
    end;

disconnected(internal, {finish, connect}, _Data) ->
    {stop, normal};

disconnected({timeout, connect}, Strategy, _Data) ->
    {keep_state_and_data, next_event_action({connect, Strategy})};

disconnected(info, {request_timeout, Req = #request{ref = Ref}}, Data) ->
    ?LOG_ERROR("Timeout(~p)", [Ref]),
    ok = reply(Req, {error, timeout}),
    Queue = queue:delete(Req, Data#data.pending),
    {keep_state, Data#data{pending = Queue}};

disconnected({call, From}, {request, _}, _Data) ->
    {keep_state_and_data, reply_action(From, {error, ?FUNCTION_NAME})};

disconnected(cast, {request, Req}, Data = #data{response_timeout = Timeout}) ->
    Request = create_req_timer(Req, Timeout),
    Queue = queue:in(Request, Data#data.pending),
    {keep_state, Data#data{pending = Queue}}.

%%-- Connected state ----------------------------------------------------------

-spec connected
    (enter, state(), data()) -> keep_state_and_data;
    (cast, {request, request()}, data()) -> {keep_state, data(), [gen_statem:action()]};
    (info, {tcp_closed, gen_tcp:socket()}, data()) -> {next_state, state(), data()};
    (info, {tcp, gen_tcp:socket(), binary()}, data()) -> keep_state_and_data;
    (internal, process_queue, data()) ->
        keep_state_and_data |
        {keep_state, data(), [gen_statem:action()]} |
        {next_state, state(), data()}.

connected(enter, disconnected, #data{credits = Credits}) ->
    ?LOG_INFO("Login as '~ts'", [credits_username(Credits)]),
    keep_state_and_data;

connected({call, _} = Owner, {request, Req}, Data = #data{response_timeout = Timeout}) ->
    Request = create_req_timer(Req#request{owner = Owner}, Timeout),
    Queue = queue:in(Request, Data#data.pending),
    Action = next_event_action(process_queue),
    {keep_state, Data#data{pending = Queue}, Action};

connected(cast, {request, Req}, Data = #data{response_timeout = Timeout}) ->
    Request = create_req_timer(Req, Timeout),
    Queue = queue:in(Request, Data#data.pending),
    Action = next_event_action(process_queue),
    {keep_state, Data#data{pending = Queue}, Action};

connected(info, {tcp_closed, Socket}, Data = #data{socket = Socket}) ->
    ?LOG_DEBUG("Connection is closed"),
    {next_state, disconnected, Data};

connected(info, {tcp, Socket, RxData}, #data{socket = Socket} = Data) ->
    Bin = <<(Data#data.buffer)/binary, RxData/binary>>,
    Res = case tnt_proto:decode(Bin) of
        {wait, Sz} ->
            ?LOG_DEBUG("Rx(~tp); incomplete (expected: ~tp bytes)",
                [byte_size(RxData), Sz]
            ),
            recv_and_decode(Socket, Sz, Bin, Data#data.response_timeout);
        Else ->
            Else
    end,
    DataUpd = handle_response(Res, Data),
    Action = next_event_action(process_queue),
    {keep_state, DataUpd, Action};

connected(info, {request_timeout, Req = #request{ref = Ref}}, Data) ->
    ?LOG_ERROR("Timeout(~p)", [Ref]),
    ok = reply(Req, {error, timeout}),
    HoldersUpd = purge_holders(Ref, Data#data.holders),
    Queue = queue:delete(Req, Data#data.pending),
    {keep_state, Data#data{
        holders = HoldersUpd,
        pending = Queue
    }};

connected(internal, process_queue, #data{sync = Sync, pending = Queue} = Data) ->
    case queue:out(Queue) of
        {empty, _} ->
            keep_state_and_data;

        {{value, Req = #request{msg = Msg, timer = Timer, ref = Ref}}, Q} ->
            TxData = tnt_proto:encode(Msg, Sync),
            Socket = Data#data.socket,
            case gen_tcp:send(Socket, TxData) of
                ok ->
                    _ = erlang:cancel_timer(Timer),
                    Holders = Data#data.holders,
                    DataUpd = Data#data{
                        pending = Q,
                        holders = Holders#{Sync => Req#request{timer = undefined}},
                        sync = tnt_proto:next_sync(Sync)
                    },
                    ok = inet:setopts(Socket, [{active, once}]),
                    {keep_state, DataUpd};

                {error, Err} ->
                    ?LOG_ERROR("Failed to send(~tp) ~tp:~p with ~p", [
                        Sync, tnt_proto:get_request_type(Msg), Ref, Err
                    ]),
                    {next_state, disconnected, Data}
            end
    end.

%%-- internals ----------------------------------------------------------------

-spec reply(integer(), tnt_proto:proto(), request()) -> ok.
reply(?IPROTO_OK, Body, Req) ->
    Type = tnt_proto:get_request_type(Req#request.msg),
    Reply = {ok, tnt_proto:make_reply_ok(Type, Body)},
    reply(Req, Reply);
reply(Code, Body, Req) ->
    Reply = {error, tnt_proto:get_error(Code, Body)},
    reply(Req, Reply).

-spec reply(request(), {ok | error, any()}) -> ok.
reply(#request{ref = Ref, owner = Pid}, Answer) when is_pid(Pid) ->
    Pid ! #tnt_reply{ref = Ref, answer = Answer},
    ok;
reply(#request{owner = {call, From}}, Answer) ->
    gen_statem:reply(From, Answer).

%%

-spec handshake(gen_tcp:socket(), data()) -> {ok | error, data()}.
handshake(Socket, #data{response_timeout = Timeout} = Data) ->
    case gen_tcp:recv(Socket, ?IPROTO_GREETING_SIZE, Timeout) of
        {ok, <<Greeting:63/binary, $\n, SaltB64:44/binary, _/binary>>} ->
            ?LOG_DEBUG("Greeting: ~p", [Greeting]),
            maybe_introduce(Socket, Data, base64:decode(SaltB64));
        {ok, Unknown} when is_binary(Unknown) ->
            ?LOG_ERROR("Unexpected greeting: ~p", [Unknown]),
            {error, Data};
        {error, Reason} ->
            ?LOG_ERROR("Error: ~p", [Reason]),
            {error, Data}
    end.

-spec maybe_introduce(gen_tcp:socket(), data(), binary()) -> {ok | error, data()}.
maybe_introduce(Socket, Data = #data{credits = {User, Pwd}}, Salt) ->
    #data{response_timeout = Timeout, sync = Sync} = Data,
    try
        AuthReq = tnt_proto:request_auth(User, Pwd, Salt),
        TxData = tnt_proto:encode(AuthReq, Sync),
        case send_sync_and_decode(Socket, TxData, Timeout) of
            {ok, {?IPROTO_OK, _Sync, _SchemaID, ?IPROTO_BODY_OK}, Tail} ->
                {ok, Data#data{
                    buffer = Tail,
                    sync = tnt_proto:next_sync(Sync)
                }};
            {ok, {Code, _Sync, _SchemaID, Body}, Tail} ->
                ?LOG_ERROR("Auth failed with: ~p", [tnt_proto:get_error(Code, Body)]),
                {error, Data#data{
                    buffer = Tail
                }};
            {error, Reason} ->
                ?LOG_ERROR("Error: ~p", [Reason]),
                {error, Data}
        end
    catch
        error:What:STrace ->
            ?LOG_ERROR("Exception(~p) occured. Stacktrace: ~p", [What, STrace]),
            {error, Data}
    end;
maybe_introduce(_, Data, _) ->
    {ok, Data#data{
        buffer = <<>>
    }}.

-spec handle_response(decode_result(), data()) -> data().
handle_response({ok, {Code, Sync, _SchemaID, Body}, Tail}, Data) ->
    case maps:take(Sync, Data#data.holders) of
        {Req, HoldersUpd} ->
            reply(Code, Body, Req),
            Data#data{buffer = Tail, holders = HoldersUpd};
        error ->
            ?LOG_ERROR("Failed to find owner by sync(~p)", [Sync]),
            Data#data{buffer = Tail}
    end;
handle_response({error, Reason}, Data) ->
    ?LOG_ERROR("Failed to decode with: ~p", [Reason]),
    Data#data{buffer = <<>>}.

%%

-spec send_sync_and_decode(Socket, TxData, Timeout) -> Result when
    Socket :: gen_tcp:socket(),
    TxData :: binary(),
    Timeout :: timeout(),
    Result :: decode_result().
send_sync_and_decode(Socket, TxData, Timeout) ->
    case gen_tcp:send(Socket, TxData) of
        ok ->
            recv_and_decode(Socket, 0, <<>>, Timeout);
        {error, _} = Err ->
            Err
    end.

-spec recv_and_decode(Socket, Size, Bin, Timeout) -> Result when
    Socket :: gen_tcp:socket(),
    Size :: non_neg_integer(),
    Bin :: binary(),
    Timeout :: timeout(),
    Result :: decode_result().
recv_and_decode(Socket, Size, Bin, Timeout) ->
    case gen_tcp:recv(Socket, Size, Timeout) of
        {ok, RxData} ->
            ?LOG_DEBUG("Rx(~p)", [byte_size(RxData)]),
            Acc = <<Bin/binary, RxData/binary>>,
            case tnt_proto:decode(Acc) of
                {wait, _} ->
                    recv_and_decode(Socket, Size, Acc, Timeout);
                Else ->
                    Else
            end;
        {error, _} = Err ->
            Err
    end.

%%

-spec credits_build(mayhap(binary()), mayhap(binary())) -> mayhap(credits()).
credits_build(User, Pwd) when is_binary(User), is_binary(Pwd) ->
    {User, Pwd};
credits_build(_, _) ->
    undefined.

-spec credits_username(mayhap(credits())) -> binary().
credits_username(undefined) ->
    <<"guest">>;
credits_username({Username, _}) ->
    Username.

%%

-spec new_request(tnt_proto:request(), mayhap(pid())) -> request().
new_request(Msg, Owner) ->
    #request{
        ref = make_ref(),
        msg = Msg,
        owner = Owner
    }.

-spec create_req_timer(request(), timeout()) -> request().
create_req_timer(Req, infinity) ->
    Req;
create_req_timer(Req, Msecs) ->
    Req#request{
        timer = erlang:send_after(Msecs, self(), {request_timeout, Req})
    }.

%%

-spec purge_holders(reference(), holders()) -> holders().
purge_holders(In, Holders) ->
    Pred = fun (_Key, #request{ref = Ref}) ->
        Ref =:= In
    end,
    maps:filter(Pred, Holders).

%%

-spec build_strategy(maybe_strategy(), data()) -> tnt_retry:strategy().
build_strategy(undefined, #data{reconnect_policy = Policy}) ->
    tnt_retry:new(Policy);
build_strategy(Strategy, _) ->
    Strategy.

%%

-spec reply_action(gen_statem:from(), any()) -> reply_action().
reply_action(To, Msg) ->
    {reply, To, Msg}.

-spec retry_action(timeout_event(), tnt_retry:strategy()) -> Action when
    Action :: timeout_action() | internal_event_action().
retry_action(Event, S0) ->
    case tnt_retry:next(S0) of
        {wait, Timeout, SUpd} ->
            timeout_action(Event, Timeout, SUpd);

        finish ->
            next_event_action({finish, Event})
    end.

-spec next_event_action(internal_event()) -> internal_event_action().
next_event_action(Event) ->
    {next_event, internal, Event}.

-spec timeout_action(timeout_event(), timeout(), any()) -> timeout_action().
timeout_action(Event, Timeout, Content) ->
    {{timeout, Event}, Timeout, Content}.

-spec timeout_action(timeout_event(), timeout()) -> timeout_action().
timeout_action(Event, Timeout) ->
    timeout_action(Event, Timeout, undefined).
