% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
-module(bloom).
-author("Paulo Sergio Almeida <psa@di.uminho.pt>").
-export([sbf/1, sbf/2, sbf/3, sbf/4,
         bloom/1, bloom/2,
         member/2, add/2,
         size/1, capacity/1]).
-export([is_element/2, add_element/2]). % alternative names
-import(math, [log/1, pow/2]).

is_element(E, B) -> member(E, B).
add_element(E, B) -> add(E, B).


%% Based on
%% Scalable Bloom Filters
%% Paulo Sérgio Almeida, Carlos Baquero, Nuno Preguiça, David Hutchison
%% Information Processing Letters
%% Volume 101, Issue 6, 31 March 2007, Pages 255-261 
%%
%% Provides scalable bloom filters that can grow indefinitely while
%% ensuring a desired maximum false positive probability. Also provides
%% standard partitioned bloom filters with a maximum capacity. Bit arrays
%% are dimensioned as a power of 2 to enable reusing hash values across
%% filters through bit operations. Double hashing is used (no need for
%% enhanced double hashing for partitioned bloom filters).
%%
%% This module assumes the existence of a module called bitarray so that
%% different alternatives may be provided. To get an extremely efficient but
%% non-functional variant, hipe_bifs can be used, defining bitarray as:
%%
%%-module(bitarray).
%%-export([new/1, set/2, get/2]).
%%
%%new(Size) -> hipe_bifs:bitarray(Size, false).
%%set(I, A) -> hipe_bifs:bitarray_update(A, I, true).
%%get(I, A) -> hipe_bifs:bitarray_sub(A, I).
%%
%% A functional alternative with good lookup performance can be obtained
%% resorting to the array module. E.g.
%%
%%-module(bitarray).
%%-export([new/1, set/2, get/2]).
%%
%%-define(W, 27).
%%
%%new(N) -> array:new((N-1) div ?W + 1, {default, 0}).
%%
%%set(I, A) ->
%%  AI = I div ?W,
%%  V = array:get(AI, A),
%%  V1 = V bor (1 bsl (I rem ?W)),
%%  array:set(AI, V1, A).
%%
%%get(I, A) ->
%%  AI = I div ?W,
%%  V = array:get(AI, A),
%%  V band (1 bsl (I rem ?W)) =/= 0.

-record(bloom, {
  e,    % error probability
  n,    % maximum number of elements
  mb,   % 2^mb = m, the size of each slice (bitvector)
  h,    % number of hashes (2: double hashing, 3: triple hashing, etc)
  size, % number of elements
  a     % list of bitvectors
}).

-record(sbf, {
  e,    % error probability
  r,    % error probability ratio
  s,    % log 2 of growth ratio
  size, % number of elements
  b     % list of plain bloom filters
}).

%% Constructors for (fixed capacity) bloom filters
%%
%% N - capacity
%% E - error probability

bloom(N) -> bloom(N, 0.001).
bloom(N, E) when is_number(N), N > 0,
            is_float(E), E > 0, E < 1 ->
  bloom(size, N, E).

bloom(Mode, Dim, E) ->
  crypto:start(),
  K = 1 + trunc(log2(1/E)),
  P = pow(E, 1 / K),
  case Mode of
    size -> Mb = 1 + trunc(-log2(1 - pow(1 - P, 1 / Dim)));
    bits -> Mb = Dim
  end,
  M = 1 bsl Mb,
  N = trunc(log(1-P) / log(1-1/M)),
  #bloom{e=E, n=N, mb=Mb, size = 0,
         h = number_hashes(Mb, E),
         a = [bitarray:new(1 bsl Mb) || _ <- lists:seq(1, K)]}.

log2(X) -> log(X) / log(2).

number_hashes(Mb, E) -> 2 + trunc(log2(4/E) / Mb).

%% Constructors for scalable bloom filters
%%
%% N - initial capacity before expanding
%% E - error probability
%% S - growth ratio when full (log 2) can be 1, 2 or 3
%% R - tightening ratio of error probability

sbf(N) -> sbf(N, 0.001).
sbf(N, E) -> sbf(N, E, 1).
sbf(N, E, 1) -> sbf(N, E, 1, 0.85);
sbf(N, E, 2) -> sbf(N, E, 2, 0.75);
sbf(N, E, 3) -> sbf(N, E, 3, 0.65).
sbf(N, E, S, R) when is_number(N), N > 0,
                     is_float(E), E > 0, E < 1,
                     is_integer(S), S > 0, S < 4,
                     is_float(R), R > 0, R < 1 ->
  #sbf{e=E, s=S, r=R, size=0, b=[bloom(N, E*(1-R))]}.

%% Returns number of elements
%%
size(#bloom{size=Size}) -> Size;
size(#sbf{size=Size}) -> Size.

%% Returns capacity
%%
capacity(#bloom{n=N}) -> N;
capacity(#sbf{}) -> infinity.

%% Test for membership
%%
member(Elem, #bloom{}=B) ->
  hash_member(make_hashes(B, Elem), B);
member(Elem, #sbf{b=[B|_]}=Sbf) ->
  hash_member(make_hashes(B, Elem), Sbf).

hash_member(Hashes, #bloom{mb=Mb, a=A, h=H}) ->
  all_set(1 bsl Mb - 1, make_indexes(H, Mb, Hashes), A);
hash_member(Hashes, #sbf{b=B}) ->
  lists:any(fun(X) -> hash_member(Hashes, X) end, B).

make_hashes(_, Elem) ->
  crypto:sha(term_to_binary(Elem)).
%make_hashes(#bloom{mb=Mb, h=H}, Elem) ->
  %N32 = (H * Mb - 1) div 32 + 1,
  %<< <<(erlang:phash2({Elem,I}, 1 bsl 32)):32>> || I <- lists:seq(1,N32) >>.
    
make_indexes(N, Mb, HashBits) ->
  Size = Mb*N,
  <<Bin:Size/bits, _/bits>> = HashBits,
  Is = [I || <<I:Mb>> <= Bin],
  if
    N =< 4 -> list_to_tuple(Is);
    true -> Is
  end.

fst([H|_]) -> H;
fst(Indexes) -> element(1, Indexes).

next_idx(Mask, {I0,I1}) -> {(I0+I1) band Mask, I1};
next_idx(Mask, {I0,I1,I2}) -> {(I0+I1) band Mask, I1+I2, I2};
next_idx(Mask, {I0,I1,I2,I3}) -> {(I0+I1) band Mask, I1+I2, I2+I3, I3};
next_idx(Mask, [I0 | Is=[I1|_]]) -> [(I0+I1) band Mask | next_idx(Is)].
next_idx([I]) -> [I];
next_idx([I0 | Is=[I1|_]]) -> [I0+I1 | next_idx(Is)].

all_set(_Mask, _Indexes, []) -> true;
all_set(Mask, Indexes, [H|T]) ->
  case bitarray:get(fst(Indexes), H) of
    true -> all_set(Mask, next_idx(Mask, Indexes), T);
    false -> false
  end.

%% Adds element to set
%%
add(Elem, #bloom{}=B) -> hash_add(make_hashes(B, Elem), B);
add(Elem, #sbf{size=Size, r=R, s=S, b=[H|T]=Bs}=Sbf) ->
  #bloom{mb=Mb, e=E, n=N, size=HSize} = H,
  Hashes = make_hashes(H, Elem),
  case hash_member(Hashes, Sbf) of
    true -> Sbf;
    false ->
      case HSize < N of
        true -> Sbf#sbf{size=Size+1, b=[hash_add(Hashes, H)|T]};
        false ->
          B = add(Elem, bloom(bits, Mb + S, E * R)),
          Sbf#sbf{size=Size+1, b=[B|Bs]}
      end
  end.

hash_add(Hashes, #bloom{mb=Mb, a=A, h=H, size=Size} = B) ->
  Mask = 1 bsl Mb -1,
  Indexes = make_indexes(H, Mb, Hashes),
  case all_set(Mask, Indexes, A) of
    true -> B;
    false -> B#bloom{size=Size+1, a=set_bits(Mask, Indexes, A)}
  end.

set_bits(_Mask, _Indexes, []) -> [];
set_bits(Mask, Indexes, [H|T]) ->
  [bitarray:set(fst(Indexes), H) | set_bits(Mask, next_idx(Mask, Indexes), T)].

