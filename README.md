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

> **Note**: to create a space see section Eval/Call

2. CRUD
```erlang
%%---- insert

{ok, [1, "one"]} = tnt:insert_sync(Conn, 512, [1, "one"]).
{ok, [2, <<"two">>]} = tnt:insert_sync(Conn, 512, [2, <<"two">>]).

%%---- select

{ok, [[1, "one"]]} = tnt:select_sync(Conn, 512, [1]).
%% or
Params1 = #{
    index_id => 0,             %% IndexId (default: 0)
    limit    => ?SELECT_LIMIT, %%
    offset   => 0,             %% offset (default: 0)
    iterator => ?ITERATOR_EQ   %%
},
{ok, [[1, "one"]]} = tnt:select_sync(Conn, 512, [1], Params1).

%%---- select non existing key

{ok, []} = tnt:select_sync(Conn, 512, [10]).

%% select all

{ok, [[1, "one"], [2, <<"two">>]]} = tnt:select_sync(Conn, 512, []).

%%---- replace/update

{ok, [1, "uno"]} = tnt:replace_sync(Conn, 512, [1, "uno"]).

Op1 = [<<$=>>, 1, <<"due">>], %% or ?OP_ASSIGN(1, <<"due">>),
{ok, [2, <<"due">>]} = tnt:update_sync(Conn, 512, [2], [Op1]).

%% or
Params2 = #{
    index_id => 0 %% IndexId (default: 0)
},
{ok, [2, "due"]} = tnt:update_sync(Conn, 512, [2], [Op1], Params2).

%%---- upsert

Op2 = [<<$=>>, 1, <<"three">>], %% or ?OP_ASSIGN(1, <<"three">>),
Row = [3, "three"],
{ok, []} = tnt:upsert_sync(Conn, 512, Row, [Op2]).
{ok, [[3, "three"]]} = tnt:select_sync(Conn, 512, [3]).
{ok, []} = tnt:upsert_sync(Conn, 512, Row, [Op2]).
{ok, [[3, <<"three">>]]} = tnt:select_sync(Conn, 512, [3]).

%%---- delete

{ok, [1, "uno"]} = tnt:delete_sync(Conn, 512, [1]).

%% or
Params = #{
    index_id => 0 %% IndexId (default: 0)
},
{ok, [1, "uno"]} = tnt:delete_sync(Conn, 512, [1], Params).

%% deletion of a non-existent key
{ok, []} = tnt:delete_sync(Conn, 512, [1]).
```

3. Eval/Call
```erlang
%%---- eval

{ok, <<"hello">>} = tnt:eval_sync(Conn, <<"return 'hello'">>).

{ok, [{<<"hello">>, [<<"hello">>]}]} = tnt:eval_sync(Conn, <<"return {['hello']={'hello'}}">>).

%%---- creating space example
Query = <<"s = box.schema.space.create('test_table', {engine = 'memtx', if_not_exists = true})
s:create_index('pk', {unique = true, type = 'HASH', if_not_exists = true})
return s.id">>.

{ok, 512} = tnt:eval_sync(Conn, Query).

%%---- call

{ok, 5} = tnt:call_sync(Conn, <<"tonumber">>, [<<"5">>]).
```

4. Misc
```erlang
%% get space id by name
{ok, 512} = tnt:get_space_id(Conn, <<"test_table">>).

{error, not_found} = tnt:get_space_id(Conn, <<"not_exists">>).

%% ping
ok = tnt:ping_sync(Conn).
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
