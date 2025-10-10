-define(IPROTO_GREETING_SIZE, 128).
-define(IPROTO_BODY_MAX_LEN, 16#80000000).

%%-- Request types ------------------------------------------------------------
%% 

-define(REQUEST_TYPE_SELECT, 16#01).
-define(REQUEST_TYPE_INSERT, 16#02).
-define(REQUEST_TYPE_REPLACE, 16#03).
-define(REQUEST_TYPE_UPDATE, 16#04).
-define(REQUEST_TYPE_DELETE, 16#05).
-define(REQUEST_TYPE_AUTH,   16#07).
-define(REQUEST_TYPE_EVAL,   16#08).
-define(REQUEST_TYPE_UPSERT, 16#09).
-define(REQUEST_TYPE_CALL,   16#0A).
-define(REQUEST_TYPE_PING,   16#40).

-define(IPROTO_OK,       0).
-define(IPROTO_UNKNOWN, -1).
-define(IPROTO_TYPE_ERROR, (1 bsl 15)).

%%-- Key compare iterators ----------------------------------------------------

-define(ITERATOR_EQ,  0).
-define(ITERATOR_REQ, 1).
-define(ITERATOR_ALL, 2).
-define(ITERATOR_LT,  3).
-define(ITERATOR_LE,  4).
-define(ITERATOR_GE,  5).
-define(ITERATOR_GT,  6).
-define(ITERATOR_BITSET_ALL_SET, 7).
-define(ITERATOR_BITSET_ANY_SET, 8).
-define(ITERATOR_BITSET_ALL_NOT_SET, 9).
-define(ITERATOR_OVERLAPS, 10).
-define(ITERATOR_NEIGHBOR, 11).

%%-- Operations for update & upsert -------------------------------------------

-define(OP_ADD(FieldNo, Arg),    [<<$+>>, FieldNo, Arg]).
-define(OP_SUB(FieldNo, Arg),    [<<$->>, FieldNo, Arg]).
-define(OP_BAND(FieldNo, Arg),   [<<$&>>, FieldNo, Arg]).
-define(OP_BXOR(FieldNo, Arg),   [<<$^>>, FieldNo, Arg]).
-define(OP_DEL(FieldNo, Arg),    [<<$#>>, FieldNo, Arg]).
-define(OP_INS(FieldNo, Arg),    [<<$!>>, FieldNo, Arg]).
-define(OP_ASSIGN(FieldNo, Arg), [<<$=>>, FieldNo, Arg]).
-define(OP_SPLICE(FieldNo, Pos, Offs, Arg), [<<$:>>, FieldNo, Pos, Offs, Arg]).

%%

-define(SELECT_LIMIT, 16#FFFF).
-define(INITIAL_SYNC, 1).

%%

-define(SPACE_SCHEMA, 272).
-define(SPACE_SPACE, 280).
-define(SPACE_INDEX, 288).
-define(SPACE_FUNC, 296).
-define(SPACE_VSPACE, 281).
-define(SPACE_VINDEX, 289).
-define(SPACE_VFUNC, 297).
-define(SPACE_USER, 304).
-define(SPACE_PRIV, 312).
-define(SPACE_CLUSTER, 320).

-define(IDX_SPACE_PRIMARY, 0).
-define(IDX_SPACE_NAME, 2).
-define(IDX_INDEX_PRIMARY, 0).
-define(IDX_INDEX_NAME, 2).

%%

-define(MP_ERROR_TYPE,    16#00).
-define(MP_ERROR_FILE,    16#01).
-define(MP_ERROR_LINE,    16#02).
-define(MP_ERROR_MESSAGE, 16#03).
-define(MP_ERROR_ERRNO,   16#04).
-define(MP_ERROR_ERRCODE, 16#05).
-define(MP_ERROR_FIELDS,  16#06).

%%

-record(tnt_reply, {
	ref :: reference(),
	answer :: any()
}).

-record(tnt_error, {
	ref :: reference(),
	reason :: tnt_worker:error_message() | timeout
}).
