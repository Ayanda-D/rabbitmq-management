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
-module(rabbit_mgmt_wm_aliveness_test).

-export([init/1, to_json/2, content_types_provided/2, is_authorized/2]).
-export([resource_exists/2]).

-include("rabbit_mgmt.hrl").
-include_lib("webmachine/include/webmachine.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-define(QUEUE, <<"aliveness-test">>).

%%--------------------------------------------------------------------

init(_Config) -> {ok, #context{}}.

content_types_provided(ReqData, Context) ->
   {[{"application/json", to_json}], ReqData, Context}.

resource_exists(ReqData, Context) ->
    {case rabbit_mgmt_util:vhost(ReqData) of
         not_found -> false;
         _         -> true
     end, ReqData, Context}.

to_json(ReqData, Context = #context{ user = #user { username = Username },
                                     password = Password }) ->
    Params = #amqp_params{username = Username,
                          password = Password,
                          virtual_host = rabbit_mgmt_util:vhost(ReqData)},
    %% TODO use network connection (need to check what we're bound to)
    {ok, Conn} = amqp_connection:start(direct, Params),
    {ok, Ch} = amqp_connection:open_channel(
                   Conn, {amqp_direct_consumer, [self()]}),
    amqp_channel:call(Ch, #'queue.declare'{ queue = ?QUEUE }),
    amqp_channel:call(Ch,
                      #'basic.publish'{ routing_key = ?QUEUE },
                      #amqp_msg{payload = <<"test_message">>}),
    amqp_channel:call(Ch, #'basic.consume'{queue = ?QUEUE, no_ack = true}),
    CTag = receive #'basic.consume_ok'{consumer_tag = CT} -> CT end,
    receive
        {#'basic.deliver'{}, _} -> ok
    end,
    amqp_channel:call(Ch, #'basic.cancel'{consumer_tag = CTag}),
    receive
        #'basic.cancel_ok'{} -> ok
    end,
    %% Don't delete the queue. If this is pinged every few seconds we
    %% don't want to create a mnesia transaction each time.
    amqp_channel:close(Ch),
    amqp_connection:close(Conn),
    rabbit_mgmt_util:reply([{status, ok}], ReqData, Context).

is_authorized(ReqData, Context) ->
    rabbit_mgmt_util:is_authorized_vhost(ReqData, Context).

