TNT
===

A native Erlang client for Tarantool. Compatible with Tarantool 3.x and Erlang/OTP 26.

See the [CHANGELOG](CHANGELOG.md) for the list of implemented features.

Options
-------

* `host`: DNS name or IP address as string, default: "localhost"
* `port`: integer, default: 3301
* `username`: string, default: undefined
* `password`: string, default: <<>>
* `connect_timeout`: connection timeout (milliseconds), default: 5000
* `response_timeout`: request response timeout (milliseconds), default: 5000
* `reconnect_policy`: the rule that determines the delay between reconnection attempts,
    default: {infinity, {exponential, 100, 30000}}. Interpretation: Initial delay is 100ms. Each subsequent delay doubles until capped at 30000ms. Retries continue indefinitely (infinity).

Connection Pool
---------------
`TNT` uses a single connection by default. Connection pooling can be achieved via an external library.

Usage
-----

```shell
make compile && erl -pa _build/default/lib/*/ebin
```

1. Connect
```erlang
{ok, Conn} = tnt:connect([]).

%% or

Args = [
    {host, "localhost"},     %% Host (default: "localhost")
    {port, 3301},            %% Port (default: 3301)
    {username, <<"guest">>}, %% User (default: undefined, use guest access)
    {password, <<>>}         %% Pass (default: <<>>, use guest access)
],
{ok, Conn} = tnt:connect(Args).

%% or

{ok, Conn} = tnt:connect("localhost", 3301).
```

2. CRUD
```erlang
%%---- insert

{ok, [1, "one"]} = tnt:insert_sync(Conn, 512, [1, <<"one">>]).
{ok, [2, "two"]} = tnt:insert_sync(Conn, 512, [2, <<"two">>]).

%%---- select

{ok, [[1, "one"]]} = tnt:select_sync(Conn, 512, [1]).
%% or
Params = #{
    index_id => 0,             %% IndexId (default: 0)
    limit    => ?SELECT_LIMIT, %%
    offset   => 0,             %% offset (default: 0)
    iterator => ?ITERATOR_EQ   %%
},
{ok, [[1, "one"]]} = tnt:select_sync(Conn, 512, [1], Params).

%% select all

{ok, [[1, "one"], [2, "two"]]} = tnt:select_sync(Conn, 512, []).

%%---- replace/update

{ok, [1, "uno"]} = tnt:replace_sync(Conn, 512, [1, "uno"]).

Op = [<<$=>>, 1, <<"due">>], %% or ?OP_ASSIGN(1, <<"due">>),
{ok, [2, "due"]} = tnt:update_sync(Conn, 512, [2], [Op]).

%% or
Params = #{
    index_id => 0 %% IndexId (default: 0)
},
{ok, [2, "due"]} = tnt:update_sync(Conn, 512, [2], [Op], Params).

%%---- upsert

Op = [<<$=>>, 1, <<"three">>], %% or ?OP_ASSIGN(1, <<"three">>),
Row = [3, <<"three">>],
{ok, []} = tnt:upsert_sync(Conn, 512, Row, [Op]).

%%---- delete

{ok, [1, "uno"]} = tnt:delete_sync(Conn, 512, [1]).

%% or
Params = #{
    index_id => 0 %% IndexId (default: 0)
},
{ok, [1, "uno"]} = tnt:delete_sync(Conn, 512, [1], Params).
```

3. Eval/Call
```erlang
%%---- eval

{ok, <<"hello">>} = tnt:eval_sync(Conn, <<"return 'hello'">>).

{ok, [{"hello", ["hello"]}]} = tnt:eval_sync(Conn, <<"return {['hello']={'hello'}}">>).

%%---- call

{ok, 5} = tnt:call_sync(C2, <<"tonumber">>, [<<"5">>]).
```

4. Misc
```erlang
%% get space id by name
{ok, 512} = tnt:get_space_id(Conn, <<"test_table">>).

%% ping
ok = tnt:ping(Conn).
```

5. Close
```erlang
ok = tnt:close(Conn).
```

Cheatsheet
----------

```shell
make compile
```

```shell
make tests
```

```shell
make xref
make lint
make dialyzer
