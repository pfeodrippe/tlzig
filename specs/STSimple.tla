MODULE STSimple
EXTENDS Naturals
CONSTANT N
Node == 0 .. N-1
VARIABLES active, td

Init ==
  /\ active \in [Node -> BOOLEAN]
  /\ td \in BOOLEAN

Next ==
  \/ \E i \in Node : /\ active[i]
                     /\ active' = [active EXCEPT ![i] = FALSE]
                     /\ td' = td
  \/ \E i,j \in Node : /\ active[i]
                       /\ active' = [active EXCEPT ![j] = TRUE]
                       /\ td' = td
  \/ /\ \A n \in Node : ~ active[n]
     /\ td' = TRUE
     /\ UNCHANGED active

vars == <<active, td>>
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

Inv == active \in [Node -> BOOLEAN]
Prop == []((\A n \in Node : ~ active[n]) => td)
