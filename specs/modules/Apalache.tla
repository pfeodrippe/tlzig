---- MODULE Apalache ----

\* Convert a function whose domain is 1..n into a sequence of length m.
\* This is an Apalache-specific helper used in several examples.
FunAsSeq(f, n, m) == [ i \in 1..m |-> f[i] ]

=============================================================================
