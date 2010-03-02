
-module(preach).
-export([run/0,startWorker/7,ready/1, doneNotDone/4]).
-include("common.erl").

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
	 bo_bound,  % BackOff bound; max size of message queue before
                % backoff kicks in
	 unbo_bound,% UnBackOff bound; when message queue gets
                % this small and we're in back-off mode, we send Unbackoff
     checkdeadlocks,% 
     profiling_rate  % determines how often profiling info is spat out
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
    crypto:start(),
    receive {Names, names} -> do_nothing end,
    receive {trace_handler, TraceH} -> nop end,
    receive {terminator, Terminator} -> nop end,
    MyID = indexOf(self(), tuple_to_list(Names)),
    murphi_interface:start(ModelName),
    murphi_interface:init_hash(HashSize),
    WQ = initWorkQueue(),
    TF = initTraceFile(),
% IF YOU WANT BLOOM...
%    reach(#r{ss= bloom:bloom(200000000, 0.00000001),
% ELSE
    reach(#r{ss=null,
% ENDIF
          names=Names, term=Terminator, th=TraceH,
	      sent=0, recd=0, count=0, bov=initBov(Names), selfbo=false, 
	      wq=WQ, tf=TF, id=MyID,
	      t0=1000000 * element(1,now()) + element(2,now()), usesym=UseSym, checkdeadlocks=CheckDeadlocks,
          bo_bound=BoBound, unbo_bound=UnboBound, profiling_rate=Profiling_rate }), 
    %murphi_interface:stop(),
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
	    {[{State, PrevState, Recycled, RecycStateID}], Q2} = dequeue(WorkQueue),
	    if Recycling -> % prevent too much printing during recycling
		    nop;
	       true ->
		    profiling(R)
	    end,
	    if Recycled == 0 ->
		    StateID = diskq:count(TF),
		    TF2 = diskq:enqueue(TF, {State, PrevState});
	       true  ->
		    StateID = RecycStateID,
		    TF2 = TF
	    end,
	    NewStates = transition(State),
        if (CheckDeadlocks andalso (NewStates == [])) ->
		    io:format("Found (global) deadlock state.~n",[]),
		    io:format("Just in case cex constructiong fails, here it is:~n",[]),
            printState(State),
		    TraceH ! {error_found, self(), StateID},
		    traceMode(Names, TF2, TraceH, UseSym);
        (is_integer(hd(NewStates))) -> % this will hold iff NewStates is an error message 
		    io:format("Murphi Engine threw an error (likely an assertion in the Murphi model failed):~n~s~n",[NewStates]),
		    io:format("Just in case cex constructiong fails, here it is:~n",[]),
            printState(State),
		    TraceH ! {error_found, self(), StateID},
		    traceMode(Names, TF2, TraceH, UseSym);
        true ->
	    NewCanonicalizedStates = canonicalizeStates(NewStates, UseSym),
	    FailedInvariant = checkInvariants(State),
	    if (FailedInvariant /= null) ->
		    io:format("Found Invariant Failure (~s)~n",[FailedInvariant]),
		    io:format("Just in case cex constructiong fails, here it is:~n",[]),
            printState(State),
		    TraceH ! {error_found, self(), StateID},
		    traceMode(Names, TF2, TraceH, UseSym);
	       true ->
		    SendSuccessful = tryToSendStates({MyID, StateID}, NewCanonicalizedStates, Names, Bov),
		    if (SendSuccessful) ->
			    NewWQ = Q2,
			    NewNumSent = NumSent + length(NewCanonicalizedStates),
			    NewCount = Count+1,
			    NewRecycling = false;
		       true ->
			    NewWQ = enqueue(Q2,{State, PrevState, 1, StateID}),
			    NewNumSent = NumSent,
			    NewCount = Count,
			    NewRecycling = true
		    end,
		    reach(R2#r{tf=TF2, wq=NewWQ, count=NewCount, sent=NewNumSent, recyc=NewRecycling})
	    end
	    end
    end.

doneNotDone(Terminator, NumSent, NumRecd, NumStates) ->
    receive not_done ->
	    nop
    after 5000 ->
	    Terminator ! { done, self(), NumSent, NumRecd, NumStates, murphi_interface:probNoOmission()  },
	    receive not_done ->
		    Terminator ! {not_done, self(), NumSent, NumRecd, NumStates}
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
recvStates(R=#r{sent=NumSent, recd=NumRecd, count=NumStates, wq=WorkQ, ss=StateSet, tf=TF,
	        th=TraceH, names=Names, term=Terminator, bov=Bov, selfbo=SelfBo, usesym=UseSym,
            bo_bound=BoBound, unbo_bound=UnboBound }) ->
    WQSize = count(WorkQ),
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
       true ->
	    if WQSize > 0 ->
		    TermDelay = none,
		    Timeout = 0;
	       true ->
		    TermDelay = spawn(?MODULE, doneNotDone, [Terminator, NumSent, NumRecd, NumStates]),
		    Timeout = 60000
	    end,
	    receive
		Msg ->
		    if WQSize == 0 ->
			    TermDelay ! not_done;
		       true -> nop
		    end,
		    case Msg of
			{{State, Prev}, state} ->
% IF YOU WANT BLOOM...
%			    case bloom:member(State, StateSet) of 
%				true ->
%				    recvStates(R#r{recd=NumRecd+1});
%				false ->
%				    Q2 = enqueue(WorkQ, {State, Prev, 0, 0}),
%				    SS2 = bloom:add(State, StateSet),
%%                   % printState(State), 
%				    recvStates(R#r{recd=NumRecd+1, ss=SS2, wq=Q2})
%		  	end;
% ELSE
				Test = murphi_interface:brad_hash(State),
				if Test == false -> % State not present
				     Q2 = enqueue(WorkQ,{State, Prev, 0,0}),	
					 recvStates(R#r{recd=NumRecd+1, wq=Q2});
				true -> % State was present
					recvStates(R#r{recd=NumRecd+1})
				end;
% ENDIF
			{backoff,Pid} ->
			    ets:insert(Bov, {Pid, true}),
			    recvStates(R#r{bov=Bov});
			{goforit,Pid} ->
			    ets:insert(Bov, {Pid, false}),
			    recvStates(R#r{bov=Bov});
			die -> done;
			{tc, Pid}   ->
			    Pid ! {ack, self()},
			    traceMode(Names, TF, TraceH, UseSym)
		    end
	    after Timeout ->
		    if Timeout == 60000 ->
			    io:format("Node ~s (~w) 60 secs without any states~n", [second(inet:gethostname()), self()]),
			    TermDelay ! not_done,
			    recvStates(R);
		       true ->
			    R
		    end
	    end
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
