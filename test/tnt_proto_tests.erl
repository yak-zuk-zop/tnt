-module(tnt_proto_tests).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

%% Types

-type test_case() :: {Name :: string(), Fun :: function(), Args :: list()}.

%%-- tests --------------------------------------------------------------------

-spec proto_test_() -> _.
proto_test_() ->
    {setup,
        fun proto_test_setup/0,
        fun (Tests) ->
            [proto_test_builder(T) || T <- Tests]
        end
    }.

%%-- internals ----------------------------------------------------------------

-spec proto_test_setup() -> list(test_case()).
proto_test_setup() ->
    [
        {"select",  fun tnt_proto:request_select/6, [1, 0, [0], 0, 1, 0]},
        {"insert",  fun tnt_proto:request_insert/2, [1, [0, 1]]},
        {"replace", fun tnt_proto:request_replace/2, [1, [0, 1]]},
        {"upsert",  fun tnt_proto:request_upsert/3, [1, [0, 1], []]},
        {"update",  fun tnt_proto:request_update/4, [1, [0], [], 1]},
        {"delete",  fun tnt_proto:request_delete/3, [1, [0], 1]},
        {"call",    fun tnt_proto:request_call/2, [<<>>, []]},
        {"eval",    fun tnt_proto:request_eval/2, [<<>>, []]},
        {"ping",    fun tnt_proto:request_ping/0, []}
    ].

-spec proto_test_builder(test_case()) -> {Name :: string(), Test :: function()}.
proto_test_builder({Name, Fun, Args}) ->
    {Name, fun () -> request_check(Fun, Args) end}.

-spec request_check(function(), list()) -> _.
request_check(Fun, Args) ->
    FieldsAmount = get_arity(Fun),
    Req = apply(Fun, Args),
    ?assert(is_tuple(Req)),
    {Code, Payload} = Req,
    ?assert(is_integer(Code)),
    ?assert(is_binary(Payload)),
    {ok, Unpacked} = msgpack:unpack(Payload, [{map_format, jsx}]),
    ?assertEqual(FieldsAmount, length(Unpacked)).

-spec get_arity(function()) -> non_neg_integer().
get_arity(Fun) ->
    proplists:get_value(arity, erlang:fun_info(Fun)).
