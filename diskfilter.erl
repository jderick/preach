-module(diskfilter).
-export([open/2, keymerge/3, nkeymerge/5]).

-record(q,
 	{ name,      % filename
	  max,       % cache size
	  fd,        
 	  bl = [],   % block list
 	  il = [],   % index list
 	  ql = []   % quick list
	 } ).

open(Name, BlockSize) ->
    {ok, FD} = file:open(Name, [raw, binary, read, write, read_ahead, delayed_write]),
    #q{name = Name, max = BlockSize, fd = FD}.

find_block(BL) ->
    if BL == [] ->
	    0;
       true ->
	    {Last, LL} = lists:last(BL),
	     Last + LL
    end.
		    
keymerge(Q=#q{bl=BL, il=IL, fd=FD, max=BlockSize, name=Name, ql=QL}, L, NewFun) ->
    {ok, FD2} = file:open(Name ++ ".tmp", [raw, binary, read, write, read_ahead, delayed_write]),
    {Added, NewBL, NewIL} = keymerge(BL, L, [], NewFun, [], [], [], FD, FD2, BlockSize),
    file:close(FD),
    file:delete(Name),
    file:close(FD2),
    file:rename(Name ++ ".tmp", Name),
    {ok, FD3} = file:open(Name, [raw, binary, read, write, read_ahead, delayed_write]),    
    {Q#q{fd=FD3, bl=NewBL, il=NewIL}, Added}.

keyfilter([], _, _, _, _, Acc) -> Acc;
keyfilter([{H, H2} | T], BL, IL, FD, BlockSize, Acc) ->
    case get_block(H, BL, IL, FD) of
	not_found ->
	    keyfilter(T, BL, IL, FD, BlockSize, [{H, H2} | Acc]);
	B ->
	    {[], [], _, _, New} = nkeymerge(BlockSize + 1, B, [{H, H2}], fun (X) -> X end, fun (X) -> X end),
	    case New of
		[] ->
		    keyfilter(T, BL, IL, FD, BlockSize, Acc);
		[E] ->
		    keyfilter(T, BL, IL, FD, BlockSize, [E | Acc])
	    end
    end.

get_block(_X, [], [], _FD) -> not_found;
get_block(X, [{Begin, End} | BL], [{First, Last} | IL], FD) ->
    if X >= First andalso X =< Last ->
	    {ok, Bin} = file:pread(FD, Begin, End),
	    binary_to_term(Bin);
    true ->
	    get_block(X, BL, IL, FD)
    end.
    
    
     

keymerge([], [], [], _F, Added, NewBL, NewIL, _FD, _FD2, _CacheSize) ->
    {Added, NewBL, NewIL};

keymerge([{Begin, Length}|BL], L, L2, F, Added, NewBL, NewIL, FD, FD2, CacheSize)
  when length(L2) < CacheSize ->
    {ok, Bin} = file:pread(FD, Begin, Length),
    L22 = L2 ++ binary_to_term(Bin),
    keymerge(BL, L, L22, F, Added, NewBL, NewIL, FD, FD2, CacheSize);

keymerge(BL, L, L2, F, Added, NewBL, NewIL, FD, FD2, CacheSize) ->
    {NewL2, NewL, NewBlock, LastEl, L2Added} = nkeymerge(CacheSize, L2, L, F, fun id/1),
    NewBin = term_to_binary(NewBlock),
    NewLen = size(NewBin),
    NewBegin = find_block(NewBL),
    ok = file:pwrite(FD2, NewBegin, NewBin),
    keymerge(BL, NewL, NewL2, F, L2Added ++ Added, NewBL ++ [{NewBegin, NewLen}],
	     NewIL ++ [{hd(NewBlock), LastEl}], FD, FD2, CacheSize).

id(X) -> X.

% merge n keys from x and y
% return the remainder of the two lists along with the merged list
% F is applied to items in Y before they are added to the list
% we accumulate items added to the merged list from Y in A

nkeymerge(N, X, Y, F, F2) ->
    nkeymerge(N, X, Y, [], [], F, F2).


nkeymerge(0, X, Y, L, Added, _F, _) -> {X, Y, lists:reverse(L), case L of [H|_T] -> H; [] -> [] end, Added};

nkeymerge(_N, [], [], L, Added, _F, _) -> {[], [], lists:reverse(L), case L of [H|_T] -> H; [] -> [] end, Added};

nkeymerge(N, [], [Y1 | Y], L, Added, F, F2) ->
    nkeymerge(N-1, [], Y, [F(Y1) | L], [Y1 | Added], F, F2);

nkeymerge(N, [A | X], [], L, Added, F, F2) ->
    nkeymerge(N-1, X, [], [F2(A) | L], Added, F, F2);

nkeymerge(N, [A | X], [Y1 | Y], L, Added, F, F2) ->
    KY = F(Y1),
    KA = F2(A),
    if KA < KY ->
	    nkeymerge(N-1, X, [Y1 | Y], [F2(A) | L], Added, F, F2);
       KA > KY ->
	    nkeymerge(N-1, [F2(A) | X], Y, [(F(Y1)) | L], [Y1 | Added], F, F2);
       true ->
	    nkeymerge(N-1, X, Y, [F2(A) | L], Added, F, F2)
    end.
