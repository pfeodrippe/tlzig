# All-Core Performance Architecture

Date: 2026-07-16

This document is the measured plan for making tlzig faster without weakening
TLA+ semantics or encoding user specifications in the runtime. Correctness is
the first gate: an optimization is accepted only after the relevant TLC-valid
model has the same outcome and, for an exhaustive successful run, the same
distinct-state count as TLC.

## Target And Measurement Contract

- Target machine: Apple M3 Max, 16 logical/physical cores, 48 GiB RAM.
- Performance measurements use `ReleaseFast` only.
- The default performance target is all available cores. Long one-worker rows
  are opt-in and are not part of the default benchmark.
- Default generated benchmark rows run one TLC-auto and one tlzig-AOT-auto
  process directly. They do not run an interpreted tlzig duplicate or depend
  on machine-local baseline files.
- Capped probes are useful for A/B decisions, but their generated-state count
  varies with the parallel frontier. Retired instructions, cycles, generated
  and distinct counts must be reported together. An uncapped exhaustive run is
  the final performance and correctness gate.
- Generated models must report `fallback_count = 0`. Generated-model ABI
  mismatches are compile errors, not silent interpreter fallbacks.
- Runtime and built-in overrides may implement TLA+ built-ins and standard
  modules. They must not recognize model names, operator names, source paths,
  constants, or shapes from a user specification.

The decisive MultiShardTxn workload is `RC/snapshot exhaustive`:

| Measurement | Generated | Distinct | Wall time | Instructions | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Retained TLC all-core exact baseline | 405,005,930 | 67,629,092 | 669.976s | - | - |
| Fresh paired TLC all-core | 405,005,930 | 67,629,092 | 697.495s | - | - |
| Original tlzig exact baseline | 405,005,930 | 67,629,092 | 679.912s | - | - |
| Prior accepted tlzig exact | 405,005,930 | 67,629,092 | 360.86s | 63.56T | 26,015,973,376 B |
| Pre-trail tlzig exact | 405,005,930 | 67,629,092 | 334.557s | - | - |
| Initial compact-trail exact | 405,005,930 | 67,629,092 | 335.834s | 59.310T | 30,868,815,872 B |
| Refined trail before body inlining | 405,005,930 | 67,629,092 | 328.100s | 57.138T | 26,281,590,784 B |
| Prior countered tlzig exact | 405,005,930 | 67,629,092 | 318.628s | 54.658T | 29,406,117,888 B |
| Current tlzig exact | 405,005,930 | 67,629,092 | 314.422s | - | - |

The current exact run is `1.013x` faster than the preceding `318.628s` run,
`1.064x` faster than the pre-trail `334.557s` run, `1.148x` faster than the
prior countered `360.86s` run, `2.162x` faster than the original `679.912s`
tlzig baseline, and `2.218x` faster than the fresh paired `697.495s` TLC run.
The fresh pair did not collect hardware counters. The preceding `318.628s`
run remains the latest countered observation: retired instructions were 4.34%
below its predecessor and 14.0% below the older `63.56T` measurement. Its peak
RSS was 11.9% above the preceding observation; capped-probe RSS was unchanged,
so memory remains an explicit follow-up rather than a hidden regression. This
is a measured generic improvement, not a 10x claim.

The bounded 3-million-distinct probe recorded this normalized progression.
Generated-candidate counts vary slightly with parallel frontier scheduling, so
instructions per generated candidate are the comparison column:

| Stage | Instructions/generated candidate |
| --- | ---: |
| Fresh pre-trail baseline | 126.442K |
| Compact bounded state trail | 125.436K |
| Separate state/local extension | 124.79-124.82K |
| Remove impossible lexical source-pool branch | 123.041K |
| Fixed-capacity checker scratch pools | 122.814-122.822K |
| Structure-of-arrays state trail | 122.402-122.500K |
| ReleaseFast rollback without stale-slot poisoning | 122.04-122.20K |
| Inline evaluator extension wrappers | 121.15-121.92K |
| Inline private state/local extension bodies | 116.05-116.09K |

The body-inlining control retired `1.81844T` instructions for `15,016,404`
generated candidates (`121.097K` each) in `10.36s`. The two changed runs
retired `1.74174T` for `15,008,820` (`116.048K`) and `1.74450T` for
`15,027,062` (`116.091K`) in `10.13s` and `9.98s`. Normalized work is 4.13-4.17%
below that control and about 8.2% below the fresh pre-trail baseline.

## Accepted Changes

These changes are generic and survived ReleaseFast A/B measurements:

1. `auto` uses all logical cores. Worker count is bounded and asserted through
   `src/platform.zig`; there is no model-specific worker policy.
2. Generated lexical captures carry explicit depth metadata, avoiding repeated
   name resolution while preserving nested scope semantics.
3. `CompiledExpr` stores a pointer to one immutable startup-allocated generated
   expression descriptor instead of copying the descriptor through action
   plans. On the 3M probe this reduced instructions from about 2.043T to
   1.968T and wall time to 10.71-11.02s.
4. Generated argument and Boolean/integer literal expressions are evaluated
   directly by the action executor before evaluator snapshot/reset work. This
   reduced the probe to about 1.898-1.903T instructions and 10.39-10.63s.
5. Generated operator metadata records whether recursive state memoization is
   required. Nonrecursive strict AOT models skip that lifecycle. The metadata
   is derived by the compiler, encoded in generated-model ABI version 2, and
   never inferred from a model name.
6. Existing accepted generic work remains enabled: sparse `u64` partial-state
   masks, immutable release-published canonical components, changed-component
   resolution before publication, no graph writes when graph storage is not
   requested, generated constant slots, and allocation-free state-assignment
   iteration.
7. State assignments use a bounded 64-variable mutable trail with O(1) slot
   lookup and mark/rollback backtracking. `Context` remains 32 bytes, and the
   former 131,072-entry state-binding slab per evaluator is gone. Tests cover
   repeated assignment, rollback, and the context-size bound.
8. State and lexical extension are separate operations. Lexical bindings no
   longer carry an impossible alternate `ValuePool`: generated arguments are
   always eval-pool values, so depth-indexed reads avoid a branch and clone
   path that could never be valid.
9. The state trail is structure-of-arrays: names, values, source pools, and
   assignment kinds are contiguous independent columns. Generated calls borrow
   the value/pool slices directly instead of creating two 64-entry stack arrays
   for every invocation.
10. Checker scratch pools are fixed-capacity after initialization in the CLI
    and benchmark. The library remains growable by default for embedders and
    deliberately tiny structural tests; `Checker.set_scratch_growable` and the
    CLI's `--unlimited-memory` make the policy explicit.
11. ReleaseFast rollback clears the authoritative assignment mask/count but
    does not poison now-unreachable slots. Debug and ReleaseSafe retain stale
    slot clearing and assertions.
12. Small context-extension wrappers are forced inline. Their bounds and
    ownership assertions remain active in assertion-enabled builds.
13. The private state/local extension bodies are also forced inline. This lets
    ReleaseFast specialize the distinct state/local paths and removed another
    4.13-4.17% of normalized probe instructions without weakening assertions.
14. Tuple-destructuring function binders retain their single declared domain,
    and multi-bound set maps iterate domains directly without allocating an
    intermediate Cartesian product. Symbolic function-set assignments stream
    one candidate at a time, with candidate storage pre-sized from the existing
    checker budget.
15. Recursive-call memo keys have a fixed 16-node admission budget and reject
    executable values. Large aggregate arguments bypass the optional cache
    before recursive hashing/cloning; compact recursive states still use it.
    On GameOfLife this reduced strict AOT from `2.575s` to `0.794s` while
    retaining exact `131,072/65,536` counts.
16. The fixed root hash cache avalanches aggregate identity and pool identity
    before applying its direct-map mask. Aggregate offsets are stored in the
    high 32 bits; using only low identity bits caused systematic collisions
    between equal-length sets, tuples, and records. Alternating exact Storage
    runs improved from a `14.215s` control mean to `14.041s` without changing
    capacity or allocating.
17. The generator recognizes one-bound-variable filters whose predicate is a
    direct Boolean state path and emits numeric variable/argument slots plus
    literal field descriptors. The generated runtime resolves the invariant
    prefix once and streams candidates through one loop, avoiding callback,
    lexical-binding, and temporary string-value work. This is syntax-directed
    and contains no user-spec dispatch. Exhaustive Storage retained exact
    `8,723,634/1,078,623` counts and improved from `14.606s` to `11.965s`,
    versus paired TLC-auto `36.979s`; an exact repeat completed in `12.095s`.

## Rejected Experiments

Rejected experiments are removed from the production path. Keeping this list
prevents repeating attractive but slower changes.

| Experiment | Result | Decision |
| --- | --- | --- |
| Eval-pool 4K string interning | 2.017-2.021T instructions vs 1.968T | Removed |
| Candidate-pool 4K string interning | 1.914-1.925T vs about 1.889T | Removed |
| One-mix fingerprint and Wyhash strings | More instructions | Removed |
| One-mix fingerprint only | About 0.23% more instructions | Removed |
| Literal-aware path/field string helpers | 40 fused comparisons, but 1.894-1.899T and about 509B cycles vs 1.889-1.891T and about 505B | Removed |
| Candidate pre-fingerprint duplicate probe | More work on the dominant path | Removed |
| Parent batch size 1 | Worse throughput | Removed |
| Larger fingerprint cache | Worse locality | Removed |
| Physical evaluator-context split | Exact run regressed to 457.701s | Removed |
| State/constant direct descriptors | No retained ReleaseFast win | Removed |
| Tagged generated-expression union | No retained ReleaseFast win | Removed |
| Generic runtime string hashes for generated names | 11.49-11.67s probe | Removed |
| Pointer-only duplicate lookup pass | 12.13-12.29s probe | Removed |
| Structure-of-arrays canonical hash table | 11.36-12.31s probe | Removed |
| ABI-3 static string literals, prelocalized record keys, and direct hash-slot lookup | 1.8976-1.9033T instructions, 0.04-0.06% worse normalized | Removed; ABI remains 2 |
| Generation-scoped recursive value-hash memoization | NanoMedium regressed from 1.118s to 1.186s; Storage exhaustive regressed from 14.606s to 16.314s with exact counts | Removed; cache probes cost more than shared-subtree reuse saved |
| Native-Boolean set-filter callbacks | NanoMedium was 1.172s; Storage exhaustive regressed from 14.606s to 16.221s with exact counts | Removed; filter result boxing is not a decisive cost |
| Per-filter validated record-slot caches | Index-cache exact runs were 12.103s, 12.093s, and 12.358s; interned-token-cache repeats were 12.994s and 13.439s, versus the retained 11.965-12.095s direct-filter range | Removed; validation and cache state outweighed shorter field scans; revisit only with a proven typed slot |
| Candidate clone-and-fingerprint fusion | Exact five-run Storage median regressed from 11.668s to 11.823s and mean from 11.455s to 11.568s; won 2/5 pairs | Removed completely; inline hash work and cache insertion outweighed the later traversal saved |
| Whole direct-filter force-inlining | Exact five-run Storage median was effectively flat at 10.859s to 10.849s, but mean regressed from 10.694s to 10.887s and it won 2/5 pairs | Removed; specialize the post-bound field access without duplicating the entire loop |
| Nonrecursive state-filter call memoization | Three exact Storage pairs increased mean retired instructions from 1.950606T to 1.989776T (+2.008%); wall median regressed from 11.450s to 11.580s and mean from 11.553s to 12.117s | Removed completely; cloning results and memo hashing cost more than recomputing small filters |
| Separate materialized-aggregate fingerprint routines | Three exact Storage pairs increased mean retired instructions by 0.204%, wall mean by 1.030%, wall median by 0.095%, and executable size by 17,392 bytes | Removed completely; lower cycles did not compensate for worse instructions and wall time |

## Current Hot Path

The latest sampled profile is CPU-work dominated, not publication-lock
dominated. All-core utilization is roughly 14.2 cores from aggregate user time.
The main thread's large `__ulock_wait` sample is the final worker join; worker
lock waits are substantially smaller.

The final sample still shows the largest generic costs in this order:

- action-step execution;
- recursive `Value.clone_assume_capacity`;
- recursive value fingerprinting;
- generated expression evaluation;
- ordered and cross-pool equality;
- `memmove` while materializing aggregate values;
- generated path resolution and expression dispatch;
- recursive `EXCEPT` reconstruction.

The 2026-08-03 exact Storage sample, taken from the strict ReleaseFast AOT
binary, confirms the same structural boundary after the direct filter
lowering. Aggregated top-of-stack samples were led by recursive value
fingerprinting (`17,203`), cross-pool path application (`5,229`), value clone
(`4,159`), equality/memmove, and then the new direct filter loop (`2,267`).
The sample run retained exact `8,723,634/1,078,623` counts and about 1 GiB
physical footprint. Its profiler-inflated wall time is not used as benchmark
evidence. Two validated field-slot-cache designs were slower and removed.
The next high-leverage change is therefore patch-aware clone/fingerprint work,
not another lookup cache around the recursive `Value` representation.

Depth-indexed lexical lookup samples fell materially after removing the dead
source-pool path, and extension wrappers are now inlined. Invariant-loop samples
are small on RC/snapshot; most time is spent generating, cloning, hashing, and
deduplicating successors that invariants later inspect. Optimizing only the
invariant dispatch loop would therefore miss this workload's dominant cost.

The current `Value` representation is a tagged recursive tree whose aggregate
children are addressed through pool offsets. That representation is not a
useful direct SIMD target: traversal has irregular tags, lengths, branches, and
dependent loads. Applying `@Vector` to this layer would add packing work while
leaving the dominant clone/path operations intact.

The focused GameOfLife profile exposed a different, workload-specific generic
cost before the bounded memo admission change: `37.235` aggregate CPU-seconds,
of which about `15.3` seconds were recursive-call memo lookup/insert work and
`4.2` seconds were the old hashability prewalk. `Sum(sc, points)` is linear
recursion over large function/set arguments, so caching cost exceeded
recomputation. Rejecting the large key before traversal cut all-core
ReleaseFast wall time from `2.575s` to `0.794s`; a fresh paired TLC run took
`1.624s`. This is a shape/cost policy derived from bounded value size, not from
the model or operator name.

## Structural Work, In Order

### 1. Bounded State Trail (Complete)

State assignments now use this bounded mutable trail:

```text
state_values: [64]Value
state_pools: [64]*const ValuePool
assigned_mask: u64
trail: [N]RestoreRecord
mark: u32
```

An assignment records the prior slot in the trail, writes one contiguous slot,
and restores to a mark on backtracking. State-variable lookup is O(1). The
state columns are SoA and generated calls borrow them directly. Exact
RC/snapshot parity and the full benchmark gate passed after this conversion.
Lexical parameters still use linked immutable bindings; flattening those frames
is remaining work and must preserve nested capture depth and lazy thunk scope.

### 2. Flat Lexical Frames, Borrowed Reads, And Patch-Based Updates

Replace linked lexical bindings with bounded contiguous frames addressed by
the compiler's depth metadata. Generated state reads should return `(Value,
source_pool)` views whenever the consumer can compare, inspect, or hash
cross-pool data. `EXCEPT` should build a bounded path patch and materialize only
at successor commit. This avoids the current eval-pool reconstruction followed
by candidate/state-pool cloning. Lifetime rules must explicitly prohibit values
borrowed across evaluator snapshot restoration.

### 3. Typed Generated IR

Infer and validate fixed model domains at startup, then lower generated code to
typed state slots, fixed record-field indices, tuple offsets, and finite-domain
ordinals. TypeOK may authorize unchecked generated access only when the user
explicitly selects the invariant and startup validation proves the inferred
layout. A failed proof rejects specialization; it never falls back silently to
an unsound assumption.

PGO can identify hot operators and common value shapes, but PGO observations
cannot prove a type. It may guide which proven specialization to emit, not
remove semantic checks on its own.

### 4. Contiguous Batches And SIMD

After typed lowering, batch homogeneous work into contiguous arrays:

- component fingerprints for fixed state slots;
- primitive integer/Boolean invariant columns;
- finite-domain membership and equality masks;
- open-addressing probe fingerprints and occupancy metadata.

Use Zig vectors only where a scalar reference implementation and randomized
differential test demonstrate identical results. Preserve a scalar tail and
measure both retired instructions and wall time. Do not vectorize recursive
`Value` trees by first packing them into temporary arrays.

### 5. Compile-Time Literals And Constants

The attempted generic prelocalized-`Value` implementation was slightly slower
and is removed. Revisit literals only as part of typed generated IR where a
field or finite-domain ordinal can replace the recursive `Value` entirely. The
previous runtime interning and ABI-3 experiments show that adding another
lookup layer around the current representation is the wrong mechanism.

## Non-Targets

- A general ECS such as Flecs adds archetype and query machinery around a
  fixed-size model state. A purpose-built slot/trail representation gives the
  required data orientation without that indirection.
- GPU execution is not currently appropriate. Successor generation has
  irregular branching, small per-state kernels, recursive aggregates, global
  deduplication, and frequent frontier synchronization. Reconsider only after
  typed batched IR creates large homogeneous kernels whose transfer and merge
  costs can be measured.
- A runtime override for a user operator is never an optimization option.

## Verification Gates

Every accepted structural change must pass, in this order:

1. `zig build test` in the normal assertion-enabled test mode.
2. Strict generation audit: ABI current, `fallback_count = 0`, no user-spec
   identifiers in runtime dispatch.
3. Two ReleaseFast 3M all-core probes with generated/distinct counts,
   instructions, cycles, wall time, and RSS.
4. Exact TLC-valid MDBTLA rows with exact distinct-state parity. First-error
   rows compare the semantic outcome and a deterministic witness where exact
   frontier counts are not traversal invariant.
5. The default ReleaseFast benchmark, kept near the five-minute guideline and
   excluding heavy one-worker runs.
6. The primary-corpus audit. Bounded rows remain explicitly bounded and are not
   counted as exhaustive compatibility.

## 2026-07-16 Gate Results

- Assertion-enabled tests: `186/186` passed.
- Strict artifacts: all 28 stored generated Zig models independently
  compiled in ReleaseFast; every artifact declares ABI `2` and
  `fallback_count = 0`.
- MDBTLA inventory: all 13 upstream configurations are classified; 11
  TLC-valid configurations are benchmark-covered and two are invalid in TLC
  because `Timestamps` is unassigned.
- Runtime override audit: MDBTLA, MultiShardTxn, MCBinarySearch, and EWD998
  identifiers occur under `src` only in parser tests. Production overrides are
  TLA+/TLC built-ins and standard-module operators.
- Decisive exhaustive result: fresh exact paired
  `405,005,930/67,629,092`; TLC `697.495s`, tlzig `314.422s` (`2.218x`).
- Primary corpus: all 280 configurations classified with zero hard gaps and
  zero completed count mismatches (`151` exact, `24` outcome-exact, `1`
  stochastic, `42` bounded, `60` TLC-invalid, `2` non-model harnesses).
- Default ReleaseFast benchmark passed and contains no heavy one-worker rows.
  Strict exact rows include Slush Medium (`21.109s/16.541s`), MCBinarySearch
  (`2.001s/0.714s`), GameOfLife (`1.498s/0.778s`), ClientCentric
  (`2.334s/1.052s`), and SingleLog MDBLinearizability (`2.013s/0.746s`),
  reported as TLC/tlzig.

Large initial-state products now stream through fixed-size candidate batches.
Filtered record sets iterate their original domains directly, repeated strings
are interned in resettable/canonical pools, and canonical aggregate caching
stops inserting at 75% occupancy with a hard 64-probe bound. This removes an
unbounded open-addressing failure mode without model-specific dispatch.
CoffeeCan1000 is exact at `2,000,002/501,500`, TLC/tlzig
`13.082s/2.081s` (`6.29x`). The opt-in CoffeeCan3000 row is exact at
`18,000,002/4,504,500`, `131.203s/18.600s` (`7.05x`); current tlzig is `5.25x`
faster than its prior `97.649s` baseline.

The generated-pattern audit now provides a concrete compiler backlog across 28
artifacts: 25,684 nested runtime-helper chains, 5,073 generic variable paths,
1,237 whole-root primed comparisons, 557 generic mapped-set constructions, 435
generic `UNCHANGED` expressions, 236 generic `EXCEPT` reconstructions, and 176
materialized function ranges. Counts are syntactic opportunities, not assumed
speedups; each lowering still requires differential tests and ReleaseFast A/B
evidence.

References: [TigerBeetle TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
and [Zig vectors](https://ziglang.org/documentation/master/#Vectors).

## 2026-07-28 Structural Gate

- Action-local memoization now rejects large aggregate keys after a bounded
  structural walk and returns immediately for an empty table.
- Recursive finite-set sums lower to a contiguous iterator loop with a scalar
  accumulator; no intermediate set difference or recursive memo key is built.
- Generated lazy closures use required-capture masks, preserving stable
  argument layouts without forcing unused LET definitions.
- Standard finite-set predicates use direct calls and constant-slot metadata;
  generated artifacts contain no string-based native dispatch.
- Strict linked models always enable their complete generated expression table;
  there is no benchmark feature flag selecting the fast path. Benchmark
  binaries compile-fail when `fallback_count` is nonzero.
- Exact ReleaseFast results: GameOfLife `2.573s/0.788s` and BTree
  `4.066s/0.954s` (TLC/tlzig). All default strict rows remain faster than TLC,
  all 40 stored artifacts compile, and every artifact has zero fallback.

## 2026-08-03 Shared State-Path Predicate Gate

Generated conjunctions now recognize a deliberately narrow structural pair:
a string-literal membership in `DOMAIN state_path`, immediately followed by a
field equality on the same path against an operator argument. The generated
runtime resolves the path once, checks the record/function domain without
building a set, and forces the equality argument only after membership passes.
This preserves TLA+ short-circuit/error order and allocates nothing on the hot
path. The matcher uses AST identity and parameter slots only; no user operator,
field name, or model name selects the optimization.

Storage exhaustive remains exact at `1,078,623` distinct states. Fresh paired
ReleaseFast all-core measurements are TLC `32.385s` and tlzig `10.529s`, with
a tlzig repeat of `10.579s`. The accepted change improves the preceding
`11.965-12.095s` tlzig range by `12-13%` and the earlier `14.606s` baseline by
`27.9%`. All 221 assertion-enabled tests and the complete default ReleaseFast
benchmark pass; regenerated artifacts have zero fallback and no generated
`runtime.native` dispatch.

Replacing primitive FNV leaf hashing with scalar mixing and Wyhash was tested
and removed. It retained exact counts but produced `10.766s`, `10.796s`, and
`11.123s` Storage runs, all slower than the accepted `10.529-10.579s` range.
Reducing leaf rounds does not compensate for the added code/setup cost; future
hash work must remove recursive aggregate traversals instead.

Generic membership in `DOMAIN state_path` and
`DOMAIN state_path.record_field` now resolves the path once and checks function,
tuple, or record domains without materializing a set. Exact Storage exhaustive
improved again to a paired `10.162s`, with isolated repeats of `10.016s` and
`10.496s`; both engines retain `1,078,623` distinct states. All 222 tests and
the default ReleaseFast corpus pass with zero generated fallback.

A narrower string-literal domain API was measured and removed. Its isolated
A/B results were `10.365s/10.836s` versus `9.971s/10.003s` for the generic
direct-domain binary, despite one noisy paired result of `9.654s`. Keeping the
element as the ordinary generated expression gives less code and better stable
performance.

The remaining reconstruct/clone/fingerprint duplication needs a lifetime
change, not an early write into candidate storage. Candidate pools are
append-only while failed action branches roll back evaluator pools; writing
partial results there would leak bounded capacity. A future typed patch/trail
must define rollback and primed-read semantics before it can replace those
traversals.

The 2026-08-03 current-binary sample still identifies recursive value
fingerprinting as the dominant top-of-stack cost (`9,304` samples), followed
by cross-pool path application (`3,818`), cloning, and byte comparison. A
standalone disjoint-`EXCEPT` constructor was measured and removed: Storage
already takes the fused primed-variable comparison path, while the extra
constructor regressed three exact isolated runs to
`10.513s/10.920s/10.881s`. Reverted runs under the same load were
`10.396s/10.436s/10.886s`.

Repeated state paths in flattened short-circuit conjunctions now use an
allocation-free `ResolvedPath` view after their first fused domain/field
guard. The compiler matches AST structure and numeric state/argument slots;
the runtime contains no model, operator, or field-name dispatch. Resolution
is kept at the original guard position, so earlier false predicates and error
order remain unchanged. Later field comparisons and field-domain membership
reuse `(Value, source_pool)` instead of traversing the same function path.
Five alternating exact Storage runs improved median all-core time from
`10.761s` to `10.413s` and mean from `10.606s` to `10.449s`, winning four of
five paired positions. Exact `8,723,634/1,078,623` counts, all `223` tests,
the complete default ReleaseFast corpus, and zero-fallback generation remain
intact.

Capturing a second repeated path while evaluating the right side of an ordered
field comparison was also tested and removed. Although it eliminated another
path traversal without changing left-to-right error order, the larger helper
regressed five-run Storage median from `10.831s` to `11.066s` and mean from
`10.805s` to `10.940s`; only one paired position improved. Path reuse remains
limited to views established by the existing fused guard, where the measured
code-size/work tradeoff is positive.

A generic clone-and-fingerprint walk was implemented for every hashable
`Value` variant and measured with matched ReleaseFast binaries. Exact Storage
counts held, but five alternating runs regressed median from `11.668s` to
`11.823s` and mean from `11.455s` to `11.568s`; only two pairs improved. The
implementation and its cache relocation were removed. This confirms that a
future candidate optimization must avoid materialization or retain old-root
sharing, not only merge two existing recursive walks.

Dense integer/model function lookup now validates the computed slot with a
direct tag and scalar comparison instead of calling the generic cross-pool
equality dispatcher. Sparse domains still fall back to the linear semantic
lookup. Five alternating exact Storage runs improved median from `11.711s` to
`11.386s` and mean from `11.527s` to `11.369s`, winning four of five pairs;
all ten runs retained `8,723,634/1,078,623` counts. The post-change corpus has
`224` passing tests, complete coverage of all 11 TLC-valid MDBTLA configs,
zero generated fallback, and every default AOT row faster than TLC-auto.

Generic cross-pool application is now force-inlined into path resolution.
This exposes integer/model dense probes and tuple indexing to each AOT caller
without adding a new runtime representation or model-specific dispatch. Eight
alternating and reverse-order exact Storage runs improved aggregate median
from `12.385s` to `11.543s` and mean from `12.264s` to `11.757s`; pairwise
wins were 4/8 because machine load varied sharply, but the generated binary
also became `17,152` bytes smaller. A fresh CPU sample no longer contains an
out-of-line `apply_cross_pool` hotspot; the inlined work is correctly charged
to `resolve_path`. A second complete default ReleaseFast corpus passed with
zero fallback, exact exhaustive counts, and every AOT row faster than
TLC-auto.

Path resolution itself is now force-inlined into generated AOT callers. Eight
alternating and reverse-order exact Storage runs improved aggregate median
from `10.387s` to `10.118s` and mean from `10.439s` to `10.305s`, winning
seven of eight pairs. The generated executable grew by `17,536` bytes, a
bounded code-size cost for the measured reduction in dispatch and call
overhead. Literal-string cross-pool application is also force-inlined. Six
fully recorded exact pairs improved median from `10.354s` to `10.012s` and
mean from `10.537s` to `9.965s`, winning all six; this second change reduced
the executable by `128` bytes relative to the path-inline control.

The accepted build passes formatting, all `224` tests, ReleaseFast
compilation, complete coverage of all 11 TLC-valid MDBTLA configurations, and
the default ReleaseFast benchmark. Every strict generated artifact has zero
fallbacks and every AOT row is faster than TLC-auto. The exhaustive Storage
A/B runs retain exactly `8,723,634/1,078,623` generated/distinct states.

A fresh accepted-build sample confirms that both newly inlined helpers have
disappeared as standalone hotspots. Top-of-stack work is now recursive value
fingerprinting (`13,990` samples), direct state-path filtering (`3,836`), byte
equality (`2,905`), action-step execution (`2,423`), recursive cloning
(`2,283`), and aggregate moves (`1,251`). The sample retained exact Storage
counts; its profiler-inflated wall time is not benchmark evidence.

Generated state paths with a final literal-string key now pass that literal
directly after resolving the prefix. This is not a record-layout assumption:
the generic helper preserves record and string-keyed function application and
the same errors for missing keys or invalid operands. It removes temporary
string interning and generic final-key dispatch. Ten exact all-core Storage
pairs won seven positions, with aggregate median `10.768s` to `10.729s` and
mean `10.972s` to `10.848s`. Three paired hardware-counter runs were more
stable: retired instructions fell by `0.450%`, `0.440%`, and `0.528%`, a mean
reduction from `1.962156T` to `1.952880T` (`0.473%`). Code size increased by
`144` bytes. The post-change gate has `225` passing tests, complete MDBTLA
coverage, zero generated fallback, and every default AOT row faster than
TLC-auto.

The same representation-preserving path specialization now covers equality,
inequality, and set membership. It resolves the prefix once and applies the
final literal directly; literal string right-hand operands are compared by
bytes without constructing another `Value.string`. This remains generic over
records and string-keyed functions and contains no model names or model
semantics. Exhaustive Storage lowers `28` hot sites (`18` equality, `6`
inequality, and `4` membership). Six alternating exact ReleaseFast pairs
reduced retired instructions in every pair, from a `1.953476T` baseline mean
to `1.950359T`, a `0.160%` reduction. Aggregate wall mean moved from `10.553s`
to `10.508s` and median from `10.660s` to `10.370s`; pairwise wall order was
noisy, so the consistent counter result is the acceptance evidence. The
executable grew by `32` bytes. Formatting, all `225` tests, ReleaseFast
compilation, coverage audit, full default benchmark, zero-fallback audit, and
no-spec-semantics audit all pass.

Recursive value fingerprints now inline a generic primitive-child dispatcher.
The fingerprint format is unchanged: Boolean, integer, model, string, and
range leaves retain their exact FNV tags and bytes, model permutations remain
identical, and bounded hashing consumes the same node budget. Only aggregate
values enter the larger recursive switch, so primitive children avoid a full
out-of-line redispatch. This is representation-level machinery shared by all
models; it has no generated operator or model-name knowledge. Three
alternating exact ReleaseFast Storage pairs retained
`8,723,634/1,078,623` generated/distinct states while mean retired
instructions fell from `1.950677T` to `1.748778T` (`10.350%`) and cycles fell
`4.863%`. Wall mean improved from `11.930s` to `11.293s` (`5.337%`) and
median from `11.930s` to `11.380s` (`4.610%`), with all three pairs faster.
The executable grew by `16,544` bytes. Formatting, all `225` tests,
ReleaseFast compilation, complete MDBTLA coverage, the full default
benchmark, zero-fallback audit, and no-spec-semantics audit pass.

Generated Boolean set filters now retain a verified slot for their first
post-bound literal record field. The first candidate scans normally. Later
candidates reuse the slot only when its field name still matches; a different
record layout falls back to a scan and updates the slot. Debug builds also
assert that no earlier field has the same name, matching TLA+ record-field
uniqueness. The cache lives on the filter stack, performs no allocation, and
is selected from a general AST shape emitted in eight MDBTLA models. Six
alternating exact ReleaseFast Storage pairs retained
`8,723,634/1,078,623` generated/distinct states. Mean retired instructions
fell from `1.748343T` to `1.715462T` (`1.881%`) and cycles fell `2.187%`, with
no executable growth. Wall mean improved `0.568%`; median regressed `2.237%`
under run-order noise, while the candidate won four of six pair positions.
Formatting, all `226` tests, ReleaseFast compilation, complete MDBTLA
coverage, the full default benchmark, zero-fallback audit, and
no-spec-semantics audit pass.

Any future lazy EXCEPT patch must satisfy a stricter ownership contract than
the current evaluator representation:

1. The base root and its pool must outlive action-branch rollback; no patch may
   retain a value owned only by the rollbackable evaluator pool.
2. Replacement values and dynamic path components must be copied into bounded
   patch scratch or be proven candidate-owned scalars before the evaluator
   mark is restored.
3. Rejected branches must leave persistent candidate capacity unchanged.
   Publication may happen only after the action predicate succeeds.
4. Primed reads during the same action must resolve through the patch overlay,
   including nested reads and multiple updates to the same path.
5. Repeated, overlapping, and nested EXCEPT paths must preserve TLA+ left-to-
   right update and `@` semantics.
6. Equality, fingerprinting, canonicalization, and eventual materialization
   must describe the same value without pointer identity or profile-derived
   assumptions.
7. Capacity must be preflighted from bounded path/update counts so failure is
   explicit and no hot-path allocator fallback is introduced.

Until all seven conditions are implemented together, eager localization and
materialization remain the correct ownership boundary. A partial patch would
trade measured CPU work for dangling references, stale primed reads, or
candidate-pool leakage and is therefore not an acceptable optimization.
