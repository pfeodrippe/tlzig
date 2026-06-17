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

Target: **≥50% of all `.tla` files in `vendor/tlaplus-examples/specifications` must pass.**

### Latest benchmark run (ReleaseFast)
```
                           SPEC     TLC(s)   Tlzig(s)   TLC states Tlzig states  Speedup
---------------------------------------------------------------------------------------------
                           HourClock.tla      0.352      0.001           12           12   352.0x
                     AsynchInterface.tla      0.368      0.000           12           12     0.0x
                             Channel.tla      0.370      0.000           12           12     0.0x
                             DieHard.tla      0.396      0.002           14           14   198.0x
            MissionariesAndCannibals.tla      0.425      0.005           61           61    85.0x
                    CigaretteSmokers.tla      0.374      0.001            6            6   374.0x
                  APCigaretteSmokers.tla      0.375      0.001            6            6   375.0x
                           CoffeeCan.tla      0.775      0.092         5150         5150     8.4x
                              Simple.tla      0.437      0.027          723          723    16.2x
                             Barrier.tla      0.387      0.004           64           64    96.8x
                                Lock.tla      0.407      0.001           12           12   407.0x
                          MCMajority.tla      0.506      0.042         2733         2733    12.0x
                       MCFindHighest.tla      0.492      0.013          742          742    37.8x
                            TwoPhase.tla      0.410      0.022          288          288    18.6x
                       LiveHourClock.tla      0.372      0.000           12           12     0.0x
```

### Coverage probe (all 226 specifiable configs, max_states=50000, --unlimited-memory)
- PASS: 100 / 226 (44%) -- up from 50->53->73->74->81->82->89->91->98->100
- FAIL categories: StateSpaceExhausted 25, TypeError 23, UndefinedSymbol 18, ConfigError 12, SyntaxError 9, NotImplemented 4, OOM 2
- Many StateSpaceExhausted specs would pass with higher max_states (e.g. 100000+)
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
- [ ] Profile on medium specs
- [ ] Multi-threaded worker pool
- [ ] Lock-free / sharded FPSet
- [ ] Compressed state queue
- [ ] Disk FPSet spill
- [ ] Benchmark suite

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

## Notes
- Update this file after every spec/example milestone.
- Record Java TLC command and timing in the spec row.
- Record tlzig command and timing in the spec row.
