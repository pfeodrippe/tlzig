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
- [x] Remove string-named generated dispatch for `Cardinality`, sequence
  operators, `Range`, permutations, `INTERSECTION`, `\o`, `@@`, and `:>`.
  Stored generated models now contain zero `runtime.native` or
  `runtime.native_binary` calls.
- [x] Emit deterministic, `zig fmt`-formatted native files under
  `generated_models/`, with the original TLA+ path, line, operator signature,
  and declaration attached to every generated operator.
- [x] Resolve action assignments and `UNCHANGED` to numeric variable slots at
  compile time. State commits and generated-call partial bindings no longer
  scan variable names in the hot path.
- [x] Separate canonical-state capacity from temporary successor capacity.
  `--max-successors` defaults to 65,536, eliminating the duplicate
  `max_states`-sized candidate store for each worker.
- [x] Omit transition-graph storage for invariant-only configurations.
  Liveness edges previously reserved `max_states * 32` entries even when no
  temporal property was configured.
- [x] Keep exhaustive canonical value pools stable and contiguous. The current
  offset representation cannot relocate safely under macOS memory pressure;
  large runs pre-size 60 values per state (up to 132 million), disable
  canonical pool growth, and return a precise `OutOfMemory` instead of
  triggering a multi-gigabyte relocation copy.
- [x] Fix arena oversized-allocation growth: dedicated large chunks no longer
  poison the ordinary growth increment and force a second multi-gigabyte
  chunk on the next allocation.
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
  - [x] Resolve assignment/`UNCHANGED` variable slots and execute deterministic
    step chains iteratively.
  - [x] Move parallel candidate constraints, symmetry hashing, and invariants
    outside the canonical-store mutex. Exhaustive auto improved from
    `100.33s` to `33.14s`; removing safety-only BFS barriers reached `32.54s`.
  - [x] Export generated action-expression entry points keyed to resolved
    action IR, including lexical parameters/bound variables, then make guards,
    assignment RHS expressions, domains, and branch conditions call native
    Zig. Full rc-local exhaustive improved from `358.17s/32.54s` to
    `266.78s/25.90s`.
- [ ] Re-run exhaustive `CHECK_DEADLOCK FALSE` differential models before
  treating deadlock-stop generated/distinct counts as coverage totals.
  Default MultiShardTxn configs stop at the first valid deadlock, and worker
  scheduling/enumeration order changes those partial counts.
  - [x] TLC one-core, symmetry enabled, rc-local:
    `12,467,888` generated / `2,132,765` distinct, depth 35, `357.02s`,
    8.03 GB peak RSS.
  - [x] tlzig one-core, symmetry enabled, rc-local:
    `12,320,318` generated / `2,132,765` distinct, normal completion,
    `266.78s`, 2.23 GB peak RSS. Distinct states match exactly; tlzig is
    1.34x faster and uses 72% less peak memory than TLC.
  - [x] Complete matching TLC/tlzig all-core exhaustive runs with identical
    `2,132,765` distinct states and normal completion:
    TLC `30.14s` / 6.55 GB; tlzig `25.90s` / 2.25 GB.
  - [x] Close both exhaustive speed gaps with generated action-expression
    entry points: one-core is 1.34x faster and all-core is 1.16x faster.
- [~] Current strict AOT full-run performance snapshot (2026-06-27,
  exact-label benchmark filter, generated models with `fallbacks=0` and no
  `runtime.native` calls):
  - ClientCentric: TLC `2.265s/2.398s`, tlzig `1.150s/1.137s`,
    distinct `801/801`.
  - MCM snapshot invariant/deadlock-stop: TLC `2.212s/1.744s`,
    tlzig `0.702s/0.096s`; both stop before exhaustive completion, so
    generated/distinct totals are traversal-order diagnostics only.
  - MCM rc-local invariant/deadlock-stop: TLC `1.299s/1.440s`,
    tlzig `0.140s/0.053s`; both stop before exhaustive completion.
  - Storage: TLC `2.776s/1.444s`, tlzig `1.436s/0.220s`,
    distinct `13370/13370`.
  - RC no-prepare-block deadlock-stop: TLC `1.966s/1.843s`,
    tlzig `0.696s/0.085s`; both reach TLC-compatible deadlock.
  - RC no-prepare-block-or-ww deadlock-stop: TLC `1.900s/1.604s`,
    tlzig `0.701s/0.107s`; both reach TLC-compatible deadlock.
  - RC snapshot deadlock-stop: TLC `5.194s/2.401s`,
    tlzig `4.918s/0.313s`; both stop before exhaustive completion.
  - RC with-prepare-block deadlock-stop: TLC `1.878s/1.574s`,
    tlzig `0.691s/0.101s`; both reach TLC-compatible deadlock.
  All measured MultiShardTxn rows are faster in tlzig-auto. The next blocker
  is exhaustive `CHECK_DEADLOCK FALSE` variants for every deadlock-stop row,
  because partial generated/distinct totals are not valid coverage totals.
- [~] Current strict AOT exhaustive no-prepare-block baseline (2026-06-28,
  ReleaseFast, exact-label benchmark filter, generated model
  `generated_models/mdbtla_rc_no_prepare_block_exhaustive.zig`, fallbacks
  `0`):
  - Full `MultiShardTxn RC/no-prepare-block exhaustive`, all cores:
    TLC-auto `172.109s` to `174.157s`; tlzig-auto improved from `221.550s`
    to `202.501s`/`202.590s`. Distinct states match exactly at
    `17,057,584`; generated counts remain traversal-order diagnostics
    (`99,713,354` TLC vs `98,533,426` tlzig).
  - Capped 3M-state ReleaseFast tlzig baseline improved from `30.53s` /
    `5.196T` retired instructions to best observed `28.84s` / `5.103T`
    after terminal `UNCHANGED` clone bypass and single-pass commit assignment
    collection. This is real progress but still not enough to beat TLC on the
    full row.
  - Rejected experiments: bool-returning constant quantifier predicates,
    no-clone boolean `variable_path(...)`, no-op terminal `UNCHANGED` binding
    skip, and pointer-switching `ActionStep` all failed wall-time validation
    despite some instruction-count reductions.
- [x] Make config constant substitutions native in generated code. Applications
  such as `AbortTransaction(n, tid)` with `AbortTransaction <- FALSE` now emit
  the configured constant directly and do not evaluate arguments or fall back
  through generic runtime calls.
- [x] Make generated-expression identity traversal match generation traversal
  for native calls and constant substitutions. This keeps strict action
  expression lookup stable after `runtime.native` removal.
- [x] Make benchmark label filtering exact while retaining path substring
  filters, so `MultiShardTxn RC/no-prepare-block` no longer also runs
  `MultiShardTxn RC/no-prepare-block-or-ww`.
- [x] Fix default benchmark temporal parity for `MCChangRoberts` and
  `SpanTree`:
  - expand simple finite universal fairness clauses such as
    `\A self \in Node : WF_vars(node(self))` into context-bound fairness
    conditions;
  - evaluate temporal `ENABLED A` compositionally by replaying action `A`
    against stored successor edges, instead of using raw successor count.

### MDBTLA / SingleLog MCMDBProps integration (2026-06-27)
- [x] Validate the full Java TLC baseline for
  `vendor/MDBTLA/SingleLog/MCMDBProps.tla`:
  `3,101,918` generated / `269,881` distinct, depth 11, no errors,
  `26m46s` wall time including temporal-property checking.
- [x] Fix parser support needed by `MDBProps.tla`:
  parenthesized symbolic bag operators `(+)/(-)`, `\lnot`, and bulleted
  RHS bodies after `=>` / `~>`.
- [x] Generate strict AOT for `MCMDBProps.cfg` with zero fallbacks:
  `41` generated operators, `3` direct native bag operators.
- [x] Fix action-local parameterized `LET` operators such as
  `modHistory(initState)` by inlining local action calls before step
  collection, so primed assignments inside local operators become real
  `ActionStep` assignments instead of boolean-only conditions.
- [x] Fix bag semantics used by SingleLog write histories:
  `bag (+) SetToBag({record})` and `bag (-) ...` now accept `<<>>` as the
  empty bag/function, and both generic and generated paths use structural
  cross-pool equality for record-valued bag keys.
- [x] Record the corrected capped performance baseline for
  `MCMDBProps --max-states 1000` in ReleaseFast:
  generic tlzig `0.19s` / `515.7M` retired instructions / `8.8 MB` RSS,
  strict AOT tlzig `0.16s` / `215.5M` retired instructions / `8.5 MB` RSS,
  both `2,416` generated / `1,000` distinct. Wall time is too small/noisy
  for a strong ratio at this cap; instruction count improves `2.39x`.
- [x] Remove the O(SCC²) temporal condensation matrix. The full
  `MCMDBProps` temporal run previously crashed around 4.7 GB RSS while
  allocating `scc_count * scc_count` booleans. SCC successor deduplication now
  stores packed `u64` edge keys, sorts, and uniquifies in O(edges) memory.
- [x] Run strict AOT `MCMDBProps` without the small cap and compare against
  TLC's full result, including temporal-property checking:
  TLC Java `26m46s`, `3,101,918` generated / `269,881` distinct;
  tlzig strict AOT ReleaseFast `258.99s`, same `3,101,918/269,881`,
  `578.7 MB` peak RSS. Full-run speedup is `6.2x`.
- [x] Add `MCMDBProps` as an opt-in long ReleaseFast benchmark row only. It is
  excluded from the default benchmark because the TLC side is a 26-minute full
  temporal run. Use exact filter `-Dbenchmark-filter='SingleLog MCMDBProps'`
  or `-Dbenchmark-include-long=true` to include it.
- [x] Raise benchmark value-pool budgets for RC deadlock-stop rows to avoid
  flaky `OutOfMemory` in representative generated runs.
- [x] Add explicit exhaustive `CHECK_DEADLOCK FALSE` benchmark configs for the
  four MDBTLA RC model configs under `benchmark_configs/MDBTLA/...`, keeping
  the vendored upstream cfg files unchanged.
- [x] Add long/exhaustive benchmark rows as opt-in cases. The default
  ReleaseFast benchmark skips these rows, and one-core heavy runs are disabled
  unless `--include-one-core` is passed.
- [ ] Add a separate batched one-core throughput mode, e.g.
  `--one-core-batch N`, for running independent one-worker TLC/tlzig jobs in
  parallel when machine cores and memory allow it. Keep this separate from the
  isolated one-core latency comparison because concurrent jobs contend for CPU
  cache, memory bandwidth, and Java heap/GC.
- [x] Add first-class strict-generated representative benchmark executables to
  `zig build -Doptimize=ReleaseFast benchmark`. The current benchmark binary
  can link at most one `-Dgenerated-model`; default MDBTLA rows therefore
  measure the generic checker unless the whole build is invoked with a single
  generated model. Add separate build steps for key generated models such as
  `mdbtla_storage.zig` and `mdbtla_rc_no_prepare_block.zig`, keep long
  one-core exhaustive rows opt-in, and print them as explicit AOT rows.
  - Implemented generated benchmark executables for all eight upstream-valid
    MultiShardTxn generated models, chained after the generic benchmark and
    filtered by exact label/path just like the benchmark script.
  - Filtered verification for Storage: generic tlzig `3.886s/0.355s`; strict
    AOT tlzig `1.417s/0.157s`; TLC `2.777s/1.468s`.
  - Filtered verification after exact-label/long-row tightening:
    Storage generic tlzig `3.973s/0.356s`; strict AOT tlzig
    `1.449s/0.285s`; TLC `2.852s/1.432s`. Storage AOT is `1.97x` faster than
    TLC one-core and `5.02x` faster than TLC auto in this run.
  - Filtered verification after exact-label/long-row tightening:
    RC/snapshot generic tlzig `7.840s/0.756s`; strict AOT tlzig
    `4.983s/0.418s`; TLC `5.141s/2.326s`. RC/snapshot AOT is `1.03x` faster
    than TLC one-core and `5.56x` faster than TLC auto in this run.
  - Filtered verification for RC/no-prepare-block before filter tightening:
    strict AOT tlzig `0.698s/0.096s`; TLC `1.883s/1.580s`.
  - Full default verification after adding all eight MultiShardTxn AOT rows:
    - ClientCentric: TLC `2.195s/2.356s`, AOT tlzig `1.152s/1.123s`.
    - MCM snapshot-invariant: TLC `2.144s/1.768s`, AOT tlzig
      `0.687s/0.111s`.
    - MCM rc-local-invariant: TLC `1.256s/1.433s`, AOT tlzig
      `0.154s/0.053s`.
    - Storage: TLC `2.773s/1.429s`, AOT tlzig `1.415s/0.161s`.
    - RC/no-prepare-block: TLC `1.872s/1.761s`, AOT tlzig
      `0.693s/0.093s`.
    - RC/no-prepare-block-or-ww: TLC `1.873s/1.632s`, AOT tlzig
      `0.720s/0.103s`.
    - RC/snapshot: TLC `5.223s/2.351s`, AOT tlzig `4.965s/0.465s`.
    - RC/with-prepare-block: TLC `1.816s/1.598s`, AOT tlzig
      `0.703s/0.104s`.
    All eight strict AOT rows are faster than TLC in both one-core and auto
    mode in this run. Deadlock-stop generated/distinct totals remain
    traversal-order diagnostics where `compare_generated/compare_distinct`
    are disabled; exhaustive `CHECK_DEADLOCK FALSE` rows remain opt-in.
  - Generic tlzig to strict AOT tlzig speedups in the same full run:
    - ClientCentric: generic `2.334s/2.320s` -> AOT `1.152s/1.123s`,
      `2.03x/2.07x`.
    - MCM snapshot-invariant: generic `1.240s/0.303s` -> AOT
      `0.687s/0.111s`, `1.80x/2.73x`.
    - MCM rc-local-invariant: generic `0.222s/0.093s` -> AOT
      `0.154s/0.053s`, `1.44x/1.75x`.
    - Storage: generic `3.932s/0.465s` -> AOT `1.415s/0.161s`,
      `2.78x/2.89x`.
    - RC/no-prepare-block: generic `1.084s/0.167s` -> AOT
      `0.693s/0.093s`, `1.56x/1.80x`.
    - RC/no-prepare-block-or-ww: generic `1.092s/0.163s` -> AOT
      `0.720s/0.103s`, `1.52x/1.58x`.
    - RC/snapshot: generic `7.734s/0.595s` -> AOT `4.965s/0.465s`,
      `1.56x/1.28x`.
    - RC/with-prepare-block: generic `1.074s/0.158s` -> AOT
      `0.703s/0.104s`, `1.53x/1.52x`.
  - Generated benchmark rows now print with ` [AOT]` label suffix so generic
    and strict native rows are not visually conflated.
- [ ] Complete full TLC/tlzig all-core comparisons for the new RC exhaustive
  rows. The no-prepare-block exhaustive run exceeded the old 3M state cap, and
  a 10M one-core probe was intentionally stopped after it remained CPU-bound
  for over ten minutes; do not put that path back into the default benchmark.
- [x] Add `scripts/audit_generated_patterns.py` to keep generated-code
  performance debt measurable. Current audit scans `generated_models/*.zig`
  and reports representative source lines for helper-heavy native code.
- [x] Tighten generated-model activation with a deterministic config
  replacement fingerprint. Generated registries now match module, configured
  roots, and config operator/constant replacements before activation; sibling
  MDBTLA cfgs with the same roots can no longer accidentally reuse the wrong
  native model.
- [x] Specialize generated `Permutations(A) \cup ... \cup Permutations(N)`
  trees into `runtime.permutations_union(...)`, eliminating nested generic
  permutation set construction. Audit count for `permutations_union_chain`
  is now `0`.
- [x] Batch generated root-variable `UNCHANGED` checks with
  `runtime.unchanged_variables(...)`. Audit count for individual
  `unchanged_variable` calls dropped from `6354` to `891`.
- [x] Specialize boolean guards over `Head(variable_path(...)).field` and
  `variable_path(...).field`, including equality, membership, and direct bool
  field tests. The concrete `Head(shardTxnReqs[s][tid]).op = "coordCommit"`,
  `Head(...).op \in {"read", "write"}`, `Head(...).start`, and
  `coordInfo[s][tid].self` patterns now emit direct cross-pool helpers.
- [x] Specialize direct state-path membership guards such as
  `tid \in participants[s]` into `variable_path_member_bool(...)`, avoiding
  cloned path values for hot action guards.
- [x] Fuse simple generated action-assignment checks of the form
  `v' = [v EXCEPT ![path] = rhs]` into
  `primed_variable_except_update_equal_bool(...)`. The runtime compares the
  next root with the current root across pools, calls the EXCEPT updater only
  at the changed leaf, and avoids reconstructing the whole updated root.
- [x] Honor config operator replacements before direct native lowering in
  generated calls. `Seq <- LimitedSeq` no longer emits unbounded
  `runtime.sequence_set(...)` for MCBinarySearch; the replacement target is
  also marked reachable so strict generated files link all referenced
  operators.
- [x] Add per-evaluator generated caches for zero-argument context-free
  operators. Cached values live in a generated-cache pool, not the canonical
  state pool, so large constant expressions can be reused without consuming
  canonical-state capacity.
- [ ] Replace generic generated action assignments:
  `primed_variable = except_update(variable, path, rhs)` should lower to
  native typed/path-indexed next-state writes, not whole-root reconstruction.
  Current audit after the fused simple-EXCEPT path:
  `except_update=2673`, `primed_variable_full_compare=284`. Remaining sites
  are mostly nested EXCEPT chains and value-producing EXCEPT expressions.
- [ ] Replace generated `variable_path(...)` reads with typed/indexed accessors
  derived from resolved state layout and TypeOK where available. Current audit:
  `variable_path=8068`.
- [ ] Fuse sequence-head record-field guards such as
  `field(sequence_head(variable_path(...)), "op")` into direct helpers that
  read once and compare typed fields. Current audit:
  `field_sequence_head=357`; the remaining cases are mostly value-producing
  field reads passed into records/operators, not simple boolean guards.
- [ ] Specialize mapped-set/range construction used in hot MDBTLA actions,
  especially `map_set(function_range(variable_path(...)), ...)`. Current
  audit: `map_set=287`, `function_range=395`.
- [ ] Add an explicit statistical benchmark mode for performance-sensitive
  rows. It should run ReleaseFast specs repeatedly under an opt-in flag, record
  wall/user/sys/RSS/instructions when the platform exposes them, and report
  min/median/p95/stddev plus confidence intervals. Keep the default benchmark
  single-pass/fast; use the statistical mode for noisy all-core runs and delay
  distribution measurements.
- [ ] Add tlzig-only meta properties over runs/traces as TLA+-style extension
  properties, explicitly separated from Java TLC-compatible semantics. They
  should look and be configured like normal invariants/temporal properties, but
  their operators quantify over run/trace ensembles, e.g. “at least one
  explored path reaches event/label X”, “some run includes an allow
  transition”, “p99 delay across statistical runs stays below a threshold”, or
  “coverage of action classes is nonzero”. Java TLC will not support these
  extension operators; tlzig output must label them separately from standard
  TLC parity.
- [x] For the strict generated MDBTLA
  `MCMultiShardTxn_RC_no_prepare_block_exhaustive` model, lower common
  value-producing path helpers instead of only boolean comparisons:
  `Len(variable_path(...))`, `Head(variable_path(...)).field`,
  `variable_path(...).field`, `Range(variable_path(...))`, and
  `DOMAIN variable_path(...)`. The model still has `fallbacks=0`; current
  one-file audit after regeneration is `variable_path=523`,
  `function_range=11`, `field_sequence_head=0`, `nested_runtime_call=896`.
  Capped 3M ReleaseFast best improved from the previous `28.84s`/`5.103T`
  accepted baseline to `28.59s`/`4.830T` instructions.
  Full ReleaseFast exact benchmark row is still slower than TLC:
  TLC-auto `177.440s`, tlzig-auto `203.328s`, both distinct
  `17,057,584`.
- [x] Fuse same-parent, static-key nested generated EXCEPT comparisons such as
  `[mtxnSnapshots EXCEPT ![n][tid]["active"] = FALSE,
  ![n][tid]["committed"] = TRUE]` into
  `primed_variable_double_except_update_equal_bool(...)`. The generated
  model remains strict with `fallbacks=0`. One-file audit improved
  `except_update=121 -> 75` and `primed_variable_full_compare=83 -> 64`.
  Capped 3M ReleaseFast improved only slightly from the accepted
  `28.59s`/`4.830T` to `28.48s`/`4.825T`, so this is correct direction but
  not enough to close the full TLC gap.
- [x] Generalize nested EXCEPT comparison lowering to statically disjoint
  paths with different depths, while rejecting ancestor/descendant overlaps.
  This covers hot updates such as `["writeSet"]` and `["data"][k]` under the
  same `mtxnSnapshots[n][tid]` record. One-file audit improved again to
  `except_update=61`, `primed_variable_full_compare=63`, `variable_path=523`,
  `function_range=11`, and `fallbacks=0`. Capped 3M ReleaseFast best improved
  to `27.75s` / `4.822T` retired instructions / ~`2.98GB` peak footprint.
- [x] Specialize generated no-clone boolean state-path reads and integer
  state-path comparisons. This lowered the one-file audit to
  `variable_path=383`, `nested_runtime_call=876`, and emitted `40`
  `variable_path*_int_compare_bool` calls with `fallbacks=0`. Capped 3M
  ReleaseFast is neutral on wall time but lower on retired instructions:
  `27.78s` / `4.821T` best repeat, with a lower single-run instruction count
  of `4.818T`. Latest full exact row before this path-compare specialization:
  TLC-auto `175.588s`, tlzig-auto `195.517s`, both distinct `17,057,584`.
- [x] Reduce generated-call context clearing in the hot action executor.
  Generated expression calls now clear only the active variable slice instead
  of all 64 partial-value slots. Sampling showed this path under
  `eval_compiled_bool`; capped 3M ReleaseFast improved to `26.52s` /
  `4.649T` retired instructions / ~`2.97GB` peak footprint. This is the best
  current tlzig capped baseline and is `7.9%` faster than the earlier
  `28.84s` accepted baseline. Full exact row improved to TLC-auto
  `171.622s`, tlzig-auto `183.769s`, both distinct `17,057,584`; tlzig is
  still slower by ~`7.1%`.
- [ ] Reduce remaining nested runtime helper chains after the concrete
  patterns above. Current broad audit count: `nested_runtime_call=9284`.
- [ ] Investigate and optimize `MCBinarySearch`. It remains correct but
  materially slower than TLC in the default ReleaseFast benchmark:
  TLC `1.703s/1.988s`, generic tlzig `6.261s/6.349s`, exact
  `34383/27953` states. Strict AOT now compiles with `Seq <- LimitedSeq`
  honored (`12` generated / `3` native / `0` fallbacks), but it was stopped
  after more than one minute because the first cached `SortedSeqs` build still
  materializes `UNION {[1..n -> Values] : n \in 1..MaxSeqLen}` eagerly. The
  next real fix is a lazy bounded-sequence/filter lowering for this pattern,
  not adding the AOT row to the default benchmark.
- [~] Borrow data-oriented ideas from Flecs/ECS, but do not add Flecs as a
  dependency unless a prototype proves it wins on tlzig's state-exploration
  hot paths. Useful ideas are packed/columnar TypeOK-derived state layouts,
  relationship-like indexes for function domains, query/branch planning, and
  batched candidate commits. The direct Flecs entity/component abstraction is
  not a natural fit for arbitrary canonical TLA+ values and would fight the
  TigerStyle/no-allocation hot-path goal.
- [ ] Keep the current 10x performance target tied to concrete strict
  generated baselines before further representation work:
  - `MultiShardTxn RC/no-prepare-block`: tlzig `0.695s/0.102s`; 10x target
    `0.069s/0.010s`.
  - `MultiShardTxn Storage`: tlzig `1.447s/0.174s`; 10x target
    `0.145s/0.017s`.
  - A packed/power-of-two fingerprint table prototype regressed both rows
    (`0.713s/0.105s` and `1.467s/0.187s`) and was reverted.
  - A one-pass sequence-function fingerprint prototype was neutral/noisy:
    RC/no-prepare-block moved to `0.702s/0.105s`, while Storage varied from
    `1.430s/0.162s` to `1.444s/0.228s`; it was reverted.
  - A marker-only `UNCHANGED` prototype removed root clones in the generic
    action executor, but generated-runtime primed reads still see only
    partial values without assignment kinds, causing a valid MDBTLA run to
    fail with `TypeError`; it was reverted. Revisit only with typed/generated
    action IR carrying assignment metadata end-to-end.
- [ ] Treat GPU acceleration as a later batched typed-layout experiment, not
  the next optimization step. The current `Value` evaluator is branch-heavy,
  pointer/offset traversing, and dedup/queue synchronized; GPU transfer,
  scheduling, and irregular memory would likely lose. Revisit only after
  TypeOK-derived flat arrays/bitsets exist for batched hashing, symmetry, and
  relation/set operations.
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
- [ ] Add explicit type-invariant specialization to CLI/library generation.
  Accept user-selected invariants such as `TypeOK`, validate them at initial
  states (and optionally on every successor in debug builds), infer stable
  variable/path types, and emit no-fallback Zig that can elide proven tag
  checks and generic set/function/record dispatch. Reject unsupported or
  ambiguous type invariants instead of silently weakening assumptions.
  - [ ] Add `--type-invariant NAME` and a matching library option. Never infer
    trust from an invariant merely named `TypeOK`.
    - [x] CLI strict-generation flag added. Selected invariants must name
      zero-argument operators, are added as generation roots, and are emitted
      as `type_invariant_names` metadata. Verified on `Barrier.tla` with
      `TypeOK` and `fallback_count=0`.
  - [ ] Parse supported membership/function/record/tuple/sequence clauses into
    a closed type environment; reject disjunctions, state-dependent domains,
    and paths whose type is not unique.
  - [ ] Validate the selected invariant on every initial state before enabling
    specialization. In Debug, assert it on every committed successor.
  - [ ] Emit fixed variable/path layouts and direct typed accessors in generated
    Zig. Remove value-tag switches, generic record lookup, and cross-pool
    dispatch only where the invariant proves the representation.
  - [ ] Make specialized generation strict: an unproved access is a generation
    error, never a fallback to generic `Value` operations.
- [ ] Benchmark type-specialized code against the same full TLC-valid configs
  in Debug, ReleaseFast one-core, and all-core modes. Keep specialization only
  where exact state counts/outcomes match the unspecialized checker.
- [ ] Add profile-guided generated-model specialization on top of TypeOK.
  - [ ] Add an instrumented model-run mode that records generated operator,
    branch, value-tag, collection-cardinality, quantifier short-circuit, and
    state-path frequencies into a versioned profile tied to the module/config
    identity and generated-source hash.
  - [ ] Merge profiles from representative one-core and all-core runs with
    saturating counters. Reject stale or mismatched profiles.
  - [ ] Feed the profile into strict Zig generation to order branches, inline
    hot operators, specialize dominant finite cardinalities, select bitset
    relation/set layouts, and move cold valid cases out of line.
  - [ ] Never use observed profiles as type proofs. TypeOK proves which
    representations are valid; profiles only choose among semantically
    equivalent implementations.
  - [ ] Experiment with LLVM instrumentation/use when supported by the pinned
    Zig toolchain. Keep tlzig-level PGO as the deterministic fallback because
    Zig 0.17.0-dev.857 exposes no documented PGO option in its CLI/build API.
  - [ ] Differentially verify PGO binaries against the same unspecialized
    generated model and Java TLC state counts/outcomes. Benchmark cold-start,
    trained one-core, trained all-core, and cross-trained profiles.
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

### Validation update (2026-06-20)

- [x] Build Java TLC deterministically from `vendor/tlaplus` before the
  benchmark. The exact benchmark command no longer depends on
  `/tmp/tla2tools.jar`; action-composition specs use the checked-in TLC source.
- [x] Fix CRLF dashed-section lexing. `UndirectedGraphs.tla` no longer loses
  `ConnectedComponents`, `AreConnectedIn`, and `IsStronglyConnected`; both
  YoYo configs now match TLC exactly in one-core and all-core runs.
- [x] Evaluate zero-argument primed definitions against the partial next state,
  matching the existing parameterized-operator path. This prevents
  `Serializable'` from accepting invalid self-edges in MCInnerSerial.
- [x] Remove the last generated action-call argument fallback: action operator
  arguments are `CompiledExpr` values and strict generated runs require native
  expression entries for all of them.
- [x] Restore canonical invariant semantics in parallel runs with worker-local
  evaluators. MCCRDT is exact at `1,350,001/25,000` without the former SIGBUS;
  YoYo Pruning is exact at `157/102`.
- [x] Strict RC native deadlock-stop timings:
  - snapshot: TLC `5.603s/2.486s`, tlzig `4.718s/0.280s`;
  - no-prepare-block: TLC `2.011s/1.982s`, tlzig `0.651s/0.077s`;
  - no-prepare-block-or-ww: TLC `1.889s/1.664s`, tlzig `0.630s/0.075s`;
  - with-prepare-block: TLC `1.873s/1.633s`, tlzig `0.655s/0.076s`.
  These configs stop on a deadlock; add `CHECK_DEADLOCK FALSE` differential
  configs before treating their partial distinct counts as full coverage.
- [x] Add lazy filtered-power-set quantifier iteration with scratch rollback.
  It avoids materializing all accepted subsets before existential
  short-circuiting.
- [x] Finish MCInnerSerial native performance work.
  - Fixed generated `variable_path` to honor `read_primed`, matching
    `variable()`/`primed_variable()` for indexed reads inside primed
    expressions. This removed the crossed `opQ'`/`opOrder'` false deadlock.
  - Re-enabled the filtered-power-set quantifier shortcut after proving the
    rejection was the primed indexed-read bug.
  - Added strict total-order recognition for existential quantification over
    `{R \in SUBSET (X \X X) : connex /\ transitive /\ irreflexive}`. The
    generated model lowers it to `exists_total_order_relation`, enumerating
    `|X|!` permutation orders instead of `2^(|X|^2)` subsets.
  - Verified strict generated MCInnerSerial: `fallback_count=0`, exact Java TLC
    parity `6181 generated / 195 distinct`.
  - Clean tlzig timings after removing debug probes:
    one-worker `0.73s`, auto-workers `0.06s`, peak RSS about `19MB/35MB`.
    Previous Java TLC baseline was about `304.85s` one-worker for the same
    config.
- [x] Add no-clone generated comparisons for indexed state reads.
  - `var[keys...] = rhs` and `var[keys...] # rhs` now lower to
    `variable_path_equal_bool` / `variable_path_not_equal_bool`, resolving the
    path in its source pool and comparing via `Value.eql_cross_pool` instead of
    cloning the leaf into the eval pool.
  - `field(var[keys...], name) = rhs` and `#` now lower to
    `variable_path_field_equal_bool` / `variable_path_field_not_equal_bool`,
    comparing the selected record field in its source pool without cloning the
    whole record.
  - MCInnerSerial remains exact at `6181/195`; generated code now has three
    no-clone path comparisons plus field-fused sites. Timing remains about
    `0.69s`, as expected because total-order enumeration dominates this spec's
    gain.
  - MDBTLA `MCMultiShardTxn_RC_snapshot` generates 116 no-clone path/field
    comparisons with `fallback_count=0` and remains exact on the one-worker
    deadlock-stop frontier: `245844 generated / 84692 distinct`, about
    `4.87s`.
- [x] Replace `Value.eql`'s `std.meta.eql` identical-representation fast path
  with explicit `same_repr` payload checks. This preserves the structural
  fallback and removes a measurable generic-union comparison cost:
  MCInnerSerial one-worker improved from about `0.72s` to `0.68s`; MDBTLA
  RC/snapshot remains exact at `245844/84692` and about `4.89s`.
- [x] Skip invariant reevaluation for duplicate canonical states. State
  invariants are checked when a canonical state is first inserted; repeated
  successors with the same fingerprint reuse that already-checked state.
- [x] Add no-clone generated comparisons for bare state roots:
  `x = rhs` and `x # rhs` now lower to `variable_equal_bool` /
  `variable_not_equal_bool` when exactly one side is a state variable. The
  runtime resolves the root in its source pool and compares with
  `Value.eql_cross_pool` instead of cloning the whole root into `eval_pool`.
- [x] Compare generated `UNCHANGED variable` cross-pool without cloning both
  roots. `Value.eql_cross_pool` now has the same-representation fast path for
  same-pool values, so borrowed unchanged canonical roots return immediately.
- [x] Re-validate strict generated benchmarks after these changes:
  - `MCMultiShardTxn_RC_snapshot`: TLC `5.257s/2.159s`, tlzig
    `4.794s/0.346s`, deadlock-stop frontier `245844/84692`.
  - `MCInnerSerial`: TLC `300.209s/32.068s`, tlzig `0.984s/0.112s`, exact
    `6181/195`.
- [ ] Implement native/typed state commit for MDBTLA-class specs.
  Expression-side wins are now mostly exhausted for RC/snapshot. The remaining
  one-worker cost and `~400MB` RSS are dominated by `commit_state` cloning
  changed `Value` trees into the candidate store. Use TypeOK-derived layouts
  and per-successor canonicalization to replace recursive clones with flat
  typed copies, preserving exact canonical fingerprints and parallel safety.
- [ ] Generate native action executors for MDBTLA-class `Next`.
  Samples for `MCMultiShardTxn_RC_no_prepare_block_exhaustive` are still
  dominated by recursive `ActionExecutor.execute_steps` branch/choose/call
  dispatch (`branch` at `src/action.zig:1472`, `choose` at `1372`, call
  continuations at `1414`). The strict generated expression layer is native,
  but action control flow still interprets the `ActionStep` tree. Generate
  per-action Zig loops/branches with explicit continuation structure before
  attempting more scalar helper micro-optimizations.
- [ ] Review stash `aaaa` follow-ups.
  - Keep: primed `variable_path` semantics, strict total-order lowering, and
    indexed no-clone path comparisons were good ideas and have been extracted
    into the working tree.
  - Keep, constrained: bare-variable comparison now lands only for one-sided
    state-root equality/inequality and is covered by strict generated
    RC/snapshot and MCInnerSerial benchmark runs.
  - Do not apply wholesale: the candidate-store borrowing/successor callback
    pipeline in the stash still changes value lifetimes across evaluator-pool
    restores and the prepared parallel path. Revisit only through a smaller
    typed-state commit design with differential tests.
  - Defer: native candidate-store borrowing / successor callback pipeline may
    attack the MDBTLA commit-state clone hotspot, but it changes state-value
    lifetime semantics and must not be merged without exact canonicalization,
    invariant, and parallel-worker tests.
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
  keep long cases and isolated one-core heavy cases opt-in so the default
  benchmark remains usable.

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
  - 2026-06-28 current target:
    `MultiShardTxn RC/no-prepare-block exhaustive`
    (`benchmark_configs/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block_exhaustive.cfg`).
  - Previous exact ReleaseFast row after partial slot clearing:
    TLC-auto 171.622s, tlzig-auto 183.769s,
    TLC states `99713354/17057584`,
    tlzig states `98533426/17057584`.
  - After generated boolean quantifier predicates:
    capped 3M best run 26.23s, 4.638T instructions, peak footprint
    2.976GB, generated/distinct `16920402/3000000`.
    This is better than the prior capped best 26.52s / 4.649T, but not
    a 10x-class change.
  - Exact row after generated boolean quantifier predicates:
    TLC-auto 176.805s, tlzig-auto 183.451s,
    TLC states `99713354/17057584`,
    tlzig states `98533426/17057584`.
    tlzig remains slower than TLC Java on this row by about 3.8%.
  - After generated-expression batch context lookup plus state-only context
    chains for generated partial assignments:
    capped 3M best observed run 26.56s, 4.569T instructions, peak footprint
    2.974GB, generated/distinct `16913730/3000000`.
    Exact row: TLC-auto 171.290s, tlzig-auto 182.444s,
    TLC states `99713354/17057584`,
    tlzig states `98533426/17057584`.
    This is the current best exact tlzig time in this thread, but tlzig is
    still about 6.5% slower than TLC Java for this full row.
  - After skipping generated partial-state array setup when no state
    assignments are present:
    capped 3M best observed run 23.90s, 4.258T instructions, peak footprint
    2.972GB, generated/distinct `16916698/3000000`.
    Exact row: TLC-auto 162.754s, tlzig-auto 165.286s,
    TLC states `99713354/17057584`,
    tlzig states `98533426/17057584`.
    This achieves the requested 10x-percent-class improvement over today's
    accepted tlzig full baseline (183.769s -> 165.286s, about 10.1% faster),
    but tlzig is still about 1.6% slower than TLC Java on this row.
  - Next structural target: remove generic action/context churn in
    `ActionExecutor.execute_steps` and generated expression argument binding;
    the remaining `Value`-based helper lowering is not enough for the
    requested speedup.

## Notes
- Update this file after every spec/example milestone.
- Record Java TLC command and timing in the spec row.
- Record tlzig command and timing in the spec row.
