const std = @import("std");
const Arena = @import("arena.zig").Arena;
const parser = @import("parser.zig");

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
    try std.testing.expectEqual(module.definitions.len, 2);
}
