-module(tnt_retry).

%% API
-export([
    new/1,
    next/1,
    skip/1
]).

-export_type([
    strategy/0,
    policy/0
]).

%% Types
-record(strategy, {
    retries :: retries(),
    timeout :: interval()
}).

-opaque strategy() :: #strategy{}.
-type retries() :: non_neg_integer() | infinity.
-type tout() :: non_neg_integer().
-type interval() ::
    {constant, Timeout :: tout()} |
    {exponential, Timeout :: tout(), MaxTimeout :: tout()}.
-type policy() :: no_retry | {retries(), interval()}.

%% Macros

-define(IS_POS_INT(T), is_integer(T), T >= 0).

%%-- API ----------------------------------------------------------------------

-spec new(policy()) -> strategy().
new({Retries, {constant, T} = Timeout}) when ?IS_POS_INT(T) ->
    #strategy{retries = Retries, timeout = Timeout};
new({Retries, {exponential, T, Max} = Timeout}) when ?IS_POS_INT(T), is_integer(Max), Max > T ->
    #strategy{retries = Retries, timeout = Timeout};
new(no_retry) ->
    #strategy{retries = 0, timeout = {constant, 0}};
new(Unknown) ->
    erlang:error(badarg, Unknown).

-spec next(strategy()) -> {wait, tout(), strategy()} | finish.
next(#strategy{retries = 0}) ->
    finish;
next(#strategy{retries = R, timeout = Tm} = S) ->
    {wait, get_timeout(Tm), S#strategy{
        retries = next_retry(R),
        timeout = next_timeout(Tm)
    }}.

-spec skip(strategy()) -> strategy().
skip(X) ->
    case next(X) of
        finish ->
            X;
        {wait, _, DX} ->
            DX
    end.

%%

-spec get_timeout(interval()) -> tout().
get_timeout({constant, Timeout}) ->
    Timeout;
get_timeout({exponential, Timeout, _}) ->
    Timeout.

-spec next_timeout(interval()) -> interval().
next_timeout({constant, _} = Int) ->
    Int;
next_timeout({exponential, Timeout, MaxTimeout}) ->
    {exponential, min(Timeout bsl 1, MaxTimeout), MaxTimeout}.

-spec next_retry(retries()) -> retries().
next_retry(infinity) ->
    infinity;
next_retry(R) ->
    R - 1.
