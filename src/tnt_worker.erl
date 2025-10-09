-module(tnt_worker).

-include_lib("kernel/include/logger.hrl").
-include("tnt.hrl").

-behaviour(gen_statem).

%% API
-export([
    start_link/1,
    stop/1,
    request/2
]).

%% gen_statem callbacks
-export([
    callback_mode/0,
    init/1
]).

-export([
    disconnected/3,
    connected/3
]).

-export_type([
    client/0,
    host/0,
    portnum/0,
    options/0,
    error_message/0
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

%% Records

-record(request, {
    ref   :: reference(),
    msg   :: tnt_proto:request(),
    owner :: pid(),
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
    sync = 1 :: tnt_proto:sync(),
    buffer = <<>> :: binary(),
    reconnect_policy :: tnt_retry:policy()
}).

%% Types

-type data() :: #data{}.
-type request() :: #request{}.

-type state() :: disconnected | connected.

-type maybe_strategy() :: mayhap(tnt_retry:strategy()).
-type connect_event() :: {connect, maybe_strategy()}.
-type timeout_event() :: connect.
-type internal_event() :: connect_event() | process_queue | {finish, timeout_event()}.

-type internal_event_action() :: {next_event, internal, internal_event()}.
-type timeout_action() :: {{timeout, timeout_event()}, timeout(), EventContent :: any()}.

-type error_message() :: {Code :: pos_integer(), Msg :: iodata()} | {unknown, tnt_proto:proto()}.

-type pending() :: queue:queue(request()).
-type holders() :: #{tnt_proto:sync() := request()}.
-type credits() :: {Username :: binary(), Password :: binary()}.
-type host() :: string() | atom() | inet:ip_address().
-type portnum() :: non_neg_integer().
-type client() :: pid().
-type mayhap(T) :: T | undefined.
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

-spec start_link(options()) -> gen_statem:start_ret().
start_link(Options) ->
    gen_statem:start_link(?MODULE, Options, []).

-spec stop(client()) -> ok.
stop(Client) ->
    gen_statem:stop(Client).

-spec request(client(), tnt_proto:request()) -> {ok, reference()}.
request(Client, Msg) ->
    Req = new_request(Msg, self()),
    ok = gen_statem:cast(Client, {request, Req}),
    {ok, Req#request.ref}.

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
    {keep_state, Data#data{socket = undefined}, Action};

disconnected(internal, {connect, Strategy}, #data{host = Host, port = Port} = Data) ->
    ?LOG_WARNING("Connecting to ~ts:~tp...", [Host, Port]),
    case gen_tcp:connect(Host, Port, [binary, {active, false}], Data#data.connect_timeout) of
        {ok, Socket} ->
            ?LOG_WARNING("Connection to ~ts:~tp is established", [Host, Port]),
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
            ?LOG_WARNING("Connection to ~ts:~tp failed with: ~ts", [
                Host, Port, inet:format_error(What)
            ]),
            Action = retry_action(connect, build_strategy(Strategy, Data)),
            {keep_state, Data, Action}
    end;

disconnected({timeout, connect}, Strategy, _Data) ->
    {keep_state_and_data, next_event_action({connect, Strategy})};

disconnected(info, {request_timeout, #request{ref = Ref, owner = Owner}}, _Data) ->
    Owner ! #tnt_error{ref = Ref, reason = timeout},
    keep_state_and_data;

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

connected(enter, disconnected, Data = #data{credits = Credits}) ->
    ?LOG_WARNING("Login as '~ts'", [credits_username(Credits)]),
    ok = inet:setopts(Data#data.socket, [{active, true}]),
    {keep_state, Data#data{sync = ?INITIAL_SYNC}};

connected(cast, {request, Req}, Data = #data{response_timeout = Timeout}) ->
    Request = create_req_timer(Req, Timeout),
    Queue = queue:in(Request, Data#data.pending),
    Action = next_event_action(process_queue),
    {keep_state, Data#data{pending = Queue}, Action};

connected(info, {tcp_closed, Socket}, Data = #data{socket = Socket}) ->
    ?LOG_WARNING("Connection is closed"),
    {next_state, disconnected, Data};

connected(info, {tcp, Socket, RxData}, #data{socket = Socket} = Data) ->
    ?LOG_WARNING("Rx(~p): ~p", [byte_size(RxData), RxData]),
    Bin = <<(Data#data.buffer)/binary, RxData/binary>>,
    case tnt_proto:decode(Bin) of
        incomplete ->
            {keep_state, Data#data{buffer = Bin}};
        {ok, {Code, Sync, _SchemaID, Body}, Tail} ->
            case maps:take(Sync, Data#data.holders) of
                {Req, HoldersUpd} ->
                    reply_answer(Code, Body, Req),
                    {keep_state, Data#data{buffer = Tail, holders = HoldersUpd}};
                error ->
                    ?LOG_ERROR("Failed to find owner by sync(~p). Reply: ~p", [Sync, Body]),
                    {keep_state, Data#data{buffer = Tail}}
            end;
        {error, Reason} ->
            ?LOG_ERROR("Decoding failed with: ~p", [Reason]),
            {keep_state, Data#data{buffer = <<>>}}
    end;

connected(info, {request_timeout, #request{ref = Ref, owner = Owner}}, _Data) ->
    Owner ! #tnt_error{ref = Ref, reason = timeout},
    keep_state_and_data;

connected(internal, process_queue, #data{sync = Sync, pending = Queue} = Data) ->
    case queue:out(Queue) of
        {empty, _} ->
            keep_state_and_data;

        {{value, Req = #request{msg = Msg, timer = Timer}}, Q} ->
            try
                TxData = tnt_proto:encode(Msg, Sync),
                case gen_tcp:send(Data#data.socket, TxData) of
                    ok ->
                        _ = erlang:cancel_timer(Timer),
                        Holders = Data#data.holders,
                        DataUpd = Data#data{
                            pending = Q,
                            holders = Holders#{Sync => Req#request{timer = undefined}},
                            sync = tnt_proto:next_sync(Sync)
                        },
                        {keep_state, DataUpd, next_event_action(process_queue)};

                    {error, Err} ->
                        ?LOG_ERROR("Failed(~tp) sending ~p", [Err, Msg]),
                        {next_state, disconnected, Data}
                end
            catch
                error:What:STrace ->
                    ?LOG_ERROR(
                        "Exception(~p) occured while encoding ~p. Stacktrace: ~p",
                        [What, Msg, STrace]
                    ),
                    %% SKIP-IT!!!
                    Action = next_event_action(process_queue),
                    {keep_state, Data#data{pending = Q}, Action}
            end
    end.

%%-- internals ----------------------------------------------------------------

-spec reply_answer(integer(), tnt_proto:proto(), request()) -> ok.
reply_answer(?IPROTO_OK, [{}], #request{ref = Ref, owner = Pid}) ->
    Pid ! #tnt_reply{ref = Ref, answer = ok};
%% IPROTO_DATA
reply_answer(?IPROTO_OK, [{16#30, Body}], #request{ref = Ref, msg = Msg, owner = Pid}) ->
    Val = case {Body, tnt_proto:get_request_type(Msg)} of
        {[V], Type} when Type =/= ?REQUEST_TYPE_SELECT ->
            V;
        {Else, _} ->
            Else
    end,
    Pid ! #tnt_reply{ref = Ref, answer = Val},
    ok;
reply_answer(Code, Body, #request{ref = Ref, owner = Pid}) ->
    Pid ! #tnt_error{ref = Ref, reason = get_error(Code, Body)},
    ok.

-spec get_error(pos_integer(), tnt_proto:proto()) -> error_message().
get_error(Code, Body) ->
    case proplists:get_value(16#31, Body, undefined) of %% IPOTO_ERROR_24
        undefined ->
            case proplists:get_value(16#52, Body, undefined) of %% IPROTO_ERROR
                [_ | _] = ErrBox ->
                    ErrCode = proplists:get_value(?MP_ERROR_ERRCODE, ErrBox, undefined),
                    ErrStr  = proplists:get_value(?MP_ERROR_MESSAGE, ErrBox, undefined),
                    {ErrCode, ErrStr};
                _ ->
                    {unknown, Body}
            end;
        Str ->
            {Code band (?IPROTO_TYPE_ERROR - 1), Str}
    end.

-spec handshake(gen_tcp:socket(), data()) -> {ok | error, data()}.
handshake(Socket, #data{response_timeout = Timeout} = Data) ->
    case gen_tcp:recv(Socket, ?IPROTO_GREETING_SIZE, Timeout) of
        {ok, <<Greeting:63/binary, $\n, SaltB64:44/binary, _/binary>>} ->
            ?LOG_WARNING("Greeting: ~p", [Greeting]),
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
            {ok, {?IPROTO_OK, _Sync, _SchemaID, [{}]}, Tail} -> %% [{}] = ok
                {ok, Data#data{
                    buffer = Tail,
                    sync = tnt_proto:next_sync(Sync)
                }};
            {ok, {Code, _Sync, _SchemaID, Body}, Tail} ->
                ?LOG_ERROR("Auth failed with: ~p", [get_error(Code, Body)]),
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

-spec send_sync_and_decode(Socket, TxData, Timeout) -> Result when
    Socket :: gen_tcp:socket(),
    TxData :: binary(),
    Timeout :: timeout(),
    Result :: {ok, tuple(), binary()} | {error, any()}.
send_sync_and_decode(Socket, TxData, Timeout) ->
    case gen_tcp:send(Socket, TxData) of
        ok ->
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, RxData} ->
                    tnt_proto:decode(RxData);
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

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

-spec new_request(tnt_proto:request(), pid()) -> request().
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

-spec build_strategy(maybe_strategy(), data()) -> tnt_retry:strategy().
build_strategy(undefined, #data{reconnect_policy = Policy}) ->
    tnt_retry:new(Policy);
build_strategy(Strategy, _) ->
    Strategy.

%%

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
