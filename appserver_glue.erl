%%%-------------------------------------------------------------------
%%% File    : appserver_glue.erl
%%% Author  : Fredrik Thulin <ft@it.su.se>
%%% Descrip.: Appserver glue between sipproxy and server transaction.
%%% Created : 25 Oct 2004 by Fredrik Thulin <ft@it.su.se>
%%%-------------------------------------------------------------------
-module(appserver_glue).

-behaviour(gen_server).

%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([
	 start_link/2,
	 start_link_cpl/5
	]).

%%--------------------------------------------------------------------
%% Internal exports - gen_server callbacks
%%--------------------------------------------------------------------
-export([
	 init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3
	]).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("sipproxy.hrl").
-include("siprecords.hrl").
%%-include("sipsocket.hrl").

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------
-record(state, {
	  branchbase,		%% string(), base of branches we should use
	  callhandler,		%% term(), the server transaction handler
	  request,		%% request record()
	  actions,		%% list() of sipproxy_action record()
	  forkpid,		%% pid() of sipproxy process
	  callhandler_pid,	%% pid() of server transaction handler, only use for matching!
	  cancelled=false,	%% atom(), true | false
	  completed=false,	%% atom(), true | false
	  cpl_pid=none		%% pid(), CPL interpreter backend
	 }).

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------
%% Timeout before dying.
-define(TIMEOUT, 300 * 1000).

%%====================================================================
%% External functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: start_link(Request, Actions)
%%           Request = request record()
%%           Actions = list() of sipproxy_action record()
%% Descrip.: start this appserver_glue gen_server.
%% Returns : gen_server:start_link/4
%%--------------------------------------------------------------------
start_link(Request, Actions) when is_record(Request, request), is_list(Actions) ->
    gen_server:start_link(?MODULE, [Request, Actions], []).

start_link_cpl(Parent, BranchBase, CallHandler, Request, Actions) when is_pid(Parent), is_list(BranchBase),
								       is_record(Request, request), is_list(Actions) ->
    gen_server:start_link(?MODULE, [cpl, Parent, BranchBase, CallHandler, Request, Actions], []).


%%====================================================================
%% Server functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init([Request, Actions])
%%           init([cpl, Parent, BranchBase, Actions]) ->
%%           Request     = request record()
%%           Actions     = list() of sipproxy_action record()
%%           Parent      = pid(), CPL interpreter backend process
%%           BranchBase  = string()
%% Descrip.: Initiates the server
%% Returns : {ok, State, Timeout} |
%%           ok                   |
%%           error (parent will throw a siperror (500))
%%--------------------------------------------------------------------
init([Request, Actions]) when is_record(Request, request), is_list(Actions) ->
    case transactionlayer:adopt_st_and_get_branchbase(Request) of
	{ok, CallHandler, BranchBase} ->
	    ForkPid = spawn_link(sipproxy, start_actions, [BranchBase, self(), Request, Actions]),
	    logger:log(normal, "~s: Appserver glue: Forking request, ~p actions",
		       [BranchBase, length(Actions)]),
	    logger:log(debug, "Appserver glue: Forking request, CallHandler (UAS) ~p, ForkPid (sipproxy) ~p",
		       [CallHandler, ForkPid]),
	    %% We need the pid of the callhandler extracted to do guard matches on it
	    CHPid = transactionlayer:get_pid_from_handler(CallHandler),
	    logger:log(debug, "Appserver glue started"),
	    {ok, #state{branchbase=BranchBase, callhandler=CallHandler, forkpid=ForkPid,
			request=Request, actions=Actions, callhandler_pid=CHPid},
	     ?TIMEOUT};
	ignore ->
	    ok;
	Res ->
	    logger:log(error, "Appserver glue: Can't start - failed to adopt server transaction : ~p",
		       [Res]),
	    error
    end;

%% For CPL proxy actions, we don't adopt the server transaction and we return
%% everything but provisional responses and 2xx response to INVITE to the CPL
%% script for further processing, instead of sending it to the STHandler like
%% we do for non-CPL processing.
init([cpl, Parent, BranchBase, CallHandler, Request, Actions]) ->
    ForkPid = spawn_link(sipproxy, start_actions, [BranchBase, self(), Request, Actions]),
    logger:log(normal, "~s: Appserver glue: Forking request, ~p actions",
	       [BranchBase, length(Actions)]),
    logger:log(debug, "Appserver glue: Forking request, CPL process ~p, CallHandler ~p, ForkPid ~p",
	       [Parent, CallHandler, ForkPid]),
    %% We need the pid of the callhandler extracted to do guard matches on it
    CHPid = transactionlayer:get_pid_from_handler(CallHandler),
    logger:log(debug, "Appserver glue (CPL) started"),
    {ok, #state{branchbase=BranchBase, callhandler=CallHandler, forkpid=ForkPid,
		request=Request, actions=Actions, callhandler_pid=CHPid, cpl_pid=Parent}, ?TIMEOUT}.


%%--------------------------------------------------------------------
%% Function: handle_call(Msg, From, State)
%% Descrip.: Handling call messages.
%% Returns : {reply, Reply, State}          |
%%           {reply, Reply, State, Timeout} |
%%           {noreply, State}               |
%%           {noreply, State, Timeout}      |
%%           {stop, Reason, Reply, State}   | (terminate/2 is called)
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_call(Msg, From, State) ->
    logger:log(error, "Appserver glue: Received unknown gen_server call from ~p :~n~p",
	       [From, Msg]),
    {noreply, State, ?TIMEOUT}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State)
%% Descrip.: Handling cast messages
%% Returns : {noreply, State}          |
%%           {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_cast(Msg, State) ->
    logger:log(error, "Appserver glue: Received unknown gen_server cast :~n~p", [Msg]),
    {noreply, State, ?TIMEOUT}.

%%--------------------------------------------------------------------
%% Function: handle_info(Msg, State)
%% Descrip.: Handling all non call/cast messages
%% Returns : {noreply, State}          |
%%           {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: handle_info({servertransaction_cancelled, FromPid, EH}
%%           FromPid = pid() (callhandler_pid)
%%           EH      = list() of {Key, ValueList} tuples, extra
%%                     headers to include in the CANCEL requests
%% Descrip.: Our server transaction (CallHandlerPid) signals that it
%%           has been cancelled. Send {cancel_pending, EH} to our
%%           sipproxy process (ForkPid).
%% Returns : {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info({servertransaction_cancelled, FromPid, EH}, #state{callhandler_pid=FromPid} = State) when is_pid(FromPid) ->
    ForkPid = State#state.forkpid,
    logger:log(debug, "Appserver glue: Original request has been cancelled, sending " ++
	       "'cancel_pending' to ForkPid ~p and entering state 'cancelled' (answering '487 Request Cancelled')",
	       [ForkPid]),
    %% By not doing util:safe_signal(...), we crash (and return 500) instead of returning 487 if this fails
    ForkPid ! {cancel_pending, EH},
    transactionlayer:send_response_handler(State#state.callhandler, 487, "Request Cancelled"),
    NewState1 = State#state{cancelled=true},
    check_quit({noreply, NewState1, ?TIMEOUT}, none);

%%--------------------------------------------------------------------
%% Function: handle_info({servertransaction_terminated, FromPid}, ...
%%           FromPid = pid() (callhandler_pid)
%% Descrip.: Our server transaction (CallHandlerPid) signals that it
%%           has terminated. We have no business when either our
%%           server transaction, or our sipproxy has terminated so
%%           we might as well quit too. This will make sipproxy
%%           exit, which will make the client transactions cancel
%%           themselves if they are not already finished.
%% Returns : {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info({servertransaction_terminating, FromPid}, #state{callhandler_pid=FromPid}=State) when is_pid(FromPid) ->
    {CallHandlerPid, ForkPid} = {State#state.callhandler_pid, State#state.forkpid},
    logger:log(debug, "Appserver glue: received servertransaction_terminating from my CallHandlerPid ~p "
	       "(ForkPid is ~p) - terminating (completed: ~p)", [CallHandlerPid, ForkPid, State#state.completed]),
    check_quit({stop, normal, State});

%%--------------------------------------------------------------------
%% Function: handle_info({sipproxy_response, FromPid, Branch,
%%                       Response}, State)
%%           FromPid  = pid() (forkpid)
%%           Branch   = string()
%%           Response = response record()
%% Descrip.: Our sipproxy has received a response that it was supposed
%%           to forward to the TU (transaction user, us). Check it out
%%           to see what we should do with it (forward it to the
%%           server transaction, or just ignore it - depends on our
%%           sipstate).
%% Returns : {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info({sipproxy_response, FromPid, _Branch, Response}, #state{forkpid=FromPid}=State)
  when is_record(Response, response), is_pid(FromPid) ->
    NewState = handle_sipproxy_response(Response, State),
    check_quit({noreply, NewState, ?TIMEOUT});

%%--------------------------------------------------------------------
%% Function: handle_info({sipproxy_all_terminated, FromPid,
%%                        FinalResponse}, State)
%%           FromPid  = pid() (forkpid)
%%           FinalResponse = response record() | {Status, Reason}
%%           Status = integer(), SIP status code
%%           Reason = string(), SIP reason phrase
%% Descrip.: Our sipproxy says that now, all it's client transactions
%%           are finished. It hands us either a final response
%%           as a record(), which we might or might not have seen
%%           before (so we check if we should forward it to the server
%%           transaction), or an (error) response as a tuple that it
%%           wants us to tell the server transaction to generate.
%% Returns : {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info({sipproxy_all_terminated, FromPid, FinalResponse}, #state{forkpid=FromPid}=State) when is_pid(FromPid) ->
    CallHandler = State#state.callhandler,
    NewState1 =
	case State#state.cancelled of
	    true ->
		logger:log(debug, "Appserver glue: received sipproxy_all_terminated - request was "
			   "previously cancelled. Silently enter state 'completed'."),
		State#state{completed=true};
	    false ->
		case FinalResponse of
		    _ when is_record(FinalResponse, response) ->
			logger:log(debug, "Appserver glue: received sipproxy_all_terminated with a '~p ~s' "
				   "response (completed: ~p)", [FinalResponse#response.status,
								FinalResponse#response.reason,
								State#state.completed]),
			handle_sipproxy_response(FinalResponse, State);
		    {Status, Reason} when is_integer(Status), Status >= 200, is_list(Reason) ->
			logger:log(debug, "Appserver glue: received sipproxy_all_terminated - asking CallHandler "
				   "~p to answer '~p ~s'", [CallHandler, Status, Reason]),
			send_final_response(State, Status, Reason)
		end
	end,
    check_quit({noreply, NewState1, ?TIMEOUT});

%%--------------------------------------------------------------------
%% Function: handle_info({sipproxy_no_more_actions, FromPid}, State)
%%           FromPid  = pid() (forkpid)
%% Descrip.: Our sipproxy says that it has no more actions to perform.
%%           Check if we have sent a final response by now, and if so
%%           just ignore this signal. If we haven't sent a final
%%           response yet we check if we should generate a
%%           '408 Request Timeout' response.
%% Returns : {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info({sipproxy_no_more_actions, FromPid}, #state{forkpid=FromPid}=State) when is_pid(FromPid) ->
    NewState1 =
	case State#state.cancelled of
	    true ->
		logger:log(debug, "Appserver glue: received sipproxy_no_more_actions when cancelled. Ignoring."),
		State#state{completed=true};
	    false ->
		case State#state.completed of
		    false ->
			Request = State#state.request,
			{Method, URI} = {Request#request.method, Request#request.uri},
			logger:log(debug, "Appserver glue: received sipproxy_no_more_actions when NOT cancelled "
				   "(and not completed), responding 408 Request Timeout to original request ~s ~s",
				   [Method, sipurl:print(URI)]),
			send_final_response(State, 408, "Request Timeout");
		    true ->
			logger:log(debug, "Appserver glue: received sipproxy_no_more_actions "
				   "when already completed - ignoring"),
			State
		end
	end,
    check_quit({noreply, NewState1, ?TIMEOUT});

%%--------------------------------------------------------------------
%% Function: handle_info({sipproxy_terminating, FromPid}, State)
%%           FromPid  = pid() (forkpid)
%% Descrip.: Our sipproxy is terminating. We might as well terminate
%%           too. If we haven't sent a final response to our server
%%           transaction yet, it will detect us exiting and generate a
%%           500 Server Internal Error.
%% Returns : {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info({sipproxy_terminating, FromPid}, #state{forkpid=FromPid}=State) when is_pid(FromPid) ->
    {CallHandlerPid, ForkPid} = {State#state.callhandler_pid, State#state.forkpid},
    logger:log(debug, "Appserver glue: received sipproxy_terminating from my ForkPid ~p (CallHandlerPid is ~p) "
	       "- exiting normally (completed: ~p).", [ForkPid, CallHandlerPid, State#state.completed]),
    check_quit({stop, normal, State});

%%--------------------------------------------------------------------
%% Function: handle_info(timeout, State)
%% Descrip.: For some reason, we are still alive. Check if we should
%%           just garbage collect our way out of here.
%% Returns : {noreply, NewState, ?TIMEOUT}
%% Notes   : XXX maybe we should log this as an error. This should
%%           always be an indication that _something_ is wrong - even
%%           if it really is something in the transaction layer or
%%           wherever.
%%--------------------------------------------------------------------
handle_info(timeout, State) ->
    {CallHandler, ForkPid} = {State#state.callhandler, State#state.forkpid},
    logger:log(error, "Appserver glue: Still alive after 5 minutes! Exiting. CallHandler '~p', ForkPid '~p'",
	       [CallHandler, ForkPid]),
    util:safe_signal("Appserver glue: ", ForkPid, {showtargets}),
    check_quit({stop, "appserver_glue should not live forever", State});

handle_info(Info, State) ->
    logger:log(error, "Appserver glue: Received unknown signal :~n~p", [Info]),
    {noreply, State, ?TIMEOUT}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State)
%% Descrip.: Shutdown the server
%% Returns : any (ignored by gen_server)
%%--------------------------------------------------------------------
terminate(Reason, State) ->
    {Request, BranchBase} = {State#state.request, State#state.branchbase},
    {Method, URI} = {Request#request.method, Request#request.uri},
    case Reason of
	normal ->
	    logger:log(normal, "~s: Appserver glue: Finished with fork (~s ~s), exiting.",
		       [BranchBase, Method, sipurl:print(URI)]);
	_ ->
	    logger:log(error, "~s: Appserver glue: Terminating fork (~s ~s), exiting ABNORMALLY.",
		       [BranchBase, Method, sipurl:print(URI)]),
	    logger:log(debug, "Appserver glue: Abnormally exiting with reason :~n~p", [Reason])
    end,
    Reason.

%%--------------------------------------------------------------------
%% Function: code_change(OldVsn, State, Extra)
%% Descrip.: Convert process state when code is changed
%% Returns : {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: check_quit(Res)
%%           check_quit(Res, From)
%%           Res  = term(), gen_server:call/cast/info() return value
%%           From = term(), gen_server from-value | none
%% Descrip.: Wrapper function checking if our server transaction
%%           (callhandler) or our sipproxy (forkpid) is dead. If so,
%%           If so, turn Res into a {stop, ...} but if Res was a
%%           {reply, ...} do the gen_server:reply() first.
%% Returns : Res                   |
%%           {stop, Reason, State}            (terminate/2 is called)
%% Note    : Not all variants of gen_server call/cast/info return
%%           values are covered in these functions - only the ones we
%%           actually use!
%%--------------------------------------------------------------------
check_quit(Res) ->
    check_quit(Res, none).

check_quit(Res, From) ->
    case Res of
	{stop, _Reason, State} when is_record(State, state) ->
	    check_quit2(Res, From, State);
	{noreply, State, _Timeout} when is_record(State, state) ->
	    check_quit2(Res, From, State)
    end.

%% part of check_quit/2
check_quit2(Res, From, #state{cpl_pid=CPLpid, forkpid=FP}=State) when CPLpid /= none, FP == none ->
    %% When we are executing a CPL script, we never have a callhandler, so just check forkpid
    logger:log(debug, "Appserver glue: We are executing on behalf of a CPL script and ForkPid is 'none' - terminating"),
    check_quit2_terminate(Res, From, State);

check_quit2(Res, From, #state{callhandler=CH, forkpid=FP}=State) when CH == none; FP == none ->
    logger:log(debug, "Appserver glue: CallHandler (~p) or ForkPid (~p) is 'none' - terminating",
	       [CH, FP]),
    check_quit2_terminate(Res, From, State);

check_quit2(Res, _From, State) when is_record(State, state) ->
    %% Not time to quit yet
    Res.

%% part of check_quit2(), turn Res into a {stop, ...}.
check_quit2_terminate(Res, _From, State) ->
    NewReply = case Res of
		   {noreply, _State, _Timeout} ->
		       {stop, normal, State};
		   {stop, _Reason, _State} ->
		       Res
	       end,
    NewReply.

%%--------------------------------------------------------------------
%% Function: send_final_response(State, Status, Reason)
%%           State = state record()
%%           Status = integer(), SIP status code
%%           Reason = string(), SIP reason phrase
%% Descrip.: We have a final response to deliver.
%%           * Non-CPL : Send a final response to our server
%%             transaction (aka. callhandler).
%%           * CPL : Check if it is a 2xx response. If it is, we send
%%             it to the server transaction directly and then tell the
%%             CPL pid about it. If it is not a 2xx response, just
%%             tell the CPL pid about it.
%% Returns : State = state record()
%%--------------------------------------------------------------------
send_final_response(#state{cpl_pid=none}=State, Status, Reason) when is_integer(Status), is_list(Reason) ->
    TH = State#state.callhandler,
    transactionlayer:send_response_handler(TH, Status, Reason),
    State#state{completed=true};
send_final_response(State, Status, Reason) when is_record(State, state), is_integer(Status), is_list(Reason) ->
    Response = {Status, Reason},
    if
	Status >= 200, Status =< 299 ->
	    %% We send 2xx responses to the server transaction directly, and just tell CPL about it afterwards
	    transactionlayer:send_response_handler(State#state.callhandler, Status, Reason);
	true -> true
    end,
    State#state.cpl_pid ! {appserver_glue_final_response, self(), Response},
    State#state{completed=true}.

%%--------------------------------------------------------------------
%% Function: handle_sipproxy_response(Response, State)
%%           Response = response record()
%%           State    = state record()
%% Descrip.: Process a response we have received from our sipproxy
%%           process and figure out what to do with it. See if we
%%           should send it on to our parent and record if this was a
%%           final response (set State#state.completed=true if so).
%% Returns : State = state record() | does not return
%%--------------------------------------------------------------------
%%
%% Method is INVITE and we are already completed
%%
handle_sipproxy_response(Response, #state{request=Request, completed=true}=State)
  when is_record(Response, response), is_record(Request, request), Request#request.method == "INVITE" ->
    URI = Request#request.uri,
    {Status, Reason} = {Response#response.status, Response#response.reason},
    if
	Status >= 200, Status =< 299 ->
	    %% XXX change to debug level? Might be good to see in the log though, since
	    %% resends of the 200 Ok means that the ACK is not getting through.
	    logger:log(normal, "Appserver glue: Forwarding 'late' 2xx response, ~p ~s to INVITE ~s statelessly",
		       [Status, Reason, sipurl:print(URI)]),
	    transportlayer:send_proxy_response(none, Response);
	true ->
	    logger:log(error, "Appserver glue: NOT forwarding non-2xx response ~p ~s to INVITE ~s - " ++
		       "a final response has already been forwarded (sipproxy should not do this!)",
		       [Status, Reason, sipurl:print(URI)]),
	    erlang:error(more_than_one_final_response, [Response, State])
    end,
    State;
%%
%% Method is non-INVITE and we are already completed
%%
handle_sipproxy_response(Response, #state{completed=true}=State) when is_record(Response, response) ->
    Request = State#state.request,
    {Method, URI} = {Request#request.method, Request#request.uri},
    {Status, Reason} = {Response#response.status, Response#response.reason},
    logger:log(error, "Appserver glue: NOT forwarding response ~p ~s to non-INVITE request ~s ~s - " ++
	       "a final response has already been forwarded (sipproxy should not do this!)",
	       [Status, Reason, Method, sipurl:print(URI)]),
    erlang:error(more_than_one_final_response, [Response, State]);

%%
%% We are not yet completed, this is not a provisional response, and we have a CPL-pid in State.
%% Forward response to the CPL-pid, so that it can take whatever action the CPL-script stipulates.
%%
handle_sipproxy_response(#response{status=Status}=Response, #state{cpl_pid=CPLpid}=State)
  when is_pid(CPLpid), Status >= 200 ->
    Request = State#state.request,
    {Method, URI} = {Request#request.method, Request#request.uri},
    {Status, Reason} = {Response#response.status, Response#response.reason},
    %% We always tell CallHandler about 2xx responses
    if
	Status >= 200, Status =< 299 ->
	    CallHandler = State#state.callhandler,
	    logger:log(debug, "Appserver glue: Forwarding response '~p ~s' to '~s ~s' to CallHandler ~p",
		       [Status, Reason, Method, sipurl:print(URI), CallHandler]),
	    transactionlayer:send_proxy_response_handler(CallHandler, Response);
	true -> true
    end,
    %% Now, tell CPLpid about the final response
    CPLpid = State#state.cpl_pid,
    logger:log(debug, "Appserver glue: Forwarding final response '~p ~s' to '~s ~s' to CPL-pid ~p",
	       [Status, Reason, Method, sipurl:print(URI), CPLpid]),
    CPLpid ! {appserver_glue_final_response, self(), Response},
    State#state{completed=true};
%%
%% We are not yet completed, and State does not contain a CPL-pid, or this is a provisional
%% response so we basically forward the response to our CallHandler, and if if it >= 200 we
%% set 'completed' to 'true'.
%%
handle_sipproxy_response(Response, State) when is_record(Response, response), is_record(State, state) ->
    Request = State#state.request,
    {Method, URI} = {Request#request.method, Request#request.uri},
    {Status, Reason} = {Response#response.status, Response#response.reason},
    CallHandler = State#state.callhandler,
    logger:log(debug, "Appserver glue: Forwarding response '~p ~s' to '~s ~s' to CallHandler ~p",
	       [Status, Reason, Method, sipurl:print(URI), CallHandler]),
    transactionlayer:send_proxy_response_handler(CallHandler, Response),
    if
	Status >= 200 ->
	    State#state{completed=true};
	true ->
	    State
    end.
