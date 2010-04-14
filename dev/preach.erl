
-module(preach).
-export([run/0,startWorker/9,ready/1, doneNotDone/5, load_balancer/3]).

-record(r,
   {tf, % tracefile
    wq, % work queue
    oq, % out queue
    coq, % current output queue
    minwq, % minimum peer workq count
    oqs, % out queue size
    req, % recycle queue
    ss, % state set
    hcount, % # states in hash file
    count, % # states expanded
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
    owq, % other work queues
    recyc, % recycling flag
    usesym, % symmetry reduction flag
    bo_bound,  % BackOff bound; max size of message queue before backoff kicks in
    unbo_bound,% UnBackOff bound; when message queue gets this small and we're in back-off mode, we send Unbackoff
    checkdeadlocks,% 
    profiling_rate, % determines how often profiling info is spat out
    last_profiling_time, % keeps track of number of calls to profiling()
    lb_pending,
    lb_pid,
	bo_stats, % 2-tuple {BackoffCount, NumRecycledStates} to report as statistics
	seed     % seed for owner hashing
   }).


%% Purpose : Main function to be called 
run() ->
    start(length(hosts())).

%% Purpose : Uses Erlang's slave library to start remote processes
makeLink([], _Args) -> ok;

makeLink([Host | Rest], Args) ->
    S = re:split(atom_to_list(Host), "[@]", [{return, list}]),
    Machine = list_to_atom(lists:nth(1,tl(S))),
    Name = list_to_atom(hd(S)),
    case slave:start(Machine, Name, Args) of
    {ok, Node} ->
       log("Erlang node started = [~p]", [Node]),
       makeLink(Rest, Args);
    {error,timeout} ->
       log("Could not connect to host ~w...Exiting",[Host]),
       halt();
    {error,Reason} ->
       log("Could not start workers: Reason= ~w...Exiting",[Reason]),
       halt()
    end.

load_balancer(Names,Ratio,State) ->
   log("load_balancer State = ~w",[State]),
   case State of
   idle ->
      receive {im_feeling_idle,IdlePid} -> ok end,
      log("LB: got im_feeling_idle from ~w",[IdlePid]),
      sendAllExcept(wq_length_query,Names,IdlePid),
      load_balancer(Names,Ratio,{collecting,IdlePid,length(tuple_to_list(Names))-1,0,null});
   {collecting,IdlePid,0,MaxLen,MaxPid} ->
      if (MaxLen > 50) -> 
         log("sending {send_some_of_your_wq_to,~w,~w} to ~w",[IdlePid,Ratio,MaxPid]),
         MaxPid ! {send_some_of_your_wq_to,IdlePid,Ratio};
      true -> 
         log("sending {extraStateList,[]} to ~w",[IdlePid]),
         IdlePid ! {extraStateList,[]}
      end,
      load_balancer(Names,Ratio,idle);
   {collecting,IdlePid,N,MaxLen,MaxPid} ->
      receive Msg -> 
         case Msg of
         {im_feeling_idle,IdlePid2} -> 
            IdlePid2 ! {lb_nack},
            load_balancer(Names,Ratio,State);
         {wq_query_response,Len,Pid} ->
            if (Len > MaxLen) -> 
               load_balancer(Names,Ratio,{collecting,IdlePid,N-1,Len,Pid});
            true ->
               load_balancer(Names,Ratio,{collecting,IdlePid,N-1,MaxLen,MaxPid})
            end
         end
      end
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
    Intel = is_intelMode(),
    if Local orelse Intel ->
       ok;
       true ->
       Args = "-pa " ++ os:getenv("PREACH_ROOT") ++ " -rundir " ++ os:getenv("PWD") ++ " -model " ++ model_name() ++ " -verbose " ++ integer_to_list(getintarg(verbose,verboseDefault())),
       pmap(fun(X) -> makeLink(X, Args) end, split_list(10, hosts())),
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
    LBPid = spawn(?MODULE, load_balancer, [Names,getintarg(lbr,0),idle]),
    lists:map(fun(X) -> X ! {lbPid, LBPid} end, tuple_to_list(Names)),
    murphi_interface:start(rundir(), model_name()),
    Seed = getintarg(seed,0),
    log("About to compute startstates... ",[],1),
    SS = startstates(),
    case SS of 
    {error,ErrorMsg} -> 
       log("Murphi found an error in a startstate:~n~s",[ErrorMsg]);
    _ -> 
       CanonicalizedStartStates = canonicalizeStates(SS,init:get_argument(nosym) == error),
       log("owner of 1st startstate is ~w",[owner(hd(CanonicalizedStartStates),Names,Seed)]),
       tryToSendStates( null_state, CanonicalizedStartStates, Names, initBov(Names),Seed),
       NumSent = length(startstates()),
       log("(Root): sent ~w startstates",[NumSent],1),
       case detectTermination(0, NumSent, 0, 0, Names, dict:new(),Seed,{0,0,0}) of
      {verified,NumStates,ProbNoOmission, GlobalSent,{BoCount,NumDisc,NumRecyc}} ->
          OmissionProb =  1.0 - ProbNoOmission,
          Dur = timer:now_diff(now(), T0)*1.0e-6,
          {CpuTime,_} = statistics(runtime),
          io:format("----------~n" ++
               "VERIFICATION SUCCESSFUL:~n" ++
               "\tTotal of ~w states visited, ~w rules fired" ++
			   " (this only accurate if no error or in localmode)~n" ++
               "\tExecution time: ~f seconds~n" ++
               "\tStates visited per second (real time): ~w~n" ++
               "\tStates visited per second per thread (real time): ~w~n" ++ 
               "\tStates visited per second (cpu time): ~w~n" ++
               "\tPr[even one omitted state] <= ~w~n" ++
			   "\tRules fires per state: ~.2f~n" ++
			   "\tTotal of ~w backoffs with ~w recycled states and ~w discarded states~n" ++
               "----------~n",
               [NumStates, GlobalSent, Dur, trunc(NumStates/Dur), trunc((NumStates/Dur)/P),
                trunc(1000 * NumStates/CpuTime),OmissionProb,GlobalSent/NumStates,
				BoCount,NumRecyc,NumDisc]);
      cex -> ok
       end
    end.


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
	HashSize = getintarg(m,mDefault()),
	log("Aggregate hash table space is ~w MBs",[HashSize*length(Names)]),  
    list_to_tuple(Names);

initThreads(Names, NumThreads) ->
    Local = is_localMode(),
    UseSym = init:get_argument(nosym) == error,
    CheckDeadlocks = init:get_argument(ndl) == error,
    BoBound0 =  getintarg(bob,10000),
    Seed =  getintarg(seed,0),
    BoBound = if (BoBound0 == 0) -> infinity; true -> BoBound0 end,
    UnboBound =  getintarg(unbob,if BoBound == infinity -> null; true -> (BoBound div 20) end ),
    HashSize = getintarg(m,mDefault()),
    PR = getintarg(pr,5),
    LB = getintarg(lbr,0),
    if Local ->
            Args = [model_name(), UseSym,infinity, null, HashSize,CheckDeadlocks,PR,false,Seed],
            ID = spawn(preach,startWorker,Args);
       true ->
            Args = [model_name(), UseSym,BoBound,UnboBound, HashSize,CheckDeadlocks,PR,not (LB==0),Seed ],
            ID = spawnAndCheck(mynode(NumThreads),preach,startWorker,Args),
            link(ID)
    end,
    log("Starting worker thread on ~w with PID ~w", [mynode(NumThreads),ID],1),
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
detectTermination(NumDone, GlobalSent, GlobalRecd, NumStates, Names,ProbDict,Seed,{BoCount,NumDisc,NumRecyc}) ->
    log("DetectTerm: ROOT: NumDone = ~w, GlobalSent = ~w, GlobalRecd = ~w",[NumDone,GlobalSent,GlobalRecd],1),
    if NumDone == tuple_size(Names) andalso GlobalSent == GlobalRecd ->
            lists:map(fun(X) -> X ! die end, tuple_to_list(Names)),
            ProbNoOmission = dict:fold(fun(_,X,Y) -> X*Y end,1.0,ProbDict),
            {verified,NumStates,ProbNoOmission, GlobalSent,{BoCount,NumDisc,NumRecyc}};
       true ->
            receive
                {done, Name, Sent, Recd, States, ProbNoOmission, ThisBoStats} ->
					{ThisBoCount,ThisNumDisc,ThisNumRecyc} = ThisBoStats,
					BoStats = {BoCount+ThisBoCount,NumDisc+ThisNumDisc,NumRecyc+ThisNumRecyc},
                    log("got done from ~w",[Name],1),
                    detectTermination(NumDone+1, GlobalSent+Sent, GlobalRecd+Recd, NumStates+States, 
                                      Names, dict:store(Name,ProbNoOmission,ProbDict),Seed, BoStats);
                {not_done, Name, Sent, Recd, States,ThisBoStats} ->
                    log("got not_done from ~w",[Name]),
					{ThisBoCount,ThisNumDisc,ThisNumRecyc} = ThisBoStats,
					BoStats = {BoCount-ThisBoCount,NumDisc-ThisNumDisc,NumRecyc-ThisNumRecyc},
                    detectTermination(NumDone-1, GlobalSent-Sent, GlobalRecd-Recd, NumStates-States, 
                                      Names, dict:erase(Name,ProbDict),Seed, BoStats);
                {error_found, State} -> 
                    Owner = owner(State,Names,Seed),
                    log("got error_found ~w, ~w",[State,Owner]),
                    lists:map(fun(X) ->
                                      log("Sending tc to ~w",[X]),
                                      X ! {tc, self()}
                              end,
                              tuple_to_list(Names)),
                    checkAck(tuple_to_list(Names)),
                    log("checkAck done; Owner = ~w",[Owner]),
                    Owner ! {find_prev, State, []},
                    receive trace_complete -> lists:map(fun(X) -> X ! die end, tuple_to_list(Names)) end,
                    cex
            end
    end.

%% Purpose : Used in traceComputation. Find the tuple w/ the matching state 
%%          and return the previous state.
findPrev(State, TraceFile) ->
    diskq:foldl(
      fun ({Sta, PrevSta}, Acc) -> if (State == Sta) -> PrevSta; true -> Acc end end,
      not_found,
      TraceFile).

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
    Owner ! {State,PrevState, none, state},
    sendStates(PrevState, SRest, ORest).

%% Computes which node within Names owns State
owner(State,Names,Seed) -> 
    element(1+erlang:phash2({Seed,State},tuple_size(Names)), Names) .

%% Purpose :  Like sendStates, but first check if the state owner "is telling"
%%  to backoff
tryToSendStates(PrevState, States, Names,Bov,Seed ) ->
    Owners = lists:map(fun(S) -> owner(S,Names,Seed) end, States),
    GottaBo = gottaBo(Owners,Bov),
    if (GottaBo) ->
	    false;
       true ->
	    sendStates(PrevState, States, Owners),
	    true
    end.


queueStates(PrevState, States, OutQ, Seed, Names) ->
    lists:foldl(fun(X, Q) ->
                        Owner = erlang:phash2({Seed,X},tuple_size(Names)),
			array:set(Owner, diskq:enqueue(array:get(Owner, Q), {X, PrevState}), Q)
		end,
		OutQ,
		States).

sendAllExcept(Msg,Names,Exception) -> 
    NamesList = tuple_to_list(Names),
    PeersList = lists:filter(fun(Y) -> Y /= Exception end,NamesList),
    lists:map(fun(Pid) -> Pid ! {Msg,self()} end,PeersList).

%% Purpose: Broadcast Msg
sendAllPeers(Msg,Names) -> 
    NamesList = tuple_to_list(Names),
    PeersList = lists:filter(fun(Y) -> Y /= self() end,NamesList),
    lists:map(fun(Pid) -> Pid ! {Msg,self()} end,PeersList).

printTrace([]) -> ok;
printTrace([H | [] ]) -> 
    log("Here's the last state...",[]),
    printState(H);
printTrace([H | [H1 | T] ]) -> 
    printState(H),
    RuleNum = murphi_interface:whatRuleFired(H,H1),
    if RuleNum == -1 ->
       %%io:format("Uh oh... Preach was asked to print an invalid trace!~n",[]),
       %%error;
       log("Bad Trans",[]),
       printTrace([H1 | T]);
       true ->
       io:format("~nRule ~s Fired~n",[murphi_interface:rulenumToName(RuleNum)]),
       printTrace([H1 | T])
    end.

%% Purpose :  Computes a counter-example, starting from the state that
%%           violates an invariant. It searches it's local queue (disk-based)
%%           for the predecessor of 'State'. If it finds and it is not the
%%           start state, it iterates; if it is the start-state "0", then
%%           the counter-examples is done;
%% Args    : 
%%           Names is a list of worker's PIDs;
traceMode(Names, TraceFile, TraceH, UseSym,Seed) ->
   log("entering traceMode",[]),
   receive 
      {find_prev, State, Trace} ->
         log("got find_prev",[]),
         %{Hash, {PrevOwner, PrevIndex}} = findPrev(State, TraceFile),
         case findPrev(State,TraceFile) of
         not_found -> 
            log("Uhoh!  Not found! (~w) ~w",[owner(State,Names,Seed),State]);
         null_state ->
            T2 = [State | Trace],
            log("------------------",[]),
            log("Trace Length = ~w~nTrace:~n",[length(T2)]),
            case constructCounterExample(UseSym,T2, startstates(),[]) of
            {done,Cex} -> 
               io:format("Here's the first state...~n",[]),printTrace(Cex);
            _ -> 
               log("counter example construction failed!!~n",[])
            end,
            TraceH ! trace_complete, 
            traceMode(Names, TraceFile, TraceH,UseSym,Seed);
         PrevState ->
            T2 = [State | Trace],
            PrevOwner = owner(PrevState,Names,Seed),
            PrevOwner ! {find_prev, PrevState, T2},
            traceMode(Names, TraceFile, TraceH, UseSym,Seed) 
         end;
      {tc, Pid}   ->  
            Pid ! {ack, self()}, % in case two nodes find simultaneous failure
            traceMode(Names, TraceFile, TraceH, UseSym,Seed) ;
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
       log("constructCounterExample failure...~n~w",[TraceHead]),
       {done,Cex};
    true -> 
       NextStateSuccs = transition(NextState),
       constructCounterExample(UseSym,TraceTail,NextStateSuccs,lists:append(Cex,[NextState]))
    end.


%% Purpose : Only intended to be used w/ trace generation. This function 
%%          works as a selective barrier

checkAck([]) -> ok;
checkAck(L) -> 
   receive {ack, PID} ->
      log("Received ack from ~w", [PID]),
      checkAck(lists:delete(PID, L));
   _ -> checkAck(L)
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

initOutQueues(0) -> [];
initOutQueues(N) ->
    [diskq:open(tmp_disk_path() ++ "/outQueue." ++ integer_to_list(N) ++ atom_to_list(node()),
                getintarg(wqsize, 50000000000), getintarg(wqcache, 10000)) |
     initOutQueues(N - 1)].

initRecycleQueue() ->
    diskq:open(tmp_disk_path() ++ "/reQueue." ++ atom_to_list(node()),
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


is_localMode() -> init:get_argument(localmode) /= error.

is_intelMode() -> init:get_argument(intel) /= error.

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
       filename:absname("");
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

initBov(Names) ->
    case ets:info(bov) of
        undefined ->
            Bov = ets:new(bov, [set, named_table, public]),
            lists:map(fun(Pid) -> ets:insert(Bov, {Pid,0}) end, tuple_to_list(Names)),
            Bov;
        _ -> bov
    end.

initOtherWQ(Names) ->
    case ets:info(owq) of
        undefined ->
            OWQ = ets:new(owq, [set, named_table, public]),
            lists:map(fun(Pid) -> ets:insert(owq, {Pid,0}) end, tuple_to_list(Names)),
            OWQ;
        _ -> owq
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

%%----------------------------------------------------------------------
%% Function: startWorker/0
%% Purpose : Initializes a worker thread by receiving the list of PIDs and 
%%      calling reach().
%% Args    : 
%%
%% Returns : ok
%%     
%%----------------------------------------------------------------------
startWorker(ModelName, UseSym, BoBound, UnboBound,HashSize,CheckDeadlocks,Profiling_rate,UseLB,Seed) ->
    log("startWorker() entered (model is ~s;UseSym is ~w;CheckDeadlocks is ~w,UseLB is ~w)~n", 
         [ModelName,UseSym,CheckDeadlocks,UseLB],1),
    %crypto:start(),
    receive {Names, names} -> do_nothing end,
    receive {trace_handler, TraceH} -> nop end,
    receive {terminator, Terminator} -> nop end,
    receive {lbPid, LBPid} -> nop end,
    %MyID = indexOf(self(), tuple_to_list(Names)),
    log("running model in ~s~n", [rundir()],1),
    murphi_interface:start(rundir(), ModelName),
    timer:sleep(1000),
    murphi_interface:init_hash(HashSize),
    WQ = initWorkQueue(),
    OQ = array:from_list(initOutQueues(tuple_size(Names))),
    ReQ = initRecycleQueue(),
    TF = initTraceFile(),
    %% IF YOU WANT BLOOM...
    %%    reach(#r{ss= bloom:bloom(200000000, 0.00000001),
    %% ELSE
    case (catch reach(#r{ss=null,
    %% ENDIF
        names=Names, term=Terminator, th=TraceH,
        sent=0, recd=0, count=0, oqs=0, coq=0, minwq=0, hcount=0,bov=initBov(Names), owq=initOtherWQ(Names), selfbo=false, 
        wq=WQ, req=ReQ, oq=OQ, tf=TF, 
        t0=1000000 * element(1,now()) + element(2,now()), usesym=UseSym, checkdeadlocks=CheckDeadlocks,
         bo_bound=BoBound, unbo_bound=UnboBound, lb_pid = LBPid, lb_pending=(not UseLB), 
         last_profiling_time=0,profiling_rate = Profiling_rate, bo_stats = {0,0,0},seed= Seed })) 
    of
    {'EXIT',R} -> log("EXCEPTION ~w",[R]);
    _ -> ok
    end,
    %%murphi_interface:stop(),
    OmissionProb =  1.0 - murphi_interface:probNoOmission(),
    log("Worker is done; Pr[even one omitted state] <= ~w; No. of hash collisions = ~w",
        [OmissionProb,murphi_interface:numberOfHashCollisions()],1),
    ok.

%%----------------------------------------------------------------------
%% Function: reach/9
%% Purpose : Removes the first state from the list, 
%%      generates new states returned by the call to transition that
%%      are appended to the list of states. Recurses until there
%%      are no further states to process. 
%% Args    : Tracefile is a disk-based queue containing trace info for 
%%          generating a counter-example when an invariant fails
%%           WorkQueue is a disk-based queue containing a set of states to
%%          be expanded;
%%        Names is a list of worker's PIDs;
%%        BigList is a bloom filter containing the set of reachable states
%%          computed so far by this node;
%%        {NumSent, NumRecd} is the running total of the number of states   
%%       sent and received, respectively   
%%        SendList is the accumulated list of states to be sent to other
%%          workers for expansion
%%        Count is used to count the number of visited states
%%           T0 is running time
%%           QSize is the size of the WorkQueue
%%
%% Returns : done
%%     
%%----------------------------------------------------------------------

reach(R=#r{names=Names, count=Count, th=TraceH, recyc=Recycling, usesym=UseSym, checkdeadlocks=CheckDeadlocks, seed=Seed} ) ->
   case recvStates(R) of
   done -> log("reach is done",[], 5), done;
   R1=#r{wq=WorkQueue, oq=OutQ, oqs=OQSize, tf=TF, bov=Bov, sent=NumSent, bo_stats=BoStats} ->
       {[State], Q2} = dequeue(WorkQueue),
     %  if Recycling -> % prevent too much printing during recycling
     %     nop;
     %  true ->
     %     profiling(R)
     %  end,
       R2 = profiling(R1),
       NewStates = transition(State),
       case NewStates of 
       {error,ErrorMsg,RuleNum}  ->
          log("Murphi Engine threw an error evaluating rule \"~s\" (likely an assertion in the Murphi model failed):~n~s",
              [murphi_interface:rulenumToName(RuleNum),ErrorMsg]),
          log("Just in case cex construction fails, here it is:",[]),
          printState(State),
          TraceH ! {error_found, State},
          traceMode(Names, TF, TraceH, UseSym,Seed);
       _ ->
          if (CheckDeadlocks andalso NewStates == []) ->
             log("Found (global) deadlock state.",[]),
             log("Just in case cex construction fails, here it is:",[]),
             printState(State),
             TraceH ! {error_found, State},
             traceMode(Names, TF, TraceH, UseSym,Seed);
          true -> ok
          end,
          NewCanonicalizedStates = canonicalizeStates(NewStates, UseSym),
          FailedInvariant = checkInvariants(State),
          if (FailedInvariant /= null) ->
             log("Found Invariant Failure: ~s",[FailedInvariant]),
             log("Just in case cex construction fails, here it is:",[]),
             printState(State),
             TraceH ! {error_found, State},
             traceMode(Names, TF, TraceH, UseSym,Seed);
          true ->
		  OutQ2 = queueStates(State, NewCanonicalizedStates, OutQ, Seed, Names),
		  NewWQ = Q2,
		  NewCount = Count+1,
		  NewRecycling = false,
		  NewBoStats = BoStats,
		  NewOQSize = OQSize + length(NewCanonicalizedStates),
		  reach(R2#r{tf=TF, oq=OutQ2, oqs=NewOQSize, wq=NewWQ, count=NewCount, recyc=NewRecycling, bo_stats=NewBoStats})
          end
       end
    end.

doneNotDone(Terminator, NumSent, NumRecd, NumStates, BoStats) ->
    receive not_done ->
       nop
    after 5000 ->
       Terminator ! { done, self(), NumSent, NumRecd, NumStates, murphi_interface:probNoOmission(), BoStats},
       receive not_done ->
          Terminator ! {not_done, self(), NumSent, NumRecd, NumStates, BoStats}
       end
    end.

secondsSince(T0) ->
    {M, S, _} = now(),
    (1000000 * M + S) - T0 + 1.


%%----------------------------------------------------------------------
%% Purpose : Polls for incoming messages within a time window
%%
%% Args    : BigListSize is used only to report the size upon termination;
%%        Names is a list of worker's PIDs;
%%        {NumSent, NumRecd} is the running total of the number of states
%%       sent and received, respectively;
%%        NewStates is an accumulating list of the new received states;
%%           QSize keeps track of the size of the working Queue
%%----------------------------------------------------------------------
recvStates(R0=#r{sent=NumSent, recd=NumRecd, count=NumStates, hcount=Hcount, req=ReQ, oq=OutQ, wq=WorkQ, tf=TF, t0=T0,
		 th=TraceH, names=Names, term=Terminator, bov=Bov, selfbo=SelfBo, usesym=UseSym, seed=Seed,
		 bo_bound=BoBound, unbo_bound=UnboBound, lb_pid=LBPid, lb_pending=LB_pending, bo_stats=BoStats,
                oqs=OQSize, coq=CurOQ, minwq=MinWQ}) ->
    R = profiling(R0),
    WQSize = count(WorkQ),
    Runtime = secondsSince(T0),
    Finished = WQSize == 0 andalso OQSize == 0,
%    {_, RuntimeLen} = process_info(self(),message_queue_len),
    if (WQSize == 0 andalso OQSize == 0 andalso (Runtime > 30) andalso not LB_pending) ->
	    LBPid ! { im_feeling_idle, self() },
	    recvStates(R#r{lb_pending=true});
	  true ->
	       if Finished ->
		       TermDelay = spawn(?MODULE, doneNotDone, [Terminator, NumSent, NumRecd, Hcount, BoStats]),
		       Timeout = 60000;
		  true -> 
		       TermDelay = none,
		       Timeout = 0
	       end,
	       receive Msg ->
		       if Finished -> TermDelay ! not_done; true -> nop end,
		       case Msg of
			   {State, Prev, Pid, state} ->
                               case Pid of
                                   none -> nop;
                                   Src -> Src ! {ack, self(), 1, WQSize}
                               end,
			       Test = murphi_interface:brad_hash(State),
			       if Test == false -> % State not present
				       Q2 = enqueue(WorkQ,State),   
				       TF2 = diskq:enqueue(TF, {State, Prev}),
				       recvStates(R#r{recd=NumRecd+1, wq=Q2, tf=TF2, hcount=(Hcount+1)});
				  true -> 
				       recvStates(R#r{recd=NumRecd+1})
			       end;
			   {lb_nack} -> 
			       log("got lb_nack",[]),
			       recvStates(R#r{lb_pending=false});
			   {wq_length_query,_} -> 
			       log("got wq_length_query",[]),
			       LBPid !  {wq_query_response,WQSize,self()},
			       recvStates(R);
			   {send_some_of_your_wq_to,IdlePid,Ratio} ->
			       log("got sendsome"),	    
			       NumberToSend = (Ratio * WQSize) div 100,
                   % go into back off mode to avoid mailbox blow up while building extraStateList msg
                               %NumberToSend = if (NumberToSend0 > 10000) -> 10000; true -> NumberToSend0 end,
			       {StateList,Q2} = dequeueMany(WorkQ, NumberToSend),
			       IdlePid ! {extraStateList, StateList},
			       recvStates(R#r{sent=NumSent+NumberToSend, wq=Q2});
						%recvStates(R#r{sent=NumSent, wq=Q2});
			   {extraStateList, StateList} ->
			       log("got extrastate"),	    
			       StateListLen = length(StateList),
			       log("got ~w extra states", [StateListLen]),
			       Q2 = enqueueMany(WorkQ, StateList),
			       recvStates(R#r{recd=NumRecd+StateListLen,wq=Q2, lb_pending=(StateList == [])});
						%recvStates(R#r{recd=NumRecd,wq=Q2, lb_pending=(StateList == [])});
                           {Count, StateList, Pid, stateList} ->
                               case Pid of
                                   none -> nop;
                                   _ -> Pid ! {ack, self(), Count, WQSize}
                               end,
                               NewStatePairs = lists:filter(
                                                 fun({X,Y}) -> murphi_interface:brad_hash(X) == false end,
                                                 StateList),
                               NewStates = lists:map(fun({X,Y}) -> X end, NewStatePairs),
                               Q2 = enqueueMany(WorkQ, NewStates),
                               TF2 = enqueueMany(TF, NewStatePairs),
                               recvStates(R#r{recd=NumRecd+Count, wq=Q2, tf=TF2, hcount=(Hcount+length(NewStates))});
                           {Count, StateList, Pid, extraStateList} ->
                               case Pid of
                                   none -> nop;
                                   _ -> Pid ! {ack, self(), Count, WQSize}
                               end,
                               Q2 = enqueueMany(WorkQ, StateList),
                               recvStates(R#r{recd=NumRecd+Count, wq=Q2});
			   {ack, Pid, AckSize, OtherWQSize} ->
			       ets:update_counter(Bov, Pid, -AckSize),
			       ets:insert(owq, {Pid, OtherWQSize}),
			       recvStates(R#r{bov=Bov, minwq=min(OtherWQSize, MinWQ)});
			   die -> 
			       log("got die!!!",[],5), done;
			   {tc, Pid}   ->
			       log("got tc",[]),
			       Pid ! {ack, self()},
			       traceMode(Names, TF, TraceH, UseSym, Seed)
		       end
	       after Timeout ->
		       if Timeout == 60000 ->
			       log("60 secs without any states",[]),
			       TermDelay ! not_done,
			       recvStates(R);
			  true ->
				  if (MinWQ < 100 andalso OQSize > 0) ->
                                          R2 = sendOutQ(R),
                                          recvStates(R2);
                                     (MinWQ < 10000 andalso OQSize > 1000 * tuple_size(Names)) ->
                                          R2 = sendOutQ(R),
                                          recvStates(R2);
                                     (OQSize > 10000 * tuple_size(Names)) ->
                                          R2 = sendOutQ(R),
                                          recvStates(R2);
                                     (MinWQ + 20000 < WQSize) ->
                                          R2 = sendOutQ(R),
                                          recvStates(R2);
                                     WQSize > 0 -> R;
                                     (OQSize > 0) ->
                                          R2 = sendOutQ(R),
                                          recvStates(R2);
                                     true -> log("wtf")
                                  end
                       end
	       end
       end.

% minwq(WQSize) -> list:fold_left(fun (X,A) -> min(X,A) end, WQSize, ets:match(owq, {'_', '$1'})).
    
sendOutQ(R=#r{names=Names, coq=CurOQ, sent=NumSent, bov=Bov, oqs=OQSize, oq=OutQ, minwq=MinWQ, wq=WQ}) ->
    DestPid = element(CurOQ+1, Names),
    WQSize = count(WQ),
    [{_, Backoff}] = ets:lookup(Bov, DestPid),
    [{_, OWQSize}] = ets:lookup(owq, DestPid),
    if Backoff > 10000 div tuple_size(Names) ->
            R#r{coq=(CurOQ + 1) rem tuple_size(Names)};
       true ->
            if (OWQSize + 10000 < WQSize) ->
                    LBSize = min(WQSize div 2, 100),
                    {LBList, WQ2} = dequeueMany(WQ, LBSize),
                    DestPid ! {LBSize, LBList, self(), extraStateList},                            
                    NewBO = ets:update_counter(Bov, DestPid, LBSize),
                    R#r{coq=(CurOQ + 1) rem tuple_size(Names),
                        wq=WQ2,
                        minwq=MinWQ + LBSize,
                        sent=NumSent+ LBSize};
               true ->
                    COQ = array:get(CurOQ, OutQ),
                    ListSize = min(diskq:count(COQ), 100),
                    if ListSize == 0 ->
                            R#r{coq=(CurOQ + 1) rem tuple_size(Names)};
                       true ->
                            {StateList, COQ2} = dequeueMany(COQ, ListSize),
                            DestPid ! {ListSize, StateList, self(), stateList},
                            NewBO = ets:update_counter(Bov, DestPid, ListSize),
                            R#r{coq=(CurOQ + 1) rem tuple_size(Names),
                                oq=array:set(CurOQ, COQ2, OutQ),
                                oqs=OQSize - ListSize,
                                minwq=MinWQ + ListSize,
                                sent=NumSent + ListSize}
                    end
            end
    end.

profiling(R=#r{selfbo=SelfBo,count=Count,hcount=Hcount, t0=T0, sent=NumSent, recd=NumRecd, oqs=OQSize, minwq=MinWQ, wq=WorkQ,profiling_rate=PR,last_profiling_time=LPT})->
    Runtime = secondsSince(T0),
    if (Runtime > (LPT + PR)) ->
       %{_, Mem} = process_info(self(),memory),
       {CpuTime,_} = statistics(runtime),
       WorkQ_heapSize =  erts_debug:flat_size(WorkQ) * 8, 
       {_, MsgQLen} = process_info(self(),message_queue_len),
       log( "~w states expanded; ~w states in hash table, in ~w s (~.1f per sec) (cpu time: ~.1f; ~.1f per second ) " ++
            "with ~w states sent, ~w states received " ++
            "and ~w states in the queue (which is ~w bytes of heap space) " ++ 
            "and ~w states in the out queue " ++ 
            "and Backoff = ~w, msgq len = ~w, minwq = ~w", 
            [Count, Hcount, Runtime, Count / Runtime, CpuTime / 1000.0, 1000 * Count / CpuTime ,
             NumSent, NumRecd, diskq:count(WorkQ), WorkQ_heapSize, OQSize, SelfBo,MsgQLen, MinWQ ],1),
       R#r{last_profiling_time=Runtime};
    true ->
       R
    end.

log(Format, Vars, Verbosity) ->
	VLevel = getintarg(verbose, verboseDefault()),
	if Verbosity =< VLevel -> log(Format, Vars);
		true -> noop
	end.

log(Format, Vars) ->
    io:format("~s.~w: " ++ Format ++ "~n", [second(inet:gethostname()), self()] ++ Vars).

log(Format) ->
    io:format("~s.~w: " ++ Format ++ "~n", [second(inet:gethostname()), self()]).

dequeue(Q) -> diskq:dequeue(Q).

enqueueMany(WQ, []) -> WQ;

enqueueMany(WQ, [State | Rest]) ->
    Q2 = enqueue(WQ, State),
    enqueueMany(Q2, Rest).

dequeueMany(WQ, 0) ->
    {[], WQ};   

dequeueMany(WQ, Num) ->
    {[State],Q2} = dequeue(WQ),
    {R3,Q3} = dequeueMany(Q2, Num-1),
    {[State | R3],Q3}.

verboseDefault() -> 1.

mDefault() -> 1024.


split_list(N, L) ->
    Piece = length(L) div N,
    if Piece < 1 -> get_pieces(1, L);
       true -> get_pieces(Piece, L)
    end.
    

get_pieces(N, L) ->
    if length(L) > N ->
            [lists:sublist(L, N) | get_pieces(N, lists:sublist(L, N+1, length(L)))];
       true -> [L]
    end.

pmap(F, L) ->
    Parent = self(),
    [receive {Pid, Result} -> Result end
     || Pid <- [spawn(fun() -> Parent ! {self(), F(X)} end)
                || X <- L]].
min(X, Y) ->
    if X > Y ->
            Y;
    true ->
            X
    end.

max(X, Y) ->
    if X > Y ->
            X;
    true ->
            Y
    end.
