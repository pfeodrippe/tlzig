const std = @import("std");
const Arena = @import("arena.zig").Arena;

pub const ConstantAssignment = struct {
    name: []const u8,
    expr: []const u8,
};

pub const Config = struct {
    spec_name: ?[]const u8,
    init_name: ?[]const u8,
    next_name: ?[]const u8,
    invariants: []const []const u8,
    constants: []const ConstantAssignment,

    pub fn empty() Config {
        return Config{
            .spec_name = null,
            .init_name = null,
            .next_name = null,
            .invariants = &.{},
            .constants = &.{},
        };
    }
};

pub fn parse(arena: *Arena, source: []const u8) !Config {
    var cfg = Config.empty();
    var invariants = std.ArrayList([]const u8).empty;
    defer invariants.deinit(std.heap.page_allocator);
    var constants = std.ArrayList(ConstantAssignment).empty;
    defer constants.deinit(std.heap.page_allocator);

    var it = std.mem.tokenizeAny(u8, source, "\r\n");
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "\\*")) continue;
        if (std.mem.startsWith(u8, trimmed, "(*")) continue;

        const first_word = first_token(trimmed);
        const rest = std.mem.trim(u8, trimmed[first_word.len..], " \t");
        if (std.mem.eql(u8, first_word, "SPECIFICATION")) {
            cfg.spec_name = try arena_dup(arena, rest);
        } else if (std.mem.eql(u8, first_word, "INIT")) {
            cfg.init_name = try arena_dup(arena, rest);
        } else if (std.mem.eql(u8, first_word, "NEXT")) {
            cfg.next_name = try arena_dup(arena, rest);
        } else if (std.mem.eql(u8, first_word, "INVARIANT")) {
            invariants.append(std.heap.page_allocator, try arena_dup(arena, rest)) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, first_word, "INVARIANTS")) {
            while (it.next()) |inv| {
                const t = std.mem.trim(u8, inv, " \t");
                if (t.len == 0) continue;
                invariants.append(std.heap.page_allocator, try arena_dup(arena, t)) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, first_word, "CONSTANT") or std.mem.eql(u8, first_word, "CONSTANTS")) {
            if (rest.len > 0) {
                try parse_constant_assignment(arena, rest, &constants);
            }
            while (it.next()) |cand| {
                const t = std.mem.trim(u8, cand, " \t");
                if (t.len == 0) continue;
                if (is_directive(t)) break;
                try parse_constant_assignment(arena, t, &constants);
            }
        }
    }

    const invariants_copy: []const []const u8 = if (invariants.items.len == 0) &[_][]const u8{} else blk: {
        const result = try arena.alloc([]const u8, invariants.items.len);
        @memcpy(result, invariants.items);
        break :blk result;
    };
    const constants_copy: []const ConstantAssignment = if (constants.items.len == 0) &[_]ConstantAssignment{} else blk: {
        const result = try arena.alloc(ConstantAssignment, constants.items.len);
        @memcpy(result, constants.items);
        break :blk result;
    };
    return Config{
        .spec_name = cfg.spec_name,
        .init_name = cfg.init_name,
        .next_name = cfg.next_name,
        .invariants = invariants_copy,
        .constants = constants_copy,
    };
}

fn parse_constant_assignment(arena: *Arena, line: []const u8, out: *std.ArrayList(ConstantAssignment)) !void {
    const eq_idx = std.mem.indexOf(u8, line, "=") orelse return error.SyntaxError;
    const name = std.mem.trim(u8, line[0..eq_idx], " \t");
    const expr = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
    out.append(std.heap.page_allocator, ConstantAssignment{
        .name = try arena_dup(arena, name),
        .expr = try arena_dup(arena, expr),
    }) catch return error.OutOfMemory;
}

fn is_directive(line: []const u8) bool {
    const first = first_token(line);
    const directives = [_][]const u8{
        "SPECIFICATION", "INIT",       "NEXT",
        "INVARIANT",     "INVARIANTS", "CONSTANT",
        "CONSTANTS",
    };
    for (directives) |d| {
        if (std.mem.eql(u8, first, d)) return true;
    }
    return false;
}

fn first_token(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] != ' ' and s[i] != '\t') i += 1;
    return s[0..i];
}

fn arena_dup(arena: *Arena, s: []const u8) ![]const u8 {
    const copy = try arena.alloc(u8, s.len);
    @memcpy(copy, s);
    return copy;
}
