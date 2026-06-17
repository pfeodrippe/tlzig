MODULE STSimple7
EXTENDS Naturals
CONSTANT N
Node == 0 .. N-1
VARIABLES active, td

Init == active = [i \in Node |-> TRUE] /\ td = FALSE

Next ==
  \/ \E i \in Node : /\ active[i]
                     /\ active' = [active EXCEPT ![i] = FALSE]
                     /\ td' = td
  \/ /\ \A n \in Node : ~ active[n]
     /\ td' = TRUE
     /\ UNCHANGED active

vars == <<active, td>>
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

Inv == active \in [Node -> BOOLEAN]
Prop == [](\A n \in Node : ~ active[n] => td)
