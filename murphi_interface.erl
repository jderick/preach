-module(murphi_interface).
-export([start/2, stop/0, init/1]).
-export([startstates/0, nextstates/1, checkInvariants/1, stateToString/1,
	 is_p_state/1, is_q_state/1, has_cangetto/0, print_diff/2,fasthash/1,
         normalize/1,fireRule/2,rulenumToName/1, startstateToName/1, brad_hash/1,
         whatRuleFired/2,init_hash/1,probNoOmission/0,canonicalize/1, 
         equivalentStates/2, numberOfHashCollisions/0, rules_info/0,
	 set_smcpp/1,
% stuff added to support CGT....
         cgt_init_hash/1, cgt_hash_query/1, cgt_hash_add/1, cgt_successor/1, cgt_mask_rule/1, rule_count/0 ]).
-export([dummy/1]).


start(Path, SharedLib) ->
    case erl_ddll:try_load(Path, SharedLib, []) of
        {ok, loaded} ->
	    proc_lib:start(?MODULE, init, [SharedLib]),
	    ok;
        {ok, already_loaded} -> ok;
        {error, E} -> 
	    io:format("Can't seem to open ~s.so, perhaps it doesn't exist?~n",[SharedLib]),
	    io:format("~w~n",[E]),
	    io:format("~s~n",[erl_ddll:format_error(E)]),
	    exit(E)
    end.


init(SharedLib) ->
    register(murphi_int, self()),
    Port = open_port({spawn_driver, SharedLib}, [binary]),
    case Port of 
	{error,Reason} -> io:format("Error: ~w~n",[Reason]);
	_ -> ok
    end,
    proc_lib:init_ack(ok),
    loop(Port).

stop() -> murphi_int ! stop.

swapEndian(<<A:8,B:8,C:8,D:8>>) -> <<D,C,B,A>>.

insert(K,V) ->  Kbits = swapEndian(<<K:32>>),
                Vbits = swapEndian(<<V:32>>),
                binary_to_term(call_port({55, <<Kbits/binary, Vbits/binary>> })).

smcpp_hash_state(State) -> Key = erlang:phash2(State,twoTo28()),
                     Val = erlang:phash2({State,0},twoTo31()),
                     insert(Key,Val).


twoTo28() -> erlang:trunc(math:pow(2,28)).
twoTo31() -> erlang:trunc(math:pow(2,31)).

set_smcpp(DoSmcpp) -> put(smcpp,DoSmcpp).

dummy(X) -> binary_to_term(call_port({55,swapEndian(<<X:32>>)})).

startstates() -> 
    binary_to_term(call_port({1, <<0>>})).
nextstates(Y) -> 
    binary_to_term(call_port({2, Y})).
checkInvariants(X) -> 
	case get(smcpp) of 
		false -> binary_to_term(call_port({3, X}));
		true -> pass % no invariants in smcpp
	end.
stateToString(X) -> 
    binary_to_term(call_port({4, X})).
is_p_state(X) -> 
    binary_to_term(call_port({5,X})).
is_q_state(X) -> 
    binary_to_term(call_port({6,X})).
has_cangetto() -> 
    binary_to_term(call_port({7,<<0>>})).
print_diff(X,Y) -> 
    binary_to_term(call_port({8,list_to_binary([X,Y])})).
fasthash(X) -> 
    binary_to_term(call_port({9,X})).
normalize(X) -> 
    binary_to_term(call_port({10,X})).
fireRule(State,Rule) -> 
    binary_to_term(call_port({11,list_to_binary([Rule,State])})).
rulenumToName(RuleNum) -> 
    binary_to_term(call_port({12,list_to_binary([RuleNum rem 256,RuleNum div 256])})).
startstateToName(SSNum) -> 
    binary_to_term(call_port({13,list_to_binary([SSNum])})).
brad_hash(X) -> 
	case get(smcpp) of
		false -> binary_to_term(call_port({14,X}));
	        true -> smcpp_hash_state(X)
	end.
whatRuleFired(X,Y) -> 
    binary_to_term(call_port({15,list_to_binary([X,Y])})).
init_hash(Size) -> 
    %% this seems to be the only 
    %% way i found to pass an integer to the c code
    %% (actually this assume the int fits into two bytes and 
    %% is unsigned, or something) -- JESSE
	case get(smcpp) of false ->
    		call_port({16,list_to_binary([Size rem 256,Size div 256])});
			true -> binary_to_term(call_port({56, <<0>>}))
	end, ok.
probNoOmission() ->
    binary_to_term(call_port({17, <<0>>})).
canonicalize(X) -> 
    %% NOTE: if you call canonicalize() and them subsequently call
    %% normalize(), normalize() might behave like canonicalize()
    binary_to_term(call_port({18,X})).
equivalentStates(X,Y) -> 
    R = binary_to_term(call_port({19,list_to_binary([X,Y])})),
    R.
numberOfHashCollisions() -> 
    binary_to_term(call_port({20,<<0>>})).
cgt_successor(Y) -> 
    binary_to_term(call_port({21, Y})).
cgt_mask_rule(RuleNum) -> 
    call_port({22,list_to_binary([RuleNum rem 256,RuleNum div 256])}), ok.
rule_count() -> 
    binary_to_term(call_port({23, <<0>>})).
cgt_init_hash(Size) -> 
    call_port({24,list_to_binary([Size rem 256,Size div 256])}), ok.
cgt_hash_query(X) -> 
    binary_to_term(call_port({25,X})).
% JESSE: this needs to be enhanced to detect the full hash table error
cgt_hash_add(X) -> 
    call_port({26,X}), ok.
rules_info() -> 
    binary_to_term(call_port({27,<<0>>})).

call_port(Msg) ->
    murphi_int ! {call, self(), Msg},
    receive
        {murphi_int, Result} -> Result
    end.

loop(Port) ->
    receive
        {call, Caller, Msg} ->
            Port ! {self(), {command, encode(Msg)}},
            receive
                {Port, {data, Data}} ->
                    Caller ! {murphi_int, decode(Data)}
            end,
            loop(Port);
        stop ->
            Port ! {self(), close},
            receive
                {Port, closed} ->
                    exit(normal)
            end;
        {'EXIT', Port, Reason} ->
            io:format("~p ~n", [Reason]),
            exit(port_terminated)
    end.

encode({N, X}) -> <<N, X/bytes>>.

decode(Out) -> Out.
