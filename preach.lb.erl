
-module(preach).
-export([run/0,startWorker/7,ready/1, doneNotDone/4, load_balancer/3]).
-include("common.lb.erl").

-ifndef(NOFLOW).
-define(NOFLOW,false).
-endif.

-record(r,
	{tf, % tracefile
	 wq, % work queue
	 ss, % state set
	 count, % # states in hash file
	 names, % process list
	 id, % index into names array 
	 term, % terminator pid
	 th, % trace handler pid
	 sent, % states sent
	 recd, % states recd
	 t0,   % initial time
	 fc,    % flow control record
	 selfbo, % backoff flag 
	 bov, % backoff vector
	 recyc, % recycling flag
	 usesym, % symmetry reduction flag
	 bo_bound,  % BackOff bound; max size of message queue before backoff kicks in
	 unbo_bound,% UnBackOff bound; when message queue gets this small and we're in back-off mode, we send Unbackoff
	 checkdeadlocks,
	 profiling_rate,  % determines how often profiling info is spat out
	 lb_pending,
	 lb_pid
	}).


%%----------------------------------------------------------------------
%% Function: startWorker/0
%% Purpose : Initializes a worker thread by receiving the list of PIDs and 
%%		calling reach().
%% Args    : 
%%
%% Returns : ok
%%     
%%----------------------------------------------------------------------
startWorker(ModelName, UseSym, BoBound, UnboBound,HashSize,CheckDeadlocks,Profiling_rate) ->
    io:format("Host ~s; PID ~w: startWorker() entered (model is ~s;UseSym is ~w;CheckDeadlocks is ~w)~n", 
	      [second(inet:gethostname()),self(),ModelName,UseSym,CheckDeadlocks]),
						%crypto:start(),
    receive {Names, names} -> do_nothing end,
    receive {trace_handler, TraceH} -> nop end,
    receive {terminator, Terminator} -> nop end,
    receive {lbPid, LBPid} -> nop end,
    MyID = indexOf(self(), tuple_to_list(Names)),
    murphi_interface:start(ModelName),
    murphi_interface:init_hash(HashSize),
    WQ = initWorkQueue(),
    TF = initTraceFile(),
%% IF YOU WANT BLOOM...
%%    reach(#r{ss= bloom:bloom(200000000, 0.00000001),
%% ELSE
    reach(#r{ss=null,
%% ENDIF
	     names=Names, term=Terminator, th=TraceH,
	     sent=0, recd=0, count=0, bov=initBov(Names), selfbo=false, 
	     wq=WQ, tf=TF, id=MyID,
	     t0=1000000 * element(1,now()) + element(2,now()), usesym=UseSym, checkdeadlocks=CheckDeadlocks,
	     bo_bound=BoBound, unbo_bound=UnboBound, lb_pid = LBPid, lb_pending=false, profiling_rate = Profiling_rate }), 
    %%murphi_interface:stop(),
    OmissionProb =  1.0 - murphi_interface:probNoOmission(),
    io:format("PID ~w: Worker is done; Pr[even one omitted state] <= ~w; No. of hash collisions = ~w~n",
              [self(),OmissionProb,murphi_interface:numberOfHashCollisions()]),
    ok.

%%----------------------------------------------------------------------
%% Function: reach/9
%% Purpose : Removes the first state from the list, 
%%		generates new states returned by the call to transition that
%%		are appended to the list of states. Recurses until there
%%		are no further states to process. 
%% Args    : Tracefile is a disk-based queue containing trace info for 
%%          generating a counter-example when an invariant fails
%%           WorkQueue is a disk-based queue containing a set of states to
%%          be expanded;
%%	     Names is a list of worker's PIDs;
%%	     BigList is a bloom filter containing the set of reachable states
%%          computed so far by this node;
%%	     {NumSent, NumRecd} is the running total of the number of states	
%%	    sent and received, respectively	
%%	     SendList is the accumulated list of states to be sent to other
%%          workers for expansion
%%	     Count is used to count the number of visited states
%%           T0 is running time
%%           QSize is the size of the WorkQueue
%%
%% Returns : done
%%     
%%----------------------------------------------------------------------
reach(R=#r{names=Names, count=Count, sent=NumSent, th=TraceH, id=MyID, recyc=Recycling, usesym=UseSym, checkdeadlocks=CheckDeadlocks } ) ->
    case recvStates(R) of
	done -> done;
	R2=#r{wq=WorkQueue, tf=TF, bov=Bov} ->
	    {[{State,Recycled}], Q2} = dequeue(WorkQueue),
	    if Recycled -> % prevent too much printing during recycling
		    nop;
	       true ->
		    profiling(R)
	    end,
	    NewStates = transition(State),
	    case NewStates of  
		[] ->
		    if (CheckDeadlocks) ->
			    io:format("Found (global) deadlock state.~n",[]),
			    io:format("Just in case cex constructiong fails, here it is:~n",[]),
			    printState(State),
			    TraceH ! {error_found, self(), State},
			    traceMode(Names, TF, TraceH, UseSym);
		       true -> ok 
		    end;
		{error,ErrorMsg,RuleNum}  ->
		    io:format("Murphi Engine threw an error evaluating rule \"~s\" (likely an assertion in the Murphi model failed):~n~s~n",[ErrorMsg,murphi_interface:rulenumToName(RuleNum)]),
		    io:format("Just in case cex constructiong fails, here it is:~n",[]),
		    printState(State),
		    TraceH ! {error_found, self(), State},
		    traceMode(Names, TF, TraceH, UseSym);
		_ ->
		    NewCanonicalizedStates = canonicalizeStates(NewStates, UseSym),
		    FailedInvariant = checkInvariants(State),
		    if (FailedInvariant /= null) ->
			    io:format("Found Invariant Failure (~s)~n",[FailedInvariant]),
			    io:format("Just in case cex constructiong fails, here it is:~n",[]),
			    printState(State),
			    TraceH ! {error_found, self(), State},
			    traceMode(Names, TF, TraceH, UseSym);
		       true ->
			    SendSuccessful = tryToSendStates(State, NewCanonicalizedStates, Names, Bov),
			    if (SendSuccessful) ->
				    NewWQ = Q2,
				    NewNumSent = NumSent + length(NewCanonicalizedStates),
				    NewCount = Count+1,
				    NewRecycling = false;
			       true ->
				    NewWQ = enqueue(Q2,{State,true}),
				    NewNumSent = NumSent,
				    NewCount = Count,
				    NewRecycling = true
			    end,
			    reach(R2#r{tf=TF, wq=NewWQ, count=NewCount, sent=NewNumSent, recyc=NewRecycling})
		    end
	    end
    end.

secondsSince(T0) ->
    {M, S, _} = now(),
    (1000000 * M + S) - T0 + 1.

%%----------------------------------------------------------------------
%% Purpose : Polls for incoming messages within a time window
%%
%% Args    : BigListSize is used only to report the size upon termination;
%%	     Names is a list of worker's PIDs;
%%	     {NumSent, NumRecd} is the running total of the number of states
%%	    sent and received, respectively;
%%	     NewStates is an accumulating list of the new received states;
%%           QSize keeps track of the size of the working Queue
%%----------------------------------------------------------------------
recvStates(R=#r{sent=NumSent, recd=NumRecd, count=NumStates, wq=WorkQ, ss=StateSet, tf=TF, t0=T0,
		th=TraceH, names=Names, term=Terminator, bov=Bov, selfbo=SelfBo, usesym=UseSym,
		bo_bound=BoBound, unbo_bound=UnboBound, lb_pid=LBPid, lb_pending=LB_pending }) ->
    WQSize = count(WorkQ),
    Runtime = secondsSince(T0),
    {_, RuntimeLen} = process_info(self(),message_queue_len),
    if (SelfBo andalso (RuntimeLen < UnboBound)) ->
	    io:format("(~s) Sending UNBACKOFF~n", [second(inet:gethostname())]),
	    sendAllPeers(goforit,Names),
	    recvStates(R#r{selfbo=false});
       ((not SelfBo) andalso (RuntimeLen > BoBound)) ->
	    io:format("(~s) Sending BACKOFF, RuntimeLen is ~w, SelfBo is ~w~n",
		      [second(inet:gethostname()),RuntimeLen,SelfBo]),
	    sendAllPeers(backoff,Names),
	    recvStates(R#r{selfbo=true});
       ((WQSize == 0) and (Runtime > 30) and not LB_pending) ->
	    LBPid ! { im_feeling_idle, self() },
	    recvStates(R#r{lb_pending=true});
       true ->
	    if (WQSize == 0) ->
		    TermDelay = spawn(?MODULE, doneNotDone, [Terminator, NumSent, NumRecd, NumStates]),
		    Timeout = infinity;
	       true -> 
		    TermDelay = none,
		    Timeout = 0
	    end,
	    receive Msg ->
		    if WQSize == 0 -> TermDelay ! not_done;
		       true -> nop
		    end,
		    case Msg of
			{{State, Prev}, state} ->
			    Test = murphi_interface:brad_hash(State),
			    if Test == false -> % State not present
				    Q2 = enqueue(WorkQ,{State,false}),	
				    TF2 = diskq:enqueue(TF, {State, Prev}),
				    recvStates(R#r{recd=NumRecd+1, wq=Q2, tf=TF2});
			       true -> 
				    recvStates(R#r{recd=NumRecd+1})
			    end;
			{lb_nack} -> 
			    recvStates(R#r{lb_pending=false});
			{wq_length_query,_} -> 
			    LBPid !  {wq_query_response,WQSize,self()},
			    recvStates(R);
			{send_some_of_your_wq_to,IdlePid,Ratio} -> 
			    io:format("(~s.~w) sending ~w percent of my states to ~w~n", [second(inet:gethostname()),self(),Ratio,IdlePid]),
			    NumberToSend = (Ratio * WQSize) div 100,
			    {StateList,Q2} = dequeueMany(WorkQ, NumberToSend),
			    IdlePid ! {extraStateList, StateList},
			    %%recvStates(R#r{sent=NumSent+NumberToSend, wq=Q2});
			    recvStates(R#r{sent=NumSent, wq=Q2});
			{extraStateList, StateList} -> 
			    StateListLen = length(StateList),
			    io:format("(~s.~w) got ~w extra states~n", [second(inet:gethostname()),self(),StateListLen]),
			    Q2 = enqueueMany(WorkQ, StateList),
			    %%recvStates(R#r{recd=NumRecd+StateListLen,wq=Q2, lb_pending=(StateList == [])});
			    recvStates(R#r{recd=NumRecd,wq=Q2, lb_pending=(StateList == [])});
			{backoff,Pid} ->
			    ets:insert(Bov, {Pid, true}),
			    recvStates(R#r{bov=Bov});
			{goforit,Pid} ->
			    ets:insert(Bov, {Pid, false}),
			    recvStates(R#r{bov=Bov});
			die -> done;
			{tc, Pid}   ->
			    io:format("(~s.~w) got tc~n", [second(inet:gethostname()),self()]),
			    Pid ! {ack, self()},
			    traceMode(Names, TF, TraceH, UseSym)
		    end
	    after Timeout -> R end
    end.



profiling(#r{selfbo=SelfBo,count=Count, t0=T0, sent=NumSent, recd=NumRecd, wq=WorkQ,profiling_rate=PR})->
    if Count rem PR == 0 ->
	    Runtime = secondsSince(T0),
	    {_, Mem} = process_info(self(),memory),
	    {CpuTime,_} = statistics(runtime),
	    WorkQ_heapSize =  erts_debug:flat_size(WorkQ) * 8, 
	    io:format("~n~s.~w: " ++
		      "~w states explored in ~w s (~.1f per sec) (cpu time: ~.1f; ~.1f per second ) " ++
		      "with ~w states sent, ~w states received " ++
		      "and ~w states in the queue (which is ~w bytes of heap space) " ++ 
		      "and Backoff = ~w and using ~w byts of RAM (according to process_info) ~n",
		      [second(inet:gethostname()), self(), Count, Runtime, Count / Runtime, CpuTime / 1000.0, 1000 * Count / CpuTime ,
		       NumSent, NumRecd, diskq:count(WorkQ), WorkQ_heapSize, SelfBo, Mem ]);
       true -> nop
    end.


dequeue(Q) -> diskq:dequeue(Q).

enqueueMany(WQ, []) -> WQ;

enqueueMany(WQ, [State | Rest]) ->
    Q2 = enqueue(WQ, {State,false}),
    enqueueMany(Q2, Rest).

dequeueMany(WQ, 0) ->
    {[], WQ};	

dequeueMany(WQ, Num) ->
    {[{State,Recycled}],Q2} = dequeue(WQ),
    {R3,Q3} = dequeueMany(Q2, Num-1),
    {[State | R3],Q3}.

doneNotDone(Terminator, NumSent, NumRecd, NumStates) ->
    receive not_done ->
	    nop
    after 5000 ->
	    Terminator ! { done, self(), NumSent, NumRecd, NumStates, murphi_interface:probNoOmission()  },
	    receive not_done ->
		    Terminator ! {not_done, self(), NumSent, NumRecd, NumStates}
	    end
    end.




