# All-Core Performance Architecture

Date: 2026-07-14

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
| TLC all-core exact baseline | 405,005,930 | 67,629,092 | 669.976s | - | - |
| Original tlzig exact baseline | 405,005,930 | 67,629,092 | 679.912s | - | - |
| Prior accepted tlzig exact | 405,005,930 | 67,629,092 | 360.86s | 63.56T | 26,015,973,376 B |
| Pre-trail tlzig exact | 405,005,930 | 67,629,092 | 334.557s | - | - |
| Initial compact-trail exact | 405,005,930 | 67,629,092 | 335.834s | 59.310T | 30,868,815,872 B |
| Refined trail before body inlining | 405,005,930 | 67,629,092 | 328.100s | 57.138T | 26,281,590,784 B |
| Current tlzig exact | 405,005,930 | 67,629,092 | 318.628s | 54.658T | 29,406,117,888 B |

The current exact run is `1.030x` faster than the preceding `328.100s` run,
`1.050x` faster than the pre-trail `334.557s` run, `1.133x` faster than the
prior countered `360.86s` run, `2.134x` faster than the original `679.912s`
tlzig baseline, and `2.103x` faster than the retained `669.976s` TLC baseline.
Retired instructions are 4.34% below the preceding exact run and 14.0% below
the older `63.56T` measurement. Observed exact-run peak RSS rose 11.9% from
`26.28GB` to `29.41GB`; capped-probe RSS was unchanged, so one run does not
establish the cause. The memory delta remains an explicit regression risk and
follow-up measurement rather than being hidden. This is a measured generic
improvement, not a 10x claim.

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

## 2026-07-14 Gate Results

- Assertion-enabled tests: `176/176` passed.
- Strict artifacts: all 25 checked-in generated Zig models independently
  compiled in ReleaseFast; every artifact declares ABI `2` and
  `fallback_count = 0`.
- MDBTLA inventory: all 13 upstream configurations are classified; 11
  TLC-valid configurations are benchmark-covered and two are invalid in TLC
  because `Timestamps` is unassigned.
- Runtime override audit: MDBTLA, MultiShardTxn, MCBinarySearch, and EWD998
  identifiers occur under `src` only in parser tests. Production overrides are
  TLA+/TLC built-ins and standard-module operators.
- Decisive exhaustive result: exact `405,005,930/67,629,092` in `318.628s`,
  `54.658T` retired instructions, and `29,406,117,888` bytes peak RSS.
- Default ReleaseFast benchmark: `56/56` build steps passed in `160.18s`. It
  contains no heavy one-worker rows and includes strict representative AOT
  models such as Slush Medium, MCBinarySearch, and MDBTLA.

The generated-pattern audit now provides a concrete compiler backlog across 25
artifacts: 25,472 nested runtime-helper chains, 5,068 generic variable paths,
1,231 whole-root primed comparisons, 555 generic mapped-set constructions, 435
generic `UNCHANGED` expressions, 234 generic `EXCEPT` reconstructions, and 176
materialized function ranges. Counts are syntactic opportunities, not assumed
speedups; each lowering still requires differential tests and ReleaseFast A/B
evidence.

References: [TigerBeetle TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
and [Zig vectors](https://ziglang.org/documentation/master/#Vectors).
