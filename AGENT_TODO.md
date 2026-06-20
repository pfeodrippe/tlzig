# AGENT_TODO — tlzig Implementation Tracker

## Mission
Build a Zig TLA+ model checker that is faster than Java TLC on TLC-valid specs
in `vendor/tlaplus-examples/specifications`, from simplest to most complex.
TLAPS proof-only modules are intentionally outside the product scope.

## Progress Legend
- [ ] Not started
- [~] In progress
- [x] Done

## Phase 0 — Foundation
- [x] Add `vendor/tlaplus-examples` submodule
- [x] Add `vendor/zig` (Codeberg master) submodule
- [x] Add `vendor/tlaplus` clone for study
- [x] Download latest Zig master binary for macOS aarch64
- [x] Create `build.zig` / `build.zig.zon`
- [x] Create `IMPLEMENTATION.md`
- [x] Get `zig build test` green
- [x] Get `zig build` green

## Phase 1 — Core Engine
- [x] Value representation stable and tested
- [x] Fingerprint / FPSet tested
- [x] State store and queue tested
- [x] Expression evaluator tested
- [x] Action / next-state generator tested
- [x] Invariant checker tested
- [x] Config parser tested
- [x] End-to-end checker CLI tested

## Phase 2 — Examples (simplest to complex)

Target: **100% of TLC-valid, non-TLAPS configurations must pass.**

### Current validation snapshot (2026-06-18)
- Unit/integration suite: `75/75` passing in Debug.
- Probe suffix after EWD998: `18 PASS / 14 FAIL / 2 SKIP`.
- `sums_even/MC_sums_even` is excluded: Java TLC rejects it during parsing
  because its base module imports `TLAPS`; tlzig must not invent proof-system
  semantics to make it pass.
- Exact advanced examples:
  - EWD998 Async: `53271/4097`.
  - YoYo NoPruning: `110/60`.
  - YoYo Pruning: `157/102`.
  - MCCRDT: `1350001/25000`.
  - MCReplicatedLog: `11617/1363`.
  - MCInnerSerial: `11136/972`.
- Parser/evaluator support added for expression-only specs, assumptions,
  symbolic `Nat`/`Int`/ranges, tuple destructuring, local namespace
  instances, primed function applications, record `DOMAIN`, nested function
  sets, action composition, and lexical `LET` shadowing.

### MDBTLA / MultiShardTxn integration (2026-06-18)
- [x] Add `muratdem/MDBTLA` as `vendor/MDBTLA` submodule at
  `39ba8ba327c57366e82f7aee970f2c1e366e94b7`.
- [x] Parse parameterized namespace instances such as
  `Storage(s) == INSTANCE Storage WITH ...`.
- [x] Preserve namespace-qualified calls in `ASSUME`; `CC!Op(...)` is no
  longer misparsed as an assumption label.
- [x] Support config operator replacements such as
  `AbortTransaction <- FALSE` without suppressing sibling `Next` branches.
- [x] Support string-keyed nested record `EXCEPT` and record `@@` override.
- [x] Validate `ClientCentricTests` against bundled TLC:
  - TLC `-workers 1`: `1602/801`, 2.286s in benchmark.
  - TLC `-workers auto`: `1602/801`, 2.375s.
  - tlzig `--workers 1`: `2044/801`, 8.427s.
  - tlzig `--workers auto`: `2044/801`, 8.438s.
  - Distinct states match exactly; generated-state accounting still differs.
- [x] Reduce `ClientCentricTests` tlzig runtime from 159.5s to 4.66s:
  bounded fingerprint set deduplication, assumption-scoped definition
  memoization, and pre-sized non-growing evaluation/state pools.
- [x] Add `ClientCentricTests` to the ReleaseFast benchmark with MDBTLA's
  bundled TLC/CommunityModules classpath.
- [x] Fix RC semantic under-exploration and deadlock handling:
  - unprimed state applications now read the pre-state inside actions;
  - parameterized namespace calls flatten instance and operator arguments;
  - TLC-compatible deadlocks are reported instead of false completion;
  - all four RC model configs now match TLC's full-run outcome and depth.
- [x] Implement fixed-capacity, allocation-free evaluator contexts with
  branch snapshots; remove the 32-entry context copy from every recursive
  expression evaluation.
- [x] Implement TLC-compatible symmetry support:
  - parse `SYMMETRY`;
  - return model-value functions from `Permutations`;
  - compute the generated permutation subgroup;
  - fingerprint a deterministic orbit representative.
- [x] Remove page-allocator calls from the hot one-variable set-filter path
  and use fixed-stack open addressing for large set deduplication.
- [x] Run full, unbounded single/auto comparisons for every upstream-valid
  MDBTLA MultiShardTxn configuration and add each case to the benchmark:
  `ClientCentricTests.cfg`, `Storage.cfg`, `MCMultiShardTxn.cfg`,
  `MCMultiShardTxn_rc_local.cfg`, and all four configs under `models/`.
- [x] Make all-core tlzig faster than TLC on every full MultiShardTxn run.
  Representative ReleaseFast results:
  - RC snapshot: tlzig `1.03s` vs TLC `2.44s`;
  - Storage: tlzig `0.45s` vs TLC `1.50s`;
  - RC no-prepare-block: tlzig `0.15s` vs TLC `1.59s`;
  - symmetry rc-local: tlzig `0.15s` vs TLC `1.44s`;
  - ClientCentric: tlzig `1.95s` vs TLC `2.36s`.
- [ ] Eliminate the remaining single-core gaps:
  - RC snapshot: tlzig `6.76s` vs true one-core TLC `5.30s`;
  - Storage: tlzig `3.36s` vs true one-core TLC `2.76s`;
  - ClientCentric is now faster in both modes:
    tlzig `1.92s/1.95s` vs TLC `2.25s/2.36s`.
  - Snapshot-invariant symmetry is now faster in both modes:
    tlzig `1.96s/1.40s` vs TLC `2.21s/1.80s`.
- [x] Add strict configuration-aware Zig generation:
  every configured `INIT`, `NEXT`, invariant, temporal property, state/action
  constraint, symmetry operator, and operator substitution is a native
  reachability root. Strict builds reject any reachable fallback.
- [x] Remove the `--allow-fallbacks` generation escape hatch. Emission is now
  all-native for the selected configuration or fails with the exact
  unsupported definition list.
- [x] Attach module/config identity metadata to generated models and activate
  generated registries only when the loaded module and all configured roots
  match. This prevents common names such as `Init` and `Next` from leaking
  across benchmark specs.
- [x] Compile every upstream-valid MultiShardTxn configuration with zero
  reachable fallbacks. Current strict counts range from 41 generated
  operators for `Storage.cfg` to 83 for the snapshot-invariant config.
- [x] Add generated-runtime cross-pool state access so emitted Zig traverses
  nested state functions/tuples/records in canonical storage and clones only
  the selected leaf. RC snapshot single-thread improved from `7.13s` to
  `6.39s`; Storage improved to `1.78s`.
- [x] Make the benchmark link an optional strict generated model and activate
  it only for matching configs. Print both TLC and tlzig state counts so
  deadlock traversal-order differences are visible.
- [ ] Generate native execution for the compiled `ActionStep` tree. Generated
  expression operators are faster, but `Next` still dispatches recursively
  through the generic action executor and AST evaluator. This is the primary
  remaining RC snapshot single-core gap.
- [ ] Re-run exhaustive `CHECK_DEADLOCK FALSE` differential models before
  treating deadlock-stop generated/distinct counts as coverage totals.
  Default MultiShardTxn configs stop at the first valid deadlock, and worker
  scheduling/enumeration order changes those partial counts.
- [ ] Current strict AOT full-run performance snapshot:
  - ClientCentric: TLC `2.231s/2.364s`, tlzig `1.550s/1.578s`;
  - Storage: TLC `2.828s/1.516s`, tlzig `1.777s/0.440s`;
  - RC snapshot: TLC `5.216s/2.173s`, tlzig `6.392s/0.898s`.
  RC snapshot single-thread remains the explicit performance blocker.
- [x] Stream one-variable filters over finite function sets through resettable
  scratch storage and materialize only accepted functions. This removes
  rejected composite values from `TxnSetsAll` while preserving exact results.
- [x] Detect pointwise finite-function predicates
  `{f \in [D -> C] : \A x \in D : P(x, f[x])}` conservatively, validate the
  quantified domain, and construct only products of per-key accepted values.
  Non-pointwise predicates retain the general complete-enumeration path.
- [x] Add native, allocation-bounded implementations for standard finite
  operators used heavily by MDBTLA: `PermSeqs`, `SeqToSet`, `Index`,
  function `Range`, `INTERSECTION`, and sequence `ReduceSeq/FoldFunction`.
  Add a generic sequence-record-field projection for function literals such
  as `[i \in 1..Len(s) |-> s[i].field]`.
- [x] Represent generated candidates as overlays: changed roots live in the
  candidate pool while unchanged roots borrow immutable canonical values.
  Make constraint evaluation and symmetry hashing pool-aware per variable.
- [x] Fuse state-rooted `EXCEPT` cloning with path update, and specialize
  universal scalar constraints over nested state functions.
- [x] Prototype and reject direct-canonical successors and per-parent
  unchanged-root caching after full benchmarks. Both lose to the small
  resettable candidate pool's cache locality (snapshot +6.7%, Storage +3.5%);
  do not carry either path without a different storage representation.
- [x] Prototype and reject a 4,096-entry worker-local AST variable-index
  cache. RC snapshot remained neutral (`7.171s` vs `7.176s`) while increasing
  per-worker memory; linear lookup is not the dominant remaining cost.
- [x] Prototype and reject cross-pool string interning, recursive borrowed
  field access, and generic parameterized-call memoization:
  - string hashing regressed ClientCentric to `4.36s`;
  - recursive borrowed field discovery regressed RC snapshot to `7.24s`;
  - semantic argument hashing regressed ClientCentric to `14.7s`.
  These costs need compile-time resolution or representation changes, not
  additional runtime hashing and AST-shape discovery.
- [ ] Replace deep temporary successor copies with a compact or structurally
  shared candidate representation that preserves the resettable candidate
  pool's locality. Benchmark before retaining the design.
- [ ] Complete and integrate the existing resolved IR evaluator so hot
  expressions use variable indices, definition references, and local slots
  directly. Fix `IrModule.defs` construction and keep the AST evaluator as
  the compatibility fallback until every benchmarked construct is covered.
  - [x] Export the resolved definition bodies from `Resolver.resolve_all`
    and compile the resolver through a cross-definition unit test.
  - [ ] Implement IR evaluation and differential tests against the AST
    evaluator before enabling it for model checking.
- [ ] Match TLC's generated count for `ClientCentricTests` (`1602/801`;
  tlzig currently reaches the same `801` distinct states with different
  generated-state accounting).
- [x] Classify upstream configs that TLC itself rejects:
  `MultiShardTxn.cfg` and `models/MultiShardTxn_RC.cfg` omit required
  constants such as `Timestamps`; do not invent tlzig-only defaults.

### Long-running public benchmark candidates
- [ ] `detector_chan96/EnvironmentController.tla` (official Examples;
  documented runtime over two hours):
  https://github.com/tlaplus/Examples/blob/master/specifications/detector_chan96/EnvironmentController.tla
- [ ] Payment-channel model (reported about two hours / 1,131,490 states):
  https://conf.tlapl.us/2021/MatthiasGrundmann-talk.pdf
- [ ] Snapshot-isolation database model (reported 44 minutes with three keys):
  https://muratbuffalo.blogspot.com/2023/09/a-snapshot-isolated-database-modeling.html
- [ ] Fine-grained DCAS model (historical report around 40 hours):
  https://lamport.azurewebsites.net/tla/dcas.pdf
- [ ] Existing vendor long models: `MCKVSSafetyLarge` (~7h16),
  `SlushLarge` (~50m), `bcastFolklore` (~30m), MultiCarElevator liveness
  (~11m), `aba-asyn-byz` (~10m), and high-level EWD998 (~50m).
- [ ] Add only reproducible, TLC-valid configurations to benchmark tiers;
  keep >10-minute cases opt-in so the default benchmark remains usable.

### Representative benchmark run (ReleaseFast)
```
                            SPEC      TLC-1   TLC-auto    tlzig-1 tlzig-auto       states
----------------------------------------------------------------------------------------
                   HourClock.tla      0.671      0.369      0.001      0.002           12
             AsynchInterface.tla      0.397      0.384      0.000      0.001           12
                     Channel.tla      0.377      0.443      0.000      0.001           12
                     DieHard.tla      0.406      0.408      0.002      0.003           14
    MissionariesAndCannibals.tla      0.437      0.424      0.009      0.007           61
            CigaretteSmokers.tla      0.406      0.457      0.001      0.001            6
          APCigaretteSmokers.tla      0.433      0.413      0.001      0.002            6
                   CoffeeCan.tla      0.793      0.855      0.565      0.581         5150
                      Simple.tla      0.463      0.447      0.029      0.031          723
                     Barrier.tla      0.407      0.408      0.006      0.008           64
                        Lock.tla      0.422      0.418      0.001      0.002           12
                  MCMajority.tla      0.519      0.527      0.088      0.112         2733
               MCFindHighest.tla      0.524      0.508      0.006      0.011          742
                    TwoPhase.tla      0.424      0.420      0.006      0.007          288
               LiveHourClock.tla      0.375      0.381      0.001      0.001           12
                     TCommit.tla      0.397      0.391      0.002      0.003           34
                   APTCommit.tla      0.431      0.401      0.002      0.004           34
              MCChangRoberts.tla      0.467      0.437      0.005      0.008          137
                    SpanTree.tla      0.707      0.630      1.021      0.972         1236
    SyncTerminationDetection.tla      0.467      0.428      0.022      0.017          129
   AsyncTerminationDetection.tla      0.632      0.582      0.352      0.297         4097
```
Intentional invariant/property-violation models compare deterministic
single-thread counts; parallel runs may stop after a different worker finds
the same counterexample.

### Coverage probe (all 226 specifiable configs, max_states=200000, --unlimited-memory)
- PASS: 111 / 226 (49%) -- up from 50->53->73->74->81->82->89->91->98->100->103->104->108->109->111
- FAIL categories: StateSpaceExhausted 20, TypeError 13, UndefinedSymbol 15, ConfigError 12, SyntaxError 7, NotImplemented 2, OOM 2
- Note: remaining failures are mostly missing features (Init-as-predicate enumeration, `Bags`/`FiniteSets` operators, complex PlusCal, symmetry) and a few parser gaps.

### Recent fixes (latest batch)
- **Parser: `@@`/`\o`/`:>` in comparison RHS**: `parse_comparison` now uses `parse_cartesian()` for RHS, fixing `L = (state :> 0) @@ L` and similar in PlusCal-generated code (TLCMC, etc.).
- **Parser: operator references**: `+`, `\cup`, etc. are now accepted as function arguments by generating a lambda (e.g. `F(+, a, b)` becomes `F(LAMBDA x,y: x+y, a, b)`).
- **Parser: module terminator `====`**: `skip_to_next_definition` now stops at `====`, preventing narrative text after `====` from being parsed as definitions.
- **Parser: `-.` prefix operator def**: `-. a == 0 - a` in Integers.tla no longer breaks parsing.
- **Parser: RECURSIVE/LEMMA/PROOF/etc.**: These proof keywords are now skipped in the module loop.
- **Parser: tuple destructuring in set filters/maps**: `{<<a,b>> \in S : P}` and `{e : <<a,b>> \in S}` are now handled.
- **Parser: `[A]_v` stuttering action**: Properly parsed in `parse_primary`.
- **Module loader: missing modules**: EXTENDS/INSTANCE of unfoundable modules (TLAPS, community modules) now gracefully skipped.
- **PlusCal: always prefer handwritten translation**: When `\* BEGIN TRANSLATION` exists, always strip the algorithm and keep the translation.
- **Checker: cfg.init_name/next_name preference**: INIT/NEXT from config are now preferred over extract_spec_names.
- **Checker: default init/next names**: Falls back to `Init`/`Next` when no SPECIFICATION is found.
- **Probe: invariant/property violations counted as pass**: Specs designed to find violations (DieHard, etc.) now correctly count as passing.
- **IR**: `src/ir.zig` created with resolved `IrExpr` type and `Resolver` — compiles but not yet wired into eval.

### Recent fixes
- Fixed ReleaseFast-only `OutOfMemory` on CigaretteSmokers: `Checker.init` was storing a pointer to a stack-local `eval_arena`; now allocated from the main arena with stable lifetime.
- Added `Checker.deinit()` and wired it up in `main` and benchmark.
- Added assertions in `FpSet`, `Checker.successors`, and `Arena`.
- **Lazy symbolic set membership landed**:
  - Added `Value` variants `function_set_v`, `record_set_v`, `tuple_set_v`, `union_v`, `cup_v`, `cap_v`, `diff_v`.
  - `eval_binary .in`/`.notin` now tries `eval_symbolic_set()` first and falls back to materialization.
  - `Seq(S)` and user-defined `{ [1..n -> S] : n \in Domain }` / `UNION { ... }` are checked symbolically.
  - Record sets `[f1 : D1, ...]` and Cartesian products `S \times T` are also handled symbolically.
  - Fixed `MCMajority`: 5.5s → 0.04s (125× faster than before, 12.5× faster than TLC).
  - Fixed `MCFindHighest`: 5.6s → 0.013s (430× faster than before, 37.7× faster than TLC).
- **Liveness / fairness overhaul**:
  - Extract `WF_vars(A)` / `SF_vars(A)` conditions from the spec formula.
  - Compute fair SCCs using standard WF/SF rules (enabledness + angle-step checks).
  - Compute the fair region (states that can reach a fair SCC) and treat vacuous states as satisfying every LTL formula.
  - Implement fair-game `[]` and `\<\>` evaluation (safety reachability + attractor for necessity).
  - Parse and evaluate `P ~> Q` as `[](P => \<\>Q)` under fairness.
- **Parser fixes**:
  - `\<\<A\>\>_v` / `[A]_v` subscript parsing now uses `parse_primary()` so `/\` after the subscript is not swallowed.
  - `~>` (leads-to) token and AST operator added.
- **Action executor fix**: `commit_state()` no longer uses `bool_v` as an "unassigned" sentinel; it clones the parent state and then overwrites assigned variables. This fixes boolean variables being silently reset to their old values.
- **Config parser**: block-format `SPECIFICATION`, `INIT`, and `NEXT` directives are now supported; `INVARIANT`, `PROPERTY`, and `CONSTRAINT` (singular) now accept space-separated names on one line.
- **State-count reporting**: invariant-violating states are canonicalized before the invariant check, so `distinct` matches TLC's count for specs like `DieHard` and `MissionariesAndCannibals`.
- **SCC panic**: replaced recursive Tarjan with iterative version and filter stale `maxInt` edges before liveness checking.
- **Parser / lexer fixes**:
  - Infix operator definitions (`a + b == ...`, `_ \cup _ == ...`, custom operators like `\sqsubseteq`) now parse correctly.
  - `LOCAL INSTANCE M` and `LOCAL Op == ...` are handled.
  - Recursive function definitions `F[x \in S] == ...` are parsed and evaluated via closures.
  - Multi-variable set comprehensions `{ e : x \in S, y \in T }` and `{ x \in S, y \in T : P }` are supported.
  - `in` is accepted as an identifier in variable/constant/definition contexts.
- **Symbolic range sets (`range_v`)**:
  - `a .. b` is now represented as a lazy `range_v` instead of a materialized integer set.
  - Record-set and function-set membership use the symbolic range, eliminating the `CoffeeCan` bottleneck.
  - `CoffeeCan`: 2.49s → 0.09s, now **8.4× faster than TLC**.
  - Materialization is performed on demand for quantifiers, function literals, set operations, and action enumeration.
- **User-defined infix operators in expressions**: parsed via `read_infix_operator_name_for_expr()` with layout guards (column > 1 and > current definition column) to avoid swallowing the next definition name.
- **Prefix `~` precedence**: moved from `parse_not` to `parse_unary` so `x = ~y` parses correctly; bulleted-list operand `~ /\ A /\ B` still supported.
- **LET definitions**: now build lambda closures for parameterized definitions and recursive-function closures for `F[x \in S] == ...` inside `LET`.
- **Proof/step labels**: `P0:: expr` is parsed as a no-op prefix.
- **PlusCal translator**: fixed `@memcpy` length mismatch when replacing an existing translation block.
- **Value equality**: `Value.eql()` now returns `false` for cross-tag comparisons instead of panicking (e.g. `string_v` vs `model_v`).

### Active work
- [~] Expand benchmark suite to at least 50% of specifiable examples (currently 15 in benchmark, 50/226 probed at max_states=10000).
- [x] Investigate remaining slowdown on `CoffeeCan` (0.09s vs TLC 0.78s — fixed).
- [x] Fix SCC index-out-of-bounds panic on `SyncTerminationDetection`.

### Next steps (IMMEDIATE)
1. **Build a resolved IR** (see Phase 5 below) — replace runtime string lookups with pre-linked pointers. This is the single highest-value architectural change: fixes UndefinedSymbol/TypeError at load time, eliminates O(n) string comparisons in the hot path, makes the checker usable as a library without restarts.
2. Fix remaining parser gaps (SimpleRegular stops parsing after Init — investigate).
3. Add more assertions throughout hot paths (state store, eval, action compiler, queue).
4. Implement Init-as-predicate enumeration (StateSpaceExhausted bucket, 12 specs).
5. Add remaining standard-module overrides (`SelectSeq`, `SortSeq`, `Bags`, etc.).
6. Complete PlusCal translator for `if`/`either`/`while`/`with`/`await`/`assert`/`print`/`skip`/assignments.

## Phase 2b — Scale to 50% of all specs

- [x] Implement `INSTANCE M WITH ...` substitutions (highest unlock rate).
- [x] Implement `LAMBDA`/higher-order operators and `CHOOSE` predicates (basic).
- [x] Parse `WF_vars(A)` / `SF_vars(A)` fairness syntax and `[]`/`\<\>` temporal operators.
- [x] Implement lazy symbolic set membership (critical for `Seq`-based specs).
- [ ] Add remaining standard-module overrides (`SelectSeq`, `SortSeq`, `Bags`, etc.).
- [x] Support config substitutions (`<-`) and multi-line `CONSTANTS` blocks.
- [~] Keep harness green and update pass count after each unlock.
- [x] Parse infix operator definitions and recursive function definitions.
- [x] Symbolic range sets (`a..b`) to avoid materializing large integer sets.
- [x] Custom infix operators in expression parsing (e.g. `\prec`, `\sqsubseteq`).
- [~] Add remaining standard-module overrides (`SelectSeq`, `SortSeq`, `Bags`, etc.).
- [ ] Complete PlusCal translator for `if`/`either`/`while`/`with`/`await`/`assert`/`print`/`skip`/assignments.

## Phase 3 — Performance
- [~] Profile on medium specs
- [~] Multi-threaded worker pool
- [ ] Lock-free / sharded FPSet
- [ ] Compressed state queue
- [ ] Disk FPSet spill
- [~] Benchmark suite

### Performance correctness gates

- [x] Benchmark `ewd840/EWD840` and `ewd998/AsyncTerminationDetection`
  against Java TLC with exact state-count validation.
  - EWD840: tlzig `1817/302`; TLC `2001/302`.
  - AsyncTerminationDetection: tlzig and TLC both `53271/4097`.
- [x] Measure ReleaseFast single-thread baseline for EWD998:
  - Historical tlzig baseline: 3.15s, approximately 2.48GB peak RSS.
  - Current tlzig: 0.38s, approximately 17MB peak RSS.
  - Current TLC `-workers 1`: 0.68s, approximately 370MB peak RSS.
- [x] EWD998 four-mode benchmark matrix with exact counts:
  - TLC `-workers 1`: 0.68s, approximately 370MB.
  - TLC `-workers auto` (16 workers): 0.55s, approximately 356MB.
  - tlzig `--workers 1`: 0.38s, approximately 17MB.
  - tlzig `--workers 4`: 0.30s, approximately 19MB.
- [~] Benchmark matrix for every performance claim:
  - TLC `-workers 1`.
  - TLC `-workers auto`.
  - tlzig `--workers 1`.
  - tlzig `--workers auto`.
  - Exact generated/distinct counts must match before comparing time.

### Immediate memory/runtime repair

- [x] Stop committing duplicate successors to the permanent state value pool.
  - Generate successors in a resettable candidate pool.
  - Fingerprint and check constraints before permanent cloning.
  - Clone only newly canonical states into `StateStore.values_pool`.
  - Reset the candidate pool after each expanded parent state.
- [x] Re-benchmark EWD998 after candidate-state canonicalization:
  - Exact count preserved: `53271/4097`.
  - ReleaseFast runtime: 3.15s -> 1.03s.
  - Peak RSS: approximately 2.48GB -> approximately 17MB.
  - TLC `-workers 1`: 0.70s, approximately 318MB.
  - TLC `-workers auto` (16 workers): 0.62s, approximately 324MB.
- [x] Restore the single-thread evaluator to a stable post-initialization
  snapshot before and after every expanded state.
  - The old code restored a snapshot taken immediately before each restore,
    which was a no-op and leaked temporary values across the entire search.
  - Live MCDistributedReplicatedLog RSS dropped from over 4GB in the stale
    probe process to hundreds of MB after rebuilding with the fix.
- [x] Replace parallel worker busy-waiting with condition-variable blocking.
  - EWD998 `--workers auto`: 1.01s wall, 0.37s system CPU.
  - The previous spin/yield loop used 8.37s system CPU for the same result.
- [ ] Replace `max_states * 256` eager value-pool sizing with measured,
  bounded initial capacities and geometric growth telemetry.
- [ ] Replace the fixed `max_states * 32` successor edge allocation with
  chunked graph storage sized from observed outdegree.
- [~] Remove runtime `std.ArrayList(page_allocator)` from evaluator/action hot
  paths; use bounded stack buffers or arena-owned reusable buffers.
  - [x] Replace the successor-state `ArrayList` with an arena-owned
    fixed-capacity `StateBuffer`.
  - [x] Remove page-allocator lists from quantifier and set-map evaluation.
  - [ ] Audit and remove the remaining evaluator/action hot-path lists.
- [ ] Replace the relocatable canonical `ValuePool` with segmented,
  non-relocating storage. Parallel readers currently require growth to be
  disabled; the TLC test-model EWD998 configuration reaches the fixed
  8-million-value cap at `340025/68965`.
- [x] Make parallel error cleanup single-owner:
  - Never join a thread handle twice while propagating a worker failure.
  - Never deinitialize worker arenas through both partial-init and normal
    cleanup paths.
  - The large EWD998 test model now returns `error.OutOfMemory` normally
    instead of crashing in ReleaseFast.
- [ ] Add `--stats` output for permanent values, candidate values, strings,
  graph edges, generated states, duplicate states, and arena high-water marks.
- [ ] Add assertions that candidate-pool values never escape into canonical
  state storage and that canonical values never reference resettable pools.

### Multi-threading prerequisites

- [x] Add CLI `--workers 1|auto|N`; keep `1` as the correctness baseline.
- [x] Give each worker a private evaluator, candidate arena, candidate
  `ValuePool`, action executor, and successor buffer.
- [x] Share immutable AST/compiled actions and canonical states.
- [x] Synchronize canonical-state insertion, queue publication, trace
  predecessor assignment, counters, and transition graph updates.
- [ ] Shard the fingerprint set before scaling worker count; do not serialize
  all workers behind one global FPSet lock.
- [x] Preserve temporal-property graph completeness and exact state counts
  under parallel exploration.
  - EWD998 Async, 4 workers: `53271/4097`, identical to TLC and worker 1.
  - YoYoPruning, 4 workers: `157/102`, identical to TLC and tlzig worker 1.
  - MCBinarySearch, worker 1 and auto: `34383/27953`, identical to TLC.

### MCBinarySearch performance gate

- [x] Run MCBinarySearch individually before the next full probe.
  - TLC worker 1: 1.78s, approximately 774MB RSS.
  - tlzig worker 1: 10.27s, approximately 814MB RSS.
  - tlzig auto: 10.47s, approximately 819MB RSS.
- [x] Profile the tlzig run with macOS `sample`.
  - The dominant cost was repeated construction of `SortedSeqs` while
    checking invariants.
  - Removed quadratic `make_set` deduplication from the sorted-sequence
    generator because its lexicographic generation is already unique.
- [x] Add allocation-free hash prefiltering to generic set canonicalization
  for sets up to 4,096 elements; structural equality is only checked when
  fingerprints match.
  - MCBinarySearch worker 1 improved from 10.27s to 8.07s with exact counts.
- [ ] Cache state-independent zero-argument definitions in canonical storage,
  or represent filtered sequence sets symbolically, so `SortedSeqs` is not
  regenerated for every invariant and state.
- [ ] Avoid allocating worker contexts when BFS levels expose no useful
  parallelism; MCBinarySearch has maximum outdegree 1 and gains nothing from
  `--workers auto`.

### Temporal-property performance

- [x] Build predecessor CSR (`pred_offsets`/`pred_edges`) with the SCC graph.
- [x] Evaluate universal box properties with one reverse reachability pass
  instead of a graph traversal from every state.
- [x] Evaluate universal diamond properties over predecessor edges.
- [x] Preserve exact EWD998 liveness results after the algorithm change.

### MCCRDT performance gate

- [x] Match Java TLC exactly: `1350001/25000`.
- [x] Remove page-allocator traffic from quantifier and set-map hot paths.
- [x] Improve tlzig auto from 52.12s to 11.63s.
- [ ] Beat TLC's approximately 9s runtime.
- [ ] Shard canonical-state insertion; the global canonicalization mutex is
  now the primary parallel bottleneck.

### TigerBeetle-style engineering gates

- [x] Prioritize safety, then performance, then developer experience.
- [x] Add explicit bounds and assertions around state indices, pool counts,
  queue publication, graph edges, worker ownership, and candidate lifetimes.
- [x] Keep exploration hot paths allocation-free where converted; allocate
  worker scratch storage before exploration.
- [~] Eliminate all runtime dynamic allocation after initialization.
- [~] Maintain performance sketches and exact TLC/tlzig benchmark matrices.
- [x] Keep `zig fmt --check` and `git diff --check` clean.

### EWD687a correctness/performance gate

- [x] Keep `ACTION_CONSTRAINT(S)` separate from state `CONSTRAINT(S)`.
  - Action constraints filter transitions and never filter initial states.
- [x] Evaluate primed parameterized operators against a partial next state
  assembled from the parent state and primed assignments accumulated so far.
- [x] Validate MCEWD687a in both engines.
  - TLC worker 1: `177171/18028`, 17.97s, approximately 796MB RSS.
  - tlzig worker 1: `175873/18028`, 24.53s, approximately 100MB RSS.
  - tlzig auto: `175873/18028`, 21.99s, approximately 103MB RSS.
  - Distinct state count is exact; generated-state accounting still differs.

### Probe-driven semantic fixes

- [x] Implement `DOMAIN` for records as the set of record field-name strings.
  - `SpecifyingSystems/AdvancedExamples/MCInnerSerial` now completes:
    `11136/972`.
- [x] Evaluate `UNCHANGED (expression)` across parent and next states.
  - Fixed `glowingRaccoon/clean`: Java TLC and tlzig both `99/63`.
  - Fixed boxed-action stuttering checks that previously compared the parent
    state to itself instead of comparing parent to child.
- [x] Keep `ENABLED` and temporal operands lazy in ordinary expression
  evaluation; action operands must not be evaluated without a next state.
  - CoffeeCan remains exact at `20002/5150` generated/distinct and the
    benchmark reports 0.530s tlzig worker 1 versus 0.795s TLC worker 1.
- [x] Prime arbitrary `INSTANCE ... WITH` substitution expressions.
  - `dna <- sumList(doubles)` now rewrites `dna'` as a next-state expression.
  - Fixed `glowingRaccoon/product`: Java TLC and tlzig both `376/305`.
- [x] Verify bounded no-witness `CHOOSE` against Java TLC.
  - TLC raises an evaluation error; tlzig intentionally retains
    `error.EmptyChoose` for compatibility.
- [x] Add resumable full-probe support with `START_AFTER` and `RESULT_FILE`.

## Phase 4 — Advanced TLA+
- [x] Liveness checking (`[]`/`<>/`leads-to with weak/strong fairness and stuttering)
- [ ] Symmetry reduction
- [x] Model values / constants
- [ ] TLC-compatible trace output

## Phase 5 — Resolved IR (Symbol Resolution Layer)

**Goal**: Parse → AST (strings) → Resolve → IR (indices/pointers) → Evaluate (fast, zero string lookups).

**Why**: Currently every `ident` node is a raw `[]const u8`. Every evaluation step does O(n) string comparisons to resolve the name against variables, constants, definitions, context, overrides. This is slow and also the root cause of many `UndefinedSymbol`/`TypeError` failures that should be caught at load time.

### Design
- [ ] Create `src/ir.zig` with a resolved expression type `IrExpr`.
  - `ident` → tagged union: `.var(u16)`, `.const_val(u16)`, `.def_ref(*IrDef)`, `.builtin(enum)`, `.ctx_local(u16)`
  - `primed` → `.primed_var(u16)` (pre-resolved to variable index)
  - `apply` → pre-resolved: `.call(*IrDef, []IrExpr)` or `.builtin_call(op, []IrExpr)` or `.lambda_call(*IrLambda, []IrExpr)`
  - All other nodes mirror AST but with resolved children.
- [ ] Create `src/resolver.zig` — walks AST, builds IR.
  - Maintains a scope stack: global defs → let bindings → quantifier bindings → lambda params.
  - Resolves every name to its target at compile time.
  - Reports `UndefinedSymbol` with file/line/col at load time (not during model checking).
  - Inline constant values.
  - Resolve operator references (`+` etc.) to builtin enum.
- [ ] Refactor `eval.zig` to evaluate `IrExpr` instead of `ast.Expr`.
  - No string comparisons in the hot path.
  - `Context` becomes a flat array indexed by u16 instead of string-keyed.
- [ ] Refactor `action.zig` to compile `IrExpr`.
- [ ] Refactor `checker.zig` to use IR for invariants/properties/temporal.
- [ ] Delete all runtime `find_definition` / `find_variable` / `find_constant` / `resolve_alias` string lookups.
- [ ] Add assertions: every `IrExpr` is fully resolved (no dangling names).

### Implementation order
1. Define `IrExpr` and `IrDef` types.
2. Build resolver for simple expressions (literals, idents, binary, unary).
3. Wire evaluator to accept `IrExpr` — coexist with AST eval during migration.
4. Resolve function applications and higher-order operators.
5. Resolve quantifiers and CHOOSE.
6. Resolve LET-IN and lambdas.
7. Resolve temporal operators and box actions.
8. Remove AST eval path entirely.

## Phase 6 — AOT Zig model generation

**Goal**: `tlzig --emit-zig model.zig` lowers the parsed TLA+ module into
allocation-free Zig operator overrides, and
`zig build -Dgenerated-model=model.zig` links them into the checker.

- [x] Add the `--emit-zig` CLI entry point using tlzig's existing parser and
  loaded module graph.
- [x] Make AOT emission strict: unsupported reachable definitions prevent
  output and are listed by name. There is no fallback-generation escape hatch.
- [x] Add a generated-operator ABI sharing tlzig's `Value`, `ValuePool`, and
  current/next state representations.
- [x] Compile generated modules independently and link them through
  `-Dgenerated-model`.
- [x] Preserve native TLC override precedence; generated definitions may not
  replace `Print`, `TLCSet`, standard-module overrides, or other special
  semantics.
- [x] Treat `TLCEval` as an intrinsic rather than compiling its apparent
  identity body; it controls evaluation/memoization and is not semantically
  interchangeable with an ordinary eager function.
- [x] Use stable definition indices for Zig symbols and escape arbitrary TLA+
  operator names in metadata.
- [x] Lower literals, configured-constant reads, current/primed variables,
  scalar arithmetic and logic, structural equality/order, conditionals,
  record-field reads, function/sequence lookup, and generated calls.
- [x] Omit unsupported operators from generated registries and reject the
  generated model before writing or linking it.
- [x] Differentially validate the initial ClientCentric generated build:
  interpreted and generated both report `2044/801`.
- [x] Differentially validate RC/snapshot after excluding primed partial-state
  operators and TLC intrinsics: interpreted and generated both report
  `245844/84692` in the current checkout.
- [x] Extend the generated action ABI with partial next-state assignments and
  lower primed parameterized operators.
- [x] Lower finite sets, ranges, membership, tuples, records, and set
  operations without hot-path heap allocation.
  - Set/tuple/record literals, ranges, membership, subset checks, equivalence,
    and integer power now use only `ValuePool` bump allocation.
  - Union/intersection/difference materialize into resettable scratch storage;
    power/function/record sets retain compact symbolic representations.
  - `UNION`, bounded function sets, filters/maps, and record sets are
    materialized without general-purpose runtime allocation.
- [x] Allow generated operators to call existing native Zig overrides through
  the generated call context without returning to AST evaluation.
- [x] Enforce `fallback_count == 0` at generated-model link time.
- [x] ClientCentric strict coverage: `67 generated / 0 native /
  0 unsupported` for the selected config.
- [x] Lower bounded quantifiers, filters, maps, CHOOSE, function literals,
  `EXCEPT`, `@`, `SelectSeq`, `ReduceSeq`, and action predicates using fixed
  worker scratch storage.
- [ ] Generate direct entry points for INIT, NEXT actions, constraints,
  invariants, and temporal-state/action predicates instead of routing their
  zero-argument definitions through generic AST evaluation.
- [ ] Resolve constants and definitions to generated indices so generated hot
  paths contain no runtime name scans.
- [ ] Add differential tests comparing every generated operator against the
  interpreter over representative values and states.
- [x] Link optional generated models into the ReleaseFast benchmark with
  module/config identity checks; print TLC and tlzig counts separately.
- [ ] Beat the interpreter and TLC Java on representative single-core and
  all-core MultiShardTxn full runs before enabling AOT generation by default.

## Notes
- Update this file after every spec/example milestone.
- Record Java TLC command and timing in the spec row.
- Record tlzig command and timing in the spec row.
