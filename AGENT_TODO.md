# AGENT_TODO — tlzig Implementation Tracker

## Mission
Build a Zig TLA+ model checker that is faster than Java TLC on all specs in
`vendor/tlaplus-examples/specifications`, from simplest to most complex.

## Progress Legend
- [ ] Not started
- [~] In progress
- [x] Done

## Phase 0 — Foundation
- [x] Add `vendor/tlaplus-examples` submodule
- [x] Add `vendor/zig` (Codeberg master) submodule
- [x] Add reference `vendor/tlaplus` clone for study
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

Target: **≥50% of all `.tla` files in `vendor/tlaplus-examples/specifications` must pass.**
Current harness (existing `.cfg` when present, otherwise generic `INIT Init / NEXT Next / INVARIANT TypeOK`, `--max-states 5000`): **16/394 passing (4%)**.

Top blockers observed in harness:
1. `INSTANCE M WITH ...` substitutions (modular specs).
2. Higher-order operators / `LAMBDA` / `CHOOSE` predicates (CigaretteSmokers, Echo, SlidingPuzzles, ...).
3. `WF_vars(Next)` / `SF_vars(Next)` fairness syntax in `Spec` definitions.
4. Config substitutions (`<-`) and advanced config directives.
5. Missing standard-module operators (`SelectSeq`, `SortSeq`, `Bags`, `Permutations`, etc.).
6. Proof-only / non-checkable `.tla` files (acceptable to skip for the 50% target).

Target list sorted by perceived complexity (single module, few variables, no advanced modules first):

1. [x] `specifications/SpecifyingSystems/HourClock/HourClock.tla`
   - Java TLC: 0.366s, 24 generated, 12 distinct
   - tlzig (Debug): 0.197s, 24 generated, 12 distinct
   - tlzig (ReleaseFast): 0.006s
   - Speedup: ~60x
2. [ ] `specifications/SpecifyingSystems/TwoPhase/TwoPhase.tla` (with config)
3. [x] `specifications/SpecifyingSystems/AsynchronousInterface/AsynchInterface.tla`
   - Java TLC: 0.355s, 30 generated, 12 distinct
   - tlzig (Debug): 0.199s, 30 generated, 12 distinct
   - tlzig (ReleaseFast): 0.006s
   - Speedup: ~60x
   - Required: `CONSTANT` declarations, model values, `UNCHANGED <<x, y>>`
4. [x] `specifications/DieHard/DieHard.tla`
   - Java TLC: 0.354s, 97 generated, 16 distinct
   - tlzig (Debug): 0.190s, 97 generated, 16 distinct
   - tlzig (ReleaseFast): 0.007s
   - Speedup: ~50x
   - `NotSolved` invariant correctly fails when `big = 4`
5. [x] `specifications/TeachingConcurrency/SimpleRegular.tla`
   - Java TLC: ~0.5s, 34 generated, 22 distinct, depth 7
   - tlzig (ReleaseFast): 0.005s, 34 generated, 22 distinct
   - Speedup: ~100x
   - Required: `\A`/`|->`/`[S -> T]`/`SUBSET`/`\` (setminus)/`EXCEPT`/quantified action calls
6. [x] `specifications/TeachingConcurrency/Simple.tla`
   - Java TLC: ~0.5s, 18 generated, 13 distinct, depth 5
   - tlzig (ReleaseFast): 0.007s, 18 generated, 13 distinct
   - Speedup: ~70x
7. [x] `specifications/MissionariesAndCannibals/MissionariesAndCannibals.tla`
   - Java TLC: 283 generated, 64 distinct (TypeOK only)
   - tlzig (ReleaseFast): 283 generated, 64 distinct (TypeOK only)
   - `Solution` invariant correctly violated when all cross to west bank
   - Required: `LET/IN` action bindings, `Cardinality`, `SUBSET`, function-set membership, `\cup`/ `\` , set-order canonical fingerprints
8. [x] `specifications/barriers/Barrier.tla`
   - Java TLC: 14 generated, 8 distinct
   - tlzig (ReleaseFast): 14 generated, 8 distinct
   - Required: nested conjunction/disjunction list parsing, action-level `\/` branching, `UNCHANGED` tuple expansion, quantified action calls
9. [x] `specifications/Majority/Majority.tla`
   - Bounded `Seq(Value)` and `Nat` overrides allow model-checking all input sequences up to length 3
   - Java TLC: 300 generated, 222 distinct (Value={v1,v2,v3}, max sequence length 3)
   - tlzig (ReleaseFast): 300 generated, 222 distinct
   - Required: `Seq(S)` override, bounded `Nat`/`Int` overrides
10. [x] `specifications/LearnProofs/FindHighest.tla`
   - Bounded `Seq(Nat)` and action-level `IF/THEN/ELSE` compilation
   - tlzig (ReleaseFast): 1503 generated, 1244 distinct (max seq len 3, Nat 0..5)
11. [x] `specifications/transaction_commit/TwoPhase.tla` (existing cfg)
12. [x] `specifications/locks_auxiliary_vars/Lock.tla` (existing cfg)
13. [x] `specifications/bcastFolklore/bcastFolklore.tla` (existing cfg)
14. [x] `specifications/CoffeeCan/CoffeeCan.tla` (existing cfg)
15. [x] `specifications/SpecifyingSystems/Composing/HourClock.tla` (existing cfg)
16. [x] `specifications/SpecifyingSystems/Liveness/HourClock.tla` (existing cfg, liveness property ignored)
17. [ ] `specifications/echo/Echo.tla`
9. [ ] `specifications/Majority/Majority.tla`
10. [ ] `specifications/Bakery-Boulangerie/Bakery.tla`
11. [ ] `specifications/KeyValueStore/KeyValueStore.tla`
12. [ ] `specifications/PaxosHowToWinATuringAward/Paxos.tla`
13. [ ] `specifications/dag-consensus/Sailfish.tla`

For each spec:
- [ ] Translate / parse real TLA+ syntax
- [ ] Identify unsupported operators/modules
- [ ] Implement missing operators/modules
- [ ] Run with Java TLC baseline (`time java -cp ... tlc2.TLC ...`)
- [ ] Run with `tlzig`
- [ ] Verify identical results (states generated, invariants, deadlock)
- [ ] Measure speedup vs Java TLC
- [ ] Mark complete when tlzig ≥ 2× faster and correct

## Phase 2b — Scale to 50% of all specs

- [ ] Implement `INSTANCE M WITH ...` substitutions (highest unlock rate).
- [ ] Implement `LAMBDA`/higher-order operators and `CHOOSE` predicates.
- [ ] Parse `WF_vars(A)` / `SF_vars(A)` fairness syntax (or skip in `Spec` extraction).
- [ ] Add remaining standard-module overrides (`SelectSeq`, `SortSeq`, `Bags`, etc.).
- [ ] Support config substitutions (`<-`) and multi-line `CONSTANTS` blocks.
- [ ] Keep harness green and update pass count after each unlock.

## Phase 3 — Performance
- [ ] Profile on medium specs
- [ ] Multi-threaded worker pool
- [ ] Lock-free / sharded FPSet
- [ ] Compressed state queue
- [ ] Disk FPSet spill
- [ ] Benchmark suite

## Phase 4 — Advanced TLA+
- [ ] Liveness checking
- [ ] Symmetry reduction
- [x] Model values / constants
- [ ] TLC-compatible trace output

## Notes
- Update this file after every spec/example milestone.
- Record Java TLC command and timing in the spec row.
- Record tlzig command and timing in the spec row.
