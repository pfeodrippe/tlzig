MODULE BoxActionTest
EXTENDS Naturals
VARIABLE x
Init == x = 0
Next == x' = 1
vars == <<x>>
Spec == Init /\ [][Next]_vars
Prop == [][Next]_vars
