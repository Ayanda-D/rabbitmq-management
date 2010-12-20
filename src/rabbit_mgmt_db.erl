%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ Management Plugin.
%%
%%   The Initial Developer of the Original Code is VMware, Inc.
%%   Copyright (c) 2007-2010 VMware, Inc.  All rights reserved.
-module(rabbit_mgmt_db).

-include_lib("rabbit_common/include/rabbit.hrl").

-behaviour(gen_server).

-export([start_link/0]).

-export([get_queues/1, get_queue/1, get_exchanges/1, get_exchange/1,
         get_connections/0, get_connection/1, get_overview/1,
         get_overview/0, get_channels/0, get_channel/1]).

%% TODO can these not be exported any more?
-export([pget/2, add/2, rates/5]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-record(state, {tables}).
-define(FINE_STATS_TYPES, [channel_queue_stats, channel_exchange_stats,
                           channel_queue_exchange_stats]).
-define(TABLES, [queue_stats, connection_stats, channel_stats, consumers] ++
            ?FINE_STATS_TYPES).

-define(DELIVER_GET, [deliver, deliver_no_ack, get, get_no_ack]).
-define(FINE_STATS, [publish, ack, deliver_get] ++ ?DELIVER_GET).

-define(
   FINE_STATS_CHANNEL_LIST,
   [{channel_queue_stats,   [channel], message_stats, channel},
    {channel_exchange_stats,[channel], message_stats, channel}]).

-define(
   FINE_STATS_CHANNEL_DETAIL,
   [{channel_queue_stats,    [channel],           message_stats, channel},
    {channel_exchange_stats, [channel],           message_stats, channel},
    {channel_exchange_stats, [channel, exchange], publishes,     channel},
    {channel_queue_stats,    [channel, queue],    deliveries,    channel}]).

-define(
   FINE_STATS_QUEUE_LIST,
   [{channel_queue_stats,          [queue], message_stats, queue},
    {channel_queue_exchange_stats, [queue], message_stats, queue}]).

-define(
   FINE_STATS_QUEUE_DETAIL,
   [{channel_queue_stats,          [queue],           message_stats, queue},
    {channel_queue_exchange_stats, [queue],           message_stats, queue},
    {channel_queue_stats,          [queue, channel],  deliveries, queue},
    {channel_queue_exchange_stats, [queue, exchange], incoming, queue}]).

-define(
   FINE_STATS_EXCHANGE_LIST,
   [{channel_exchange_stats,       [exchange], message_stats_in,  exchange},
    {channel_queue_exchange_stats, [exchange], message_stats_out, exchange}]).

-define(
   FINE_STATS_EXCHANGE_DETAIL,
   [{channel_exchange_stats,       [exchange], message_stats_in,   exchange},
    {channel_queue_exchange_stats, [exchange], message_stats_out,  exchange},
    {channel_exchange_stats,       [exchange, channel],  incoming, exchange},
    {channel_queue_exchange_stats, [exchange, queue],    outgoing, exchange}]).

-define(FINE_STATS_NONE, []).

%%----------------------------------------------------------------------------

start_link() ->
    case gen_server:start_link({global, ?MODULE}, ?MODULE, [], []) of
        {error, {already_started, Pid}} ->
            rabbit_log:info(
              "Statistics database already registered at ~p.~n", [Pid]),
            ignore;
        Else ->
            rabbit_log:info(
              "Statistics database started.~n", []),
            Else
    end.

get_queues(Qs)         -> safe_call({get_queues, Qs, list}, Qs).
get_queue(Q)           -> safe_call({get_queues, [Q], detail}, [Q]).
get_exchanges(Xs)      -> safe_call({get_exchanges, Xs, list}, Xs).
get_exchange(X)        -> safe_call({get_exchanges, [X], detail}, [X]).
get_connections()      -> safe_call(get_connections).
get_connection(Name)   -> safe_call({get_connection, Name}).
get_channels()         -> safe_call(get_channels).
get_channel(Name)      -> safe_call({get_channel, Name}).
get_overview(Username) -> safe_call({get_overview, Username}).
get_overview()         -> safe_call({get_overview, all}).

safe_call(Term) -> safe_call(Term, []).

safe_call(Term, Item) ->
    try
        gen_server:call({global, ?MODULE}, Term, infinity)
    catch exit:{noproc, _} -> Item
    end.

%%----------------------------------------------------------------------------

pget(Key, List) -> pget(Key, List, unknown).

pget(Key, List, Default) -> proplists:get_value(Key, List, Default).

pset(Key, Value, List) -> [{Key, Value} | proplists:delete(Key, List)].

pid(Pid) when is_pid(Pid) -> rabbit_mgmt_format:pid(Pid).

id(List) ->
    case pget(name, List) of
        Name = #resource{} -> Name;
        _                  -> rabbit_mgmt_format:pid(pget(pid, List))
    end.

add(unknown, _) -> unknown;
add(_, unknown) -> unknown;
add(A, B)       -> A + B.

lookup_element(Table, Key) -> lookup_element(Table, Key, 2).

lookup_element(Table, Key, Pos) ->
    try ets:lookup_element(Table, Key, Pos)
    catch error:badarg -> []
    end.

result_or_error([]) -> error;
result_or_error(S)  -> S.

rates(Stats, Timestamp, OldStats, OldTimestamp, Keys) ->
    Stats ++ [R || Key <- Keys,
                   R   <- [rate(Stats, Timestamp, OldStats, OldTimestamp, Key)],
                   R =/= unknown].

rate(Stats, Timestamp, OldStats, OldTimestamp, Key) ->
    case OldTimestamp == [] orelse not proplists:is_defined(Key, OldStats) of
        true  -> unknown;
        false -> Diff = pget(Key, Stats) - pget(Key, OldStats),
                 Name = details_key(Key),
                 Rate = Diff / (timer:now_diff(Timestamp, OldTimestamp) /
                                    1000000),
                 {Name, [{rate, Rate},
                         {last_event,
                          rabbit_mgmt_format:timestamp_ms(Timestamp)}]}
    end.

sum(List, Keys) ->
    lists:foldl(fun (Stats, Acc) ->
                        [{Key, Val + pget(Key, Stats, 0)} || {Key, Val} <- Acc]
                end,
                [{Key, 0} || Key <- Keys], List).

%% List = [{ [{channel, Pid}, ...], [{deliver, 123}, ...] } ...]
group_sum([], List) ->
    lists:foldl(fun ({_, Item1}, Item0) ->
                        gs_update(Item0, Item1)
                end, [], List);

group_sum([Group | Groups], List) ->
    D = lists:foldl(
          fun (Next = {Ids, _}, Dict) ->
                  Id = {Group, pget(Group, Ids)},
                  dict:update(Id, fun(Cur) -> [Next | Cur] end, [Next], Dict)
          end, dict:new(), List),
    dict:map(fun(_, SubList) ->
                     group_sum(Groups, SubList)
             end, D).

gs_update(Item0, Item1) ->
    Keys = lists:usort([K || {K, _} <- Item0 ++ Item1]),
    [{Key, gs_update_add(Key, pget(Key, Item0), pget(Key, Item1))} ||
        Key <- Keys].

gs_update_add(Key, Item0, Item1) ->
    case is_details(Key) of
        true  ->
            I0 = if_unknown(Item0, []),
            I1 = if_unknown(Item1, []),
            [{rate,       pget(rate, I0, 0) + pget(rate, I1, 0)},
             {last_event, erlang:max(pget(last_event, I0, 0),
                                     pget(last_event, I1, 0))}];
        false ->
            I0 = if_unknown(Item0, 0),
            I1 = if_unknown(Item1, 0),
            I0 + I1
    end.

if_unknown(unknown, Def) -> Def;
if_unknown(Val,    _Def) -> Val.

%%----------------------------------------------------------------------------

init([]) ->
    {ok, #state{tables = orddict:from_list(
                           [{Key, ets:new(anon, [private])} ||
                               Key <- ?TABLES])}}.

handle_call({get_queues, Qs0, Mode}, _From, State = #state{tables = Tables}) ->
    FineSpecs = case Mode of
                    list   -> ?FINE_STATS_QUEUE_LIST;
                    detail -> ?FINE_STATS_QUEUE_DETAIL
                end,
    Qs1 = queue_stats(Qs0, FineSpecs, Tables),
    Qs2 = [[{messages, add(pget(messages_ready, Q),
                           pget(messages_unacknowledged, Q))} | Q] || Q <- Qs1],
    {reply, Qs2, State};

handle_call({get_exchanges, Xs, Mode}, _From,
            State = #state{tables = Tables}) ->
    FineSpecs = case Mode of
                    list   -> ?FINE_STATS_EXCHANGE_LIST;
                    detail -> ?FINE_STATS_EXCHANGE_DETAIL
                end,
    {reply, exchange_stats(Xs, FineSpecs, Tables), State};

handle_call(get_connections, _From, State = #state{tables = Tables}) ->
    Conns = created_events(connection_stats, Tables),
    {reply, connection_stats(Conns, Tables), State};

handle_call({get_connection, Name}, _From, State = #state{tables = Tables}) ->
    Conns = created_event(Name, connection_stats, Tables),
    [Res] = connection_stats(Conns, Tables),
    {reply, result_or_error(Res), State};

handle_call(get_channels, _From, State = #state{tables = Tables}) ->
    Chs = created_events(channel_stats, Tables),
    {reply, channel_stats(Chs, ?FINE_STATS_CHANNEL_LIST, Tables), State};

handle_call({get_channel, Name}, _From, State = #state{tables = Tables}) ->
    Chs = created_event(Name, channel_stats, Tables),
    [Res] = channel_stats(Chs, ?FINE_STATS_CHANNEL_DETAIL, Tables),
    {reply, result_or_error(Res), State};

handle_call({get_overview, Username}, _From, State = #state{tables = Tables}) ->
    VHosts = case Username of
                 all -> rabbit_access_control:list_vhosts();
                 _   -> rabbit_mgmt_util:vhosts(Username)
             end,
    Qs0 = [rabbit_mgmt_format:queue(Q) || V <- VHosts,
                                          Q <- rabbit_amqqueue:list(V)],
    Qs1 = basic_queue_stats(Qs0, Tables),
    Totals0 = sum(Qs1, [messages_ready, messages_unacknowledged]),
    Totals = [{messages, add(pget(messages_ready, Totals0),
                             pget(messages_unacknowledged, Totals0))}|Totals0],
    Filter = fun(Id, Name) ->
                     lists:member(pget(vhost, pget(Name, Id)), VHosts)
             end,
    F = fun(Type, Name) ->
                get_fine_stats(
                  [], [R || R = {Id, _, _}
                                <- ets:tab2list(orddict:fetch(Type, Tables)),
                            %% TODO lose augment
                            Filter(augment_msg_stats(format_id(Id), Tables),
                                   Name)])
        end,
    Publish = F(channel_exchange_stats, exchange),
    Consume = F(channel_queue_stats, queue_details),
    {reply, [{message_stats, Publish ++ Consume},
             {queue_totals, Totals}], State};

handle_call(_Request, _From, State) ->
    {reply, not_understood, State}.

handle_cast({event, Event}, State) ->
    handle_event(Event, State),
    {noreply, State};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Arg, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------

handle_event(#event{type = queue_stats, props = Stats, timestamp = Timestamp},
             State) ->
    handle_stats(queue_stats, Stats, Timestamp,
                 [{fun rabbit_mgmt_format:properties/1,[backing_queue_status]},
                  {fun rabbit_mgmt_format:timestamp/1, [idle_since]}],
                 [], State);

handle_event(Event = #event{type = queue_deleted}, State) ->
    handle_deleted(queue_stats, Event, State);

handle_event(#event{type = connection_created, props = Stats}, State) ->
    Name = rabbit_mgmt_format:print(
             "~s:~w",
             [rabbit_mgmt_format:ip(pget(peer_address, Stats)),
              pget(peer_port, Stats)]),
    handle_created(
      connection_stats, [{name, Name} | Stats],
      [{fun rabbit_mgmt_format:ip/1,           [address, peer_address]},
       {fun rabbit_mgmt_format:node_and_pid/1, [pid]},
       {fun rabbit_mgmt_format:protocol/1,     [protocol]},
       {fun rabbit_mgmt_format:amqp_table/1,   [client_properties]}], State);

handle_event(#event{type = connection_stats, props = Stats,
                    timestamp = Timestamp},
             State) ->
    handle_stats(connection_stats, Stats, Timestamp, [], [recv_oct, send_oct],
                 State);

handle_event(Event = #event{type = connection_closed}, State) ->
    handle_deleted(connection_stats, Event, State);

handle_event(#event{type = channel_created, props = Stats},
             State = #state{tables = Tables}) ->
    ConnTable = orddict:fetch(connection_stats, Tables),
    Conn = lookup_element(ConnTable, {pid(pget(connection, Stats)), create}),
    Name = rabbit_mgmt_format:print("~s:~w:~w",
                                    [pget(peer_address, Conn),
                                     pget(peer_port,    Conn),
                                     pget(number,       Stats)]),
    handle_created(channel_stats, [{name, Name}|Stats],
                   [{fun rabbit_mgmt_format:node_and_pid/1, [pid]},
                    {fun rabbit_mgmt_format:pid/1,          [connection]}],
                   State);

handle_event(#event{type = channel_stats, props = Stats, timestamp = Timestamp},
             State) ->
    handle_stats(channel_stats, Stats, Timestamp,
                 [{fun rabbit_mgmt_format:timestamp/1, [idle_since]}],
                 [], State),
    [handle_fine_stats(Type, Stats, Timestamp, State) ||
        Type <- ?FINE_STATS_TYPES],
    {ok, State};

handle_event(Event = #event{type = channel_closed,
                            props = [{pid, Pid}]}, State) ->
    handle_deleted(channel_stats, Event, State),
    [delete_fine_stats(Type, pid(Pid), State) ||
        Type <- ?FINE_STATS_TYPES],
    {ok, State};

handle_event(#event{type = consumer_created, props = Props}, State) ->
    handle_consumer(fun(Table, Id, P) -> ets:insert(Table, {Id, P}) end,
                    Props, State);

handle_event(#event{type = consumer_deleted, props = Props}, State) ->
    handle_consumer(fun(Table, Id, _P) -> ets:delete(Table, Id) end,
                    Props, State);

handle_event(_Event, State) ->
    {ok, State}.

%%----------------------------------------------------------------------------

handle_created(TName, Stats, Funs, State = #state{tables = Tables}) ->
    Formatted = rabbit_mgmt_format:format(Stats, Funs),
    ets:insert(orddict:fetch(TName, Tables), {{id(Stats), create},
                                              Formatted,
                                              pget(name, Stats)}),
    {ok, State}.

handle_stats(TName, Stats0, Timestamp, Funs,
             RatesKeys, State = #state{tables = Tables}) ->
    Id = {id(Stats0), stats},
    Stats = lists:foldl(
              fun (K, StatsAcc) -> proplists:delete(K, StatsAcc) end,
              Stats0, [name | ?FINE_STATS_TYPES]),
    Table = orddict:fetch(TName, Tables),
    OldStats = lookup_element(Table, Id),
    OldTimestamp = lookup_element(Table, Id, 3),
    Stats1 = rates(Stats, Timestamp, OldStats, OldTimestamp, RatesKeys),
    Stats2 = proplists:delete(pid, rabbit_mgmt_format:format(Stats1, Funs)),
    ets:insert(Table, {Id, Stats2, Timestamp}),
    {ok, State}.

handle_deleted(TName, #event{props = Props}, State = #state{tables = Tables}) ->
    Table = orddict:fetch(TName, Tables),
    ets:delete(Table, {id(Props), create}),
    ets:delete(Table, {id(Props), stats}),
    {ok, State}.

handle_consumer(Fun, Props,
                State = #state{tables = Tables}) ->
    P = rabbit_mgmt_format:format(
          Props, [{fun rabbit_mgmt_format:pid/1, [channel]}]),
    Table = orddict:fetch(consumers, Tables),
    Fun(Table, {pget(queue, P), pget(channel, P)}, P),
    {ok, State}.

handle_fine_stats(Type, Props, Timestamp, State = #state{tables = Tables}) ->
    case pget(Type, Props) of
        unknown ->
            ok;
        AllFineStats ->
            ChPid = id(Props),
            Table = orddict:fetch(Type, Tables),
            IdsStatsTS =
                [{Ids,
                  Stats,
                  lookup_element(Table, fine_stats_key(ChPid, Ids)),
                  lookup_element(Table, fine_stats_key(ChPid, Ids), 3)} ||
                    {Ids, Stats} <- AllFineStats],
            delete_fine_stats(Type, ChPid, State),
            [handle_fine_stat(ChPid, Ids, Stats, Timestamp,
                              OldStats, OldTimestamp, Table) ||
                {Ids, Stats, OldStats, OldTimestamp} <- IdsStatsTS]
    end.


handle_fine_stat(ChPid, Ids, Stats, Timestamp,
                 OldStats, OldTimestamp,
                 Table) ->
    Id = fine_stats_key(ChPid, Ids),
    Total = lists:sum([V || {K, V} <- Stats, lists:member(K, ?DELIVER_GET)]),
    Stats1 = case Total of
                 0 -> Stats;
                 _ -> [{deliver_get, Total}|Stats]
             end,
    Res = rates(Stats1, Timestamp, OldStats, OldTimestamp, ?FINE_STATS),
    ets:insert(Table, {Id, Res, Timestamp}).

delete_fine_stats(Type, ChPid, #state{tables = Tables}) ->
    Table = orddict:fetch(Type, Tables),
    ets:match_delete(Table, {{ChPid, '_'}, '_', '_'}),
    ets:match_delete(Table, {{ChPid, '_', '_'}, '_', '_'}).

fine_stats_key(ChPid, {Q, X}) -> {ChPid, Q, X};
fine_stats_key(ChPid, QX)     -> {ChPid, QX}.

created_event(Name, Type, Tables) ->
    Table = orddict:fetch(Type, Tables),
    Id = case ets:match(Table, {{'$1', create}, '_', Name}) of
             []    -> none;
             [[I]] -> I
         end,
    [lookup_element(Table, {Id, create})].

created_events(Type, Tables) ->
    [Facts || {{_, create}, Facts, _Name}
                  <- ets:tab2list(orddict:fetch(Type, Tables))].

get_fine_stats(Type, GroupBy, Tables) ->
    get_fine_stats(GroupBy, ets:tab2list(orddict:fetch(Type, Tables))).

get_fine_stats(GroupBy, List) ->
    All = [{format_id(Id), zero_old_rates(Stats)} ||
              {Id, Stats, _Timestamp} <- List],
    group_sum(GroupBy, All).

format_id({ChPid,
           #resource{name=XName, kind=exchange, virtual_host=XVhost}}) ->
    [{channel, ChPid}, {exchange, [{name, XName}, {vhost, XVhost}]}];
format_id({ChPid,
           #resource{name=QName, kind=queue, virtual_host=QVhost}}) ->
    [{channel, ChPid}, {queue,    [{name, QName}, {vhost, QVhost}]}];
format_id({ChPid,
           #resource{name=QName, kind=queue,    virtual_host=QVhost},
           #resource{name=XName, kind=exchange, virtual_host=XVhost}}) ->
    [{channel, ChPid},
     {queue,    [{name, QName}, {vhost, QVhost}]},
     {exchange, [{name, XName}, {vhost, XVhost}]}].

%%----------------------------------------------------------------------------

merge_stats(Objs, Funs) ->
    [lists:foldl(fun (Fun, Props) -> Fun(Props) ++ Props end, Obj, Funs)
     || Obj <- Objs].

basic_stats_fun(Type, IdFun, Tables) ->
    Table = orddict:fetch(Type, Tables),
    fun (Props) ->
            zero_old_rates(lookup_element(Table, {IdFun(Props), stats}))
    end.

pid_id_fun(Props) ->
    pget(pid, Props).

q_id_fun(Props) ->
    rabbit_misc:r(pget(vhost, Props), queue, pget(name, Props)).

fine_stats_fun(FineSpecs, Tables) ->
    FineStats = [{AttachName, AttachBy,
                  get_fine_stats(FineStatsType, GroupBy, Tables)}
                 || {FineStatsType, GroupBy, AttachName, AttachBy}
                        <- FineSpecs],
    fun (Props) ->
            lists:foldl(fun (FineStat, StatProps) ->
                                fine_stat(Props, StatProps, FineStat, Tables)
                        end, [], FineStats)
    end.

fine_stat(Props, StatProps, {AttachName, AttachBy, Dict}, Tables) ->
    Id = case AttachBy of
             exchange ->
                 [{name, pget(name, Props)}, {vhost, pget(vhost, Props)}];
             _ ->
                 pget(pid, Props)
         end,
    case dict:find({AttachBy, Id}, Dict) of
        {ok, Stats} -> [{AttachName, pget(AttachName, StatProps, []) ++
                             augment_fine_stats(Stats, Tables)} |
                        proplists:delete(AttachName, StatProps)];
        error       -> StatProps
    end.

augment_fine_stats(Dict, Tables) when element(1, Dict) == dict ->
    [[{stats, augment_fine_stats(Stats, Tables)} |
      augment_msg_stats([IdTuple], Tables)]
     || {IdTuple, Stats} <- dict:to_list(Dict)];
augment_fine_stats(Stats, _Tables) ->
    Stats.

consumer_details_fun(PatternFun, Tables) ->
    Table = orddict:fetch(consumers, Tables),
    fun ([])    -> [];
        (Props) -> Pattern = PatternFun(Props),
                   [{consumer_details,
                     [augment_msg_stats(Obj, Tables)
                      || Obj <- lists:append(
                                  ets:match(Table, {Pattern, '$1'}))]}]
    end.

zero_old_rates(Stats) -> [maybe_zero_rate(S) || S <- Stats].

maybe_zero_rate({Key, Val}) ->
    case is_details(Key) of
        true  -> Age = rabbit_misc:now_ms() - pget(last_event, Val),
                 {Key, case Age > ?STATS_INTERVAL * 1.5 of
                           true  -> pset(rate, 0, Val);
                           false -> Val
                       end};
        false -> {Key, Val}
    end.

is_details(Key) -> lists:suffix("_details", atom_to_list(Key)).

details_key(Key) -> list_to_atom(atom_to_list(Key) ++ "_details").

%%----------------------------------------------------------------------------

augment_msg_stats(Props, Tables) ->
    (augment_msg_stats_fun(Tables))(Props) ++ Props.

augment_msg_stats_fun(Tables) ->
    Funs = [{connection, fun augment_connection_pid/2},
            {channel,    fun augment_channel_pid/2},
            {queue,      fun augment_queue/2},
            {owner_pid,  fun augment_connection_pid/2}],
    fun (Props) -> augment(Props, Funs, Tables) end.

augment(Items, Funs, Tables) ->
    Augmented = [augment(K, Items, Fun, Tables) || {K, Fun} <- Funs],
    [{K, V} || {K, V} <- Augmented, V =/= unknown].

augment(K, Items, Fun, Tables) ->
    Key = details_key(K),
    case pget(K, Items) of
        none    -> {Key, unknown};
        unknown -> {Key, unknown};
        Id      -> {Key, Fun(Id, Tables)}
    end.

augment_channel_pid(Pid, Tables) ->
    Ch = lookup_element(orddict:fetch(channel_stats, Tables),
                        {Pid, create}),
    Conn = lookup_element(orddict:fetch(connection_stats, Tables),
                          {pget(connection, Ch), create}),
    [{name,            pget(name,   Ch)},
     {number,          pget(number, Ch)},
     {connection_name, pget(name,         Conn)},
     {peer_address,    pget(peer_address, Conn)},
     {peer_port,       pget(peer_port,    Conn)}].

augment_connection_pid(Pid, Tables) ->
    Conn = lookup_element(orddict:fetch(connection_stats, Tables),
                          {Pid, create}),
    [{name,         pget(name,         Conn)},
     {peer_address, pget(peer_address, Conn)},
     {peer_port,    pget(peer_port,    Conn)}].

augment_queue(Name, _Tables) ->
    [{name,  Name#resource.name},
     {vhost, Name#resource.virtual_host}].

%%----------------------------------------------------------------------------

basic_queue_stats(Objs, Tables) ->
    merge_stats(Objs, [basic_stats_fun(queue_stats, fun q_id_fun/1, Tables),
                       augment_msg_stats_fun(Tables)]).

queue_stats(Objs, FineSpecs, Tables) ->
    merge_stats(Objs, [basic_stats_fun(queue_stats, fun q_id_fun/1, Tables),
                       consumer_details_fun(
                         fun (Props) -> {q_id_fun(Props), '_'} end, Tables),
                       fine_stats_fun(FineSpecs, Tables),
                       augment_msg_stats_fun(Tables)]).

exchange_stats(Objs, FineSpecs, Tables) ->
    merge_stats(Objs, [fine_stats_fun(FineSpecs, Tables),
                       augment_msg_stats_fun(Tables)]).

connection_stats(Objs, Tables) ->
    merge_stats(Objs, [basic_stats_fun(connection_stats, fun pid_id_fun/1,
                                       Tables),
                       augment_msg_stats_fun(Tables)]).

channel_stats(Objs, FineSpecs, Tables) ->
    merge_stats(Objs, [basic_stats_fun(channel_stats, fun pid_id_fun/1, Tables),
                       consumer_details_fun(
                         fun (Props) -> {'_', pget(pid, Props)} end, Tables),
                       fine_stats_fun(FineSpecs, Tables),
                       augment_msg_stats_fun(Tables)]).
