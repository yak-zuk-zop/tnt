-module(tnt_scramble_tests).

-include_lib("eunit/include/eunit.hrl").

-spec test() -> _.

%%-- tests --------------------------------------------------------------------

-spec scramble_test() -> _.
scramble_test() ->
    Expected = base64:decode(<<"SQagY1ConB6eOwEbFuJ+DRlvix8=">>),
    Salt = base64:decode(<<"QFelQe0EVKtv2gDkYusNyrCIhZs=">>),
    HashedPwd = crypto:hash(sha, <<"abcdef">>),
    ?assertEqual(Expected, tnt_proto:scramble(Salt, HashedPwd)).
