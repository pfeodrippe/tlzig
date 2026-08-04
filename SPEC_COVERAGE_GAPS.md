# TLA+ Specification Coverage

Last updated: 2026-07-28

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
The latest completed run on 2026-07-28 stayed within the five-minute guideline
and passed generation, compilation, and every configured comparison. TLC-auto
versus tlzig-AOT-auto was ClientCentric `2.328s` vs `0.429s`, Storage `1.428s`
vs `0.163s`, RC/snapshot `2.404s` vs `0.249s`, SingleShardTxn/small `2.353s`
vs `0.155s`, SingleLog MDBLinearizability `2.040s` vs `0.156s`,
MCBinarySearch `2.755s` vs `1.311s`, Slush Medium `24.807s` vs `18.591s`, and
GameOfLife `2.573s` vs `0.788s`. Completed rows retain exact distinct counts.
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
tools/zig-aarch64-macos-0.17.0-dev.1543+6db520a4c/zig build
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
