-module(tnt).

-include("tnt.hrl").

%% API
-export([
    connect/0,
    connect/1,
    connect/2,
    close/1
]).

%% async requests
-export([
    select/3,
    select/4,
    insert/3,
    replace/3,
    upsert/4,
    update/4,
    update/5,
    delete/3,
    delete/4,
    call/2,
    call/3,
    eval/2,
    eval/3,
    ping/1
]).

%% sync requests
-export([
    select_sync/3,
    select_sync/4,
    insert_sync/3,
    replace_sync/3,
    upsert_sync/4,
    update_sync/4,
    update_sync/5,
    delete_sync/3,
    delete_sync/4,
    call_sync/2,
    call_sync/3,
    eval_sync/2,
    eval_sync/3,
    ping_sync/1
]).

%% misc
-export([
    get_space_id/2
]).


%% helpers
-export([
    wait/2
]).

-export_type([
    client/0,
    options/0,
    space_id/0,
    params/0,
    key/0,
    tnt_tuple/0,
    operation/0
]).

%%-- Macros -------------------------------------------------------------------

-define(DEFAULT_SYNC_TIMEOUT, 5_000).

%%-- Types --------------------------------------------------------------------

-type options() :: tnt_worker:options().
-type host() :: tnt_worker:host().
-type portnum() :: tnt_worker:portnum().
-type client() :: tnt_worker:client().
-type result(Expected) :: Expected | {error, term()}.
-type space_id() :: tnt_proto:space_id().
-type tnt_tuple() :: tnt_proto:tnt_tuple().
-type key() :: tnt_proto:key().
-type operation() :: tnt_proto:operation().
-type ops() :: list(operation()).
-type params() :: #{
    index_id => non_neg_integer(),
    iterator => non_neg_integer(),
    limit => pos_integer(),
    offset => non_neg_integer()
}.

%%-- API ----------------------------------------------------------------------

-spec connect() -> result({ok, client()}).
connect() ->
    connect([]).

-spec connect(options()) -> result({ok, client()}).
connect(Options) ->
    tnt_worker:start_link(Options).

-spec connect(host(), portnum()) -> result({ok, client()}).
connect(Host, Port) ->
    connect([{host, Host}, {port, Port}]).

-spec close(client()) -> ok.
close(Client) ->
    tnt_worker:stop(Client).

%%-- async requests -----------------------------------------------------------

-spec select(client(), space_id(), key()) -> {ok, reference()}.
select(Client, SpaceID, Key) ->
    select(Client, SpaceID, Key, #{}).

-spec select(client(), space_id(), key(), params()) -> {ok, reference()}.
select(Client, SpaceID, Key, Params) ->
    IndexID = maps:get(index_id, Params, 0),
    Iter = maps:get(iterator, Params, ?ITERATOR_EQ),
    Lim = maps:get(limit, Params, ?SELECT_LIMIT),
    Offs = maps:get(offset, Params, 0),
    Req = tnt_proto:request_select(SpaceID, IndexID, Key, Iter, Lim, Offs),
    tnt_worker:request(Client, Req).

-spec insert(client(), space_id(), tnt_tuple()) -> {ok, reference()}.
insert(Client, SpaceID, Data) ->
    Req = tnt_proto:request_insert(SpaceID, Data),
    tnt_worker:request(Client, Req).

-spec replace(client(), space_id(), tnt_tuple()) -> {ok, reference()}.
replace(Client, SpaceID, Data) ->
    Req = tnt_proto:request_replace(SpaceID, Data),
    tnt_worker:request(Client, Req).

-spec upsert(client(), space_id(), tnt_tuple(), ops()) -> {ok, reference()}.
upsert(Client, SpaceID, Data, Ops) ->
    Req = tnt_proto:request_upsert(SpaceID, Data, Ops),
    tnt_worker:request(Client, Req).

-spec update(client(), space_id(), key(), ops()) -> {ok, reference()}.
update(Client, SpaceID, Key, Ops) ->
    update(Client, SpaceID, Key, Ops, #{}).

-spec update(client(), space_id(), key(), ops(), params()) -> {ok, reference()}.
update(Client, SpaceID, Key, Ops, Params) ->
    IndexID = maps:get(index_id, Params, 0),
    Req = tnt_proto:request_update(SpaceID, Key, Ops, IndexID),
    tnt_worker:request(Client, Req).

-spec delete(client(), space_id(), key()) -> {ok, reference()}.
delete(Client, SpaceID, Key) ->
    delete(Client, SpaceID, Key, #{}).

-spec delete(client(), space_id(), key(), params()) -> {ok, reference()}.
delete(Client, SpaceID, Key, Params) ->
    IndexID = maps:get(index_id, Params, 0),
    Req = tnt_proto:request_delete(SpaceID, Key, IndexID),
    tnt_worker:request(Client, Req).

-spec call(client(), binary()) -> {ok, reference()}.
call(Client, Func) ->
    call(Client, Func, []).

-spec call(client(), binary(), tnt_tuple()) -> {ok, reference()}.
call(Client, Func, Args) ->
    Req = tnt_proto:request_call(Func, Args),
    tnt_worker:request(Client, Req).

-spec eval(client(), binary()) -> {ok, reference()}.
eval(Client, Expr) ->
    eval(Client, Expr, []).

-spec eval(client(), binary(), tnt_tuple()) -> {ok, reference()}.
eval(Client, Expr, Args) ->
    Req = tnt_proto:request_eval(Expr, Args),
    tnt_worker:request(Client, Req).

-spec ping(client()) -> {ok, reference()}.
ping(Client) ->
    Req = tnt_proto:request_ping(),
    tnt_worker:request(Client, Req).

%%-- sync requests ------------------------------------------------------------

-spec select_sync(client(), space_id(), key()) -> result({ok, list(tnt_tuple())}).
select_sync(Client, SpaceID, Key) ->
    select_sync(Client, SpaceID, Key, #{}).

-spec select_sync(client(), space_id(), key(), params()) -> result({ok, list(tnt_tuple())}).
select_sync(Client, SpaceID, Key, Params) ->
    {ok, Ref} = select(Client, SpaceID, Key, Params),
    wait(Ref, ?DEFAULT_SYNC_TIMEOUT).

-spec insert_sync(client(), space_id(), tnt_tuple()) -> result({ok, tnt_tuple()}).
insert_sync(Client, SpaceID, Data) ->
    {ok, Ref} = insert(Client, SpaceID, Data),
    wait(Ref, ?DEFAULT_SYNC_TIMEOUT).

-spec replace_sync(client(), space_id(), tnt_tuple()) -> result({ok, tnt_tuple()}).
replace_sync(Client, SpaceID, Data) ->
    {ok, Ref} = replace(Client, SpaceID, Data),
    wait(Ref, ?DEFAULT_SYNC_TIMEOUT).

-spec upsert_sync(client(), space_id(), tnt_tuple(), ops()) -> result({ok, tnt_tuple()}).
upsert_sync(Client, SpaceID, Data, Ops) ->
    {ok, Ref} = upsert(Client, SpaceID, Data, Ops),
    wait(Ref, ?DEFAULT_SYNC_TIMEOUT).

-spec update_sync(client(), space_id(), key(), ops()) -> result({ok, tnt_tuple()}).
update_sync(Client, SpaceID, Key, Ops) ->
    update_sync(Client, SpaceID, Key, Ops, #{}).

-spec update_sync(client(), space_id(), key(), ops(), params()) -> result({ok, tnt_tuple()}).
update_sync(Client, SpaceID, Key, Ops, Params) ->
    {ok, Ref} = update(Client, SpaceID, Key, Ops, Params),
    wait(Ref, ?DEFAULT_SYNC_TIMEOUT).

-spec delete_sync(client(), space_id(), key()) -> result({ok, tnt_tuple()}).
delete_sync(Client, SpaceID, Key) ->
    delete_sync(Client, SpaceID, Key, #{}).

-spec delete_sync(client(), space_id(), key(), params()) -> result({ok, tnt_tuple()}).
delete_sync(Client, SpaceID, Key, Params) ->
    {ok, Ref} = delete(Client, SpaceID, Key, Params),
    wait(Ref, ?DEFAULT_SYNC_TIMEOUT).

-spec call_sync(client(), binary()) -> result({ok, tnt_tuple()}).
call_sync(Client, Func) ->
    call_sync(Client, Func, []).

-spec call_sync(client(), binary(), tnt_tuple()) -> result({ok, tnt_tuple()}).
call_sync(Client, Func, Args) ->
    {ok, Ref} = call(Client, Func, Args),
    wait(Ref, ?DEFAULT_SYNC_TIMEOUT).

-spec eval_sync(client(), binary()) -> result({ok, any()}).
eval_sync(Client, Expr) ->
    eval_sync(Client, Expr, []).

-spec eval_sync(client(), binary(), tnt_tuple()) -> result({ok, any()}).
eval_sync(Client, Expr, Args) ->
    {ok, Ref} = eval(Client, Expr, Args),
    wait(Ref, ?DEFAULT_SYNC_TIMEOUT).

-spec ping_sync(client()) -> result(ok).
ping_sync(Client) ->
    {ok, Ref} = ping(Client),
    wait(Ref, ?DEFAULT_SYNC_TIMEOUT).

%%-- misc requests ------------------------------------------------------------

-spec get_space_id(client(), string() | binary()) -> result({ok, space_id()}).
get_space_id(Client, TableName) when is_binary(TableName) ->
    Query = <<"return box.space._space.index[2]:select{'", TableName/binary, "'}">>,
    case eval_sync(Client, Query) of
        {ok, [[SpaceID | _]]} when is_integer(SpaceID) ->
            {ok, SpaceID};
        {ok, _} ->
            {error, not_found};
        {error, _} = Err ->
            Err
    end;
get_space_id(Client, TableName) when is_list(TableName) ->
    get_space_id(Client, list_to_binary(TableName)).

%%-- helpers ------------------------------------------------------------------

-spec wait(reference(), timeout()) -> ok | result({ok, any()}).
wait(Ref, Timeout) ->
    receive
        #tnt_reply{ref = Ref, answer = ok} ->
            ok;

        #tnt_reply{ref = Ref, answer = Reply} ->
            {ok, Reply};

        #tnt_error{ref = Ref, reason = What} ->
            {error, What}
    after
        Timeout ->
            {error, timeout}
    end.
