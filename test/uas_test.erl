%% -------------------------------------------------------------------
%%
%% uas_test: Basic Test Suite
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

-module(uas_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


uas_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun uas/0}, 
            {timeout, 60, fun auto/0},
            {timeout, 60, fun timeout/0}
        ]
    }.


start() ->
    tests_util:start_nksip(),
    nksip_config:put(nksip_store_timer, 200),
    nksip_config:put(nksip_sipapp_timer, 10000),

    ok = sipapp_server:start({uas, server1}, [
        {from, "\"NkSIP Basic SUITE Test Server\" <sip:server1@nksip>"},
        {supported, "a;a_param, 100rel"},
        registrar,
        {transports, [{udp, all, 5060}, {tls, all, 5061}]}
    ]),

    ok = sipapp_endpoint:start({uas, client1}, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client1@nksip>"},
        {transports, [{udp, all, 5070}, {tls, all, 5071}]}
    ]),
            

    ok = sipapp_endpoint:start({uas, client2}, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client2@nksip>"}]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = sipapp_server:stop({uas, server1}),
    ok = sipapp_endpoint:stop({uas, client1}),
    ok = sipapp_endpoint:stop({uas, client2}).


uas() ->
    C1 = {uas, client1},
    
    % Test loop detection
    {ok, 200, Values1} = nksip_uac:options(C1, "sip:127.0.0.1", [
                                {add, <<"x-nk-op">>, <<"reply-stateful">>},
                                {meta, [call_id, from, cseq_num]}]),
    [{call_id, CallId1}, {from, From1}, {cseq_num, CSeq1}] = Values1,

    {ok, 482, [{reason_phrase, <<"Loop Detected">>}]} = 
        nksip_uac:options(C1, "sip:127.0.0.1", [
                            {add, <<"x-nk-op">>, <<"reply-stateful">>},
                            {call_id, CallId1}, {from, From1}, {cseq_num, CSeq1}, 
                            {meta, [reason_phrase]}]),

    % Stateless proxies do not detect loops
    {ok, 200, Values3} = nksip_uac:options(C1, "sip:127.0.0.1", [
                            {add, "x-nk-op", "reply-stateless"},
                            {meta, [call_id, from, cseq_num]}]),

    [{_, CallId3}, {_, From3}, {_, CSeq3}] = Values3,
    {ok, 200, []} = nksip_uac:options(C1, "sip:127.0.0.1", [
                        {add, "x-nk-op", "reply-stateless"},
                        {call_id, CallId3}, {from, From3}, {cseq_num, CSeq3}]),

    % Test bad extension endpoint and proxy
    {ok, 420, [{all_headers, Hds5}]} = nksip_uac:options(C1, "sip:127.0.0.1", [
                                           {add, "require", "a,b;c,d"}, 
                                           {meta, [all_headers]}]),
    % 'a' is supported because of app config
    [<<"b,d">>] = proplists:get_all_values(<<"unsupported">>, Hds5),
    
    {ok, 420, [{all_headers, Hds6}]} = nksip_uac:options(C1, "sip:a@external.com", [
                                            {add, "proxy-require", "a,b;c,d"}, 
                                            {route, "<sip:127.0.0.1;lr>"},
                                            {meta, [all_headers]}]),
    [<<"a,b,d">>] = proplists:get_all_values(<<"unsupported">>, Hds6),

    % Force invalid response
    nksip_trace:warning("Next warning about a invalid sipreply is expected"),
    {ok, 500,  [{reason_phrase, <<"Invalid SipApp Response">>}]} = 
        nksip_uac:options(C1, "sip:127.0.0.1", [
            {add, "x-nk-op", "reply-invalid"}, {meta, [reason_phrase]}]),
    ok.


auto() ->
    C1 = {uas, client1},
    % Start a new server to test ping and register options
    sipapp_server:stop({uas, server2}),
    ok = sipapp_server:start({uas, server2}, 
                                [registrar, {transports, [{udp, all, 5080}]}]),
    timer:sleep(200),
    Old = nksip_config:get(registrar_min_time),
    nksip_config:put(registrar_min_time, 1),
    {error, invalid_uri} = nksip_sipapp_auto:start_ping(n, ping1, "sip::a", 1, []),
    Ref = make_ref(),
    ok = sipapp_endpoint:add_callback(C1, Ref),
    {ok, true} = nksip_sipapp_auto:start_ping(C1, ping1, 
                                "<sip:127.0.0.1:5080;transport=tcp>", 5, []),

    {error, invalid_uri} = nksip_sipapp_auto:start_register(name, reg1, "sip::a", 1, []),
    {ok, true} = nksip_sipapp_auto:start_register(C1, reg1, 
                                "<sip:127.0.0.1:5080;transport=tcp>", 1, []),

    [{ping1, true, _}] = nksip_sipapp_auto:get_pings(C1),
    [{reg1, true, _}] = nksip_sipapp_auto:get_registers(C1),

    ok = tests_util:wait(Ref, [{ping, ping1, true}, {reg, reg1, true}]),

    nksip_trace:info("Next infos about connection error to port 9999 are expected"),
    {ok, false} = nksip_sipapp_auto:start_ping(C1, ping2, 
                                            "<sip:127.0.0.1:9999;transport=tcp>", 1, []),
    {ok, false} = nksip_sipapp_auto:start_register(C1, reg2, 
                                            "<sip:127.0.0.1:9999;transport=tcp>", 1, []),
    ok = tests_util:wait(Ref, [{ping, ping2, false}, {reg, reg2, false}]),

    [{ping1, true,_}, {ping2, false,_}] = 
        lists:sort(nksip_sipapp_auto:get_pings(C1)),
    [{reg1, true,_}, {reg2, false,_}] = 
        lists:sort(nksip_sipapp_auto:get_registers(C1)),
    
    ok = nksip_sipapp_auto:stop_ping(C1, ping2),
    ok = nksip_sipapp_auto:stop_register(C1, reg2),

    [{ping1, true, _}] = nksip_sipapp_auto:get_pings(C1),
    [{reg1, true, _}] = nksip_sipapp_auto:get_registers(C1),

    ok = sipapp_server:stop({uas, server2}),
    nksip_trace:info("Next info about connection error to port 5080 is expected"),
    {ok, false} = nksip_sipapp_auto:start_ping(C1, ping3, 
                                            "<sip:127.0.0.1:5080;transport=tcp>", 1, []),
    ok = nksip_sipapp_auto:stop_ping(C1, ping1),
    ok = nksip_sipapp_auto:stop_ping(C1, ping3),
    ok = nksip_sipapp_auto:stop_register(C1, reg1),
    [] = nksip_sipapp_auto:get_pings(C1),
    [] = nksip_sipapp_auto:get_registers(C1),
    nksip_config:put(registrar_min_time, Old),
    ok.

timeout() ->
    C1 = {uas, client1},
    C2 = {uas, client2},
    SipC1 = "<sip:127.0.0.1:5070;transport=tcp>",

    {ok, _Module, Opts, _Pid} = nksip_sipapp_srv:get_opts(C1),
    Opts1 = [{sipapp_timeout, 0.02}|Opts],
    ok = nksip_sipapp_srv:put_opts(C1, Opts1),

    % Client1 callback module has a 50msecs delay in route()
    {ok, 500, [{reason_phrase, <<"No SipApp Response">>}]} = 
        nksip_uac:options(C2, SipC1, [{meta,[reason_phrase]}]),

    Opts2 = [{timer_t1, 10}, {timer_c, 0.5}|Opts] -- [{sipapp_timeout, 0.02}],
    ok = nksip_sipapp_srv:put_opts(C1, Opts2),

    Hd1 = {add, "x-nk-sleep", 2000},
    {ok, 408, [{reason_phrase, <<"No-INVITE Timeout">>}]} = 
        nksip_uac:options(C2, SipC1, [Hd1, {meta, [reason_phrase]}]),

    Hds2 = [{add, "x-nk-op", busy}, {add, "x-nk-sleep", 2000}],
    {ok, 408, [{reason_phrase, <<"Timer C Timeout">>}]} = 
        nksip_uac:invite(C2, SipC1, [{meta,[reason_phrase]}|Hds2]),
    ok.






