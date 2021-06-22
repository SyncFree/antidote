%% -------------------------------------------------------------------
%%
%% Copyright <2013-2018> <
%%  Technische Universität Kaiserslautern, Germany
%%  Université Pierre et Marie Curie / Sorbonne-Université, France
%%  Universidade NOVA de Lisboa, Portugal
%%  Université catholique de Louvain (UCL), Belgique
%%  INESC TEC, Portugal
%% >
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either expressed or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% List of the contributors to the development of Antidote: see AUTHORS file.
%% Description and complete License: see LICENSE file.
%% -------------------------------------------------------------------

-module(vector_orddict).
-include("antidote.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% @doc The vector orddict is an ordered dictionary used to store materialized snapshots whose order
%%      is described by vectorclocks.
%%      Note that the elements are stored in a sorted list going from big to small (left to right);
%%      i.e. the most recent snapshot is stored at the head of the list.
%%      The second element of the tuple stores the size of the list.

-type vector_term() :: {vectorclock(), term()}.
-type vector_term_list() :: [vector_term()].
-type vector_orddict() :: {vector_term_list(), non_neg_integer()}.
-type nonempty_vector_orddict() :: {[vector_term(), ...], non_neg_integer()}.

-export_type([vector_term/0, vector_term_list/0, vector_orddict/0, nonempty_vector_orddict/0]).

-export([new/0,
    get_smaller/2,
    get_smaller_from_id/3,
    insert/3,
    insert_bigger/3,
    sublist/3,
    size/1,
    to_list/1,
    from_list/1,
    first/1,
    last/1,
    filter/2,
    is_concurrent_with_any/2]).


-spec new() -> {[], 0}.
new() ->
    {[], 0}.

%% @doc Get the first appropriate element from the dict according to a monotonically increasing ordering.
%%
%%      `get_smaller(Clock, Dict)' will return `{{DClock, _}=Entry, IsFirst}'',
%%      where Entry is the most recent entry such that `DClock <= Clock'.
%%
%%      In addition, return IsFirst, indicating if the selected entry was the newest entry
%%      in the orddict.
%%
-spec get_smaller(vectorclock(), vector_orddict()) -> {undefined | vector_term(), boolean()}.
get_smaller(Vector, {List, _Size}) ->
    get_smaller_internal(Vector, List, true).

-spec get_smaller_internal(vectorclock(), vector_term_list(), boolean()) -> {undefined | vector_term(), boolean()}.
get_smaller_internal(_Vector, [], IsFirst) ->
    {undefined, IsFirst};
get_smaller_internal(Vector, [{FirstClock, FirstVal} | Rest], IsFirst) ->
    case vectorclock:le(FirstClock, Vector) of
        true ->
            {{FirstClock, FirstVal}, IsFirst};
        false ->
            get_smaller_internal(Vector, Rest, false)
    end.

%% @doc Get the first element from the dict where the clock for some Id is smaller than or equal to Time.
-spec get_smaller_from_id(term(), clock_time(), vector_orddict()) -> undefined | vector_term().
get_smaller_from_id(Id, Time, {List, _Size}) ->
    get_smaller_from_id_internal(Id, Time, List).

-spec get_smaller_from_id_internal(term(), clock_time(), vector_term_list()) -> undefined | vector_term().
get_smaller_from_id_internal(_Id, _Time, []) ->
    undefined;
get_smaller_from_id_internal(Id, Time, [{Clock, Val} | Rest]) ->
    ValTime = vectorclock:get(Id, Clock),
    case ValTime =< Time of
        true ->
            {Clock, Val};
        false ->
            get_smaller_from_id_internal(Id, Time, Rest)
    end.

%% @doc Insert an new entry into the sorted list according to the vectorclock.
-spec insert(vectorclock(), term(), vector_orddict()) -> nonempty_vector_orddict().
insert(Vector, Val, {List, Size}) ->
    insert_internal(Vector, Val, List, Size + 1, []).

-spec insert_internal(vectorclock(), term(), vector_term_list(), non_neg_integer(), vector_term_list()) -> nonempty_vector_orddict().
insert_internal(Vector, Val, [], Size, PrevList) ->
    {lists:reverse([{Vector, Val} | PrevList]), Size};

insert_internal(Vector, Val, [{FirstClock, FirstVal} | Rest], Size, PrevList) ->
    case vectorclock:all_dots_greater(Vector, FirstClock) of
        true ->
            {lists:reverse(PrevList, [{Vector, Val} | [{FirstClock, FirstVal} | Rest]]), Size};
        false ->
            insert_internal(Vector, Val, Rest, Size, [{FirstClock, FirstVal} | PrevList])
    end.

%% @doc Insert a new entry if it is more recent than all other entries.
-spec insert_bigger(vectorclock(), term(), vector_orddict()) -> nonempty_vector_orddict().
insert_bigger(Vector, Val, {List, Size}) ->
    insert_bigger_internal(Vector, Val, List, Size).

-spec insert_bigger_internal(vectorclock(), term(), vector_term_list(), non_neg_integer()) -> nonempty_vector_orddict().
insert_bigger_internal(Vector, Val, [], 0) ->
    {[{Vector, Val}], 1};

insert_bigger_internal(Vector, Val, [{FirstClock, FirstVal} | Rest], Size) ->
    case not vectorclock:le(Vector, FirstClock) of
        true ->
            {[{Vector, Val} | [{FirstClock, FirstVal} | Rest]], Size + 1};
        false ->
            {[{FirstClock, FirstVal} | Rest], Size}
    end.

%% @doc Returns sublist from position Start with length Len.
-spec sublist(vector_orddict(), non_neg_integer(), non_neg_integer()) -> vector_orddict().
sublist({List, _Size}, Start, Len) ->
    Res = lists:sublist(List, Start, Len),
    {Res, length(Res)}.

%% @doc Returns true if the vectorclock is concurrent with at least one of the entries in the vector orddict.
-spec is_concurrent_with_any(vector_orddict(), vectorclock()) -> boolean().
is_concurrent_with_any({List, _Size}, OtherClock) ->
    lists:any(fun({Clock, _Val}) -> vectorclock:conc(Clock, OtherClock) end, List).

%% @doc Returns size of the vector orddict.
-spec size(vector_orddict()) -> non_neg_integer().
size({_List, Size}) ->
    Size.

%% @doc Turns vector orddict into list.
-spec to_list(vector_orddict()) -> vector_term_list().
to_list({List, _Size}) ->
    List.

%% @doc Turns list into vector orddict.
%% If the list is not ordered then it is sorted by the vts.
-spec from_list(vector_term_list()) -> vector_orddict().
from_list(VectorTermList) ->
    IsSorted = is_sorted_high_to_low_by_vts(VectorTermList),
    SortedVectorTermList =
        case IsSorted of
            true -> VectorTermList;
            false -> sort_high_to_low_by_vts(VectorTermList)
        end,
    {SortedVectorTermList, length(SortedVectorTermList)}.

%% High to Low sorting
-spec is_sorted_high_to_low_by_vts(vector_term_list()) -> boolean().
is_sorted_high_to_low_by_vts([]) -> true;
is_sorted_high_to_low_by_vts([_]) -> true;
is_sorted_high_to_low_by_vts([{HighestVts, _} | RestVectorTermList]) ->
    LowerThanAny =
        lists:any(
            fun({LowerVts, _}) ->
                vectorclock:lt(HighestVts, LowerVts)
            end, RestVectorTermList),
    case LowerThanAny of
        true -> false;
        false -> is_sorted_high_to_low_by_vts(RestVectorTermList)
    end.

%% High to Low sorting
-spec sort_high_to_low_by_vts(vector_term_list()) -> vector_term_list().
sort_high_to_low_by_vts(VectorTermList) ->
    sort_high_to_low_by_vts_internal([], VectorTermList).

%% High to Low sorting
-spec sort_high_to_low_by_vts_internal(vector_term_list(), vector_term_list()) -> vector_term_list().
sort_high_to_low_by_vts_internal(SortedVectorTermList, []) -> SortedVectorTermList;
sort_high_to_low_by_vts_internal(SortedVectorTermList, [HighestVectorTerm]) ->
    [HighestVectorTerm | SortedVectorTermList];
sort_high_to_low_by_vts_internal(SortedVectorTermList, [FirstVectorTerm = {FirstVts, _} | UnsortedElementWithVtsList]) ->
    %% Here we check if any vts is greater than the first vts from the unsorted list
    AnyLower =
        lists:any(
            fun({OtherVts, _}) ->
                vectorclock:lt(OtherVts, FirstVts)
            end, UnsortedElementWithVtsList),
    case AnyLower of
        %% If any vts is lower we failed and have to try again putting the first element to the last position in the unsorted list
        true ->
            sort_high_to_low_by_vts_internal(SortedVectorTermList, UnsortedElementWithVtsList ++ [FirstVectorTerm]);
        %% If there are no vts lower then we can append it to the list of sorted vts since all of them must be higher or concurrent because of the sorting
        false ->
            sort_high_to_low_by_vts_internal([FirstVectorTerm | SortedVectorTermList], UnsortedElementWithVtsList)
    end.

%% @doc Returns the first entry.
-spec first(vector_orddict()) -> vector_term().
first({[First | _Rest], _Size}) ->
    First.

%% @doc Returns the last entry.
-spec last(vector_orddict()) -> vector_term().
last({List, _Size}) ->
    lists:last(List).

%% @doc Returns all entries for which the filter function evaluates to true.
-spec filter(fun((vector_term()) -> boolean()), vector_orddict()) -> vector_orddict().
filter(Fun, {List, _Size}) ->
    Result = lists:filter(Fun, List),
    {Result, length(Result)}.

-ifdef(TEST).

vector_oddict_get_smaller_from_id_test() ->
    %% Fill up the vector
    Vdict0 = vector_orddict:new(),
    CT1 = vectorclock:from_list([{dc1, 4}, {dc2, 4}]),
    Vdict1 = vector_orddict:insert(CT1, 1, Vdict0),
    CT2 = vectorclock:from_list([{dc1, 8}, {dc2, 8}]),
    Vdict2 = vector_orddict:insert(CT2, 2, Vdict1),
    CT3 = vectorclock:from_list([{dc1, 1}, {dc2, 10}]),
    Vdict3 = vector_orddict:insert(CT3, 3, Vdict2),

    %% Check you get the correct smaller snapshot
    ?assertEqual(undefined, vector_orddict:get_smaller_from_id(dc1, 0, Vdict0)),
    ?assertEqual(undefined, vector_orddict:get_smaller_from_id(dc1, 0, Vdict3)),
    ?assertEqual({CT3, 3}, vector_orddict:get_smaller_from_id(dc1, 1, Vdict3)),
    ?assertEqual({CT2, 2}, vector_orddict:get_smaller_from_id(dc2, 9, Vdict3)).


vector_orddict_get_smaller_test() ->
    %% Fill up the vector
    Vdict0 = vector_orddict:new(),
    CT1 = vectorclock:from_list([{dc1, 4}, {dc2, 4}]),
    Vdict1 = vector_orddict:insert(CT1, 1, Vdict0),
    CT2 = vectorclock:from_list([{dc1, 8}, {dc2, 8}]),
    Vdict2 = vector_orddict:insert(CT2, 2, Vdict1),
    CT3 = vectorclock:from_list([{dc1, 1}, {dc2, 10}]),
    Vdict3 = vector_orddict:insert(CT3, 3, Vdict2),

    %% Check you get the correct smaller snapshot
    ?assertEqual({undefined, false}, vector_orddict:get_smaller(vectorclock:from_list([{dc1, 0}, {dc2, 0}]), Vdict3)),
    ?assertEqual({undefined, false}, vector_orddict:get_smaller(vectorclock:from_list([{dc1, 1}, {dc2, 6}]), Vdict3)),
    ?assertEqual({{CT1, 1}, false}, vector_orddict:get_smaller(vectorclock:from_list([{dc1, 5}, {dc2, 5}]), Vdict3)),
    ?assertEqual({{CT2, 2}, true}, vector_orddict:get_smaller(vectorclock:from_list([{dc1, 9}, {dc2, 9}]), Vdict3)),
    ?assertEqual({{CT3, 3}, false}, vector_orddict:get_smaller(vectorclock:from_list([{dc1, 3}, {dc2, 11}]), Vdict3)).



vector_orddict_insert_bigger_test() ->
    Vdict0 = vector_orddict:new(),
    %% Insert to empty dict
    CT1 = vectorclock:from_list([{dc1, 4}, {dc2, 4}]),
    Vdict1 = vector_orddict:insert_bigger(CT1, 1, Vdict0),
    ?assertEqual(1, vector_orddict:size(Vdict1)),
    %% Should not insert because smaller
    CT2 = vectorclock:from_list([{dc1, 3}, {dc2, 3}]),
    Vdict2 = vector_orddict:insert_bigger(CT2, 2, Vdict1),
    ?assertEqual(1, vector_orddict:size(Vdict2)),
    %% Should insert because bigger
    CT3 = vectorclock:from_list([{dc1, 6}, {dc2, 10}]),
    Vdict3 = vector_orddict:insert_bigger(CT3, 3, Vdict2),
    ?assertEqual(2, vector_orddict:size(Vdict3)).

vector_orddict_filter_test() ->
    VDict = vector_orddict:from_list([
        {vectorclock:from_list([{dc1, 4}, {dc2, 4}]), snapshot_1},
        {vectorclock:from_list([{dc1, 0}, {dc2, 3}]), snapshot_2},
        {vectorclock:new(), snapshot_3}
    ]),
    ?assertEqual(3, vector_orddict:size(VDict)),

    Result = vector_orddict:filter(fun({Vector, _}) ->
        vectorclock:gt(Vector, vectorclock:new())
                                   end, VDict),
    ?assertEqual(2, vector_orddict:size(Result)),

    Filtered = [
        {vectorclock:from_list([{dc1, 4}, {dc2, 4}]), snapshot_1},
        {vectorclock:from_list([{dc1, 0}, {dc2, 3}]), snapshot_2}
    ],
    ?assertEqual(Filtered, vector_orddict:to_list(Result)).

vector_orddict_conc_test() ->
    VDict = vector_orddict:from_list([
        {vectorclock:from_list([{dc1, 4}, {dc2, 4}]), snapshot_1},
        {vectorclock:from_list([{dc1, 0}, {dc2, 3}]), snapshot_2},
        {vectorclock:new(), snapshot_3}
    ]),
    CT1 = vectorclock:from_list([{dc1, 3}, {dc2, 3}]),
    CT2 = vectorclock:from_list([{dc1, 2}, {dc2, 1}]),

    ?assertEqual(is_concurrent_with_any(VDict, CT1), false),
    ?assertEqual(is_concurrent_with_any(VDict, CT2), true).

-endif.
