
const
  N : 6;
  M : 10;

type
  INDEX : 1 .. N;
  RANGE : 0 .. (M-1);

var 
  x : array [INDEX] of RANGE;
  flag : BOOLEAN;

startstate "start state"

  for i : INDEX do x[i] := 0 end;
  flag := FALSE;

end;


ruleset
  i : INDEX
do
rule "incremenet"
  TRUE
==>
  x[i] := (x[i] + 1) % M;
end
end;

rule "set flag"
  (forall i : INDEX do x[i] = M-1 end)
==>
  flag := TRUE;
end;

--invariant "noflag"  
--  ! flag
--;


