# TLA+ Specification Coverage

Last updated: 2026-07-12

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
  engine reaches the 15-second or 200,000-state audit bound. This is not an
  exhaustive correctness claim.
- **TLC invalid**: Java TLC rejects the module/configuration before ordinary
  model checking. This is not a tlzig compatibility requirement.
- **Non-model harness**: an executable Toolbox/CI utility that performs
  top-level expression or subprocess work without INIT/NEXT/SPECIFICATION.
- **Gap**: tlzig rejects/crashes after TLC accepts, disagrees on outcome, or an
  exhaustively successful run has a different distinct-state count.

## Current Paired Audit

Manifest: `coverage_results/primary_final_clean.jsonl`

| Resolved model path | Exact | Outcome exact | Stochastic | Bounded | TLC invalid | Non-model | Hard gaps |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `specs` | 6 | 1 | 0 | 0 | 16 | 0 | 0 |
| `tlaplus-examples` | 148 | 16 | 1 | 35 | 42 | 2 | 0 |
| `MDBTLA` | 2 | 7 | 0 | 2 | 2 | 0 | 0 |
| **Total** | **156** | **24** | **1** | **37** | **60** | **2** | **0** |

The short audit has zero tlzig rejections, zero outcome mismatches, and zero
exhaustive distinct-count mismatches. It does **not** prove all 37 bounded
rows exhaustively. Long MDBTLA evidence is maintained separately because its
largest rows require minutes rather than the short corpus gate.

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

The generic generated-code fixes were also checked on the exhaustive btree
model. `coverage_results/btree_post_lazy.jsonl` records exact interpreter parity
at `2,820,091/374,727`; TLC took `28.27s` and interpreted tlzig took `34.12s`.
The strict zero-fallback AOT build completed the same counts in `14.52s`, about
`1.95x` faster than that fresh TLC run.

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
| RC/snapshot exhaustive | 67,629,092 | 669.976s | 360.86s | 1.86x |
| SingleLog MCMDBProps | 269,881 | 1,434.504s | 99.42s | 14.4x |
| SingleShardTxn ShardTxn | 5,502,547 | 179.117s | 24.286s | 7.38x |

The MCMDBProps TLC timing is the completed baseline for the unchanged upstream
model; its current one-core TLC rerun was still incomplete at 300 seconds.
SingleShardTxn is a fresh paired 2026-07-12 run. Both current tlzig AOT runs
completed exact generated and distinct counts. First-error MultiShard rows
compare outcome rather than partial counts because parallel traversal may stop
on different valid witnesses.

The current default paired ReleaseFast benchmark completes in under three
minutes. TLC runs once in the primary comparison; strict zero-fallback AOT
rows run tlzig-only and compare against the stored interpreted tlzig baseline,
so generated rows do not launch duplicate Java checks. In the latest run,
TLC-auto versus tlzig-AOT-auto was ClientCentric `2.385s` vs `0.933s`, Storage
`1.539s` vs `0.340s`, RC/snapshot `2.395s` vs `0.571s`,
SingleShardTxn/small `2.352s` vs `0.093s`, and SingleLog MDBLinearizability
`2.030s` vs `1.186s`. Completed rows retain exact distinct counts. Configured
first-error rows compare deterministic one-worker counts within explicit
tolerances and compare AOT outcome under all-core scheduling.

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
- Large set construction uses resettable-pool-backed open addressing instead
  of a quadratic fallback, and ungraphed initial states avoid redundant edge
  deduplication. CoffeeCan1000 improved from over `131s` to `6.878s`, versus
  TLC-auto `15.875s`, with exact `2,000,002/501,500` counts.

## Remaining Work

- [ ] Run opt-in exhaustive paired checks for the 37 bounded primary rows.
- [ ] Complete the extended paired runs for upstream `MCMDBProps` and
  `ShardTxn`; their fresh 60-second audit rows are intentionally still bounded.
- [ ] Audit ordinary non-TLAPS model fixtures under `vendor/tlaplus` separately
  from Java-extension, distributed-TLC, trace, and malformed-input fixtures.
- [ ] Continue generic typed AOT lowering from trusted TypeOK facts and
  measured profile data. PGO observations may select optimizations, but cannot
  silently assume semantics not guaranteed by the model/configuration.

## Reproduction

```sh
tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build
python3 scripts/audit_spec_coverage.py \
  --corpus specs \
  --corpus vendor/tlaplus-examples/specifications \
  --corpus vendor/MDBTLA \
  --jobs 8 --timeout 15 --resolve-timeout 15 \
  --max-states 200000 --fresh \
  --output coverage_results/primary_final_clean.jsonl
python3 scripts/audit_mdbtla_coverage.py
```
