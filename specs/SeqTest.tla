-------------------------------- MODULE SeqTest --------------------------------
EXTENDS Sequences

CONSTANT A, B

VARIABLE seq

Init == seq \in Seq({A, B})
Next == seq' = seq

Inv == seq \in Seq({A, B})
================================================================================
