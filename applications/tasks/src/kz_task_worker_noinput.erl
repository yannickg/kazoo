%%%-------------------------------------------------------------------
%%% @copyright (C) 2016-2017, 2600Hz INC
%%% @doc
%%%  Run tasks without CSV input file, scheduled by kz_tasks.
%%% @end
%%% @contributors
%%%   Pierre Fenoll
%%%-------------------------------------------------------------------
-module(kz_task_worker_noinput).

%% API
-export([start/3]).

-include("tasks.hrl").

-record(state, {task_id :: kz_tasks:id()
               ,api :: kz_json:object()
               ,output_header :: kz_tasks:output_header()
               ,extra_args :: kz_tasks:extra_args()
               ,total_failed = 0 :: non_neg_integer()
               ,total_succeeded = 0 :: non_neg_integer()
               }).
-type state() :: #state{}.

-define(OUT(TaskId), <<"/tmp/task_out.", (TaskId)/binary, ".csv">>).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec start(kz_tasks:id(), kz_json:object(), kz_tasks:extra_args()) -> ok.
start(TaskId, API, ExtraArgs) ->
    _ = kz_util:put_callid(TaskId),
    case init(TaskId, API, ExtraArgs) of
        {'ok', State} ->
            lager:debug("worker for ~s started", [TaskId]),
            loop('init', State);
        {'error', _R} ->
            kz_tasks_scheduler:worker_error(TaskId),
            lager:debug("worker exiting now: ~p", [_R])
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
-spec init(kz_tasks:id(), kz_json:object(), kz_tasks:extra_args()) -> {ok, state()} |
                                                                      {error, any()}.
init(TaskId, API, ExtraArgs) ->
    Header = kz_tasks_scheduler:get_output_header(API),
    case write_output_csv_header(TaskId, Header) of
        {'error', _R}=Error ->
            lager:error("failed to write CSV header in ~s", [?OUT(TaskId)]),
            Error;
        'ok' ->
            State = #state{task_id = TaskId
                          ,api = API
                          ,extra_args = ExtraArgs
                          ,output_header = Header
                          },
            {'ok', State}
    end.

%% @private
-spec loop(kz_tasks:iterator(), state()) -> any().
loop(IterValue, State=#state{task_id = TaskId
                            ,total_failed = TotalFailed
                            ,total_succeeded = TotalSucceeded
                            }) ->
    case is_task_successful(State, IterValue) of
        'stop' ->
            _ = kz_tasks_scheduler:worker_finished(TaskId
                                                  ,TotalSucceeded
                                                  ,TotalFailed
                                                  ,?OUT(TaskId)
                                                  ),
            'stop';
        {IsSuccessful, Written, 'stop'} ->
            NewState = state_after_writing(IsSuccessful, Written, State),
            _ = kz_tasks_scheduler:worker_finished(TaskId
                                                  ,NewState#state.total_succeeded
                                                  ,NewState#state.total_failed
                                                  ,?OUT(TaskId)
                                                  ),
            'stop';
        {IsSuccessful, Written, NewIterValue} ->
            NewState = state_after_writing(IsSuccessful, Written, State),
            loop(NewIterValue, NewState)
    end.

%% @private
-spec state_after_writing(boolean(), non_neg_integer(), state()) -> state().
state_after_writing('true', Written, State) ->
    new_state_after_writing(Written, 0, State);
state_after_writing('false', Written, State) ->
    new_state_after_writing(0, Written, State).

%% @private
-spec new_state_after_writing(non_neg_integer(), non_neg_integer(), state()) -> state().
new_state_after_writing(WrittenSucceeded, WrittenFailed, State) ->
    NewTotalSucceeded = WrittenSucceeded + State#state.total_succeeded,
    NewTotalFailed = WrittenFailed + State#state.total_failed,
    S = State#state{total_succeeded = NewTotalSucceeded
                   ,total_failed = NewTotalFailed
                   },
    _ = kz_tasks_scheduler:worker_maybe_send_update(State#state.task_id
                                                   ,NewTotalSucceeded
                                                   ,NewTotalFailed
                                                   ),
    _ = kz_tasks_scheduler:worker_pause(),
    S.

%% @private
-spec is_task_successful(state(), kz_tasks:iterator()) ->
                                {boolean(), non_neg_integer(), kz_tasks:iterator()} |
                                stop.
is_task_successful(State=#state{api = API
                               ,extra_args = ExtraArgs
                               }
                  ,IterValue
                  ) ->
    case tasks_bindings:apply(API, [ExtraArgs, IterValue]) of
        ['stop'] -> 'stop';
        [{'EXIT', {_Error, _ST=[_|_]}}] ->
            lager:error("error: ~p", [_Error]),
            kz_util:log_stacktrace(_ST),
            Written = store_return(State, ?WORKER_TASK_FAILED),
            {'false', Written, 'stop'};
        [{'ok', NewIterValue}] ->
            %% For initialisation steps. Skeeps writing a CSV output row.
            {'true', 0, NewIterValue};
        [{[_|_]=NewRowOrRows, NewIterValue}] ->
            Written = store_return(State, NewRowOrRows),
            {'true', Written, NewIterValue};
        [{#{}=NewMappedRow, NewIterValue}] ->
            Written = store_return(State, NewMappedRow),
            {'true', Written, NewIterValue};
        [{?NE_BINARY=NewRow, NewIterValue}] ->
            Written = store_return(State, NewRow),
            {'true', Written, NewIterValue};
        [{Error, NewIterValue}] ->
            Written = store_return(State, Error),
            {'false', Written, NewIterValue}
    end.

%% @private
-spec store_return(state(), kz_tasks:return()) -> pos_integer().
store_return(State, Rows=[_Row|_]) when is_list(_Row);
                                        is_map(_Row) ->
    lists:sum([store_return(State, Row) || Row <- Rows]);
store_return(#state{task_id = TaskId
                   ,output_header = OutputHeader
                   }
            ,Reason
            ) ->
    Data = [reason(OutputHeader, Reason), $\n],
    kz_util:write_file(?OUT(TaskId), Data, ['append']),
    1.

%% @private
-spec reason(kz_tasks:output_header(), kz_tasks:return()) -> iodata().
reason(Header, MappedRow) when is_map(MappedRow) ->
    kz_csv:mapped_row_to_iolist(Header, MappedRow);
reason(_, [_|_]=Row) ->
    kz_csv:row_to_iolist(Row);
reason(_, ?NE_BINARY=Reason) ->
    kz_csv:row_to_iolist([Reason]);
reason(_, _) -> <<>>.

%% @private
-spec write_output_csv_header(kz_tasks:id(), kz_csv:row()) -> ok | {error, any()}.
write_output_csv_header(TaskId, Header) ->
    Data = [kz_csv:row_to_iolist(Header), $\n],
    file:write_file(?OUT(TaskId), Data).

%%% End of Module.
