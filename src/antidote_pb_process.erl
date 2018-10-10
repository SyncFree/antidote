%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
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
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(antidote_pb_process).

-ifdef(TEST).
-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("antidote.hrl").

-export([process/1]).

-spec process(antidote_pb_codec:request()) -> antidote_pb_codec:response().
process({start_transaction, {Clock, Properties}}) ->
    Response = antidote:start_transaction(Clock, Properties),
    case Response of
        {ok, TxId} -> antidote_pb_codec:encode(start_transaction_response,
                                             {ok, TxId});
        {error, Reason} -> antidote_pb_codec:encode(start_transaction_response,
                                             {error, Reason})
    end;

process({abort_transaction, TxId}) ->
    Response = antidote:abort_transaction(TxId),
    case Response of
        ok -> antidote_pb_codec:encode(operation_response, ok);
        {error, Reason} -> antidote_pb_codec:encode(operation_response,
                                             {error, Reason})
            %% TODO: client initiated abort is not implemented yet
            %% Add the following only after it is implemented to avoid dialyzer errors
            %% ok -> antidote_pb_codec:encode(operation_response, ok),
    end;

process({commit_transaction, TxId}) ->
    Response = antidote:commit_transaction(TxId),
    case Response of
        {error, Reason} -> antidote_pb_codec:encode(commit_response,
                                             {error, Reason});
        {ok, CommitTime} -> antidote_pb_codec:encode(commit_response, {ok, CommitTime})
    end;

process({update_objects, {Updates, TxId}}) ->
    Response = antidote:update_objects(Updates, TxId),
    case Response of
        {error, Reason} -> antidote_pb_codec:encode(operation_response, {error, Reason});
        ok -> antidote_pb_codec:encode(operation_response, ok)
    end;

process({static_update_objects, {Clock, Properties, Updates}}) ->
    Response = antidote:update_objects(Clock, Properties, Updates),
    case Response of
        {error, Reason} ->
            antidote_pb_codec:encode(commit_response,
                                             {error, Reason});
        {ok, CommitTime} ->
            antidote_pb_codec:encode(commit_response, {ok, CommitTime})
    end;

process({read_objects, {Objects, TxId}}) ->
    Response = antidote:read_objects(Objects, TxId),
    case Response of
        {error, Reason} -> antidote_pb_codec:encode(read_objects_response,
                                             {error, Reason});
        {ok, Results} -> antidote_pb_codec:encode(read_objects_response,
                                             {ok, lists:zip(Objects, Results)})
    end;


process({static_read_objects, {Clock, Properties, Objects}}) ->
    Response = antidote:read_objects(Clock, Properties, Objects),
    case Response of
        {error, Reason} ->
            antidote_pb_codec:encode(commit_response,
                                             {error, Reason});
        {ok, Results, CommitTime} ->
            antidote_pb_codec:encode(static_read_objects_response,
                                             {ok, lists:zip(Objects, Results), CommitTime})
    end;

process({create_dc, NodeNames}) ->
    try
      ok = antidote_dc_manager:create_dc(NodeNames), antidote_pb_codec:encode(operation_response, ok)
    catch
     Error:Reason -> %% Some error, return unsuccess. TODO: correct error response
       lager:info("Create DC Failed ~p : ~p", [Error, Reason]),
       antidote_pb_codec:encode(operation_response, {error, create_dc_failed})
    end;

process({get_connection_descriptor}) ->
    try
       {ok, Descriptor} = antidote_dc_manager:get_connection_descriptor(),
       antidote_pb_codec:encode(get_connection_descriptor_resp,{ok, term_to_binary(Descriptor)})
    catch
      Error:Reason -> %% Some error, return unsuccess. TODO: correct error response
        lager:info("Get Conection Descriptor ~p : ~p", [Error, Reason]),
        antidote_pb_codec:encode(get_connection_descriptor_resp,{error, no_clue})
    end;

process({connect_to_dcs, Descriptors}) ->
    try
       ok = antidote_dc_manager:subscribe_updates_from(Descriptors),
       antidote_pb_codec:encode(operation_response, ok)
    catch
      Error:Reason -> %% Some error, return unsuccess. TODO: correct error response
        lager:info("Connect to DCs Failed ~p : ~p", [Error, Reason]),
        antidote_pb_codec:encode(operation_response, {error, connect_to_dcs_failed})
    end;

process(Message) ->
  lager:error("Received unhandled message ~p~n", [Message]),
  MessageStr = erlang:iolist_to_binary(io_lib:format("~p", [Message])),
  {error_response, {unknown, <<"Unhandled message ", MessageStr/binary>>}}.
