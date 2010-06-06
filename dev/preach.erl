
-module(preach).
-export([run/0,startWorker/13,ready/1, doneNotDone/5, load_balancer/3]).

-record(r,
   {tf, % tracefile
    wq, % work queue
    oq, % out queue
    coq, % current output queue
    last_sent, % last # sent when coq = 0
    minwq, % minimum peer workq count
    oqs, % out queue size
    req, % recycle queue
    ss, % state set
    hcount, % # states in hash file
    cgt_hcount, % # states in cgt hash file
    count, % # states expanded
    names, % process list
    id, % index into names array 
    term, % terminator pid
    th, % trace handler pid
    sent, % states sent
    recd, % states recd
    extra, % extra states recd
    esent, % extra states sent
    t0,   % initial time
    fc,    % flow control record
    msu,    % make successors unique flag
    bov, % backoff vector
    owq, % other work queues
    recyc, % recycling flag
    usesym, % symmetry reduction flag
    checkdeadlocks,% 
    nt,%  no trace file
    profiling_rate, % determines how often profiling info is spat out
    last_profiling_time, % keeps track of number of calls to profiling()
    lb_pending,
    lb_pid,
    has_cgt, % flag indicating if the model has a CGT property
    cgthdt,  % Can Get To Hash Distance Threshold; states with CGT distances greater or equal
             % to this value get stored in the CGT hash table.
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
      if (MaxLen > 1000) -> 
         %log("sending {send_some_of_your_wq_to,~w,~w} to ~w",[IdlePid,Ratio,MaxPid]),
         MaxPid ! {send_some_of_your_wq_to,IdlePid,Ratio};
      true -> 
         %log("sending {extraStateList,[]} to ~w",[IdlePid]),
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
    murphi_interface:start(rundir(), model_name()),
    Names = initThreads([], P),
    lists:map(fun(X) -> X ! {trace_handler, self()} end, tuple_to_list(Names)),
    lists:map(fun(X) -> X ! {terminator, self()} end, tuple_to_list(Names)),
    LBPid = spawn(?MODULE, load_balancer, [Names,getintarg(lbr,0),idle]),
    lists:map(fun(X) -> X ! {lbPid, LBPid} end, tuple_to_list(Names)),
    case init:get_argument(nhr) of error -> Nhr = []; {ok,[Nhr]} -> ok end,
    case murphi_interface:has_cangetto() of true -> cgt_mask_nonhelpful_rules(Nhr,true); _ -> ok end,
    Seed = getintarg(seed,0),
    T0 = now(),
    log("About to compute startstates... ",[],1),
    SS = startstates(),
    case SS of 
    {error,ErrorMsg} -> 
       log("Murphi found an error in a startstate:~n~s",[ErrorMsg]);
    _ -> 
       CanonicalizedStartStates = canonicalizeStates(SS,init:get_argument(nosym) == error),
       %log("owner of 1st startstate is ~w",[owner(hd(CanonicalizedStartStates),Names,Seed)]),
       tryToSendStates( null_state, CanonicalizedStartStates, Names, initBov(Names),Seed),
       NumSent = length(startstates()),
       log("(Root): sent ~w startstates",[NumSent],1),
       case detectTermination(0, NumSent, 0, 0, Names, dict:new(),Seed,{0,0,0}) of
      {verified,NumStates,ProbNoOmission, _,{BoCount,NumDisc,NumRecyc}} ->
          OmissionProb =  1.0 - ProbNoOmission,
          Dur = timer:now_diff(now(), T0)*1.0e-6,
          %{CpuTime,_} = statistics(runtime),
			% BRAD: Put rules fired stats back in as part of code-cleanup
          io:format("-- This is PReach, version DEV (1.1+)~n" ++
			   "----------~n" ++
               "-- VERIFICATION SUCCESSFUL:~n" ++
               "--\tTotal of ~w states visited" ++ %, ~w rules fired" ++
			   " (this only accurate if no error or in localmode)~n" ++
               "--\tExecution time: ~.2f seconds~n" ++
			   "--\tNumber of worker nodes: ~w~n" ++
               "--\tStates visited per second (real time): ~w~n" ++
               "--\tStates visited per second per worker node (real time): ~w~n" ++ 
%               "\tStates visited per second (cpu time): ~w~n" ++
               "--\tPr[even one omitted state] <= ~w~n" ++
%			   "\tRules fires per state: ~.2f~n" ++
			   "--\tTotal of ~w backoffs with ~w recycled states and ~w discarded states~n" ++
               "----------~n",
               [NumStates, Dur, P, trunc(NumStates/Dur), trunc((NumStates/Dur)/P),
                OmissionProb,BoCount,NumRecyc,NumDisc]);
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
    MSU = init:get_argument(msu) =/= error,
    CheckDeadlocks = init:get_argument(ndl) == error,
    case init:get_argument(nhr) of
    error -> Nhr = [];
    {ok,[Nhr]} -> ok
    end,
    NoTrace = init:get_argument(nt) /= error,
    Cgthdt =  getintarg(cgthdt,0),
    Seed =  getintarg(seed,0),
    HashSize = getintarg(m,mDefault()),
    CgtHashSize = getintarg(cm,1024),
    DoCgt = murphi_interface:has_cangetto() and (init:get_argument(no_cgt) == error),
    PR = getintarg(pr,5),
    LB = getintarg(lbr,0),
    if Local ->
            Args = [model_name(), UseSym,HashSize,CgtHashSize,CheckDeadlocks,NoTrace,PR,false,Seed,MSU,Nhr,Cgthdt,DoCgt],
            ID = spawn(preach,startWorker,Args);
       true ->
            Args = [model_name(), UseSym,HashSize,CgtHashSize,CheckDeadlocks,NoTrace,PR,not (LB==0),Seed,MSU,Nhr,Cgthdt,DoCgt],
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
    %log("DetectTerm: ROOT: NumDone = ~w, GlobalSent = ~w, GlobalRecd = ~w",[NumDone,GlobalSent,GlobalRecd],1),
    if NumDone == tuple_size(Names) andalso GlobalSent == GlobalRecd ->
            lists:map(fun(X) -> X ! die end, tuple_to_list(Names)),
            ProbNoOmission = dict:fold(fun(_,X,Y) -> X*Y end,1.0,ProbDict),
            {verified,NumStates,ProbNoOmission, GlobalSent,{BoCount,NumDisc,NumRecyc}};
       true ->
            receive
                {done, Name, Sent, Recd, States, ProbNoOmission, ThisBoStats} ->
					{ThisBoCount,ThisNumDisc,ThisNumRecyc} = ThisBoStats,
					BoStats = {BoCount+ThisBoCount,NumDisc+ThisNumDisc,NumRecyc+ThisNumRecyc},
                    %log("got done from ~w",[Name],1),
                    detectTermination(NumDone+1, GlobalSent+Sent, GlobalRecd+Recd, NumStates+States, 
                                      Names, dict:store(Name,ProbNoOmission,ProbDict),Seed, BoStats);
                {not_done, Name, Sent, Recd, States,ThisBoStats} ->
                    %log("got not_done from ~w",[Name]),
					{ThisBoCount,ThisNumDisc,ThisNumRecyc} = ThisBoStats,
					BoStats = {BoCount-ThisBoCount,NumDisc-ThisNumDisc,NumRecyc-ThisNumRecyc},
                    detectTermination(NumDone-1, GlobalSent-Sent, GlobalRecd-Recd, NumStates-States, 
                                      Names, dict:erase(Name,ProbDict),Seed, BoStats);
                {error_found, StateList} -> 
                    [State | StateListTl] = StateList,
                    Owner = owner(State,Names,Seed),
                    NoTrace = init:get_argument(nt) =/= error,
                    if NoTrace ->
                       lists:map(fun(X) -> X ! die end, tuple_to_list(Names));
                    true ->
                       lists:map(fun(X) ->
                                         log("Sending tc to ~w",[X],5),
                                         X ! {tc, self()}
                                 end,
                                 tuple_to_list(Names)),
                       checkAck(tuple_to_list(Names)),
                       log("checkAck done; Owner = ~w",[Owner]),
                       Owner ! {find_prev, State, StateListTl},
                       receive trace_complete -> lists:map(fun(X) -> X ! die end, tuple_to_list(Names)) end
                    end,
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
      %log("Received ack from ~w", [PID]),
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
startWorker(ModelName, UseSym, HashSize,CgtHashSize, CheckDeadlocks,NoTrace,Profiling_rate,UseLB,Seed,MSU,Nhr,Cgthdt,DoCgt) ->
    log("startWorker() entered (model is ~s;UseSym is ~w;CheckDeadlocks is ~w;UseLB is ~w;MSU is ~w)~n", 
         [ModelName,UseSym,CheckDeadlocks,UseLB,MSU],1),
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
    % CGT stuff
    if DoCgt ->
       murphi_interface:cgt_init_hash(CgtHashSize),
       cgt_mask_nonhelpful_rules(Nhr,false),
       ets:new(steps, [ordered_set, named_table, public]),
       lists:map(fun(D) -> ets:insert(steps,{D,0}) end, lists:seq(0,100));
    true -> ok end,
    %% IF YOU WANT BLOOM...
    %%    reach(#r{ss= bloom:bloom(200000000, 0.00000001),
    %% ELSE
    case (catch reach(#r{ss=null,
    %% ENDIF
        names=Names, term=Terminator, th=TraceH,
        sent=0, recd=0, extra=0, esent=0, count=0, oqs=0, coq=0, last_sent=0, minwq=0, cgt_hcount=0, hcount=0,bov=initBov(Names), owq=initOtherWQ(Names), 
        wq=WQ, req=ReQ, oq=OQ, tf=TF, 
        t0=1000000 * element(1,now()) + element(2,now()), usesym=UseSym, checkdeadlocks=CheckDeadlocks,
         lb_pid = LBPid, lb_pending=(not UseLB), nt=NoTrace, has_cgt = DoCgt,
         cgthdt = Cgthdt,
         last_profiling_time=0,profiling_rate = Profiling_rate, bo_stats = {0,0,0},seed= Seed,msu=MSU })) 
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

check_CGT(_,R=#r{has_cgt=false}) -> R;
check_CGT(State, R=#r{th=TraceH, tf=TF, names=Names, usesym=UseSym, seed=Seed, cgt_hcount=Cgt_hcount, cgthdt=Cgthdt}) ->
   case search_CGT(State) of
   {failure,Reason,StateList} ->
      log("Found a CGT violation, reason being ~w; CGT suffix has length ~w~n",[Reason,length(StateList)]),
      TraceH ! {error_found, StateList},
      traceMode(Names, TF, TraceH, UseSym, Seed);
   {can_get_there,Dist,StateList} -> 
      %log("CGT in ~w steps~n",[Dist],5), 
      %ets:update_counter(steps, Dist, 1),
      if (Dist > Cgthdt) ->
         HashPrefixLen = Dist - R#r.cgthdt,
         lists:map(fun(X) -> murphi_interface:cgt_hash_add(X) end,
                   lists:sublist(StateList,HashPrefixLen)),
         R#r{cgt_hcount=Cgt_hcount+HashPrefixLen};
      true -> 
         R
      end
   end.

check_invariants(State, _=#r{th=TraceH, tf=TF, names=Names, usesym=UseSym, seed=Seed}) ->
   case murphi_interface:checkInvariants(State) of
   pass -> ok;
   {fail, FailedInvariant} ->
      log("Found Invariant Failure: ~s",[FailedInvariant]),
      log("Just in case cex construction fails, here it is:",[]),
      printState(State),
      log("And in case you care, here are the rules that are enabled:",[]),
      lists:map(fun(S) -> io:format("~s~n",[S]) end, enabled_rules(State)),
      TraceH ! {error_found, [State]},
      traceMode(Names, TF, TraceH, UseSym, Seed)
   end.

expand_a_state(State, R=#r{count=Count,oq=OutQ, tf=TF, th=TraceH, names=Names, usesym=UseSym, 
                           seed=Seed, oqs=OQSize,msu=MSU, checkdeadlocks=CheckDeadlocks}) ->
   TransitionResult = transition(State),
   case TransitionResult of 
   {error,ErrorMsg,RuleNum}  ->
      log("Murphi Engine threw an error evaluating rule \"~s\" (likely an assertion in the Murphi model failed):~n~s",
          [murphi_interface:rulenumToName(RuleNum),ErrorMsg]),
      log("Just in case cex construction fails, here it is:",[]),
      printState(State),
      TraceH ! {error_found, [State]},
      traceMode(Names, TF, TraceH, UseSym, Seed);
   _ ->
      NewStates = if (MSU) -> lists:usort(TransitionResult); true -> TransitionResult end,
      if (CheckDeadlocks andalso NewStates == []) ->
         log("Found (global) deadlock state.",[]),
         log("Just in case cex construction fails, here it is:",[]),
         printState(State),
         TraceH ! {error_found, [State]},
         traceMode(Names, TF, TraceH, UseSym, Seed);
      true -> 
         NewCanonicalizedStates = canonicalizeStates(NewStates, UseSym),
         OutQ2 = queueStates(State, NewCanonicalizedStates, OutQ, Seed, Names),
         NewCount = Count+1,
         NewOQSize = OQSize + length(NewCanonicalizedStates),
         R#r{oq=OutQ2, oqs=NewOQSize, count=NewCount }
      end
   end.

reach(R=#r{}) ->
   case recvStates(R) of
   done -> done;
   R1 ->
      R11 = profiling(R1),
      {[State], NewWq} = dequeue(R11#r.wq),
      case check_CGT(State,R11#r{wq=NewWq}) of 
      done -> done;
      R2 -> 
         case check_invariants(State,R2) of
         done -> done;
         ok -> 
            case expand_a_state(State,R2) of
            done -> done;
            R3 -> reach(R3)
            end
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
recvStates(R0=#r{sent=NumSent, recd=NumRecd, hcount=Hcount, wq=WorkQ, tf=TF, t0=T0,
		 th=TraceH, names=Names, term=Terminator, bov=Bov, usesym=UseSym, seed=Seed,
		 lb_pid=LBPid, lb_pending=LB_pending, bo_stats=BoStats,
                oqs=OQSize, minwq=MinWQ, nt=NoTrace, extra=Extra }) ->
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
                                       if NoTrace ->
                                               TF2 = TF;
                                          true ->
                                               TF2 = diskq:enqueue(TF, {State, Prev})
                                       end,
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
			       WQPart = (Ratio * WQSize) div 100,
                               %NumberToSend = if (WQPart > 100000) -> 100000; true -> WQPart end,
                               NumberToSend = WQPart,
			       {StateList,Q2} = dequeueMany(WorkQ, NumberToSend),
			       IdlePid ! {extraStateList, StateList},
			       recvStates(R#r{sent=NumSent+NumberToSend, wq=Q2});
			   {extraStateList, StateList} ->
			       log("got extrastate"),	    
			       StateListLen = length(StateList),
			       log("got ~w extra states", [StateListLen]),
			       Q2 = enqueueMany(WorkQ, StateList),
			       recvStates(R#r{recd=NumRecd+StateListLen,wq=Q2, lb_pending=(StateList == [])});
						%recvStates(R#r{recd=NumRecd,wq=Q2, lb_pending=(StateList == [])});
                           {Count, StateList, Pid, OtherWQSize, stateList} ->
                               case Pid of
                                   none -> nop;
                                   _ -> Pid ! {ack, self(), 1, WQSize + Count}
                               end,
			       ets:insert(owq, {Pid, OtherWQSize}),
                               NewStatePairs = lists:filter(
                                                 fun({X,_}) -> murphi_interface:brad_hash(X) == false end,
                                                 StateList),
                               NewStates = lists:map(fun({X,_}) -> X end, NewStatePairs),
                               Q2 = enqueueMany(WorkQ, NewStates),
                               if NoTrace ->
                                       TF2 = TF;
                                  true ->
                                       TF2 = enqueueMany(TF, NewStatePairs)
                               end,
                               recvStates(R#r{recd=NumRecd+Count, wq=Q2, tf=TF2, minwq=min(OtherWQSize, MinWQ), hcount=(Hcount+length(NewStates))});
                           {Count, StateList, Pid, extraStateList} ->
                               case Pid of
                                   none -> nop;
                                   _ -> Pid ! {ack, self(), 1, WQSize + Count}
                               end,
                               Q2 = enqueueMany(WorkQ, StateList),
                               recvStates(R#r{recd=NumRecd+Count, wq=Q2, extra=Extra+Count});
			   {ack, Pid, AckSize, OtherWQSize} ->
			       ets:update_counter(Bov, Pid, -AckSize),
			       ets:insert(owq, {Pid, OtherWQSize}),
			       recvStates(R#r{bov=Bov, minwq=min(OtherWQSize, MinWQ)});
			   die -> 
			       log("got die!!!",[],5), done;
			   {tc, Pid}   ->
			       log("got tc",[],5),
			       Pid ! {ack, self()},
			       traceMode(Names, TF, TraceH, UseSym, Seed)
		       end
	       after Timeout ->
		       if Timeout == 60000 ->
			       log("60 secs without any states",[]),
			       TermDelay ! not_done,
			       recvStates(R);
			  true ->
                               R2 = sendOutQ(R),
                               if WQSize > 0 -> R2;
                                  true -> recvStates(R2)
                               end
                       end
	       end
       end.

% minwq(WQSize) -> list:fold_left(fun (X,A) -> min(X,A) end, WQSize, ets:match(owq, {'_', '$1'})).
    
sendOutQ(R=#r{names=Names, coq=CurOQ, sent=NumSent, esent=ESent, bov=Bov, oqs=OQSize, oq=OutQ, minwq=MinWQ, wq=WQ}) ->
    DestPid = element(CurOQ+1, Names),
    [{_, Backoff}] = ets:lookup(Bov, DestPid),
    WQSize = count(WQ),
    [{_, OWQSize}] = ets:lookup(owq, DestPid),
    if Backoff > 100 div tuple_size(Names)
% LB OFF 1 line here
       orelse 5 * WQSize < OWQSize andalso OWQSize > 10000
       ->  % other node is in lb
            R#r{coq=(CurOQ + 1) rem tuple_size(Names)};
       true ->
            COQ = array:get(CurOQ, OutQ),
            ListSize = min(diskq:count(COQ), 100),
            if 
% LB OFF 11 lines here
                OWQSize * 5 < WQSize andalso WQSize > 10000 ->  % we are lb
                    LBSize = 100,
                    {LBList, WQ2} = dequeueMany(WQ, LBSize),
                    DestPid ! {LBSize, LBList, self(), extraStateList},                            
                    ets:update_counter(Bov, DestPid, 1),
                    ets:update_counter(owq, DestPid, LBSize),
                    R#r{coq=(CurOQ + 1) rem tuple_size(Names),
                        wq=WQ2,
                        minwq=MinWQ + LBSize,
                        sent=NumSent+ LBSize,
                        esent=ESent + LBSize};
                OWQSize < 100 andalso ListSize > 0 orelse
                WQSize == 0 andalso ListSize > 0 orelse
                ListSize >= 100 ->
                    {StateList, COQ2} = dequeueMany(COQ, ListSize),
                    DestPid ! {ListSize, StateList, self(), WQSize, stateList},
                    ets:update_counter(Bov, DestPid, 1),
                    R#r{coq=(CurOQ + 1) rem tuple_size(Names),
                        oq=array:set(CurOQ, COQ2, OutQ),
                        oqs=OQSize - ListSize,
                        minwq=MinWQ + ListSize,
                        sent=NumSent + ListSize};
                true ->
                    R#r{coq=(CurOQ + 1) rem tuple_size(Names)}
            end
    end.

profiling(R=#r{count=Count,cgt_hcount=CGT_hcount,hcount=Hcount, t0=T0, sent=NumSent, recd=NumRecd, oqs=OQSize,
               minwq=MinWQ, wq=WorkQ,profiling_rate=PR,last_profiling_time=LPT, extra=Extra, esent=ESent})->
    Runtime = secondsSince(T0),
    if (Runtime > (LPT + PR - 1)) ->
       %{_, Mem} = process_info(self(),memory),
       {CpuTime,_} = statistics(runtime),
       WorkQ_heapSize =  erts_debug:flat_size(WorkQ) * 8, 
       {_, MsgQLen} = process_info(self(),message_queue_len),
       log( "~w states expanded; ~w states in hash table, in ~w s (~.1f per sec) (cpu time: ~.1f; ~.1f per second ) " ++
            "with ~w states sent, ~w states received " ++
            "and ~w states in the queue (which is ~w bytes of heap space) " ++ 
            "and ~w states in the out queue, " ++ 
            "msgq len = ~w, minwq = ~w, extra recd = ~w, extra sent = ~w, " ++
            "and CGT_hcount = ~w",
            [Count, Hcount, Runtime, Count / Runtime, CpuTime / 1000.0, 1000 * Count / CpuTime ,
             NumSent, NumRecd, diskq:count(WorkQ), WorkQ_heapSize, OQSize, MsgQLen, MinWQ, Extra, ESent, CGT_hcount ],1),
       R#r{last_profiling_time=Runtime};
    true ->
       R
    end.

%
% note this returns the list of rules that are both enabled
% *and effect a state change* from the given state
%
enabled_rules(State) ->
   Successors = transition(State),
   RuleNums = lists:map(fun(Succ) -> murphi_interface:whatRuleFired(State,Succ) end, Successors),
   lists:map(fun(RN) -> murphi_interface:rulenumToName(RN) end, RuleNums).

log(Format, Vars, Verbosity) ->
	VLevel = getintarg(verbose, verboseDefault()),
	%VLevel = 5,
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

min(X, Y) -> if X > Y -> Y; true -> X end.

%
%  {bound_hit,StateList}
%  {deadlock,StateList}
%  {error,StateList}
%  cangetthere
%
%
search_CGT(500,StateList) -> 
  StateListU = lists:usort(StateList),
  case length(StateListU) < length(StateList) of
  % Jesse; should really prune StateList down to just the loop part, but too lazy right now
  true ->  {failure,loop,lists:reverse(StateList)};   
  false -> {failure,bound_of_500_hit,lists:reverse(StateList)}
  end;
search_CGT(N,StateList) ->
   Head = hd(StateList),
   case (murphi_interface:cgt_hash_query(Head) orelse murphi_interface:is_q_state(Head)) of
   true -> 
% JESSE: this list reversal is not necessary, but removing it requires some
% tweaks in check_CGT(), which I"m too lazy to do right now
       {can_get_there,N,lists:reverse(tl(StateList))};
   false ->
      case murphi_interface:cgt_successor(Head) of
      null -> {failure,deadlock,lists:reverse(StateList)}; 
      {error,_,_} -> {failure,error,lists:reverse(StateList)}; 
      Succ -> search_CGT(N+1,lists:append([Succ],StateList))
      end
   end.
search_CGT(State) -> search_CGT(0,[State]).


%
% tells the murphi engine to mask (i.e. disable) all rules not
% deemed to be helpful.  But it only masks them in the successor function
%
cgt_mask_nonhelpful_rules(Nhr0,Print) ->
   case Nhr0 of
   [] -> 
      if Print -> log("All rules deemed helpful (use -nhr to designate some rules as non-helpful)",[]);
      true -> ok end;
   _ ->
      RuleCount = murphi_interface:rule_count(),
      AllRules = lists:seq(0,RuleCount-1),
      Nhr = string:join(Nhr0,"|"),
      NonHelpfulRules = 
         lists:filter(
           fun(RuleNum) ->
              RuleName = murphi_interface:rulenumToName(RuleNum),
              (re:run(RuleName,Nhr) =/= nomatch)
           end,
           AllRules),
      lists:map(fun(R) -> murphi_interface:cgt_mask_rule(R) end, NonHelpfulRules),
      if Print ->
         log("The following nonhelpful rules will be disabled for CGT checking:",[]),
         lists:map(fun(R) -> log("~s",[murphi_interface:rulenumToName(R)]) end, NonHelpfulRules);
      true -> ok end
   end.


