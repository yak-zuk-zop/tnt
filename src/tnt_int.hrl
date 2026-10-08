-record(context, {
    state :: {initial, binary()} | {continue, msgpack:state()} | complete,
    total :: non_neg_integer(),
    code :: undefined | tnt_proto:code(),
    sync  :: undefined | tnt_proto:sync(),
    schema :: undefined | non_neg_integer(),
    msg :: undefined | tnt_proto:proto() | any()
}).