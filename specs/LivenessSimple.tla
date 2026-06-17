---- MODULE LivenessSimple ----
EXTENDS Naturals
VARIABLE x
Init == x = 0
Next == x' = 1
vars == <<x>>
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)
Prop == (x = 0) ~> (x = 1)
====
