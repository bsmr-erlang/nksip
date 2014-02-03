%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @private UDP Transport Module.
-module(nksip_transport_udp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_listener/4, send/2, send/4, send_stun/3, get_port/1, connect/3]).
-export([start_ping/3, start_ping/4]).
-export([start_link/2, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
             handle_info/2]).

-include("nksip.hrl").

-define(MAX_UDP, 1500).


%% ===================================================================
%% Private
%% ===================================================================



%% @private Starts a new listening server
-spec start_listener(nksip:app_id(), inet:ip_address(), inet:port_number(), 
                   nksip_lib:proplist()) ->
    {ok, pid()} | {error, term()}.

start_listener(AppId, Ip, Port, _Opts) ->
    Transp = #transport{
        proto = udp,
        local_ip = Ip, 
        local_port = Port,
        listen_ip = Ip,
        listen_port = Port,
        remote_ip = {0,0,0,0},
        remote_port = 0
    },
    Spec = {
        {AppId, udp, Ip, Port}, 
        {?MODULE, start_link, [AppId, Transp]},
        permanent, 
        5000, 
        worker, 
        [?MODULE]
    },
    nksip_transport_sup:add_transport(AppId, Spec).


%% @private Starts a new connection to a remote server
-spec connect(nksip:app_id(), inet:ip_address(), inet:port_number()) ->
    {ok, pid(), nksip_transport:transport()} | {error, term()}.
         
%% @private Registers a new connection
connect(AppId, Ip, Port) ->
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    case nksip_transport:get_listening(AppId, udp, Class) of
        [{Transp, Pid}|_] -> 
            case catch gen_server:call(Pid, {connect, Ip, Port}) of
                ok -> 
                    Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port},
                    {ok, Pid, Transp1};
                _ -> 
                    {error, no_response}
            end;
        [] ->
            {error, no_listening_transport}
    end.


%% @private Sends a new UDP request or response
-spec send(pid(), #sipmsg{}) ->
    ok | error.

send(Pid, SipMsg) ->
    #sipmsg{
        class = Class,
        app_id = AppId, 
        call_id = CallId,
        transport=#transport{remote_ip=Ip, remote_port=Port} = Transp
    } = SipMsg,
    Packet = nksip_unparse:packet(SipMsg),
    case send(Pid, Ip, Port, Packet) of
        ok ->
            case Class of
                {req, Method} ->
                    nksip_trace:insert(SipMsg, {udp_out, Ip, Port, Method, Packet}),
                    nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transp, Packet),
                    ok;
                {resp, Code, _Reaosn} ->
                    nksip_trace:insert(SipMsg, {udp_out, Ip, Port, Code, Packet}),
                    nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transp, Packet),
                    ok
            end;
        {error, closed} ->
            error;
        {error, too_large} ->
            error;
        {error, Error} ->
            ?notice(AppId, CallId, "could not send UDP msg to ~p:~p: ~p", 
                  [Ip, Port, Error]),
            error
    end.


%% @private Sends a new packet
-spec send(pid(), inet:ip4_address(), inet:port_number(), binary()) ->
    ok | {error, term()}.

send(Pid, Ip, Port, Packet) when byte_size(Packet) =< ?MAX_UDP ->
    case catch gen_server:call(Pid, {send, Ip, Port, Packet}, 60000) of
        ok -> ok;
        {error, Error} -> {error, Error};
        {'EXIT', {noproc, _}} -> {error, closed};
        {'EXIT', Error} -> {error, Error}
    end;

send(_Pid, _Ip, _Port, Packet) ->
    lager:debug("Coult not send UDP packet (too large: ~p)", [byte_size(Packet)]),
    {error, too_large}.


%% @private Sends a STUN binding request
send_stun(Pid, Ip, Port) ->
    case catch gen_server:call(Pid, {send_stun, Ip, Port}, 30000) of
        {ok, StunIp, StunPort} -> {ok, StunIp, StunPort};
        _ -> error
    end.


%% @private Get transport current port
-spec get_port(pid()) ->
    {ok, inet:port_number()}.

get_port(Pid) ->
    gen_server:call(Pid, get_port).


%% @doc Start a time-alive series (defualt time)
-spec start_ping(pid(), inet:ip_address(), inet:port_number()) ->
    ok.

start_ping(Pid, Ip, Port) ->
    start_ping(Pid, Ip, Port, ?DEFAULT_UDP_KEEPALIVE).


%% @doc Start a time-alive series
-spec start_ping(pid(), inet:ip_address(), inet:port_number(), pos_integer()) ->
    ok.

start_ping(Pid, Ip, Port, Secs) ->
    Rand = crypto:rand_uniform(80, 101),
    Time = (Rand*Secs) div 100,
    gen_server:cast(Pid, {start_ping, Ip, Port, Time}).


%% ===================================================================
%% gen_server
%% ===================================================================

%% @private
start_link(AppId, Transp) -> 
    gen_server:start_link(?MODULE, [AppId, Transp], []).


-record(conn, {
    dest :: {inet:ip_address(), inet:port_number()},
    remote_dest :: {inet:ip_address(), inet:port_number()},
    timeout_timer :: reference(),
    refresh_timer :: reference(),
    time :: pos_integer()
}).

-record(stun, {
    id :: binary(),
    dest :: {inet:ip_address(), inet:port_number()},
    packet :: binary(),
    retrans_timer :: reference(),
    next_retrans :: integer(),
    from :: from()
}).

-record(state, {
    app_id :: nksip:app_id(),
    transport :: nksip_transport:transport(),
    socket :: port(),
    tcp_pid :: pid(),
    conns :: [#conn{}],
    stuns :: [#stun{}],
    timer_t1 :: pos_integer()
}).



%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([AppId, #transport{listen_ip=Ip, listen_port=Port}=Transp]) ->
    case open_port(AppId, Ip, Port, 5) of
        {ok, Socket}  ->
            process_flag(priority, high),
            {ok, Port1} = inet:port(Socket),
            Self = self(),
            spawn(fun() -> start_tcp(AppId, Ip, Port1, Self) end),
            Transp1 = Transp#transport{local_port=Port1, listen_port=Port1},
            nksip_proc:put(nksip_transports, {AppId, Transp1}),
            nksip_proc:put({nksip_listen, AppId}, Transp1),
            State = #state{
                app_id = AppId, 
                transport = Transp1, 
                socket = Socket,
                tcp_pid = undefined,
                conns = [],
                stuns = [],
                timer_t1 = nksip_config:get(timer_t1)
            },
            {ok, State};
        {error, Error} ->
            ?error(AppId, "B could not start UDP transport on ~p:~p (~p)", 
                   [Ip, Port, Error]),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call({send, Ip, Port, Packet}, _From, #state{socket=Socket}=State) ->
    {reply, gen_udp:send(Socket, Ip, Port, Packet), State};

handle_call({send_stun, Ip, Port}, From, State) ->
    case do_send_stun(Ip, Port, From, State) of
        {ok, State1} -> {noreply, State1};
        error -> {reply, error, State}
    end;

handle_call(get_port, _From, #state{transport=#transport{listen_port=Port}}=State) ->
    {reply, {ok, Port}, State};

handle_call({connect, Ip, Port}, _From, State) ->
    {reply, ok, do_connect_create(Ip, Port, State)};

handle_call(get_data, _From, #state{conns=Conns}=State) ->
    {reply, Conns, State};

handle_call(Msg, _Form, State) -> 
    lager:warning("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast({matching_tcp, {ok, Pid}}, State) ->
    {noreply, State#state{tcp_pid=Pid}};

handle_cast({matching_tcp, {error, Error}}, State) ->
    {stop, {matching_tcp, {error, Error}}, State};

handle_cast({start_ping, Ip, Port, Secs}, State) ->
    {noreply, do_connect_ping(Ip, Port, Secs, State)};

handle_cast(Msg, State) -> 
    lager:warning("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({udp, Socket, _Ip, _Port, <<_, _>>}, #state{socket=Socket}=State) ->
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};

handle_info({udp, Socket, Ip, Port, <<0:2, _Header:158, _Msg/binary>>=Packet}, State) ->
    #state{
        app_id = AppId,
        socket = Socket
    } = State,
    ok = inet:setopts(Socket, [{active, once}]),
    State1 = inbound(Ip, Port, State),
    case nksip_stun:decode(Packet) of
        {request, binding, TransId, _} ->
            Response = nksip_stun:binding_response(TransId, Ip, Port),
            gen_udp:send(Socket, Ip, Port, Response),
            ?debug(AppId, "sent STUN bind response to ~p:~p", [Ip, Port]),
            {noreply, State1};
        {response, binding, TransId, Attrs} ->
            {noreply, do_stun_response(TransId, Attrs, State1)};
        error ->
            ?notice(AppId, "received unrecognized UDP packet: ~s", [Packet]),
            {noreply, State1}
    end;

handle_info({udp, Socket, Ip, Port, Packet}, #state{socket=Socket}=State) ->
    parse(Packet, Ip, Port, State),
    read_packets(100, State),
    ok = inet:setopts(Socket, [{active, once}]),
    State1 = inbound(Ip, Port, State),
    {noreply, State1};

handle_info({timeout, Ref, stun_retrans}, #state{stuns=Stuns}=State) ->
    {value, Stun1, Stuns1} = lists:keytake(Ref, #stun.retrans_timer, Stuns),
    {noreply, do_stun_retrans(Stun1, State#state{stuns=Stuns1})};
   
handle_info({timeout, Ref, conn_refresh}, #state{conns=Conns}=State) ->
    State1 = case lists:keyfind(Ref, #conn.refresh_timer, Conns) of
        #conn{}=Conn -> do_connect_refresh(Conn, State);
        false -> State
    end,
    {noreply, State1};
   
handle_info({timeout, Ref, conn_timeout}, #state{app_id=AppId, conns=Conns}=State) ->
    State1 = case lists:keytake(Ref, #conn.timeout_timer, Conns) of
        {value, Conn1, Conns1} ->
            do_connect_timeout(Conn1, State#state{conns=Conns1});
        false ->
            ?warning(AppId, "received unexpected conn_timeout", []),
            State
    end,
    {noreply, State1};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
-spec terminate(term(), #state{}) ->
    gen_server_terminate().

terminate(_Reason, _State) ->  
    ok.




%% ========= STUN processing ================================================

%% @private
do_send_stun(Ip, Port, From, State) ->
    #state{app_id=AppId, timer_t1=T1, stuns=Stuns, socket=Socket} = State,
    {Id, Packet} = nksip_stun:binding_request(),
    case gen_udp:send(Socket, Ip, Port, Packet) of
        ok -> 
            ?debug(AppId, "sent STUN request to ~p", [{Ip, Port}]),
            Stun = #stun{
                id = Id,
                dest = {Ip, Port},
                packet = Packet,
                retrans_timer = start_timer(T1, stun_retrans),
                next_retrans = 2*T1,
                from = From
            },
            {ok, State#state{stuns=[Stun|Stuns]}};
        {error, Error} ->
            ?notice(AppId, "could not send UDP STUN request to ~p:~p: ~p", 
                  [Ip, Port, Error]),
            error
    end.


%% @private
do_stun_retrans(Stun, State) ->
    #stun{dest={Ip, Port}, packet=Packet, next_retrans=Next} = Stun,
    #state{app_id=AppId, stuns=Stuns, timer_t1=T1, socket=Socket} = State,
    case Next =< (16*T1) of
        true ->
            case gen_udp:send(Socket, Ip, Port, Packet) of
                ok -> 
                    ?notice(AppId, "sent STUN refresh", []),
                    Stun1 = Stun#stun{
                        retrans_timer = start_timer(Next, stun_retrans),
                        next_retrans = 2*Next
                    },
                    State#state{stuns=[Stun1|Stuns]};
                {error, Error} ->
                    ?notice(AppId, "could not send UDP STUN request to ~p:~p: ~p", 
                          [Ip, Port, Error]),
                    do_stun_timeout(Stun, State)
            end;
        false ->
            do_stun_timeout(Stun, State)
    end.


%% @private
do_stun_response(TransId, Attrs, State) ->
    #state{app_id=AppId, stuns=Stuns} = State,
    case lists:keytake(TransId, #stun.id, Stuns) of
        {value, #stun{dest={Ip, Port}, retrans_timer=Retrans, from=From}, Stuns1} ->
            cancel_timer(Retrans),
            case nksip_lib:get_value(xor_mapped_address, Attrs) of
                {StunIp, StunPort} -> 
                    ok;
                _ ->
                    case nksip_lib:get_value(mapped_address, Attrs) of
                        {StunIp, StunPort} -> ok;
                        _ -> StunIp = StunPort = undefined
                    end
            end,
            case From of
                undefined -> ok;
                _ -> gen_server:reply(From, {ok, StunIp, StunPort})
            end,
            State1 = State#state{stuns=Stuns1},
            do_connect_response({Ip, Port}, {StunIp, StunPort}, State1);
        false ->
            ?notice(AppId, "received unexpected STUN response", []),
            State
    end.


%% @private
do_stun_timeout(Stun, #state{app_id=AppId, conns=Conns}=State) ->
    #stun{dest={Ip, Port}, from=From} = Stun,
    ?notice(AppId, "STUN request to ~p timeout", [{Ip, Port}]),
    case From of
        undefined -> ok;
        _ -> gen_server:reply(From, error)
    end,
    case lists:keytake({Ip, Port}, #conn.dest, Conns) of
        {value, Conn1, Conns1} -> do_connect_timeout(Conn1, State#state{conns=Conns1});
        false -> State
    end.
    


%% ========= Connection processing ============================================


%% @private
do_connect_create(Ip, Port, State) ->
    #state{app_id=AppId, transport=Transp, conns=Conns, timer_t1=T1} = State,
    ?debug(AppId, "connected to ~s:~p (udp)", [nksip_lib:to_host(Ip), Port]),
    case lists:keytake({Ip, Port}, #conn.dest, Conns) of
        false ->
            Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port},
            nksip_proc:put({nksip_connection, {AppId, udp, Ip, Port}}, Transp1), 
            Conn = #conn{
                dest = {Ip, Port},
                timeout_timer = start_timer(64*T1, conn_timeout),
                time = undefined
            },
            State#state{conns=[Conn|Conns]};
        {value, #conn{timeout_timer=TimeoutTimer}=Conn, Conns1} ->
            Conn1 = case is_reference(TimeoutTimer) of
                true -> 
                    cancel_timer(TimeoutTimer),
                    Conn#conn{timeout_timer=start_timer(64*T1, conn_timeout)};
                _ ->
                    Conn
            end,
            State#state{conns=[Conn1|Conns1]}
    end.


%% @private
do_connect_ping(Ip, Port, Secs, #state{app_id=AppId, conns=Conns}=State) ->
    ?notice(AppId, "UDP started keep alive to ~p (~p)", [{Ip, Port}, Secs]),
    Time = 1000*Secs,
    case lists:keytake({Ip, Port}, #conn.dest, Conns) of
        {value, Conn, Conns1} ->
            #conn{timeout_timer=TimeoutTimer, refresh_timer=RefreshTimer} = Conn,
            cancel_timer(TimeoutTimer),
            cancel_timer(RefreshTimer),
            Conn1 = Conn#conn{
                timeout_timer = undefined,
                refresh_timer = start_timer(Time, conn_refresh),
                time = Time
            },
            State#state{conns=[Conn1|Conns1]};
        false ->
            Conn = #conn{
                dest = {Ip, Port},
                timeout_timer = undefined,
                refresh_timer = start_timer(Time, conn_refresh),
                time = Time
            },
            State#state{conns=[Conn|Conns]}
    end.


%% @private
do_connect_refresh(#conn{dest={Ip, Port}}, State) ->
    case do_send_stun(Ip, Port, undefined, State) of
        {ok, State1} -> State1;
        error -> State
    end.


%% @private
do_connect_response(Dest, StunDest, #state{conns=Conns}=State) ->
    case lists:keyfind(Dest, #conn.dest, Conns) of
        #conn{timeout_timer=undefined, remote_dest=RemDest, time=Time}=Conn ->
            case RemDest==undefined orelse RemDest==StunDest of
                true ->
                    Conn1 = Conn#conn{
                        remote_dest = StunDest,
                        refresh_timer = start_timer(Time, conn_refresh)
                    },
                    Conns1 = lists:keystore(Dest, #conn.dest, Conns, Conn1),
                    State#state{conns=Conns1};
                _ ->
                    do_connect_timeout(Conn, State)
            end;
        _ ->
            State
    end.


%% @private
do_connect_timeout(Conn, #state{app_id=AppId}=State) ->
    #conn{dest={Ip, Port}} = Conn,
    ?warning(AppId, "UDP flow to ~p:~p timeout", [Ip, Port]),
    nksip_proc:del({nksip_connection, {AppId, udp, Ip, Port}}),
    State.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
inbound(Ip, Port, State) ->
    #state{app_id=AppId, conns=Conns, transport=Transp, timer_t1=T1} = State,    
    case lists:keymember({Ip, Port}, #conn.dest, Conns) of
        true -> 
            State;
        false -> 
            ?debug(AppId, "connected from ~s:~p (udp)", [nksip_lib:to_host(Ip), Port]),
            Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port},
            nksip_proc:put({nksip_connection, {AppId, udp, Ip, Port}}, Transp1), 
            Conn = #conn{
                dest = {Ip, Port},
                timeout_timer = start_timer(64*T1, conn_timeout),
                time = undefined
            },
            State#state{conns=[Conn|Conns]}
    end.


%% @private
start_tcp(AppId, Ip, Port, Pid) ->
    case nksip_transport:start_transport(AppId, tcp, Ip, Port, []) of
        {ok, TcpPid} -> gen_server:cast(Pid, {matching_tcp, {ok, TcpPid}});
        {error, Error} -> gen_server:cast(Pid, {matching_tcp, {error, Error}})
    end.

%% @private Checks if a port is available for UDP and TCP
-spec open_port(nksip:app_id(), inet:ip_address(), inet:port_number(), integer()) ->
    {ok, port()} | {error, term()}.

open_port(AppId, Ip, Port, Iter) ->
    Opts = [binary, {reuseaddr, true}, {ip, Ip}, {active, once}],
    case gen_udp:open(Port, Opts) of
        {ok, Socket} ->
            {ok, Socket};
        {error, eaddrinuse} when Iter > 0 ->
            lager:warning("UDP port ~p is in use, waiting (~p)", [Port, Iter]),
            timer:sleep(1000),
            open_port(AppId, Ip, Port, Iter-1);
        {error, Error} ->
            {error, Error}
    end.


%% @private 
read_packets(0, _State) ->
    ok;
read_packets(N, #state{socket=Socket}=State) ->
    case gen_udp:recv(Socket, 0, 0) of
        {error, _} -> 
            ok;
        {ok, {Ip, Port, Packet}} -> 
            parse(Packet, Ip, Port, State),
            read_packets(N-1, State)
    end.


%% @private
parse(Packet, Ip, Port, #state{app_id=AppId, transport=Transp}=State) ->   
    Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port},
    case nksip_parse:packet(AppId, Transp1, Packet) of
        {ok, #raw_sipmsg{call_id=CallId, class=Class}=RawMsg, More} -> 
            nksip_trace:sipmsg(AppId, CallId, <<"FROM">>, Transp1, Packet),
            nksip_trace:insert(AppId, CallId, {in_udp, Class}),
            nksip_call_router:incoming_async(RawMsg),
            case More of
                <<>> -> ok;
                _ -> ?notice(AppId, "ignoring data after UDP msg: ~p", [More])
            end;
        {rnrn, More} ->
            parse(More, Ip, Port, State);
        {more, More} ->
            ?notice(AppId, "ignoring extrada data ~s processing UDP msg", [More]);
        {error, Error} ->
            ?notice(AppId, "error ~p processing UDP msg", [Error])
    end.


%% @private
start_timer(Time, Msg) ->
    erlang:start_timer(Time, self(), Msg).

%% @private
cancel_timer(Ref) ->
    nksip_lib:cancel_timer(Ref).
