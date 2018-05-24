%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Helium Systems, Inc.  All Rights Reserved.
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

-module(test_utils).

-include_lib("eunit/include/eunit.hrl").

-compile({parse_transform, lager_transform}).

-export([at_init_testsuite/0,
         %get_cluster_members/1,
         pmap/2,
         start_node/2,
         connect_cluster/1,
         kill_and_restart_nodes/2,
         kill_nodes/1,
         get_node_name/1,
         descriptors/1,
         web_ports/1,
         plan_and_commit/1,
         do_commit/1,
         try_nodes_ready/3,
         wait_until_nodes_ready/1,
         is_ready/1,
         wait_until_nodes_agree_about_ownership/1,
         staged_join/2,
         brutal_kill_nodes/1,
         restart_nodes/2,
         partition_cluster/2,
         heal_cluster/2,
         join_cluster/1,
         set_up_clusters_common/1]).

at_init_testsuite() ->
%% this might help, might not...
    os:cmd(os:find_executable("epmd") ++ " -daemon"),
    {ok, Hostname} = inet:gethostname(),
    case net_kernel:start([list_to_atom("runner@"++Hostname), shortnames]) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, {{already_started, _}, _}} -> ok
    end.


%get_cluster_members(Node) ->
%    {Node, {ok, Res}} = {Node, rpc:call(Node, plumtree_peer_service_manager, get_local_state, [])},
%    ?SET:value(Res).

pmap(F, [print, Desc, L]) ->
    ct:print("[~s] Start nodes: ~p", [Desc, L]),
    Parent = self(),
    lists:foldl(
        fun(X, N) ->
                spawn_link(fun() ->
                            Parent ! {pmap, N, F(X)}
                    end),
                N+1
        end, 0, L),
    L2 = [receive {pmap, N, R} -> {N, R} end || _ <- L],
    {_, L3} = lists:unzip(lists:keysort(1, L2)),
    L3;
pmap(F, L) ->
    pmap(F, [print, "", L]).


-spec kill_and_restart_nodes([node()], [tuple()]) -> [node()].
kill_and_restart_nodes(NodeList, Config) ->
    NewNodeList = brutal_kill_nodes(NodeList),
    restart_nodes(NewNodeList, Config).

%% when you just can't wait
-spec brutal_kill_nodes([node()]) -> [node()].
brutal_kill_nodes(NodeList) ->
    lists:map(fun(Node) ->
                  lager:info("Killing node ~p", [Node]),
                  OSPidToKill = rpc:call(Node, os, getpid, []),
                  %% try a normal kill first, but set a timer to
                  %% kill -9 after 5 seconds just in case
                  rpc:cast(Node, timer, apply_after,
                       [5000, os, cmd, [io_lib:format("kill -9 ~s", [OSPidToKill])]]),
                  rpc:cast(Node, os, cmd, [io_lib:format("kill -15 ~s", [OSPidToKill])]),
                  Node
              end, NodeList).

-spec kill_nodes([node()]) -> [node()].
kill_nodes(NodeList) ->
    lists:map(fun(Node) ->
                  %% Crash if stopping fails
                  {ok, Name1} = ct_slave:stop(get_node_name(Node)),
                  Name1
              end, NodeList).

-spec restart_nodes([node()], [tuple()]) -> [node()].
restart_nodes(NodeList, Config) ->
    pmap(fun(Node) ->
             start_node(get_node_name(Node), Config),
             ct:print("Waiting until vnodes are restarted at node ~w", [Node]),
             riak_utils:wait_until_ring_converged([Node]),
             time_utils:wait_until(Node, fun wait_init:check_ready/1),
             Node
         end, NodeList).

-spec get_node_name(node()) -> atom().
get_node_name(NodeAtom) ->
    Node = atom_to_list(NodeAtom),
    {match, [{Pos, _Len}]} = re:run(Node, "@"),
    list_to_atom(string:substr(Node, 1, Pos)).

start_node(Name, Config) ->
    CodePath = lists:filter(fun filelib:is_dir/1, code:get_path()),
    %% have the slave nodes monitor the runner node, so they can't outlive it
    NodeConfig = [
            {monitor_master, true},
            {erl_flags, "-smp"}, %% smp for the eleveldb god
            {startup_functions, [
                    {code, set_path, [CodePath]}
                    ]}],
    case ct_slave:start(Name, NodeConfig) of
        {ok, Node} ->
            PrivDir = proplists:get_value(priv_dir, Config),
            NodeDir = filename:join([PrivDir, Node]),

            ct:print("Node dir: ~p", [NodeDir]),

            ok = rpc:call(Node, application, set_env, [lager, log_root, NodeDir]),
            ok = rpc:call(Node, application, load, [lager]),

            ok = rpc:call(Node, application, load, [riak_core]),

            PlatformDir = NodeDir ++ "/data/",
            RingDir = PlatformDir ++ "/ring/",
            NumberOfVNodes = 4,
            filelib:ensure_dir(PlatformDir),
            filelib:ensure_dir(RingDir),

            ok = rpc:call(Node, application, set_env, [riak_core, riak_state_dir, RingDir]),
            ok = rpc:call(Node, application, set_env, [riak_core, ring_creation_size, NumberOfVNodes]),

            ok = rpc:call(Node, application, set_env, [riak_core, platform_data_dir, PlatformDir]),
            ok = rpc:call(Node, application, set_env, [riak_core, handoff_port, web_ports(Name) + 3]),

            ok = rpc:call(Node, application, set_env, [riak_core, schema_dirs, ["../../_build/default/rel/antidote/lib/"]]),

            ok = rpc:call(Node, application, set_env, [riak_api, pb_port, web_ports(Name) + 2]),
            ok = rpc:call(Node, application, set_env, [riak_api, pb_ip, "127.0.0.1"]),

            ok = rpc:call(Node, application, load, [antidote]),
            ok = rpc:call(Node, application, set_env, [antidote, pubsub_port, web_ports(Name) + 1]),
            ok = rpc:call(Node, application, set_env, [antidote, logreader_port, web_ports(Name)]),
            ok = rpc:call(Node, application, set_env, [antidote, metrics_port, web_ports(Name) + 4]),

            {ok, _} = rpc:call(Node, application, ensure_all_started, [antidote]),
            ct:print("Node ~p started", [Node]),

            Node;
        {error, Reason, Node} ->
            ct:print("Error starting node ~w, reason ~w, will retry", [Node, Reason]),
            ct_slave:stop(Name),
            time_utils:wait_until_offline(Node),
            start_node(Name, Config)
    end.

partition_cluster(ANodes, BNodes) ->
    pmap(fun({Node1, Node2}) ->
                true = rpc:call(Node1, erlang, set_cookie, [Node2, canttouchthis]),
                true = rpc:call(Node1, erlang, disconnect_node, [Node2]),
                ok = time_utils:wait_until_disconnected(Node1, Node2)
        end,
         [{Node1, Node2} || Node1 <- ANodes, Node2 <- BNodes]),
    ok.

heal_cluster(ANodes, BNodes) ->
    GoodCookie = erlang:get_cookie(),
    pmap(fun({Node1, Node2}) ->
                true = rpc:call(Node1, erlang, set_cookie, [Node2, GoodCookie]),
                ok = time_utils:wait_until_connected(Node1, Node2)
        end,
         [{Node1, Node2} || Node1 <- ANodes, Node2 <- BNodes]),
    ok.

connect_cluster(Nodes) ->
  Clusters = [[Node] || Node <- Nodes],
  ct:pal("Connecting DC clusters..."),

  pmap(fun(Cluster) ->
              Node1 = hd(Cluster),
              ct:print("Waiting until vnodes start on node ~p", [Node1]),
              time_utils:wait_until_registered(Node1, inter_dc_pub),
              time_utils:wait_until_registered(Node1, inter_dc_query_receive_socket),
              time_utils:wait_until_registered(Node1, inter_dc_query_response_sup),
              time_utils:wait_until_registered(Node1, inter_dc_query),
              time_utils:wait_until_registered(Node1, inter_dc_sub),
              time_utils:wait_until_registered(Node1, meta_data_sender_sup),
              time_utils:wait_until_registered(Node1, meta_data_manager_sup),
              ok = rpc:call(Node1, inter_dc_manager, start_bg_processes, [stable]),
              ok = rpc:call(Node1, logging_vnode, set_sync_log, [true])
          end, Clusters),
    Descriptors = descriptors(Clusters),
    ct:print("the clusters ~w", [Clusters]),
    Res = [ok || _ <- Clusters],
    pmap(fun(Cluster) ->
              Node = hd(Cluster),
              ct:print("Making node ~p observe other DCs...", [Node]),
              %% It is safe to make the DC observe itself, the observe() call will be ignored silently.
              Res = rpc:call(Node, inter_dc_manager, observe_dcs_sync, [Descriptors])
          end, Clusters),
    pmap(fun(Cluster) ->
              Node = hd(Cluster),
              ok = rpc:call(Node, inter_dc_manager, dc_successfully_started, [])
          end, Clusters),
    ct:pal("DC clusters connected!").

descriptors(Clusters) ->
  lists:map(fun(Cluster) ->
    {ok, Descriptor} = rpc:call(hd(Cluster), inter_dc_manager, get_descriptor, []),
    Descriptor
  end, Clusters).


web_ports(dev1) ->
    10015;
web_ports(dev2) ->
    10025;
web_ports(dev3) ->
    10035;
web_ports(dev4) ->
    10045.

%% Build clusters
join_cluster(Nodes) ->
    ct:print("Joining: ~p", [Nodes]),
    %% Ensure each node owns 100% of it's own ring
    [?assertEqual([Node], riak_utils:owners_according_to(Node)) || Node <- Nodes],
    ct:print("Owning ensured"),
    %% Join nodes
    [Node1|OtherNodes] = Nodes,
    case OtherNodes of
        [] ->
            %% no other nodes, nothing to join/plan/commit
            ok;
        _ ->
            %% ok do a staged join and then commit it, this eliminates the
            %% large amount of redundant handoff done in a sequential join
            [staged_join(Node, Node1) || Node <- OtherNodes],
            plan_and_commit(Node1),
            try_nodes_ready(Nodes, 3, 500)
    end,
    ct:print("Join success"),

    ?assertEqual(ok, wait_until_nodes_ready(Nodes)),

    ct:print("Wait until nodes ready finished"),

    %% Ensure each node owns a portion of the ring
    wait_until_nodes_agree_about_ownership(Nodes),
    ct:print("Wait until nodes agreed woner finished"),

    ?assertEqual(ok, riak_utils:wait_until_no_pending_changes(Nodes)),
    ct:print("Wait until no pending finished"),
    riak_utils:wait_until_ring_converged(Nodes),
    ct:print("Wait until converged finished"),
    time_utils:wait_until(hd(Nodes), fun wait_init:check_ready/1),
    ct:print("another Wait until finished"),
    ok.


%% @doc Have `Node' send a join request to `PNode'
staged_join(Node, PNode) ->
    timer:sleep(5000),
    R = rpc:call(Node, riak_core, staged_join, [PNode]),
    lager:info("[join] ~p to (~p): ~p", [Node, PNode, R]),
    ?assertEqual(ok, R),
    ok.

plan_and_commit(Node) ->
    timer:sleep(5000),
    lager:info("planning and committing cluster join"),
    case rpc:call(Node, riak_core_claimant, plan, []) of
        {error, ring_not_ready} ->
            lager:info("plan: ring not ready"),
            timer:sleep(5000),
            riak_utils:maybe_wait_for_changes(Node),
            plan_and_commit(Node);
        {ok, _, _} ->
            do_commit(Node)
    end.
do_commit(Node) ->
    lager:info("Committing"),
    case rpc:call(Node, riak_core_claimant, commit, []) of
        {error, plan_changed} ->
            lager:info("commit: plan changed"),
            timer:sleep(100),
            riak_utils:maybe_wait_for_changes(Node),
            plan_and_commit(Node);
        {error, ring_not_ready} ->
            lager:info("commit: ring not ready"),
            timer:sleep(100),
            riak_utils:maybe_wait_for_changes(Node),
            do_commit(Node);
        {error, nothing_planned} ->
            %% Assume plan actually committed somehow
            ok;
        ok ->
            ok
    end.

try_nodes_ready([Node1 | _Nodes], 0, _SleepMs) ->
      lager:info("Nodes not ready after initial plan/commit, retrying"),
      plan_and_commit(Node1);
try_nodes_ready(Nodes, N, SleepMs) ->
  ReadyNodes = [Node || Node <- Nodes, is_ready(Node) =:= true],
  case ReadyNodes of
      Nodes ->
          ok;
      _ ->
          timer:sleep(SleepMs),
          try_nodes_ready(Nodes, N-1, SleepMs)
  end.


%% @doc Given a list of nodes, wait until all nodes are considered ready.
%%      See {@link wait_until_ready/1} for definition of ready.
wait_until_nodes_ready(Nodes) ->
    lager:info("Wait until nodes are ready : ~p", [Nodes]),
    [?assertEqual(ok, time_utils:wait_until(Node, fun is_ready/1)) || Node <- Nodes],
    ok.

%% @private
is_ready(Node) ->
    case rpc:call(Node, riak_core_ring_manager, get_raw_ring, []) of
        {ok, Ring} ->
            case lists:member(Node, riak_core_ring:ready_members(Ring)) of
                true -> true;
                false -> {not_ready, Node}
            end;
        Other ->
            Other
    end.

wait_until_nodes_agree_about_ownership(Nodes) ->
    lager:info("Wait until nodes agree about ownership ~p", [Nodes]),
    Results = [ time_utils:wait_until_owners_according_to(Node, Nodes) || Node <- Nodes ],
    ?assert(lists:all(fun(X) -> ok =:= X end, Results)).



%% Build clusters for all test suites.
set_up_clusters_common(Config) ->
   StartDCs = fun(Nodes) ->
                      pmap(fun(N) ->
                              start_node(N, Config)
                           end, [print, "DC", Nodes])
                  end,


    {Time, Clusters} = timer:tc(fun() -> pmap(fun(N) ->
                  StartDCs(N)
              end, [print, "Cluster", [[dev1, dev2], [dev3], [dev4]]]) end),

    ct:print("Time for clusterinit: ~p s", [Time div 1000]),

    ct:print("-------------------GO-------------------------------"),

   [Cluster1, Cluster2, Cluster3] = Clusters,
   %% Do not join cluster if it is already done
   case riak_utils:owners_according_to(hd(Cluster1)) of % @TODO this is an adhoc check
     Cluster1 ->
         ok; % No need to build Cluster
     _ ->
         ct:print("Joining ~p", [Clusters]),
        [join_cluster(Cluster) || Cluster <- Clusters],
         ct:print("-----------------joined clusers--------------------------------"),
        Clusterheads = [hd(Cluster) || Cluster <- Clusters],
        connect_cluster(Clusterheads),
         ct:print("-----------------connected clusers--------------------------------")
   end,

    ct:print("-----------------FIN--------------------------------"),
   [Cluster1, Cluster2, Cluster3].
