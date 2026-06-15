const std = @import("std");
const Arena = @import("arena.zig").Arena;
const parser = @import("parser.zig");

test "parse DieHard" {
    const source =
        \\------------------------------ MODULE DieHard -------------------------------
        \\EXTENDS Naturals
        \\VARIABLES big, small
        \\TypeOK == /\ small \in 0..3
        \\          /\ big   \in 0..5
        \\Init == /\ big = 0
        \\       /\ small = 0
        \\FillSmallJug  == /\ small' = 3
        \\                 /\ big' = big
        \\Next ==  \/ FillSmallJug
        \\       \/ FillBigJug
        \\=============================================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var p = parser.Parser.init(&arena, source);
    // Print tokens around TypeOK.
    var lp = parser.Lexer.init(source);
    var tok = lp.next();
    var ti: u32 = 0;
    while (tok.kind != .eof and ti < 120) : (ti += 1) {
        std.debug.print("tok {d}: {s} '{s}' line={d} col={d} len={d}\n", .{ ti, @tagName(tok.kind), tok.text, tok.line, tok.col, tok.text.len });
        tok = lp.next();
    }
    const module = try p.parse_module();
    try std.testing.expectEqualStrings("DieHard", module.name);
    std.debug.print("definitions: {d}\n", .{module.definitions.len});
    for (module.definitions) |d| {
        std.debug.print("  {s}\n", .{d.name});
    }
    try std.testing.expect(module.definitions.len >= 3);
    var found_init = false;
    for (module.definitions) |d| {
        if (std.mem.eql(u8, d.name, "Init")) found_init = true;
    }
    try std.testing.expect(found_init);
}
