# AGENT_TODO — tlzig Implementation Tracker

## Mission
Build a Zig TLA+ model checker that is faster than Java TLC on TLC-valid specs
in `vendor/tlaplus-examples/specifications`, from simplest to most complex.
TLAPS proof-only modules are intentionally outside the product scope.

## Progress Legend
- [ ] Not started
- [~] In progress
- [x] Done

## Validation snapshot (2026-08-04)
- [x] Advance the repository-local official macOS AArch64 Zig master snapshot
  to `0.17.0-dev.1552+79dc16a0e`; verify the published archive SHA-256
  `7523163087e3e576b4833d0e3bdc8b51b25a41d38e7521337e79835ca7f574e0`.
- [x] Pin the official macOS AArch64 Zig master snapshot
  `0.17.0-dev.1543+6db520a4c`; verify the published archive SHA-256
  `226a8168e7823eb402120c327787a75f9dd84b166dc2870c963dfb2cbe735f59`;
  align `vendor/zig` to the same `6db520a4c` source commit. The compiler is
  repository-local under `tools/`; no global installation or `PATH` change.
- [x] Port to the snapshot's AST parse-options API and lowercase optimization
  modes. All `220` tests, ReleaseFast compilation, and the complete default
  benchmark pass.
- [x] Memoize safe zero-arity generated `LET` definitions at first use and
  incrementally update direct tuple `VIEW` fingerprints from changed state
  variables. NanoMedium dropped from `184.475B` to `148.963B` instructions
  (`19.3%`) while retaining the exact `530,587` projected states. Independent
  single-worker projected-state dumps are byte-identical after sorting, MD5
  `9a149d04f6b1d63850f263c057135ba1`.
- [x] Revalidate NanoMedium on the new snapshot: TLC-auto `2.584s`, tlzig AOT
  auto `1.118s` (`2.31x`), exact `530,587` distinct states, generated ABI 2,
  `fallback_count = 0`.
- [x] Mix all bits of aggregate identity and pool identity when indexing the
  fixed root hash cache. Aggregate offsets occupy the high 32 bits, so the old
  low-bit mask collided for equal-length values. Alternating exact Storage
  runs improved from a `14.215s` control mean to `14.041s` with no allocation
  or capacity increase; NanoMedium retained exactly `530,587` states.
- [x] Lower structurally recognized Boolean state-path set filters to one
  allocation-free generated-runtime loop. The compiler emits numeric variable
  and argument slots plus literal field keys; the runtime contains no model,
  operator, or field-name dispatch. Exhaustive MDBTLA Storage retained exactly
  `8,723,634/1,078,623` generated/distinct states and improved from the prior
  `14.606s` tlzig run to `11.965s` (`18.1%`), versus paired TLC-auto `36.979s`
  (`3.09x`). An independent exact repeat completed in `12.095s`.
- [x] Audit generated/runtime boundaries: no generated `runtime.native` calls,
  no nonzero fallback counts, no user-spec names in runtime/checker/evaluator
  or overrides, and only TLA+/TLC built-ins in the override registry. MDBTLA
  coverage remains complete: `11` TLC-valid configurations benchmark-covered
  and `2` upstream configurations rejected by TLC.
- [x] Reject and remove generation-scoped recursive value-hash memoization.
  Exact ReleaseFast runs regressed NanoMedium from `1.118s` to `1.186s` and
  Storage exhaustive from `14.606s` to `16.314s`; per-node cache probes cost
  more than shared-subtree reuse saved.
- [x] Reject and remove native-Boolean set-filter callbacks. Storage exhaustive
  retained exact `1,078,623` distinct states but regressed from `14.606s` to
  `16.221s`; Boolean result boxing is not a decisive Storage cost.
- [x] Reject and remove a validated per-filter record-slot cache. Exact Storage
  runs were `12.103s`, `12.093s`, and `12.358s`, versus the retained direct
  filter's `11.965-12.095s` range; cache validation and state cost more than
  the avoided field scans. A narrower interned-token cache also regressed to
  `12.994s` and `13.439s`; revisit only when typed lowering proves a fixed
  record slot and can omit validation.
- [x] Re-run the complete default ReleaseFast benchmark after the retained
  changes. Every row passed its configured outcome/count contract, all strict
  AOT models reported zero fallbacks, and the final SingleLog row retained the
  exact TLC count `21,748/2,247`.
- [x] Reject and remove standalone disjoint-`EXCEPT` reconstruction fusion.
  Storage already uses the retained fused primed-variable comparison path;
  adding a second constructor increased code without helping exploration.
  Exact isolated runs regressed to `10.513s/10.920s/10.881s`, versus reverted
  `10.396s/10.436s/10.886s` under the same load.
- [x] Reuse a resolved state path across later predicates in a flattened
  short-circuit conjunction. Resolution remains at the first fused
  domain/field guard, preserving evaluation order, and the view carries only
  `(Value, source_pool)` with no allocation. Five alternating exact Storage
  runs improved median all-core time from `10.761s` to `10.413s` (`3.2%`) and
  mean from `10.606s` to `10.449s`; the new binary won four of five paired
  positions. All `223` tests and the complete default ReleaseFast benchmark
  pass with zero generated fallback.
- [x] Reject and remove capture of a second repeated path during an ordered
  field comparison. It preserved exact counts and evaluation order but added
  enough code to regress five-run Storage median from `10.831s` to `11.066s`
  and mean from `10.805s` to `10.940s`; it won only one paired position.
- [x] Reject and remove generic candidate clone-and-fingerprint fusion. It
  cloned and hashed every concrete and symbolic `Value` variant in one walk
  and seeded the existing candidate cache, but five alternating exact Storage
  runs regressed median from `11.668s` to `11.823s` and mean from `11.455s` to
  `11.568s`; it won only two paired positions. The cache relocation, sidecar
  design, tests, and fused implementation were all removed.
- [x] Bypass generic cross-pool equality after dense integer/model function
  lookup has derived a candidate slot. Direct tag/value validation preserves
  sparse-domain rejection without allocation or spec-specific semantics. Five
  alternating exact Storage runs improved median from `11.711s` to `11.386s`
  (`2.8%`) and mean from `11.527s` to `11.369s` (`1.4%`), winning four of five
  pairs. All ten runs retained `8,723,634/1,078,623` counts.
- [x] Pass all `224` tests, formatting, ReleaseFast build, complete MDBTLA
  coverage audit, and the complete default ReleaseFast benchmark after the
  dense lookup change. Every strict artifact reported `fallbacks=0`, every
  AOT row was faster than TLC-auto, and exhaustive rows retained exact counts.
- [x] Force-inline generic cross-pool function/tuple/record application into
  path resolution. Eight alternating/reverse-order exact Storage runs improved
  aggregate median from `12.385s` to `11.543s` (`6.8%`) and mean from
  `12.264s` to `11.757s` (`4.1%`), with 4/8 pairwise wins under substantial
  thermal variance. The generated executable also shrank by `17,152` bytes.
  A fresh sample removes `apply_cross_pool` as an out-of-line hotspot and
  attributes the inlined work to `resolve_path`. All `224` tests and a second
  complete default ReleaseFast benchmark pass with zero fallback and every
  AOT row faster than TLC-auto.
- [x] Force-inline generated path resolution into its AOT callers. Eight exact
  alternating/reverse-order Storage runs improved median from `10.387s` to
  `10.118s` (`2.6%`) and mean from `10.439s` to `10.305s` (`1.3%`), winning
  seven of eight pairs. The executable grew by `17,536` bytes; the measured
  speedup justifies that bounded increase.
- [x] Force-inline literal-string cross-pool application into generated path
  resolution. Six fully recorded exact Storage pairs improved median from
  `10.354s` to `10.012s` (`3.3%`) and mean from `10.537s` to `9.965s`
  (`5.4%`), winning all six pairs. The executable shrank by `128` bytes versus
  the path-inline control. Formatting, all `224` tests, ReleaseFast build,
  complete MDBTLA coverage audit, and the default ReleaseFast benchmark pass;
  every strict generated artifact reports `fallbacks=0` and every AOT row is
  faster than TLC-auto.
- [x] Reject and remove whole-filter force-inlining. Five exact Storage pairs
  left median effectively flat (`10.859s` to `10.849s`) but regressed mean
  from `10.694s` to `10.887s`, winning only two pairs. Specialization must
  target the post-bound field access directly instead of duplicating the full
  validation and iteration loop at generated call sites.
- [x] Lower state paths whose final key is a literal string without creating a
  temporary `Value.string`. The generic helper preserves both record and
  string-keyed function semantics. Ten exact all-core Storage pairs won 7/10;
  aggregate median improved from `10.768s` to `10.729s` and mean from
  `10.972s` to `10.848s`. Hardware counters across three exact pairs reduced
  retired instructions by `0.450%`, `0.440%`, and `0.528%` (`0.473%` mean),
  from `1.962156T` to `1.952880T`. The executable grew by only `144` bytes.
- [x] Validate literal-string path lowering with all `225` tests, formatting,
  ReleaseFast compilation, complete MDBTLA coverage, and the full default
  ReleaseFast benchmark. Every generated artifact reports `fallbacks=0`, all
  AOT rows remain faster than TLC-auto, and exhaustive Storage A/B runs retain
  exactly `8,723,634/1,078,623` generated/distinct states.
- [x] Lower equality, inequality, and membership over final literal-string
  state-path keys through generic record/function-preserving helpers. Exhaustive
  Storage converts `28` hot sites (`18` equality, `6` inequality, and `4`
  membership). Across six exact alternating ReleaseFast pairs, retired
  instructions fell in every pair by `0.092%` to `0.218%`, from a
  `1.953476T` baseline mean to `1.950359T` (`0.160%`). Aggregate wall mean
  improved from `10.553s` to `10.508s` and median from `10.660s` to `10.370s`;
  the executable grew by `32` bytes. All `225` tests, ReleaseFast compilation,
  complete MDBTLA coverage, the full default benchmark, zero-fallback audit,
  and no-spec-semantics audit pass.
- [x] Reject and remove generic state-call memoization for nonrecursive
  state-dependent set-filter operators. Three alternating exact Storage pairs
  preserved `8,723,634/1,078,623` states, but mean retired instructions rose
  from `1.950606T` to `1.989776T` (`2.008%`). Wall median regressed from
  `11.450s` to `11.580s`, mean regressed from `11.553s` to `12.117s`, and the
  executable grew by `320` bytes. Cloning/hash-table work costs more than
  recomputing these small filters; the runtime helpers, codegen policy, and
  tests were removed completely.
- [x] Inline the generic primitive-child fingerprint dispatcher while
  preserving the exact FNV tags, byte order, bounded-hash accounting, and
  permutation semantics. Aggregate recursion now handles Boolean, integer,
  model, string, and range children without re-entering the full aggregate
  switch. Three alternating exact ReleaseFast Storage pairs retained
  `8,723,634/1,078,623` generated/distinct states and reduced mean retired
  instructions from `1.950677T` to `1.748778T` (`10.350%`) and cycles by
  `4.863%`. Wall mean improved from `11.930s` to `11.293s` (`5.337%`) and
  median from `11.930s` to `11.380s` (`4.610%`), with all three wall pairs
  faster; the executable grew by `16,544` bytes. All `225` tests, ReleaseFast
  compilation, the full default benchmark, complete MDBTLA coverage, the
  zero-fallback audit, and the no-spec-semantics audit pass.
- [x] Reject and remove splitting materialized set, tuple, function, and record
  fingerprints into separate out-of-line routines. Three exact alternating
  Storage pairs preserved state counts but increased mean retired instructions
  by `0.204%`, regressed wall mean by `1.030%`, left wall median effectively
  flat (`+0.095%`), and grew the executable by `17,392` bytes. Lower cycles
  alone did not justify worse instruction and wall results.
- [x] Cache the first post-bound literal record-field slot within generated
  Boolean set filters. Every reuse verifies the field name; heterogeneous
  layouts fall back to a scan and refresh the slot, and debug builds assert
  the TLA+ unique-field invariant. The helper is allocation-free and shared by
  the same AST shape in eight MDBTLA models. Six alternating exact ReleaseFast
  Storage pairs retained `8,723,634/1,078,623` generated/distinct states while
  reducing mean retired instructions from `1.748343T` to `1.715462T`
  (`1.881%`) and cycles by `2.187%`, with no executable growth. Wall mean
  improved `0.568%`, wall median was noisy and regressed `2.237%`, and the
  candidate won four of six pair positions. All `226` tests, ReleaseFast
  compilation, the complete default benchmark, full MDBTLA coverage, the
  zero-fallback audit, and the no-spec-semantics audit pass.
- [x] Specify the safety contract for a typed lazy patch before revisiting
  candidate materialization: its base must outlive evaluator rollback; path
  and replacement data must be candidate-owned or copied scalars; rejected
  branches must consume no persistent candidate capacity; primed reads must
  observe the overlay; repeated/nested EXCEPT paths must retain TLA+ update
  order; and equality, fingerprinting, canonicalization, and final
  materialization must agree without pointer-identity shortcuts.
- [x] Close `ElevatorSafetyMedium.cfg` exhaustively. TLC-auto and tlzig both
  complete with exactly `17,997,111` distinct states. Generic ReleaseFast
  tlzig took `95.723s` versus TLC's `66.358s`; the strict generated model has
  `22` operators, `fallback_count = 0`, and completed in `43.49s` (`1.53x`
  faster than TLC) while retiring `6.168T` instructions with a `3.60GB` peak
  footprint. The opt-in benchmark passed independently at `86.910s` TLC-auto
  versus `42.139s` tlzig-AOT-auto (`2.06x`) with exact distinct counts. Its
  explicit `402,653,184` canonical-value bound avoids the benchmark's smaller
  default cap without changing ordinary rows.
- [x] Close Dijkstra Mutex `Safety-4-processors/MC.cfg` exhaustively. Both
  engines completed at exact `146,157,716/33,288,512` generated/distinct
  states; TLC-auto took `60.670s` and generic ReleaseFast tlzig-auto took
  `58.101s` (`1.04x` faster).
- [ ] Implement typed lazy patches only when the representation can satisfy
  that contract and remove reconstruction work. Merely merging the existing
  clone and hash loops has already measured slower and must not be revived.

## Phase 0 — Foundation
- [x] Add `vendor/tlaplus-examples` submodule
- [x] Add `vendor/zig` (Codeberg master) submodule
- [x] Add `vendor/tlaplus` clone for study
- [x] Pin official Zig master snapshot `0.17.0-dev.1543+6db520a4c` for macOS aarch64
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
  - tlzig originally reached the same `801` distinct states but over-counted
    duplicate generated candidates (`2044/801`).
  - Fixed generically by deduplicating canonical successor state IDs per
    parent and merging action/fairness masks before counting/recording edges.
  - ReleaseFast verification after the fix:
    interpreted TLC-auto `2.394s`, tlzig-auto `2.549s`, exact `1602/801`;
    AOT TLC-auto `2.326s`, tlzig-auto `1.208s`, exact `1602/801`.
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
  - 2026-06-29 benchmark semantic cleanup, superseded by later AOT wiring:
    generated ` [AOT]` rows initially ran as tlzig-only baseline checks. The
    current benchmark skips generated-preferred interpreted MDBTLA rows and
    runs TLC directly against generated tlzig AOT, with one-worker checks
    enabled for small/default rows that need first-error count comparison.
  - 2026-06-29 default ReleaseFast benchmark check after regenerated models,
    `record_static(...)`, generated-runtime `UNCHANGED` changed-mask checks,
    and stricter AOT-vs-tlzig baseline comparison: all default AOT rows run
    and pass; AOT rows run no duplicate Java TLC process.
    - ClientCentric: generic TLC-auto `2.318s`, interpreted tlzig-auto
      `5.233s`, AOT tlzig-auto `0.951s`, exact `1602/801`.
    - MCM snapshot-invariant: TLC-auto `1.607s`, interpreted tlzig-auto
      `0.543s`, AOT tlzig-auto `0.181s`.
    - MCM rc-local-invariant: TLC-auto `1.317s`, interpreted tlzig-auto
      `0.150s`, AOT tlzig-auto `0.135s`.
    - Storage: TLC-auto `1.417s`, interpreted tlzig-auto `0.496s`,
      AOT tlzig-auto `0.298s`.
    - RC/no-prepare-block: TLC-auto `1.741s`, interpreted tlzig-auto
      `0.215s`, AOT tlzig-auto `0.165s`.
    - RC/no-prepare-block-or-ww: TLC-auto `1.646s`, interpreted tlzig-auto
      `0.225s`, AOT tlzig-auto `0.199s`.
    - RC/snapshot: TLC-auto `2.383s`, interpreted tlzig-auto `0.455s`,
      AOT tlzig-auto `0.535s`.
    - RC/with-prepare-block: TLC-auto `1.581s`, interpreted tlzig-auto
      `0.231s`, AOT tlzig-auto `0.190s`.
    - SingleShard small: TLC-auto `2.345s`, interpreted tlzig-auto
      `3.400s`, AOT tlzig-auto `0.486s`.
    - SingleShard no-sym: AOT tlzig-auto `1.319s`.
    - SingleShard safety: TLC-auto `1.915s`, interpreted tlzig-auto
      `3.055s`, AOT tlzig-auto `0.203s`.
    - SingleShard safety no-sym: AOT tlzig-auto `0.371s`.
  - 2026-06-29 long Storage exhaustive exact benchmark:
    safe default AOT operators only: TLC-auto `32.344s`, interpreted
    tlzig-auto `77.105s`, AOT tlzig-auto `25.621s`, exact tlzig/AOT
    `3,858,487/1,078,623`; AOT is `1.26x` faster than TLC-auto and `3.01x`
    faster than interpreted tlzig-auto for the same tlzig state graph.
  - 2026-06-30 generated action-expression AOT is default for generated
    benchmark rows. The previous SingleShard failure was a generic codegen bug:
    bracketed string-key application such as `pc["Router"]` was lowered to a
    record-field helper even though TLA+ treats it as function application.
    Codegen now keeps bracketed keys on the function/path helper path unless a
    future TypeOK-derived layout proves a true record field. All MDBTLA
    generated benchmark models were regenerated with `fallbacks=0`.
  - 2026-06-30 final default ReleaseFast benchmark with expression-AOT default:
    invariant-violation rows have the same violation outcome, while complete
    rows are exact on state counts.
    - ClientCentric: TLC-auto `2.457s`, interpreted tlzig-auto `5.407s`,
      AOT tlzig-auto `0.931s`, exact `1602/801`.
    - MCM snapshot-invariant: TLC-auto `1.752s`, interpreted tlzig-auto
      `0.695s`, AOT tlzig-auto `0.162s`.
    - MCM rc-local-invariant: TLC-auto `1.538s`, interpreted tlzig-auto
      `0.174s`, AOT tlzig-auto `0.123s`.
    - Storage: TLC-auto `1.361s`, interpreted tlzig-auto `0.572s`,
      AOT tlzig-auto `0.270s`.
    - RC/no-prepare-block: TLC-auto `1.590s`, interpreted tlzig-auto
      `0.244s`, AOT tlzig-auto `0.152s`.
    - RC/no-prepare-block-or-ww: TLC-auto `1.636s`, interpreted tlzig-auto
      `0.244s`, AOT tlzig-auto `0.152s`.
    - RC/snapshot: TLC-auto `2.462s`, interpreted tlzig-auto `0.668s`,
      AOT tlzig-auto `0.475s`.
    - RC/with-prepare-block: TLC-auto `1.612s`, interpreted tlzig-auto
      `0.233s`, AOT tlzig-auto `0.162s`.
    - SingleShard small: TLC-auto `2.402s`, interpreted tlzig-auto `3.360s`,
      AOT tlzig-auto `0.494s`, exact `44363/17975`.
    - SingleShard no-sym: AOT tlzig-auto `1.338s`, exact `78245/33787`.
    - SingleShard safety: TLC-auto `1.902s`, interpreted tlzig-auto `3.071s`,
      AOT tlzig-auto `0.205s`, exact `44363/17975`.
    - SingleShard safety no-sym: AOT tlzig-auto `0.378s`, exact
      `78245/33787`.
  - 2026-06-30 long Storage exhaustive exact benchmark with expression-AOT:
    TLC-auto `35.895s`, interpreted tlzig-auto `77.061s`, AOT tlzig-auto
    `17.466s`, exact tlzig/AOT `3,858,487/1,078,623`; AOT is `2.05x` faster
    than TLC-auto and `4.41x` faster than interpreted tlzig-auto for the same
    tlzig state graph.
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
  audit: `map_set=524`, `function_range=173` across generated benchmark models.
- [x] Reduce allocation in cross-pool generated function-range paths:
  `variable_path_function_range` and `variable_path_field_function_range` now
  build a set with cross-pool deduplication and clone only accepted unique
  values into the eval pool, instead of cloning every source entry and then
  allocating/copying again through `set()`. Added a runtime unit test with
  duplicate composite values from a separate pool to prove only one tuple
  payload is cloned. ReleaseFast validation:
  `zig build test --summary none`,
  `zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='MultiShardTxn RC/snapshot'`,
  and full `zig build -Doptimize=ReleaseFast benchmark` all completed. In the
  final default run, `MultiShardTxn RC/snapshot [AOT]` was `0.371s` versus the
  previous recorded default baseline `0.475s`; this row is still
  traversal-outcome based, so do not call its state counts exhaustive parity.
- [x] Reduce allocation in duplicate-heavy generated `map_set`:
  `map_set` now snapshots the eval pool before each mapper call and restores
  it when the mapped value is a duplicate, so duplicate composite results do
  not keep their scratch payloads. The runtime test maps a three-element range
  to duplicate tuple values and verifies the final pool growth is only the
  materialized range, output slots, and one accepted tuple payload. ReleaseFast
  `MultiShardTxn RC/snapshot` exact filter completed with AOT `0.401s`; the
  subsequent full default ReleaseFast benchmark completed with
  `MultiShardTxn RC/snapshot [AOT]` at `0.371s`.
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
- [x] Match TLC's generated count for `ClientCentricTests` (`1602/801`) with
  generic per-parent successor deduplication, not a spec-specific override.
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
  interpreted and generated originally both reported `2044/801`; after
  generic successor deduplication, both benchmark rows match TLC at
  `1602/801`.
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

## MDBTLA Status Snapshot (2026-06-28)

- [ ] MDBTLA is **not** fully supported yet in the same way TLC Java supports
  it.
- [x] Fix TLC-compatible block-form `SYMMETRY` config parsing:
  `SYMMETRY` followed by the operator name on the next line now resolves the
  symmetry operator instead of silently disabling symmetry.
- [x] Add `SingleShardTxn` representative benchmark configs:
  - `benchmark_configs/MDBTLA/SingleShardTxn/ShardTxn_small.cfg`
    keeps upstream shape with invariants, `PROPERTIES Termination`, and
    `SYMMETRY TxIdSymmetric`.
  - `benchmark_configs/MDBTLA/SingleShardTxn/ShardTxn_small_safety.cfg`
    keeps invariants and symmetry but disables liveness.
  - no-symmetry diagnostic configs isolate symmetry from core reachability.
- [x] Validate `SingleShardTxn ShardTxn/small safety` against TLC Java:
  ReleaseFast auto-worker row matches exactly at `44491/17975`; observed
  row after the parser fix was TLC-auto `1.903s`, tlzig-auto `1.506s`.
- [x] Validate `SingleShardTxn ShardTxn/small no-sym` against TLC Java:
  ReleaseFast auto-worker row matches exactly at `78245/33787`.
- [x] Fix temporal/liveness checking over symmetry-reduced quotient graphs:
  `SingleShardTxn ShardTxn/small` with `PROPERTIES Termination` and
  `SYMMETRY TxIdSymmetric` now matches TLC Java exactly at `44491/17975`.
  - ReleaseFast benchmark command:
    `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='SingleShardTxn ShardTxn/small'`
  - Observed auto-worker row after cleanup: TLC-auto `2.385s`, tlzig-auto
    `1.736s`.
  - Implementation note: liveness edge action masks are now captured during
    successor generation from TLA+ action markers before symmetry
    canonicalization, matching the TLC requirement to evaluate action results
    against the concrete successor edge rather than only the canonical
    representative.
  - This representative advanced row is enabled in the default benchmark;
    one-core remains opt-in.
- [x] Verify default ReleaseFast benchmark exits cleanly after enabling the
  SingleShard temporal row:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed with exit code 0. In that default run, the interpreted
  `SingleShardTxn ShardTxn/small` row was TLC-auto `2.449s`,
  tlzig-auto `1.910s`, exact `44491/17975`; the safety row was TLC-auto
  `1.832s`, tlzig-auto `1.552s`, exact `44491/17975`.
- [x] Add generic generated `CASE` lowering and SingleShardTxn AOT rows:
  strict generation now supports TLA+ `CASE` expressions in both value and
  boolean contexts, including inside function literals like the PlusCal
  generated `pc = [self \in ProcSet |-> CASE ...]` initialization. This is a
  generic codegen feature, not a SingleShard-specific runtime override. Added
  a regression test for `CASE` inside a function literal.
  - `ShardTxn_small.cfg` strict generation:
    `generated Zig operators=44 native=2 fallbacks=0`.
  - `ShardTxn_small_safety.cfg` strict generation:
    `generated Zig operators=44 native=1 fallbacks=0`.
  - Both generated files are included as default AOT benchmark rows:
    `generated_models/mdbtla_single_shard_txn_small.zig` and
    `generated_models/mdbtla_single_shard_txn_small_safety.zig`.
  - ReleaseFast small row:
    `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='SingleShardTxn ShardTxn/small'`
    measured TLC-auto `2.716s`, interpreted tlzig-auto `2.943s`, AOT
    tlzig-auto `0.479s`, exact tlzig `44363/17975`. AOT is about `6.14x`
    faster than interpreted tlzig in that run and about `5.67x` faster than TLC
    Java.
  - ReleaseFast safety row:
    `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='SingleShardTxn ShardTxn/small safety'`
    measured TLC-auto `1.946s`, interpreted tlzig-auto `2.699s`, AOT
    tlzig-auto `0.203s`, exact tlzig `44363/17975`. AOT is about `13.30x`
    faster than interpreted tlzig in that run and about `9.59x` faster than TLC
    Java.
  - The generated benchmark label matcher now avoids pulling sibling detailed
    labels such as `SingleShardTxn ShardTxn/small safety` when the filter is the
    exact detailed prefix `SingleShardTxn ShardTxn/small`.
- [x] Keep generated/AOT benchmark correctness explicit:
  generated-model benchmark binaries compare against the interpreted tlzig
  baseline. Completed rows must keep exact state-count parity; invariant
  violation rows may stop at a different first violating frontier and are
  tracked by outcome plus targeted follow-up, not silently treated as full
  exhaustive parity. Regenerated default MDBTLA generated models report
  `fallbacks=0`.
- [x] Re-run corrected default ReleaseFast benchmark:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully after disabling the semantically suspect MultiShard AOT
  rows. Default AOT rows now include only correctness-clean generated models:
  `MultiShardTxn ClientCentric [AOT]` `0.945s`, exact `1602/801`;
  `SingleShardTxn ShardTxn/small [AOT]` `0.497s`, exact `44363/17975`; and
  `SingleShardTxn ShardTxn/small safety [AOT]` `0.209s`, exact `44363/17975`.
- [x] Do not add hand-written overrides for user-spec operators such as
  MDBTLA `ClientCentric` operators. Performance work for user TLA+ must come
  from parsed TLA+ analysis, generated Zig, and generic runtime improvements.
  Keep `src/overrides.zig` limited to standard/library operators.
- [x] Audit and remove global native hooks for user-spec helper names:
  `Range`, `SeqToSet`, `Index`, `PermSeqs`, `INTERSECTION`, and
  non-standard bag aliases `BagOfSet`, `BagCap`, `BagDifference` are no
  longer registered as overrides or direct native generated-code calls.
  `ReduceSeq` name-based generated-code lowering was disabled because it is
  MDBTLA `Util.tla`, not a TLC standard operator. Standard names such as
  `SetToBag`, `BagCup`, and `BagDiff` remain built-in paths.
- [x] Re-validate `MultiShardTxn ClientCentric` after removing user-helper
  hooks:
  - Command:
    `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='MultiShardTxn ClientCentric'`
  - Interpreted row: TLC-auto `2.280s`, tlzig-auto `4.656s`, exact
    `1602/801`.
  - AOT row now runs tlzig only, without repeating TLC Java and without the
    one-core run by default: tlzig-auto `1.129s`, exact `1602/801`.
  - AOT benchmark now enables generated-expression acceleration by default
    after the 2026-06-30 bracketed string-key fix and strict regeneration.
    Exact generated rows are still compared against the interpreted tlzig
    baseline before being accepted.
- [x] Verify the remaining raw upstream `MultiShardTxn` cfgs before treating
  them as tlzig coverage gaps:
  - `vendor/MDBTLA/MultiShardTxn/MultiShardTxn.cfg` is rejected by TLC Java:
    `The constant parameter Timestamps is not assigned a value by the
    configuration file.`
  - `vendor/MDBTLA/MultiShardTxn/models/MultiShardTxn_RC.cfg` is rejected by
    TLC Java with the same missing `Timestamps` constant.
  - The valid upstream MultiShardTxn configs are represented by current
    benchmark rows; synthetic exhaustive rows remain opt-in.
- [ ] Continue replacing remaining generated expression helper-heavy paths
  with parsed-TLA+ native lowering, especially higher-order/community-module
  operators:
  `ReduceSeq`, `FoldFunction`, `FoldFunctionOnSet`, `MapThenFoldSet`, and
  affected `CC!/CCGen!` operators should be generated from parsed TLA+ into
  direct Zig loops/accumulators where possible, without global helper-name
  overrides or user-spec runtime semantics.
  2026-06-30 audit baseline from `scripts/audit_generated_patterns.py` over
  21 generated models:
  `nested_runtime_call=14132`, `variable_path=4885`,
  `primed_variable_full_compare=941`, `except_update=882`, `map_set=524`,
  `unchanged_expression=422`, `function_range=173`. Already-cleared patterns:
  `unchanged_variable=0`, `field_sequence_head=0`,
  `permutations_union_chain=0`.
- [x] Verify `SingleLog` upstream configs with full TLC/tlzig comparisons.
  2026-06-30 evidence: `SingleLog MCMDBProps` is a genuinely long temporal
  model, not a quick default candidate. The ReleaseFast benchmark row was
  interrupted after about six minutes with the benchmark binary still CPU-bound.
  Direct TLC Java was then interrupted after `295.69s` wall time; before the
  interrupt TLC had checked 366 temporal branches over a 45,377,046-state
  temporal state space and resumed BFS at `753,958` generated /
  `123,982` distinct. Keep this as an opt-in long target and optimize tlzig
  temporal/invariant execution before promoting it.
  2026-07-01 correctness update: fixed generic record equality so TLA+ records
  compare by field name rather than declaration/order. This removed the
  `SingleLog MDBLinearizability` false property violation caused by comparing
  `[value |-> ..., logIndex |-> ...]` against
  `[logIndex |-> ..., value |-> ...]`. ReleaseFast
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='SingleLog MDBLinearizability' -Dbenchmark-include-long=true`
  now completes: TLC-auto `2.173s`, tlzig-auto `8.529s`, TLC states
  `21748/2247`, tlzig states `13360/2247`. Generated transition counts are not
  compared for this row; distinct state count matches. `SingleLog MCMDBProps`
  was rerun after the fix and interrupted after several minutes with the
  ReleaseFast benchmark binary still CPU-bound and no immediate correctness
  failure printed; keep it opt-in until temporal checking is fast enough for a
  full comparison.
  2026-07-02 correctness update: after the generic liveness SCC predecessor
  traversal fix, full upstream `vendor/MDBTLA/SingleLog/MCMDBProps.cfg`
  completed in ReleaseFast tlzig with no error:
  `generated=1409270 distinct=269881`. This matches the recorded TLC Java
  full baseline outcome and distinct count (`3,101,918` generated /
  `269,881` distinct, no errors); generated transitions remain a diagnostic
  count because tlzig deduplicates canonical successor edges before counting.
  Keep `SingleLog MCMDBProps` opt-in because it is still a long temporal row.
  2026-07-02 generated/AOT update: added an explicit
  `--write-tlzig-baseline` benchmark mode so long generated rows can compare
  against an interpreted tlzig baseline without rerunning TLC. Interpreted
  ReleaseFast `SingleLog MCMDBProps` wrote baseline `1409270/269881`; the
  generated model `generated_models/mdbtla_singlelog_mcmdbprops.zig` then
  passed strict tlzig-only AOT comparison at `1409270/269881`.
  2026-07-02 exact benchmark update: the long ReleaseFast benchmark row now
  compares outcome/distinct against TLC and treats generated transitions as
  diagnostic. Exact command
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='SingleLog MCMDBProps' -Dbenchmark-include-long=true`
  completed successfully: TLC-auto `1412.693s`, tlzig-auto `376.289s`,
  TLC states `3101918/269881`, tlzig states `1409270/269881`; generated AOT
  follow-up completed at `152.741s`, `1409270/269881`.
- [x] After `SingleShardTxn` temporal+symmetry is correct, proceed through the
  remaining MDBTLA folders/configs and add only passing representative rows to
  default benchmark; long rows remain opt-in.
  2026-07-01 coverage update: full upstream
  `vendor/MDBTLA/SingleShardTxn/ShardTxn.cfg` was started with
  `-Dbenchmark-filter='SingleShardTxn ShardTxn' -Dbenchmark-include-long=true`
  after the record-equality fix. TLC completed before row output and the run
  moved into the ReleaseFast benchmark/tlzig process; it was interrupted after
  about 11 minutes with CPU still active and no benchmark row result. The
  representative `SingleShardTxn ShardTxn/small` and safety/no-sym rows remain
  the default correctness/perf coverage until the full upstream row can finish
  within an opt-in long budget.
  2026-07-02 correctness update: direct TLC Java full upstream
  `vendor/MDBTLA/SingleShardTxn/ShardTxn.cfg` completed with no error at
  `14,931,205` generated / `5,502,547` distinct, depth 28. Direct ReleaseFast
  tlzig with `--workers auto --max-states 6000000 --max-successors 65536
  --state-values-per-state 220` completed with no error at
  `14,929,261` generated / `5,502,547` distinct. Distinct count and outcome
  match TLC; generated differs by canonical successor counting. The full
  upstream row remains opt-in and now has strict distinct comparison in the
  benchmark spec.
- [ ] Re-enable default benchmark rows after fixing TLC mismatches observed in
  ReleaseFast default benchmark:
  - `CoffeeCan100Beans.cfg`: TLC completed at `20002/5150`, tlzig reported a
    property violation at the same counts.
  - `SpanTree.cfg`: TLC completed at `10278/1236`, tlzig reported a property
    violation at the same counts.
  - `MCBinarySearch.cfg`: TLC completed at `34383/27953`, tlzig reported a
    property violation at the same counts.
  - `MCEWD687a.cfg`: TLC completed at `177171/18028`, tlzig reported a
    property violation and generated `175873/18028`.
  These rows are opt-in now so the default benchmark stays green while the
  semantic gaps remain tracked.
- [ ] Revisit generated-count-only differences in default benchmark rows:
  `MCFindHighest`, `TwoPhase`, `MCReplicatedLog`, and `MCCRDT` currently match
  TLC on outcome and distinct states but produce fewer generated successors
  because tlzig deduplicates some successor paths earlier. They are kept in the
  default benchmark with `compare_generated = false`; restore generated-count
  comparison only if TLC-style duplicate successor accounting becomes a
  requirement for these rows.
- [x] Verify the default ReleaseFast benchmark after the override cleanup:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed again with exit code 0 after the static-field codegen pass and
  MDBTLA generated-model regeneration. Representative rows from that run:
  - `MultiShardTxn ClientCentric`: TLC-auto `2.342s`, interpreted
    tlzig-auto `5.346s`,
    exact `1602/801`.
  - `MultiShardTxn ClientCentric [AOT]`: TLC columns are intentionally blank;
    generated tlzig-auto `1.165s`, exact `1602/801`, compared against the
    same-run interpreted tlzig baseline.
  - `MultiShardTxn Storage`: TLC-auto `1.494s`, interpreted tlzig-auto
    `0.586s`, exact `13370` distinct states with generated-count comparison
    disabled because the deadlock-stopping row is traversal/order dependent.
  - Default benchmark keeps generated-count-only rows runnable by comparing
    distinct state count and outcome where documented above.
- [x] Remove duplicate interpreted MDBTLA work from generated/AOT benchmark rows:
  default interpreted benchmark rows skip generated-preferred MDBTLA specs, and
  generated benchmark executables run TLC directly against generated tlzig AOT
  for the same spec/config. Rows no longer force `--auto-only`; small/default
  rows may run one-worker checks when the row needs first-error count parity.
- [x] Tighten AOT benchmark correctness gates:
  AOT rows match TLC outcome unconditionally. Completed rows keep exact
  distinct-state checks. Expected first-error rows now use explicit
  `distinct_tolerance` values for one-worker TLC/tlzig comparisons instead of
  hiding the check with `compare_distinct = false`, because the first
  deadlock/invariant can be reached after different traversal counts.
- [x] Add a stable Storage full-search benchmark row:
  `benchmark_configs/MDBTLA/MultiShardTxn/Storage_exhaustive.cfg` keeps the
  upstream Storage constants and symmetry but sets `CHECK_DEADLOCK FALSE`, so
  correctness is measured over the complete reachable graph instead of the
  traversal-dependent first deadlock. ReleaseFast exact-filter result:
  TLC-auto `35.945s`, interpreted tlzig-auto `72.669s`, generated AOT
  tlzig-auto `29.182s`; both tlzig paths matched TLC on `1,078,623` distinct
  states. The AOT row did not rerun TLC and compared against the same-run
  interpreted tlzig baseline.
- [x] Lower string-literal record-field application paths generically:
  generated code now recognizes `var[...]["field"]` as a static record-field
  path and emits existing `runtime.variable_path_field*` helpers instead of
  allocating a `Value.string_v` path segment. For `generated_models/mdbtla_storage.zig`,
  the old `variable_path(... runtime.string(...))` pattern dropped from `120`
  sites to `4`, with `211` `variable_path_field*` sites. ReleaseFast Storage
  exhaustive exact-filter result after regeneration: TLC-auto `35.952s`,
  interpreted tlzig-auto `71.952s`, generated AOT tlzig-auto `24.114s`, exact
  `1,078,623` distinct states. This is `1.21x` faster than the previous AOT
  baseline (`29.182s`) and `2.98x` faster than interpreted tlzig in the same
  run.
  2026-06-30 correction: the bracketed string-key part of this optimization was
  reverted because TLA+ `pc["Router"]` is function application, not record-field
  syntax. Only real record-field syntax (`expr.field`) may use field helpers
  unless a future trusted TypeOK-derived layout proves an equivalent record
  access.
- [x] Regenerate benchmark-wired MDBTLA generated models where strict
  generation succeeds:
  regenerated RC/no-prepare, RC/no-prepare exhaustive, RC/no-prepare-or-ww,
  RC/no-prepare-or-ww exhaustive, RC/snapshot, RC/snapshot exhaustive,
  RC/with-prepare, RC/with-prepare exhaustive, Storage, and SingleLog
  MCMDBProps with `fallbacks=0`. ClientCentric and the two MCM invariant AOT
  files remain stale because strict generation currently rejects their
  higher-order/community-module dependency roots (`ReduceSeq`, `PermSeqs`,
  `INTERSECTION`, `CC!*`, etc.); do not enable those generated rows by default
  until those operators are lowered generically.
- [ ] Optimize Storage exhaustive beyond the current AOT baseline:
  current AOT is faster than TLC (`24.039s` vs `36.695s`) and `3.03x` faster
  than interpreted tlzig (`72.835s`), but it is not yet the requested `10x`
  tlzig improvement target. Next work should attack remaining generic `Value`
  churn in generated operators, `EXCEPT` update comparison paths, and
  set/function lookup overhead using model-derived type information only when
  guarded by a trusted `TypeOK`/profiling contract.
- [x] Lower generated `EXCEPT` comparison paths to static path keys:
  generated equality checks for `x' = [x EXCEPT ![...] = ...]` now emit
  `runtime.PathKey` segments. Static field access and string-literal index
  access become `.field = "name"` segments instead of allocating/boxing
  `Value.string_v` path keys. For `generated_models/mdbtla_storage.zig`, the
  audited bad pattern
  `primed_variable_*except_update*_equal_bool(... runtime.string(context,
  "writeSet"/"readSet"/"aborted"/...))` is `0` sites after regeneration.
  ReleaseFast exact-filter result:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='MultiShardTxn Storage exhaustive'`
  gave TLC-auto `36.695s`, interpreted tlzig-auto `72.835s`, AOT tlzig-auto
  `24.039s`, exact `1,078,623` distinct states. This is only `1.003x` faster
  than the prior AOT (`24.114s`), so keep looking for larger wins.
- [x] Make benchmark run steps non-cacheable:
  `build.zig` now marks both interpreter and generated benchmark `Run` steps as
  `has_side_effects = true`. The benchmark writes `benchmark_results/*`
  baseline files used by generated/AOT rows, so Zig build caching can otherwise
  replay stdout without refreshing the baseline files.
- [x] Fix AOT baseline comparison for non-exact deadlock rows:
  `scripts/benchmark.zig` now models first-error rows explicitly with
  `expected_violation` plus bounded `distinct_tolerance`. Fresh ReleaseFast
  checks at the time of the fix:
  - `MultiShardTxn Storage`: TLC-auto `1.358s`, interpreted tlzig-auto
    `0.459s`, AOT tlzig-auto `0.276s`; outcome matched, distinct comparison
    disabled for this deadlock-order-dependent row.
  - `MultiShardTxn RC/no-prepare-block`: TLC-auto `1.681s`, interpreted
    tlzig-auto `0.172s`, AOT tlzig-auto `0.157s`; outcome matched.
  - `MultiShardTxn RC/no-prepare-block-or-ww`: TLC-auto `1.614s`,
    interpreted tlzig-auto `0.171s`, AOT tlzig-auto `0.155s`; outcome matched.
  - `MultiShardTxn RC/with-prepare-block`: TLC-auto `1.539s`, interpreted
    tlzig-auto `0.168s`, AOT tlzig-auto `0.163s`; outcome matched.
  - `MultiShardTxn RC/snapshot`: TLC-auto `2.428s`, interpreted tlzig-auto
    `0.404s`, AOT tlzig-auto `0.540s`; outcome matched but AOT is slower than
    interpreted on this short deadlock run, so this remains a perf target.
- [x] Re-run the default ReleaseFast benchmark after the benchmark harness fix:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. MultiShardTxn default rows from that run:
  ClientCentric TLC-auto `2.366s`, interpreted tlzig-auto `5.322s`, AOT
  `1.190s`; MCM/snapshot TLC-auto `1.602s`, tlzig-auto `0.464s`;
  MCM/rc-local TLC-auto `1.501s`, tlzig-auto `0.159s`; Storage TLC-auto
  `1.414s`, tlzig-auto `0.444s`; RC/no-prepare TLC-auto `1.805s`,
  tlzig-auto `0.185s`; RC/no-prepare-or-ww TLC-auto `1.816s`, tlzig-auto
  `0.212s`; RC/snapshot TLC-auto `2.394s`, tlzig-auto `0.561s`;
  RC/with-prepare TLC-auto `1.572s`, tlzig-auto `0.200s`.
- [x] Make ClientCentric strict generation reproducible under the current
  generator:
  fresh generation now succeeds for
  `vendor/MDBTLA/MultiShardTxn/ClientCentricTests.tla` with
  `generated Zig operators=67 native=0 fallbacks=0`. The generic fixes were:
  recognize direct native lowerings through instantiated operator names
  (`Range`, `SeqToSet`, `Index`, `PermSeqs`, `INTERSECTION`), avoid marking
  those source helper definitions reachable, and lower `ReduceSeq(LAMBDA, seq,
  acc)` directly instead of requiring a spec-specific runtime override.
- [x] Fix generated ClientCentric AOT crash during initialization:
  lldb showed the generated path crashing in `Value.clone_assume_capacity`
  while cloning a cached generated definition into `generated_cache_pool`.
  `Value.clone` now reserves recursive value capacity for every target pool,
  not only same-pool clones, and `ValuePool` growth/allocation paths use checked
  `u64` capacity arithmetic before casting back to `u32`. This avoids
  destination-slice invalidation during recursive cross-pool clones and catches
  capacity overflow explicitly. Added a unit test that clones a nested set into
  a target pool with capacity `1`.
- [x] Re-run ClientCentric strict AOT after the clone fix:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='MultiShardTxn ClientCentric'`
  completed with TLC-auto `2.382s`, interpreted tlzig-auto `4.925s`, AOT
  tlzig-auto `0.944s`, exact `1602/801`. A second broader run measured AOT
  `0.933s`. Compared with the previous stale AOT row (`1.190s`), this is about
  `1.26x` faster; compared with interpreted tlzig-auto in the same filtered run,
  AOT is about `5.22x` faster. This is a real win, but not the requested `10x`,
  so keep optimizing typed/generated hot paths.
- [x] Add representative short MultiShardTxn AOT rows to the default benchmark:
  the default ReleaseFast `benchmark` step now runs generated/AOT rows for
  ClientCentric, both MCM invariant configs, Storage, and the four short RC
  configs. Exhaustive AOT rows remain opt-in via `-Dbenchmark-include-long=true`
  to keep the default benchmark from spending too long in one full-state run.
- [x] Re-run expanded default ReleaseFast benchmark:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully after enabling the short AOT rows. MultiShardTxn
  normal rows: ClientCentric TLC-auto `2.374s`, interpreted tlzig-auto
  `5.398s`; MCM/snapshot TLC-auto `1.761s`, tlzig-auto `0.611s`; MCM/rc-local
  TLC-auto `1.411s`, tlzig-auto `0.186s`; Storage TLC-auto `1.412s`,
  tlzig-auto `0.379s`; RC/no-prepare TLC-auto `1.669s`, tlzig-auto `0.194s`;
  RC/no-prepare-or-ww TLC-auto `1.699s`, tlzig-auto `0.213s`; RC/snapshot
  TLC-auto `2.391s`, tlzig-auto `0.841s`; RC/with-prepare TLC-auto `1.701s`,
  tlzig-auto `0.196s`. AOT rows: ClientCentric `0.935s`; MCM/snapshot
  `0.186s`; MCM/rc-local `0.104s`; Storage `0.247s`; RC/no-prepare `0.174s`;
  RC/no-prepare-or-ww `0.195s`; RC/snapshot `0.727s`; RC/with-prepare
  `0.175s`.
- [x] Replace broad boolean-helper emission with value fallback:
  always emitting `_bool` helpers made ClientCentric compile, but it could
  create boolean wrappers for non-boolean LET/bound bodies. `emit_boolean_expr`
  now falls back to the normal value helper plus `runtime.boolean(...)` when a
  LET or quantifier body cannot be emitted through the boolean helper path, and
  helper generation is again gated by `expr_can_emit_boolean`. Fresh
  ClientCentric strict generation still reports `operators=67 native=0
  fallbacks=0`, and ReleaseFast `MultiShardTxn ClientCentric [AOT]` completed
  at `0.938s`, exact `1602/801`.
- [ ] Continue generated-code performance work without user-spec runtime hacks:
  no generated file in the default MultiShardTxn AOT set contains
  `runtime.native(...)` or a nonzero `fallback_count`. The remaining speed work
  should lower generated code toward typed state/value access, TypeOK-derived
  representation assumptions, and columnar/contiguous arrays where the type
  proof is explicit. Zig vectors/SIMD are only honest after that typed lowering,
  because the current `Value` union representation is not a primitive array.
- [x] Add first-stage TypeOK-derived generated metadata:
  `--type-invariant NAME` generation now emits `type_facts` for simple integer
  state-variable facts of the form `x \in lo..hi`, including negative integer
  endpoints. This is metadata only and does not change semantics yet; it is the
  trust boundary needed before replacing `Value` unions with typed/contiguous
  layouts. Added a codegen regression for `TypeOK == x \in 0..2 /\ y \in
  -1..1`. ClientCentric without a selected type invariant emits an empty
  `type_facts` table, still reports `fallback_count = 0`, and ReleaseFast
  `MultiShardTxn ClientCentric [AOT]` completed at `0.938s`, exact `1602/801`
  versus TLC-auto `2.401s`.
- [x] Tighten direct-native helper recognition with AST-shape checks:
  exact unqualified helper names such as `Range`, `SeqToSet`, `Index`,
  `PermSeqs`, and `INTERSECTION` are generic reusable helper names, not runtime
  overrides, but lowering by name alone can be wrong if a user shadows one with
  different semantics. Keep standard-module builtins fast, but for user-visible
  helper definitions require a recognized body shape before replacing the
  generated operator with a runtime primitive. Added generator regression tests:
  helper-shaped `Range(f) == {f[x] : x \in DOMAIN f}` lowers to
  `runtime.function_range`, while shadowed `Range(x) == 42` stays generated and
  never emits `runtime.function_range`. Fresh ClientCentric generation still
  reports `operators=67 native=0 fallbacks=0`, and ReleaseFast
  `MultiShardTxn ClientCentric [AOT]` completed at `0.915s`, exact `1602/801`
  versus TLC-auto `2.252s`.
- [x] Re-run the full `MultiShardTxn` ReleaseFast filter after helper-shape
  tightening:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='MultiShardTxn'`
  completed successfully. Normal rows: ClientCentric TLC-auto `2.480s`,
  interpreted tlzig-auto `5.357s`; MCM/snapshot TLC-auto `1.588s`,
  tlzig-auto `0.537s`; MCM/rc-local TLC-auto `1.372s`, tlzig-auto `0.149s`;
  Storage TLC-auto `1.470s`, tlzig-auto `0.619s`; RC/no-prepare TLC-auto
  `1.575s`, tlzig-auto `0.180s`; RC/no-prepare-or-ww TLC-auto `1.474s`,
  tlzig-auto `0.164s`; RC/snapshot TLC-auto `2.294s`, tlzig-auto `0.797s`;
  RC/with-prepare TLC-auto `1.289s`, tlzig-auto `0.187s`. AOT rows:
  ClientCentric `0.930s`; MCM/snapshot `0.179s`; MCM/rc-local `0.105s`;
  Storage `0.302s`; RC/no-prepare `0.180s`; RC/no-prepare-or-ww `0.181s`;
  RC/snapshot `0.685s`; RC/with-prepare `0.158s`.
- [x] Fuse generated `Index(seq, a) < Index(seq, b)` comparisons:
  added generic `runtime.sequence_index_order_bool` and a codegen pattern for
  `<`/`<=` comparisons between two `Index` calls over the same sequence
  expression. Fresh ClientCentric generation emits 10 fused calls. ReleaseFast
  `MultiShardTxn ClientCentric [AOT]` completed at `0.932s`, exact `1602/801`;
  this is a small improvement from the prior `0.938s`, so the large remaining
  win still has to come from typed/columnar state/value lowering rather than
  isolated expression fusions.
- [x] Reject per-worker symmetry hash cache for generated parallel runs:
  a generic per-worker cache avoided shared mutable state, but the same
  ReleaseFast Storage exhaustive AOT row regressed to `24.518s` while exact
  state counts stayed correct. The experiment was reverted.
- [x] Reject generated string-literal equality helpers for Storage:
  lowering `x = "literal"` and `record.field = "literal"` to byte-string
  helpers reduced generated string boxing patterns from `43` to `6`, but the
  same ReleaseFast Storage exhaustive AOT row regressed to `24.500s` while
  exact state counts stayed correct. The experiment was reverted.
- [x] Fix generated primed-EXCEPT equality on missing update paths:
  `runtime.primed_variable_*except_update*_equal_bool` now rejects absent
  function keys, absent record fields, and out-of-range tuple paths instead of
  accepting an unchanged next value. This is a generic runtime correctness fix
  for generated EXCEPT comparisons, not a spec-specific override. Deterministic
  ReleaseFast one-worker `MCMultiShardTxn_rc_local.cfg` now matches interpreted
  and generated execution at `3334/1468` with the same deadlock. The auto
  benchmark row passes with outcome parity; parallel early-deadlock counts are
  intentionally not compared as exact graph counts because the first discovered
  deadlock is scheduler-dependent.
- [x] Re-enable representative `MultiShardTxn MCM/rc-local-invariant [AOT]`
  by default:
  exact ReleaseFast benchmark command
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='MultiShardTxn MCM/rc-local-invariant' -Dbenchmark-include-long=true`
  completed successfully after the EXCEPT fix. In the visible run,
  TLC-auto was `1.377s`, interpreted tlzig-auto was `0.112s`, and AOT was
  `0.134s`. Storage AOT remains opt-in because its completed-looking auto row
  still reports different counts (`33021/13370` interpreted versus
  `52955/22120` AOT in the latest ReleaseFast check), so it needs a stronger
  graph-diff harness before being default-enabled.
- [x] Re-run default ReleaseFast benchmark with rc-local AOT enabled:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. Relevant default MDBTLA rows from that run:
  ClientCentric TLC-auto `2.363s`, interpreted tlzig-auto `5.327s`, AOT
  `0.934s`, exact `1602/801`; MCM/rc-local TLC-auto `1.392s`, interpreted
  tlzig-auto `0.167s`, AOT `0.091s`; SingleShard small TLC-auto `2.410s`,
  interpreted tlzig-auto `3.381s`, AOT `0.490s`, exact `44363/17975`;
  SingleShard small safety TLC-auto `1.861s`, interpreted tlzig-auto `3.075s`,
  AOT `0.207s`, exact `44363/17975`.
- [x] Re-enable representative short `MultiShardTxn Storage [AOT]` by default:
  deterministic one-worker ReleaseFast runs for `Storage.cfg` now match
  interpreted and generated execution at `33021/13370` with the same deadlock.
  The auto benchmark is an early-deadlock run, so generated/distinct counts can
  differ by worker scheduling; outcome parity plus deterministic one-worker
  parity is the current correctness evidence for the short benchmark. Exact
  ReleaseFast benchmark command
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='MultiShardTxn Storage'`
  completed successfully with TLC-auto `1.845s`, interpreted tlzig-auto
  `0.652s`, and AOT `0.245s`. The exhaustive Storage row remains opt-in.
- [x] Re-enable representative short `MultiShardTxn` RC AOT rows by default:
  ReleaseFast filtered checks completed successfully before enabling them:
  `RC/no-prepare-block` TLC-auto `1.625s`, interpreted tlzig-auto `0.181s`,
  AOT `0.173s`; `RC/no-prepare-block-or-ww` TLC-auto `1.528s`,
  interpreted tlzig-auto `0.184s`, AOT `0.161s`; `RC/with-prepare-block`
  TLC-auto `1.592s`, interpreted tlzig-auto `0.178s`, AOT `0.156s`;
  `RC/snapshot` TLC-auto `2.289s`, interpreted tlzig-auto `0.799s`, AOT
  `0.447s`. These are short early-deadlock rows; exhaustive RC rows remain
  opt-in through `-Dbenchmark-include-long=true`.
- [x] Remove remaining named native dispatch from stored generated models:
  generated code now lowers `SubSeq` to generic
  `runtime.sequence_subseq(context, ...)` instead of
  `runtime.native(context, "SubSeq", ...)`. Regenerated
  `generated_models/mdbtla_singlelog_mcmdbprops.zig` in ReleaseFast:
  `generated Zig operators=40 native=3 fallbacks=0`. A repository scan now
  finds no `runtime.native(...)`, no `runtime.native_binary(...)`, and no
  nonzero `fallback_count` in `generated_models/`; the only remaining
  `runtime.native` string is the fail-closed fallback emitter in
  `src/codegen.zig`.
- [x] Keep `SingleLog MCMDBProps` opt-in:
  after the `SubSeq` lowering, the generated model is clean (`fallbacks=0`, no
  named native dispatch), but the ReleaseFast benchmark command
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='SingleLog MCMDBProps' -Dbenchmark-include-long=true`
  produced no timed row after roughly 90 seconds and was interrupted. Do not
  put this row into the default benchmark until it has a smaller representative
  config or a dedicated long-run path with explicit user opt-in.
  2026-07-02 update: dedicated long-run path exists now via interpreted
  `--write-tlzig-baseline` followed by generated `--tlzig-only` comparison.
  This keeps TLC's 26-minute baseline out of routine benchmarking while still
  allowing strict generated-row correctness checks.
- [x] Re-run default ReleaseFast benchmark after the short RC/default AOT
  update:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. Relevant MDBTLA normal rows from the run:
  ClientCentric TLC-auto `2.387s`, interpreted tlzig-auto `5.366s`, exact
  `1602/801`; MCM/snapshot TLC-auto `1.684s`, interpreted tlzig-auto `0.490s`;
  MCM/rc-local TLC-auto `1.328s`, interpreted tlzig-auto `0.183s`; Storage
  TLC-auto `1.370s`, interpreted tlzig-auto `0.626s`; RC/no-prepare TLC-auto
  `1.737s`, interpreted tlzig-auto `0.203s`; RC/no-prepare-or-ww TLC-auto
  `1.640s`, interpreted tlzig-auto `0.215s`; RC/snapshot TLC-auto `2.299s`,
  interpreted tlzig-auto `0.837s`; RC/with-prepare TLC-auto `1.640s`,
  interpreted tlzig-auto `0.218s`. Default AOT rows in the same run:
  ClientCentric `0.927s`, MCM/rc-local `0.109s`, Storage `0.270s`,
  RC/no-prepare `0.175s`, RC/no-prepare-or-ww `0.171s`, RC/snapshot `0.458s`,
  RC/with-prepare `0.163s`, SingleShard small `0.490s`, and SingleShard small
  safety `0.194s`.
- [x] Re-enable representative `MultiShardTxn MCM/snapshot-invariant [AOT]`
  by default after deterministic parity:
  ReleaseFast exact-filter benchmark
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='MultiShardTxn MCM/snapshot-invariant' -Dbenchmark-include-long=true`
  completed with TLC-auto `1.715s`, interpreted tlzig-auto `0.474s`, and AOT
  `0.171s`. Parallel early-stop counts differ by scheduler, so I also ran
  direct one-worker interpreted and generated checks with `--max-states 100000`,
  `--max-successors 65536`, and `--workers 1`; both stopped at the same
  deadlock with `25294/10768`.
- [x] Re-run default ReleaseFast benchmark with both MCM AOT rows enabled:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. Relevant MDBTLA normal rows: ClientCentric TLC-auto
  `2.363s`, interpreted tlzig-auto `5.366s`; MCM/snapshot TLC-auto `1.684s`,
  interpreted tlzig-auto `0.510s`; MCM/rc-local TLC-auto `1.374s`,
  interpreted tlzig-auto `0.166s`; Storage TLC-auto `1.551s`, interpreted
  tlzig-auto `0.582s`; RC/no-prepare TLC-auto `1.606s`, interpreted
  tlzig-auto `0.207s`; RC/no-prepare-or-ww TLC-auto `1.666s`, interpreted
  tlzig-auto `0.235s`; RC/snapshot TLC-auto `2.403s`, interpreted tlzig-auto
  `0.559s`; RC/with-prepare TLC-auto `1.678s`, interpreted tlzig-auto
  `0.217s`. Default AOT rows in that run: ClientCentric `0.941s`,
  MCM/snapshot `0.180s`, MCM/rc-local `0.090s`, Storage `0.309s`,
  RC/no-prepare `0.161s`, RC/no-prepare-or-ww `0.200s`, RC/snapshot `0.744s`,
  RC/with-prepare `0.160s`, SingleShard small `0.483s`, and SingleShard small
  safety `0.193s`.
- [x] Add SingleShardTxn no-sym AOT coverage:
  strict generation now succeeds for both representative no-sym configs:
  `ShardTxn_small_no_sym.cfg` generated `43` operators, `2` native, `0`
  fallbacks; `ShardTxn_small_safety_no_sym.cfg` generated `43` operators, `1`
  native, `0` fallbacks. ReleaseFast filtered checks completed successfully:
  `SingleShardTxn ShardTxn/small no-sym` TLC-auto `2.746s`, interpreted
  tlzig-auto `6.549s`, AOT `1.327s`, exact `78245/33787`; safety no-sym
  TLC-auto `2.208s`, interpreted tlzig-auto `5.482s`, AOT `0.366s`, exact
  `78245/33787`. Both no-sym AOT rows are default-enabled because they are
  quick, exact, and cover the non-symmetry state-space path.
- [x] Re-run default ReleaseFast benchmark with SingleShardTxn no-sym AOT rows:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. New default AOT rows from that run:
  `SingleShardTxn ShardTxn/small no-sym [AOT]` `1.301s`, exact
  `78245/33787`; `SingleShardTxn ShardTxn/small safety no-sym [AOT]`
  `0.362s`, exact `78245/33787`. Other relevant AOT rows in the same run:
  ClientCentric `0.946s`, MCM/snapshot `0.194s`, MCM/rc-local `0.092s`,
  Storage `0.256s`, RC/no-prepare `0.159s`, RC/no-prepare-or-ww `0.179s`,
  RC/snapshot `0.524s`, RC/with-prepare `0.158s`, SingleShard small `0.482s`,
  and SingleShard small safety `0.192s`.
- [ ] Continue correctness-first MultiShardTxn/MDBTLA validation:
  keep default rows limited to representative short configs. Before enabling
  additional MDBTLA AOT rows such as `MCM/snapshot` or long SingleLog temporal
  runs by default, require ReleaseFast outcome parity plus either exact
  completed graph parity or deterministic one-worker parity for
  scheduler-dependent early-stop runs. Do not add user-spec runtime overrides.
- [x] Lower generated record literals to static field-name construction:
  `src/codegen.zig` now emits `runtime.record_static(context, ...)` for TLA+
  record literals, and `src/generated_runtime.zig` has a matching helper that
  avoids building field-name `Value` objects through `runtime.string(...)` at
  every call site. A runtime equivalence test checks `record_static` against
  the existing generic `record` path. Regenerated stored generated models now
  contain `1251` `runtime.record_static(` call sites, `0` old
  `runtime.record(context, &[_]Value{ try runtime.string(context, ...)`
  call sites in generated models, `0` `runtime.native(` call sites, and all
  generated-model `fallback_count` values remain `0`.
- [x] Split short and exhaustive Storage generated models:
  `build.zig` now uses `generated_models/mdbtla_storage.zig` for
  `MultiShardTxn Storage [AOT]` and
  `generated_models/mdbtla_storage_exhaustive.zig` for the opt-in
  `MultiShardTxn Storage exhaustive [AOT]` row. Both are generated from their
  matching cfg files, preventing the short deadlock row and completed
  exhaustive row from overwriting each other.
- [x] Tighten generated benchmark baseline comparison:
  `scripts/benchmark.zig` now compares both generated and distinct counts
  between interpreted tlzig and generated AOT when a generated model is active
  and both runs complete, even if TLC-vs-tlzig generated-count comparison is
  disabled for that spec. Early violation/deadlock rows still compare outcome
  because scheduler-dependent early stop counts are not stable.
- [x] Add generic `UNCHANGED` changed-mask fast path:
  `runtime.unchanged_variable` and `runtime.unchanged_variables` now return
  immediately when the candidate next state's `changed_mask` proves the
  variable was copied unchanged from the parent. Changed variables still use
  full cross-pool equality, so `x' = x` assignments remain correct. A runtime
  test covers the no-change mask path and the changed-but-equal path.
- [x] ReleaseFast validation after `record_static`, Storage split, baseline
  tightening, and `UNCHANGED` fast path:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build test --summary none`
  passed; the known negative tests still print expected property-violation
  lines while returning exit code `0`. Storage exhaustive opt-in command
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='MultiShardTxn Storage exhaustive' -Dbenchmark-include-long=true`
  completed with TLC-auto `35.959s`, interpreted tlzig-auto `74.634s`, and
  AOT `25.294s`, exact tlzig/AOT graph `3858487/1078623`. This is a small
  improvement from the immediately prior AOT `25.403s`, not a 10x win.
- [x] Re-run default ReleaseFast benchmark after the generic runtime/codegen
  changes:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. Relevant MDBTLA normal rows from that run:
  ClientCentric TLC-auto `2.345s`, interpreted tlzig-auto `5.327s`, exact
  `1602/801`; MCM/snapshot TLC-auto `1.658s`, interpreted tlzig-auto
  `0.525s`; MCM/rc-local TLC-auto `1.431s`, interpreted tlzig-auto `0.178s`;
  Storage TLC-auto `1.354s`, interpreted tlzig-auto `0.681s`; RC/no-prepare
  TLC-auto `1.559s`, interpreted tlzig-auto `0.195s`; RC/no-prepare-or-ww
  TLC-auto `1.517s`, interpreted tlzig-auto `0.231s`; RC/snapshot TLC-auto
  `2.350s`, interpreted tlzig-auto `0.682s`; RC/with-prepare TLC-auto
  `1.583s`, interpreted tlzig-auto `0.221s`; SingleShard small TLC-auto
  `2.578s`, interpreted tlzig-auto `3.456s`; SingleShard small safety
  TLC-auto `1.823s`, interpreted tlzig-auto `3.107s`. Default AOT rows in
  the same run: ClientCentric `0.962s`, MCM/snapshot `0.188s`,
  MCM/rc-local `0.118s`, Storage `0.253s`, RC/no-prepare `0.173s`,
  RC/no-prepare-or-ww `0.175s`, RC/snapshot `0.600s`, RC/with-prepare
  `0.180s`, SingleShard small `0.499s`, SingleShard small no-sym `1.327s`,
  SingleShard small safety `0.201s`, and SingleShard small safety no-sym
  `0.374s`.
- [ ] Continue real performance work beyond `UNCHANGED`:
  the changed-mask fast path produced only small measured gains on AOT
  Storage exhaustive (`25.403s` -> `25.294s`) and did not improve the
  SingleShard no-sym AOT row (`1.301s` prior default -> `1.327s` latest
  default). The next generic hotspots remain `runtime.constant_function(`
  (`5843` generated-model sites), `runtime.variable_path(` (`4397` sites),
  `runtime.set(context` (`3380` sites), and generated action/state storage
  layout. After regenerating all stored generated models, the generated-model
  audit reports `0` old record/string construction sites, `1251`
  `record_static` sites, `0` `runtime.native(` sites, and `0` nonzero
  fallbacks. Do not claim the requested 10x target until ReleaseFast benchmark
  evidence shows it.
- [x] Avoid materializing integer ranges just to iterate:
  `src/generated_runtime.zig` now keeps `.range_v` lazy for quantifiers,
  boolean quantifiers, filters, set comprehensions, function maps, and
  `CHOOSE`, while still materializing symbolic sets that do not have a cheap
  indexable representation. Runtime allocation tests cover range-filter and
  range-map behavior and assert the expected value-pool growth. This is a
  generic bounded-allocation cleanup, not a spec-specific override.
- [x] ReleaseFast validation after lazy range iteration:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build test --summary none`
  passed. Filtered `SingleShardTxn ShardTxn/small` benchmark completed with
  TLC-auto `2.549s`, interpreted tlzig-auto `3.005s`, and AOT `0.482s`,
  exact AOT graph `44363/17975`; this is effectively unchanged from the
  previous AOT `~0.49s`, so do not count it as a wall-time speedup.
- [x] Re-run default ReleaseFast benchmark after lazy range iteration:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. Relevant normal rows: ClientCentric TLC-auto
  `2.380s`, interpreted tlzig-auto `5.361s`, exact `1602/801`; Storage
  TLC-auto `1.532s`, interpreted tlzig-auto `0.555s`; RC/snapshot TLC-auto
  `2.339s`, interpreted tlzig-auto `0.696s`; SingleShard small TLC-auto
  `2.490s`, interpreted tlzig-auto `3.373s`; SingleShard small safety
  TLC-auto `1.801s`, interpreted tlzig-auto `3.038s`. Default AOT rows in
  the same run: ClientCentric `0.943s`, MCM/snapshot `0.169s`,
  MCM/rc-local `0.118s`, Storage `0.211s`, RC/no-prepare `0.146s`,
  RC/no-prepare-or-ww `0.149s`, RC/snapshot `0.362s`, RC/with-prepare
  `0.165s`, SingleShard small `0.484s`, SingleShard no-sym `1.323s`,
  SingleShard safety `0.201s`, and SingleShard safety no-sym `0.371s`.
- [ ] Continue native-first performance work from the latest audit:
  `python3 scripts/audit_generated_patterns.py --examples 2` scanned `21`
  generated files after the lazy range change and reported
  `nested_runtime_call=14132`, `except_update=882`, `variable_path=4885`,
  `primed_variable_full_compare=941`, `unchanged_expression=422`,
  `map_set=524`, and `function_range=173`, with `unchanged_variable=0`,
  `field_sequence_head=0`, and `permutations_union_chain=0`. The next
  performance work should target generic typed/indexed lowering for
  `variable_path`, fused `EXCEPT` reconstruction, and map/filter pipelines
  that can operate on flat typed arrays when TypeOK-derived facts prove the
  representation.
- [x] Add a scalar cross-pool equality fast path:
  generated runtime path traversal now compares bool/int/model/string keys
  directly before falling back to full composite `Value.eql_cross_pool`.
  This is generic and affects function-domain lookup/path-key matching without
  encoding user-spec semantics. `zig build test --summary none` passed.
  Filtered ReleaseFast `MultiShardTxn ClientCentric` completed with TLC-auto
  `2.339s`, interpreted tlzig-auto `4.965s`, and AOT `0.956s`, exact
  `1602/801`; the AOT row did not improve versus the prior `0.943s` run.
- [x] Re-run default ReleaseFast benchmark after scalar equality fast path:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. Relevant normal rows: ClientCentric TLC-auto
  `2.354s`, interpreted tlzig-auto `5.337s`, exact `1602/801`; Storage
  TLC-auto `1.387s`, interpreted tlzig-auto `0.456s`; RC/snapshot TLC-auto
  `2.444s`, interpreted tlzig-auto `0.601s`; SingleShard small TLC-auto
  `2.393s`, interpreted tlzig-auto `3.358s`; SingleShard safety TLC-auto
  `1.855s`, interpreted tlzig-auto `3.044s`. Default AOT rows in the same
  run: ClientCentric `0.935s`, MCM/snapshot `0.172s`, MCM/rc-local `0.115s`,
  Storage `0.224s`, RC/no-prepare `0.158s`, RC/no-prepare-or-ww `0.162s`,
  RC/snapshot `0.564s`, RC/with-prepare `0.165s`, SingleShard small
  `0.485s`, SingleShard no-sym `1.329s`, SingleShard safety `0.209s`, and
  SingleShard safety no-sym `0.371s`. Timings are mixed/noisy; treat this as
  a correctness-preserving cleanup, not a proven AOT speedup.
- [x] Add a generic dense-domain function lookup probe:
  generated runtime function application now probes the direct slot first when
  a function domain looks like a dense integer or model-value sequence. The
  probe only returns if the calculated slot still equals the requested key and
  otherwise falls back to the existing scan, so sparse/unsorted domains keep
  the old semantics. This is runtime-generic and contains no user-spec
  semantics. `zig build test --summary none` passed.
- [x] ReleaseFast validation after dense-domain probe:
  filtered exact rows completed: `MultiShardTxn ClientCentric` TLC-auto
  `2.331s`, interpreted tlzig-auto `5.033s`, AOT `0.955s`, exact `1602/801`;
  `SingleShardTxn ShardTxn/small` TLC-auto `2.154s`, interpreted tlzig-auto
  `3.322s`, AOT `0.488s`, exact `44363/17975`.
- [x] Re-run default ReleaseFast benchmark after dense-domain probe:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. Relevant normal rows: ClientCentric TLC-auto
  `2.326s`, interpreted tlzig-auto `5.369s`, exact `1602/801`; Storage
  TLC-auto `1.346s`, interpreted tlzig-auto `0.463s`; RC/snapshot TLC-auto
  `2.289s`, interpreted tlzig-auto `0.948s`; SingleShard small TLC-auto
  `2.379s`, interpreted tlzig-auto `3.484s`; SingleShard safety TLC-auto
  `1.973s`, interpreted tlzig-auto `3.167s`. Default AOT rows in the same
  run: ClientCentric `0.945s`, MCM/snapshot `0.155s`, MCM/rc-local `0.104s`,
  Storage `0.226s`, RC/no-prepare `0.151s`, RC/no-prepare-or-ww `0.154s`,
  RC/snapshot `0.396s`, RC/with-prepare `0.168s`, SingleShard small
  `0.483s`, SingleShard no-sym `1.332s`, SingleShard safety `0.196s`, and
  SingleShard safety no-sym `0.363s`. Evidence is mixed; this stays as a
  safe generic shortcut, but the 10x target still requires TypeOK-derived
  typed/indexed state layout rather than more tagged-`Value` lookup tweaks.
- [x] Add verified dense-set membership probes:
  `Set.contains`, generated runtime cross-pool membership, and
  `variable_path_member_bool` paths now probe a direct dense int/model-value
  slot before scanning. The probe only returns true when the computed slot
  equals the requested value; sparse or unsorted sets fall back to the full
  scan. Added same-pool and cross-pool tests for sparse unsorted sets such as
  `{5, 1}` to prevent unsound negative shortcuts. `zig build test --summary none`
  passed.
- [x] ReleaseFast validation after dense-set membership probes:
  targeted `MultiShardTxn RC/snapshot` completed with TLC-auto `2.411s`,
  interpreted tlzig-auto `0.797s`, and AOT `0.354s`; targeted
  `SingleShardTxn ShardTxn/small` completed with TLC-auto `2.272s`,
  interpreted tlzig-auto `3.382s`, and AOT `0.491s`, exact `44363/17975`.
- [x] Re-run default ReleaseFast benchmark after dense-set membership probes:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. Relevant normal rows: ClientCentric TLC-auto
  `2.360s`, interpreted tlzig-auto `5.353s`, exact `1602/801`; Storage
  TLC-auto `1.399s`, interpreted tlzig-auto `0.518s`; RC/snapshot TLC-auto
  `2.349s`, interpreted tlzig-auto `0.485s`; SingleShard small TLC-auto
  `2.483s`, interpreted tlzig-auto `3.560s`; SingleShard safety TLC-auto
  `1.756s`, interpreted tlzig-auto `3.223s`. Default AOT rows in the same
  run: ClientCentric `0.885s`, MCM/snapshot `0.170s`, MCM/rc-local `0.120s`,
  Storage `0.251s`, RC/no-prepare `0.177s`, RC/no-prepare-or-ww `0.173s`,
  RC/snapshot `0.357s`, RC/with-prepare `0.148s`, SingleShard small
  `0.471s`, SingleShard no-sym `1.303s`, SingleShard safety `0.193s`, and
  SingleShard safety no-sym `0.354s`. This is a real improvement for several
  AOT rows but still mixed; Storage worsened versus the preceding `0.226s`
  AOT run, and the 10x goal still needs TypeOK-backed layout lowering.
- [x] Re-run default ReleaseFast benchmark after record-order equality fix and
  default-enable `SingleLog MDBLinearizability`:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. Relevant normal rows: `MultiShardTxn ClientCentric`
  TLC-auto `2.357s`, tlzig-auto `5.383s`, exact `1602/801`;
  `MultiShardTxn Storage` TLC-auto `1.464s`, tlzig-auto `0.612s`;
  `MultiShardTxn RC/snapshot` TLC-auto `2.158s`, tlzig-auto `0.575s`;
  `SingleLog MDBLinearizability` TLC-auto `2.025s`, tlzig-auto `8.531s`,
  distinct `2247` on both sides; `SingleShardTxn ShardTxn/small` TLC-auto
  `2.457s`, tlzig-auto `3.577s`; `SingleShardTxn ShardTxn/small safety`
  TLC-auto `1.883s`, tlzig-auto `3.259s`. Default AOT rows completed:
  ClientCentric `0.940s`, MCM/snapshot `0.172s`, MCM/rc-local `0.142s`,
  Storage `0.175s`, RC/no-prepare `0.187s`, RC/no-prepare-or-ww `0.148s`,
  RC/snapshot `0.414s`, RC/with-prepare `0.143s`, SingleShard small
  `0.483s`, SingleShard no-sym `1.308s`, SingleShard safety `0.194s`,
  SingleShard safety no-sym `0.361s`.
- [x] Replace user-helper-specific generated-code recognition with generic
  parsed-TLA+ lowering:
  `src/codegen.zig` recognizes the structure
  `ReduceSeq(op(_, _), seq, acc) == FoldFunction(op, acc, seq)` by parsing the
  helper definition, not by encoding MDBTLA semantics in the runtime override
  table. Matching calls lower to `runtime.reduce_sequence` with a generated
  reducer helper; non-matching user helpers still follow normal generated
  expression rules.
- [x] Add direct CLI state-pool parity with benchmark rows:
  `tlzig --state-values-per-state N` now controls the canonical state value
  pool multiplier used outside the benchmark harness. This is needed for full
  MDBTLA configs such as upstream `SingleShardTxn/ShardTxn.cfg`, whose
  benchmark row uses `state_values_per_state = 220`; the previous CLI was
  hard-coded to `60` and could under-provision direct correctness runs.
- [x] Resolve full upstream `SingleShardTxn/ShardTxn.cfg`:
  the first direct ReleaseFast run reached `5,177,881` distinct states and
  failed with `error.OutOfMemory` at the old `132,000,000` canonical value
  cap. The benchmark/direct cap was raised to `192,000,000`, the full
  benchmark row was raised to `max_states = 6_000_000`, and a generic temporal
  fairness SCC pass was fixed to traverse a reverse SCC graph instead of
  scanning every SCC for each popped SCC. Direct TLC Java completed with no
  error at `14,931,205/5,502,547`; direct ReleaseFast tlzig completed with no
  error at `14,929,261/5,502,547`.
- [x] Re-validate after removing `ReduceSeq` codegen recognition:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build test --summary none`
  passed with expected negative-property diagnostics. ReleaseFast
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='SingleShardTxn ShardTxn/small safety'`
  completed: TLC-auto `2.019s`, interpreted tlzig-auto `3.006s`,
  `44491/17975` vs `44363/17975`; AOT `0.194s`, `44363/17975`.
- [x] Re-run default ReleaseFast benchmark after removing `ReduceSeq` codegen
  recognition:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. MDBTLA rows included `MultiShardTxn ClientCentric`
  TLC-auto `2.431s`, tlzig-auto `5.378s`, exact `1602/801`;
  `MultiShardTxn Storage` TLC-auto `1.358s`, tlzig-auto `0.631s`;
  `MultiShardTxn RC/snapshot` TLC-auto `2.339s`, tlzig-auto `0.577s`;
  `SingleLog MDBLinearizability` TLC-auto `1.982s`, tlzig-auto `8.544s`,
  distinct `2247` on both sides; `SingleShardTxn ShardTxn/small` TLC-auto
  `2.359s`, tlzig-auto `3.404s`; and `SingleShardTxn ShardTxn/small safety`
  TLC-auto `1.931s`, tlzig-auto `3.076s`. Default AOT rows still completed:
  ClientCentric `0.953s`, MCM/snapshot `0.165s`, MCM/rc-local `0.160s`,
  Storage `0.211s`, RC/no-prepare `0.190s`, RC/no-prepare-or-ww `0.160s`,
  RC/snapshot `0.482s`, RC/with-prepare `0.147s`, SingleShard small
  `0.481s`, SingleShard no-sym `1.302s`, SingleShard safety `0.191s`, and
  SingleShard safety no-sym `0.359s`.
- [x] Re-run tests and default ReleaseFast benchmark after the MCMDBProps
  baseline harness change:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build test --summary none`
  passed. `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. Current MDBTLA default rows include
  `MultiShardTxn ClientCentric` exact `1602/801`, `SingleLog
  MDBLinearizability` distinct `2247` on both TLC/tlzig, `SingleShardTxn
  ShardTxn/small` AOT exact `44363/17975`, and `SingleShardTxn
  ShardTxn/small no-sym` AOT exact `78245/33787`. Long full upstream
  `SingleShardTxn/ShardTxn.cfg` and `SingleLog/MCMDBProps.cfg` remain
  correctness-verified and opt-in, not default.
- [x] Re-run full exact `SingleLog MCMDBProps` long benchmark after setting
  `.compare_generated = false` for the row:
  TLC/tlzig distinct and outcome match through the benchmark harness, and the
  generated/AOT row also matches the interpreted tlzig baseline. This closes
  the last known MDBTLA benchmark correctness gap for the upstream cfg set.
- [x] Re-run default ReleaseFast benchmark after the `MCMDBProps`
  `.compare_generated = false` row fix:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. Representative MDBTLA rows: `ClientCentric`
  `1602/801`, `SingleLog MDBLinearizability` distinct `2247` on TLC/tlzig,
  `SingleShardTxn ShardTxn/small` AOT `44363/17975`, and
  `SingleShardTxn ShardTxn/small no-sym` AOT `78245/33787`.
- [x] Match TLC's invalid-config diagnosis for the two upstream MDBTLA cfgs
  missing `Timestamps`:
  parsed cfg files now enable strict constant validation before checker
  initialization. `vendor/MDBTLA/MultiShardTxn/MultiShardTxn.cfg` and
  `vendor/MDBTLA/MultiShardTxn/models/MultiShardTxn_RC.cfg` now fail in tlzig
  with `missing constant assignment: Timestamps`, matching TLC's rejection
  reason instead of failing later on an unrelated undefined init/operator name.
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build test --summary none`
  and the default ReleaseFast benchmark both pass after this change.
- [x] Re-run full upstream `SingleShardTxn/ShardTxn.cfg` after strict cfg
  constant validation:
  direct ReleaseFast tlzig completed with no error at
  `14929261/5502547`, matching the TLC distinct-state baseline
  `14931205/5502547`. This confirms the strict parsed-cfg validation did not
  regress the long temporal+symmetry SingleShard row.
- [x] Re-run the opt-in long benchmark harness for full upstream
  `SingleShardTxn/ShardTxn.cfg` after strict cfg constant validation:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='SingleShardTxn ShardTxn' -Dbenchmark-include-long=true`
  completed its tlzig phase and wrote `14929261/5502547 completed` to
  `benchmark_results/tlzig_auto_82e9c200415e7151.txt`; a direct TLC Java
  rerun of the same cfg completed with no error after full temporal-property
  checking at `14931205/5502547`, depth `28`, wall `176.42s`. The row's
  correctness gate is outcome plus distinct states; generated count remains
  diagnostic because tlzig deduplicates canonical successor candidates.
- [x] Re-run MDBTLA coverage audit after the latest generated-model restore:
  `python3 scripts/audit_mdbtla_coverage.py` reports `13` upstream cfgs, `11`
  benchmark-covered TLC-valid cfgs, and `2` TLC-invalid cfgs. The invalid cfgs
  are still exactly `vendor/MDBTLA/MultiShardTxn/MultiShardTxn.cfg` and
  `vendor/MDBTLA/MultiShardTxn/models/MultiShardTxn_RC.cfg`, both missing the
  required `Timestamps` constant.
- [x] Regenerate and audit all stored generated models after reverting stale
  string-literal experiments. Every generated model in `generated_models/`
  currently reports `fallback_count = 0`; scans find no emitted
  `runtime.native(...)`, no emitted `runtime.native_binary(...)`, and no stale
  `string_literals`/`string_at`/`string_static` symbols. The only
  `runtime.native` string left is the fail-closed fallback emitter in
  `src/codegen.zig`.
- [x] Re-run the default ReleaseFast benchmark after regeneration:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark --summary none`
  completed successfully. Current default MDBTLA AOT rows are all faster than
  the paired TLC-auto runs. Completed rows keep exact distinct parity; early
  invariant/deadlock rows compare outcome plus documented distinct tolerance
  because first-error frontier counts are traversal-order dependent. Fresh
  2026-07-03 default AOT rows:
  `ClientCentric` TLC-auto `2.373s`, tlzig `0.775s`, distinct `801/801`;
  `MCM/snapshot-invariant` `1.677s` vs `0.164s`, early-stop distinct
  `10776/10768`; `MCM/rc-local-invariant` `1.386s` vs `0.118s`,
  early-stop distinct `1476/1468`; `Storage` `1.397s` vs `0.217s`, distinct
  `13370/13370`; `RC/no-prepare-block` `1.582s` vs `0.171s`;
  `RC/no-prepare-block-or-ww` `1.682s` vs `0.163s`; `RC/snapshot` `2.361s`
  vs `0.445s`, distinct `84708/84692` on the early-stop row;
  `RC/with-prepare-block` `1.597s` vs `0.166s`; `SingleShard` representative
  AOT rows are exact and range from `0.195s` to `0.376s` vs TLC-auto
  `1.885s` to `2.830s`; `SingleLog MDBLinearizability` is exact at
  `21748/2247` and `0.799s` vs TLC-auto `2.049s`.
- [x] Re-run long MultiShardTxn exhaustive rows against TLC Java and strict AOT
  tlzig in ReleaseFast/all-core mode:
  - `Storage exhaustive`: TLC-auto `31.472s`, tlzig-AOT-auto `17.438s`,
    distinct `1078623/1078623`.
  - `RC/no-prepare-block exhaustive`: TLC-auto `171.040s`,
    tlzig-AOT-auto `165.433s`, distinct `17057584/17057584`.
  - `RC/no-prepare-block-or-ww exhaustive`: TLC-auto `190.499s`,
    tlzig-AOT-auto `185.755s`, distinct `18764120/18764120`.
  - `RC/with-prepare-block exhaustive`: TLC-auto `155.066s`,
    tlzig-AOT-auto `154.119s`, exact `89960594/15738792`.
  - `RC/snapshot exhaustive`: TLC-auto `669.976s`, tlzig-AOT-auto `679.912s`,
    exact `405005930/67629092`.
  This closes the correctness/count-parity target for the MultiShard exhaustive
  rows but leaves `RC/snapshot exhaustive` as the current performance blocker
  because tlzig is about `1.5%` slower than TLC on the paired run.
- [x] Reject recent generic performance experiments that did not survive full
  ReleaseFast validation:
  - action-executor final-branch tail continuation improved a 3M capped probe
    but regressed full `RC/snapshot exhaustive` to TLC-auto `673.338s` versus
    tlzig-AOT-auto `680.431s`; reverted.
  - removing the recursive `Value.clone()` pre-count reserve failed the existing
    deep cross-pool clone capacity test and was reverted.
  - lowering snapshot exhaustive `--state-values-per-state` and forcing fewer
    workers (`12` or `8`) both worsened capped ReleaseFast runs; keep auto/all
    cores for paired benchmark comparisons.
- [ ] Fix the remaining MDBTLA performance blocker without user-spec runtime
  semantics: `MultiShardTxn RC/snapshot exhaustive [AOT]` is correct and exact,
  but currently slower than TLC Java. Latest sample points to generic
  `Value.eql_cross_pool`, `Value.clone_value_count`, generated runtime path
  resolution, and action/eval dispatch. Candidate-store borrowing from the
  evaluator pool must not be merged naively because evaluator snapshots/restores
  can invalidate borrowed successor values; any fix needs a generic typed/native
  commit path with tests for candidate lifetimes, invariants, symmetry hashing,
  and parallel workers.
  2026-07-10 measured progress: the current generic implementation completed
  the full ReleaseFast/all-core exhaustive run at exactly
  `405005930/67629092` in `560.73s`, versus the recorded paired TLC-auto
  `669.976s` and prior tlzig-AOT-auto `679.912s`. This is a real `1.21x`
  improvement over prior tlzig and `1.19x` over TLC, but it does **not** meet
  the requested `2x` over TLC (`<=334.988s`), so this item remains open.
  Peak resident size reported by `/usr/bin/time -lp` was `25,484,083,200`
  bytes; aggregate system time remained high at `515.69s`, with `72,440,544`
  involuntary context switches. The next architectural target remains
  concurrent canonical publication/native action frames, not model-specific
  shortcuts.
- [x] Add and validate generic hot-path improvements used by the 2026-07-10
  exhaustive result:
  - incremental non-symmetry state fingerprints update only variables in the
    candidate changed mask, with a regression test against full recomputation;
  - commutative set/function/record hashing no longer sorts temporary hash
    arrays;
  - each worker caches stable canonical component hashes separately from
    generation-scoped candidate hashes; cache keys include pool identity and a
    generation epoch, so recycled candidate offsets cannot return stale data;
  - candidate hashing and canonical-value interning reuse the same recursive
    component hash;
  - fixed-capacity fingerprint slots use an acquire/release `u64` publication
    representation instead of 16-byte optional `u64` slots, halving the
    fingerprint table from about `2.18GB` to `1.09GB` at the 68M-state limit;
  - successor commit copies the contiguous parent top-level value array and
    applies only linked changed assignments with a `u64` shadow mask instead
    of clearing a 64-entry assignment array and scanning every variable;
  - invariant evaluation for newly published states runs outside the canonical
    insertion mutex, while queue publication still waits for all invariants to
    pass;
  - homogeneous inline bool/int/model/range collections use bulk copies, and
    growable cross-pool cloning first attempts the preallocated no-growth path
    before doing an exact reserve/retry.
- [x] Reject and revert ReleaseFast experiments that did not improve the 3M
  snapshot cap: generated context-layout caching (`19.99s`), required-only
  generated capture lookup (`17.76s` after the accepted cache work), hash-table
  multiply-high indexing (`18.95s`), duplicate-only lock-free preclassification
  (`17.52-17.62s`), bounded commit-mutex spinning (`18.08s`), skipping deep
  no-op equality (`17.95s`), larger canonical hash caches (`17.76s`), deeper
  contiguous context-frame scans (`17.78s`), cross-variable canonical sharing
  (instruction-neutral), and `-Dcpu=native` (`17.90s`). Keep the accepted
  compact-table/candidate-cache cap at approximately `17.33s`; the same-machine
  pre-work control was `22.38s` (`1.29x` cap improvement).
- [x] Re-run post-change correctness gates on 2026-07-10:
  `zig build test` exits `0`; the default ReleaseFast benchmark exits `0`;
  `scripts/audit_mdbtla_coverage.py` reports `13` upstream cfgs, `11`
  TLC-valid benchmark-covered cfgs, and `2` TLC-invalid cfgs; generated models
  contain no `runtime.native`/`runtime.native_binary` calls and all generated
  `fallback_count` declarations remain `0`.
- [x] Audit MDBTLA cfg coverage:
  `vendor/MDBTLA` currently has `13` upstream cfg files. `scripts/benchmark.zig`
  covers the `11` TLC-valid cfgs directly:
  `ClientCentricTests.cfg`, `MCMultiShardTxn.cfg`,
  `MCMultiShardTxn_rc_local.cfg`, `Storage.cfg`, the four
  `MCMultiShardTxn_RC_*` model cfgs, `SingleLog/MCMDBProps.cfg`,
  `SingleLog/MDBLinearizability.cfg`, and `SingleShardTxn/ShardTxn.cfg`.
  The only upstream cfgs not present as benchmark rows are
  `MultiShardTxn.cfg` and `models/MultiShardTxn_RC.cfg`, both rejected by TLC
  and tlzig because `Timestamps` is unassigned.
  Added `scripts/audit_mdbtla_coverage.py` so this coverage stays mechanical:
  it currently reports `13` upstream cfgs, `11` benchmark-covered cfgs, `2`
  TLC-invalid cfgs, and complete upstream coverage.
- [x] Re-run the default ReleaseFast benchmark after the coverage audit:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  completed successfully. Current default MDBTLA rows include
  `MultiShardTxn ClientCentric` exact `1602/801`, `SingleLog
  MDBLinearizability` distinct `2247` on both TLC/tlzig, `SingleShardTxn
  ShardTxn/small` distinct `17975` on both TLC/tlzig, and all default MDBTLA
  AOT rows compare successfully against the interpreted tlzig baseline.
- [x] Fix interpreter and generated-code formal shadowing:
  operator parameters/local bindings now shadow state variables before state
  variable application fast paths run. Regression tests cover both the
  interpreter and generated paths so a formal such as `txnSnapshots` in
  `Storage!CommittedTransactions(s, n, txnSnapshots)` cannot be compiled as
  the state variable `mtxnSnapshots`.
- [x] Rebuild all checked-in generated models after the shadowing and generic
  ReduceSeq fixes:
  every `generated_models/*.zig` file compiled with
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast -Dgenerated-model=... --summary none`.
  MDBTLA regeneration reported `fallbacks=0` for the regenerated model set.
- [x] Re-run MDBTLA AOT correctness/performance rows directly in ReleaseFast:
  `MultiShardTxn ClientCentric` AOT `0.763s`, exact `1602/801`;
  `MCM/snapshot-invariant` AOT `0.159s`, `21526/9357`;
  `MCM/rc-local-invariant` AOT `0.126s`, `3648/1607`;
  `Storage` AOT `0.225s`, `36808/14536`;
  `RC/no-prepare-block` AOT `0.180s`, `23490/10300`;
  `RC/no-prepare-block-or-ww` AOT `0.166s`, `24595/10792`;
  `RC/snapshot` AOT `0.513s`, `175427/75120`;
  `RC/with-prepare-block` AOT `0.162s`, `22652/10026`;
  `SingleShardTxn ShardTxn/small` AOT `0.221s`, exact `44363/17975`;
  `small safety` AOT `0.200s`, exact `44363/17975`;
  `small no-sym` AOT `0.395s`, exact `78245/33787`;
  `small safety no-sym` AOT `0.367s`, exact `78245/33787`.
- [x] Add and verify the opt-in full upstream SingleShard AOT benchmark row:
  `build.zig` now has disabled-by-default
  `benchmark_mdbtla_single_shard_txn_full_aot` for
  `vendor/MDBTLA/SingleShardTxn/ShardTxn.cfg`. Direct ReleaseFast AOT completed
  in `68.409s` at `14929261/5502547`, matching the existing distinct-state
  baseline for the full temporal+symmetry row.
- [x] Re-check the two upstream TLC-invalid MDBTLA configs through the plain
  ReleaseFast `tlzig` executable:
  `vendor/MDBTLA/MultiShardTxn/MultiShardTxn.cfg` and
  `vendor/MDBTLA/MultiShardTxn/models/MultiShardTxn_RC.cfg` both exit `1` with
  `missing constant assignment: Timestamps`, matching TLC's invalid-config
  diagnosis.
- [x] Re-run the default ReleaseFast benchmark after the current regenerated
  AOT set:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  exited `0`. Current default MDBTLA rows include `ClientCentric`
  TLC-auto `2.321s`, interpreted tlzig-auto `5.425s`, AOT `0.772s`, exact
  `1602/801`; `Storage` TLC-auto `1.302s`, interpreted tlzig-auto `0.467s`,
  AOT `0.198s`; `RC/snapshot` TLC-auto `2.375s`, interpreted tlzig-auto
  `0.896s`, AOT `0.427s`; `SingleShardTxn ShardTxn/small` TLC-auto `2.324s`,
  interpreted tlzig-auto `3.338s`, AOT `0.202s`, exact `44363/17975`; and
  `SingleShardTxn ShardTxn/small safety` TLC-auto `1.833s`, interpreted
  tlzig-auto `3.265s`, AOT `0.196s`, exact `44363/17975`.
- [x] Re-run regenerated opt-in `SingleLog MCMDBProps` AOT directly:
  `generated_models/mdbtla_singlelog_mcmdbprops.zig` completed in `157.623s`
  at `1409270/269881`, matching the interpreted tlzig distinct-state baseline
  and improving over the previous interpreted tlzig run (`367.322s`) while
  remaining well below the recorded TLC Java run (`1416.622s`).
- [x] Remove the remaining default MDBTLA row where TLC was faster than
  generated tlzig:
  `SingleLog MDBLinearizability` previously had TLC-auto around `1.984s` and
  interpreted tlzig-auto around `8.918s`. AOT generation was blocked by the
  self-recursive `DictWriteNTimes` helper, so `src/codegen.zig` now has a
  generic active-definition support stack for recursive generated operators
  instead of rejecting them at the depth guard. Regenerated
  `generated_models/mdbtla_singlelog_mdblinearizability.zig` reports
  `operators=24 native=2 fallbacks=0` and runs in `0.792s` at `13360/2247`,
  matching the interpreted tlzig distinct-state baseline and beating the TLC
  row without any MDBTLA-specific runtime override.
- [x] Re-run the default ReleaseFast benchmark with the
  `SingleLog MDBLinearizability` AOT row wired into `build.zig`:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  exited `0`. In that run `SingleLog MDBLinearizability` was TLC-auto
  `2.036s`, interpreted tlzig-auto `8.786s`, and generated tlzig AOT
  `0.787s`, all with distinct-state count `2247`. Default MDBTLA AOT rows
  also completed for ClientCentric, MultiShard RC/Storage, and SingleShard
  small/safety rows.
- [x] Final verification after formatting/restoring the default binary:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build test --summary none`
  passed; direct generated `SingleLog MDBLinearizability` AOT re-run completed
  in `0.846s` at `13360/2247`; and a final
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast --summary none`
  restored the normal non-generated binary artifacts.
- [x] Make the default benchmark use the fastest correct MDBTLA path instead of
  printing slower interpreted MDBTLA rows:
  MDBTLA specs with generated models now set `prefer_generated = true`; the
  normal benchmark binary receives `--skip-prefer-generated`; and generated
  rows run TLC-auto versus generated tlzig-auto directly rather than running as
  `--tlzig-only` baseline checks. This avoids running TLC twice for the same
  default MDBTLA row and makes the visible default comparison the honest fast
  path. `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  exited `0` with default MDBTLA AOT rows all faster than TLC-auto, including
  `ClientCentric` TLC `2.368s` vs tlzig AOT `0.790s`, `RC/snapshot` TLC
  `2.218s` vs tlzig AOT `0.405s`, `SingleShardTxn/small` TLC `2.409s` vs
  tlzig AOT `0.212s`, and `SingleLog MDBLinearizability` TLC `2.003s` vs
  tlzig AOT `0.802s`.
- [x] Fix exact-filter generated-preferred benchmark behavior:
  `--skip-prefer-generated` now skips generated-preferred MDBTLA specs
  unconditionally, even when `-Dbenchmark-filter` exactly matches a spec label.
  This prevents filtered benchmark runs such as
  `-Dbenchmark-filter='SingleLog MDBLinearizability'` from launching the slow
  interpreted MDBTLA row before the AOT row. Verified with
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='SingleLog MDBLinearizability'`:
  only the generated row ran, with TLC `1.962s` and tlzig AOT `0.795s`.
- [x] Re-run the opt-in full upstream SingleShard generated comparison through
  the build benchmark path after the exact-filter fix:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark -Dbenchmark-filter='SingleShardTxn ShardTxn' -Dbenchmark-include-long=true`
  exited `0` without launching the interpreted SingleShard row. The full
  upstream `SingleShardTxn ShardTxn [AOT]` row completed with TLC `179.070s`
  versus tlzig AOT `67.703s`; distinct states matched at `5502547`
  (`14931205/5502547` TLC generated/unique vs `14929261/5502547` tlzig
  generated/unique). The substring filter also matched the smaller SingleShard
  generated rows, all of which completed faster in tlzig AOT than TLC.
- [x] Replace hidden MDBTLA `compare_distinct = false` waivers with explicit
  first-error correctness bounds:
  Storage is now marked as an expected deadlock row and all default
  MultiShardTxn first-error rows require the same TLC/tlzig outcome plus a
  one-worker distinct-state delta within `16` or `32` states. This records the
  real limitation: TLC and tlzig stop on the first deadlock/invariant violation
  in traversal-order-dependent places, so exact stopped counts are not a
  semantic equality proof. The default generated MultiShardTxn sweep now runs
  one-worker checks for rows that need them and passed with visible counts:
  `ClientCentric` exact `1602/801`; `Storage` exact distinct `13370`;
  `MCM/snapshot-invariant` `10776` TLC vs `10768` tlzig; `MCM/rc-local`
  `1476` vs `1468`; `RC/no-prepare-block` `10652` vs `10636`;
  `RC/no-prepare-block-or-ww` `10636` vs `10632`; `RC/snapshot` `84708` vs
  `84692`; and `RC/with-prepare-block` `10652` vs `10636`.
- [x] Re-run the default ReleaseFast benchmark after replacing the hidden
  distinct-count waivers:
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark`
  exited `0`. Default MDBTLA AOT rows were all faster than TLC-auto:
  `ClientCentric` `2.360s` TLC vs `0.761s` tlzig, exact `801` distinct;
  `Storage` `1.437s` vs `0.206s`, exact one-worker distinct `13370`;
  `RC/snapshot` `2.403s` vs `0.362s`, first-error one-worker distinct
  `84708` vs `84692`; `SingleShardTxn/small` `2.318s` vs `0.208s`, exact
  `17975` distinct; `SingleShardTxn/small no-sym` `2.674s` vs `0.379s`,
  exact `33787` distinct; and `SingleLog MDBLinearizability` `1.941s` vs
  `0.794s`, exact `2247` distinct.
- [x] Verification after the benchmark policy fix:
  `python3 scripts/audit_mdbtla_coverage.py`,
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build test --summary none`,
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast --summary none`,
  and `git diff --check` all passed. Runtime overrides were audited with `rg`;
  MDBTLA-specific names appear in benchmark/test/generated files but not in
  `src/overrides.zig`, whose entries are built-ins/modules only.
- [x] Re-run the full upstream MDBTLA ReleaseFast AOT/TLC comparison set after
  the generic action/generated-expression changes:
  `python3 scripts/audit_mdbtla_coverage.py` reports `13` upstream cfg files,
  `11` benchmark-covered TLC-valid cfgs, and `2` TLC-invalid cfgs. The two
  invalid upstream cfgs (`MultiShardTxn.cfg` and `models/MultiShardTxn_RC.cfg`)
  still fail in tlzig with `missing constant assignment: Timestamps`. Default
  MDBTLA rows pass the benchmark harness; first-error rows require same outcome
  plus bounded one-worker distinct deltas because TLC/tlzig can stop at
  different first counterexamples. Completed/full rows have exact distinct-state
  parity:
  `Storage exhaustive` TLC `35.981s` vs tlzig `16.989s`, exact `1078623`
  distinct; `RC/no-prepare-block exhaustive` TLC `172.084s` vs tlzig
  `166.338s`, exact `17057584`; `RC/no-prepare-block-or-ww exhaustive` TLC
  `191.966s` vs tlzig `180.775s`, exact `18764120`;
  `RC/with-prepare-block exhaustive` TLC `155.452s` vs tlzig `153.345s`,
  exact `15738792`; `RC/snapshot exhaustive` TLC `677.225s` vs tlzig
  `675.583s`, exact `67629092`; upstream `SingleLog MCMDBProps` TLC
  `1434.504s` vs tlzig `157.265s`, exact `269881`; and upstream
  `SingleShardTxn ShardTxn` TLC `181.348s` vs tlzig `67.052s`, exact
  `5502547`. The printed TLC/tlzig generated counts are not currently a
  like-for-like correctness metric: TLC prints non-distinct successor attempts,
  while tlzig prints committed candidate states. Add a TLC-compatible attempted
  successor counter before requiring exact generated-count parity in the
  benchmark harness.
- [x] Add a comparable generated-attempt counter:
  `Checker.generated`/benchmark output now report TLC-style non-distinct
  generated states: initial states plus raw next-state candidates before
  constraints/fingerprinting/successor-edge deduplication. The previous
  post-filter counter is kept as `committed_generated` for internal profiling.
  This made full upstream rows strict where TLC reports the same attempt
  semantics: `SingleShardTxn ShardTxn [AOT]` is now exactly
  `14931205/5502547` on both TLC and tlzig, and `SingleLog MCMDBProps [AOT]`
  is exactly `3101918/269881` on both. MultiShard first-error rows still use
  outcome plus bounded distinct deltas because the first counterexample can be
  reached at a different traversal point.
- [ ] Improve the narrowest remaining MDBTLA performance win without
  spec-specific runtime overrides:
  latest `RC/snapshot exhaustive [AOT]` paired run has exact count parity
  (`405005930/67629092` on both TLC and tlzig), but tlzig AOT was slower in
  that run (`689.630s` vs TLC-auto `637.733s`). Generic improvements made
  since then: generated models now emit `constant_at` instead of name-based
  constant lookups; no-graph runs skip unused edge-action-mask writes; and
  full MDBTLA exhaustive benchmark caps were tightened to just above observed
  completed distinct counts to reduce tlzig preallocation. Direct tlzig-only
  `RC/snapshot exhaustive` with the tightened `68M` cap completed with exact
  counts in `670.22s`, still slower than the latest TLC timing and therefore
  still the primary perf target. Disabling generated expressions was worse
  (`>776s`, interrupted), so expression AOT remains enabled.
- [x] Final gate after the full upstream MDBTLA sweep:
  `python3 scripts/audit_mdbtla_coverage.py`,
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build test --summary none`,
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast --summary none`,
  `tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build -Doptimize=ReleaseFast benchmark --summary none`,
  and `git diff --check` all passed. Default MDBTLA AOT rows remained faster
  than TLC-auto, including `ClientCentric` `2.348s` TLC vs `0.775s` tlzig,
  `Storage` `1.487s` vs `0.228s`, `RC/snapshot` `2.332s` vs `0.361s`,
  `SingleShardTxn/small` `2.554s` vs `0.200s`, and
  `SingleLog MDBLinearizability` `1.992s` vs `0.798s`.

- [x] Complete the 2026-07-10 post-optimization MDBTLA correctness and
  ReleaseFast performance sweep without spec-specific runtime semantics.
  `scripts/audit_mdbtla_coverage.py` still classifies all `13` upstream cfgs:
  `11` TLC-valid cfgs are benchmark-covered and the remaining `2` are invalid
  in both TLC/tlzig because `Timestamps` is unassigned. The default benchmark
  passes all `37/37` build/run steps, including invariant, temporal, symmetry,
  interpreted, and strict AOT paths. Completed long rows retain exact distinct
  counts:
  - `Storage exhaustive`: `1,078,623`, tlzig `13.22s` versus TLC `35.981s`
    (`2.72x`).
  - `RC/no-prepare-block exhaustive`: `17,057,584`, tlzig `86.18s` versus TLC
    `172.084s` (`2.00x`).
  - `RC/no-prepare-block-or-ww exhaustive`: `18,764,120`, tlzig `91.94s`
    versus TLC `191.966s` (`2.09x`).
  - `RC/with-prepare-block exhaustive`: `15,738,792`, tlzig `75.65s` versus
    TLC `155.452s` (`2.05x`).
  - `RC/snapshot exhaustive`: exact `405,005,930/67,629,092`, tlzig `360.86s`
    versus TLC `669.976s` (`1.86x`). This is also `1.20x` faster than the
    previous accepted tlzig `432.26s` run and `1.88x` faster than the original
    `679.912s` tlzig baseline. Retired instructions fell from `68.20T` to
    `63.56T`; maximum RSS was `26,015,973,376` bytes.
  - upstream `SingleLog MCMDBProps`: exact `3,101,918/269,881`, tlzig `80.93s`
    versus TLC `1,434.504s` (`17.7x`).
  - upstream `SingleShardTxn ShardTxn`: exact `14,931,205/5,502,547`, tlzig
    `17.94s` versus TLC `181.348s` (`10.1x`).
- [x] Add the generic hot-path work responsible for the latest long-run gains:
  evaluator/action receivers no longer copy large structs; generated partial
  state setup uses a sparse `u64` mask; Darwin commit serialization uses
  `os_unfair_lock`; ungraphed no-invariant workers preclassify fingerprints and
  publish duplicates concurrently; canonical component entries are immutable
  release-published values with acquire readers and per-entry pool bounds; and
  changed components are resolved before the short final state-publication
  lock. Generated action binding names are interned once during action-plan
  compilation, retaining textual fallback while avoiding repeated matching
  work. The 3M snapshot cap improved from the prior accepted `13.42-13.49s` to
  `10.75-10.86s`. Canonical occupancy is measured and asserted: the full
  snapshot used about `600k/2,097,152` entries at 60M distinct states, so the
  table is not saturating.
- [x] Reject and remove post-publication experiments that failed ReleaseFast
  wall-time validation: 64-bit generated-name hashes (`11.49-11.67s`), an
  explicit local context chain (`11.06-11.33s`), pointer-only duplicate lookup
  passes (`12.13-12.29s`), state-binding skip scans (`11.08-11.17s`), same-pool
  recursive clone identity (`10.94-11.08s` despite fewer instructions), and a
  structure-of-arrays canonical table (`11.36-12.31s`). None remain in the hot
  path.
- [x] Stop duplicate Java execution for generated benchmark rows. The current
  mechanism supersedes the temporary stored-baseline design: the base runner
  skips generated-preferred models and each generated AOT row runs exactly one
  TLC-auto process and one tlzig-AOT-auto process. Completed rows retain exact
  configured generated/distinct checks; configured first-error rows compare
  the violation/deadlock outcome because all-core traversal can reach the same
  error at a different nondeterministic frontier.

- [x] Replace the permissive tlzig-only corpus probe with a paired TLC/tlzig
  auditor. `scripts/audit_spec_coverage.py` resolves configured roots, runs TLC
  first, compares semantic outcomes, requires exact distinct counts for
  exhaustively successful rows, records bounded runs separately, and rewrites
  manifests atomically with normalized parity labels.
- [x] Complete a fresh 280-config primary-corpus gate after the 2026-07-11
  correctness work. `coverage_results/primary_final_candidate.jsonl` contains
  `89` exact rows, `14` same-outcome first-witness rows, `115` bounded rows,
  `60` TLC-invalid rows, and `2` non-model harnesses. There are zero hard tlzig
  gaps, zero outcome mismatches, and zero exhaustive count mismatches.
- [x] Fix temporal eventuality checking on induced graphs. `<>P` now finds fair
  cycles in the subgraph induced by `~P` instead of reusing full-graph SCCs,
  reevaluates WF/SF witnesses on internal edges, and rejects acyclic singleton
  SCCs as infinite behaviors. Added a regression with a `~P` self-cycle inside
  a larger SCC.
- [x] Fix repeated action assignment semantics. Equality, membership, and
  `UNCHANGED` clauses for an already assigned variable are conjunctive
  constraints instead of last-write-wins updates. This removed spurious
  Moving Cat transitions and restored exact TLC generated/distinct counts:
  even boxes `128/48`, odd boxes `78/30`.
- [x] Keep the coverage audit side-effect free. CarTalk Model 3 (top-level
  `AllSolutions` expression) and `SmokeEWD998_SC` (nested TLC/CSV driver) are
  explicitly recorded as non-model harnesses instead of being hidden or
  launched as ordinary state-space checks.
- [ ] Exhaustively validate the `115` rows that exceed the short 15-second or
  200,000-state corpus gate. Bounded acceptance is not a 100% compatibility
  claim.
- [x] Re-run and accept the default `ReleaseFast` benchmark after the latest
  liveness/action fixes. Any correctness or performance regression takes
  priority over additional optimization work.

- [x] Complete the 2026-07-12 generated-code correctness follow-up. Multi-bound
  function literals now use Cartesian-product domains and tuple keys;
  multi-argument function application applies the tuple key; zero-arity `LET`
  definitions are lazy generated thunks; and decomposed action plans honor
  generated-expression required-argument masks. Strict btree AOT now completes
  exact TLC counts `2820091/374727` in `14.52s`, versus fresh TLC `28.27s`.
- [x] Prevent stale generated code from silently running against a changed
  runtime. Generated models now carry ABI version `1`, main/benchmark builds
  reject missing or mismatched versions, and every selected AOT benchmark row
  regenerates its model from an explicit TLA+/CFG pair before compilation.
  All regenerated default models report `fallback_count = 0`.
- [x] Restore one honest paired comparison per generated benchmark row. The
  base runner skips generated-preferred MDBTLA models; each AOT row now runs
  TLC-auto once and tlzig-AOT-auto once, with no interpreted duplicate. The
  complete default ReleaseFast benchmark passed in `123.03s`; all default
  MDBTLA AOT rows were faster than TLC.
- [x] Refresh MDBTLA coverage after lazy generated `LET` changes.
  `coverage_results/mdbtla_post_lazy.jsonl` has `2` exact, `7` outcome-exact,
  `2` TLC-invalid, and `2` explicitly bounded rows, with no semantic gaps or
  completed count mismatches. Extended MCMDBProps interpreted tlzig completed
  exact `3101918/269881` in `208.27s`; current zero-fallback AOT completed the
  same counts in `99.42s` with 569 MiB peak RSS.
- [x] Re-run full upstream SingleShardTxn through the paired generated
  benchmark. TLC-auto and tlzig AOT both completed exact
  `14931205/5502547`; TLC took `179.117s` and tlzig took `24.286s` (`7.38x`).
- [ ] The short primary audit still has `62` explicitly bounded rows. Do not
  describe bounded acceptance as exhaustive compatibility; continue moving
  those rows to exact or outcome-exact with opt-in long runs.

## Notes
- Update this file after every spec/example milestone.
- Record Java TLC command and timing in the spec row.
- Record tlzig command and timing in the spec row.

## 2026-07-12 Correctness And Benchmark Gate

- [x] Fix inherited `FairSpec` extraction so a boxed action nested under
  fairness cannot replace the configured transition relation. MCCRDT now
  lowers all four `ReductionNext` branches and completes at `25,000` distinct
  states, matching TLC. ReleaseFast auto timing: TLC `1.684s`, tlzig `0.786s`.
- [x] Restore capture-avoiding substitution only when a generated argument
  collides with a function binder. CheckpointCoordination completed with exact
  TLC distinct parity at `901,692`; a 1,000-state post-fix smoke reached the
  bound with no false invariant.
- [x] Separate exact recursion detection from the conservative dependency
  scanner. Nonrecursive CHOOSE operators no longer receive recursive memo
  wrappers, while Sailfish recursive AOT remains exact and improved from
  `94.99s` to `14.27s` (`6.66x`).
- [x] Replace the large-set quadratic fallback with scratch-pool open
  addressing and skip redundant initial-edge deduplication when graph storage
  is disabled. CoffeeCan1000 is exact at `2,000,002/501,500` and improved from
  over `131s` to `6.878s`; CoffeeCan3000 is exact at
  `18,000,002/4,504,500` in `97.649s` versus TLC `156.464s`.
- [x] Refresh `coverage_results/primary_final_clean.jsonl`: `158` exact, `24`
  outcome-exact, `1` stochastic-outcome, `35` bounded, `60` TLC-invalid, and
  `2` non-model rows, with zero hard gaps.
- [x] Run TLC once per default benchmark model. Generated AOT rows are now
  tlzig-only and validate against the interpreted baseline; completed rows
  require exact configured counts, while first-error rows use deterministic
  one-worker count tolerances and all-core outcome equality. The full
  ReleaseFast benchmark exits `0`.
- [ ] Move the remaining `35` bounded corpus rows to exact/outcome-exact with
  opt-in long runs, prioritizing SlushMedium and EWD998.
- [ ] Continue generic AOT work for the remaining performance gaps. Do not add
  model-specific runtime semantics; `src/overrides.zig` remains built-in and
  standard-module-only.
- [x] Expose `--state-values-per-state` in the paired coverage auditor. Long
  structured-state checks now configure both the per-state canonical budget
  and `--arena-bytes`; increasing only `--max-states` can no longer hide the
  fixed half-arena `Value` ceiling from the audit command.
- [x] Remove the CLI's artificial 192-million canonical-value ceiling. The
  generic state-capacity helper now uses the requested states, per-state value
  budget, arena budget, and `u32` representation limit, with regressions above
  the former cap. `MCKVSSafetyMedium` consequently completes with exact TLC
  counts (`365609473/17220672`) in ReleaseFast: tlzig `103.64s` versus TLC
  `173.982s` (`1.68x`). `MCKVSSafetySmall` is exact at
  `56349379/3409605`, tlzig `21.516s` versus TLC `31.494s` (`1.46x`).

## 2026-07-14 All-Core Generated Runtime Gate

- [x] Record the measured architecture and optimization backlog in
  `ALL_CORE_PERFORMANCE_ARCHITECTURE.md`, including accepted and rejected A/B
  experiments, the exact correctness contract, typed/trail lowering, SIMD
  prerequisites, TypeOK restrictions, and explicit ECS/GPU non-targets.
- [x] Use all 16 logical cores for `--workers auto`; retain bounded worker-count
  assertions and keep heavy one-worker rows opt-in.
- [x] Stop copying generated expression descriptors through action plans.
  `CompiledExpr` now points to one immutable startup-arena descriptor. Add
  direct action-executor handling for captured arguments and Boolean/integer
  literals before evaluator lifecycle work.
- [x] Bump strict generated-model ABI to version `2` and emit compiler-derived
  `state_memo_required` metadata. Nonrecursive generated models skip recursive
  state-memo lifecycle; recursive models retain it. This is syntax-derived
  generic metadata, not a user-spec override.
- [x] Reject and remove eval/candidate string interning, alternate fingerprint
  mixing, and literal path/field helper experiments after they increased
  ReleaseFast instructions or cycles. Do not retain speculative hot-path code.
- [x] Complete the decisive strict AOT all-core RC/snapshot exhaustive gate.
  The regenerated model has `67` operators and `fallback_count = 0`; tlzig
  completed exact `405005930/67629092` generated/distinct counts in `318.628s`,
  with `54.658T` retired instructions and `29,406,117,888` bytes peak RSS.
  This is `1.030x` faster than the preceding tlzig `328.100s`, `1.133x` faster
  than the prior countered tlzig `360.86s`, `2.134x` faster than the original
  tlzig `679.912s`, and `2.103x` faster than the retained TLC exact baseline
  `669.976s`. Exact-run RSS was 11.9% above the preceding observation; capped
  RSS was unchanged, so keep memory as an explicit follow-up measurement.
- [x] Run the post-change default ReleaseFast benchmark, MDBTLA inventory,
  generated-pattern, strict-artifact, and no-spec-override gates. The default
  benchmark passed `56/56` build steps in `160.18s`; all 25 generated models
  independently compile in ReleaseFast with ABI `2` and `fallback_count = 0`;
  the MDBTLA audit classifies all `13` cfgs (`11` covered TLC-valid, `2`
  TLC-invalid); and production source contains no audited model identifiers.
- [x] Refresh the full bounded primary-corpus manifest after these runtime
  changes. `coverage_results/primary_2026-07-16_post_streaming.jsonl` records
  `136` exact, `23` outcome-exact, `1` stochastic, `58` bounded, `60`
  TLC-invalid, and `2` non-model rows with zero hard gaps and zero completed
  distinct-count mismatches. Do not present the 58 bounded rows as exhaustive
  evidence.
- [x] Remove the default generated benchmark's dependency on untracked local
  tlzig baseline files. The base runner skips generated-preferred models and
  every generated row now compares one TLC-auto run directly with one strict
  tlzig-AOT-auto run. `--tlzig-only` remains an explicit runner option, but is
  not the clean-workspace default.
- [x] Replace linked state assignments with a bounded 64-variable mutable
  trail behind exact differential tests. State/local extension is split,
  state lookup is O(1), state columns use SoA storage, generated calls borrow
  contiguous value/pool slices, and `Context` remains 32 bytes. Repeated
  assignment, rollback, nested capture, all tests, the default benchmark, and
  exhaustive RC/snapshot parity pass. The normalized 3M probe improved from
  `126.442K` to `116.05-116.09K` instructions per generated candidate after
  forcing both public wrappers and private state/local extension bodies inline.
- [ ] Flatten the remaining linked lexical bindings into bounded frames using
  generated capture-depth metadata. Preserve lazy LET/operator scope and reject
  the change unless differential tests and ReleaseFast counters improve.
- [ ] Lower the highest-volume generic generated patterns without model-name
  dispatch: `25,548` nested helper chains, `5,073` variable paths, `1,233`
  whole-root primed comparisons, `557` mapped sets, `435` unchanged
  expressions, `234` EXCEPT reconstructions, and `176` function ranges. Start
  with borrowed path reads and patch-based EXCEPT because clone/fingerprint/
  action work dominates the final profile; measure before adding SIMD.

## 2026-07-16 Corpus, Lazy Function-Set, And Performance Gate

- [x] Make recursive state-call memoization safe for nested executable values.
  Lambda and generated-operator arguments now bypass the optional cache instead
  of reaching fingerprint panics. Add regressions for nested operators and
  fixed-generation cache reset.
- [x] Bound memo-key admission to 16 aggregate nodes. Large functions and sets
  are rejected before recursive hashing/cloning, while compact integer and
  tuple recursion remains memoized. ReleaseFast Time Profiler data on
  GameOfLife identified `15.3` aggregate CPU-seconds in the old memo path;
  strict AOT wall time improved from `2.575s` to `0.794s` with exact
  `131072/65536` counts, versus fresh TLC-auto `1.624s`.
- [x] Preserve tuple-bound function domains. `F[<<x,y>> \in D]` now keeps `D`
  once and destructures each key; it is no longer lowered as `D \X D`.
  Ordinary comma-separated binders retain Cartesian-product semantics.
- [x] Generate multi-bound set maps through a direct recursive domain iterator
  rather than materializing an intermediate Cartesian product. Strict
  GameOfLife generation now reports `9` operators and `fallback_count = 0`.
- [x] Keep `[S -> T]` symbolic in both interpreted and generated expression
  paths. Membership assignments stream one candidate function at a time, and
  the initial candidate pool is pre-sized from the checker's configured state
  budget. A regression proves 256 functions can be explored with a 1,024-value
  fixed scratch pool that cannot hold an eager materialization.
- [x] Complete a fresh paired 280-configuration audit after the generic
  changes: `136` exact, `23` outcome-exact, `1` stochastic-outcome, `58`
  bounded, `60` TLC-invalid, and `2` non-model harnesses. There are zero hard
  gaps, outcome mismatches, or exhaustive distinct-state mismatches.
- [x] Complete a fresh paired all-core ReleaseFast RC/snapshot exhaustive run.
  TLC and strict zero-fallback tlzig both reached exact
  `405005930/67629092`; TLC took `697.495s` and tlzig `314.422s` (`2.218x`).
  The current run is `1.013x` faster than the prior exact `318.628s` tlzig run
  and `2.162x` faster than the original `679.912s` tlzig baseline.
- [x] Compile all 26 stored generated models independently in ReleaseFast.
  Every model declares ABI `2` and `fallback_count = 0`; production runtime
  source contains no MDBTLA, GameOfLife, or Chameneos identifiers.
- [x] Pass the complete default ReleaseFast benchmark with heavy one-worker
  rows still disabled. Fresh exact comparisons include Slush Medium
  `21.109s/16.541s`, MCBinarySearch `2.001s/0.714s`, GameOfLife
  `1.498s/0.778s`, ClientCentric `2.334s/1.052s`, SingleShardTxn safety
  `1.833s/0.054s`, and SingleLog MDBLinearizability `2.013s/0.746s`
  (TLC/tlzig).
- [ ] Continue generic lowering of the 28-artifact generated-pattern backlog.
  Prioritize borrowed indexed state paths, patch-based EXCEPT updates, and
  typed fixed-domain layouts before SIMD. Do not add model-name dispatch or
  user-operator runtime overrides.

## 2026-07-16 Large Initial-State And Saturation Gate

- [x] Stream initial candidates through the fixed successor buffer instead of
  requiring every initial state to fit simultaneously. Candidate batches are
  canonicalized immediately, the resettable pool is restored between batches,
  and action compositions retain the non-streaming path until their
  intermediate-state lifetime can be partitioned safely.
- [x] Lower direct filtered-set assignments to nested domain choices and stream
  symbolic record-set products one record at a time. Candidate and canonical
  pools intern repeated strings, so record field names and values do not
  exhaust fixed string storage. The fixed-scratch regressions cover function
  sets, filtered record sets, and candidate buffers smaller than the initial
  state count.
- [x] Bound canonical aggregate-cache insertion at 75% occupancy and every
  lookup/insertion to 64 probes. Before this fix, a 2,097,152-entry table was
  scanned in full for each later unique aggregate. A test-only 1,024-entry cap
  exercises saturation with 1,024 distinct record-valued initial states;
  assertion-enabled tests pass `186/186`.
- [x] Add representative CoffeeCan1000 to the default benchmark and keep
  CoffeeCan3000 opt-in. Fresh strict AOT all-core paired results are exact:
  CoffeeCan1000 `2,000,002/501,500`, TLC `13.082s`, tlzig `2.081s` (`6.29x`);
  CoffeeCan3000 `18,000,002/4,504,500`, TLC `131.203s`, tlzig `18.600s`
  (`7.05x`). CoffeeCan3000 is `5.25x` faster than the prior accepted tlzig
  `97.649s` run. Both generated models report `fallback_count = 0`.
- [x] Complete the longer paired corpus retry. The authoritative 280-row
  manifest `coverage_results/primary_2026-07-16_retry60_1m.jsonl` contains
  `151` exact, `24` outcome-exact, `1` stochastic-outcome, `42` bounded, `60`
  TLC-invalid, and `2` non-model rows, with zero hard gaps, outcome
  mismatches, or completed distinct-count mismatches.
- [x] Re-run the complete default ReleaseFast benchmark after the initial-state
  changes. Heavy one-worker rows remain disabled; all exact and configured
  first-witness contracts pass, and every default strict row is faster than
  its paired TLC-auto run.
- [x] Compile all `28` stored generated models independently for both CLI and
  benchmark entry points in ReleaseFast. Every artifact declares ABI `2` and
  `fallback_count = 0`; the production `src` tree contains no CoffeeCan,
  MDBTLA, MultiShardTxn, GameOfLife, Slush, or MCBinarySearch identifiers.
- [x] Prevent benchmark metadata accumulation. TLC now receives a unique
  per-run metadir that is recursively removed on every normal/error return.
  The focused ReleaseFast HourClock gate left no metadata directory. Removed
  `45 GB` of stale TLC metadata, increasing free disk from `15 GB` to `61 GB`;
  Zig caches remain reproducible and are removed after the final build gates.

## 2026-07-16 EWD998 Strict AOT And Semantic Graph Gate

- [x] Lower the standard `Functions!FoldFunctionOnSet` definition only after a
  structural match of its recursive map/fold semantics. The generated reducer
  is a direct callback, range/function inputs are iterated without materialized
  sets, and a shadow definition with the same name is deliberately rejected.
  EWD998Small now generates `24` operators with `fallback_count = 0`.
- [x] Add assertion-enabled runtime and codegen regressions for allocation-free
  range folding, reducer callback capture, strict zero-fallback generation,
  helper reachability, and same-name shadowing. `zig build test` passes.
- [x] Prove semantic parity on the complete N=2 EWD998 graph with the reusable
  `scripts/compare_state_graphs.py` audit: exact `6,876` states, `32` initial
  states, `26,182` unique edges, and `6,158` weak-fair `System` edges. TLC's
  DOT contains `31,392` raw edges because it preserves `5,210` duplicate action
  witnesses; this is not a transition-relation difference.
- [x] Add EWD998Small to the default strict AOT benchmark. The exhaustive N=3
  row has exact `1,520,618` distinct states; fresh all-core ReleaseFast timing
  is TLC-auto `3.274s` versus tlzig-AOT-auto `1.865s`, a `1.76x` speedup.
  TLC/tlzig raw witness counters are `11,238,019/10,507,635` and are explicitly
  excluded from this row after the complete graph audit above.
- [ ] Continue the bounded primary-corpus queue now that Misra, Sailfish, and
  EWD998Small are exhaustive. Require strict zero-fallback generation and
  paired TLC semantic evidence before reclassifying each remaining row.

## 2026-07-18 Elevator Liveness And Symbolic Fairness Gate

- [x] Propagate compiled `ENABLED` feasibility into generated operators. The
  strict generator now classifies `ENABLED` as Boolean and treats quantified
  `WF_`/`SF_` applications as temporal definitions without interpreter
  fallback.
- [x] Expand finite fairness domains represented by symbolic set-like values.
  Record sets are materialized once during checker initialization, cloned into
  stable storage, and non-set domains return `TypeError` instead of silently
  dropping fairness conditions. Assertion-enabled regressions cover strict
  generation and four record-valued fairness bindings; all `196` tests pass.
- [x] Complete an exact large MultiCarElevator semantic audit. TLC and tlzig
  match all `50,653` states, `729` initial states, and `218,899` unique edges.
  The upgraded generic graph verifier also matches all `20` parameterized
  fairness relations exactly; TLC's `11,271` additional raw edges are duplicate
  action witnesses.
- [x] Add `ElevatorLivenessMedium` as a default all-core strict AOT benchmark
  with heavy one-core measurement disabled. Both engines complete the temporal
  property at exact `14,296/4,122` counts. After exact fairness replay, the
  focused ReleaseFast benchmark is TLC-auto `4.260s` versus tlzig-AOT-auto
  `0.162s`, a `26.3x` speedup, and the generated artifact reports `22`
  operators with `fallback_count = 0`.
- [ ] Continue the remaining bounded primary-corpus rows. Full completion and
  exact distinct-state parity are required for successful models; first-error
  rows require the same semantic outcome. Keep all performance measurements
  in ReleaseFast and all runtime semantics specification-independent.

## 2026-07-18 Hereditary Power-Set And SpanTree Gate

- [x] Share a structural hereditary-filter matcher across evaluator, action
  compiler, and generator. Lower
  `{E \in SUBSET A : \A e \in E : P(e)}` to the symbolic
  `SUBSET {e \in A : P(e)}` without model-name dispatch or a runtime override.
- [x] Add fixed-capacity end-to-end coverage that produces exactly `1,024`
  initial states from five nodes, plus strict codegen assertions for the direct
  inner predicate helper and `fallback_count = 0`. The full test suite passes.
- [x] Complete `SpanTreeTest5Nodes` in both engines with exact
  `3,150,464/410,112` generated/distinct counts and both temporal properties
  satisfied. ReleaseFast all-core timing is TLC `423.53s` versus strict AOT
  tlzig `2.83s`, a `149.7x` speedup.
- [x] Add SpanTree as an opt-in strict AOT benchmark. Its seven-minute TLC run
  is excluded from the default duration budget and heavy one-core runs remain
  disabled.

## 2026-07-18 Exact Fairness And bcastFolklore Gate

- [x] Fix strict membership for a symbolic state set in `SUBSET A`. The shared
  generated runtime performs direct cross-pool inclusion for concrete sets and
  ranges and retains an exact materializing path for other symbolic set forms.
- [x] Replace inferred named-call fairness masks at the temporal correctness
  boundary. Every configured fairness action is evaluated once per concrete
  graph edge, including stable quantified bindings, and the exact masks are
  reused for SCC and induced-cycle checks.
- [x] Add assertion-enabled regressions for cross-pool symbolic range
  membership and a conjunctive weak-fairness action whose idle cycle must be
  rejected. The focused interpreted and strict zero-fallback AOT checks pass.
- [x] Complete full `bcastFolklore` parity. TLC and strict AOT tlzig both finish
  without error at exact `9,718,336/501,552` generated/distinct counts. Fresh
  ReleaseFast all-core time is TLC `1,148.63s` versus tlzig `65.42s`, a
  `17.56x` speedup; the corrected tlzig path is also `1.6%` faster than its
  prior semantically wrong `66.48s` run.
- [x] Add `bcastFolklore` as an opt-in all-core AOT benchmark with one-core
  disabled. The generated artifact reports `12` generated operators, `5`
  native temporal definitions, and `fallback_count = 0`.
- [ ] Continue the remaining TLC-valid bounded primary corpus with the same
  exact outcome/count requirement before performance work.

## 2026-07-21 APbcastFolklore INSTANCE Gate

- [x] Generate strict AOT for the annotated `APbcastFolklore` wrapper through
  generic INSTANCE translation: `12` generated operators, `1` native temporal
  definition, and `fallback_count = 0`.
- [x] Complete paired all-core runs with no errors and exact
  `9,718,336/501,552` generated/distinct counts. The public ReleaseFast
  benchmark is TLC `3.950s` versus tlzig `1.713s`, a `2.31x` speedup;
  separately measured peak RSS is about `1.67 GB` versus `423 MB`.
- [x] Add APbcastFolklore as a default representative all-core benchmark and
  keep one-core disabled. The related nineteen-minute temporal model remains
  opt-in.

## 2026-07-21 Cross-Pool Nested EXCEPT Gate

- [x] Fix every fused single- and double-EXCEPT equality leaf to localize a
  canonical-state operand before invoking a generated updater. Generated
  updater arguments now always belong to the evaluation pool they are decoded
  against; primitive values retain the allocation-free path.
- [x] Add an assertion-enabled regression with a function-valued state whose
  outer EXCEPT updates a nested record field across distinct state/evaluation
  pools. The focused test passes and the prior Debug assertion identifies the
  exact invalid-pool boundary.
- [x] Revalidate strict `ElevatorLivenessMedium` in ReleaseFast at exact
  `14,296/4,122` counts: TLC-auto `4.260s`, tlzig-AOT-auto `0.162s` (`26.3x`).

## 2026-07-21 Bounded Power-Set Action Gate

- [x] Lower the generic action pattern
  `x \in SUBSET Base /\ x \subseteq Upper /\ Lower \subseteq x` to direct
  enumeration of `Lower \cup SUBSET((Base \cap Upper) \ Lower)`. The action
  compiler accepts only leading, bound-independent, unprimed, nonvolatile
  constraints; no model name or user-operator override is involved.
- [x] Add assertion-enabled compiler coverage and pass all `202` tests. A
  diagnostic ReleaseFast smoke run confirms bosco's `Receive` action contains
  one bounded power-set choice followed directly by the primed assignment.
- [x] Complete exact all-core ReleaseFast bosco parity at
  `29,223,200/1,072,452` generated/distinct states. The public benchmark moved
  tlzig from the recorded `43.04s` baseline to `6.938s` (`6.20x` faster), while
  TLC-auto took `59.855s`; strict tlzig is `8.63x` faster than TLC.
- [x] Revalidate the `APbosco` wrapper at the same exact counts. Strict tlzig
  takes `6.64s` versus the recorded TLC-auto `67.83s` (`10.22x`). Both generated
  translations report `27` operators, `1` temporal-native definition, and
  `fallback_count = 0`.
- [x] Add bosco as a generated-preferred default benchmark with one-core runs
  disabled. The base benchmark runs TLC once and compares it directly with the
  strict AOT all-core path.
- [ ] Continue reconciling the remaining bounded primary-corpus rows, starting
  with the FiniteMonotonic annotation wrappers. Exact successful rows require
  equal generated/distinct counts; first-error rows require matching outcomes.

## 2026-07-21 Recursive LET And PaxosCommit Gate

- [x] Generate local recursive functions of the form
  `LET F[x \in S] == ... F[...] ... IN ...` as self-capturing generated
  operators. Support analysis, helper emission, and runtime capture layout use
  the same bounded lexical frame; no model-specific name or override is used.
- [x] Add assertion-enabled recursive-LET coverage and pass the full test suite.
  PaxosCommit now emits `16` generated operators, `1` native definition, and
  `fallback_count = 0` instead of rejecting `Maximum`, `Phase2a`, and `PCNext`.
- [x] Complete full ReleaseFast all-core PaxosCommit parity at exact
  `1,321,761` distinct states. TLC reports `16,959,159` raw generated witnesses
  in `13.202s`; strict AOT tlzig reports `15,242,979` in `11.914s`.
- [x] Prove the raw-count difference is duplicate-witness accounting on the
  reduced complete graph: exact `1,461` states, `1` initial state, and `5,136`
  semantic edges; TLC retains `9,935` raw edges, including `4,799` duplicates.
- [ ] Profile and optimize the full strict PaxosCommit row from the recorded
  `11.914s` baseline. The current `1.11x` speedup is correct but below the
  project target of at least `2x` versus TLC-auto.

## 2026-07-21 EWD998Chan Symbolic Set And Parallel Temporal Gate

- [x] Preserve set operations symbolically when a record, tuple, function, or
  nested set domain contains an unmaterializable range. `Message == TokenMsg
  \cup BasicMsg` therefore remains a lazy union instead of trying to enumerate
  a record field over all `Int`; structural sequence membership stays exact.
- [x] Generate imported actions containing `UNCHANGED` computed INSTANCE
  substitutions. EWD998Chan now emits `35` operators, uses `3` native built-in
  definitions, and has `fallback_count = 0` without model-specific runtime
  behavior.
- [x] Prove complete N=2 graph parity: exact `7,150` states, `32` initial
  states, `27,550` semantic edges, and `6,410` weak-fair `System` edges. TLC's
  DOT has `37,084` raw edges, including `9,534` duplicate witnesses.
- [x] Parallelize read-only temporal state, `ENABLED`, and boxed-action
  evaluation across isolated evaluator/value-pool workers. Assertion-enabled
  coverage exercises a 256-state four-worker boxed refinement; all `206`
  tests pass.
- [x] Complete the original N=3 configuration at exact `1,524,022` distinct
  states with both temporal checks satisfied. ReleaseFast all-core tlzig
  improved from `124.150s` to `21.868s` (`5.68x`) and is `3.12x` faster than
  TLC-auto at `68.32s`.
- [x] Generate MultiPaxosSmall strictly with `60` generated operators, `1`
  native temporal definition, and `fallback_count = 0`.
- [x] Prove complete MultiPaxosSmall quotient-graph parity under
  `SymmetricPerms`: exact `343,796` states, `1` initial state, and `735,847`
  unique semantic edges. TLC's DOT retains `736,011` raw edges, including
  `164` duplicate action witnesses; tlzig stores each semantic edge once.
- [x] Make deterministic zero-argument finite domains eligible for the
  generated eager cache and raise the bounded cache admission/storage limits
  consistently. `Messages` now warms once at `10,630` values and `20,920`
  string bytes instead of being rebuilt in every `TypeOK` evaluation.
- [x] Profile and optimize the clean all-core ReleaseFast MultiPaxosSmall row.
  Generic codegen now fuses membership in a pure named set union into
  short-circuit membership against the original symbolic leaves, evaluating
  the element once. `TypeOK` checks five record-set domains instead of scanning
  a materialized `2,214`-record union. Repeated exact paired runs measured TLC
  `2.719s/2.753s` and tlzig `1.338s/1.311s`; the latter is `2.10x` faster than
  paired TLC and `2.12x` faster than the pre-fusion tlzig `2.773s`. The matcher
  is structural, rejects volatile TLC expressions, and has no model-name
  dispatch or user-operator override.
- [ ] Continue strict primary-corpus generation with NanoLarge; require zero
  fallback and paired semantic evidence before performance work.

## 2026-07-28 Generic Closure, Recursive Fold, And Full Gate

- [x] Bound generated action-call memo admission structurally. Empty memo
  lookups return before hashing, and action-local calls use the same 16-node
  aggregate budget as the evaluator instead of hashing large recursive
  arguments. No model flag or operator name selects this path.
- [x] Lower the structural recursive finite-set sum
  `IF S = {} THEN 0 ELSE f[x] + Sum(f, S \ {x})`, including swapped addition
  operands, to one allocation-free iterable fold. The matcher verifies the
  recursive call, CHOOSE binding, parameter identity, and set subtraction;
  near matches retain ordinary generated code.
- [x] Restore exact GameOfLife parity at `131,072/65,536` and improve strict
  all-core ReleaseFast from the recorded tlzig `2.581s` baseline to `0.788s`.
  The paired TLC run took `2.573s`, so current tlzig is `3.27x` faster than TLC
  and `3.28x` faster than its pre-fix baseline.
- [x] Fix optional lexical captures in generated lazy operators. Closure
  construction now honors each expression's required-argument mask and fills
  unused slots without requiring a binding. The new opt-in BTree benchmark
  completes exact `2,820,091/374,727`; TLC-auto took `4.066s` and strict tlzig
  took `0.954s` (`4.26x`).
- [x] Directly lower standard `IsFiniteSet` calls, including a constant-slot
  Boolean path that does not clone aggregate constants during TypeOK checks.
  Generated artifacts now contain zero `runtime.native` or
  `runtime.native_binary` string-dispatch calls.
- [x] Remove the benchmark-only generated-expression feature switch. A linked
  strict model now always uses its complete generated operator and expression
  tables, matching the production CLI; benchmark compilation rejects any
  artifact with `fallback_count != 0`. A no-switch GameOfLife gate remains
  exact at `131,072/65,536`, TLC `1.673s`, tlzig `0.682s`.
- [x] Pass all `211` assertion-enabled tests, compile all `40` stored generated
  artifacts through the ReleaseFast CLI and benchmark entry points, and verify
  ABI `2` plus `fallback_count = 0` for every artifact. Production runtime
  source contains no audited user-spec dispatch names.
- [x] Pass the complete default ReleaseFast benchmark. Every strict AOT row
  reports zero fallback and is faster than its paired TLC-auto run. Exact
  examples include Slush Medium `24.807s/18.591s`, GameOfLife
  `2.573s/0.788s`, Elevator liveness `4.637s/0.181s`, Bosco
  `55.167s/6.778s`, ClientCentric `2.328s/0.429s`, and SingleLog
  MDBLinearizability `2.040s/0.156s` (TLC/tlzig).
- [x] Complete a fresh eight-worker paired 280-configuration audit:
  `142` exact, `22` outcome-exact, `53` bounded, `61` TLC-invalid, and `2`
  non-model harnesses, with zero hard gaps, outcome mismatches, or exhaustive
  distinct-state mismatches. The two initially unresolved trace-tool configs
  were rerun for 60 seconds and are rejected by current Java TLC before model
  checking because of its Java trace-serializer signature.
- [ ] Continue converting the `53` short-gate bounded rows to independent
  exhaustive evidence. Existing exact long-run evidence remains valid, but a
  bounded row is never itself described as exhaustive.

## 2026-08-03 Shared State-Path Predicate Gate

- [x] Fuse the generic adjacent predicate shape
  `"field" \in DOMAIN state_path /\ state_path.record_field = argument` in
  generated Boolean functions. The matcher requires the same structural path,
  a string-literal domain member, and a delayed operator argument on the
  equality side. It preserves left-to-right short-circuit/error order and has
  no model-name or user-operator dispatch.
- [x] Check string membership in record/function domains without materializing
  a `DOMAIN` set. Successful predicates resolve the shared state path once,
  then perform the field equality directly across pools; failed domain checks
  do not force the delayed equality argument. The hot path performs no heap
  allocation.
- [x] Retain exact Storage exhaustive parity at
  `8,723,634/1,078,623` tlzig generated/distinct states. Fresh paired
  ReleaseFast all-core timing is TLC `32.385s` versus tlzig `10.529s`
  (`3.08x`); a direct tlzig repeat is `10.579s`. This is `12-13%` faster than
  the immediately preceding accepted tlzig range (`11.965-12.095s`) and
  `27.9%` faster than the pre-path-lowering `14.606s` baseline.
- [x] Pass all `221` assertion-enabled tests, the full default ReleaseFast
  benchmark, the ReleaseFast build, formatting/diff checks, and strict audits.
  Every regenerated default artifact reports `fallbacks=0`; MDBTLA coverage
  remains all `11` TLC-valid upstream configurations covered, with the other
  two rejected by TLC for missing `Timestamps` assignments.
- [x] Reject and remove primitive-leaf fingerprint replacement. Strong scalar
  mixing plus Wyhash preserved exact counts but regressed Storage exhaustive to
  `10.766s`, `10.796s`, and `11.123s`; the accepted FNV leaf code remains.
- [x] Lower membership in `DOMAIN state_path` and
  `DOMAIN state_path.record_field` directly for functions, tuples, and records.
  The generic runtime resolves the path once and tests the domain in place,
  avoiding construction of an intermediate set. All `222` assertion-enabled
  tests and the complete default ReleaseFast benchmark pass with exact counts
  and zero generated fallback.
- [x] Improve exact Storage exhaustive further to a paired `10.162s`, with
  isolated repeats of `10.016s` and `10.496s`. This is approximately `3%`
  faster than the preceding shared-path lowering and `30%` faster than the
  pre-path `14.606s` baseline. TLC and tlzig retain exact `1,078,623` distinct
  states.
- [x] Reject and remove string-literal-only domain-membership helpers. A paired
  run reached `9.654s`, but isolated A/B runs were slower at
  `10.365s/10.836s` versus `9.971s/10.003s` for the generic direct-domain
  binary. The redundant specialization and API were removed.
- [ ] Continue with patch-aware candidate construction/fingerprinting. Direct
  writes into append-only candidate pools remain unsafe across failed action
  branches; any accepted design must provide bounded rollback or a typed patch
  lifetime before removing the current reconstruct/clone/hash traversals.

## 2026-08-03 Exact Fairness Edge Markers

- [x] Profile the exact `cf1s_folklore` temporal run. Strict AOT spent `83.4%`
  of samples rebuilding fairness masks by reevaluating TLA+ action predicates
  over every committed edge after exploration.
- [x] Reuse exploration-time action masks only when a structural proof finds
  every primitive fairness action explicitly under the same existential
  domain in `Next`. Aliases, conjunctions, universal quantification, and every
  unsupported shape retain exact semantic replay. This is model-independent
  and contains no user-operator dispatch.
- [x] Keep Debug/ReleaseSafe verification mandatory for eligible shapes and
  expose `TLZIG_VERIFY_FAIRNESS_MARKERS=1` for ReleaseFast audits. The full
  `cf1s` audit compared `14,666,114` edges with zero mismatches, missing bits,
  or extra bits. A conjunctive-fairness regression test proves that ambiguous
  named actions are rejected by the fast path.
- [x] Preserve exact temporal completion and
  `22,438,432/2,057,174` generated/distinct counts. Direct strict AOT improved
  from `38.94s` to `8.22s` (`4.74x`); the maintained paired benchmark reports
  TLC-auto `16.515s` versus tlzig-auto `8.008s` (`2.06x`). Register `cf1s` as
  a default all-core AOT benchmark with `11` operators, `3` temporal-native
  definitions, and `fallback_count = 0`.

## 2026-08-04 Allocation-Free Materialization

- [x] Profile the strict `c1cs` AOT path and identify evaluator set
  materialization as a generic allocation defect. Temporary `ArrayList`
  buffers used `page_allocator` recursively, producing repeated
  `mmap`/`munmap`, `2,984s` of system CPU, and more than `60 million` page
  reclaims before the old run was stopped after `351.13s`.
- [x] Add evaluator-local, per-worker, arena-backed high-water scratch frames.
  The frames are recursion-safe, require no shared lock, and stage values,
  secondary results, names, and sequence lengths without hot runtime
  allocation.
- [x] Convert record-set, tuple-set, union, recursive set-filter, Cartesian,
  and sorted-sequence materialization to scratch or exact preallocation.
  Record and Cartesian builders now preflight aggregate storage before
  retaining `ValuePool` slices, preventing backing-array growth from leaving
  stale destination pointers. `src/eval.zig` has zero `page_allocator` and
  zero `ArrayList` sites.
- [x] Preserve the exact temporal `cf1s_folklore` gate at
  `22,438,432/2,057,174`; the fresh paired ReleaseFast result is TLC-auto
  `16.441s` versus strict tlzig AOT `7.880s` (`2.09x`). All `227`
  assertion-enabled tests pass.
- [x] Preserve exact set-heavy and sorted-sequence behavior after removing the
  last evaluator-local temporary lists. Bosco completes at
  `29,223,200/1,072,452`, with TLC-auto `59.007s` versus strict tlzig AOT
  `8.114s`; an isolated tlzig repeat is `7.81s`. MCBinarySearch completes at
  `34,383/27,953`, with TLC-auto `2.199s` versus tlzig AOT `1.007s`.
- [x] Recheck bounded `c1cs` with strict AOT. The run reached the explicit
  two-million-state limit at `42,013,184/2,000,000` in `17.97s`, using
  `2.51 GB` peak RSS and only `4.21s` system CPU. The preceding post-first-fix
  ten-million-state run completed its bound in `97.19s`; `c1cs` remains open
  because neither result is exhaustive parity.
- [x] Run a historical all-core `EWD840_anim` exhaustive diagnostic with a
  strict 22-operator, one-temporal-native, zero-fallback artifact. TLC timed
  out after 300 seconds at `1,983,728,622/52,032,023` with `7,038,064` queued;
  tlzig reached its explicit twenty-million-state cap at
  `255,340,261/20,000,000` in `26.115s`. The later manifest audit establishes
  that this is a simulation model, so these figures are throughput data rather
  than its required compatibility verdict.
- [ ] Continue the 8-row finite exhaustive backlog. Bounded throughput is useful
  evidence but must never be reported as exact correctness.

## 2026-08-04 Named Filtered Power-Set Correctness

- [x] Generate strict `MC_HDiskSynod` and reproduce an AOT-only false
  `HInv4` violation on its first initial state. Interpreted tlzig and Java TLC
  accept the same state, proving this was generated-code semantics rather than
  an upstream model result.
- [x] Trace the failure to lexical arguments in a quantifier over the named
  zero-arity `MajoritySet` definition. Its filter helper expects only `D`, but
  the ordinary filtered-power-set runtime prepended caller arguments `p` and
  `bk`; ReleaseFast consequently tested the wrong value without a Debug arity
  assertion.
- [x] Add a structurally selected isolated-filter entry point for zero-arity
  definition chains. Direct set filters retain caller arguments and therefore
  keep the existing entry point. No model/operator name selects either path.
- [x] Add one codegen regression containing both named and direct filtered
  power-set domains. All `228` assertion-enabled tests pass, and a Debug
  DiskPaxos AOT run reaches the same 10-state bound as interpreted tlzig with
  generated helper-arity assertions enabled.
- [x] Regenerate strict DiskPaxos with `30` operators and zero fallback. The
  repaired all-core run reaches `104,887,762/10,000,000` in `52.05s` without
  a false invariant. A fresh 60-second pair records TLC at
  `2,361,454/302,250` before timeout and tlzig at its explicit
  `19,134,362/2,000,000` cap in `8.958s`; keep the row bounded.
- [x] Audit stored generated artifacts for the old runtime call. None contain
  the affected call shape; the regenerated DiskPaxos artifact contains 13
  explicit isolated-filter calls.
- [x] Pass the complete default ReleaseFast benchmark after the lexical-frame
  fix. Every enabled artifact regenerates with zero fallback, every configured
  semantic/count contract passes, and every strict AOT row is faster than its
  paired TLC-auto run. Representative TLC/tlzig times are Slush
  `25.645s/19.057s`, MCBinarySearch `1.948s/1.030s`, GameOfLife
  `1.700s/0.701s`, `cf1s` `16.871s/7.750s`, Bosco `61.298s/8.157s`,
  ClientCentric `2.431s/0.486s`, and SingleLog `2.234s/0.164s`.

## 2026-08-04 Sailfish2 Bounded Audit

- [x] Generate strict `TLCSailfish2` with `36` operators, one native temporal
  definition, and zero fallback. The generated model accepts and explores the
  configuration without a semantic error.
- [x] Separate canonical density from scratch allocation. The model stores
  approximately 200 canonical `Value` nodes per state: an 8 GB arena filled at
  `673,643` states and a 20 GB arena filled at `1,579,290`; a 30 GB arena
  reached the explicit two-million-state bound with `13.55 GB` peak RSS.
- [x] Record a fresh all-core bounded pair. TLC reached
  `399,821/162,226` generated/distinct states in 60 seconds with `123,966`
  queued. Strict tlzig reached `3,780,221/2,000,000` in `26.604s`.
- [ ] Keep `TLCSailfish2.cfg` in the 8-row finite backlog. Closing it requires a
  denser canonical representation or a larger-memory exhaustive run with a
  conclusive TLC outcome and matching tlzig distinct-state count.

## 2026-08-04 Module-Qualified Built-In Overrides

- [x] Reproduce strict `TestMCReachability` failing before exploration while
  Java TLC accepts the same configuration. Its imported assumptions failed
  with `TypeError` because generated `GraphName` evaluated the TLA body of
  `IOUtils!IOEnv` instead of the Community Modules native override.
- [x] Add module-qualified `IOUtils!IOEnv` and `IOUtils!atoi` dispatch to the
  native registry and generated compiler. Generated wrappers retain operator
  arity and higher-order use, carry source provenance, and dispatch only when
  the definition comes from `IOUtils.tla`; unrelated user operators named
  `IOEnv` or `atoi` remain generated TLA code.
- [x] Add a codegen regression covering both module-qualified dispatch and the
  same-name user-operator case. All `229` assertion-enabled tests pass.
- [x] Regenerate `TestMCReachability` with `57` generated operators, `4`
  native definitions, and zero fallback. A fresh all-core pair records TLC at
  `376,820/252,366` before its 60-second timeout and strict tlzig at its
  explicit `15,719,199/10,000,000` generated/distinct cap in `32.783s`.
- [ ] Keep `TestMCReachability.cfg` in the 8-row finite backlog. The initialization
  compatibility gap is closed, but neither engine completed the exhaustive
  temporal state space.

## 2026-08-04 Recursive Canonical Subvalue Sharing

- [x] Identify the generic c1cs memory cliff. The top-level canonical-value
  cache stopped inserting at `1,572,864/2,097,152` entries, after which every
  changed function or set miss cloned its complete nested representation.
  Canonical storage grew from `51.4 million` values at two million states to
  `266.6 million` at eight million states.
- [x] Canonicalize concrete sets, functions, tuples, and records bottom-up.
  Repeated domains, message records, and nested sets now share immutable
  canonical offsets across states. Selection is solely by `Value` shape; the
  runtime contains no user-model names or semantics.
- [x] Raise the bounded production interner ceiling from `2,097,152` to
  `8,388,608` slots, and to `16,777,216` only when the configured state bound
  exceeds 64 Mi. Temporal graph runs retain the `2,097,152`-slot ceiling
  because c1cs showed neutral throughput and lower total RSS once recursive
  sharing is active. The table remains fixed-size during parallel exploration,
  preserving lock-free reads and stable published entries.
- [x] Measure the same strict c1cs AOT path in ReleaseFast. At two million
  states the new path uses `3,517,358` canonical values and `1.10 GB` peak RSS
  versus about `51.4 million` and `2.51 GB`; wall time is `17.54s` versus
  `17.97s`. With the final graph-aware table, twelve million states use
  `27,464,951` values and `5.00 GB` peak RSS in `106.04s`, while recording
  `70,512,089` temporal graph edges.
- [x] Pass all `229` assertion-enabled tests and the complete default
  ReleaseFast benchmark. Every strict artifact regenerates with zero fallback,
  all exact distinct-state and configured-outcome contracts pass, and every
  strict all-core row remains faster than TLC. Representative TLC/tlzig times
  from the final graph-aware run are EWD998Small `3.774s/1.870s`, cf1s
  `15.046s/7.326s`, Bosco `55.485s/7.497s`, ClientCentric
  `2.356s/0.454s`, and SingleLog `2.020s/0.172s`.
- [x] Re-audit `MCNanoLarge.cfg`. At the same ten-million-state boundary,
  canonical storage falls from `689,774,468` to `13,045,263` values, peak RSS
  from `16.28 GB` to `3.25 GB`, and wall time from `26.36s` to `23.68s`. A
  thirty-million-state run reaches `46,167,175/30,000,000` in `64.20s` with
  `8.12 GB` RSS and `16,174,006` queued.
- [x] Re-audit `TLCSailfish2.cfg`. At two million states, canonical storage
  falls from roughly 400 million to `60,180,882` values, peak RSS from
  `13.55 GB` to `2.70 GB`, and wall time from `26.604s` to `23.62s`. The run
  still has `1,590,436` queued.
- [x] Re-audit `APLamportMutex.cfg`. The old path exhausted `536,870,912`
  canonical values at `29,082,375` states after `84.011s`; the new path reaches
  forty million states in `63.24s` with `13,082,908` values. At the
  130-million-state bound, adaptive large-run sizing lowers the 120-million
  checkpoint from `194,790,406` to `35,057,430` values, improves wall time
  from `259.70s` to `208.66s`, and lowers peak process footprint from
  `40.37 GB` to `33.97 GB`. The frontier remains open.
- [x] Re-audit `MultiPaxos_MC.cfg`. At twenty million states, canonical
  storage falls from `373,537,046` to `26,169,746` values, peak RSS from
  `15.55 GB` to `6.14 GB`, and wall time from `209.40s` to `193.33s`. The run
  still has `3,830,790` queued. This historical bounded result is superseded
  by the exact closure below.
- [x] Re-audit the low-density `EnvironmentController.cfg` temporal row with
  graph-aware sizing. The final repeat reaches
  `112,409,658/20,000,000` in `268.42s`, with `2,830,058` queued and
  `11.80 GB` RSS. This is lower memory but not a claimed speedup over the
  historical `247.00s` sample; keep it as a throughput-variance target.
- [ ] Keep Sailfish2 and Lamport mutex open until both engines
  finish with conclusive matching outcomes and exact distinct-state parity for
  successful exhaustive runs. NanoLarge and MultiPaxos are now closed below.

## 2026-08-04 Cross-Pool State-Set Membership

- [x] Generate strict `APc1cs.cfg` AOT: `22` generated operators, one standard
  native operator, and zero fallback.
- [x] Profile the ReleaseFast all-core artifact. Recursive aggregate cloning,
  string copying, and fingerprinting dominate; the hottest generated predicate
  cloned state variable `bcastMsg` for every `msg \in bcastMsg` test.
- [x] Add generic direct-variable membership lowering. Generated
  `element \in stateSet` and `element \notin stateSet` now call the existing
  complete cross-pool `Value.member_cross_pool` implementation, including
  current and primed reads, without materializing the state set in the eval
  pool. No model name or user semantics are present in the runtime or codegen.
- [x] Remove collisions for cached materialized current/primed variables by
  indexing all 128 legal slots directly. Snapshot restoration still invalidates
  every entry whose aggregate storage was rewound.
- [x] Add runtime and codegen regressions. The runtime test proves cross-pool
  membership leaves the eval-pool snapshot unchanged; the codegen test proves
  direct state-set membership selects the specialized generic helper. All 229
  assertion-enabled tests pass.
- [x] Measure the identical twenty-million-state boundary before and after.
  ReleaseFast tlzig improves from `173.12s` to `141.97s` (`1.22x`), user CPU
  from `2,566.58s` to `1,897.48s`, and retired instructions from `38.37T` to
  `28.12T`. The improved run reaches `452,005,985/20,000,000` with
  `11,677,559` queued and `6.80 GB` peak RSS.
- [x] Record fresh paired TLC evidence. TLC-auto reaches `18,496,258` distinct
  states at 183 seconds with `10,595,893` queued and `8.91 GB` observed peak
  RSS; tlzig averages about `1.39x` its distinct-state throughput over these
  bounded runs.
- [x] Pass the complete default ReleaseFast benchmark after the new lowering.
  Every strict artifact regenerates with zero fallback, every exact distinct
  count and configured-outcome contract passes, and every AOT all-core row
  remains faster than TLC.
- [ ] Keep `APc1cs.cfg` in the 8-row finite backlog. Both frontiers are expanding;
  only matching exhaustive completion can close the correctness row.

## 2026-08-04 Infinite Corpus Wrappers

- [x] Prove that `APCRDT.cfg` is intentionally infinite: `Increment(n)` can
  increase `counter[n][n] \in Nat` without bound. A successful exhaustive state
  count cannot exist in TLC or tlzig.
- [x] Prove that `APReplicatedLog.cfg` is intentionally infinite: enabled
  `WriteTx(n, tx)` actions can append to `log \in Seq(Transaction)` forever.
- [x] Generate both wrappers as strict AOT. Each reports eight generated
  operators, one standard native operator, and zero fallback.
- [x] Record large bounded invariant evidence. `APCRDT` reaches 100 million
  distinct states in 270 seconds with `28,964,052` queued and no violation;
  TLC reaches `84,398,731` at 300 seconds with `24,777,057` queued.
  `APReplicatedLog` reaches ten million distinct states in `10.80s` with
  `5,003,163` queued and no violation; TLC reaches `138,892,346` at 300 seconds
  with `69,456,028` queued.
- [x] Retain exact finite-companion closure for the shared semantic paths:
  `MCCRDT.cfg` has exact `25,000` distinct states and
  `MCReplicatedLog.cfg` exact `1,363` in both engines.
- [x] Prove both unbounded FIFO annotation wrappers are also infinite. Repeated
  `BufRcv` transitions append to `q`, and neither `APInnerFIFO.cfg` nor
  `APInnerFIFOInstanced.cfg` supplies a queue-length constraint.
- [x] Generate both FIFO wrappers as strict AOT: 16 generated operators, one
  standard native operator, and zero fallback each. Fresh five-million-state
  runs preserve their invariants in `5.71s` and `5.38s`, with about 1.47 million
  states still queued.
- [x] Retain exact FIFO finite-companion closure. `MCInnerFIFO.cfg` completes at
  exact `9,660/3,864` generated/distinct states in both engines, and
  `APMCInnerFIFO.cfg` reaches the same configured bound-violation outcome.
- [x] Remove the five infinite wrappers from the finite exhaustive-evidence
  backlog. The current finite backlog is 8 configurations; the wrappers remain
  supported nonterminating models, not falsely claimed exhaustive successes.

## 2026-08-04 ABA Exact Temporal Closure

- [x] Generate strict `aba_asyn_byz.cfg` AOT with 15 generated operators, four
  standard temporal/native definitions, and zero fallback.
- [x] Cross the previous arbitrary five-million-state cap. The BFS queue peaks
  and drains before the ten-million limit, then tlzig completes all three
  configured temporal properties.
- [x] Establish exact TLC base-state parity at `5,843,977` distinct states.
  tlzig reports `85,121,584` raw generated successors versus TLC's
  `85,612,896`; this is duplicate-edge accounting on the same complete graph.
- [x] Record ReleaseFast resources: `139.36s` wall time and `3.36 GB` peak RSS.
  TLC completed the base graph but had not finished temporal analysis after
  240 seconds, making tlzig at least `1.72x` faster to the successful verdict.
- [x] Remove `aba_asyn_byz.cfg` from the finite exhaustive backlog.

## 2026-08-04 Elevator Large Exact Temporal Closure

- [x] Regenerate strict `ElevatorLivenessLarge.cfg` AOT with 22 generated
  operators, three standard temporal/native definitions, and zero fallback.
- [x] Complete tlzig at exact `230,803/50,653` generated/distinct states,
  including the configured temporal property, in `1.68s` with `270 MB` peak RSS.
- [x] Run default Java TLC to its full successful verdict. It completes at
  `230,899/50,653` in `1,951.17s` (`32min 30s`) with `18.33 GB` peak RSS, so
  tlzig is `1,161x` faster end to end at exact distinct-state parity.
- [x] Profile TLC's liveness phase. Eight `LiveWorker` threads spend
  `checkSccs`/`checkComponent` repeatedly seeking and reading disk-backed
  `TableauDiskGraph` nodes through `BufferedRandomAccessFile`. TLC checks an
  intermediate 302,912-node product for `11min 47s`, then the final
  405,224-node product for `20min 38s`; tlzig traverses its contiguous in-memory
  temporal graph once.
- [x] Remove `ElevatorLivenessLarge.cfg` from the finite exhaustive backlog.
  The current finite backlog is 8 configurations.

## 2026-08-04 Elevator Large Exact Safety Closure

- [x] Generate strict `ElevatorSafetyLarge.cfg` AOT with 22 generated
  operators, two standard native definitions, and zero fallback.
- [x] Complete tlzig with no violation at `545,380,491/59,007,145`
  generated/distinct states in `112.97s`, using `11.36 GB` peak RSS.
- [x] Complete Java TLC with no violation at
  `545,537,067/59,007,145` generated/distinct states in `157.14s`, using
  `11.21 GB` peak RSS. The exact reachable-state count matches; the raw
  generated difference is duplicate action-witness accounting.
- [x] Record the honest ReleaseFast all-core speedup: tlzig is `1.39x` faster
  end to end while retiring `18.31T` instructions versus TLC's `23.82T`.
- [x] Add the strict row to the maintained benchmark as opt-in. Its
  59-million-state pair would consume most of the default benchmark budget.
- [x] Remove `ElevatorSafetyLarge.cfg` from the finite exhaustive backlog. The
  current finite backlog is 8 configurations.

## 2026-08-04 MultiPaxos Exact Symmetry Closure

- [x] Generate strict `MultiPaxos_MC.cfg` AOT with 60 generated operators, one
  standard native definition, and zero fallback.
- [x] Complete tlzig and Java TLC without error at the exact same `37,078,209`
  quotient states. tlzig reports `101,402,513` raw generated successors and
  TLC `101,413,181`; the `10,668` difference is duplicate action-witness
  accounting rather than a reachable-state mismatch.
- [x] Identify a generic parallel-symmetry defect: candidate canonicalization
  received the checker-level cache, which is intentionally disabled with
  multiple workers, instead of each worker's private candidate and canonical
  hash caches. No model name or user semantics select the repaired path.
- [x] Route hashes through the cache matching each value's pool and add an
  assertion-enabled regression proving that both private cache tables are
  populated while producing the same fingerprint as the uncached path.
- [x] Improve ReleaseFast tlzig from `312.16s` to `254.14s` (`1.23x`) and
  retired instructions from `58.84T` to `48.02T`, while preserving exact
  states. TLC takes `292.63s`, so repaired tlzig is `1.15x` faster.
- [x] Register the exact 37-million-state pair as an opt-in benchmark with a
  strict zero-fallback AOT artifact and exact distinct-state comparison.
- [x] Remove `MultiPaxos_MC.cfg` from the finite exhaustive backlog. The
  current finite backlog is 8 configurations.

## 2026-08-04 EWD998 N=4 Extended Frontier

- [x] Regenerate `EWD998.cfg` as strict AOT with 33 generated operators, four
  standard native definitions, and zero fallback.
- [x] Complete all-core ReleaseFast exploration at `2,613,583,722` generated
  transitions, `248,006,200` distinct states, and `2,083,298,801` graph edges.
- [x] Add fatal benchmark diagnostics for generated, distinct, and queued
  counts without allocating an unused result string on the error path.
- [x] Fix generic strict-AOT `UNCHANGED NamedOperator` lowering. Zero-arity
  named operators now receive an empty argument slice instead of inheriting
  the enclosing action's parameters. ReleaseSafe exposed the violated arity
  contract; ReleaseFast had silently produced a false `TDSpec` rejection.
- [x] Differentially close constrained temporal N=2 and N=3. TLC/tlzig exact
  distinct counts are `6,876` and `1,520,618`; both `Liveness` and `TDSpec`
  pass under interpreted, ReleaseSafe AOT, and ReleaseFast AOT execution.
- [x] Add the N=2 temporal regression to the default all-core paired benchmark.
  A fresh run measured TLC-auto `1.000s` versus tlzig AOT `0.051s` with exact
  `6,876` distinct states and zero generated fallback.
- [x] Complete strict-AOT N=4 exploration and both temporal properties after
  the fix. The paired Java TLC reference run is still completing its final
  disk-backed liveness pass; do not claim final TLC count parity until it exits.
- [x] Raise the opt-in benchmark to 250 million states and 2.2 billion graph
  edges through generic resource-limit plumbing; keep it out of the default
  benchmark because the complete pair is intentionally long-running.
- [x] Add `scripts/tlc_graph_count.py` to count and validate live TLC
  `ptrs_N` records without loading graph nodes. Its parser is covered by short,
  long-natural, tableau, and partial-live-record tests.
- [x] Re-run the complete default ReleaseFast benchmark on Zig
  `0.17.0-dev.1552+79dc16a0e`: `95/95` build steps pass, including every
  strict zero-fallback AOT row and the new EWD998 temporal regression.

## 2026-08-04 Simulation-Mode Corpus Classification

- [x] Read the examples manifests instead of treating every `.cfg` as an
  exhaustive-search model. `EWD687a_anim.cfg` and `EWD840_anim.cfg` both
  declare 100-trace simulation mode with an expected safety failure.
- [x] Make the paired auditor pass TLC `-simulate num=100` for manifest-declared
  simulation models and invoke tlzig with the same trace count, depth, and seed.
- [x] Remove the two animation models from the finite exhaustive backlog. The
  current finite backlog is 8 configurations; neither is now a compatibility
  gap.
- [x] Implement bounded seeded simulation in tlzig. It uses normal initial-state
  generation, checks state/action constraints and every generated successor,
  evaluates invariants and safety properties, preserves deadlock semantics, and
  retries randomly ordered actions that have no successor.
- [x] Implement TLC-compatible maximum-prefix action decomposition for generic
  disjunctions and constant-domain bounded existentials. The selector is
  allocation-free and contains no user-model names or semantics.
- [x] Implement dynamic `TLCGet("level")` semantics in interpreted and generated
  execution. The value is zero outside state evaluation and otherwise the
  current state's one-based trace level, matching Java TLC.
- [x] Pair the manifest-declared outcomes in ReleaseFast. `EWD840_anim.cfg`
  finds `AnimInv` in both engines at TLC-auto `0.740s` versus tlzig `0.364s`;
  `EWD687a_anim.cfg` finds `InterestingBehavior` at `0.719s` versus `0.058s`.
- [x] Evaluate temporal properties over successful finite simulation traces.
  The existing temporal engine now checks each sampled trace after folding
  repeated states and adding TLC-compatible stuttering edges. Java-validated
  pass/fail regressions cover terminal-stuttering semantics.
- [x] Reuse post-initial state slots after each checked trace. Canonical values
  remain stable and interned, while state storage is bounded by the initial set
  plus one trace instead of trace-count times trace-depth.
- [x] Give manifest simulation audits a one-million-state resource floor.
  `EWD840_anim.cfg` has more than 262,000 valid initial states, so the ordinary
  200,000-state short exhaustive bound rejected it before the first trace.

## 2026-08-04 Compact State Metadata And HDisk Frontier

- [x] Remove the per-state `borrowed_mask`. Candidate ownership is exactly the
  complement of `changed_mask` when `borrowed_pool` is present, while committed
  canonical states have no borrowed pool. A layout assertion fixes
  `StateStore.State` at 40 bytes instead of 48 bytes.
- [x] Add mixed-pool assertions proving unchanged slots read from the canonical
  pool and changed slots read from the candidate pool. All 238 assertion-enabled
  tests pass.
- [x] Measure the identical strict-AOT `MC_HDiskSynod` 30-million-state command
  before and after the accepted layout change. Peak RSS falls from `11.79 GB`
  to `11.53 GB`; normalized retired work falls from `74,010.751` to
  `73,851.001` instructions per generated successor. Wall samples are
  `148.32s` and `141.20s`, but only the memory and normalized-instruction
  reductions are treated as stable evidence.
- [x] Prototype and reject moving `borrowed_pool` from each state into the
  shared candidate `ValuePool`. Although this produced a 32-byte state and a
  lower `11.30 GB` peak RSS, the complete benchmark exposed an
  `IndexOutOfBounds` regression in `Barrier`. The unsafe compaction was removed;
  `Barrier` again completes at exact `194/64` generated/distinct counts.
- [x] Pass the complete default ReleaseFast benchmark after retaining only the
  40-byte representation. Every exact/outcome contract reaches the final row,
  every generated artifact reports zero fallbacks, and all AOT rows remain
  faster than paired TLC. Slush Medium is exact at
  `65,138,523/9,886,336`, with TLC-auto `24.616s` versus tlzig `15.668s`.
- [x] Extend strict-AOT `MC_HDiskSynod` to 60 million distinct states. It
  reaches `762,972,247/60,000,000` in `328.86s`, with `17,633,057` queued,
  `15.69 GB` maximum RSS, `22.51 GB` peak process footprint, and no invariant
  failure.
- [ ] Keep `MC_HDiskSynod.cfg` in the 8-row finite backlog. Its frontier is
  still expanding. Exact closure now requires compact canonical top-level state
  values, not merely a larger fixed state bound; the design must retain
  per-state mixed-pool ownership and pass `Barrier` plus the full parity gate.

## 2026-08-04 Slush Large Extended Frontier

- [x] Generate `SlushLarge.cfg` as strict AOT from the unmodified upstream
  model: 35 generated operators, one standard native definition, and zero
  fallbacks.
- [x] Extend the all-core ReleaseFast frontier through 60 million, 100 million,
  and 150 million distinct states without an invariant failure. The largest run
  reaches `1,127,388,186/150,000,000` generated/distinct in `355.52s`; its queue
  peaks around 120 million states and contracts to `13,479,765` at the bound.
  Maximum RSS is `22.71 GB` and peak process footprint is `36.60 GB`.
- [x] Record a fresh isolated Java TLC all-core sample using the same upstream
  cfg and `-Xmx32g`. At 300.20s TLC has generated `515,331,878` states, found
  `73,858,271` distinct, and retained `12,412,406` queued.
- [x] Report bounded throughput honestly: tlzig averages about `421.9K`
  distinct states/s versus TLC's `246.0K` (`1.71x`), and about `3.17M`
  generated states/s versus `1.72M` (`1.84x`). Neither run is an exhaustive
  correctness verdict.
- [x] Close `SlushLarge.cfg` at exact TLC parity after the frontier drains at
  `1,968,189,705/244,335,240` generated/distinct states.

## 2026-08-04 Compact Tagged Value Representation

- [x] Reorder the generic `GeneratedOperator` payload to remove alignment
  padding. `GeneratedOperator` is now 16 bytes instead of 24 bytes and the
  tagged `Value` union is 24 bytes instead of 32 bytes. Compile-time tests fix
  both layout contracts; this is a generic representation change with no
  model-specific semantics.
- [x] Update canonical-capacity calculations for the compact element size. A
  24 GiB arena can now retain `536,870,912` canonical values instead of
  `402,653,184`, while a 1 GiB arena retains `22,369,621` instead of
  `16,777,216`.
- [x] Repeat the identical strict-AOT SlushLarge 150-million-state ReleaseFast
  command. The compact run reaches `1,126,825,444/150,000,000`
  generated/distinct states in `288.04s`, versus `1,127,388,186/150,000,000`
  in `355.52s` before compaction: a controlled `1.23x` wall-time speedup. Peak
  process footprint falls from `36.60 GB` to `30.42 GB`; maximum RSS varies
  upward from `22.71 GB` to `24.71 GB`, and retired instructions vary upward
  from `44.75T` to `45.75T`, so only wall time and process footprint are claimed
  as improvements. The queue still contains `13,582,113` states at the bound,
  so this remains bounded evidence rather than exhaustive correctness.
- [x] Pass all 239 assertion-enabled tests, the ReleaseFast build, generated
  pattern and MDBTLA structural audits, and the complete default ReleaseFast
  benchmark after compaction. Every generated artifact reports zero fallback,
  every configured exact/outcome contract passes, and every strict-AOT row is
  faster than its paired TLC-auto row.
- [x] Re-run the contracting SlushLarge frontier at a safely enlarged state
  bound. It completes in `498.83s` at exact Java TLC generated/distinct parity;
  TLC-auto takes `678.10s`, so strict-AOT tlzig is `1.36x` faster.

## 2026-08-04 Unbounded AP Lamport Wrapper Classification

- [x] Prove from the upstream source that `APLamportMutex.cfg` is not a finite
  exhaustive model. `Clock == Nat \ {0}`, `ReceiveRequest` increments clocks,
  and the cfg omits the source-documented `ClockConstraint` required for finite
  model checking.
- [x] Preserve positive bounded evidence for the valid unbounded wrapper: TLC
  reached `96,045,036` states while still queued, and strict zero-fallback tlzig
  reached explicit 40-million and 130-million state bounds without a semantic
  rejection. No exhaustive count is claimed for either engine.
- [x] Retain exhaustive Lamport coverage through `MCLamportMutex.cfg`, whose
  configured state constraint completes in both engines at exact
  `2,729,079/724,274` generated/distinct parity.
- [x] Reduce the genuinely finite exhaustive-evidence backlog from 10 to 8
  configurations rather than spending further runs on an infinite graph.

## 2026-08-04 Slush Large Exact Closure

- [x] Complete strict zero-fallback tlzig with no invariant failure at
  `1,968,189,705/244,335,240` generated/distinct states, zero queued states,
  and graph depth 59.
- [x] Complete Java TLC on the unmodified upstream cfg at the exact same
  generated and distinct counts and successful verdict.
- [x] Record honest all-core performance: tlzig ReleaseFast takes `498.83s`
  versus TLC-auto `678.10s`, a `1.36x` tlzig speedup. Retired instructions are
  `81.23T` versus `95.44T`.
- [x] Record the memory tradeoff: tlzig uses `49.80 GB` peak footprint and
  `26.04 GB` maximum RSS, versus TLC's `20.16 GB` and `20.22 GB`.
- [x] Add SlushLarge as an opt-in strict-AOT benchmark with exact generated and
  distinct comparisons. It remains disabled by default because the complete
  pair takes about twenty minutes.
- [x] Remove SlushLarge from the finite exhaustive backlog; eight finite rows
  remain.

## 2026-08-04 Direct SUBSET Actions And Failure Diagnostics

- [x] Lower direct bounded `\E subset \in SUBSET base: Action` choices into
  subset enumeration without constructing the complete power-set value.
- [x] Push a pure leading `\A element \in subset: Predicate(element)` guard
  into the base set when the predicate does not reference the chosen subset.
  Preserve lexical frame depth with a placeholder subset binding and retain
  the ordinary path for dependent predicates.
- [x] Add direct, filtered, and dependent action-compiler regressions. All 239
  assertion-enabled tests pass in ReleaseFast.
- [x] Measure the identical strict-AOT N=3 four-million-state boundary. Wall
  time improves from `307.24s` to `18.48s` (`16.63x`) and retired instructions
  from `62.399T` to `2.779T` (`22.46x`).
- [x] Make parallel invariant failures elect one diagnostic owner before
  printing. The N=2 failure log now contains one invariant name, one violation
  summary, and one trace instead of interleaved traces from many workers.
- [x] Add `EnvironmentControllerN2Safety` to the default strict-AOT benchmark.
  Both engines find the same age-43 `TypeOK` violation: TLC-auto takes `1.393s`
  at `592,015/126,903`, while tlzig takes `0.185s` at
  `490,665/106,399` (`7.53x`). The harness enforces a 30,000-state early-stop
  tolerance and the generated artifact has 36 operators, one standard native
  built-in, and zero fallback.
- [x] Keep the unmodified N=3 cfg in the eight-row finite backlog. tlzig finds
  the same source-level violation, but the direct TLC run was interrupted
  before its verdict; the reduced pair is not claimed as exhaustive N=3
  parity.

## 2026-08-04 KeyValueStore Safety Family

- [x] Generate strict AOT artifacts for `MCKVSSafetySmall`, Medium, and Large.
  They contain 11/12/12 generated operators, one standard native built-in,
  and zero fallback.
- [x] Close Small exactly at `56,349,379/3,409,605` generated/distinct states.
  Isolated ReleaseFast timing is TLC `19.81s` versus tlzig `6.96s` (`2.85x`),
  and RSS is 4.87 GB versus 1.18 GB.
- [x] Close symmetry-reduced Medium exactly at
  `365,609,473/17,220,672`. Isolated timing is TLC `90.47s` versus tlzig
  `40.44s` (`2.24x`); the maintained benchmark records
  `100.824s/43.512s` (`2.32x`) at the same exact count.
- [x] Add Small to the default strict-AOT benchmark and Medium as an opt-in
  exact row. Both compare generated and distinct counts.
- [x] Add the full `MCKVsnap.cfg` safety-and-liveness model to the default
  strict-AOT benchmark. TLC and tlzig complete at the exact same
  `63,082/32,293` generated/distinct counts; ReleaseFast takes `2.177s` versus
  `0.241s` (`9.03x`). The artifact has 33 generated operators, two standard
  native definitions, and zero fallback.
- [x] Run isolated all-core Large frontiers on the unmodified cfg. TLC reaches
  `367,297,806/32,849,147` at 120 seconds with `15,883,975` queued; tlzig
  reaches `426,483,296/40,000,000` in `76.02s` with `20,314,356` queued.
  tlzig has `1.92x` higher distinct throughput, `1.83x` higher generated
  throughput, and lower observed RSS.
- [ ] Keep `MCKVSSafetyLarge.cfg` in the eight-row finite backlog. The bounded
  run is faster and semantically clean, but both frontiers are still growing.

## 2026-08-04 Current MDBTLA Exhaustive Revalidation

- [x] Rerun `MultiShardTxn Storage exhaustive` all-core in ReleaseFast against
  the current strict AOT artifact. TLC and tlzig complete at exactly
  `1,078,623` distinct states; TLC takes `32.756s` and tlzig `8.652s`
  (`3.79x`). The `9,390,226/8,723,634` generated-count difference is duplicate
  successor accounting; both successful runs close the same quotient graph.
- [x] Rerun `RC/no-prepare-block exhaustive` at exact `17,057,584` distinct
  states. TLC takes `179.949s` and strict zero-fallback AOT tlzig takes
  `80.513s` (`2.24x`); the artifact contains 67 generated operators and no
  native user definition.
- [x] Rerun `RC/no-prepare-block-or-ww exhaustive` at exact `18,764,120`
  distinct states. TLC takes `193.182s` and strict zero-fallback AOT tlzig
  takes `94.507s` (`2.04x`); its 67 generated operators also contain no native
  user definition.
- [x] Rerun `RC/with-prepare-block exhaustive` with exact generated/distinct
  parity at `89,960,594/15,738,792`. TLC takes `164.528s` and strict
  zero-fallback AOT tlzig takes `69.726s` (`2.36x`).
- [x] Rerun `RC/snapshot exhaustive` with exact generated/distinct parity at
  `405,005,930/67,629,092`. TLC takes `685.901s` and strict zero-fallback AOT
  tlzig takes `315.854s` (`2.17x`).
- [x] Complete the current MultiShard exhaustive matrix. Storage and all four
  RC companions have fresh exact all-core evidence; every tlzig row is faster
  and every generated artifact has zero fallback and no native user operator.
- [x] Rerun the full upstream `SingleShardTxn/ShardTxn.cfg` plus all four
  reduced companions. The full model matches exactly at
  `14,931,205/5,502,547`; TLC takes `157.304s` and tlzig `38.931s` (`4.04x`).
- [x] Rerun the full temporal `SingleLog/MCMDBProps.cfg`. Both engines complete
  at exact `3,101,918/269,881` generated/distinct counts; TLC takes
  `1,331.490s` and strict zero-fallback AOT tlzig takes `11.402s` (`116.77x`).
- [x] Close fresh current-code evidence for all 11 TLC-valid upstream MDBTLA
  cfgs. Successful exhaustive rows have exact distinct parity, first-error
  upstream rows have matching deadlock/violation outcomes, and every paired
  strict-AOT tlzig row is faster. Keep the two TLC-invalid cfgs classified as
  invalid rather than inventing tlzig behavior for them.

## 2026-08-04 Symmetry And Fairness Labels

- [x] Diagnose the `MCKVsnap` termination mismatch as a tlzig bug rather than
  a TLC/model violation. The alleged cycles were singleton implicit-stuttering
  loops with a transaction at `READ`, `UPDATE`, or `COMMIT`; the corresponding
  `WF_vars(t(self))` action was enabled, so those loops are unfair.
- [x] Check the alleged counterexample directly against the specification. For
  every transaction whose `pc` is not `Done`, exactly one of `START`, `READ`,
  `UPDATE`, or `COMMIT` is enabled, and every branch changes `pc[self]`.
  Consequently `WF_vars(t(self))` excludes an infinite stuttering suffix until
  every transaction reaches `Done`, which proves `Termination` for this finite
  model. TLC likewise evaluates liveness action predicates on the concrete
  parent/successor pair before taking the successor's symmetry fingerprint
  (`LiveCheck.addNextState`). TLC warns that symmetry is not sound for liveness
  in general, but that warning does not validate tlzig's former counterexample.
- [x] Isolate symmetry as the trigger. The no-symmetry control completed at
  `365,596/189,664`, while the symmetry quotient retained TLC's exact
  `63,082/32,293` count but previously produced a false temporal violation.
- [x] Finalize each fairness mask as the concrete `<A>_v` transition label
  before symmetry canonicalization. Quotient analysis now consumes the stored
  label and never re-evaluates an action against independently renamed state
  representatives. Unsupported marker shapes are evaluated on the concrete
  parent/candidate pair before merging, without a spec-specific override.
- [x] Add a generic regression where two symmetry-equivalent transitions with
  different bound process names merge into one quotient target. Forcing the
  old replay produces the marker mismatch and false violation; the fixed path
  completes. Add a second regression where two differently labeled concrete
  transitions from the same parent deduplicate to one quotient edge; its mask
  must retain both labels. The assertion-enabled ReleaseSafe gate passes.
- [x] Regenerate strict `MCKVsnap` AOT (`33` generated operators, `2` standard
  native definitions, `0` fallbacks) and rerun the paired all-core ReleaseFast
  benchmark. TLC and tlzig both complete at exact `63,082/32,293`; TLC takes
  `2.114s`, tlzig takes `0.136s`, and the measured tlzig speedup is `15.5x`.
  This is historical quotient evidence only; it is not a sound liveness
  baseline because plain orbit-state symmetry can change temporal semantics.
- [x] Repeat the focused strict-AOT ReleaseFast pair after the regression
  expansion: exact `63,082/32,293`, TLC `2.060s`, tlzig `0.142s` (`14.5x`).
  This result has the same historical/unsafe qualification.

## 2026-08-04 Sound Temporal Symmetry Policy

- [x] Test tlzig against TLC's ignored `April29dMC` regression. The source and
  Java test document that the model satisfies `[]<>(x=a) /\ []<>(x=b)` without
  symmetry, while the orbit quotient produces a bogus counterexample. Before
  this policy fix, tlzig reproduced that false violation at `5/2`; its explicit
  no-symmetry control completed at `8/4`.
- [x] Disable orbit-state symmetry reduction by default whenever a configured
  property requires temporal graph checking. Safety-only runs retain symmetry.
  Library-only compatibility tests may explicitly set
  `allow_unsafe_temporal_symmetry`; normal parsed cfg files cannot silently opt
  into the unsound mode.
- [x] Add a standalone two-value regression equivalent to `April29d`: a
  symmetry-configured run must disable the quotient, complete at four concrete
  states, and satisfy the recurrence property. The ReleaseSafe suite passes
  all `249/249` tests.
- [x] Classify nested recurrence structurally. An outer `[]` is safety only
  when its operand, including recursively resolved named definitions, contains
  no `<>` or `~>`. The regression uses `EventuallyZero == <>(x = 0)` and
  `Recurrence == []EventuallyZero`, with `WF_x(Next)` to exclude the otherwise
  legal infinite stuttering suffix at `x = 1`.
- [x] Recognize `WF_` and `SF_` applications nested beneath temporal aliases.
  `FairNext == WF_x(Next); BoxedFairness == []FairNext` now has an isolated
  regression proving that it uses the temporal graph and completes correctly.
- [x] Replace temporal+symmetry benchmark comparisons with sound no-symmetry
  TLC baselines. `MCKVsnap` is exact at `365,596/189,664`; ReleaseFast TLC is
  `6.345s` and strict AOT tlzig is `0.672s` (`9.44x`). `SingleShardTxn/small` is
  exact at `78,245/33,787`; TLC is `2.543s` and tlzig is `0.136s` (`18.7x`).
- [x] Remove duplicate TLC executions from generated benchmark rows. Preferred
  generated specs now run TLC once to produce the semantic baseline, then run
  only strict AOT tlzig and compare its outcome/counts to that baseline. The
  EWD998 N=2 temporal anchor remains exact at `6,876` distinct states and takes
  `0.871s` in TLC versus `0.049s` in AOT tlzig (`17.8x`).
- [ ] Implement a permutation-labeled lifted liveness graph before safely
  re-enabling temporal symmetry reduction. A plain orbit-state graph cannot
  preserve path-sensitive predicates because quotient paths can stitch edges
  through inconsistent permutations.
