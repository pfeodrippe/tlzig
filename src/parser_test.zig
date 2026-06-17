const std = @import("std");
const Arena = @import("arena.zig").Arena;
const parser = @import("parser.zig");
const ModuleLoader = @import("module_loader.zig").ModuleLoader;
const eval = @import("eval.zig");
const action = @import("action.zig");
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
        .state_store = &store,
        .eval_pool = &eval_pool,
    };
    var out = std.ArrayList(u32).empty;
    defer out.deinit(std.heap.page_allocator);
    try executor.execute_next(compiled, s0_idx, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    const next = store.get(out.items[0]);
    try std.testing.expectEqual(@as(i64, 5), next.values[0].int_v);
    try std.testing.expectEqual(@as(i64, 4), next.values[1].int_v);
    try std.testing.expectEqual(@as(i64, 0), next.values[2].int_v);
    try std.testing.expectEqualStrings("Done", next.values[3].string_v.slice(&store.values_pool));
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
    const ctx = eval.Context.empty().extend("x", .{ .int_v = 1 });
    const result = try evaluator.eval_expr(expr, ctx, null, &pool, &state_pool);
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
