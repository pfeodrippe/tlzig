# tlzig — A High-Performance TLA+ Model Checker in Zig

## 1. Goal

Build a TLA+ model checker (a TLC-compatible engine) in Zig that is:

- **Correct**: Matches TLC semantics for the supported TLA+ fragment.
- **Fast**: Single-threaded state-space exploration with cache-friendly data
  structures, 64-bit fingerprints, and no run-time allocations.
- **Lean**: Follows [TigerBeetle's TIGER_STYLE](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md):
  static allocation only after init, explicit error handling, dense assertions,
  simple control flow, and a 70-line function limit.

The project vendors:

- `vendor/tlaplus-examples` — TLA+ example specifications (git submodule).
- `vendor/zig` — Zig compiler source from Codeberg master (git submodule).
- `vendor/tlaplus` — Reference TLC/SANY implementation (plain clone for study only).

## 2. What a TLA+ Model Checker Does

Studying the reference TLC codebase (`vendor/tlaplus/tlatools/org.lamport.tlatools/src/tlc2/tool`):

- **SANY** parses `.tla` files and produces a semantic AST (`tla2sany.semantic.*`).
- **Tool** (`tlc2.tool.impl.Tool`) evaluates TLA+ expressions in a `Context`
  and one or two states (`s0`, `s1` for actions).
- **TLCState** is a vector of `IValue`s, one slot per state variable.
- **ModelChecker** BFS-explores the state graph:
  1. Generate all initial states from `Init`.
  2. For each queued state, evaluate every action in `Next` to generate successors.
  3. Check invariants, implied actions, and deadlock on successors.
  4. Fingerprint each new state and add it to `theFPSet`.
  5. Enqueue unseen states.
- **FPSet** is a set of 64-bit state fingerprints; open-addressing in memory.
- **StateQueue** holds states whose successors have not yet been explored.
- **Trace** records predecessor links so counterexamples can be reconstructed.

Our Zig engine reimplements the evaluation and model-checking loops in Zig,
using a compact value representation and pre-allocated state storage.

## 3. Supported TLA+ Fragment (MVP)

Phase 1 targets single-module teaching specs with the `Naturals` module.

Supported syntax/semantics:

- Modules, `EXTENDS Naturals`/`Integers`/`TLAPS`, `VARIABLES`, `CONSTANTS`.
- Definitions with `==`, including parameterised operators (`Min(m,n) == ...`).
- Boolean operators: `/\`, `\/`, `~`, `=>`, `<=>`, `TRUE`, `FALSE`.
- Equality/inequality: `=`, `#`, `/=`.
- Naturals: integer literals, `+`, `-`, `*`, `%`, `..`, `<`, `>`, `<=`, `>=`.
- Sets: set enumeration `{a, b}`, `\in`, `\notin`, `\subseteq`, `SUBSET S`,
  `S \cup T`, `S \cap T`, `S \ T`.
- Functions: `[x \in S |-> e]`, application `f[x]`, `DOMAIN f`,
  set-of-functions `[S -> T]` (membership checked without enumerating the set),
  `EXCEPT ![x] = e` (with `@`).
- Tuples: `<<a, b>>`, application `t[i]` (1-based).
- Records: `[a |-> v]`, field access `r.a`.
- `IF ... THEN ... ELSE ...`.
- Quantifiers: `\E x \in S : P`, `\A x \in S : P`.
- Quantified action calls (`\E self \in S : proc(self)`).
- `CHOOSE x \in S : P` (deterministic smallest element).
- Primed variables in actions: `x'`.
- `UNCHANGED x`, `UNCHANGED <<x, y>>`.
- Action conjunction/disjunction.
- `Init`, `Next`, `INVARIANT` from the `.cfg` file.
- `LET d1 == e1 IN e2` (local definitions, including inside actions).

Out of scope for Phase 1:

- Real modules beyond `Naturals` (no `Sequences`, `Bags`, `FiniteSets`, TLC overrides).
- Liveness checking (`[]`, `<>`, `~>`). The parser skips `SPECIFICATION` lines that
  contain these operators and the `.cfg` file must therefore use `INIT`/`NEXT`.
- Symmetry reduction.
- Model values and views.
- Theorem/proof constructs.
- Recursive operators and `LAMBDA`.
- Real numbers, strings (string literals are parsed but have no operations).
- Disk spill (`FPSet` stays in pre-allocated RAM).

## 4. Architecture

```
src/
  main.zig         CLI: parse args, load spec + cfg, run checker, report.
  parser.zig       Lexer + recursive-descent parser for the MVP fragment.
  ast.zig          AST node definitions (expressions, definitions, modules).
  value.zig        TLA+ value representation and small-object layout.
  eval.zig         Expression and action evaluator.
  state.zig        State vector, variable bindings, state store.
  fingerprint.zig  64-bit fingerprint/hash helpers.
  fp_set.zig       Open-addressing set of 64-bit fingerprints.
  queue.zig        Pre-allocated circular queue of state handles.
  checker.zig      BFS model-checking loop.
  action.zig       Action compiler and executor (Init/Next -> ActionStep).
  config.zig       `.cfg` file parser.
  arena.zig        Pre-sized, aligned bump allocator.
  err.zig          Error codes and diagnostics.
  tests.zig        Unit and integration tests.
```

Memory design (TigerBeetle style):

- One `Arena` is sized at startup from CLI flags (`--max-states`, `--max-memory`).
- All states, values, sets, functions, and queue entries live in this arena.
- No `Allocator` interface is used at run-time; the arena is bumped forward.
- When the arena is exhausted the checker stops with a clear error.
- Function recursion is avoided; all loops are bounded by constants or arena limits.

Value representation:

```zig
const Value = union(enum(u8)) {
    bool_v: bool,
    int_v: i64,
    set_v: Set,
    function_v: Function,
    tuple_v: Tuple,
    record_v: Record,
    string_v: String,
    model_v: u32,
};
```

`Set`, `Function`, `Tuple`, `Record` are offsets/counts into an arena-backed
value pool, not pointers, so they survive arena compaction and are serializable.

State representation:

```zig
const State = struct {
    level: u32,        // BFS depth.
    pred: u32,         // Index of predecessor in the trace table.
    values: []Value,   // One value per variable, length == module.variables.len.
};
```

Fingerprinting:

- 64-bit FNV-1a over the canonical byte sequence of the state's values.
- Sets and functions are hashed in an order-independent way so semantically
  identical values always produce the same fingerprint.

## 5. Action Compilation

Actions are compiled once into a list of `ActionStep`s:

- `assign_var`   — `x \in S` during `Init` (nondeterministic assignment).
- `assign_prime` — `x' = e` during `Init`/`Next`.
- `condition`    — boolean guard.
- `choose`       — `\E x \in S : action` (nondeterministic action choice).
- `call`         — inlined parameterised action call (`proc(self)`).
- `branch`       — top-level action disjunction `\/` (choice point);
  nested `\/` inside conditions is kept as a single condition so short-circuit
  semantics apply.
- `unchanged`    — `UNCHANGED x`.

This avoids interpreting the AST inside the hot model-checking loop. Parameterised
operator references are inlined during compilation so definitions like `Min` and
`proc(self)` are resolved before checking starts.

## 6. Evaluator Semantics

The evaluator takes an expression, a fixed-size `Context`, an optional current
state `s0`, and two value pools:

- `state_pool` persists committed states.
- `eval_pool` is temporary and snapshotted/restored per successor generation.

Variable lookup order:

1. `s0` is checked first for unprimed variables, so `x` always means the current
   state value even when `x'` has already been assigned in the next-state context.
2. `Context` is checked next for primed variables and operator parameters.
3. Operator definitions are resolved directly at application time for ident
   functions (`Min(big + small, 5)`).

## 7. Verified Examples

### HourClock

```sh
./zig-out/bin/tlzig \
  --spec vendor/tlaplus-examples/specifications/SpecifyingSystems/HourClock/HourClock.tla \
  --cfg   vendor/tlaplus-examples/specifications/SpecifyingSystems/HourClock/HourClock_simple.cfg \
  --max-states 10000
```

- Java TLC: 0.366s, 24 generated, 12 distinct
- tlzig (ReleaseFast): 0.006s, 24 generated, 12 distinct
- Speedup:  ~60x

### DieHard

```sh
./zig-out/bin/tlzig \
  --spec vendor/tlaplus-examples/specifications/DieHard/DieHard.tla \
  --cfg   vendor/tlaplus-examples/specifications/DieHard/DieHard_simple.cfg \
  --max-states 1000
```

- Java TLC: 0.354s, 97 generated, 16 distinct
- tlzig (ReleaseFast): 0.007s, 97 generated, 16 distinct
- Speedup:  ~50x
- `NotSolved` invariant (big # 4) correctly fails.

### AsynchronousInterface

```sh
./zig-out/bin/tlzig \
  --spec vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/AsynchInterface.tla \
  --cfg   vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/AsynchInterface_simple.cfg \
  --max-states 10000
```

- Java TLC: 0.355s, 30 generated, 12 distinct
- tlzig (ReleaseFast): 0.006s, 30 generated, 12 distinct
- Speedup:  ~60x

### SimpleRegular

```sh
./zig-out/bin/tlzig \
  --spec vendor/tlaplus-examples/specifications/TeachingConcurrency/SimpleRegular.tla \
  --cfg   vendor/tlaplus-examples/specifications/TeachingConcurrency/SimpleRegular_simple.cfg \
  --max-states 10000
```

- Java TLC: ~0.5s, 34 generated, 22 distinct, depth 7
- tlzig (ReleaseFast): 0.005s, 34 generated, 22 distinct
- Speedup:  ~100x
- Requires `\A`/`|->`/`[S -> T]`/`SUBSET`/`\`/`EXCEPT`/quantified action calls.

### Simple

```sh
./zig-out/bin/tlzig \
  --spec vendor/tlaplus-examples/specifications/TeachingConcurrency/Simple.tla \
  --cfg   vendor/tlaplus-examples/specifications/TeachingConcurrency/Simple_simple.cfg \
  --max-states 10000
```

- Java TLC: ~0.5s, 18 generated, 13 distinct, depth 5
- tlzig (ReleaseFast): 0.007s, 18 generated, 13 distinct
- Speedup:  ~70x

### MissionariesAndCannibals

```sh
./zig-out/bin/tlzig \
  --spec vendor/tlaplus-examples/specifications/MissionariesAndCannibals/MissionariesAndCannibals.tla \
  --cfg   vendor/tlaplus-examples/specifications/MissionariesAndCannibals/MissionariesAndCannibals_typeok.cfg \
  --max-states 10000
```

- Java TLC: 283 generated, 64 distinct (TypeOK only)
- tlzig (ReleaseFast): 283 generated, 64 distinct
- `Solution` invariant is correctly violated at the goal state.
- Required: `LET/IN` action bindings, `Cardinality`, `SUBSET`,
  function-set membership, `\cup`/ `\`, canonical set fingerprints.

## 8. Running

```sh
# Build the engine.
./tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build

# Run tests.
./tools/zig-aarch64-macos-0.17.0-dev.857+2b2b85c5f/zig build test

# Check a spec.
./zig-out/bin/tlzig --spec SPEC.tla --cfg CFG.cfg --max-states N
```

## 9. Design Rules (TigerBeetle Style Applied)

- All loops have a fixed upper bound derived from arena limits or `max_states`.
- Every function asserts preconditions and postconditions.
- No recursion; evaluation uses explicit work stacks.
- `u32`/`u64`/`i64` everywhere; no `usize` in hot paths.
- Functions fit in 70 lines; split large logic into pure helpers.
- No dependencies beyond the Zig toolchain.
- Use `zig fmt` and keep lines <= 100 columns.

## 10. Notes on Correctness

- We cross-validate against TLC on every spec we claim to support.
- Invariant checking is synchronous with state generation.
- Counterexamples are reconstructed from the trace table by following `pred` links.
