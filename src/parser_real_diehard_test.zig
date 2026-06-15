const std = @import("std");
const Arena = @import("arena.zig").Arena;
const parser = @import("parser.zig");

test "parse real DieHard" {
    var arena = try Arena.init(4 * 1024 * 1024);
    defer arena.deinit();
    const source = @embedFile("../vendor/tlaplus-examples/specifications/DieHard/DieHard.tla");
    var p = parser.Parser.init(&arena, source);
    const module = try p.parse_module();
    try std.testing.expectEqualStrings("DieHard", module.name);
    try std.testing.expect(module.definitions.len >= 3);
    var found_init = false;
    for (module.definitions) |d| {
        if (std.mem.eql(u8, d.name, "Init")) found_init = true;
    }
    try std.testing.expect(found_init);
}
