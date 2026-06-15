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
6. [ ] `specifications/echo/Echo.tla`
7. [ ] `specifications/Majority/Majority.tla`
8. [ ] `specifications/Bakery-Boulangerie/Bakery.tla`
9. [ ] `specifications/KeyValueStore/KeyValueStore.tla`
10. [ ] `specifications/PaxosHowToWinATuringAward/Paxos.tla`
11. [ ] `specifications/dag-consensus/Sailfish.tla`

For each spec:
- [ ] Translate / parse real TLA+ syntax
- [ ] Identify unsupported operators/modules
- [ ] Implement missing operators/modules
- [ ] Run with Java TLC baseline (`time java -cp ... tlc2.TLC ...`)
- [ ] Run with `tlzig`
- [ ] Verify identical results (states generated, invariants, deadlock)
- [ ] Measure speedup vs Java TLC
- [ ] Mark complete when tlzig ≥ 2× faster and correct

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
