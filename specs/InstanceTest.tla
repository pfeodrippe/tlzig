MODULE InstanceTest
EXTENDS Naturals
VARIABLE x
Init == x = 0
Next == x' = x

M == INSTANCE HourClock
Prop == M!Hour
