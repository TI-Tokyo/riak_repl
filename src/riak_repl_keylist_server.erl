%% Riak EnterpriseDS
%% Copyright (c) 2007-2016 Basho Technologies, Inc.  All Rights Reserved.

%% @doc This is the server-side component of the new fullsync strategy
%% introduced in riak 1.1. It is an improvement over the previous strategy in
%% several ways:
%%
%% <ul>
%%   <li>Client and server build keylist in parallel</li>
%%   <li>No useless merkle tree is built</li>
%%   <li>Differences are calculated and transmitted in batches, not all in one
%%   message</li>
%%   <li>Backpressure is introduced in the exchange of differences</li>
%%   <li>Pausing/cancelling the diff is immediate</li>
%% </ul>
%%
%% In addition, the client does the requesting of partition data, which makes
%% this more of a pull model as compared to the legacy strategy, which was more
%% push oriented. The new protocol is outlined below.
%%
%% When the server receives a message to begin a fullsync, it checks that all
%% nodes in the cluster support the new bloom_fold capability, and relays the
%% command to the client. If bloom_fold is not supported by all nodes, it will
%% ignore the command and check again on the next fullsync request.
%%
%% For fullsync, the client builds the partition list and instructs the server
%% to build the keylist for the first partition, while also starting off its own
%% keylist build locally. When *both* builds are complete, the client sends
%% the keylist to the server. The server does the diff and then sends *any*
%% differing keys to the client, using the realtime repl protocol. This is a
%% departure from the legacy protocol in which vector clocks were available
%% for comparison. However, worst case is we try to write stale keys, which
%% will be ignored by the put_fsm. Once all the diffs are sent (and a final
%% ack is received), the client moves onto the next partition, if any.
%%
%% Note that the new key list algorithm uses a bloom fold filter to keep the
%% keys in disk-order to speed up the key-list creation process.
-module(riak_repl_keylist_server).

-behaviour(gen_fsm).

-compile({nowarn_deprecated_function, 
            [{gen_fsm, start_link, 3},
                {gen_fsm, send_event, 2},
                {gen_fsm, sync_send_event, 3},
                {gen_fsm, sync_send_all_state_event, 2},
                {gen_fsm, sync_send_all_state_event, 3}]}).

-include_lib("kernel/include/logger.hrl").

%% API
-export([start_link/6,
        start_fullsync/1,
        start_fullsync/2,
        cancel_fullsync/1,
        pause_fullsync/1,
        resume_fullsync/1
    ]).

%% gen_fsm
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

%% folder
-export([bloom_fold/3]).

%% states
-export([wait_for_partition/2,
         wait_for_partition/3,
         build_keylist/2,
         build_keylist/3,
         wait_keylist/2,
         wait_keylist/3,
         diff_keylist/2,
         diff_keylist/3,
         diff_bloom/2,
         diff_bloom/3]).

-record(state, {
        sitename,
        socket,
        transport,
        work_dir,
        client,
        kl_pid,
        kl_ref,
        kl_fn,
        kl_fh,
        their_kl_fn,
        their_kl_fh,
        partition,
        diff_pid,
        diff_ref,
        stage_start,
        partition_start,
        pool,
        vnode_gets = true,
        diff_batch_size,
        bloom,
        bloom_pid,
        num_diffs,
        generator_paused = false,
        pending_acks = 0,
        ver = w0,
        proto
    }).

%% -define(TRACE(Stmt),Stmt).
-define(TRACE(Stmt),ok).

-define(ACKS_IN_FLIGHT,2).

%% This is currently compared against the number of keys, not really
%% the number of differences, because we don't have a fast way to count
%% the differences before we start generating the diff stream. But, if
%% the number of keys is small, then we know the number of diffs is small
%% too. TODO: when we change the diff generator to use hash trees, revisit
%% this threshold to compare it to the actual number of differences or an
%% estimate of them.
-define(KEY_LIST_THRESHOLD,(1024)).

start_link(SiteName, Transport, Socket, WorkDir, Client, Proto) ->
    gen_fsm:start_link(?MODULE, [SiteName, Transport, Socket, WorkDir, Client, Proto], []).

start_fullsync(Pid) ->
    gen_fsm:send_event(Pid, start_fullsync).

start_fullsync(Pid, Partitions) ->
    gen_fsm:send_event(Pid, {start_fullsync, Partitions}).

cancel_fullsync(Pid) ->
    gen_fsm:send_event(Pid, cancel_fullsync).

pause_fullsync(Pid) ->
    gen_fsm:send_event(Pid, pause_fullsync).

resume_fullsync(Pid) ->
    gen_fsm:send_event(Pid, resume_fullsync).

init([SiteName, Transport, Socket, WorkDir, Client, Proto]) ->
    MinPool = app_helper:get_env(riak_repl, min_get_workers, 5),
    MaxPool = app_helper:get_env(riak_repl, max_get_workers, 100),
    VnodeGets = app_helper:get_env(riak_repl, vnode_gets, true),
    DiffBatchSize = app_helper:get_env(riak_repl, diff_batch_size, 100),
    {ok, Pid} = poolboy:start_link([{worker_module, riak_repl_fullsync_worker},
            {worker_args, []},
            {size, MinPool}, {max_overflow, MaxPool}]),
    State = #state{sitename=SiteName, socket=Socket, transport=Transport,
        work_dir=WorkDir, client=Client, pool=Pid, vnode_gets=VnodeGets,
        diff_batch_size=DiffBatchSize, proto=Proto},
    riak_repl_util:schedule_fullsync(),
    {ok, wait_for_partition, State}.

%% Request to start or resume Full Sync
wait_for_partition(Command, State)
        when Command == cancel_fullsync ->
    log_stop(Command, State),
    {stop, normal, State};
wait_for_partition(Command, State)
        when Command == start_fullsync; Command == resume_fullsync ->
    %% annoyingly the server is the one that triggers the fullsync in the old
    %% protocol, so we'll just send it on to the client.
    _ = riak_repl_tcp_server:send(State#state.transport, State#state.socket, Command),
    {next_state, wait_for_partition, State};
wait_for_partition({start_fullsync, _} = Command, State) ->
    _ = riak_repl_tcp_server:send(State#state.transport, State#state.socket,
        Command),
    {next_state, wait_for_partition, State};
%% Full sync has completed
wait_for_partition(fullsync_complete, State) ->
    fullsync_completed_while_waiting(State);
%% Start full-sync of a partition
wait_for_partition({partition, Partition}, State) ->
    wait_for_individual_partition(Partition, State);
%% Unknown event (ignored)
wait_for_partition(Event, State) ->
    ?LOG_DEBUG("Full-sync with site ~p; ignoring event ~p",
        [State#state.sitename, Event]),
    {next_state, wait_for_partition, State}.

build_keylist(Command, State) when Command == cancel_fullsync ->
    log_stop(Command, State),
    {stop, normal, State};
build_keylist(Command, State) when Command == pause_fullsync ->
    perform_pause_fullsync(State),
    {next_state, wait_for_partition, State};
%% Helper has sorted and written keylist to a file
%% @plu server <- s:key-lister: keylist_built
build_keylist({Ref, keylist_built, Size}, State=#state{kl_ref=Ref}) ->
    keylist_built(Ref, Size, State);
%% Error
build_keylist({Ref, {error, Reason}}, #state{transport=Transport,
        socket=Socket, kl_ref=Ref} = State) ->
    ?LOG_WARNING("Full-sync with site ~p; skipping partition ~p because of error ~p",
        [State#state.sitename, State#state.partition, Reason]),
    _ = riak_repl_tcp_server:send(Transport, Socket, {skip_partition, State#state.partition}),
    {next_state, wait_for_partition, State};
build_keylist({_Ref, keylist_built, _Size}, State) ->
    ?LOG_WARNING("Stale keylist_built message received, ignoring"),
    {next_state, build_keylist, State};
build_keylist({_Ref, {error, Reason}}, State) ->
    ?LOG_WARNING("Stale {error, ~p} message received, ignoring", [Reason]),
    {next_state, build_keylist, State};
%% Request to skip specified partition
build_keylist({skip_partition, Partition}, #state{partition=Partition,
        kl_pid=Pid} = State) ->
    ?LOG_WARNING("Full-sync with site ~p; skipping partition ~p as requested by client",
        [State#state.sitename, Partition]),
    catch(riak_repl_fullsync_helper:stop(Pid)),
    {next_state, wait_for_partition, State}.

build_keylist(Command, _From, State) when Command == cancel_fullsync ->
    log_stop(Command, State),
    {stop, normal, ok, State};
build_keylist(Command, _From, State) when Command == pause_fullsync ->
    perform_pause_fullsync(State),
    {next_state, wait_for_partition, State};
%% Helper has sorted and written keylist to a file
%% @plu server <- s:key-lister: keylist_built
build_keylist({Ref, keylist_built, Size}, _From, State=#state{kl_ref=Ref}) ->
    keylist_built(Ref, Size, State);
%% Error
build_keylist({Ref, {error, Reason}}, _From, #state{transport=Transport,
        socket=Socket, kl_ref=Ref} = State) ->
    ?LOG_WARNING("Full-sync with site ~p; skipping partition ~p because of error ~p",
        [State#state.sitename, State#state.partition, Reason]),
    _ = riak_repl_tcp_server:send(Transport, Socket, {skip_partition, State#state.partition}),
    {next_state, wait_for_partition, State};
build_keylist({_Ref, keylist_built, _Size}, _From, State) ->
    ?LOG_WARNING("Stale keylist_built message received, ignoring"),
    {next_state, build_keylist, State};
build_keylist({_Ref, {error, Reason}}, _From, State) ->
    ?LOG_WARNING("Stale {error, ~p} message received, ignoring", [Reason]),
    {next_state, build_keylist, State};
%% Request to skip specified partition
build_keylist({skip_partition, Partition}, _From,
              #state{partition=Partition, kl_pid=Pid} = State) ->
    ?LOG_WARNING("Full-sync with site ~p; skipping partition ~p as requested by client",
        [State#state.sitename, Partition]),
    catch(riak_repl_fullsync_helper:stop(Pid)),
    {next_state, wait_for_partition, State}.

wait_for_partition(Command, _From, State) when Command == cancel_fullsync ->
    log_stop(Command, State),
    {stop, normal, ok, State};
wait_for_partition(Command, _From, State)
        when Command == start_fullsync; Command == resume_fullsync ->
    %% annoyingly the server is the one that triggers the fullsync in the old
    %% protocol, so we'll just send it on to the client.
    _ = riak_repl_tcp_server:send(State#state.transport, State#state.socket, Command),
    {next_state, wait_for_partition, State};
wait_for_partition({start_fullsync, _} = Command, _From, State) ->
    _ = riak_repl_tcp_server:send(State#state.transport,
                                  State#state.socket,
                                  Command),
    {next_state, wait_for_partition, State};
%% Full sync has completed
wait_for_partition(fullsync_complete, _From, State) ->
    fullsync_completed_while_waiting(State);
wait_for_partition({partition, Partition}, _From, State) ->
    wait_for_individual_partition(Partition, State);
%% Unknown event (ignored)
wait_for_partition(Event, _From, State) ->
    ?LOG_DEBUG("Full-sync with site ~p; ignoring event ~p",
        [State#state.sitename, Event]),
    {next_state, wait_for_partition, State}.

wait_keylist(Command, State) when Command == cancel_fullsync ->
    log_stop(Command, State),
    {stop, normal, State};
wait_keylist(Command, State) when Command == pause_fullsync ->
    perform_pause_fullsync(State),
    {next_state, wait_for_partition, State};
wait_keylist(kl_wait, State) ->
    %% ack the keylist chunks we've received so far
    %% @plu    server -> client: kl_ack
    _ = riak_repl_tcp_server:send(State#state.transport, State#state.socket, kl_ack),
    {next_state, wait_keylist, State};
%% I have recieved a chunk of the keylist
wait_keylist({kl_hunk, Hunk}, State) ->
    kl_hunk(Hunk, State);
%% the client has finished sending the keylist
wait_keylist(kl_eof, State) ->
    kl_eof(State);
wait_keylist({skip_partition, Partition}, #state{partition=Partition} = State) ->
    ?LOG_WARNING("Full-sync with site ~p; skipping partition ~p as requested by client",
        [State#state.sitename, Partition]),
    {next_state, wait_for_partition, State}.

wait_keylist(Command, _From, State) when Command == cancel_fullsync ->
    log_stop(Command, State),
    {stop, normal, ok, State};
wait_keylist(Command, _From, State) when Command == pause_fullsync ->
    perform_pause_fullsync(State),
    {next_state, wait_for_partition, State};
wait_keylist(kl_wait, _From, State) ->
    _ = riak_repl_tcp_server:send(State#state.transport,
                                  State#state.socket,
                                  kl_ack),
    {next_state, wait_keylist, State};
%% I have recieved a chunk of the keylist
wait_keylist({kl_hunk, Hunk}, _From, State) ->
    kl_hunk(Hunk, State);
%% the client has finished sending the keylist
wait_keylist(kl_eof, _From, State) ->
    kl_eof(State).

%% ----------------------------------- non bloom-fold -----------------------
%% diff_keylist states

diff_keylist(Command, State) when Command == cancel_fullsync ->
    log_stop(Command, State),
    {stop, normal, State};
diff_keylist(Command, State) when Command == pause_fullsync ->
    perform_pause_fullsync(State),
    {next_state, wait_for_partition, State};
%% @plu server <-- diff_stream : merkle_diff
diff_keylist({Ref, {merkle_diff, {{B, K}, _VClock}}}, #state{
        transport=Transport, socket=Socket, diff_ref=Ref, pool=Pool, ver=Ver} = State) ->
    Worker = poolboy:checkout(Pool, true, infinity),
    case State#state.vnode_gets of
        true ->
            %% do a direct get against the vnode, not a regular riak client
            %% get().
            ok = riak_repl_fullsync_worker:do_get(Worker, B, K, Transport, Socket, Pool,
                                                  State#state.partition, Ver);
        _ ->
            ok = riak_repl_fullsync_worker:do_get(Worker, B, K, Transport, Socket, Pool,
                                                  Ver)
    end,
    {next_state, diff_keylist, State};
%% @plu server <-- key-lister: diff_paused
diff_keylist({Ref, diff_paused}, #state{socket=Socket, transport=Transport,
        partition=Partition, diff_ref=Ref, pending_acks=PendingAcks0} = State) ->
    %% request ack from client
    _ = riak_repl_tcp_server:send(Transport, Socket, {diff_ack, Partition}),
    PendingAcks = PendingAcks0+1,
    %% If we have already received the ack for the previous batch, we immediately
    %% resume the generator, otherwise we wait for the ack from the client. We'll
    %% have at most ACKS_IN_FLIGHT windows of differences in flight.
    WorkerPaused = case PendingAcks < ?ACKS_IN_FLIGHT of
                       true ->
                           %% another batch can be sent immediately
                           State#state.diff_pid ! {Ref, diff_resume},
                           false;
                       false ->
                           %% already ACKS_IN_FLIGHT batches out. Don't resume yet.
                           true
                   end,
    {next_state, diff_keylist, State#state{pending_acks=PendingAcks,
                                           generator_paused=WorkerPaused}};
%% @plu server <-- client: diff_ack
diff_keylist({diff_ack, Partition}, #state{partition=Partition, diff_ref=Ref,
                                           generator_paused=WorkerPaused,
                                           pending_acks=PendingAcks0} = State) ->
    %% That's one less "pending" ack from the client. Tell client to keep going.
    PendingAcks = PendingAcks0-1,
    %% If the generator was paused, resume it. That would happen if there are already
    %% ACKS_IN_FLIGHT batches in flight. Better to check "paused" state than guess by
    %% pending acks count.
    case WorkerPaused of
        true ->
            State#state.diff_pid ! {Ref, diff_resume},
            ok;
        false ->
            ok
    end,
    {next_state, diff_keylist, State#state{pending_acks=PendingAcks,generator_paused=false}};
diff_keylist({Ref, diff_done}, #state{diff_ref=Ref} = State) ->
    ?LOG_INFO("Full-sync with site ~p; differences exchanged for partition ~p (done in ~p secs)",
        [State#state.sitename, State#state.partition,
         riak_repl_util:elapsed_secs(State#state.stage_start)]),
    _ = riak_repl_tcp_server:send(State#state.transport, State#state.socket, diff_done),
    {next_state, wait_for_partition, State}.

diff_keylist(Command, _From, State) when Command == cancel_fullsync ->
    log_stop(Command, State),
    {stop, normal, ok, State};
diff_keylist(Command, _From, #state{diff_pid=Pid} = State) when Command == pause_fullsync ->
    riak_repl_fullsync_helper:stop(Pid),
    _ = riak_repl_tcp_server:send(State#state.transport,
                                  State#state.socket,
                                  Command),
    log_stop(Command, State),
    {next_state, wait_for_partition, State};
%% @plu server <-- diff_stream : merkle_diff
diff_keylist({Ref, {merkle_diff, {{B, K}, _VClock}}}, _From,
             #state{transport=Transport, socket=Socket, diff_ref=Ref,
                    pool=Pool, ver=Ver} = State) ->
    Worker = poolboy:checkout(Pool, true, infinity),
    case State#state.vnode_gets of
        true ->
            %% do a direct get against the vnode, not a regular riak client
            %% get().
            ok = riak_repl_fullsync_worker:do_get(Worker, B, K, Transport, Socket, Pool,
                                                  State#state.partition, Ver);
        _ ->
            ok = riak_repl_fullsync_worker:do_get(Worker, B, K, Transport, Socket, Pool,
                                                  Ver)
    end,
    {next_state, diff_keylist, State};
%% @plu server <-- key-lister: diff_paused
diff_keylist({Ref, diff_paused}, _From, #state{socket=Socket, transport=Transport, partition=Partition, diff_ref=Ref, pending_acks=PendingAcks0} = State) ->
    %% request ack from client
    _ = riak_repl_tcp_server:send(Transport, Socket, {diff_ack, Partition}),
    PendingAcks = PendingAcks0+1,
    %% If we have already received the ack for the previous batch, we immediately
    %% resume the generator, otherwise we wait for the ack from the client. We'll
    %% have at most ACKS_IN_FLIGHT windows of differences in flight.
    WorkerPaused = case PendingAcks < ?ACKS_IN_FLIGHT of
                       true ->
                           %% another batch can be sent immediately
                           State#state.diff_pid ! {Ref, diff_resume},
                           false;
                       false ->
                           %% already ACKS_IN_FLIGHT batches out. Don't resume yet.
                           true
                   end,
    {next_state, diff_keylist, State#state{pending_acks=PendingAcks,
                                           generator_paused=WorkerPaused}};
%% @plu server <-- client: diff_ack
diff_keylist({diff_ack, Partition}, _From, #state{partition=Partition, diff_ref=Ref, generator_paused=WorkerPaused, pending_acks=PendingAcks0} = State) ->
    %% That's one less "pending" ack from the client. Tell client to keep going.
    PendingAcks = PendingAcks0-1,
    %% If the generator was paused, resume it. That would happen if there are already
    %% ACKS_IN_FLIGHT batches in flight. Better to check "paused" state than guess by
    %% pending acks count.
    case WorkerPaused of
        true ->
            State#state.diff_pid ! {Ref, diff_resume},
            ok;
        false ->
            ok
    end,
    {next_state, diff_keylist, State#state{pending_acks=PendingAcks,generator_paused=false}};
diff_keylist({Ref, diff_done}, _From, #state{diff_ref=Ref} = State) ->
    ?LOG_INFO("Full-sync with site ~p; differences exchanged for partition ~p (done in ~p secs)",
        [State#state.sitename, State#state.partition,
         riak_repl_util:elapsed_secs(State#state.stage_start)]),
    _ = riak_repl_tcp_server:send(State#state.transport, State#state.socket, diff_done),
    {next_state, wait_for_partition, State}.


%% ----------------------------------- bloom-fold ---------------------------
%% diff_bloom states

diff_bloom(Command, State)
        when Command == cancel_fullsync ->
    log_stop(Command, State),
    {stop, normal, State};
diff_bloom(Command, State)
        when Command == pause_fullsync ->
    _ = riak_repl_tcp_server:send(State#state.transport,
                                  State#state.socket,
                                  Command),
    log_stop(Command, State),
    {next_state, wait_for_partition, State};

%% Sent by streaming difference generator when hashed keys are different.
%% @plu server <- s:helper : merke_diff
diff_bloom({Ref, {merkle_diff, {{{T, B}, K}, _VClock}}}, #state{diff_ref=Ref, bloom=Bloom} = State) ->
    ebloom:insert(Bloom, <<T/binary, B/binary, K/binary>>),
    {next_state, diff_bloom, State};
diff_bloom({Ref, {merkle_diff, {{B, K}, _VClock}}}, #state{diff_ref=Ref, bloom=Bloom} = State) ->
    ebloom:insert(Bloom, <<B/binary, K/binary>>),
    {next_state, diff_bloom, State};

%% Sent by the fullsync_helper "streaming" difference generator when it's done.
%% @plu server <- s:helper : diff_done
diff_bloom({Ref, diff_done}, #state{diff_ref=Ref, partition=Partition, bloom=Bloom} = State) ->
    ?LOG_INFO("Full-sync with site ~p; fullsync difference generator for ~p complete (completed in ~p secs)",
               [State#state.sitename, State#state.partition,
                riak_repl_util:elapsed_secs(State#state.partition_start)]),
    case ebloom:elements(Bloom) == 0 of
        true ->
            ?LOG_INFO("No differences, skipping bloom fold"),
            _ = riak_repl_tcp_server:send(State#state.transport, State#state.socket, diff_done),
            {next_state, wait_for_partition, State};
        false ->
            {ok, Ring} = riak_core_ring_manager:get_my_ring(),
            OwnerNode = riak_core_ring:index_owner(Ring, Partition),

            Self = self(),
            DiffSize = State#state.diff_batch_size,
            BloomSpec = case OwnerNode == node() of
                true ->
                    Bloom;
                false ->
                    {serialized, ebloom:serialize(Bloom)}
            end,
            Worker = fun() ->
                    FoldRef = make_ref(),
                    try riak_core_vnode_master:command_return_vnode(
                            {Partition, OwnerNode},
                            riak_core_util:make_fold_req(
                                fun ?MODULE:bloom_fold/3,
                                {Self, BloomSpec,
                                 State#state.client, State#state.transport,
                                 State#state.socket, DiffSize, DiffSize},
                                false,
                                [{iterator_refresh, true}]),
                            {raw, FoldRef, self()},
                            riak_kv_vnode_master) of
                        {ok, VNodePid} ->
                            MonRef = erlang:monitor(process, VNodePid),
                            receive
                                {FoldRef, _Reply} ->
                                    %% we don't care about the reply
                                    gen_fsm:send_event(Self,
                                                       {Ref, diff_exchanged});
                                {'DOWN', MonRef, process, VNodePid, normal} ->
                                    ?LOG_WARNING("VNode ~p exited before fold for partition ~p",
                                        [VNodePid, Partition]),
                                    exit({bloom_fold, vnode_exited_before_fold});
                                {'DOWN', MonRef, process, VNodePid, Reason} ->
                                    ?LOG_WARNING("Fold of ~p exited with ~p",
                                                  [Partition, Reason]),
                                    exit({bloom_fold, Reason})
                            end
                    catch exit:{{nodedown, Node}, _GenServerCall} ->
                            %% node died between services check and gen_server:call
                            exit({bloom_fold, {nodedown, Node}})
                    end
            end,
            spawn_link(Worker), %% this isn't the Pid we need because it's just the vnode:fold
            {next_state, diff_bloom, State#state{bloom_pid=undefined}}
    end;

%% @plu server <-- s:helper : diff_paused
%% For bloom folding, we don't want the difference generator to pause at all.
diff_bloom({Ref,diff_paused}, #state{diff_ref=Ref} = State) ->
    ?TRACE(?LOG_INFO("diff_bloom <- diff_keys: {Ref, diff_paused}. resuming diff gen for ~p",
                      [State#state.partition])),
    ?TRACE(?LOG_INFO("diff_bloom -> diff_keys: {Ref, diff_resume}")),
    State#state.diff_pid ! {Ref, diff_resume},
    {next_state, diff_bloom, State};

%% Sent by bloom_folder after a window of diffs have been sent and it paused itself.
%% @plu server <-- bloom_fold: {BloomFoldPid, bloom_paused}
diff_bloom({BFPid,bloom_paused}, #state{socket=Socket, transport=Transport,
        partition=Partition, pending_acks=PendingAcks0} = State) ->
    ?TRACE(?LOG_INFO("diff_bloom <- bloom_paused")),
    %% request ack from client
    _ = riak_repl_tcp_server:send(Transport, Socket, {diff_ack, Partition}),
    PendingAcks = PendingAcks0+1,
    %% If we have already received the ack for the previous batch, we immediately
    %% resume the generator, otherwise we wait for the ack from the client. We'll
    %% have at most ACKS_IN_FLIGHT windows of differences in flight.
    WorkerPaused = case PendingAcks < ?ACKS_IN_FLIGHT of
                       true ->
                           %% another batch can be sent immediately
                           ?TRACE(?LOG_INFO("diff_bloom resuming bloom worker immediately")),
                           ?TRACE(?LOG_INFO("diff_bloom -> ~p : bloom_resume", [BFPid])),
                           BFPid ! bloom_resume,
                           false;
                       false ->
                           %% already ACKS_IN_FLIGHT batches out. Don't resume yet.
                           true
                   end,
    ?TRACE(?LOG_INFO("diff_bloom WorkerPaused = ~p, PendingAcks = ~p", [WorkerPaused, PendingAcks])),
    {next_state, diff_bloom, State#state{pending_acks=PendingAcks,
                                         generator_paused=WorkerPaused,
                                         bloom_pid=BFPid}};

%% @plu server <-- client : diff_ack 'when ready for more
diff_bloom({diff_ack, Partition}, #state{partition=Partition,
                                         generator_paused=WorkerPaused,
                                         pending_acks=PendingAcks0} = State) ->
    %% That's one less "pending" ack from the client. Tell client to keep going.
    PendingAcks = PendingAcks0-1,
    ?TRACE(?LOG_INFO("diff_bloom <- diff_ack: PendingAcks = ~p", [PendingAcks])),
    %% If the generator was paused, resume it. That would happen if there are already
    %% ACKS_IN_FLIGHT batches in flight. Better to check "paused" state than guess by
    %% pending acks count.
    case WorkerPaused of
        true ->
            ?TRACE(?LOG_INFO("diff_bloom resuming bloom fold worker after ACK")),
            ?TRACE(?LOG_INFO("diff_bloom -> ~p : bloom_resume",
                              [State#state.bloom_pid])),
            State#state.bloom_pid ! bloom_resume;
        false ->
            ok
    end,
    {next_state, diff_bloom, State#state{pending_acks=PendingAcks,generator_paused=false}};

%% Sent by the Worker function after the bloom_fold exchanges a partition's worth of diffs
%% with the client.
%% @plu server <- bloom_fold : diff_exchanged 'all done
diff_bloom({Ref,diff_exchanged},  #state{diff_ref=Ref} = State) ->
    %% Tell client that we're done with differences for this partition.
    _ = riak_repl_tcp_server:send(State#state.transport, State#state.socket, diff_done),
    ?LOG_INFO("Full-sync with site ~p; differences exchanged for partition ~p (done in ~p secs)",
               [State#state.sitename, State#state.partition,
                riak_repl_util:elapsed_secs(State#state.stage_start)]),
    %% Wait for another partition.
    {next_state, wait_for_partition, State}.

%% end of bloom states
%% --------------------------------------------------------------------------

%% server <- bloom_fold : diff_obj 'recv a diff object from bloom folder
diff_bloom({diff_obj, RObj}, _From, #state{client=Client, transport=Transport,
                                           socket=Socket, proto=Proto} = State) ->
    case riak_repl_util:maybe_send(RObj, Client, Proto) of
        cancel ->
            ok;
        Objects when is_list(Objects) ->
            V = State#state.ver,
            %% server -> client : fs_diff_obj
            %% binarize here instead of in the send() so that our wire
            %% format for the riak_object is more compact.
            _ = [riak_repl_tcp_server:send(Transport, Socket,
                                           encode_robj(O, V))
                 || O <- Objects],

            EncodedObj = encode_robj(RObj, V),

            _ = riak_repl_tcp_server:send(Transport, Socket, EncodedObj),
            ok
    end,
    {reply, ok, diff_bloom, State}.

-spec encode_robj(riak_object:riak_object(), atom()) -> binary().
encode_robj(RObj, WireVersion) ->
    case riak_object:is_ts(RObj) of
        {true, _DDLVersion} ->
            Partition = ts_partition_index(RObj, riak_object:bucket(RObj)),
            riak_repl_util:encode_obj_msg(ts, {Partition, RObj});
        false ->
            riak_repl_util:encode_obj_msg(WireVersion,{fs_diff_obj,RObj})
    end.

ts_partition_index(RObj, {Table, _}=Bucket) ->
    LK = sext:decode(riak_object:key(RObj)),
    {ok, Mod, DDL} = riak_kv_ts_util:get_table_ddl(Table),
    PK = riak_kv_ts_util:encode_typeval_key(
           riak_ql_ddl:get_partition_key(DDL, LK, Mod)),
    riak_core_util:chash_key({Bucket, PK});
ts_partition_index(_RObj, _Bucket) ->
    %% Timeseries data can only exist in bucket types, but
    %% make dialyzer happy
    logger:error("Timeseries object appears to be in legacy bucket", []),
    <<>>.

%% gen_fsm callbacks

handle_event(_Event, StateName, State) ->
    ?LOG_DEBUG("Full-sync with site ~p; ignoring ~p", [State#state.sitename, _Event]),
    {next_state, StateName, State}.

handle_sync_event(status, _From, StateName, State) ->
    Res = [{state, StateName}] ++
    case StateName of
        wait_for_partition ->
            [];
        _ ->
            [
                {fullsync, State#state.partition},
                {partition_start,
                    riak_repl_util:elapsed_secs(State#state.partition_start)},
                {stage_start,
                    riak_repl_util:elapsed_secs(State#state.stage_start)},
                {get_pool_size,
                    length(gen_fsm:sync_send_all_state_event(State#state.pool,
                            get_all_workers, infinity))}
            ]
    end,
    {reply, Res, StateName, State};
handle_sync_event(stop,_F,_StateName,State) ->
    {stop, normal, ok, State};
handle_sync_event(_Event,_F,StateName,State) ->
    ?LOG_DEBUG("Fullsync with site ~p; ignoring ~p", [State#state.sitename,_Event]),
    {reply, ok, StateName, State}.

handle_info(_I, StateName, State) ->
    ?LOG_INFO("Full-sync with site ~p; ignoring ~p", [State#state.sitename, _I]),
    {next_state, StateName, State}.

terminate(_Reason, _StateName, State) ->
    catch(ok = riak_repl_fullsync_helper:stop(State#state.kl_pid)),
    catch(_ = file:close(State#state.their_kl_fh)),
    %% Clean up the working directory on crash/exit
    Cmd = lists:flatten(io_lib:format("rm -rf ~s",
                                      [State#state.work_dir])),
    _ = os:cmd(Cmd),
    poolboy:stop(State#state.pool),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% internal funtions

log_stop(Command, State) ->
    ?LOG_INFO("Full-sync with site ~p; ~s at partition ~p (after ~p secs)",
        [State#state.sitename, command_verb(Command), State#state.partition,
            riak_repl_util:elapsed_secs(State#state.partition_start)]).

command_verb(cancel_fullsync) ->
    "cancelled";
command_verb(pause_fullsync) ->
    "paused".

%% This folder will send batches of differences to the client. Each batch is "WinSz"
%% riak objects. After a batch is sent, it will pause itself and wait to be resumed
%% by receiving "bloom_resume".
bloom_fold(BK, V, {MPid, {serialized, SBloom}, Client, Transport, Socket, NSent, WinSz}) ->
    {ok, Bloom} = ebloom:deserialize(SBloom),
    bloom_fold(BK, V, {MPid, Bloom, Client, Transport, Socket, NSent, WinSz});
bloom_fold({B, K}, V, {MPid, Bloom, Client, Transport, Socket, 0, WinSz} = Acc) ->
    Monitor = erlang:monitor(process, MPid),
    ?TRACE(?LOG_INFO("bloom_fold -> MPid(~p) : bloom_paused", [MPid])),
    gen_fsm:send_event(MPid, {self(), bloom_paused}),
    %% wait for a message telling us to stop, or to continue.
    %% TODO do this more correctly when there's more time.
    receive
        {'$gen_call', From, stop} ->
            riak_core_gen_server:reply(From, ok),
            erlang:demonitor(Monitor, [flush]),
            Acc;
        bloom_resume ->
            ?TRACE(?LOG_INFO("bloom_fold <- MPid(~p) : bloom_resume", [MPid])),
            erlang:demonitor(Monitor, [flush]),
            bloom_fold({B,K}, V, {MPid, Bloom, Client, Transport, Socket, WinSz, WinSz});
        {'DOWN', Monitor, process, MPid, _Reason} ->
            throw(receiver_down);
        _Other ->
            erlang:demonitor(Monitor, [flush]),
            ?TRACE(?LOG_INFO("bloom_fold <- ? : ~p", [_Other]))
    end;
bloom_fold({{T, B}, K}, V, {MPid, Bloom, Client, Transport, Socket, NSent0, WinSz}) ->
    NSent = case ebloom:contains(Bloom, <<T/binary, B/binary, K/binary>>) of
                true ->
                    case (catch riak_object:from_binary({T,B},K,V)) of
                        {'EXIT', _} ->
                            ok;
                        RObj ->
                            gen_fsm:sync_send_event(MPid,
                                                    {diff_obj, RObj},
                                                    infinity)
                    end,
                    NSent0 - 1;
                false ->
                    ok,
                    NSent0
            end,
    {MPid, Bloom, Client, Transport, Socket, NSent, WinSz};
bloom_fold({B, K}, V, {MPid, Bloom, Client, Transport, Socket, NSent0, WinSz}) ->
    NSent = case ebloom:contains(Bloom, <<B/binary, K/binary>>) of
                true ->
                    case (catch riak_object:from_binary(B,K,V)) of
                        {'EXIT', _} ->
                            ok;
                        RObj ->
                            gen_fsm:sync_send_event(MPid,
                                                    {diff_obj, RObj},
                                                    infinity)
                    end,
                    NSent0 - 1;
                false ->
                    ok,
                    NSent0
            end,
    {MPid, Bloom, Client, Transport, Socket, NSent, WinSz}.

wait_for_individual_partition(Partition, State=#state{work_dir=WorkDir}) ->
    ?LOG_INFO("Full-sync with site ~p; doing fullsync for ~p",
               [State#state.sitename, Partition]),
    ?LOG_INFO("Full-sync with site ~p; building keylist for ~p",
               [State#state.sitename, Partition]),
    %% client wants keylist for this partition
    TheirKeyListFn = riak_repl_util:keylist_filename(WorkDir, Partition, theirs),
    KeyListFn = riak_repl_util:keylist_filename(WorkDir, Partition, ours),
    {ok, KeyListPid} = riak_repl_fullsync_helper:start_link(self()),
    {ok, KeyListRef} = riak_repl_fullsync_helper:make_keylist(KeyListPid,
                                                              Partition,
                                                              KeyListFn),
    {next_state, build_keylist, State#state{kl_pid=KeyListPid,
                                            kl_ref=KeyListRef, kl_fn=KeyListFn,
                                            partition=Partition,
                                            partition_start=os:timestamp(),
                                            stage_start=os:timestamp(),
                                            pending_acks=0, generator_paused=false,
                                            their_kl_fn=TheirKeyListFn,
                                            their_kl_fh=undefined}}.

fullsync_completed_while_waiting(State) ->
    ?LOG_INFO("Full-sync with site ~p completed", [State#state.sitename]),
    riak_repl_stats:server_fullsyncs(),
    riak_repl_util:schedule_fullsync(),
    {next_state, wait_for_partition, State}.

perform_pause_fullsync(#state{their_kl_fh=FH, kl_pid=KlPid, diff_pid=DiffPid} = State) ->
    %% kill the worker
    case FH of
        undefined ->
            ok;
        _ ->
            %% close and delete the keylist file
            _ = file:close(FH),
            _ = file:delete(State#state.their_kl_fn),
            _ = file:delete(State#state.kl_fn),
            ok
    end,
    _ = riak_repl_tcp_server:send(State#state.transport,
                                  State#state.socket,
                                  pause_fullsync),
    catch(ok = riak_repl_fullsync_helper:stop(KlPid)),
    catch(ok = riak_repl_fullsync_helper:stop(DiffPid)),
    log_stop(pause_fullsync, State).

keylist_built(Ref, Size, State=#state{kl_ref=Ref, socket=Socket, transport=Transport, partition=Partition}) ->
    ?LOG_INFO("Full-sync with site ~p; built keylist for ~p (built in ~p secs)",
        [State#state.sitename, Partition,
         riak_repl_util:elapsed_secs(State#state.stage_start)]),
    %% @plu server -> client: {kl_exchange, P}
    _ = riak_repl_tcp_server:send(Transport, Socket, {kl_exchange, Partition}),
    %% note that num_diffs is being assigned the number of keys, regardless of diffs,
    %% because we don't the number of diffs yet. See TODO: above redarding KEY_LIST_THRESHOLD
    {next_state, wait_keylist, State#state{stage_start=os:timestamp(), num_diffs=Size}}.

kl_hunk(Hunk, #state{their_kl_fh=FH0} = State) ->
    FH = case FH0 of
        undefined ->
            {ok, F} = file:open(State#state.their_kl_fn, [write, raw, binary]),
            F;
        _ ->
            FH0
    end,
    _ = file:write(FH, Hunk),
    {next_state, wait_keylist, State#state{their_kl_fh=FH}}.

kl_eof(#state{their_kl_fh=FH, num_diffs=NumKeys} = State) ->
    case FH of
        undefined ->
            %% client has a blank vnode, write a blank file
            _ = file:write_file(State#state.their_kl_fn, <<>>),
            ok;
        _ ->
            _ = file:sync(FH),
            _ = file:close(FH),
            ok
    end,
    ?LOG_INFO("Full-sync with site ~p; received keylist for ~p (received in ~p secs)",
        [State#state.sitename, State#state.partition,
            riak_repl_util:elapsed_secs(State#state.stage_start)]),
    ?TRACE(?LOG_INFO("Full-sync with site ~p; calculating ~p differences for ~p",
                      [State#state.sitename, NumDKeys, State#state.partition])),
    {ok, Pid} = riak_repl_fullsync_helper:start_link(self()),

    %% check capability of all nodes for bloom fold ability.
    %% Since we are the leader, the fact that we have this
    %% new code means we can only choose to use it if
    %% all nodes have been upgraded to use bloom.
    %%
    %% If you do NOT want to use the bloom fold, you can disable it via the
    %% {bloom_fold, false} app env for riak_repl.
    NextState = case riak_core_capability:get({riak_repl, bloom_fold}, false) andalso
                     app_helper:get_env(riak_repl, bloom_fold, true) of
        true ->
            %% all nodes support bloom, yay

            %% Note: ACKS_IN_FLIGHT not relevant here, this is only the
            %% backpressure for the bloom filter updating
            %%
            %% Setting DiffSize to 0 can cause large message queues, so now we
            %% default it to non-zero. Users can set it back to 0 if they are
            %% brave.
            DiffSize = State#state.diff_batch_size,
            {ok, Bloom} = ebloom:new(NumKeys, 0.01, rand:uniform(1000)),
            diff_bloom;
        false ->
            DiffSize = State#state.diff_batch_size div ?ACKS_IN_FLIGHT,
            Bloom = undefined,
            diff_keylist
    end,

    {ok, Ref} = riak_repl_fullsync_helper:diff_stream(Pid, State#state.partition,
                                                      State#state.kl_fn,
                                                      State#state.their_kl_fn,
                                                      DiffSize),

    ?LOG_INFO("Full-sync with site ~p; using ~p for ~p",
               [State#state.sitename, NextState, State#state.partition]),
    {next_state, NextState, State#state{diff_ref=Ref, bloom=Bloom, diff_pid=Pid, stage_start=os:timestamp()}}.
