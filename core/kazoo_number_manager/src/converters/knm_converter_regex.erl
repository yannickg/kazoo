%%%-------------------------------------------------------------------
%%% @copyright (C) 2017, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Peter Defebvre
%%%-------------------------------------------------------------------
-module(knm_converter_regex).

-include("knm.hrl").

-export([normalize/1, normalize/2, normalize/3
        ,to_npan/1
        ,to_1npan/1
        ]).

-define(DEFAULT_E164_CONVERTERS, [{<<"^\\+?1?([2-9][0-9]{2}[2-9][0-9]{6})\$">>
                                  ,kz_json:from_list([{<<"prefix">>, <<"+1">>}])
                                  }
                                 ,{<<"^011(\\d*)$|^00(\\d*)\$">>
                                  ,kz_json:from_list([{<<"prefix">>, <<"+">>}])
                                  }
                                 ,{<<"^[2-9]\\d{7,}\$">>
                                  ,kz_json:from_list([{<<"prefix">>, <<"+">>}])
                                  }
                                 ]).

-define(KEY_E164_CONVERTERS, <<"e164_converters">>).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec normalize(ne_binary()) ->
                       ne_binary().
normalize(?NE_BINARY = Num) ->
    to_e164(Num).

-spec normalize(ne_binary(), api_binary()) ->
                       ne_binary().
normalize(?NE_BINARY = Num, 'undefined') ->
    to_e164(Num);
normalize(?NE_BINARY = Num, AccountId) ->
    to_e164(Num, AccountId).

-spec normalize(ne_binary(), ne_binary(), kz_json:object()) ->
                       ne_binary().
normalize(?NE_BINARY = Num, AccountId, DialPlan) ->
    to_e164_from_account_dialplan(Num, AccountId, DialPlan).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec to_npan(ne_binary()) -> ne_binary().
to_npan(Num) ->
    case re:run(Num, <<"^\\+?1?([2-9][0-9]{2}[2-9][0-9]{6})\$">>, [{'capture', [1], 'binary'}]) of
        'nomatch' -> Num;
        {'match', [NPAN]} -> NPAN
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec to_1npan(ne_binary()) -> ne_binary().
to_1npan(Num) ->
    case re:run(Num, <<"^\\+?1?([2-9][0-9]{2}[2-9][0-9]{6})\$">>, [{'capture', [1], 'binary'}]) of
        'nomatch' -> Num;
        {'match', [NPAN]} -> <<$1, NPAN/binary>>
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec to_e164(ne_binary()) -> ne_binary().
to_e164(<<"+",_/binary>> = N) -> N;
to_e164(Number) ->
    Converters = get_e164_converters(),
    Regexes = kz_json:get_keys(Converters),
    maybe_convert_to_e164(Regexes, Converters, Number).

to_e164(<<"+",_/binary>> = N, _AccountId) -> N;
to_e164(Number, Account) ->
    AccountId = kz_util:format_account_id(Account, 'raw'),
    case kz_account:fetch(AccountId) of
        {'ok', JObj} ->
            to_e164_from_account_dialplan(Number, AccountId, kz_account:dial_plan(JObj));
        {'error', _E} ->
            to_e164_from_account(Number, AccountId)
    end.

-spec to_e164_from_account(ne_binary(), ne_binary()) -> ne_binary().
to_e164_from_account(Number, ?NE_BINARY = AccountId) ->
    Converters = get_e164_converters(AccountId),
    Regexes = kz_json:get_keys(Converters),
    maybe_convert_to_e164(Regexes, Converters, Number).

to_e164_from_account_dialplan(Number, AccountId, 'undefined') ->
    to_e164_from_account(Number, AccountId);
to_e164_from_account_dialplan(Number, AccountId, DialPlan) ->
    to_e164_from_account_dialplan_regexes(Number
                                         ,AccountId
                                         ,DialPlan
                                         ,kz_json:get_keys(DialPlan)
                                         ).

to_e164_from_account_dialplan_regexes(Number, AccountId, _DialPlan, []) ->
    to_e164_from_account(Number, AccountId);
to_e164_from_account_dialplan_regexes(Number, AccountId, DialPlan, Regexes) ->
    to_e164_from_account(apply_dialplan(Number, DialPlan, Regexes), AccountId).

apply_dialplan(Number, _Dialplan, []) -> Number;
apply_dialplan(Number, DialPlan, [Regex|Rs]) ->
    case re:run(Number, Regex, [{'capture', 'all', 'binary'}]) of
        'nomatch' ->
            apply_dialplan(Number, DialPlan, Rs);
        'match' ->
            Number;
        {'match', Captures} ->
            Root = lists:last(Captures),
            Prefix = kz_json:get_binary_value([Regex, <<"prefix">>], DialPlan, <<>>),
            Suffix = kz_json:get_binary_value([Regex, <<"suffix">>], DialPlan, <<>>),
            <<Prefix/binary, Root/binary, Suffix/binary>>
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------

-spec get_e164_converters() -> kz_json:object().
-ifdef(TEST).
get_e164_converters() ->
    kz_json:from_list(?DEFAULT_E164_CONVERTERS).
-else.
get_e164_converters() ->
    Default = kz_json:from_list(?DEFAULT_E164_CONVERTERS),
    try kapps_config:get(?KNM_CONFIG_CAT
                        ,?KEY_E164_CONVERTERS
                        ,Default
                        )
    catch
        _:_ -> Default
    end.
-endif.

-spec get_e164_converters(ne_binary()) -> kz_json:object().
get_e164_converters(AccountId) ->
    Default = kz_json:from_list(?DEFAULT_E164_CONVERTERS),
    try kapps_account_config:get_global(AccountId
                                       ,?KNM_CONFIG_CAT
                                       ,?KEY_E164_CONVERTERS
                                       ,Default
                                       )
    catch
        _:_ -> Default
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec maybe_convert_to_e164(ne_binaries(), kz_json:object(), ne_binary()) -> ne_binary().
maybe_convert_to_e164([], _, Number) -> Number;
maybe_convert_to_e164([Regex|Regexs], Converters, Number) ->
    case re:run(Number, Regex, [{'capture', 'all', 'binary'}]) of
        'nomatch' ->
            maybe_convert_to_e164(Regexs, Converters, Number);
        {'match', Captures} ->
            Root = lists:last(Captures),
            Prefix = kz_json:get_binary_value([Regex, <<"prefix">>], Converters, <<>>),
            Suffix = kz_json:get_binary_value([Regex, <<"suffix">>], Converters, <<>>),
            <<Prefix/binary, Root/binary, Suffix/binary>>
    end.
