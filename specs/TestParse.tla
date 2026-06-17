MODULE TestParse
EXTENDS Naturals
VARIABLE x
Init == x = 0
Next == x' = x
Prop == [](x = 0) ~> [](x = 0)
