-module(diskq).
-export([open/3, enqueue/2, dequeue/1, count/1, foldl/3, bulk_foldl/3, open_ks/3,
	 truncate/1, keysort/2, findsubtract/2, dummy/0, peek/1, keylookup/6,
	 testkeysort/0, testsubtract/0, open/1, close/1, delete/1, keysub/6]).

-record(q,
 	{ name,      % filename
	  fsize,     % file size
	  max,       % cache size
	  fd,        
	  wc = [],   % write cache
	  wccnt = 0,	  
	  rc = [],   % read cache
 	  bl = [],   % block list
	  count = 0,  % total elements in q
	  sort = false % maintain blocks sorted
	 } ).

count(#q{count=C}) -> C.

open(Name, FileSize, CacheSize) ->
    R = file:open(Name, [raw, binary, read, write, read_ahead, delayed_write]),
    case R of
	{ok, FD} -> ok;
	%% JESSE: had to add the bogus assignment to FD else I get a compile-time error.
	%%   there's probably a cleaner way to do it
	{error,Reason} -> FD = null, erlang:error(Reason,[]);
	_ -> FD = null, exit(1)
    end,
    #q{name = Name, fsize = FileSize, max = CacheSize, fd = FD}.

dummy() ->
    #q{}.

close(Q=#q{fd=FD}) ->
    Q2 = flush_wc(Q),
    ok = file:close(FD),
    Q2.

delete(#q{name=Name}) ->
    ok = file:delete(Name).

open(Q=#q{name=Name}) ->
    {ok, FD} = file:open(Name, [raw, binary, read, write, read_ahead, delayed_write]),
    Q#q{fd=FD}.

truncate(Q) -> Q#q{rc = [], wc = [], wccnt = 0, bl = [], count = 0}.

open_ks(Name, FileSize, CacheSize) ->
    {ok, FD} = file:open(Name, [raw, binary, read, write, read_ahead, delayed_write]),
    #q{name = Name, fsize = FileSize, max = CacheSize, fd = FD, sort = true}.

enqueue(Q=#q{max=Max, wc=WC, wccnt=WCCnt, count=Count}, X) ->
    if WCCnt < Max ->
	    Q#q{wc=[X|WC], wccnt=WCCnt+1, count=Count+1};
       true ->
	    enqueue(flush_wc(Q), X)
    end.

flush_wc(Q=#q{wc=[]}) ->
    Q;

flush_wc(Q=#q{fsize=FSize, fd=FD, wc=WC, bl=BL, sort=KS}) ->
    if KS ->
	    WC2 = lists:sort(WC);
       true ->
	    WC2 = lists:reverse(WC)
    end,
    Bin = zlib:zip(term_to_binary(WC2)),
    Len = size(Bin),
    {ok, Begin} = find_block(Len, FSize, BL),
    ok  = file:pwrite(FD, Begin, Bin),
    Q#q{wc = [], wccnt = 0, bl = BL ++ [{Begin, Len}]}.


find_block(Len, Fsize, BL) ->
    if BL == [] ->
	    {errflag(Len < Fsize), 0};
       true ->
	    {First, _} = hd(BL),
	    {Last, LL} = lists:last(BL),
	    if First =< Last -> % includes case for single block
		    if Last + LL + Len < Fsize ->
			    {ok, Last + LL};
		       true ->
			    {errflag(Len < First), 0}
		    end;
	       true ->
		    {errflag(Last + LL + Len < First), Last + LL}
	    end
    end.

errflag(X) ->			    
    if X ->
	    ok;
       true ->
	    error
    end.

dequeue(Q=#q{rc=[X|L], count=Count}) ->
    {[X], Q#q{rc=L, count=Count-1}};

dequeue(Q=#q{rc=[], bl=[], wc=[]}) ->
    {[], Q};

dequeue(Q) ->
    dequeue(fill_rc(Q)).

fill_rc(Q=#q{rc=[], bl=[], wc=WC, sort=KS}) ->
    if KS ->
	    Q#q{rc=lists:sort(WC), wc=[], wccnt = 0};
       true ->
	    Q#q{rc=lists:reverse(WC), wc=[], wccnt = 0}
    end;

fill_rc(Q=#q{rc=[], bl=[{Begin, Length}|BL], fd=FD}) ->
    {ok, Bin} = file:pread(FD, Begin, Length),
    Q#q{rc=binary_to_term(zlib:unzip(Bin)), bl=BL}.


peek(Q=#q{count=0}) ->
    {[], Q};
peek(Q=#q{rc=[H|_]}) ->
    {[H], Q};
peek(Q) ->
    peek(fill_rc(Q)).


foldl(F, A, #q{rc=RC, bl=BL, fd=FD, wc=WC}) ->
    A2 = lists:foldl(F, A, RC),
    A3 = foldl_blocks(F, A2, BL, FD),  
    lists:foldl(F, A3, lists:reverse(WC)).

foldl_blocks(_F, A, [], _FD) -> A;
foldl_blocks(F, A, [{Begin, Length}|BL], FD) ->
    {ok, Bin} = file:pread(FD, Begin, Length),
    A2 = lists:foldl(F, A, binary_to_term(zlib:unzip(Bin))),
    foldl_blocks(F, A2, BL, FD).

bulk_foldl(F, A, #q{rc=RC, bl=BL, fd=FD, wc=WC, sort=KS}) ->
    A2 = F(RC, A), 
    A3 = bulk_foldl_blocks(F, A2, BL, FD),  
    if KS ->
	    F(lists:sort(WC), A3);
       true ->
	    F(WC, A3)
    end.

bulk_foldl_blocks(_F, A, [], _FD) -> A;
bulk_foldl_blocks(F, A, [{Begin, Length}|BL], FD) ->
    {ok, Bin} = file:pread(FD, Begin, Length),
    A2 = F(binary_to_term(zlib:unzip(Bin)), A),
    bulk_foldl_blocks(F, A2, BL, FD).


%% create a sorted diskq for each block in the q, plus rc and wc
split(Q=#q{name=Name, max=CacheSize}, KeyIdx) ->
    {RNQL, _} = bulk_foldl(fun (B, {QL, N}) ->
				   NewQ=#q{fd=NFD} = open(Name ++ "." ++ integer_to_list(N), no_limit, CacheSize),
				   if KeyIdx > 0 ->
					   SL = lists:keysort(KeyIdx, B);
				      true ->
					   SL = lists:sort(B)
				   end,
				   Bin = zlib:zip(term_to_binary(SL)),
				   Len = size(Bin),
				   ok = file:pwrite(NFD, 0, Bin),
				   {[NewQ#q{bl=[{0,Len}]} | QL], N+1}
			   end,
			   {[], 0},
			   Q),
    lists:reverse(RNQL).

keysort(Q=#q{}, KeyIdx) ->
    QL = split(Q, KeyIdx),
    close(Q),
    delete(Q),
    if KeyIdx > 0 ->
	    KeyFun = fun(X) -> element(KeyIdx, X) end;
       true ->
	    KeyFun = fun(X) -> X end
    end,
    case QL of
	[] -> Q;
	_ -> keysort(QL, KeyFun)
    end;

keysort(QL, KeyFun) ->
    if length(QL) == 0 ->
	    [];
       length(QL) == 1 ->
	    hd(QL);
       true ->
	    {QL1, QL2} = lists:split(trunc(length(QL) / 2), QL),
	    Q1 = keysort(QL1, KeyFun),
	    Q2 = keysort(QL2, KeyFun),
	    case Q1 of
		[] -> Q2;
		_ ->
		    case Q2 of
			[] -> Q1;
			_ ->
			    MQ = keymerge(Q1, Q2, [KeyFun, KeyFun]),
			    close(Q1),
			    delete(Q1),
			    close(Q2),
			    delete(Q2),
			    MQ
		    end
	    end
    end.

keymerge(#q{bl=BLA, fd=FDA, name=NameA, max=CacheSize}, #q{bl=BLB, fd=FDB}, KeyFuns) ->
    OutQ = open(NameA ++ ".0", no_limit, CacheSize),
    keymerge(BLA, BLB, [], [], FDA, FDB, KeyFuns, CacheSize, OutQ).

keymerge([], [], [], [], _, _, _, _, OutQ) ->
    OutQ;

keymerge([{PosA, LenA} | BLA], BLB, A, B, FDA, FDB, KeyFuns, CacheSize, OutQ) when length(A) < CacheSize ->
    {ok, Bin} = file:pread(FDA, PosA, LenA),
    keymerge(BLA, BLB, A ++ binary_to_term(zlib:unzip(Bin)), B, FDA, FDB, KeyFuns, CacheSize, OutQ);

keymerge(BLA, [{PosB, LenB} | BLB], A, B, FDA, FDB, KeyFuns, CacheSize, OutQ) when length(B) < CacheSize ->
    {ok, Bin} = file:pread(FDB, PosB, LenB),
    keymerge(BLA, BLB, A, B ++ binary_to_term(zlib:unzip(Bin)), FDA, FDB, KeyFuns, CacheSize, OutQ);

keymerge(BLA, BLB, A, B, FDA, FDB, KeyFuns, CacheSize, OutQ=#q{bl=OutBL, fd=OutFD, count=Count}) ->
    {A2, B2, Block} = nkeymerge(CacheSize, A, B, hd(KeyFuns), hd(tl(KeyFuns))),
    Bin = zlib:zip(term_to_binary(Block)),
    Len = size(Bin),
    {ok, Begin} = find_block(Len, no_limit, OutBL),
    ok = file:pwrite(OutFD, Begin, Bin),
    keymerge(BLA, BLB, A2, B2, FDA, FDB, KeyFuns, CacheSize, OutQ#q{bl=OutBL ++ [{Begin, Len}], count=Count+length(Block)}).


nkeymerge(N, X, Y, F, F2) ->
    nkeymerge(N, X, Y, [], F, F2).


nkeymerge(0, X, Y, L, _F, _) -> {X, Y, lists:reverse(L)};

nkeymerge(_N, [], [], L, _F, _) -> {[], [], lists:reverse(L)};

nkeymerge(N, [], [Y1 | Y], L, F, F2) ->
    nkeymerge(N-1, [], Y, [Y1 | L], F, F2);

nkeymerge(N, [X1 | X], [], L, F, F2) ->
    nkeymerge(N-1, X, [], [X1 | L], F, F2);

nkeymerge(N, [X1 | X], [Y1 | Y], L, F, F2) ->
    KX = F(X1),
    KY = F2(Y1),
    if KX < KY ->
	    nkeymerge(N-1, X, [Y1 | Y], [X1 | L], F, F2);
       KX > KY ->
	    nkeymerge(N-1, [X1 | X], Y, [Y1 | L], F, F2);
       true ->
	    nkeymerge(N-1, X, Y, [X1 | [Y1 | L]], F, F2)
    end.


%% find min level item in the set A - B
%% A and B must be sorted
findsubtract(Q1, Q2) ->
    #q{bl=BLA, fd=FDA, rc=RCA} = flush_wc(Q1),
    #q{bl=BLB, fd=FDB, rc=RCB} = flush_wc(Q2),
    findsubtract(BLA, BLB, RCA, RCB, FDA, FDB, [], 0).

findsubtract([], _BLB, [], _B, _FDA, _FDB, Hash, _) -> Hash;

findsubtract(BLA, [], [{NewHash, Level} | A], [], FDA, FDB, Hash, MinLevel) ->
    if Level < MinLevel ->
	    findsubtract(BLA, [], A, [], FDA, FDB, [NewHash], Level);
       true ->
	    findsubtract(BLA, [], A, [], FDA, FDB, Hash, MinLevel)
    end;

findsubtract([{PosA, LenA} | BLA], BLB, [], B, FDA, FDB, Hash, MinLevel) ->
    {ok, Bin} = file:pread(FDA, PosA, LenA),
    findsubtract(BLA, BLB, binary_to_term(zlib:unzip(Bin)), B, FDA, FDB, Hash, MinLevel);

findsubtract(BLA, [{PosB, LenB} | BLB], A, [], FDA, FDB, Hash, MinLevel) ->
    {ok, Bin} = file:pread(FDB, PosB, LenB),
    findsubtract(BLA, BLB, A, binary_to_term(zlib:unzip(Bin)), FDA, FDB, Hash, MinLevel);


findsubtract(BLA, BLB, A, B, FDA, FDB, Hash, MinLevel) ->
    case keysubtract(A, B, fun fst/1, fun fst/1) of
	{none, {A2, B2}} -> findsubtract(BLA, BLB, A2, B2, FDA, FDB, Hash, MinLevel);
	{found, {NewHash, Level}, {A2, B2}} ->
	    if Level > MinLevel ->
		    findsubtract(BLA, BLB, A2, B2, FDA, FDB, [NewHash], Level);
	       true ->
		    findsubtract(BLA, BLB, A2, B2, FDA, FDB, Hash, MinLevel)
	    end
    end.


fst({X, _}) -> X.


keysubtract(A, [], _, _) -> {none, {A, []}};
keysubtract([], B, _, _) -> {none, {[], B}};
keysubtract([A1 | A], [B1 | B], KFA, KFB) ->
    KA = KFA(A1),
    KB = KFB(B1),
    if KA == KB ->
	    keysubtract(A, [B1 | B], KFA, KFB);
       KA < KB ->
	    {found, A1, {A, [B1 | B]}};
       true ->
	    keysubtract([A1 | A], B, KFA, KFB)
    end.

keysub(_F, Acc, #q{count=0}, _QB, _KFA, _KFB) ->
    Acc;

keysub(F, Acc, QA, QB, KFA, KFB) ->
    {[A], QA2} = peek(QA),
    {B, QB2} = peek(QB),
    KA = KFA(A),
    case B of
	[Val] -> KB = KFB(Val);
	[] -> KB = []
    end,
    if KB == [] orelse KA < KB ->
	    Acc2 = F(A, Acc),	    
	    {_, QA3} = dequeue(QA2),
	    keysub(F, Acc2, QA3, QB, KFA, KFB);
       KB < KA ->
	    {_, QB3} = dequeue(QB2),
	    keysub(F, Acc, QA2, QB3, KFA, KFB);
       true ->
	    {_, QA3} = dequeue(QA2),
	    {_, QB3} = dequeue(QB2),
	    keysub(F, Acc, QA3, QB3, KFA, KFB)
    end.


keylookup(_F, Acc, #q{count=0}, _QB, _KFA, _KFB) ->
    Acc;
keylookup(_F, Acc, _, #q{count=0}, _KFA, _KFB) ->
    Acc;

keylookup(F, Acc, QA, QB, KFA, KFB) ->
    {[A], QA2} = peek(QA),
    {[B], QB2} = peek(QB),
    KA = KFA(A),
    KB = KFB(B),
    if KA < KB ->
	    {_, QA3} = dequeue(QA2),
	    keylookup(F, Acc, QA3, QB, KFA, KFB);
       KB < KA ->
	    {_, QB3} = dequeue(QB2),
	    keylookup(F, Acc, QA2, QB3, KFA, KFB);
       true ->
	    Acc2 = F(A, B, Acc),
	    {_, QB3} = dequeue(QB2),
	    keylookup(F, Acc2, QA2, QB3, KFA, KFB)
    end.


testkeysort() ->
    Q = diskq:open("test", none, 2),
    Q2 = diskq:enqueue(Q, <<2,3>>),
    Q3 = diskq:enqueue(Q2, <<5,2>>),
    Q4 =diskq:enqueue(Q3, <<4,4>>),
    diskq:foldl(fun (X, _) -> io:format("~w ", [X]) end, [], Q4),
    io:format("~n"),
    Q5 = diskq:keysort(Q4, 0),
    diskq:foldl(fun (X, _) -> io:format("~w ", [X]) end, [], Q5).

testsubtract() ->
    Q = diskq:open("test", none, 2),
    Q2 = diskq:enqueue(Q, {2,0}),
    Q3 = diskq:enqueue(Q2, {3,1}),
    Q4 =diskq:enqueue(Q3, {4,3}),
    diskq:foldl(fun (X, _) -> io:format("~w ", [X]) end, [], Q4),    
    P = diskq:open("test2", none, 2),
    P0 = diskq:enqueue(P, {2,3}),
    P2 = diskq:enqueue(P0, {3,3}),
    P4 =diskq:enqueue(P2, {4,2}),
    findsubtract(Q4, P4).




