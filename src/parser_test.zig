const std = @import("std");
const Arena = @import("arena.zig").Arena;
const parser = @import("parser.zig");
const ModuleLoader = @import("module_loader.zig").ModuleLoader;
const eval = @import("eval.zig");
const action = @import("action.zig");
const checker = @import("checker.zig");
const config = @import("config.zig");
const overrides = @import("overrides.zig");
const value = @import("value.zig");

test "parse function literal init" {
    const source =
        \\---------------------- MODULE TestInit ----------------------
        \\EXTENDS Naturals
        \\CONSTANT N
        \\VARIABLES x
        \\Init == x = [i \in 0..N-1 |-> {0}]
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqualStrings("TestInit", module.name);
    try std.testing.expectEqual(module.variables.len, 1);
    try std.testing.expectEqual(module.definitions.len, 1);
}

test "parse SimpleRegular-style Init" {
    const source =
        \\---------------------- MODULE TestInit ----------------------
        \\EXTENDS Naturals
        \\CONSTANT N
        \\VARIABLES x, y, pc
        \\Init == (* Global variables *)
        \\        /\ x = [i \in 0..(N-1) |-> {0}]
        \\        /\ y = [i \in 0..(N-1) |-> 0]
        \\        /\ pc = [self \in ProcSet |-> "a1"]
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqualStrings("TestInit", module.name);
    try std.testing.expectEqual(module.variables.len, 3);
    try std.testing.expectEqual(module.definitions.len, 1);
}

test "parse full SimpleRegular" {
    const source =
        \\--------------------------- MODULE SimpleRegular ---------------------------
        \\EXTENDS Integers, TLAPS
        \\
        \\CONSTANT N
        \\ASSUME NAssump ==  (N \in Nat) /\ (N > 0)
        \\
        \\VARIABLES x, y, pc
        \\
        \\vars == << x, y, pc >>
        \\
        \\ProcSet == (0..N-1)
        \\
        \\Init == (* Global variables *)
        \\        /\ x = [i \in 0..(N-1) |-> {0}]
        \\        /\ y = [i \in 0..(N-1) |-> 0]
        \\        /\ pc = [self \in ProcSet |-> "a1"]
        \\
        \\a1(self) == /\ pc[self] = "a1"
        \\            /\ x' = [x EXCEPT ![self] = {0,1}]
        \\            /\ pc' = [pc EXCEPT ![self] = "a2"]
        \\            /\ y' = y
        \\
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqualStrings("SimpleRegular", module.name);
    try std.testing.expectEqual(module.variables.len, 3);
    var found_init = false;
    for (module.definitions) |d| {
        if (std.mem.eql(u8, d.name, "Init")) found_init = true;
    }
    try std.testing.expect(found_init);
}

test "parse paren range expr" {
    const source =
        \\---------------------- MODULE Test ----------------------
        \\EXTENDS Naturals
        \\CONSTANT N
        \\R == 0..(N-1)
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqual(module.definitions.len, 1);
}

test "parse function literal with paren range" {
    const source =
        \\---------------------- MODULE TestInit ----------------------
        \\EXTENDS Naturals
        \\CONSTANT N
        \\VARIABLES x
        \\Init == x = [i \in 0..(N-1) |-> 0]
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqualStrings("TestInit", module.name);
    try std.testing.expectEqual(module.variables.len, 1);
    try std.testing.expectEqual(module.definitions.len, 1);
}

test "parse SimpleRegular Next" {
    const source =
        "---------------------- MODULE TestNext ----------------------\n" ++
        "EXTENDS Integers, TLAPS\n" ++
        "CONSTANT N\n" ++
        "ASSUME NAssump == TRUE\n" ++
        "VARIABLES x, y, pc\n" ++
        "vars == << x, y, pc >>\n" ++
        "ProcSet == (0..N-1)\n" ++
        "Init == /\\ x = [i \\in 0..(N-1) |-> {0}]\n" ++
        "        /\\ y = [i \\in 0..(N-1) |-> 0]\n" ++
        "        /\\ pc = [self \\in ProcSet |-> \"a1\"]\n" ++
        "a1(self) == /\\ pc[self] = \"a1\"\n" ++
        "            /\\ x' = [x EXCEPT ![self] = {0,1}]\n" ++
        "            /\\ pc' = [pc EXCEPT ![self] = \"a2\"]\n" ++
        "            /\\ y' = y\n" ++
        "a2(self) == /\\ pc[self] = \"a2\"\n" ++
        "            /\\ x' = [x EXCEPT ![self] = {1}]\n" ++
        "            /\\ pc' = [pc EXCEPT ![self] = \"b\"]\n" ++
        "            /\\ y' = y\n" ++
        "b(self) == /\\ pc[self] = \"b\"\n" ++
        "           /\\ \\E v \\in x[(self-1) % N]:\n" ++
        "                y' = [y EXCEPT ![self] = v]\n" ++
        "           /\\ pc' = [pc EXCEPT ![self] = \"Done\"]\n" ++
        "           /\\ x' = x\n" ++
        "proc(self) == a1(self) \\/ a2(self) \\/ b(self)\n" ++
        "Terminating == /\\ \\A self \\in ProcSet: pc[self] = \"Done\"\n" ++
        "               /\\ UNCHANGED vars\n" ++
        "Next == (\\E self \\in 0..N-1: proc(self))\n" ++
        "           \\/ Terminating\n" ++
        "==============================================================\n";
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    var found_next = false;
    for (module.definitions) |d| {
        if (std.mem.eql(u8, d.name, "Next")) found_next = true;
    }
    try std.testing.expect(found_next);
}

test "parse minimal Next" {
    const source =
        "---------------------- MODULE TestNext ----------------------\n" ++
        "EXTENDS Naturals\n" ++
        "VARIABLE x\n" ++
        "Next == (x' = 0) \\/ (x' = 1)\n" ++
        "==============================================================\n";
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqual(module.definitions.len, 1);
}

test "parse disjunction" {
    const source =
        "---------------------- MODULE Test ----------------------\n" ++
        "EXTENDS Naturals\n" ++
        "VARIABLE x\n" ++
        "D == (x' = 0) \\/ (x' = 1)\n" ++
        "==============================================================\n";
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqual(module.definitions.len, 1);
}

test "parse TypeOK" {
    const source =
        "---------------------- MODULE Test ----------------------\n" ++
        "EXTENDS Naturals\n" ++
        "CONSTANT N\n" ++
        "TypeOK == /\\ x \\in [0..(N-1) -> (SUBSET {0, 1}) \\ {{}}]\n" ++
        "==============================================================\n";
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqual(module.definitions.len, 1);
}

test "parse HourClock" {
    const source =
        \\---------------------- MODULE HourClock ----------------------
        \\EXTENDS Naturals
        \\VARIABLE hr
        \\HCini  ==  hr \in (1 .. 12)
        \\HCnxt  ==  hr' = IF hr # 12 THEN hr + 1 ELSE 1
        \\HC  ==  HCini /\ [][HCnxt]_hr
        \\--------------------------------------------------------------
        \\THEOREM  HC => []HCini
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqualStrings("HourClock", module.name);
    try std.testing.expectEqual(module.variables.len, 1);
    try std.testing.expectEqualStrings("hr", module.variables[0]);
    try std.testing.expectEqual(module.definitions.len, 3);
}

test "parse declarations continued after comment" {
    const source =
        \\---------------------- MODULE TestDecls ----------------------
        \\EXTENDS Naturals
        \\CONSTANTS Vals,
        \\          MaxKey,
        \\          MaxNode,
        \\          MaxOccupancy,
        \\
        \\          \* states
        \\          READY,
        \\          UPDATE_LEAF
        \\
        \\VARIABLES root,
        \\          isLeaf, keysOf, childOf, lastOf, valOf,
        \\          focus,
        \\          toSplit,
        \\          op, args, ret,
        \\          state
        \\
        \\TypeOk == /\ root \in 1..MaxNode
        \\          /\ isLeaf \in [1..MaxNode -> BOOLEAN]
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqual(module.constants.len, 6);
    try std.testing.expectEqualStrings("READY", module.constants[4]);
    try std.testing.expectEqual(module.variables.len, 12);
    try std.testing.expectEqualStrings("isLeaf", module.variables[1]);
    try std.testing.expectEqualStrings("state", module.variables[11]);
    try std.testing.expectEqual(module.definitions.len, 1);
}

test "parse real btree declarations" {
    var arena = try Arena.init(16 * 1024 * 1024);
    defer arena.deinit();
    const source = try read_test_file(&arena, "vendor/tlaplus-examples/specifications/btree/btree.tla");
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    var found_is_leaf = false;
    for (module.variables) |v| {
        if (std.mem.eql(u8, v, "isLeaf")) found_is_leaf = true;
    }
    try std.testing.expect(found_is_leaf);
}

test "load real btree preserves root variables" {
    var arena = try Arena.init(64 * 1024 * 1024);
    defer arena.deinit();
    const search_paths = [_][]const u8{
        "vendor/tlaplus-examples/specifications/btree",
        "specs/modules",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-examples/specifications",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load("vendor/tlaplus-examples/specifications/btree/btree.tla");
    var found_is_leaf = false;
    for (module.variables) |v| {
        if (std.mem.eql(u8, v, "isLeaf")) found_is_leaf = true;
    }
    try std.testing.expect(found_is_leaf);
}

test "repeated namespace instances load every qualified definition" {
    var arena = try Arena.init(64 * 1024 * 1024);
    defer arena.deinit();
    const search_paths = [_][]const u8{
        "vendor/tlaplus-examples/specifications/SpecifyingSystems/FIFO",
        "specs/modules",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-examples/specifications",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load("vendor/tlaplus-examples/specifications/SpecifyingSystems/FIFO/APInnerFIFO.tla");
    var found_in = false;
    var found_out = false;
    for (module.definitions) |def| {
        if (std.mem.eql(u8, def.name, "InChan!Init")) found_in = true;
        if (std.mem.eql(u8, def.name, "OutChan!Init")) found_out = true;
    }
    try std.testing.expect(found_in);
    try std.testing.expect(found_out);
}

test "embedded modules take precedence over external modules with the same name" {
    var arena = try Arena.init(32 * 1024 * 1024);
    defer arena.deinit();
    const search_paths = [_][]const u8{
        "specs/modules",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-examples/specifications",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load(
        "vendor/tlaplus-examples/specifications/braf/BufferedRandomAccessFile.tla",
    );
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    try std.testing.expect(evaluator.find_definition("Array") != null);
    try std.testing.expect(evaluator.find_definition("RAF!Write") != null);
}

test "top-level instance after theorem remains visible to the loader" {
    var arena = try Arena.init(32 * 1024 * 1024);
    defer arena.deinit();
    const search_paths = [_][]const u8{
        "vendor/tlaplus-examples/specifications/byihive",
        "specs/modules",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-examples/specifications",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load(
        "vendor/tlaplus-examples/specifications/byihive/VoucherIssue.tla",
    );
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    try std.testing.expect(evaluator.find_definition("VSpec") != null);
}

test "instance substitutions rewrite primed variables in both copies" {
    var arena = try Arena.init(128 * 1024 * 1024);
    defer arena.deinit();
    const search_paths = [_][]const u8{
        "vendor/tlaplus-examples/specifications/DieHard",
        "specs/modules",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-community-modules/modules",
        "vendor/tlaplus-examples/specifications",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load("vendor/tlaplus-examples/specifications/DieHard/MCDieHardest.tla");
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    const compiler = action.ActionCompiler.init(&arena, evaluator);
    const d1 = evaluator.find_definition("D1!Next") orelse return error.UndefinedSymbol;
    const d2 = evaluator.find_definition("D2!Next") orelse return error.UndefinedSymbol;
    const d1_next = try compiler.compile_next(d1.body);
    const d2_next = try compiler.compile_next(d2.body);
    try std.testing.expect(steps_assign_primed(d1_next.steps, "c1"));
    try std.testing.expect(steps_assign_primed(d2_next.steps, "c2"));
    try std.testing.expect(!steps_assign_primed(d1_next.steps, "contents"));
    try std.testing.expect(!steps_assign_primed(d2_next.steps, "contents"));
}

test "load EWD998Chan retains root message actions" {
    var arena = try Arena.init(128 * 1024 * 1024);
    defer arena.deinit();
    const search_paths = [_][]const u8{
        "vendor/tlaplus-examples/specifications/ewd998",
        "specs/modules",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-community-modules/modules",
        "vendor/tlaplus-examples/specifications",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load(
        "vendor/tlaplus-examples/specifications/ewd998/EWD998Chan.tla",
    );
    const evaluator = try eval.Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    try std.testing.expect(evaluator.find_definition("SendMsg") != null);
    try std.testing.expect(evaluator.find_definition("RecvMsg") != null);
    try std.testing.expect(evaluator.find_definition("Environment") != null);
    try std.testing.expect(evaluator.find_definition("EWD998!RecvMsg") != null);
}

test "compile real btree init as assignments" {
    var arena = try Arena.init(64 * 1024 * 1024);
    defer arena.deinit();
    const search_paths = [_][]const u8{
        "vendor/tlaplus-examples/specifications/btree",
        "specs/modules",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-examples/specifications",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load("vendor/tlaplus-examples/specifications/btree/btree.tla");
    var evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    const compiler = action.ActionCompiler.init(&arena, evaluator);
    const init_def = evaluator.find_definition("Init") orelse return error.UndefinedSymbol;
    const compiled = try compiler.compile_init(init_def.body);
    try std.testing.expect(compiled.steps.len >= 12);
    try std.testing.expect(compiled.steps[0] == .assign_var);
    try std.testing.expectEqualStrings("isLeaf", compiled.steps[0].assign_var.var_name);
}

test "action if false branch commits done state" {
    const source =
        \\---------------------- MODULE TestActionIf ----------------------
        \\EXTENDS Integers
        \\VARIABLES low, high, result, pc
        \\vars == << low, high, result, pc >>
        \\a == /\ pc = "a"
        \\     /\ IF low =< high /\ result = 0
        \\           THEN /\ result' = 1
        \\                /\ UNCHANGED << low, high, pc >>
        \\           ELSE /\ pc' = "Done"
        \\                /\ UNCHANGED << low, high, result >>
        \\Next == a
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    var evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    const compiler = action.ActionCompiler.init(&arena, evaluator);
    const next_def = evaluator.find_definition("Next").?;
    const compiled = try compiler.compile_next(next_def.body);

    var store = try @import("state.zig").StateStore.init(&arena, module.variables, 8, 256, 256);
    const s0_idx = try store.alloc_state();
    const done = try store.values_pool.push_string("a");
    const s0 = store.get(s0_idx);
    s0.values[0] = .{ .int_v = 5 };
    s0.values[1] = .{ .int_v = 4 };
    s0.values[2] = .{ .int_v = 0 };
    s0.values[3] = .{ .string_v = done };

    var eval_arena = try Arena.init(1024 * 1024);
    defer eval_arena.deinit();
    var eval_pool = try value.ValuePool.init(&eval_arena, 1024, 1024);
    const executor = action.ActionExecutor{
        .evaluator = evaluator,
        .source_state_store = &store,
        .candidate_store = &store,
        .eval_pool = &eval_pool,
    };
    var out = try action.StateBuffer.init(&arena, 32);
    try executor.execute_next(compiled, s0_idx, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    const next = store.get(out.items[0]);
    try std.testing.expectEqual(@as(i64, 5), next.values[0].int_v);
    try std.testing.expectEqual(@as(i64, 4), next.values[1].int_v);
    try std.testing.expectEqual(@as(i64, 0), next.values[2].int_v);
    try std.testing.expectEqualStrings("Done", next.values[3].string_v.slice(&store.values_pool));
}

test "multi-variable existential action expands every binding" {
    const source =
        \\---------------------- MODULE TestMultiChoose ----------------------
        \\EXTENDS Naturals
        \\VARIABLES x, y
        \\Next == \E a \in 1..2, b \in 3..4:
        \\          /\ x' = a
        \\          /\ y' = b
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    const compiler = action.ActionCompiler.init(&arena, evaluator);
    const next_def = evaluator.find_definition("Next").?;
    const compiled = try compiler.compile_next(next_def.body);
    try std.testing.expectEqual(@as(usize, 1), compiled.steps.len);
    try std.testing.expect(compiled.steps[0] == .choose);
    try std.testing.expect(compiled.steps[0].choose.body_steps[0] == .choose);

    var store = try @import("state.zig").StateStore.init(&arena, module.variables, 8, 256, 64);
    const s0_idx = try store.alloc_state();
    const s0 = store.get(s0_idx);
    s0.values[0] = .{ .int_v = 0 };
    s0.values[1] = .{ .int_v = 0 };

    var eval_arena = try Arena.init(1024 * 1024);
    defer eval_arena.deinit();
    var eval_pool = try value.ValuePool.init(&eval_arena, 1024, 64);
    const executor = action.ActionExecutor{
        .evaluator = evaluator,
        .source_state_store = &store,
        .candidate_store = &store,
        .eval_pool = &eval_pool,
    };
    var out = try action.StateBuffer.init(&arena, 32);
    try executor.execute_next(compiled, s0_idx, &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len);

    var seen: u4 = 0;
    for (out.items) |state_idx| {
        const next = store.get(state_idx);
        const x: u2 = @intCast(next.values[0].int_v - 1);
        const y: u2 = @intCast(next.values[1].int_v - 3);
        seen |= @as(u4, 1) << @intCast(x * 2 + y);
    }
    try std.testing.expectEqual(@as(u4, 0b1111), seen);
}

test "parameterized LET operator remains in action scope" {
    const source =
        \\---------------------- MODULE TestActionLet ----------------------
        \\EXTENDS Naturals
        \\VARIABLE x
        \\Next ==
        \\  LET Max(a, b) == IF a > b THEN a ELSE b IN
        \\  x' = Max(1, 2)
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    const compiler = action.ActionCompiler.init(&arena, evaluator);
    const next_def = evaluator.find_definition("Next").?;
    const compiled = try compiler.compile_next(next_def.body);

    var store = try @import("state.zig").StateStore.init(&arena, module.variables, 4, 128, 64);
    const s0_idx = try store.alloc_state();
    store.get(s0_idx).values[0] = .{ .int_v = 0 };
    var eval_arena = try Arena.init(1024 * 1024);
    defer eval_arena.deinit();
    var eval_pool = try value.ValuePool.init(&eval_arena, 256, 64);
    const executor = action.ActionExecutor{
        .evaluator = evaluator,
        .source_state_store = &store,
        .candidate_store = &store,
        .eval_pool = &eval_pool,
    };
    var out = try action.StateBuffer.init(&arena, 32);
    try executor.execute_next(compiled, s0_idx, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(i64, 2), store.get(out.items[0]).values[0].int_v);
}

test "CASE action executes first matching branch" {
    const source =
        \\---------------------- MODULE TestActionCase ----------------------
        \\EXTENDS Naturals
        \\VARIABLE x
        \\Next == CASE x = 0 -> x' = 1
        \\         [] x = 1 -> x' = 2
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    const compiler = action.ActionCompiler.init(&arena, evaluator);
    const next_def = evaluator.find_definition("Next").?;
    const compiled = try compiler.compile_next(next_def.body);

    var store = try @import("state.zig").StateStore.init(&arena, module.variables, 4, 128, 64);
    const s0_idx = try store.alloc_state();
    store.get(s0_idx).values[0] = .{ .int_v = 0 };
    var eval_arena = try Arena.init(1024 * 1024);
    defer eval_arena.deinit();
    var eval_pool = try value.ValuePool.init(&eval_arena, 256, 64);
    const executor = action.ActionExecutor{
        .evaluator = evaluator,
        .source_state_store = &store,
        .candidate_store = &store,
        .eval_pool = &eval_pool,
    };
    var out = try action.StateBuffer.init(&arena, 32);
    try executor.execute_next(compiled, s0_idx, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(i64, 1), store.get(out.items[0]).values[0].int_v);
}

test "spec-shaped temporal property is checked from initial states" {
    const source =
        \\---------------------- MODULE TestSpecProperty ----------------------
        \\EXTENDS Naturals
        \\VARIABLE x
        \\Init == x = 0
        \\Next == x' = 1
        \\Spec == Init /\ [][Next]_x
        \\Refinement == Spec
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(16 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const cfg = config.Config{
        .spec_name = "Spec",
        .init_name = null,
        .next_name = null,
        .invariants = &.{},
        .properties = &.{"Refinement"},
        .constants = &.{},
        .constraints = &.{},
        .action_constraints = &.{},
        .check_deadlock = false,
    };
    var model_checker = try checker.Checker.init(
        &arena,
        module,
        cfg,
        16,
        4096,
        1024,
        4096,
        1024,
        4 * 1024 * 1024,
        overrides.OverrideContext.default(),
        1,
    );
    defer model_checker.deinit();
    const result = try model_checker.check();
    try std.testing.expectEqual(@as(u64, 2), result.distinct);
}

test "recursive action property may update derived view" {
    const source =
        \\---------------------- MODULE TestRecursiveActionProperty ----------------------
        \\EXTENDS Naturals
        \\VARIABLE x
        \\view == x
        \\Init == x = 0
        \\Next == x' = 1
        \\Spec == Init /\ [][Next]_x
        \\RECURSIVE AbsStep(_, _)
        \\AbsStep(n, next_view) ==
        \\    IF n = 0
        \\    THEN view' = next_view
        \\    ELSE AbsStep(n - 1, 1)
        \\AbsInit == view = 0
        \\AbsNext == AbsStep(1, view)
        \\Refinement == AbsInit /\ [][AbsNext]_view
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(16 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const cfg = config.Config{
        .spec_name = "Spec",
        .init_name = null,
        .next_name = null,
        .invariants = &.{},
        .properties = &.{"Refinement"},
        .constants = &.{},
        .constraints = &.{},
        .action_constraints = &.{},
        .check_deadlock = false,
    };
    var model_checker = try checker.Checker.init(
        &arena,
        module,
        cfg,
        16,
        4096,
        1024,
        4096,
        1024,
        4 * 1024 * 1024,
        overrides.OverrideContext.default(),
        1,
    );
    defer model_checker.deinit();
    const result = try model_checker.check();
    try std.testing.expectEqual(@as(u64, 2), result.distinct);
}

test "recursive action property may update chosen function view" {
    const source =
        \\---------------------- MODULE TestChosenFunctionViewProperty ----------------------
        \\EXTENDS Naturals
        \\VARIABLE x
        \\Keys == {"k1", "k2"}
        \\Read(k) ==
        \\    IF x = 0 \/ k = "k2"
        \\    THEN {0}
        \\    ELSE {1}
        \\view == [k \in Keys |-> CHOOSE r \in Read(k) : TRUE]
        \\Init == x = 0
        \\Next == x' = 1
        \\Spec == Init /\ [][Next]_x
        \\RECURSIVE AbsStep(_, _)
        \\AbsStep(n, next_view) ==
        \\    IF n = 0
        \\    THEN view' = next_view
        \\    ELSE AbsStep(n - 1, [next_view EXCEPT !["k1"] = 1])
        \\AbsInit == view = [k \in Keys |-> 0]
        \\AbsNext == AbsStep(1, view)
        \\Refinement == AbsInit /\ [][AbsNext]_view
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(16 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const cfg = config.Config{
        .spec_name = "Spec",
        .init_name = null,
        .next_name = null,
        .invariants = &.{},
        .properties = &.{"Refinement"},
        .constants = &.{},
        .constraints = &.{},
        .action_constraints = &.{},
        .check_deadlock = false,
    };
    var model_checker = try checker.Checker.init(
        &arena,
        module,
        cfg,
        16,
        4096,
        1024,
        4096,
        1024,
        4 * 1024 * 1024,
        overrides.OverrideContext.default(),
        1,
    );
    defer model_checker.deinit();
    const result = try model_checker.check();
    try std.testing.expectEqual(@as(u64, 2), result.distinct);
}

test "parallel exploration preserves branching temporal state space" {
    const source =
        \\---------------------- MODULE TestParallel ----------------------
        \\EXTENDS Naturals
        \\VARIABLES x, y
        \\Init == x = 0 /\ y = 0
        \\Next == \/ /\ x < 2
        \\           /\ x' = x + 1
        \\           /\ UNCHANGED y
        \\        \/ /\ y < 2
        \\           /\ y' = y + 1
        \\           /\ UNCHANGED x
        \\Spec == Init /\ [][Next]_<<x, y>>
        \\TypeOK == x \in 0..2 /\ y \in 0..2
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(32 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const cfg = config.Config{
        .spec_name = "Spec",
        .init_name = null,
        .next_name = null,
        .invariants = &.{"TypeOK"},
        .properties = &.{},
        .constants = &.{},
        .constraints = &.{},
        .action_constraints = &.{},
        .check_deadlock = false,
    };
    var model_checker = try checker.Checker.init(
        &arena,
        module,
        cfg,
        64,
        16_384,
        4096,
        16_384,
        4096,
        4 * 1024 * 1024,
        overrides.OverrideContext.default(),
        4,
    );
    defer model_checker.deinit();
    const result = try model_checker.check();
    try std.testing.expectEqual(@as(u64, 9), result.distinct);
}

test "action constraints filter transitions but not initial states" {
    const source =
        \\---------------------- MODULE TestActionConstraint ----------------------
        \\EXTENDS Naturals
        \\VARIABLE x
        \\Init == x = 0
        \\Next == x' \in 0..2
        \\OnlyIncrement == x' = x + 1
        \\Spec == Init /\ [][Next]_x
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(32 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const cfg = config.Config{
        .spec_name = "Spec",
        .init_name = null,
        .next_name = null,
        .invariants = &.{},
        .properties = &.{},
        .constants = &.{},
        .constraints = &.{},
        .action_constraints = &.{"OnlyIncrement"},
        .check_deadlock = false,
    };
    var model_checker = try checker.Checker.init(
        &arena,
        module,
        cfg,
        64,
        16_384,
        4096,
        16_384,
        4096,
        4 * 1024 * 1024,
        overrides.OverrideContext.default(),
        4,
    );
    defer model_checker.deinit();
    const result = try model_checker.check();
    try std.testing.expectEqual(@as(u64, 3), result.distinct);
}

test "compound temporal property checks boxed action transitions" {
    const source =
        \\---------------------- MODULE TestBadRefinement ----------------------
        \\EXTENDS Naturals
        \\VARIABLE x
        \\Init == x = 0
        \\Next == x' = 1
        \\Spec == Init /\ [][Next]_x
        \\BadNext == x' = x
        \\BadRefinement == Init /\ [][BadNext]_x
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(16 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const cfg = config.Config{
        .spec_name = "Spec",
        .init_name = null,
        .next_name = null,
        .invariants = &.{},
        .properties = &.{"BadRefinement"},
        .constants = &.{},
        .constraints = &.{},
        .action_constraints = &.{},
        .check_deadlock = false,
    };
    var model_checker = try checker.Checker.init(
        &arena,
        module,
        cfg,
        16,
        4096,
        1024,
        4096,
        1024,
        4 * 1024 * 1024,
        overrides.OverrideContext.default(),
        1,
    );
    defer model_checker.deinit();
    try std.testing.expectError(error.PropertyViolated, model_checker.check());
}

test "UNCHANGED expression checks parent and next state" {
    const source =
        \\---------------------- MODULE TestUnchangedExpression ----------------------
        \\EXTENDS Naturals
        \\VARIABLES x, y
        \\vars == <<x, y>>
        \\Init == /\ x = 0
        \\        /\ y = 0
        \\Next == /\ x = 0
        \\        /\ x' = 1
        \\        /\ y' = 0
        \\CountUnchanged == UNCHANGED (x + y)
        \\Preservation == [][CountUnchanged]_vars
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(16 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    const count_unchanged = evaluator.find_definition("CountUnchanged") orelse
        return error.UndefinedSymbol;
    try std.testing.expect(count_unchanged.body.* == .unchanged_expr);
    const cfg = config.Config{
        .spec_name = null,
        .init_name = "Init",
        .next_name = "Next",
        .invariants = &.{},
        .properties = &.{"Preservation"},
        .constants = &.{},
        .constraints = &.{},
        .action_constraints = &.{},
        .check_deadlock = false,
    };
    var model_checker = try checker.Checker.init(
        &arena,
        module,
        cfg,
        16,
        4096,
        1024,
        4096,
        1024,
        4 * 1024 * 1024,
        overrides.OverrideContext.default(),
        1,
    );
    defer model_checker.deinit();
    try std.testing.expectError(error.PropertyViolated, model_checker.check());
}

test "numeric subexpression selectors resolve list conjuncts" {
    const source =
        \\---------------------- MODULE TestSubexpression ----------------------
        \\Inv == /\ TRUE
        \\       /\ FALSE
        \\       /\ TRUE
        \\First == Inv!1
        \\Second == Inv!2
        \\Third == Inv!3
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 128, 64);
    var state_pool = try value.ValuePool.init(&arena, 128, 64);

    const first = evaluator.find_definition("First") orelse return error.UndefinedSymbol;
    const second = evaluator.find_definition("Second") orelse return error.UndefinedSymbol;
    const third = evaluator.find_definition("Third") orelse return error.UndefinedSymbol;
    try std.testing.expect((try evaluator.eval_expr(first.body, eval.Context.empty(), null, &pool, &state_pool)).is_truthy());
    try std.testing.expect(!(try evaluator.eval_expr(second.body, eval.Context.empty(), null, &pool, &state_pool)).is_truthy());
    try std.testing.expect((try evaluator.eval_expr(third.body, eval.Context.empty(), null, &pool, &state_pool)).is_truthy());
}

test "quantifiers destructure tuple-bound variables" {
    const source =
        \\---------------------- MODULE TestTupleQuantifier ----------------------
        \\EXTENDS Naturals
        \\Ok == \A <<x, y>> \in {<<1, 2>>, <<2, 3>>} : x < y
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 128, 64);
    var state_pool = try value.ValuePool.init(&arena, 128, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "implication scopes over a bulleted conjunction" {
    const source =
        \\---------------------- MODULE TestBulletImplies ----------------------
        \\Formula == /\ FALSE
        \\           /\ TRUE
        \\           => FALSE
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 64, 64);
    var state_pool = try value.ValuePool.init(&arena, 64, 64);
    const formula = evaluator.find_definition("Formula") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(formula.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "same-line implication stays inside its bullet item" {
    const source =
        \\---------------------- MODULE TestBulletItemImplies ----------------------
        \\Action == /\ FALSE => FALSE
        \\          /\ FALSE
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 64, 64);
    var state_pool = try value.ValuePool.init(&arena, 64, 64);
    const action_def = evaluator.find_definition("Action") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(action_def.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(!result.is_truthy());
}

test "parenthesized implication can return a bulleted conjunction" {
    const source =
        \\---------------------- MODULE TestParenthesizedImpliesList ----------------------
        \\EXTENDS Naturals
        \\WC == "majority"
        \\epoch == 1
        \\commitIndex == 2
        \\WriteCanSucceed(token) ==
        \\    /\ TRUE
        \\    /\ (WC = "majority" =>
        \\        /\ token.epoch = epoch
        \\        /\ token.checkpoint <= commitIndex)
        \\Ok == WriteCanSucceed([epoch |-> 1, checkpoint |-> 2])
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    var pool = try value.ValuePool.init(&arena, 128, 64);
    var state_pool = try value.ValuePool.init(&arena, 128, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(
        ok.body,
        eval.Context.empty(),
        null,
        &pool,
        &state_pool,
    );
    try std.testing.expect(result.is_truthy());
}

test "inline first bullet may dedent to the definition list column" {
    const source =
        \\---------------------- MODULE TestDedentedList ----------------------
        \\EXTENDS Naturals
        \\Op(p) == /\ p = 1
        \\         /\ \E q \in 1..2 :
        \\               /\ q = 2
        \\               /\ p + q = 3
        \\         /\ p < 2
        \\Ok == Op(1)
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 128, 64);
    var state_pool = try value.ValuePool.init(&arena, 128, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "recursive function definition accepts multiple bounded arguments" {
    const source =
        \\---------------------- MODULE TestMultiFunction ----------------------
        \\EXTENDS Naturals
        \\F[n \in 0..2, v \in 1..2] ==
        \\    IF n = 0 THEN v ELSE F[n - 1, v] + 1
        \\Ok == F[2, 1] = 3
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 256, 64);
    var state_pool = try value.ValuePool.init(&arena, 256, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "UNCHANGED accepts an instance-qualified tuple name" {
    const source =
        \\---------------------- MODULE TestQualifiedUnchanged ----------------------
        \\VARIABLE x
        \\Ok == [][TRUE => UNCHANGED RAF!vars]_x
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    var found = false;
    for (module.definitions) |def| {
        if (std.mem.eql(u8, def.name, "Ok")) found = true;
    }
    try std.testing.expect(found);
}

test "singleton function binds tighter than function override" {
    const source =
        \\---------------------- MODULE TestFunctionOverride ----------------------
        \\F == "j1" :> 5 @@ "j2" :> 3
        \\Ok == /\ F["j1"] = 5
        \\      /\ F["j2"] = 3
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 128, 128);
    var state_pool = try value.ValuePool.init(&arena, 128, 128);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "function definition destructures tuple domain element" {
    const source =
        \\---------------------- MODULE TestTupleFunction ----------------------
        \\F[<<x, y>> \in {<<1, 2>>}] == x + y
        \\Apply(g) == g[<<1, 2>>]
        \\Ok == Apply(F) = 3
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 128, 64);
    var state_pool = try value.ValuePool.init(&arena, 128, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "parameterized definitions inherit caller context" {
    const source =
        \\---------------------- MODULE TestContext ----------------------
        \\VARIABLES x
        \\Use(a) == x = a
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const expr = try parser.Parser.parse_expr_string(&arena, "Use(1)");
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 64, 64);
    var state_pool = try value.ValuePool.init(&arena, 64, 64);
    const ctx = try evaluator.extend_context(
        eval.Context.empty(),
        "x",
        .{ .int_v = 1 },
    );
    const result = try evaluator.eval_expr(expr, ctx, null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "Permutations returns functions over model values" {
    const source =
        \\---------------------- MODULE TestPermutations ----------------------
        \\EXTENDS TLC
        \\=============================================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const expr = try parser.Parser.parse_expr_string(
        &arena,
        "Permutations({a, b})",
    );
    var evaluator = try eval.Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    evaluator.set_treat_unknown_as_model(true);
    var pool = try value.ValuePool.init(&arena, 128, 64);
    const result = try evaluator.eval_expr(
        expr,
        eval.Context.empty(),
        null,
        &pool,
        &pool,
    );
    try std.testing.expect(result == .set_v);
    try std.testing.expectEqual(@as(u32, 2), result.set_v.len);

    var found_swap = false;
    for (result.set_v.items(&pool)) |permutation| {
        try std.testing.expect(permutation == .function_v);
        try std.testing.expectEqual(
            @as(u32, 2),
            permutation.function_v.domain.len,
        );
        const keys = permutation.function_v.domain.items(&pool);
        const entries = permutation.function_v.entries(&pool);
        if (keys[0].model_v == entries[1].model_v and
            keys[1].model_v == entries[0].model_v)
        {
            found_swap = true;
        }
    }
    try std.testing.expect(found_swap);
}

test "local LET operator shadows a global definition" {
    const source =
        \\---------------------- MODULE TestLocalShadow ----------------------
        \\Max(S) == CHOOSE x \in S : TRUE
        \\Result ==
        \\    LET Max(a, b) == IF a > b THEN a ELSE b
        \\    IN Max(2, 3)
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(4 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    var pool = try value.ValuePool.init(&arena, 4096, 1024);
    const result = try evaluator.eval_expr(
        evaluator.find_definition("Result").?.body,
        eval.Context.empty(),
        null,
        &pool,
        &pool,
    );
    try std.testing.expectEqual(@as(i64, 3), result.int_v);
}

test "parse transitive closure definition with local operator" {
    const source =
        \\---------------- MODULE TestTransitiveClosure ----------------
        \\Support(R) == {r[1] : r \in R} \cup {r[2] : r \in R}
        \\TC1(R) ==
        \\  LET BoundedSeq(S, n) == UNION {[1..i -> S] : i \in 0..n}
        \\      S == Support(R)
        \\  IN  {<<s, t>> \in S \X S :
        \\        \E p \in BoundedSeq(S, Cardinality(S)+1) :
        \\          /\ Len(p) > 1
        \\          /\ p[1] = s
        \\          /\ p[Len(p)] = t
        \\          /\ \A i \in 1..(Len(p)-1) : <<p[i], p[i+1]>> \in R}
        \\===============================================================
        \\
    ;
    var arena = try Arena.init(4 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqual(@as(usize, 2), module.definitions.len);
    try std.testing.expectEqualStrings("TC1", module.definitions[1].name);
}

test "parse primed temporal function application" {
    const source =
        \\---------------- MODULE TestTemporalPrime ----------------
        \\NoNewSource ==
        \\  [][\A n \in Nodes : kind(n)' = "source" => kind(n) = "source"]_vars
        \\Termination == \A n \in Nodes : mailbox[n] = {}
        \\FinishIffTerminated == ~(ENABLED Next) <=> Termination
        \\===========================================================
        \\
    ;
    var arena = try Arena.init(2 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqual(@as(usize, 3), module.definitions.len);
    try std.testing.expectEqualStrings("NoNewSource", module.definitions[0].name);
    try std.testing.expectEqualStrings("FinishIffTerminated", module.definitions[2].name);
}

test "parameterized operator can be passed as a value" {
    const source =
        \\---------------------- MODULE TestHigherOrder ----------------------
        \\Inc(x) == x + 1
        \\Apply(op) == op(1)
        \\Ok == Apply(Inc) = 2
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 128, 64);
    var state_pool = try value.ValuePool.init(&arena, 128, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "multi-variable function literal belongs to cartesian function set" {
    const source =
        \\---------------------- MODULE TestFunctionSet ----------------------
        \\EXTENDS Naturals
        \\Ok == [n \in 1..2, k \in 1..2 |-> 0] \in [1..2 \X 1..2 -> {0}]
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 256, 64);
    var state_pool = try value.ValuePool.init(&arena, 256, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "nested function set membership remains symbolic" {
    const source =
        \\---------------------- MODULE TestNestedFunctionSet ----------------------
        \\EXTENDS Naturals
        \\CONSTANT Node
        \\Value == [n \in Node |-> [o \in Node |-> 0]]
        \\TypeOK == Value \in [Node -> [Node -> Nat]]
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(8 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    var evaluator = try eval.Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    evaluator.set_treat_unknown_as_model(true);
    var pool = try value.ValuePool.init(&arena, 16_384, 4096);
    const constants = try arena.alloc(eval.Constant, 1);
    const nodes = try pool.alloc_values(2);
    nodes[0] = .{ .model_v = try evaluator.models.intern("a") };
    nodes[1] = .{ .model_v = try evaluator.models.intern("b") };
    constants[0] = .{
        .name = "Node",
        .value = .{ .set_v = .{
            .offset = 0,
            .len = 2,
        } },
    };
    evaluator.set_constants(constants);
    evaluator.set_treat_unknown_as_model(false);
    const result = try evaluator.eval_expr(
        evaluator.find_definition("TypeOK").?.body,
        eval.Context.empty(),
        null,
        &pool,
        &pool,
    );
    try std.testing.expect(result.is_truthy());
}

test "tuple sequence literals belong to Seq" {
    const source =
        \\---------------------- MODULE TestSeq ----------------------
        \\EXTENDS Naturals, Sequences
        \\EmptyOk == <<>> \in Seq(1..2)
        \\NonEmptyOk == <<1, 2>> \in Seq(1..2)
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 1024, 64);
    var state_pool = try value.ValuePool.init(&arena, 1024, 64);
    const empty_ok = evaluator.find_definition("EmptyOk") orelse return error.UndefinedSymbol;
    const non_empty_ok = evaluator.find_definition("NonEmptyOk") orelse return error.UndefinedSymbol;
    try std.testing.expect((try evaluator.eval_expr(empty_ok.body, eval.Context.empty(), null, &pool, &state_pool)).is_truthy());
    try std.testing.expect((try evaluator.eval_expr(non_empty_ok.body, eval.Context.empty(), null, &pool, &state_pool)).is_truthy());
}

test "Seq membership is not limited by the enumeration bound" {
    const source =
        \\---------------------- MODULE TestUnboundedSeqMember ----------------------
        \\EXTENDS Sequences
        \\Ok == <<1, 1, 1, 1, 1, 1>> \in Seq({1})
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 128, 64);
    var state_pool = try value.ValuePool.init(&arena, 128, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "Seq membership remains symbolic inside a record set" {
    const source =
        \\---------------------- MODULE TestNestedSeqMember ----------------------
        \\EXTENDS Sequences
        \\Value == [elems |-> <<1, 1, 1, 1, 1, 1>>]
        \\Ok == Value \in [elems: Seq({1})]
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 128, 64);
    var state_pool = try value.ValuePool.init(&arena, 128, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "SUBSET membership remains symbolic inside a function set" {
    const source =
        \\---------------------- MODULE TestNestedSubsetMember ----------------------
        \\EXTENDS Naturals
        \\F == [i \in 1..2 |-> {i}]
        \\Ok == F \in [1..2 -> SUBSET (1..35)]
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 256, 64);
    var state_pool = try value.ValuePool.init(&arena, 256, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "SubSeq returns empty sequence when hi is below lo" {
    const source =
        \\---------------------- MODULE TestSubSeq ----------------------
        \\EXTENDS Sequences
        \\Ok == Len(SubSeq(<<1, 2>>, 1, 0)) = 0
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 256, 64);
    var state_pool = try value.ValuePool.init(&arena, 256, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "SubSeq and Tail renumber function-backed sequences from one" {
    const source =
        \\---------------------- MODULE TestRenumberedSequences ----------------------
        \\EXTENDS Naturals, Sequences
        \\F == [i \in 1..3 |-> i]
        \\Ok == /\ SubSeq(F, 2, 3) = <<2, 3>>
        \\      /\ Tail(F) = <<2, 3>>
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 256, 64);
    var state_pool = try value.ValuePool.init(&arena, 256, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "tuple and function sequence representations interoperate" {
    const source =
        \\---------------------- MODULE TestSequenceInterop ----------------------
        \\EXTENDS Naturals, Sequences
        \\F == [i \in 1..2 |-> i]
        \\Ok == /\ F = <<1, 2>>
        \\      /\ <<>> \o F = <<1, 2>>
        \\      /\ F \o <<3>> = <<1, 2, 3>>
        \\      /\ <<1>> \circ <<2>> = <<1, 2>>
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 256, 64);
    var state_pool = try value.ValuePool.init(&arena, 256, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "SelectSeq applies a unary operator to each sequence element" {
    const source =
        \\---------------------- MODULE TestSelectSeq ----------------------
        \\EXTENDS Sequences
        \\Read(pair) == pair[1] = "read"
        \\Input == <<<<"read", 1>>, <<"write", 2>>, <<"read", 3>>>>
        \\Expected == <<<<"read", 1>>, <<"read", 3>>>>
        \\Ok == SelectSeq(Input, Read) = Expected
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 32, 64);
    var state_pool = try value.ValuePool.init(&arena, 32, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "sets are canonical and infinite Nat stays symbolic" {
    const source =
        \\---------------------- MODULE TestSetSemantics ----------------------
        \\DuplicateSetOk == {1, 2, 2, 3, 3, 3} = {3, 2, 1}
        \\NatDifferenceOk == 40 \in Nat \ {0}
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 128, 64);
    var state_pool = try value.ValuePool.init(&arena, 128, 64);
    for (&[_][]const u8{ "DuplicateSetOk", "NatDifferenceOk" }) |name| {
        const def = evaluator.find_definition(name) orelse return error.UndefinedSymbol;
        const result = try evaluator.eval_expr(def.body, eval.Context.empty(), null, &pool, &state_pool);
        try std.testing.expect(result.is_truthy());
    }
}

test "DOMAIN of a record returns its field names" {
    const source =
        \\---------------------- MODULE TestRecordDomain ----------------------
        \\R == [alpha |-> 1, beta |-> 2]
        \\Result == DOMAIN R
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(4 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    var evaluator = try eval.Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    var pool = try value.ValuePool.init(&arena, 4096, 4096);
    const result = try evaluator.eval_expr(
        evaluator.find_definition("Result").?.body,
        eval.Context.empty(),
        null,
        &pool,
        &pool,
    );
    try std.testing.expect(result == .set_v);
    try std.testing.expect(result.member(
        &pool,
        value.Value{ .string_v = try pool.push_string("alpha") },
    ));
    try std.testing.expect(result.member(
        &pool,
        value.Value{ .string_v = try pool.push_string("beta") },
    ));
}

test "FoldFunctionOnSet folds without recursive set allocation" {
    const source =
        \\---------------------- MODULE TestFoldFunction ----------------------
        \\F == [i \in 1..4 |-> i]
        \\Ok == Functions!FoldFunctionOnSet(+, 0, F, 1..4) = 10
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 128, 64);
    var state_pool = try value.ValuePool.init(&arena, 128, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "user FoldFunctionOnSet definition is not bypassed by module override" {
    const source =
        \\---------------------- MODULE TestFoldFunctionShadow ----------------------
        \\FoldFunctionOnSet(op(_, _), base, fun, indices) == 42
        \\F == [i \in 1..4 |-> i]
        \\Ok == FoldFunctionOnSet(+, 0, F, 1..4) = 42
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(module, &arena, overrides.OverrideContext.default());
    var pool = try value.ValuePool.init(&arena, 128, 64);
    var state_pool = try value.ValuePool.init(&arena, 128, 64);
    const ok = evaluator.find_definition("Ok") orelse return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(ok.body, eval.Context.empty(), null, &pool, &state_pool);
    try std.testing.expect(result.is_truthy());
}

test "parser retains assumptions" {
    const source =
        \\---------------------- MODULE TestAssumptions ----------------------
        \\ASSUME 40 \in Nat \ {0}
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqual(@as(usize, 1), module.assumptions.len);
}

test "TLCGet config exposes bfs mode record" {
    const source =
        \\---------------------- MODULE TestTLCGetConfig ----------------------
        \\EXTENDS TLC
        \\ModeOK == TLCGet("config").mode = "bfs"
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    var pool = try value.ValuePool.init(&arena, 128, 128);
    var state_pool = try value.ValuePool.init(&arena, 128, 128);
    const mode_ok = evaluator.find_definition("ModeOK") orelse
        return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(
        mode_ok.body,
        eval.Context.empty(),
        null,
        &pool,
        &state_pool,
    );
    try std.testing.expect(result.is_truthy());
}

test "module terminator tolerates one consumed equals pair" {
    const source =
        \\---------------------- MODULE TestTerminator ----------------------
        \\EXTENDS Naturals
        \\CONSTANT MaxNat
        \\ASSUME MaxNat \in Nat
        \\NatOverride == 0..MaxNat
        \\ASSUME TRUE
        \\=================================================================
        \\
    ;
    var arena = try Arena.init(4 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqual(@as(usize, 2), module.assumptions.len);
}

test "identifier assumption does not consume next-line terminator" {
    const source =
        \\---------------------- MODULE TestAssumeTerminator ----------------------
        \\T1 == TRUE
        \\ASSUME T1
        \\=======================================================================
        \\
    ;
    var arena = try Arena.init(4 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqual(@as(usize, 1), module.assumptions.len);
}

test "parameterized definition keeps its name column as expression boundary" {
    const source =
        \\---------------------- MODULE TestActionCompositionParse ----------------------
        \\Increment(n) == n' = n + 1
        \\Reduction == TRUE
        \\IncrementAndReduction(n) ==
        \\    Increment(n) \cdot Reduction
        \\GossipAndReduction(n, o) ==
        \\    Increment(n) \cdot Reduction
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(4 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    try std.testing.expect(evaluator.find_definition(
        "IncrementAndReduction",
    ) != null);
    try std.testing.expect(evaluator.find_definition(
        "GossipAndReduction",
    ) != null);
}

test "parameterized namespace call flattens instance and operator arguments" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    const expression = try parser.Parser.parse_expr_string(
        &arena,
        "Storage(s)!StartTransaction(s, tid, ts, rc, ignore)",
    );
    try std.testing.expect(expression.* == .apply);
    try std.testing.expect(expression.apply.func.* == .ident);
    try std.testing.expectEqualStrings(
        "Storage!StartTransaction",
        expression.apply.func.ident,
    );
    try std.testing.expectEqual(@as(usize, 6), expression.apply.args.len);
}

test "MDBProps parses through parenthesized bag infix operators" {
    var arena = try Arena.init(16 * 1024 * 1024);
    defer arena.deinit();
    const source = try read_test_file(
        &arena,
        "vendor/MDBTLA/SingleLog/MDBProps.tla",
    );
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try expect_definition(module, "WriteCanSucceed");
    try expect_definition(module, "AddToBag");
    try expect_definition(module, "RemoveFromBag");
    try expect_definition(module, "PointsValid");
    try expect_definition(module, "CommitIndexImpliesDurability");
    try expect_definition(module, "WritesEventuallyComplete");
    try expect_definition(module, "ObsoleteValues");
    try expect_definition(module, "StrongConsistencyCommittedWritesDurable");
    try expect_definition(module, "ReadYourWrites");
}

test "parse parenthesized minus infix expression" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    const expression = try parser.Parser.parse_expr_string(
        &arena,
        "bag (-) SetToBag({elem})",
    );
    try std.testing.expect(expression.* == .apply);
    try std.testing.expect(expression.apply.func.* == .ident);
    try std.testing.expectEqualStrings("(-)", expression.apply.func.ident);
}

test "leads-to property stops before following definition" {
    const source =
        \\---------------------- MODULE TestLeadsToBoundary ----------------------
        \\EXTENDS Naturals
        \\VARIABLE writeHistory
        \\WritesEventuallyComplete ==
        \\    \A token \in SessionTokens :
        \\        /\ \E record \in DOMAIN writeHistory :
        \\            /\ record.token = token
        \\            /\ record.state = WriteInitState
        \\        ~>
        \\        /\ \E record \in DOMAIN writeHistory :
        \\            /\ record.token = token
        \\            /\ record.state \in {
        \\                WriteSucceededState,
        \\                WriteFailedState
        \\               }
        \\
        \\---------------------------------------------------------------------
        \\
        \\ObsoleteValues(key) ==
        \\    { log[i].value : i \in { i \in DOMAIN log :
        \\        /\ i <= readIndex
        \\        /\ log[i].key = key
        \\        /\ \E j \in (i+1)..readIndex : log[j].key = key } }
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try expect_definition(module, "WritesEventuallyComplete");
    for (module.definitions) |definition| {
        if (std.mem.eql(u8, definition.name, "WritesEventuallyComplete") and
            expr_contains_ident(definition.body, "ObsoleteValues"))
        {
            return error.NextDefinitionConsumed;
        }
    }
    try expect_definition(module, "ObsoleteValues");
}

test "set map value may be a function path" {
    const source =
        \\---------------------- MODULE TestSetMapPathValue ----------------------
        \\EXTENDS Naturals
        \\ObsoleteValues(key) ==
        \\    { log[i].value : i \in { i \in DOMAIN log :
        \\        /\ i <= readIndex
        \\        /\ log[i].key = key
        \\        /\ \E j \in (i+1)..readIndex : log[j].key = key } }
        \\After == TRUE
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try expect_definition(module, "ObsoleteValues");
    try expect_definition(module, "After");
}

test "bulleted existential expression parses after leads-to" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    const expression = try parser.Parser.parse_expr_string(&arena,
        \\/\ \E record \in DOMAIN writeHistory :
        \\    /\ record.token = token
        \\    /\ record.state \in {
        \\        WriteSucceededState,
        \\        WriteFailedState
        \\       }
    );
    try std.testing.expect(expression.* == .quantifier or expression.* == .binary);
}

test "leads-to accepts bulleted existential RHS" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    const expression = try parser.Parser.parse_expr_string(&arena,
        \\/\ \E record \in DOMAIN writeHistory :
        \\    /\ record.token = token
        \\    /\ record.state = WriteInitState
        \\~>
        \\/\ \E record \in DOMAIN writeHistory :
        \\    /\ record.token = token
        \\    /\ record.state \in {
        \\        WriteSucceededState,
        \\        WriteFailedState
        \\       }
    );
    try std.testing.expect(expr_contains_ident(expression, "WriteFailedState"));
}

test "MDBProps loader keeps definitions after bag infix operators" {
    var arena = try Arena.init(32 * 1024 * 1024);
    defer arena.deinit();
    const search_paths = [_][]const u8{
        "vendor/MDBTLA/SingleLog",
        "vendor/tlaplus/tlatools/org.lamport.tlatools/src/tla2sany/StandardModules",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load("vendor/MDBTLA/SingleLog/MDBProps.tla");
    try expect_definition(module, "WriteCanSucceed");
    try expect_definition(module, "ReadYourWrites");
}

test "action composition publishes only the second action result" {
    const source =
        \\---------------------- MODULE TestActionComposition ----------------------
        \\EXTENDS Naturals
        \\VARIABLE x
        \\Init == x = 0
        \\First == /\ x = 0
        \\         /\ x' = 1
        \\Second == x' = x + 1
        \\Next == First \cdot Second
        \\Spec == Init /\ [][Next]_x
        \\TypeOK == x \in 0..2
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(32 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const cfg = config.Config{
        .spec_name = "Spec",
        .init_name = null,
        .next_name = null,
        .invariants = &.{"TypeOK"},
        .properties = &.{},
        .constants = &.{},
        .constraints = &.{},
        .action_constraints = &.{},
        .check_deadlock = false,
    };
    var model_checker = try checker.Checker.init(
        &arena,
        module,
        cfg,
        16,
        4096,
        1024,
        4096,
        1024,
        4 * 1024 * 1024,
        overrides.OverrideContext.default(),
        1,
    );
    defer model_checker.deinit();
    const result = try model_checker.check();
    try std.testing.expectEqual(@as(u64, 2), result.distinct);
}

test "FALSE operator substitution does not suppress other Next branches" {
    const source =
        \\---------------------- MODULE TestDisabledAction ----------------------
        \\EXTENDS Naturals
        \\CONSTANT Disabled
        \\VARIABLE x
        \\Init == x = 0
        \\Step == /\ x = 0
        \\        /\ x' = 1
        \\Next == Disabled \/ Step
        \\TypeOK == x \in 0..1
        \\==============================================================
        \\
    ;
    const cfg_source =
        \\INIT Init
        \\NEXT Next
        \\INVARIANT TypeOK
        \\CONSTANT Disabled <- FALSE
        \\CHECK_DEADLOCK FALSE
    ;
    var arena = try Arena.init(32 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const cfg = try config.parse(&arena, cfg_source);
    var model_checker = try checker.Checker.init(
        &arena,
        module,
        cfg,
        16,
        4096,
        1024,
        4096,
        1024,
        4 * 1024 * 1024,
        overrides.OverrideContext.default(),
        1,
    );
    defer model_checker.deinit();
    const result = try model_checker.check();
    try std.testing.expectEqual(@as(u64, 2), result.generated);
    try std.testing.expectEqual(@as(u64, 2), result.distinct);
}

test "operator formals shadow state variables in action RHS applications" {
    const source =
        \\---------------------- MODULE TestFormalShadowState ----------------------
        \\EXTENDS Naturals
        \\VARIABLE x, y
        \\Init == /\ x = [i \in 1..1 |-> 0]
        \\        /\ y = 0
        \\Read(x) == x[1]
        \\Next == /\ x' = [i \in 1..1 |-> 1]
        \\        /\ y' = Read(x')
        \\TypeOK == y = x[1]
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(16 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const cfg = config.Config{
        .spec_name = null,
        .init_name = "Init",
        .next_name = "Next",
        .invariants = &.{"TypeOK"},
        .properties = &.{},
        .constants = &.{},
        .constraints = &.{},
        .action_constraints = &.{},
        .check_deadlock = false,
    };
    var model_checker = try checker.Checker.init(
        &arena,
        module,
        cfg,
        16,
        4096,
        1024,
        4096,
        1024,
        4 * 1024 * 1024,
        overrides.OverrideContext.default(),
        1,
    );
    defer model_checker.deinit();
    const result = try model_checker.check();
    try std.testing.expectEqual(@as(u64, 2), result.distinct);
}

test "EXCEPT indexes nested records by string key" {
    const source =
        \\---------------------- MODULE TestRecordExcept ----------------------
        \\Value == [outer |-> [inner |-> 1]]
        \\Updated == [Value EXCEPT !["outer"]["inner"] = 2]
        \\Ok == Updated.outer.inner = 2
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(4 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    var pool = try value.ValuePool.init(&arena, 1024, 1024);
    const ok = evaluator.find_definition("Ok") orelse
        return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(
        ok.body,
        eval.Context.empty(),
        null,
        &pool,
        &pool,
    );
    try std.testing.expect(result.is_truthy());
}

test "record override replaces matching fields" {
    const source =
        \\---------------------- MODULE TestRecordOverride ----------------------
        \\Value == [a |-> 1, b |-> 2] @@ [b |-> 3, c |-> 4]
        \\Ok == /\ Value.a = 1
        \\      /\ Value.b = 3
        \\      /\ Value.c = 4
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(4 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const evaluator = try eval.Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    var pool = try value.ValuePool.init(&arena, 1024, 1024);
    const ok = evaluator.find_definition("Ok") orelse
        return error.UndefinedSymbol;
    const result = try evaluator.eval_expr(
        ok.body,
        eval.Context.empty(),
        null,
        &pool,
        &pool,
    );
    try std.testing.expect(result.is_truthy());
}

test "action LET observes pre-state when constructing a record" {
    const source =
        \\---------------------- MODULE TestActionLetRecord ----------------------
        \\EXTENDS Sequences
        \\VARIABLES participants, requests, count
        \\Range(f) == {f[x] : x \in DOMAIN f}
        \\CreateEntry(start) == [start |-> start]
        \\Init ==
        \\    /\ participants = ("r1" :> ("t1" :> <<>>))
        \\    /\ requests = ("s1" :> ("t1" :> <<>>))
        \\    /\ count = ("r1" :> ("t1" :> 0))
        \\Op(r, s, t) ==
        \\    /\ participants' = [participants EXCEPT
        \\         ![r][t] = Append(participants[r][t], <<s, {"read"}>>)]
        \\    /\ LET first == ~\E el \in Range(participants[r][t]) :
        \\                          el[1] = s
        \\       IN requests' = [requests EXCEPT
        \\            ![s][t] = Append(requests[s][t], CreateEntry(first))]
        \\    /\ count' = [count EXCEPT ![r][t] = count[r][t] + 1]
        \\Next == \E r \in {"r1"}, s \in {"s1"}, t \in {"t1"} : Op(r, s, t)
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(16 * 1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    const cfg = config.Config{
        .spec_name = null,
        .init_name = "Init",
        .next_name = "Next",
        .invariants = &.{},
        .properties = &.{},
        .constants = &.{},
        .constraints = &.{},
        .action_constraints = &.{},
        .check_deadlock = false,
    };
    var model_checker = try checker.Checker.init(
        &arena,
        module,
        cfg,
        4,
        16_384,
        4096,
        16_384,
        4096,
        4 * 1024 * 1024,
        overrides.OverrideContext.default(),
        1,
    );
    defer model_checker.deinit();
    _ = model_checker.check() catch |err| {
        if (err != error.StateSpaceExhausted) return err;
    };

    const requests_index =
        model_checker.evaluator.find_variable("requests").?;
    var found = false;
    var state_index: u32 = 0;
    while (state_index < model_checker.state_store.count) : (state_index += 1) {
        const state = model_checker.state_store.get(state_index);
        if (state.level != 1) continue;
        const root = state.values[requests_index].function_v.apply(
            &model_checker.state_store.values_pool,
            .{ .string_v = try model_checker.state_store.values_pool.push_string(
                "s1",
            ) },
        ) orelse return error.UndefinedSymbol;
        const sequence = root.function_v.apply(
            &model_checker.state_store.values_pool,
            .{ .string_v = try model_checker.state_store.values_pool.push_string(
                "t1",
            ) },
        ) orelse return error.UndefinedSymbol;
        const requests = sequence.tuple_v.items(
            &model_checker.state_store.values_pool,
        );
        try std.testing.expectEqual(@as(usize, 1), requests.len);
        const start = requests[0].record_v.lookup(
            &model_checker.state_store.values_pool,
            "start",
        ) orelse return error.UndefinedSymbol;
        try std.testing.expect(start.is_truthy());
        found = true;
        break;
    }
    try std.testing.expect(found);
}

test "local namespace instance is hoisted for module expansion" {
    const source =
        \\---------------------- MODULE TestLocalInstance ----------------------
        \\Tree ==
        \\  LET E == {}
        \\      G == INSTANCE Graphs
        \\  IN G!IsTreeWithRoot([node |-> {}, edge |-> E], 1)
        \\After == TRUE
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqual(@as(usize, 2), module.definitions.len);
    try std.testing.expectEqual(@as(usize, 1), module.namespace_instances.len);
    try std.testing.expectEqualStrings("G", module.namespace_instances[0].alias);
    try std.testing.expectEqualStrings("After", module.definitions[1].name);
}

test "MDBTLA ClientCentric namespace calls remain qualified" {
    var arena = try Arena.init(256 * 1024 * 1024);
    defer arena.deinit();
    const search_paths = [_][]const u8{
        "vendor/MDBTLA/MultiShardTxn",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-community-modules/modules",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load(
        "vendor/MDBTLA/MultiShardTxn/ClientCentricTests.tla",
    );
    try std.testing.expect(find_definition(module, "CC!SnapshotIsolation"));
    try std.testing.expect(!expr_contains_ident(
        module.assumptions[0],
        "SnapshotIsolation",
    ));
    try std.testing.expect(expr_contains_ident(
        module.assumptions[0],
        "CC!SnapshotIsolation",
    ));
}

test "MDBTLA MultiShardTxn resolves Range over an empty sequence" {
    var arena = try Arena.init(256 * 1024 * 1024);
    defer arena.deinit();
    const search_paths = [_][]const u8{
        "vendor/MDBTLA/MultiShardTxn",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-community-modules/modules",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load(
        "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
    );
    const evaluator = try eval.Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    const range = evaluator.find_definition("Range") orelse
        return error.UndefinedSymbol;
    try std.testing.expectEqual(@as(usize, 1), range.params.len);
    const expression = try parser.Parser.parse_expr_string(
        &arena,
        "~\\E el \\in Range(<<>>) : el[1] = \"s1\"",
    );
    var pool = try value.ValuePool.init(&arena, 4096, 4096);
    const result = try evaluator.eval_expr(
        expression,
        eval.Context.empty(),
        null,
        &pool,
        &pool,
    );
    try std.testing.expect(result.is_truthy());
}

test "instance modules retain definitions from extended community modules" {
    var arena = try Arena.init(256 * 1024 * 1024);
    defer arena.deinit();
    const search_paths = [_][]const u8{
        "vendor/tlaplus-examples/specifications/YoYo",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-community-modules/modules",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load(
        "vendor/tlaplus-examples/specifications/YoYo/MCYoYoNoPruning.tla",
    );
    if (!find_definition(module, "IsUndirectedGraph")) {
        return error.MissingIsUndirectedGraph;
    }
    if (!find_definition(module, "IsStronglyConnected")) {
        return error.MissingIsStronglyConnected;
    }
}

test "extended modules retain imported EWD687a properties" {
    var arena = try Arena.init(256 * 1024 * 1024);
    defer arena.deinit();
    const search_paths = [_][]const u8{
        "vendor/tlaplus-examples/specifications/ewd687a",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-community-modules/modules",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load(
        "vendor/tlaplus-examples/specifications/ewd687a/MCEWD687a.tla",
    );
    try std.testing.expect(find_definition(module, "CountersConsistent"));
    try std.testing.expect(find_definition(module, "TreeWithRoot"));
    try std.testing.expect(find_definition(module, "DT2"));
}

fn read_test_file(arena: *Arena, path: []const u8) ![]u8 {
    const path_z = try arena.alloc(u8, path.len + 1);
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const file = std.c.fopen(@ptrCast(path_z.ptr), "rb") orelse return error.IoError;
    defer _ = std.c.fclose(file);

    var temp = std.ArrayList(u8).empty;
    defer temp.deinit(std.heap.page_allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, file);
        if (n == 0) break;
        try temp.appendSlice(std.heap.page_allocator, buf[0..n]);
    }
    const result = try arena.alloc(u8, temp.items.len);
    @memcpy(result, temp.items);
    return result;
}

fn find_definition(module: @import("ast.zig").Module, name: []const u8) bool {
    for (module.definitions) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return true;
    }
    return false;
}

fn expect_definition(
    module: @import("ast.zig").Module,
    name: []const u8,
) !void {
    if (find_definition(module, name)) return;
    std.debug.print("missing parsed definition: {s}\n", .{name});
    std.debug.print("parsed definitions:", .{});
    for (module.definitions) |definition| {
        std.debug.print(" {s}", .{definition.name});
    }
    std.debug.print("\n", .{});
    return error.MissingParsedDefinition;
}

fn expr_contains_ident(expr: *const @import("ast.zig").Expr, name: []const u8) bool {
    return switch (expr.*) {
        .ident => |ident| std.mem.eql(u8, ident, name),
        .primed => |ident| std.mem.eql(u8, ident, name),
        .primed_expr => |operand| expr_contains_ident(operand, name),
        .unchanged => |idents| blk: {
            for (idents) |ident| {
                if (std.mem.eql(u8, ident, name)) break :blk true;
            }
            break :blk false;
        },
        .unchanged_expr => |operand| expr_contains_ident(operand, name),
        .binary => |binary| expr_contains_ident(binary.left, name) or
            expr_contains_ident(binary.right, name),
        .unary => |unary| expr_contains_ident(unary.operand, name),
        .if_then_else => |ite| expr_contains_ident(ite.cond, name) or
            expr_contains_ident(ite.then_branch, name) or
            expr_contains_ident(ite.else_branch, name),
        .apply => |application| blk: {
            if (expr_contains_ident(application.func, name)) break :blk true;
            for (application.args) |argument| {
                if (expr_contains_ident(argument, name)) break :blk true;
            }
            break :blk false;
        },
        .field => |field| expr_contains_ident(field.expr, name),
        .tuple, .set_enum => |items| blk: {
            for (items) |item| {
                if (expr_contains_ident(item, name)) break :blk true;
            }
            break :blk false;
        },
        .record => |fields| blk: {
            for (fields) |field| {
                if (expr_contains_ident(field.value, name)) break :blk true;
            }
            break :blk false;
        },
        .set_filter => |set_filter| expr_contains_bound_vars(
            set_filter.vars,
            set_filter.pred,
            name,
        ),
        .set_map => |set_map| expr_contains_bound_vars(
            set_map.vars,
            set_map.value,
            name,
        ),
        .set_binary => |set_binary| expr_contains_ident(set_binary.left, name) or
            expr_contains_ident(set_binary.right, name),
        .set_of_functions => |set_functions| expr_contains_ident(
            set_functions.domain,
            name,
        ) or expr_contains_ident(set_functions.codomain, name),
        .function_literal => |function| expr_contains_bound_vars(
            function.vars,
            function.body,
            name,
        ),
        .record_set => |record_set| blk: {
            for (record_set.fields) |field| {
                if (expr_contains_ident(field.domain, name)) break :blk true;
            }
            break :blk false;
        },
        .except => |except| blk: {
            if (expr_contains_ident(except.func, name) or
                expr_contains_ident(except.value, name))
            {
                break :blk true;
            }
            for (except.steps) |step| {
                switch (step) {
                    .index => |index| {
                        if (expr_contains_ident(index, name)) break :blk true;
                    },
                    .field => {},
                }
            }
            break :blk false;
        },
        .let_in => |let| blk: {
            for (let.defs) |definition| {
                if (expr_contains_ident(definition.body, name)) break :blk true;
            }
            break :blk expr_contains_ident(let.body, name);
        },
        .case_expr => |case| blk: {
            for (case.arms) |arm| {
                if (expr_contains_ident(arm.cond, name) or
                    expr_contains_ident(arm.value, name))
                {
                    break :blk true;
                }
            }
            break :blk if (case.otherwise) |otherwise|
                expr_contains_ident(otherwise, name)
            else
                false;
        },
        .box_action => |box_action| expr_contains_ident(
            box_action.action,
            name,
        ) or expr_contains_ident(box_action.vars, name),
        .lambda => |lambda| expr_contains_ident(lambda.body, name),
        .quantifier => |quantifier| expr_contains_bound_vars(
            quantifier.vars,
            quantifier.body,
            name,
        ),
        .choose => |choose| (if (choose.domain) |domain|
            expr_contains_ident(domain, name)
        else
            false) or expr_contains_ident(choose.body, name),
        .bool_literal,
        .int_literal,
        .string_literal,
        .at,
        => false,
    };
}

fn expr_contains_bound_vars(
    vars: []const @import("ast.zig").BoundVar,
    body: *const @import("ast.zig").Expr,
    name: []const u8,
) bool {
    for (vars) |variable| {
        if (expr_contains_ident(variable.domain, name)) return true;
    }
    return expr_contains_ident(body, name);
}

fn steps_assign_primed(steps: []const action.ActionStep, name: []const u8) bool {
    for (steps) |step| {
        switch (step) {
            .assign_prime => |assign| {
                if (std.mem.eql(u8, assign.var_name, name)) return true;
            },
            .choose => |choose| {
                if (steps_assign_primed(choose.body_steps, name)) return true;
            },
            .branch => |branch| {
                for (branch.options) |option| {
                    if (steps_assign_primed(option, name)) return true;
                }
            },
            .if_branch => |if_branch| {
                if (steps_assign_primed(if_branch.then_steps, name)) return true;
                if (steps_assign_primed(if_branch.else_steps, name)) return true;
            },
            .case_branch => |case_branch| {
                for (case_branch.arms) |arm| {
                    if (steps_assign_primed(arm.steps, name)) return true;
                }
                if (case_branch.otherwise_steps) |otherwise| {
                    if (steps_assign_primed(otherwise, name)) return true;
                }
            },
            .call => |call| {
                if (steps_assign_primed(call.body_steps, name)) return true;
            },
            else => {},
        }
    }
    return false;
}
