MODULE BoxActionTest4
EXTENDS Naturals
VARIABLE x
Init == x = 0
Next == x' = x
vars == <<x>>
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)
Prop == [](x=0 => x=0)
