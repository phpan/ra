-module(ra_log_memory).
-behaviour(ra_log).
-export([init/1,
         close/1,
         append/2,
         write/2,
         take/3,
         last_index_term/1,
         handle_event/2,
         last_written/1,
         fetch/2,
         fetch_term/2,
         flush/2,
         next_index/1,
         write_snapshot/2,
         read_snapshot/1,
         snapshot_index_term/1,
         update_release_cursor/4,
         read_meta/2,
         write_meta/3,
         sync_meta/1,
         can_write/1,
         to_list/1
        ]).

-include("ra.hrl").

-type ra_log_memory_meta() :: #{atom() => term()}.

-record(state, {last_index = 0 :: ra_index(),
                last_written = {0, 0} :: ra_idxterm(), % only here to fake the async api of the file based one
                entries = #{0 => {0, undefined}} :: #{ra_term() => {ra_index(), term()}},
                meta = #{} :: ra_log_memory_meta(),
                snapshot :: maybe(ra_log:ra_log_snapshot())}).

-type ra_log_memory_state() :: #state{}.

-spec init(_) -> ra_log_memory_state().
init(_Args) ->
    % initialized with a deafault 0 index 0 term dummy value
    % and an empty meta data map
    #state{}.

-spec close(ra_log_memory_state()) -> ok.
close(_State) ->
    % not much to do here
    ok.

-spec append(Entry::log_entry(), State::ra_log_memory_state()) ->
    {written, ra_log_memory_state()} | no_return().
append({Idx, Term, Data}, #state{last_index = LastIdx,
                                 entries = Log} = State)
  when Idx > LastIdx ->
    {written, State#state{last_index = Idx,
                          entries = Log#{Idx => {Term, Data}}}};
append(_Entry, _State) ->
    exit(integrity_error).

-spec write(Entries :: [log_entry()], State::ra_log_memory_state()) ->
    {written, ra_log_memory_state()} |
    {error, integrity_error}.
write([{FirstIdx, _, _} | _] = Entries,
      #state{last_index = LastIdx, entries = Log0} = State)
  when FirstIdx =< LastIdx + 1 ->
    % overwrite
    Log1 = case FirstIdx < LastIdx of
               true ->
                   maps:without(lists:seq(FirstIdx+1, LastIdx), Log0);
               false ->
                   Log0
           end,
    {Log, LastInIdx} = lists:foldl(fun ({Idx, Term, Data}, {Acc, _}) ->
                                           {Acc#{Idx => {Term, Data}}, Idx}
                                   end, {Log1, FirstIdx}, Entries),
    {written, State#state{last_index = LastInIdx,
                          entries = Log}};
write([{FirstIdx, _, _} | _] = Entries,
      #state{snapshot = Snapshot, entries = Log0} = State)
 when element(1, Snapshot) + 1 =:= FirstIdx ->
    {Log, LastInIdx} = lists:foldl(fun ({Idx, Term, Data}, {Acc, _}) ->
                                           {Acc#{Idx => {Term, Data}}, Idx}
                                   end, {Log0, FirstIdx}, Entries),
    {written, State#state{last_index = LastInIdx,
                          entries = Log}};
write(_Entries, _State) ->
    {error, integrity_error}.


-spec take(ra_index(), non_neg_integer(), ra_log_memory_state()) ->
    {[log_entry()], ra_log_memory_state()}.
take(Start, Num, #state{last_index = LastIdx, entries = Log} = State) ->
    {sparse_take(Start, Log, Num, LastIdx, []), State}.

% this allows for missing entries in the log
sparse_take(Idx, _Log, Num, Max, Res)
    when length(Res) =:= Num orelse
         Idx > Max ->
    lists:reverse(Res);
sparse_take(Idx, Log, Num, Max, Res) ->
    case Log of
        #{Idx := {T, D}} ->
            sparse_take(Idx+1, Log, Num, Max, [{Idx, T, D} | Res]);
        _ ->
            sparse_take(Idx+1, Log, Num, Max, Res)
    end.


-spec last_index_term(ra_log_memory_state()) -> maybe(ra_idxterm()).
last_index_term(#state{last_index = LastIdx,
                       entries = Log,
                       snapshot = Snapshot}) ->
    case Log of
        #{LastIdx := {LastTerm, _Data}} ->
            {LastIdx, LastTerm};
        _ ->
            % If not found fall back on snapshot if snapshot matches last term.
            case Snapshot of
                {LastIdx, LastTerm, _, _} ->
                    {LastIdx, LastTerm};
                _ ->
                    undefined
            end
    end.

-spec last_written(ra_log_memory_state()) -> ra_idxterm().
last_written(#state{last_written = LastWritten}) ->
    % we could just use the last index here but we need to "fake" it to
    % remain api compatible with  ra_log_file, for now at least.
    LastWritten.

-spec handle_event(ra_log:ra_log_event(), ra_log_memory_state()) ->
    ra_log_memory_state().
handle_event({written, {_From, Idx, Term}}, State0) ->
    case fetch_term(Idx, State0) of
        {Term, State} ->
            State#state{last_written = {Idx, Term}};
        _ ->
            % if the term doesn't match we just ignore it
            State0
    end.

-spec next_index(ra_log_memory_state()) -> ra_index().
next_index(#state{last_index = LastIdx}) ->
    LastIdx + 1.

-spec fetch(ra_index(), ra_log_memory_state()) ->
    {maybe(log_entry()), ra_log_memory_state()}.
fetch(Idx, #state{entries = Log} = State) ->
    case Log of
        #{Idx := {T, D}} ->
            {{Idx, T, D}, State};
        _ -> {undefined, State}
    end.

-spec fetch_term(ra_index(), ra_log_memory_state()) ->
    {maybe(ra_term()), ra_log_memory_state()}.
fetch_term(Idx, #state{entries = Log} = State) ->
    case Log of
        #{Idx := {T, _}} ->
            {T, State};
        _ -> {undefined, State}
    end.

flush(_Idx, Log) -> Log.

-spec write_snapshot(Snapshot :: ra_log:ra_log_snapshot(),
                     State :: ra_log_memory_state()) ->
    ra_log_memory_state().
write_snapshot(Snapshot, #state{entries = Log0} = State) ->
    Index  = element(1, Snapshot),
    % discard log
    Log = maps:filter(fun (K, _) -> K > Index end, Log0),
    State#state{entries = Log, snapshot = Snapshot}.

-spec read_snapshot(State :: ra_log_memory_state()) ->
    ra_log:ra_log_snapshot().
read_snapshot(#state{snapshot = Snapshot}) ->
    Snapshot.

-spec read_meta(Key :: ra_log:ra_meta_key(), State :: ra_log_memory_state()) ->
    maybe(term()).
read_meta(Key, #state{meta = Meta}) ->
    maps:get(Key, Meta, undefined).

-spec snapshot_index_term(State :: ra_log_memory_state()) ->
    ra_idxterm().
snapshot_index_term(#state{snapshot = {Idx, Term, _, _}}) ->
    {Idx, Term};
snapshot_index_term(#state{snapshot = undefined}) ->
    undefined.

-spec update_release_cursor(ra_index(), ra_cluster(), term(),
                            ra_log_memory_state()) ->
    ra_log_memory_state().
update_release_cursor(_Idx, _Cluster, _MacState, State) ->
    State.

-spec write_meta(Key :: ra_log:ra_meta_key(), Value :: term(),
                 State :: ra_log_memory_state()) ->
    {ok,  ra_log_memory_state()} | {error, term()}.
write_meta(Key, Value, #state{meta = Meta} = State) ->
    {ok, State#state{meta = Meta#{Key => Value}}}.

sync_meta(_Log) ->
    ok.

can_write(_Log) ->
    true.

to_list(#state{entries = Log}) ->
    [{Idx, Term, Data} || {Idx, {Term, Data}} <- maps:to_list(Log)].


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

% append_test() ->
%     {0, #{}, _, _} = S = init([]),
%     {ok, {1, #{1 := {1, <<"hi">>}}, _, _}} =
%     append({1, 1, <<"hi">>}, no_overwrite, sync, S).

% append_twice_test() ->
%     {0, #{}, _, _} = S = init([]),
%     Entry = {1, 1, <<"hi">>},
%     {ok, S2} = append(Entry, no_overwrite, sync, S),
%     {error, integrity_error} = append(Entry, no_overwrite, sync, S2).

% append_overwrite_test() ->
%     {0, #{}, _, _} = S = init([]),
%     Entry = {1, 1, <<"hi">>},
%     {ok, S2} = append(Entry, overwrite, sync, S),
%     % TODO: a proper implementation should validate the term isn't decremented
%     % also it should truncate any item newer than the last written index
%     {ok,  {1, #{1 := {1, <<"hi">>}}, _, _}} = append(Entry, overwrite, sync, S2).

% take_test() ->
%     Log = #{1 => {8, <<"one">>},
%             2 => {8, <<"two">>},
%             3 => {8, <<"three">>}},
%     [{1, 8, <<"one">>},
%      {2, 8, <<"two">>}] = take(1, 2, {3, Log, #{}, undefined}),
%     [{3, 8, <<"three">>}] = take(3, 2, {3, Log, #{}, undefined}).

% last_test() ->
%     Log = #{1 => {8, <<"one">>},
%             2 => {8, <<"two">>},
%             3 => {8, <<"three">>}},
%     {3, 8, <<"three">>} = last({3, Log, #{}, undefined}).

% next_index_test() ->
%     Log = #{1 => {8, <<"one">>},
%             2 => {8, <<"two">>},
%             3 => {8, <<"three">>}},
%     4 = next_index({3, Log, #{}, undefined}).

% fetch_test() ->
%     Log = #{1 => {8, <<"one">>},
%             2 => {8, <<"two">>},
%             3 => {8, <<"three">>}},
%     {2, 8, <<"two">>} = fetch(2, {3, Log, #{}, undefined}).

% meta_test() ->
%     State0 = {0, #{}, #{}, undefined},
%     {ok, State} = write_meta(current_term, 23, State0),
%     23 = read_meta(current_term, State).

-endif.