-module(tnt_proto).

-include("tnt.hrl").

%% API
-export([
    decode/1,
    encode/2,
    next_sync/1,
    get_error/2
]).

%% requests
-export([
    request_auth/3,
    request_select/6,
    request_insert/2,
    request_replace/2,
    request_upsert/3,
    request_update/4,
    request_delete/3,
    request_call/2,
    request_eval/2,
    request_ping/0,
    get_request_type/1
]).

-ifdef(TEST).
-export([
    scramble/2
]).
-endif.

-export_type([
    request/0,
    space_id/0,
    index_id/0,
    tnt_tuple/0,
    key/0,
    sync/0,
    proto/0,
    operation/0,
    error_message/0
]).

%% Macros

-define(MPACKOPTS, [{spec, old}, {map_format, jsx}]).
-define(CHAP, <<"chap-sha1">>).

-define(IPROTO_CODE,         16#00).
-define(IPROTO_SYNC,         16#01).

-define(IPROTO_SERVER_ID,    16#02).
-define(IPROTO_TIMESTAMP,    16#04).
-define(IPROTO_SCHEMA_ID,    16#05).

-define(IPROTO_SPACE_ID,     16#10).
-define(IPROTO_INDEX_ID,     16#11).
-define(IPROTO_LIMIT,        16#12).
-define(IPROTO_OFFSET,       16#13).
-define(IPROTO_ITERATOR,     16#14).
-define(IPROTO_INDEX_BASE,   16#15).
-define(IPROTO_KEY,          16#20).
-define(IPROTO_TUPLE,        16#21).
-define(IPROTO_FUNC_NAME,    16#22).
-define(IPROTO_USER_NAME,    16#23).
-define(IPROTO_SERVER_UUID,  16#24).
-define(IPROTO_CLUSTER_UUID, 16#25).
-define(IPROTO_EXPR,         16#27).
-define(IPROTO_OPS,          16#28).
-define(IPROTO_DATA,         16#30).
-define(IPROTO_ERROR_24,     16#31).
-define(IPROTO_ERROR,        16#52).

%% Types

-type request() :: {Type :: pos_integer(), Body :: binary()}.
-type space_id() :: pos_integer().
-type index_id() :: non_neg_integer().
-type tnt_tuple() :: list().
-type key() :: list().
-type sync() :: 1 .. 16#FFFFFFFF.
-type proto() :: list({integer(), term()}).
-type operation() :: nonempty_list().
-type error_message() :: {Code :: pos_integer(), Msg :: iodata()} | {unknown, proto()}.

%%-- API ----------------------------------------------------------------------

-spec decode(binary()) -> Result when
    Result :: {ok, tuple(), binary()} | {wait, pos_integer()} | {error, any()}.
decode(Data) ->
    case msgpack:unpack_stream(Data) of
        {N, Rest} when is_integer(N), N =< byte_size(Rest) ->
            case msgpack:unpack_stream(Rest, ?MPACKOPTS) of
                {error, _} = Err ->
                    Err;
                {Hdr, BinBody} when is_list(Hdr) ->
                    Opts = [{unpack_str, as_binary}, {map_format, jsx}],
                    case msgpack:unpack_stream(BinBody, Opts) of
                        {error, _} = Err ->
                            Err;
                        {Body, Tail} ->
                            Code = proplists:get_value(?IPROTO_CODE, Hdr),
                            Sync = proplists:get_value(?IPROTO_SYNC, Hdr),
                            SchemaID = proplists:get_value(?IPROTO_SCHEMA_ID, Hdr),
                            {ok, {Code, Sync, SchemaID, Body}, Tail}
                    end
            end;
        {N, Rest} when is_integer(N) ->
            {wait, N - byte_size(Rest)};
        {error, _} = Err ->
            Err;
        {Result, _} ->
            {error, {unexpected, Result}}
    end.

-spec encode(request(), sync()) -> binary().
encode({ReqType, Body}, Sync) ->
    Head = msgpack:pack(
        [
            {?IPROTO_CODE, ReqType},
            {?IPROTO_SYNC, Sync}
        ],
        ?MPACKOPTS
    ),
    TotalSZ = msgpack:pack(byte_size(Head) + byte_size(Body)),
    <<TotalSZ/binary, Head/binary, Body/binary>>.

-spec next_sync(sync()) -> sync().
next_sync(16#FFFFFFFF) -> 1;
next_sync(Sync) -> Sync + 1.

-spec get_error(pos_integer(), proto()) -> error_message().
get_error(Code, Body) ->
    case proplists:get_value(?IPROTO_ERROR_24, Body) of
        undefined ->
            case proplists:get_value(?IPROTO_ERROR, Body) of
                [_ | _] = ErrBox ->
                    ErrCode = proplists:get_value(?MP_ERROR_ERRCODE, ErrBox),
                    ErrStr  = proplists:get_value(?MP_ERROR_MESSAGE, ErrBox),
                    {ErrCode, ErrStr};
                _ ->
                    {unknown, Body}
            end;
        Str ->
            {Code band (?IPROTO_TYPE_ERROR - 1), Str}
    end.

%%-- requests -----------------------------------------------------------------

-spec request_auth(binary(), binary(), binary()) -> request().
request_auth(Username, Password, <<Salt:20/binary, _/binary>>) ->
    Hash1 = crypto:hash(sha, Password),
    Scramble = scramble(Salt, Hash1),
    make_request(?REQUEST_TYPE_AUTH, [
        {?IPROTO_TUPLE, [?CHAP, Scramble]},
        {?IPROTO_USER_NAME, Username}
    ]).

%%

-spec request_select(SpaceID, IndexID, Key, It, Limit, Offs) -> request() when
    SpaceID :: space_id(),
    IndexID :: index_id(),
    Key :: key(),
    It :: non_neg_integer(),
    Limit :: pos_integer(),
    Offs :: non_neg_integer().
request_select(SpaceID, IndexID, Key, It, Limit, Offs) ->
    make_request(?REQUEST_TYPE_SELECT, [
        {?IPROTO_SPACE_ID, SpaceID},
        {?IPROTO_INDEX_ID, IndexID},
        {?IPROTO_LIMIT, Limit},
        {?IPROTO_OFFSET, Offs},
        {?IPROTO_ITERATOR, It},
        {?IPROTO_KEY, Key}
    ]).

-spec request_insert(space_id(), tnt_tuple()) -> request().
request_insert(SpaceID, Tuple) ->
    make_request(?REQUEST_TYPE_INSERT, [
        {?IPROTO_SPACE_ID, SpaceID},
        {?IPROTO_TUPLE, Tuple}
    ]).

-spec request_replace(space_id(), tnt_tuple()) -> request().
request_replace(SpaceID, Tuple) ->
    make_request(?REQUEST_TYPE_REPLACE, [
        {?IPROTO_SPACE_ID, SpaceID},
        {?IPROTO_TUPLE, Tuple}
    ]).

-spec request_upsert(space_id(), tnt_tuple(), list(operation())) -> request().
request_upsert(SpaceID, Tuple, Ops) ->
    make_request(?REQUEST_TYPE_UPSERT, [
        {?IPROTO_SPACE_ID, SpaceID},
        {?IPROTO_TUPLE, Tuple},
        {?IPROTO_OPS, Ops}
    ]).

-spec request_update(space_id(), key(), list(operation()), index_id()) -> request().
request_update(SpaceID, Key, Ops, IndexID) ->
    make_request(?REQUEST_TYPE_UPDATE, [
        {?IPROTO_SPACE_ID, SpaceID},
        {?IPROTO_INDEX_ID, IndexID},
        {?IPROTO_KEY, Key},
        {?IPROTO_TUPLE, Ops}
    ]).

-spec request_delete(space_id(), key(), index_id()) -> request().
request_delete(SpaceID, Key, IndexID) ->
    make_request(?REQUEST_TYPE_DELETE, [
        {?IPROTO_SPACE_ID, SpaceID},
        {?IPROTO_INDEX_ID, IndexID},
        {?IPROTO_KEY, Key}
    ]).

%%

-spec request_call(binary(), tnt_tuple()) -> request().
request_call(Function, Args) ->
    make_request(?REQUEST_TYPE_CALL, [
        {?IPROTO_FUNC_NAME, Function},
        {?IPROTO_TUPLE, Args}
    ]).

-spec request_eval(binary(), tnt_tuple()) -> request().
request_eval(Expr, Args) ->
    make_request(?REQUEST_TYPE_EVAL, [
        {?IPROTO_EXPR, Expr},
        {?IPROTO_TUPLE, Args}
    ]).

-spec request_ping() -> request().
request_ping() ->
    make_request(?REQUEST_TYPE_PING, []).

%%

-spec get_request_type(request()) -> Type :: pos_integer().
get_request_type({Type, _}) ->
    Type.

%%-- internals ----------------------------------------------------------------

-spec make_request(Type :: pos_integer(), Proto :: proto()) -> request().
make_request(Type, Proto) ->
    {Type, msgpack:pack(Proto, ?MPACKOPTS)}.

-spec scramble(binary(), binary()) -> binary().
scramble(Salt, Hash1) ->
    Hash2 = crypto:hash(sha, Hash1),
    HashFinal = crypto:hash(sha, <<Salt/binary, Hash2/binary>>),
    crypto:exor(Hash1, HashFinal).
