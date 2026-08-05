# TLA+ Specification Coverage

Last updated: 2026-08-04

## Goal

Support every runnable, non-TLAPS TLA+ model in the checked-in corpus that
Java TLC accepts. A row is complete only when tlzig agrees with TLC on the
semantic outcome. Exhaustively completed successful runs must also have the
same distinct-state count. Performance is measured only with `ReleaseFast`
after correctness is established.

No tlzig runtime path may encode a user specification's names or semantics.
Generated AOT code may specialize the parsed input model, but runtime
overrides are limited to TLA+/TLC built-ins and standard modules.

## Scope

| Corpus | Configurations |
| --- | ---: |
| `specs` | 41 |
| `vendor/tlaplus-examples/specifications` | 226 |
| `vendor/MDBTLA` | 13 |
| **Primary total** | **280** |

TLAPS proof modules and proof obligations are excluded. `vendor/tlaplus` is
the Java TLC implementation and its internal fixture tree, not part of this
primary external-model audit. A module without a model configuration is
covered through configured root modules that import it.

## Acceptance Rules

- **Exact**: both engines finish successfully with exact distinct-state parity.
- **Outcome exact**: both engines find the same kind of configured violation
  or deadlock. First-witness counts remain recorded but are not compared,
  because traversal and worker scheduling can stop on different witnesses.
- **Stochastic outcome**: both engines accept and execute a simulation or
  randomized model, but exact state counts are not deterministic.
- **Bounded**: TLC accepts the model and tlzig explores it, but at least one
  engine reaches the configured time or state bound. This is not an exhaustive
  correctness claim.
- **TLC invalid**: Java TLC rejects the module/configuration before ordinary
  model checking. This is not a tlzig compatibility requirement.
- **Non-model harness**: an executable Toolbox/CI utility that performs
  top-level expression or subprocess work without INIT/NEXT/SPECIFICATION.
- **Gap**: tlzig rejects/crashes after TLC accepts, disagrees on outcome, or an
  exhaustively successful run has a different distinct-state count.

## Current Paired Audit

Manifest: `coverage_results/primary_2026-07-28_post_generated_fix.jsonl`

| Resolved model path | Exact | Outcome exact | Stochastic | Bounded | TLC invalid | Non-model | Hard gaps |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `specs` | 18 | 2 | 0 | 0 | 21 | 0 | 0 |
| `tlaplus-examples` | 122 | 13 | 0 | 51 | 38 | 2 | 0 |
| `MDBTLA` | 2 | 7 | 0 | 2 | 2 | 0 | 0 |
| **Total** | **142** | **22** | **0** | **53** | **61** | **2** | **0** |

The fresh paired audit used two concurrent models and eight workers per engine.
It has zero tlzig rejections, zero outcome mismatches, and zero exhaustive
distinct-count mismatches. It does **not** prove all 53 short-gate bounded rows
exhaustively. Many have independent exact long-run evidence; the remainder
stay explicitly open. Audit timings are not performance evidence because the
two paired jobs intentionally share the machine.

### Reconciled Bounded Backlog (2026-08-03)

The `53` bounded rows above are a historical short-gate count, not the current
unresolved count. Later JSONL manifests provide conclusive exact,
outcome-exact, semantic-exact, or stochastic evidence for `24` of them.
Completed benchmark/semantic audits provide exact evidence for three more:
`SingleLog/MCMDBProps` (`269,881` distinct), `SingleShardTxn/ShardTxn`
(`5,502,547` distinct), and `MCInnerSerial` (`195` distinct). The conservative
reconciliation now also includes the exact Slush Medium benchmark and the
2026-08-03 exhaustive LCS Medium and Elevator Safety Medium runs. The
unresolved finite exhaustive-evidence backlog is therefore **8 configurations**:

- `KeyValueStore/MCKVSSafetyLarge.cfg`
- `TLC/TestMCReachability.cfg`
- `c1cs/APc1cs.cfg`
- `c1cs/c1cs.cfg`
- `dag-consensus/TLCSailfish2.cfg`
- `detector_chan96/EnvironmentController.cfg`
- `diskpaxos/MC_HDiskSynod.cfg`
- `ewd998/EWD998.cfg`

These are bounded evidence gaps, not known compatibility failures. They must
remain open until both engines finish with matching successful distinct counts
or matching configured violation/deadlock outcomes.

The KeyValueStore safety family now has two exact strict-AOT anchors. Small
completes in both engines at `56,349,379/3,409,605` generated/distinct states;
isolated ReleaseFast timing is TLC `19.81s` versus tlzig `6.96s` (`2.85x`),
with 4.87 GB versus 1.18 GB maximum RSS. Medium exercises the `TxId` symmetry
used by Large and completes exactly at `365,609,473/17,220,672`; TLC takes
`90.47s` versus tlzig `40.44s` (`2.24x`), with 5.63 GB versus 3.75 GB RSS.
The maintained benchmark records the same exact Medium count at
`100.824s/43.512s` (`2.32x`). Small is default-enabled and Medium is opt-in.

`MCKVsnap.cfg` adds symmetry, the `TypeOK` and `SnapshotIsolation` invariants,
and the temporal `Termination` property. Because TLC documents symmetry
reduction as unsound for liveness, tlzig now automatically explores the
concrete graph when a temporal property and symmetry are both configured. The
paired benchmark uses `benchmark_configs/MCKVsnap_no_sym.cfg` for equivalent
TLC semantics. TLC and strict zero-fallback AOT tlzig complete exactly at
`365,596/189,664`; the current ReleaseFast pair takes `6.345s` and `0.672s`
respectively (`9.44x`). Its generated artifact contains 32 generated operators,
two standard native definitions, and zero fallback. A
2026-08-04 regression briefly reported a false liveness violation while
retaining the exact quotient-state count. The cause was generic: tlzig
re-evaluated a fairness action against independently chosen parent/child
symmetry representatives, after canonicalization had renamed the concrete
child. Fairness masks are now finalized as `<A>_v` labels on concrete
transitions before quotient-edge merging. A standalone symmetric regression
forces two differently named transitions to merge into one quotient target;
it fails under the old replay and passes under the concrete-label path. A
second regression verifies that multiple concrete labels are OR-merged when
their transitions deduplicate to one quotient edge. No KeyValueStore name or
semantics is present in the runtime fix. The alleged
counterexample is also impossible directly from the model: each non-`Done`
transaction has an enabled `t(self)` step that changes `pc[self]`, so
`WF_vars(t(self))` rules out every pre-termination stuttering loop. This agrees
with TLC's rule of evaluating liveness actions on concrete successor states
before symmetry fingerprinting.

`MCKVSSafetyLarge.cfg` generates a strict 12-operator artifact with one
standard native built-in and zero fallback. At TLC's 120-second checkpoint,
Java has reached `367,297,806/32,849,147` generated/distinct states with
`15,883,975` queued. tlzig reaches its explicit 40-million-state boundary at
`426,483,296/40,000,000` in `76.02s`, with `20,314,356` queued. This is
`1.92x` higher distinct throughput and `1.83x` higher generated throughput,
while RSS is 8.02 GB versus TLC's observed 11.55 GB. Both queues are growing,
so Large remains in the eight-row backlog rather than being mislabeled exact.

`SlushLarge.cfg` now has substantially deeper strict-AOT evidence. The
unmodified model generates 35 operators with one standard native definition
and zero fallback. tlzig reaches `1,127,388,186/150,000,000`
generated/distinct states in `355.52s`, with no invariant failure and
`13,479,765` queued after the frontier starts contracting. Peak RSS is
`22.71 GB` and peak process footprint is `36.60 GB`. A fresh isolated TLC-auto
sample reaches `515,331,878/73,858,271` generated/distinct in `300.20s`, with
`12,412,406` queued. Average bounded distinct throughput favors tlzig by
`1.71x`, but neither engine completed, so the row remains in the finite backlog.

A generic tagged-value compaction has since reduced `Value` from 32 to 24
bytes without changing model semantics. On the identical strict-AOT
150-million-state command, tlzig reaches
`1,126,825,444/150,000,000` in `288.04s`, a controlled `1.23x` speedup over
the old layout. Peak process footprint falls from `36.60 GB` to `30.42 GB`.
Maximum RSS and retired instructions do not improve on this sample, so they are
not presented as wins. The queue still contains `13,582,113` states and the
run ends at the explicit state bound. The complete ReleaseFast benchmark and
all 239 assertion-enabled tests pass with the compact representation.

The enlarged run closes SlushLarge exhaustively. Strict zero-fallback tlzig
and Java TLC both complete successfully at exactly
`1,968,189,705/244,335,240` generated/distinct states, with zero states left
queued and graph depth 59. ReleaseFast tlzig takes `498.83s`; TLC-auto takes
`678.10s`, making tlzig `1.36x` faster at exact parity. tlzig uses `49.80 GB`
peak process footprint and `26.04 GB` maximum RSS; TLC uses `20.16 GB` and
`20.22 GB`, respectively. The row is registered as an opt-in strict-AOT
benchmark because the complete pair takes about twenty minutes and approaches
the memory limit of a 48 GiB machine.

Two additional valid configurations use simulation mode rather than exhaustive
search:

- `ewd687a/EWD687a_anim.cfg`
- `ewd840/EWD840_anim.cfg`

Their corpus manifests require 100 traces and expect a safety failure. Seeded
tlzig simulation now uses TLC's maximum-prefix action decomposition, checks
constraints and invariants on every generated successor, and finds the same
configured violations. Fresh all-core paired runs report `outcome-exact` for
both rows. Successful traces now use the ordinary temporal engine over a
TLC-compatible finite behavior graph: repeated states are folded and every
trace state receives a stuttering edge.

`FiniteMonotonic/APCRDT.cfg` and `APReplicatedLog.cfg` are tracked separately
because their reachable state spaces are infinite, not because either checker
rejects them. `Increment(n)` increases a `Nat` counter without a bound, and
`WriteTx(n, tx)` can append to the replicated log forever. Exhaustive completion
and a final distinct-state count therefore do not exist for either engine.
The same classification applies to `SpecifyingSystems/FIFO/APInnerFIFO.cfg`
and `APInnerFIFOInstanced.cfg`: repeated `BufRcv` actions append to `q` with no
queue-length constraint.

Fresh exhaustive evidence recorded on 2026-08-03:

- `MCLeastCircularSubstringMedium.cfg`: exact
  `1,017,073/1,007,232` generated/distinct states; TLC-auto `16.229s`,
  tlzig-auto ReleaseFast `2.682s` (`6.05x` faster).
- `ElevatorSafetyMedium.cfg`: exact `17,997,111` distinct states and successful
  completion in both engines. TLC generated `120,792,180` states in `66.358s`;
  tlzig generated `120,668,970` in `95.723s`. The generated-state difference
  is duplicate successor accounting; the exact distinct state set and outcome
  close correctness, while the `0.693x` performance ratio remains a real
  optimization target for the generic runtime. Strict AOT closes that target:
  the isolated benchmark passed at `86.910s` TLC-auto versus `42.139s`
  tlzig-AOT-auto (`2.06x`) with the same exact distinct count and zero
  generated fallback.
- The paired-audit timeout now applies the requested full timeout to a single
  configured module mapping. The shorter resolution timeout is reserved for
  genuinely ambiguous alternate module candidates.
- Dijkstra Mutex `Safety-4-processors/MC.cfg`: exact
  `146,157,716/33,288,512` generated/distinct states. TLC-auto completed in
  `60.670s`; generic ReleaseFast tlzig-auto completed in `58.101s` (`1.04x`
  faster).
- `cf1s_folklore.cfg`: exact temporal completion at
  `22,438,432/2,057,174` generated/distinct states. The maintained strict-AOT
  benchmark reports TLC-auto `16.441s` versus tlzig-auto `7.880s` (`2.09x`
  faster), with `11` generated operators, `3` temporal-native definitions,
  and zero fallback. This removes the row from the bounded backlog.

`APc1cs.cfg` remains open, but its previous strict-AOT throughput blocker is
fixed. The generated artifact contains `22` generated operators, one standard
native operator, and zero fallback. Direct membership in a state variable now
uses the generic cross-pool set implementation instead of cloning the complete
state set into the eval pool. At the same twenty-million-distinct-state bound,
tlzig ReleaseFast improved from `173.12s` to `141.97s` (`1.22x`), while user CPU
fell from `2,566.58s` to `1,897.48s` and retired instructions from `38.37T` to
`28.12T`. The improved run generated `452,005,985` states, retained
`11,677,559` queued states, and used `6.80 GB` peak RSS. In a fresh isolated
TLC-auto run, TLC reached `18,496,258` distinct states at its 183-second
checkpoint with `10,595,893` queued and `8.91 GB` observed peak RSS. This is
about `1.39x` higher average distinct-state throughput for tlzig over the
bounded runs, but neither engine completed, so this is not exhaustive
correctness evidence.

`c1cs.cfg` remains open. A 300-second all-core audit reached a TLC periodic
temporal checkpoint over a reported `8,862,895`-state current graph; that line
was not a completed base-state count, and neither engine completed within the
paired bound. Generic bottom-up canonicalization now shares repeated concrete
sets, functions, tuples, and records inside changed variables. At the
two-million-state boundary this reduced canonical storage from about
`51.4 million` to `3,517,358` `Value` nodes and peak RSS from the prior
`2.51 GB` reference to `1.10 GB`; ReleaseFast wall time was `17.54s` versus
`17.97s`. The final graph-aware cache policy uses the smaller 2 Mi table for
temporal runs; a larger strict-AOT run reached
`255,411,639/12,000,000` generated/distinct states in `106.04s`, with
`6,661,257` queued, only `27,464,951` canonical values, and `5.00 GB` peak
RSS. This is a major general representation improvement, but the expanding
frontier remains bounded rather than exact.

`EWD840_anim.cfg` is closed in its manifest-declared simulation mode. With 100
traces, depth 100, and seed `6074329268192498505`, both engines find `AnimInv`.
The post-temporal paired ReleaseFast audit records TLC-auto `0.740s` and tlzig
`0.364s`, a `2.03x` tlzig speedup. The old exhaustive frontiers exercised a mode the
manifest does not request and remain historical throughput data only.

`MC_HDiskSynod.cfg` remains open, but a strict-AOT-only correctness gap found
during the extended audit is fixed. A quantifier over the named zero-arity
`MajoritySet` definition incorrectly prepended the caller's lexical arguments
when evaluating the set filter, causing generated `HInv4` to fail on the first
initial state while interpreted tlzig and TLC accepted it. Named filtered
power-set domains now evaluate their definition filter with only its own bound
subset; direct filters still receive captured caller arguments. The post-fix
60-second pair reached TLC `2,361,454/302,250` before timeout and tlzig's
explicit two-million-state cap at `19,134,362/2,000,000` in `8.958s`. A larger
tlzig run reached `104,887,762/10,000,000` in `52.05s` without a false
invariant. These remain bounded results.

The frontier has since been extended to 60 million distinct states with the
same strict zero-fallback artifact. tlzig reaches
`762,972,247/60,000,000` generated/distinct states in `328.86s`, with
`17,633,057` queued and no invariant failure. Peak RSS is `15.69 GB` and peak
process footprint is `22.51 GB`. A generic state-layout change removes the
redundant borrowed-variable mask, shrinking state metadata from 48 to 40 bytes;
the identical 30-million-state command lowers peak RSS from `11.79 GB` to
`11.53 GB`. A more aggressive shared borrowed-pool prototype was rejected
after the complete benchmark exposed a `Barrier` semantic regression. The row
therefore remains bounded rather than being mislabeled exact.

`TLCSailfish2.cfg` remains open after a strict zero-fallback AOT audit. Its
36 generated operators and one native temporal definition now reach the
two-million-state cap at `3,784,909/2,000,000` in `23.62s`; TLC reached
`399,821/162,226` in 60 seconds with `123,966` states still queued. Before
recursive canonical subvalue sharing, this boundary stored about 400 million
`Value` nodes and used `13.55 GB` peak RSS. The new generic representation
stores `60,180,882` values and uses `2.70 GB` peak RSS, reductions of about
85% and 80%, respectively. The model still has `1,590,436` states queued, so
this remains bounded rather than exhaustive parity.

`APCRDT.cfg` and `APReplicatedLog.cfg` both generate strict AOT with eight
generated operators, one standard native operator, and zero fallback. For
`APCRDT`, tlzig reached 100 million distinct states in 270 seconds with
`28,964,052` queued and no invariant violation; TLC reached `84,398,731`
distinct states after 300 seconds with `24,777,057` queued. For
`APReplicatedLog`, tlzig reached ten million distinct states in `10.80s` with
`5,003,163` queued and no invariant violation; TLC reached `138,892,346`
distinct states after 300 seconds with `69,456,028` queued. These are expected
nonterminating frontiers. Exact finite companion configurations close the
shared semantic paths: `MCCRDT.cfg` completes at `25,000` distinct states and
`MCReplicatedLog.cfg` at `1,363` in both engines.

Both APInnerFIFO variants generate strict AOT with `16` generated operators,
one standard native operator, and zero fallback. Fresh five-million-state runs
preserve their configured channel invariants and complete the bounds in
`5.71s` and `5.38s`, with about `1.47 million` states still queued. The prior
TLC runs reached `110,256,118` and `109,437,857` distinct states after 240
seconds with more than 32 million queued, as expected for the unbounded queue.
The finite `MCInnerFIFO.cfg` companion completes exactly at `9,660/3,864`
generated/distinct states in both engines; `APMCInnerFIFO.cfg` also reaches the
same configured queue-bound violation outcome in both engines.

`ElevatorLivenessLarge.cfg` is closed with paired successful temporal verdicts
and exact `50,653` base-state parity. Current strict AOT emits `22` generated
operators, three standard temporal/native definitions, and zero fallback;
tlzig completes at `230,803/50,653` in `1.68s` with `270 MB` peak RSS. Default
Java TLC completes at `230,899/50,653` in `1,951.17s` (`32min 30s`) with
`18.33 GB` peak RSS, making tlzig `1,161x` faster end to end. TLC spends
`11min 47s` on an intermediate 302,912-node temporal product and `20min 38s`
on the final 405,224-node product. A Java thread dump shows all eight
`LiveWorker`s repeatedly seeking and reading `TableauDiskGraph` nodes through
`BufferedRandomAccessFile` in `checkSccs`; tlzig uses its contiguous in-memory
temporal graph.

`ElevatorSafetyLarge.cfg` is also closed with paired successful invariant
verdicts and exact `59,007,145` distinct-state parity. Strict AOT emits `22`
generated operators, two standard native definitions, and zero fallback.
ReleaseFast tlzig completes at `545,380,491/59,007,145` in `112.97s` with
`11.36 GB` peak RSS; Java TLC completes at
`545,537,067/59,007,145` in `157.14s` with `11.21 GB` peak RSS. The raw
generated difference is duplicate action-witness accounting. tlzig is `1.39x`
faster at the exact reachable-state count, and the row is retained as an
opt-in benchmark because the complete pair takes about four and a half minutes.

`APLamportMutex.cfg` is valid but intentionally unbounded, not a finite
exhaustive-evidence gap. `LamportMutex.tla` defines `Clock == Nat \ {0}` and
`ReceiveRequest` increases a process clock by one; the source explicitly
requires `ClockConstraint` to keep model checking finite, but the Apalache cfg
does not configure that constraint. TLC reached `96,045,036` distinct states
with `2,722,247` queued after 360 seconds.
The old tlzig representation reached `29,082,375` distinct states in
`84.011s` and then filled its `536,870,912`-value canonical pool. Recursive
subvalue sharing removes that failure. With the ordinary cache size, strict
AOT reaches `139,200,806/40,000,000` generated/distinct states in `63.24s`,
using only `13,082,908` canonical values. For state bounds above 64 Mi, the
generic interner now provisions 16 Mi slots. At 120 million states this lowers
canonical storage from `194,790,406` to `35,057,430` values; the identical
130-million-state bound improves from `259.70s` to `208.66s`, and peak process
footprint falls from `40.37 GB` to `33.97 GB`. These bounded runs establish
accepted exploration rather than an impossible exhaustive count. The finite
`MCLamportMutex.cfg`, which configures `ClockConstraint`, has paired exact
evidence at `2,729,079/724,274` generated/distinct states.

`EnvironmentController.cfg` remains bounded. TLC reached `2,691,395` distinct
states with `243,996` queued in 240 seconds. Fresh strict zero-fallback AOT
reached `112,675,153/20,000,000` generated/distinct states in `247.00s`, with
`2,848,141` states queued and `12.01 GB` peak RSS. Both engines accept and
explore the model, but the partial frontiers do not establish parity. The
post-sharing graph-aware repeat reached `112,409,658/20,000,000` in `268.42s`,
with `2,830,058` queued and `11.80 GB` peak RSS. CPU work was within 0.6% of
the larger-table repeat, but the historical `247.00s` wall sample remains
faster; no performance win is claimed for this low-density row.

Direct action lowering now recognizes bounded `SUBSET` choices without
materializing the complete power set, and conservatively pushes a leading
element-local universal guard into the base set. On the identical N=3 strict
AOT four-million-state boundary, wall time falls from `307.24s` to `18.48s`
(`16.63x`) and retired instructions from `62.399T` to `2.779T` (`22.46x`).
The optimized N=3 run then exposes a real upstream `TypeOK` violation at
approximately `456,440,685/47,087,903` generated/distinct states: a message
addressed to a failed process reaches age `43` although `maxAge` is `42`.

The reduced `EnvironmentControllerN2Safety.cfg` proves that this is not a
tlzig-only result. Java TLC and strict zero-fallback AOT tlzig both report the
same age-43 `TypeOK` violation. The default ReleaseFast benchmark records TLC
at `592,015/126,903` in `1.393s` and tlzig at `490,665/106,399` in `0.185s`,
a `7.53x` tlzig speedup; the 16.2% distinct-count difference is expected from
parallel early-stop scheduling and is bounded by an explicit 30,000-state
regression tolerance. The original N=3 cfg remains in the finite backlog:
its direct Java run was interrupted at `31,408,710/5,093,688` after `544.63s`
before reaching a verdict, so reduced paired evidence is not presented as an
exhaustive N=3 closure.

`TestMCReachability.cfg` now passes initialization through strict AOT. The
generated compiler previously evaluated the TLA body of the Community Modules
`IOUtils!IOEnv` operator instead of TLC's native module override, causing its
imported graph assumptions to fail with `TypeError`. Module-qualified native
overrides now preserve their source-module identity and do not capture a user
operator with the same unqualified name. The post-fix all-core pair reached
TLC `376,820/252,366` before its 60-second timeout and strict zero-fallback
tlzig's explicit ten-million-state cap at `15,719,199/10,000,000` in
`32.783s`. The semantic rejection is fixed; the row remains bounded because
both frontiers are incomplete.

`MultiPaxos_MC.cfg` is closed exhaustively. Fresh strict AOT emits `60`
generated operators, one standard native definition, and zero fallback. TLC
and tlzig both complete without error at exactly `37,078,209` quotient states;
tlzig reports `101,402,513` raw generated successors and TLC `101,413,181`, a
`10,668` duplicate-action-witness accounting difference. Before the generic
symmetry-cache repair, tlzig completed in `312.16s`, behind TLC's `292.63s`.
Passing each worker's private candidate and canonical hash caches through
symmetry canonicalization reduces tlzig to `254.14s`, retired instructions
from `58.84T` to `48.02T`, and cycles from `14.00T` to `11.43T`. The repaired
run is `1.15x` faster than TLC at exact distinct-state parity and uses
`10.21 GB` peak RSS versus TLC's `11.17 GB`.

`MCNanoLarge.cfg` is closed exhaustively. Strict AOT emits `51` generated
operators, one native built-in, and zero fallback. TLC and tlzig both complete
at exact `258,355,199/120,130,843` generated/distinct states. ReleaseFast
TLC-auto takes `331.332s`; tlzig-AOT-auto takes `218.574s`, making tlzig
`1.52x` faster. The closure also found and fixed a generic deferred-operator
bug: syntactically unprimed generated calls now retain partial next-state
assignments when an operator-valued argument can close over primed state.

`aba_asyn_byz.cfg` is closed. Strict AOT emits `15` generated operators, four
standard temporal/native definitions, and zero fallback. tlzig completes the
base graph and all three temporal properties at exact TLC base-state parity:
`5,843,977` distinct states. It reports `85,121,584` raw generated successors
versus TLC's `85,612,896`, a duplicate-edge accounting difference, and finishes
in `139.36s` with `3.36 GB` peak RSS. TLC completed the same base graph but had
not finished its temporal-product analysis after 240 seconds, so tlzig is at
least `1.72x` faster to the successful temporal verdict on this row.

`EWD687a_anim.cfg` is closed in its manifest-declared simulation mode. Both
engines find `InterestingBehavior` with 100 traces, depth 100, and seed
`6074329268192498505`. The post-temporal paired ReleaseFast audit records
TLC-auto `0.719s` and tlzig `0.058s`, a `12.4x` tlzig speedup. Java TLC first
reports the invariant violation; SVG alias exceptions in its trace are
rendering diagnostics, not the model outcome. Historical exhaustive frontiers
used the wrong mode and are not coverage evidence for this model.

`EWD998.cfg` now completes strict-AOT exploration at `2,613,583,722` generated
transitions, `248,006,200` distinct states, and `2,083,298,801` graph edges.
It emits `33` generated operators, four native built-ins, and zero fallback.
The earlier strict-AOT temporal mismatch was a generic code-generation defect:
`UNCHANGED` on a zero-arity named operator inherited the enclosing action's
arguments. ReleaseSafe caught the arity violation; generated code now passes an
empty argument slice. Constrained N=2 and N=3 temporal differentials match TLC
at exact `6,876` and `1,520,618` distinct states and pass both configured
temporal properties. The corrected N=4 strict-AOT run also completes both
properties. Its Java TLC reference run remains in the final disk-backed
liveness pass, so final paired TLC count evidence is still open.

The two non-model harnesses are retained visibly in the manifest:

- CarTalkPuzzle Toolbox Model 3 evaluates and prints the combinatorial
  `AllSolutions` expression. Current Java TLC did not finish that expression
  within a 120-second isolated run.
- `SmokeEWD998_SC` spawns nested Java TLC simulations from top-level
  assumptions and writes statistical CSV files. The audit does not launch
  those side-effecting child processes as a model check.

## MDBTLA Evidence

`python3 scripts/audit_mdbtla_coverage.py` reports all 13 upstream cfg files:
11 TLC-valid rows are benchmark-covered and two upstream cfgs are invalid in
both engines because `Timestamps` is not assigned.

A fresh 2026-07-12 paired run is recorded in
`coverage_results/mdbtla_post_lazy.jsonl`: two completed models have exact
distinct-state parity, seven first-counterexample models have the same outcome,
two large models are explicitly bounded at 60 seconds in both engines, and the
same two upstream configs are TLC-invalid. There are no gaps, crashes, outcome
mismatches, or completed distinct-state mismatches. The bounded rows remain
non-exhaustive until their longer runs finish.

The generic generated-code fixes were also checked on the exhaustive BTree
model. `coverage_results/aot_structural_gate_2026-07-28.jsonl` records exact
`2,820,091/374,727` generated/distinct parity. Fresh all-core ReleaseFast time
is TLC `4.066s` versus strict zero-fallback tlzig `0.954s` (`4.26x`).

Extended 300-second one-core audits are recorded separately. For
`SingleLog/MCMDBProps`, current interpreted tlzig completed the full
`3,101,918/269,881` state space in `208.27s`; TLC reached its time bound at
`115,995` generated and `32,160` distinct states. For upstream
`SingleShardTxn/ShardTxn`, TLC reached the bound at `2,580,997` distinct states
and interpreted tlzig exhausted the audit's 1 GiB canonical pool at `941,455`
distinct states. That row remains bounded here and is validated through the
larger-memory strict AOT benchmark instead.

Previous full `ReleaseFast` paired runs have exact completed-state parity for
the long rows, including:

| Model | Distinct states | TLC | tlzig AOT | Speedup |
| --- | ---: | ---: | ---: | ---: |
| Storage exhaustive | 1,078,623 | 35.981s | 13.22s | 2.72x |
| RC/no-prepare-block exhaustive | 17,057,584 | 172.084s | 86.18s | 2.00x |
| RC/no-prepare-block-or-ww exhaustive | 18,764,120 | 191.966s | 91.94s | 2.09x |
| RC/with-prepare-block exhaustive | 15,738,792 | 155.452s | 75.65s | 2.05x |
| RC/snapshot exhaustive | 67,629,092 | 697.495s | 314.422s | 2.218x |
| SingleLog MCMDBProps | 269,881 | 1,434.504s | 99.42s | 14.4x |
| SingleShardTxn ShardTxn | 5,502,547 | 179.117s | 24.286s | 7.38x |

The current 2026-08-04 strict-AOT rerun also closes Storage exhaustive at
exactly `1,078,623` distinct states: TLC takes `32.756s` and tlzig takes
`8.652s` (`3.79x`). TLC reports `9,390,226` generated successors while tlzig
reports `8,723,634`; this is duplicate-successor accounting, not a quotient
state-set difference. Both engines finish successfully and the strict artifact
contains 37 generated operators, no native user definition, and zero fallback.
The current RC/no-prepare-block exhaustive pair likewise completes at exactly
`17,057,584` distinct states: TLC takes `179.949s` and strict AOT tlzig takes
`80.513s` (`2.24x`). Its 67 generated operators contain no native user
definition and zero fallback.
RC/no-prepare-block-or-ww completes at exactly `18,764,120` distinct states:
TLC takes `193.182s` and strict AOT tlzig takes `94.507s` (`2.04x`), again
with 67 generated operators, no native user definition, and zero fallback.
RC/with-prepare-block completes with exact generated and distinct parity at
`89,960,594/15,738,792`; TLC takes `164.528s` and strict AOT tlzig takes
`69.726s` (`2.36x`). Its 67 generated operators also contain no native user
definition and zero fallback.
Finally, RC/snapshot completes with exact generated and distinct parity at
`405,005,930/67,629,092`; TLC takes `685.901s` and strict AOT tlzig takes
`315.854s` (`2.17x`). The complete current MultiShard exhaustive matrix is
therefore exact and every strict AOT row is faster than its paired TLC run.
The current full upstream `SingleShardTxn/ShardTxn.cfg` pair also has exact
generated and distinct parity at `14,931,205/5,502,547`. TLC takes `157.304s`
and strict AOT tlzig takes `38.931s`, a `4.04x` speedup. Its four maintained
reduced safety/symmetry companions also complete with exact counts.
The current `SingleLog/MCMDBProps.cfg` temporal pair completes with exact
generated and distinct parity at `3,101,918/269,881`. TLC takes `1,331.490s`
and strict AOT tlzig takes `11.402s`, a `116.77x` speedup. The artifact contains
40 generated operators, three standard native definitions, and zero fallback.
Together with the default benchmark's current short-row outcomes and exact
ClientCentric/MDBLinearizability results, all 11 TLC-valid upstream MDBTLA cfgs
now have fresh current-code all-core evidence; the other two remain
evidence-backed TLC-invalid inputs.

The MCMDBProps TLC timing is the completed baseline for the unchanged upstream
model; its current one-core TLC rerun was still incomplete at 300 seconds.
SingleShardTxn is a fresh paired 2026-07-12 run. Both current tlzig AOT runs
completed exact generated and distinct counts. First-error MultiShard rows
compare outcome rather than partial counts because parallel traversal may stop
on different valid witnesses.

The RC/snapshot entry was refreshed in a new paired run on 2026-07-16. The
strict generated model reported `67` operators and `fallback_count = 0`; TLC
and tlzig both completed exact `405,005,930/67,629,092` generated/distinct
counts. Fresh all-core ReleaseFast wall times were `697.495s` for TLC and
`314.422s` for tlzig, a `2.218x` speedup. The new tlzig run is `1.013x` faster
than the preceding `318.628s` exact run and `2.162x` faster than the original
`679.912s` tlzig baseline. The earlier `318.628s` run remains the latest exact
hardware-counter observation (`54.658T` retired instructions and
`29,406,117,888` bytes peak RSS); the fresh paired run did not collect those
counters.

The default ReleaseFast benchmark keeps heavy exhaustive rows opt-in. The base
runner skips generated-preferred models; each strict zero-fallback AOT row runs
TLC-auto once and tlzig-AOT-auto once in the same comparison, so there is no
interpreted tlzig duplicate and no dependency on an untracked baseline file.
The latest completed run on 2026-08-04 stayed within the five-minute guideline
and passed generation, compilation, and every configured comparison. TLC-auto
versus tlzig-AOT-auto was ClientCentric `2.431s` vs `0.486s`, RC/snapshot
`2.411s` vs `0.242s`, SingleShardTxn/small `2.673s` vs `0.154s`, SingleLog
MDBLinearizability `2.234s` vs `0.164s`, MCBinarySearch `1.948s` vs `1.030s`,
Slush Medium `25.645s` vs `19.057s`, GameOfLife `1.700s` vs `0.701s`,
`cf1s_folklore` `16.871s` vs `7.750s`, and Bosco `61.298s` vs `8.157s`.
Completed rows retain exact distinct counts.
Configured first-error rows compare semantic outcome because parallel frontier
order can reach different valid witnesses and partial state counts.

## Generic Fixes In This Audit

- Module instance substitution, module-scoped config assignments, restricted
  quantifiers, custom operators, FoldFunction domains, and parser block forms.
- Lexically scoped operator frames and capture-avoiding action inlining.
- Structural function/record/power-set membership without materializing huge
  TypeOK domains.
- Compiled `ENABLED` feasibility checks without candidate-state allocation.
- Concrete-transition safety checks before symmetry canonicalization.
- Fairness extraction through aliases, quantified bindings, strings, tuple
  subscripts, and inherited module definitions.
- `<>P` now computes SCCs on the `~P` induced graph and reevaluates fairness
  witnesses on internal edges; acyclic singletons are not infinite behaviors.
- Repeated action assignments now behave as conjunctive constraints. A later
  membership or `UNCHANGED` clause no longer overwrites an earlier equality.
  Moving Cat now matches TLC exactly at `128/48` and `78/30` generated/distinct.
- Paired audit manifests are atomically normalized and preserve raw results.
- Generated zero-arity `LET` definitions are lazy thunks in both direct AOT
  execution and decomposed action plans. Generated-expression availability now
  honors required-argument masks, preventing unused missing captures from
  forcing interpreter fallback or leaking executable values into state.
- Multi-bound function literals lower to Cartesian-product domains and tuple-key
  functions. Multi-argument function application uses the corresponding tuple
  key, matching TLC's `[x, y |-> e]` semantics.
- Tuple-destructuring function binders preserve their declared domain instead
  of multiplying it by tuple arity. Multi-bound set maps iterate their domains
  directly without materializing an intermediate Cartesian product.
- Function-set membership assignments enumerate one function at a time from
  the symbolic `[S -> T]` value. Initial-state generation no longer builds the
  entire function set in the evaluation pool, and candidate capacity is
  derived from the configured state budget.
- Generated models carry an explicit runtime ABI version. AOT benchmark rows
  regenerate their model from the declared TLA+/CFG inputs before compilation,
  so stale generated Zig cannot silently run against changed semantics.
- Config aliases used from inherited specifications now select the configured
  action instead of a nested boxed action inside fairness. MCCRDT explores all
  four `ReductionNext` branches and completes at the TLC-exact `25,000`
  distinct states; tlzig-auto took `0.786s` versus TLC-auto `1.684s`.
- Action substitution alpha-renames colliding function binders. The full
  CheckpointCoordination model now completes at the TLC-exact `901,692`
  distinct states instead of reporting a false invariant at state 17.
- Generated and interpreted recursion detection now distinguishes an actual
  self-call from nonrecursive CHOOSE syntax. Sailfish strict AOT retained exact
  `300,492/109,604` generated/distinct counts and improved from `94.99s` to
  `14.27s` through recursive state-call memoization.
- Recursive-call memo keys have a fixed aggregate-node admission budget and
  reject executable operator values. This retains memoization for compact
  recursive state while avoiding repeated hashing/cloning of large linear
  recursion arguments. GameOfLife strict AOT remained exact at
  `131,072/65,536` and improved from `2.575s` to `0.794s` in the focused run;
  the fresh TLC comparison was `1.624s`.
- Evaluator materialization uses evaluator-local, per-worker high-water
  scratch frames for temporary values, names, lengths, and result staging.
  Record sets, tuple filters, unions, Cartesian products, and sorted sequence
  generation preflight their exact `ValuePool` requirements before retaining
  destination slices. `src/eval.zig` now contains no `page_allocator` or
  `ArrayList` path. The change removes per-call `mmap`/`munmap` traffic without
  introducing shared locks or model-specific semantics. Post-change exact
  gates include Bosco at `29,223,200/1,072,452` and MCBinarySearch at
  `34,383/27,953` generated/distinct states.
- Filtered power-set codegen distinguishes direct filters, which may capture
  the current operator arguments, from zero-arity named definition chains,
  whose filter helper has an independent lexical frame. Runtime entry points
  make that choice explicit, and Debug generated code asserts the resulting
  helper arity. The regression fixture covers both forms in one module.
- Generated lazy-operator closures honor required-argument masks when
  capturing lexical slots. An unused missing LET binding is represented by an
  inert slot instead of causing `UndefinedSymbol`; required bindings still
  fail closed.
- Structurally verified recursive finite-set sums lower to a direct iterable
  function fold. GameOfLife remains exact at `131,072/65,536` and improved
  from tlzig `2.581s` to `0.788s`, versus paired TLC `2.573s`.
- Standard `IsFiniteSet` calls use direct generated runtime functions.
  Boolean calls over configured constants inspect the constant slot without
  cloning the aggregate. All 40 stored generated models have ABI `2`, zero
  fallback, and zero string-based `runtime.native` dispatch calls.
- Large set construction uses resettable-pool-backed open addressing instead
  of a quadratic fallback, and ungraphed initial states avoid redundant edge
  deduplication. Initial candidates now stream in fixed-size batches; filtered
  record sets iterate their source domains without materializing the product,
  repeated candidate strings are interned, and canonical aggregate cache
  probes are bounded. CoffeeCan1000 is exact at `2,000,002/501,500`, tlzig
  `2.081s` versus TLC-auto `13.082s` (`6.29x`). CoffeeCan3000 is exact at
  `18,000,002/4,504,500`, tlzig `18.600s` versus TLC-auto `131.203s`
  (`7.05x`), and is `5.25x` faster than the previous tlzig `97.649s` run.
- Canonical value capacity is derived from the configured arena instead of an
  artificial 192-million-value ceiling. `MCKVSSafetyMedium` now completes at
  the TLC-exact `365,609,473/17,220,672` counts in `103.64s`, versus TLC-auto
  `173.982s`. `MCKVSSafetySmall` is also exact at
  `56,349,379/3,409,605`, taking `21.516s` versus TLC-auto `31.494s`.
- State assignments now use a bounded 64-variable mutable SoA trail with O(1)
  lookup and mark/rollback backtracking. Generated calls borrow the contiguous
  state value/source-pool columns directly; lexical extension no longer carries
  an impossible alternate pool. CLI/benchmark scratch pools are fixed after
  initialization unless unlimited growth is explicitly selected. The exact
  RC/snapshot run and the full default benchmark passed after these changes.
- All 28 stored generated models independently compile in ReleaseFast with
  ABI `2` and `fallback_count = 0`. An identifier audit finds audited MDBTLA,
  CoffeeCan, MCBinarySearch, GameOfLife, Slush, and EWD998 names only in parser
  tests under `src`; production runtime overrides remain built-ins and
  standard-module operators.
- Standard `Functions!FoldFunctionOnSet` calls now lower through a structurally
  verified map/fold definition and a direct generated reducer callback. The
  runtime iterates range/function inputs without materializing an intermediate
  set; same-named definitions with different bodies remain on the ordinary
  path. EWD998Small therefore generates `24` operators with strict
  `fallback_count = 0` without encoding EWD-specific semantics.
- EWD998 semantic parity is stronger than raw-count parity. A complete N=2
  labeled-graph audit matches all `6,876` states, all `32` initial states, all
  `26,182` unique directed edges, and all `6,158` weak-fair `System` edges.
  TLC emits `31,392` raw DOT edges because it retains `5,210` duplicate action
  witnesses. The exhaustive N=3 benchmark consequently compares exact outcome
  and exact `1,520,618` distinct states, while treating TLC's duplicate-witness
  counter as non-semantic. Fresh all-core ReleaseFast time is TLC `3.274s`
  versus strict tlzig AOT `1.865s` (`1.76x`).
- MultiPaxosSmall strict AOT emits `60` generated operators, `1` native
  temporal definition, and `fallback_count = 0`. A complete graph audit
  canonicalized both engines under the configured `s1/s2/s3` replica symmetry
  and matches all `343,796` quotient states, the single initial state, and all
  `735,847` unique semantic edges. TLC's DOT retains `164` duplicate action
  witnesses, so the benchmark compares exact outcome and distinct states
  rather than the non-semantic raw witness counter. Generic pure-union
  membership fusion then reduced strict tlzig from `2.773s` to `1.311s`;
  a repeated paired ReleaseFast run measured TLC `2.753s`, making tlzig
  `2.10x` faster while retaining exact distinct-state parity.
- Generated `ENABLED` expressions now consume the action compiler's exact
  feasibility result through `CallContext`; strict action operators no longer
  fall back merely because they contain `ENABLED`. Quantified fairness domains
  materialize every finite symbolic set-like value, including record sets,
  and reject non-set values instead of silently producing zero obligations.
- MultiCarElevator's large base graph has exact semantic parity: `50,653`
  states, `729` initial states, and `218,899` unique directed edges. TLC emits
  `230,170` raw edges because it retains `11,271` duplicate action witnesses.
  Every one of the model's `20` quantified WF/SF action relations also matches
  exactly, including six record-valued dispatch bindings and two impossible
  bindings with zero edges.
- The completing `ElevatorLivenessMedium` temporal model generates strict AOT
  with `22` operators, `3` temporal-native definitions, and
  `fallback_count = 0`. TLC and tlzig both finish without error at exact
  `14,296/4,122` generated/distinct counts. After exact fairness replay exposed
  and fixed a cross-pool nested-EXCEPT defect, the fresh paired ReleaseFast
  benchmark is TLC-auto `4.260s` versus tlzig-AOT-auto `0.162s` (`26.3x`).
- Hereditary finite-set filters lower algebraically before enumeration:
  `{E \in SUBSET A : \A e \in E : P(e)}` is represented as the symbolic
  `SUBSET {e \in A : P(e)}`. The action compiler keeps that domain intact and
  generated Zig emits a direct inner predicate helper, avoiding both eager
  `2^|A|` construction and interpreter fallback.
- `SpanTreeTest5Nodes` is now exhaustive and exact at
  `3,150,464/410,112` generated/distinct states with both temporal properties
  satisfied. Strict AOT reports `7` generated operators, `3` temporal-native
  definitions, and `fallback_count = 0`; TLC-auto took `423.53s` and tlzig
  took `2.83s`, a `149.7x` speedup. The row is an opt-in long benchmark because
  TLC's serial initial-state enumeration alone takes almost seven minutes.
- Generated membership now handles a canonical symbolic set as an element of
  `SUBSET A` by testing subset inclusion across value pools. Explicit sets and
  ranges stay allocation-free; uncommon symbolic representations materialize
  only when direct inclusion is unavailable.
- Fairness masks are finalized from the actual parent/child transition
  semantics before SCC analysis. This removes the unsound assumption that a
  conjunction-valued fairness action can be identified from one nested named
  operator marker. The exact masks are computed once and reused by full-graph
  and induced-subgraph temporal checks.
- `bcastFolklore` now completes without error in both engines at exact
  `9,718,336/501,552` generated/distinct counts. Its strict model has `12`
  generated operators, `5` native temporal definitions, and
  `fallback_count = 0`. ReleaseFast all-core timing is TLC `1,148.63s` versus
  tlzig `65.42s`, a `17.56x` speedup. The prior tlzig result was an incorrect
  temporal violation at `66.48s`; the corrected run is also `1.6%` faster.
  This nineteen-minute TLC comparison is an opt-in benchmark.
- The annotation/INSTANCE wrapper `APbcastFolklore` also completes without
  error at exact `9,718,336/501,552` counts. Its strict artifact has `12`
  generated operators, `1` native temporal definition, and
  `fallback_count = 0`. The public ReleaseFast all-core benchmark is TLC
  `3.950s` versus tlzig `1.713s` (`2.31x`), while separately measured peak RSS
  is approximately `1.67 GB` versus
  `423 MB`. This short row is enabled in the default all-core benchmark.
- Generic bounded power-set action choices no longer materialize and reject the
  complete power set. For leading pure bounds, the action compiler enumerates
  only sets between the required lower set and allowed upper set; volatile,
  bound-dependent, and primed bounds retain the ordinary path.
- `bosco` and its annotation wrapper `APbosco` both complete without error at
  exact `29,223,200/1,072,452` generated/distinct counts. The public strict AOT
  benchmark is TLC-auto `59.855s` versus tlzig `6.938s` (`8.63x`); `APbosco`
  is TLC-auto `67.83s` versus tlzig `6.64s` (`10.22x`). Both strict translations
  have `27` generated operators, `1` native temporal definition, and zero
  fallbacks.

- Local recursive `LET` functions now compile to self-capturing generated
  operators with bounded contiguous captures. PaxosCommit therefore has a
  strict zero-fallback artifact (`16` generated, `1` native) and completes at
  exact `1,321,761` distinct states in both engines. A reduced complete audit
  matches all `1,461` states, the single initial state, and all `5,136` unique
  semantic edges. TLC's `9,935` raw edges include `4,799` duplicate witnesses,
  so the benchmark requires exact distinct parity but does not compare raw
  witness totals. Full ReleaseFast timing is currently TLC `13.202s` versus
  tlzig `11.914s`; performance optimization remains open.

- Computed `UNCHANGED` operands introduced by INSTANCE substitutions now use
  generated primed evaluation. Nested unbounded domains also keep set union,
  intersection, and difference symbolic, so record sets containing `Int` are
  checked structurally instead of materialized. EWD998Chan has a strict
  zero-fallback artifact (`35` generated, `3` native). Its N=2 audit matches
  all `7,150` states, `32` initial states, `27,550` unique edges, and `6,410`
  weak-fair edges; TLC retains `9,534` duplicate edge witnesses.
- Temporal state formulas, `ENABLED`, and boxed action relations are evaluated
  in bounded batches across private worker evaluators once the immutable graph
  is complete. The original N=3 EWD998Chan configuration matches TLC at
  `1,524,022` distinct states and completes in `21.868s`, down from the prior
  tlzig `124.150s` and versus TLC-auto `68.32s`.

## Remaining Work

- [ ] Run opt-in exhaustive paired checks for the remaining bounded primary
  rows.
- [x] Complete the extended paired runs for upstream `MCMDBProps` and
  `ShardTxn`. Exact completed evidence is `3,101,918/269,881` and
  `79,141,749/5,502,547` generated/distinct states, respectively; the old
  60-second audit rows remain only as historical bounded samples.
- [ ] Audit ordinary non-TLAPS model fixtures under `vendor/tlaplus` separately
  from Java-extension, distributed-TLC, trace, and malformed-input fixtures.
- [ ] Continue generic typed AOT lowering from trusted TypeOK facts and
  measured profile data. PGO observations may select optimizations, but cannot
  silently assume semantics not guaranteed by the model/configuration.
- [ ] Lower the measured generated-code backlog generically: 25,548 nested
  helper chains, 5,073 variable paths, 1,233 whole-root primed comparisons,
  557 mapped sets, 435 unchanged expressions, 234 EXCEPT reconstructions, and
  176 materialized function ranges. Clone, fingerprint, action execution, and
  aggregate movement dominate the current profile; SIMD should follow typed
  contiguous lowering rather than pack recursive `Value` trees at runtime.

## Reproduction

```sh
tools/zig-aarch64-macos-0.17.0-dev.1552+79dc16a0e/zig build
python3 scripts/audit_spec_coverage.py \
  --corpus specs \
  --corpus vendor/tlaplus-examples/specifications \
  --corpus vendor/MDBTLA \
  --jobs 8 --timeout 60 --resolve-timeout 60 \
  --max-states 1000000 --retry-bounded \
  --output coverage_results/primary_2026-07-16_retry60_1m.jsonl
python3 scripts/audit_mdbtla_coverage.py
python3 scripts/compare_state_graphs.py \
  --tlc-dot /tmp/ewd_n2_tlc.dot \
  --tlzig-states /tmp/ewd_n2_tlzig_states.txt \
  --tlzig-initial /tmp/ewd_n2_tlzig_initial.txt \
  --tlzig-graph /tmp/ewd_n2_tlzig_graph.txt \
  --fairness 0:InitiateProbe,PassToken
```
