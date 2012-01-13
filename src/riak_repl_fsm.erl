%% Riak EnterpriseDS
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
-module(riak_repl_fsm).
-author('Andy Gross <andy@basho.com').
-include("riak_repl.hrl").
-export([common_init/1,
         work_dir/2,
         get_vclocks/2]).

common_init(Socket) ->
    inet:setopts(Socket, ?FSM_SOCKOPTS),
    {ok, Client} = riak:local_client(),
    PI = riak_repl_util:make_peer_info(),
    Partitions = riak_repl_util:get_partitions(PI#peer_info.ring),    
    [{client, Client},
     {partitions, Partitions},
     {my_pi, PI}].

work_dir(Socket, SiteName) ->
    {ok, WorkRoot} = application:get_env(riak_repl, work_dir),
    SiteDir = SiteName ++ "-" ++ riak_repl_util:format_socketaddrs(Socket),
    WorkDir = filename:join(WorkRoot, SiteDir),
    ok = filelib:ensure_dir(filename:join(WorkDir, "empty")),
    {ok, WorkDir}.


get_vclocks(Partition, KeyList) 
  when is_integer(Partition) andalso is_list(KeyList) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    OwnerNode = riak_core_ring:index_owner(Ring, Partition),
    case lists:member(OwnerNode, riak_core_node_watcher:nodes(riak_kv)) of
        true ->
            get_each_vclock({Partition, OwnerNode}, KeyList, []);
        false ->
            {error, node_not_available}
    end.
    

get_each_vclock(_Id, [], Acc) ->
    lists:reverse(Acc);
get_each_vclock(Id, [Key | Rest], Acc) ->
    [Vclock] = riak_kv_vnode:get_vclocks(Id, [Key]),
    get_each_vclock(Id, Rest, [Vclock | Acc]).