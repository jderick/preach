
%% Purpose : Main function to be called 
run() ->
    start(length(hosts())).

%% Purpose : Uses Erlang's slave library to start remote processes
makeLink([], _Args) -> ok;

makeLink([Host | Rest], Args) ->
    S = re:split(atom_to_list(Host), "[@]", [{return, list}]),
    Machine = list_to_atom(lists:nth(1,tl(S))),
    Name = list_to_atom(hd(S)),
    io:format("For sanity: Machine: ~w, Name: ~w~n", [Machine,Name]),	
    case slave:start_link(Machine, Name, Args) of
	{ok, Node} ->
	    io:format("Erlang node started = [~p]~n", [Node]),
	    makeLink(Rest, Args);
	{error,timeout} ->
	    io:format("Could not connect to host ~w...Exiting~n",[Host]),
	    halt();
	{error,Reason} ->
	    io:format("Could not start workers: Reason= ~w...Exiting~n",[Reason]),
	    halt()
    end.


%%----------------------------------------------------------------------
%% Function: start/1
%% Purpose : It sets up all worker nodes/threads, starts the murphi interface
%%           and start the actual model-checking by sending the initial states 
%%           to the workers
%% Args    : P is the number of Erlang threads to use;
%%      
%% Returns :
%%     
%%----------------------------------------------------------------------
start(P) ->
    io:format("PReach $Rev: 408 $~n", []),
    T0 = now(),
    Local = is_localMode(),
    if Local ->
	    ok;
       true ->
	    Args = "-pa " ++ os:getenv("PREACH_ROOT") ++ " -rundir " ++ os:getenv("PWD") ++ " -model " ++ model_name(),
	    makeLink(hosts(), Args),
	    %% invalidate nfs cache to ensure latest beam files are loaded
	    Rand = integer_to_list(random:uniform(1000000000)),
	    lists:map(
	      fun(X) ->
		      rpc:call(X, os, cmd, ["echo " ++ Rand ++ " > " ++ os:getenv("PREACH_ROOT") ++ "/nfsinval"]),
		      rpc:call(X, os, cmd, ["echo " ++ Rand ++ " > " ++ os:getenv("PWD") ++ "/nfsinval"])
	      end,
	      hosts())
    end,
    Names = initThreads([], P),
    lists:map(fun(X) -> X ! {trace_handler, self()} end, tuple_to_list(Names)),
    lists:map(fun(X) -> X ! {terminator, self()} end, tuple_to_list(Names)),
    murphi_interface:start(rundir(), model_name()),
    io:format("About to compute startstates... ~n",[]),
    SS = startstates(),
    case SS of 
	{error,ErrorMsg} -> 
	    io:format("Murphi found an error in a startstate:~n~s~n",[ErrorMsg]);
	_ -> 
	    CanonicalizedStartStates = canonicalizeStates(SS,init:get_argument(nosym) == error),
	    tryToSendStates({0, 0}, CanonicalizedStartStates, Names, initBov(Names)),
	    NumSent = length(startstates()),
	    io:format("~w (Root): sent ~w startstates~n",[self(),NumSent]),
	    case detectTermination(0, NumSent, 0, 0, Names, dict:new()) of
		{verified,NumStates,ProbNoOmission} ->
		    OmissionProb =  1.0 - ProbNoOmission,
		    Dur = timer:now_diff(now(), T0)*1.0e-6,
		    {CpuTime,_} = statistics(runtime),
		    io:format("----------~n" ++
			      "REPORT:~n" ++
			      "\tTotal of ~w states visited (this only accurate if no error or in localmode)~n" ++
			      "\tExecution time: ~f seconds~n" ++
			      "\tStates visited per second (real time): ~w~n" ++
			      "\tStates visited per second per thread (real time): ~w~n" ++ 
			      "\tStates visited per second (cpu time): ~w~n" ++
			      "\tPr[even one omitted state] <= ~w~n" ++
			      "----------~n",
			      [NumStates, Dur, trunc(NumStates/Dur), trunc((NumStates/Dur)/P),
			       trunc(1000 * NumStates/CpuTime),OmissionProb]);
		cex -> ok
	    end
    end,
    init:stop().


%%----------------------------------------------------------------------
%% Function: initThreads/2
%% Purpose : Spawns worker threads. Passes the command-line input to each thread.
%%           Sends the list of all PIDs to each thread once they've all been 
%%          spawned.
%% Args    : Names is a list of PIDs of threads spawned so far.
%%           NumThreads is the number of threads left to spawn.
%% Returns : FullNames: List of workers
%%     
%%----------------------------------------------------------------------
initThreads(Names, 0) ->        
    list_to_tuple(Names);

initThreads(Names, NumThreads) ->
    Local = is_localMode(),
    UseSym = init:get_argument(nosym) == error,
    CheckDeadlocks = init:get_argument(ndl) == error,
    BoBound =  getintarg(bob,10000),
    UnboBound =  getintarg(unbob,if BoBound == infinity -> null; true -> 1000 end ),
    HashSize = getintarg(m,1024),
    PR = getintarg(pr,10000),
    if Local ->
            ID = spawn(preach,startWorker,[model_name(), UseSym,infinity, null, HashSize,CheckDeadlocks,PR ]);
       true ->
            ID = spawnAndCheck(mynode(NumThreads),preach,startWorker,[model_name(), UseSym,BoBound,UnboBound, HashSize,CheckDeadlocks,PR ])
    end,
    io:format("Starting worker thread on ~w with PID ~w~n", 
              [mynode(NumThreads),ID]),
    FullNames = initThreads([ID | Names], NumThreads-1),
    ID ! {FullNames, names}, 
    FullNames. 

%% Purpose : Spawn the remote process and only returns when the remote
%%           process is up and responding
spawnAndCheck(Node, Module, Fun, Args) ->
    Pid = spawn(Node, Module, Fun, Args),
    case rpc:call(Node, erlang, is_process_alive, [Pid]) of
        true -> Pid;
        _ -> timer:sleep(1000),
             spawnAndCheck(Node, Module, Fun, Args)
    end.

%% Purpose : Implements Stern & Dill's termination algorithm
detectTermination(NumDone, GlobalSent, GlobalRecd, NumStates, Names,ProbDict) ->
    if NumDone == tuple_size(Names) andalso GlobalSent == GlobalRecd ->
            lists:map(fun(X) -> X ! die end, tuple_to_list(Names)),
            ProbNoOmission = dict:fold(fun(_,X,Y) -> X*Y end,1.0,ProbDict),
            {verified,NumStates,ProbNoOmission};
       true ->
            receive
                {done, Name, Sent, Recd, States, ProbNoOmission} ->
                    detectTermination(NumDone+1, GlobalSent+Sent, GlobalRecd+Recd, NumStates+States, 
                                      Names, dict:store(Name,ProbNoOmission,ProbDict));
                {not_done, Name, Sent, Recd, States} ->
                    detectTermination(NumDone-1, GlobalSent-Sent, GlobalRecd-Recd, NumStates-States, 
                                      Names, dict:erase(Name,ProbDict));
                {error_found, PID, State} -> 
                    Others = [X || X <- tuple_to_list(Names),  X /= PID],
                    lists:map(fun(X) ->
                                      io:format("Sending tc to ~w~n",[X]),
                                      X ! {tc, self()}
                              end,
                              Others),
                    checkAck(Others),
                    OwnerPid = owner(State,Names),
                    OwnerPid ! {find_prev, State, []},
                    receive trace_complete -> lists:map(fun(X) -> X ! die end, tuple_to_list(Names)) end,
                    cex
            end
    end.

%% Purpose: Helper function for findPrev. 
foldIndices(F, A0, L0, IQ) ->
    {_, A2, _} =
        diskq:foldl(fun (X, {N, A, L}) ->
                            case L of
                                [] -> {N + 1, A, []};
                                [H | T] ->
                                    if H == N ->
                                            {N + 1, F(X, A), T};
                                       true ->
                                            {N + 1, A, [H | T]}
                                    end
                            end
                    end,
                    {0, A0, L0},
                    IQ),
    A2.

%% Purpose : Used in traceComputation. Find the tuple w/ the matching state 
%%          and return the previous state.
findPrev(Index, TraceFile) ->
    R = foldIndices(fun (X, _A) -> X end, not_found, [Index], TraceFile),
    io:format("findPrev returning ~w~n",[R]),
    R.

%% Purpose :  Checks if received a backoff message
gottaBo([],_Bov) -> false;
gottaBo([Owner|Rest],Bov) -> 
    [{_, OwnerBo}] = ets:lookup(Bov, Owner),
    if (OwnerBo) ->
	    true;
       true ->
	    gottaBo(Rest, Bov)
    end.

%% Purpose : To send states to corresponding owners (nodes)
sendStates(_PrevState, [], [] ) -> ok;

sendStates(PrevState, [State | SRest], [Owner | ORest] ) ->
    Owner ! {{State,PrevState}, state},
    sendStates(PrevState, SRest, ORest).

%% Computes which node within Names owns State
owner(State,Names) -> 
    element(1+erlang:phash2(State,tuple_size(Names)), Names) .

%% Purpose :  Like sendStates, but first check if the state owner "is telling"
%%  to backoff
tryToSendStates(PrevState, States, Names,Bov ) ->
    Owners = lists:map(fun(S) -> owner(S,Names) end, States),
    GottaBo = gottaBo(Owners,Bov),
    if (GottaBo) ->
	    false;
       true ->
	    sendStates(PrevState, States, Owners),
	    true
    end.

%% Purpose: Broadcast Msg
sendAllPeers(Msg,Names) -> 
    NamesList = tuple_to_list(Names),
    PeersList = lists:filter(fun(Y) -> Y /= self() end,NamesList),
    lists:map(fun(Pid) -> Pid ! {Msg,self()} end,PeersList).

printTrace([]) -> ok;
printTrace([H | [] ]) -> 
    io:format("Here's the last state...~n",[]),
    printState(H);
printTrace([H | [H1 | T] ]) -> 
    printState(H),
    RuleNum = murphi_interface:whatRuleFired(H,H1),
    if RuleNum == -1 ->
	    %%io:format("Uh oh... Preach was asked to print an invalid trace!~n",[]),
	    %%error;
	    io:format("Bad Trans~n",[]),
	    printTrace([H1 | T]);
       true ->
	    io:format("~nRule ~s Fired~n~n",[murphi_interface:rulenumToName(RuleNum)]),
	    printTrace([H1 | T])
    end.

%% Purpose :  Computes a counter-example, starting from the state that
%%           violates an invariant. It searches it's local queue (disk-based)
%%           for the predecessor of 'State'. If it finds and it is not the
%%           start state, it iterates; if it is the start-state "0", then
%%           the counter-examples is done;
%% Args    : 
%%           Names is a list of worker's PIDs;
traceMode(Names, TraceFile, TraceH, UseSym) ->
    receive 
        {find_prev, Index, Trace} ->
            io:format("~w: Searching for ~w (UseSym = ~w)~n",[self(), Index,UseSym]),
            {Hash, {PrevOwner, PrevIndex}} = findPrev(Index, TraceFile),
            T2 = [Hash | Trace],
            if PrevOwner == 0 ->
                    io:format("------------------~n",[]),
                    io:format("Trace Length = ~w~nTrace:~n",[length(T2)]),
                    case constructCounterExample(UseSym,T2, startstates(),[]) of
			{done,Cex} -> io:format("Here's the first state...~n",[]),printTrace(Cex);
			_ -> io:format("counter example construction failed!!~n",[])
                    end,
                    TraceH ! trace_complete, 
                    traceMode(Names, TraceFile, TraceH,UseSym);
               true ->
                    Owner = element(PrevOwner, Names),
                    Owner ! {find_prev, PrevIndex, T2},
                    traceMode(Names, TraceFile, TraceH, UseSym) 
            end;
        {tc, Pid}   ->  Pid ! {ack, self()}; % in case two nodes find simultaneous failure
        die -> done
    end.


%%----------------------------------------------------------------------
%% Function: constructCounterExample/2
%% Purpose : Generate a counter-example based on the actual states instead
%%          of their lossy-compression
%%           Re-run model-checker starting from start-states, hashing
%%          each next state, comparing it w/ the trace. Upon success
%%          iterate until end of the trace
%%          
%%
%% Args    : Trace containing a list of hashed-states
%%           The set of states that results from computing transition
%%
%% Returns : It prints out on screen the trace. The return is token done.
%%     
%%----------------------------------------------------------------------
constructCounterExampleSymHelper(State,StateList) ->
    NormState = murphi_interface:normalize(State),
    HeuristicAndFastApproach = 
	lists:foldl(fun(X,Y) -> case (NormState == murphi_interface:normalize(X)) of true -> X; false -> Y end end, null,StateList),
    if (HeuristicAndFastApproach == null) ->
	    lists:foldl(fun(X,Y) -> case murphi_interface:equivalentStates(NormState,X) of true -> X; false -> Y end end, null,StateList);
       true ->
	    HeuristicAndFastApproach
    end.

constructCounterExample(_,[],_States,Cex) ->
    {done,Cex};

constructCounterExample(UseSym,[TraceHead | TraceTail], SetOfStates,Cex) ->
    NextState = 
	if (UseSym) ->
		constructCounterExampleSymHelper(TraceHead, SetOfStates);
	   true ->
		lists:foldl(fun(X,Y) -> case (TraceHead == X) of true -> X; false -> Y end end,
			    null,SetOfStates)
	end,
    io:format("construct Cex: length(Partial Cex) = ~w~n",[length(Cex)]),
    if (NextState == null) ->
	    io:format("constructCounterExample failure...~n~w~n~n",[TraceHead]),
	    {done,Cex};
       true -> 
	    NextStateSuccs = transition(NextState),
	    constructCounterExample(UseSym,TraceTail,NextStateSuccs,lists:append(Cex,[NextState]))
    end.


%% Purpose : Only intended to be used w/ trace generation. This function 
%%          works as a selective barrier

checkAck([]) -> ok;
checkAck(L) -> receive {ack, PID} ->
                       io:format("Received ack from ~w~n", [PID]),
                       checkAck(lists:delete(PID, L))
               end.


getintarg(X,D) ->
    case init:get_argument(X) of
        error -> D;
        {ok,[[V]]} ->
            case string:to_integer(V) of
                {error, _} -> D;
                {I, _} -> I
            end;
        _ -> D      
    end.


tmp_disk_path() ->
    case os:getenv("PREACH_TEMP") of
        false ->
            io:format("The env var PREACH_TEMP must be set.. exitting~n",[]), exit(1);
        P -> P
    end.

%% Purpose : The trace-file contains each unique transition of the system
%%           It's used for counter-example generation.
%%          
%% Returns : Depends on the the type of the queuing being used. Look at
%%          the definition of the function open

initTraceFile() ->
    diskq:open(tmp_disk_path() ++ "/tracefile." ++ atom_to_list(node()),
	       100000000000, getintarg(tfcache, 10000)).

%% Purpose : The workQueue keeps track of the frontier states to be 
%%          explored
%%           The workQueue can be stored in main memory or in disk depending
%%          upon the queuing system being used.  Look at the definition of 
%%          the function open 
%%          
%% Returns : Depends on the the type of the queuing being used. Look at
%%          the definition of the function open

initWorkQueue() ->
    diskq:open(tmp_disk_path() ++ "/workQueue." ++ atom_to_list(node()),
	       getintarg(wqsize, 50000000000), getintarg(wqcache, 10000)).

enqueue(Q, X) -> diskq:enqueue(Q, X).

count(Q) -> diskq:count(Q).

for_each_line_in_file(Name, Proc, Mode, Accum0) ->
    {ok, Device} = file:open(Name, Mode),
    for_each_line(Device, Proc, Accum0).

for_each_line(Device, Proc, Accum) ->
    case io:get_line(Device, "") of
        eof  -> file:close(Device), Accum;
        Line -> NewAccum = Proc(Line, Accum),
                for_each_line(Device, Proc, NewAccum)
    end.

%%----------------------------------------------------------------------
%% Function: hosts/0
%% Purpose : Identify which hosts will be the workers. 
%%           If spawning multiple workers, this function requires a file
%%          called "hosts" containing the name of a machines;
%%           Otherwise, it runs in one machine: the current, login machine
%% Args    : 
%%           
%%
%% Returns : list of hosts
%%     
%%----------------------------------------------------------------------
hosts() -> 
    Localmode = is_localMode(), %init:get_argument(localmode),
    if not Localmode  ->
            for_each_line_in_file("hosts", 
                                  fun (X, Y) -> 
                                          Y ++ [list_to_atom(
                                                  hd(string:tokens(X,"\t\n")))]
                                  end, 
                                  [read], 
                                  []);
       true ->
            [list_to_atom(second(inet:gethostname()))]
    end.

%%----------------------------------------------------------------------
%% Function: is_localMode/0
%% Purpose : Identify if localmode flag was passed to preach
%% Args    : 
%%           
%%
%% Returns : true or false
%%     
%%----------------------------------------------------------------------
is_localMode() -> init:get_argument(localmode) /= error.

model_name() -> 
    Name0 = init:get_argument(model),
    if (Name0 == error) ->
	    io:format("Missing required -model <model_name> argument.. exiting~n",[]),
	    exit(1);
       true ->
	    {_,Name} = Name0,
	    hd(hd(Name))
    end.

rundir() -> 
    Name0 = init:get_argument(rundir),
    if (Name0 == error) ->
	    os:getenv("PWD");
       true ->
	    {_,Name} = Name0,
	    hd(hd(Name))
    end.

%%----------------------------------------------------------------------
%% Function: mynode/1
%% Purpose : Generates a list of "user@hosts" where erlang workers are 
%%          waiting for jobs    
%% Args    : Index is the number of workers to be used.   
%%
%% Requires: 
%% 
%% Returns : list of hosts
%%     
%%----------------------------------------------------------------------
mynode(Index) -> 
    list_to_atom(atom_to_list(lists:nth(1+((Index-1) rem length(hosts())), 
                                        hosts()))).

ready(File) -> os:cmd("touch " ++ File).

%% Purpose: Initializes a backoff vector. Each entry represents a node.
%%          It's used to track if a backoff msg has been received from a node.
initBov(Names) ->
    Bov = ets:new(bov, []),
    lists:map(fun(Pid) -> ets:insert(Bov, {Pid,false}) end, tuple_to_list(Names)),
    Bov.

%% Purpose : Helper function to indentify to which entry number does a node
%%   corresponds.
indexOf(X, L) ->
    indexOf(1, X, L).

indexOf(_N, _X, []) -> out_of_bounds;
indexOf(N, X, [H | T]) ->
    if X == H ->
            N;
       true ->
            indexOf(N+1, X, T)
    end.

startstates() ->
    murphi_interface:startstates().

printState(MS) ->
    Str = murphi_interface:stateToString(MS),
    io:format("~s~n", [Str]).

transition(MS) ->
    murphi_interface:nextstates(MS).

%% strangely, just putting murphi_interface:normalize as the first arg
%% to lists:map below causes a compile time error - Jesse
canonicalizeStates(L, UseSym) -> 
    if UseSym ->
	    lists:map(fun(X) -> murphi_interface:normalize(X) end, L);
       true -> L 
    end.

checkInvariants(MS) ->
    case murphi_interface:checkInvariants(MS) of
        pass -> null;
        {fail, R} -> R
    end.

second({_,X}) -> X.
