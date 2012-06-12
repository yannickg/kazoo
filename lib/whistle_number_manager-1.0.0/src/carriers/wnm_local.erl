%%%-------------------------------------------------------------------
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%%
%%% Handle client requests for phone_number documents
%%%
%%% @end
%%% Created : 08 Jan 2012 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(wnm_local).

-export([find_numbers/2]).
-export([acquire_number/1]).
-export([disconnect_number/1]).

-include("../wh_number_manager.hrl").

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Query the local system for a quanity of available numbers
%% in a rate center
%% @end
%%--------------------------------------------------------------------
-spec find_numbers/2 :: (ne_binary(), pos_integer()) -> {'ok', wh_json:json_object()} |
                                                        {'error', _}.
find_numbers(Number, Quanity) when size(Number) < 5 ->
    find_numbers(<<"+1", Number/binary>>, Quanity);
find_numbers(Number, Quanity) ->
    case wnm_util:number_to_db_name(Number) of
        undefined -> {error, indeterminable_db};
        Db ->
            ViewOptions = [{<<"startkey">>, [<<"available">>, Number]}
                           ,{<<"endkey">>, [<<"available">>, <<Number/binary, "\ufff0">>]}
                           ,{<<"limit">>, Quanity}
                          ],
            case couch_mgr:get_results(Db, <<"numbers/status">>, ViewOptions) of
                {ok, []} -> 
                    lager:debug("found no available local numbers"),
                    {error, non_available};
                {ok, JObjs} ->
                    lager:debug("found ~p available local numbers", [length(JObjs)]),
                    {ok, wh_json:from_list([{wh_json:get_value(<<"id">>, JObj), wh_json:new()}
                                            || JObj <- JObjs
                                           ])};
                {error, _R}=E ->
                    lager:debug("failed to lookup available local numbers: ~p", [_R]),
                    E
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Acquire a given number from the carrier
%% @end
%%--------------------------------------------------------------------
-spec acquire_number/1 :: (wnm_number()) -> wnm_number().
acquire_number(Number) -> Number.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Release a number from the routing table
%% @end
%%--------------------------------------------------------------------
-spec disconnect_number/1 :: (wnm_number()) -> wnm_number().
disconnect_number(Number) -> Number.
