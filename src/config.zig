const std = @import("std");
const Arena = @import("arena.zig").Arena;
const ast = @import("ast.zig");

pub const ConstantAssignment = struct {
    name: []const u8,
    expr: []const u8,
    is_substitution: bool,
};

pub const Config = struct {
    spec_name: ?[]const u8,
    init_name: ?[]const u8,
    next_name: ?[]const u8,
    invariants: []const []const u8,
    properties: []const []const u8,
    constants: []const ConstantAssignment,
    constraints: []const []const u8,

    pub fn empty() Config {
        return Config{
            .spec_name = null,
            .init_name = null,
            .next_name = null,
            .invariants = &[_][]const u8{},
            .properties = &[_][]const u8{},
            .constants = &[_]ConstantAssignment{},
            .constraints = &[_][]const u8{},
        };
    }

    pub fn default(arena: *Arena) Config {
        const invariants = arena.alloc([]const u8, 2) catch unreachable;
        invariants[0] = arena.dup("TypeOK") catch unreachable;
        invariants[1] = arena.dup("Inv") catch unreachable;
        return Config{
            .spec_name = null,
            .init_name = arena.dup("Init") catch unreachable,
            .next_name = arena.dup("Next") catch unreachable,
            .invariants = invariants,
            .properties = &[_][]const u8{},
            .constants = &[_]ConstantAssignment{},
            .constraints = &[_][]const u8{},
        };
    }

    pub fn from_module(arena: *Arena, module: ast.Module) Config {
        const init_name = find_def(module, "Init") orelse find_def(module, "Spec") orelse "Init";
        const next_name = find_def(module, "Next") orelse init_name;
        var invs = std.ArrayList([]const u8).empty;
        defer invs.deinit(std.heap.page_allocator);
        for (&[_][]const u8{ "TypeOK", "Inv", "Invariant", "Safety", "TypeInvariant" }) |cand| {
            if (find_def(module, cand) != null) {
                invs.append(std.heap.page_allocator, arena.dup(cand) catch unreachable) catch {};
            }
        }
        return Config{
            .spec_name = null,
            .init_name = arena.dup(init_name) catch unreachable,
            .next_name = arena.dup(next_name) catch unreachable,
            .invariants = blk: {
                const result = arena.alloc([]const u8, invs.items.len) catch unreachable;
                @memcpy(result, invs.items);
                break :blk result;
            },
            .properties = &[_][]const u8{},
            .constants = &[_]ConstantAssignment{},
            .constraints = &[_][]const u8{},
        };
    }
};

fn find_def(module: ast.Module, name: []const u8) ?[]const u8 {
    for (module.definitions) |d| {
        if (std.mem.eql(u8, d.name, name)) return d.name;
    }
    return null;
}

pub fn parse(arena: *Arena, source: []const u8) !Config {
    var cfg = Config.empty();
    var invariants = std.ArrayList([]const u8).empty;
    defer invariants.deinit(std.heap.page_allocator);
    var properties = std.ArrayList([]const u8).empty;
    defer properties.deinit(std.heap.page_allocator);
    var constants = std.ArrayList(ConstantAssignment).empty;
    defer constants.deinit(std.heap.page_allocator);
    var constraints = std.ArrayList([]const u8).empty;
    defer constraints.deinit(std.heap.page_allocator);

    const lines = try split_lines(arena, source);
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const trimmed = trim(lines[i]);
        if (trimmed.len == 0) continue;
        if (is_comment(trimmed)) continue;

        const first_word = first_token(trimmed);
        var rest = trim(trimmed[first_word.len..]);
        if (rest.len == 0 and i + 1 < lines.len) {
            i += 1;
            rest = trim(lines[i]);
        }
        if (eql(first_word, "SPECIFICATION")) {
            cfg.spec_name = try arena_dup(arena, rest);
        } else if (eql(first_word, "INIT")) {
            cfg.init_name = try arena_dup(arena, rest);
        } else if (eql(first_word, "NEXT")) {
            cfg.next_name = try arena_dup(arena, rest);
        } else if (eql(first_word, "INVARIANT")) {
            try invariants.append(std.heap.page_allocator, try arena_dup(arena, rest));
        } else if (eql(first_word, "INVARIANTS")) {
            i += 1;
            while (i < lines.len) : (i += 1) {
                const t = trim(lines[i]);
                if (t.len == 0) continue;
                if (is_comment(t)) continue;
                if (is_directive(t)) {
                    i -= 1; // let outer loop process the directive
                    break;
                }
                try invariants.append(std.heap.page_allocator, try arena_dup(arena, t));
            }
        } else if (eql(first_word, "CONSTANT") or eql(first_word, "CONSTANTS")) {
            if (rest.len > 0) {
                try parse_constant_assignment(arena, rest, &constants);
            }
            i += 1;
            while (i < lines.len) : (i += 1) {
                const t = trim(lines[i]);
                if (t.len == 0) continue;
                if (is_comment(t)) continue;
                if (is_directive(t)) {
                    i -= 1; // let outer loop process the directive
                    break;
                }
                try parse_constant_assignment(arena, t, &constants);
            }
        } else if (eql(first_word, "PROPERTY")) {
            try properties.append(std.heap.page_allocator, try arena_dup(arena, rest));
        } else if (eql(first_word, "PROPERTIES")) {
            i += 1;
            while (i < lines.len) : (i += 1) {
                const t = trim(lines[i]);
                if (t.len == 0) continue;
                if (is_comment(t)) continue;
                if (is_directive(t)) {
                    i -= 1;
                    break;
                }
                try properties.append(std.heap.page_allocator, try arena_dup(arena, t));
            }
        } else if (eql(first_word, "CONSTRAINT")) {
            try constraints.append(std.heap.page_allocator, try arena_dup(arena, rest));
        } else if (eql(first_word, "CONSTRAINTS")) {
            i += 1;
            while (i < lines.len) : (i += 1) {
                const t = trim(lines[i]);
                if (t.len == 0) continue;
                if (is_comment(t)) continue;
                if (is_directive(t)) {
                    i -= 1;
                    break;
                }
                try constraints.append(std.heap.page_allocator, try arena_dup(arena, t));
            }
        } else if (eql(first_word, "ALIAS") or
            eql(first_word, "VIEW") or
            eql(first_word, "SYMMETRY") or
            eql(first_word, "POSTCONDITION") or
            eql(first_word, "CHECK_DEADLOCK"))
        {
            // Not implemented yet; parse and ignore for now.
            if (eql(first_word, "ALIAS") or eql(first_word, "VIEW") or
                eql(first_word, "SYMMETRY") or eql(first_word, "POSTCONDITION") or
                eql(first_word, "CHECK_DEADLOCK"))
            {
                // Single-line or block values are ignored.
                if (rest.len == 0) {
                    i += 1;
                    while (i < lines.len) : (i += 1) {
                        const t = trim(lines[i]);
                        if (t.len == 0) continue;
                        if (is_comment(t)) continue;
                        if (is_directive(t)) {
                            i -= 1;
                            break;
                        }
                    }
                }
            }
        }
    }

    return Config{
        .spec_name = cfg.spec_name,
        .init_name = cfg.init_name,
        .next_name = cfg.next_name,
        .invariants = try dup_slice(arena, []const u8, invariants.items),
        .properties = try dup_slice(arena, []const u8, properties.items),
        .constants = try dup_slice(arena, ConstantAssignment, constants.items),
        .constraints = try dup_slice(arena, []const u8, constraints.items),
    };
}

fn split_lines(arena: *Arena, source: []const u8) ![]const []const u8 {
    var result = std.ArrayList([]const u8).empty;
    defer result.deinit(std.heap.page_allocator);
    var start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n' or source[i] == '\r') {
            if (i > start) try result.append(std.heap.page_allocator, source[start..i]);
            start = i + 1;
        }
    }
    if (i > start) try result.append(std.heap.page_allocator, source[start..i]);
    return try dup_slice(arena, []const u8, result.items);
}

fn parse_constant_assignment(arena: *Arena, line: []const u8, out: *std.ArrayList(ConstantAssignment)) !void {
    const is_substitution = std.mem.indexOf(u8, line, "<-") != null;
    const sep_idx = if (is_substitution)
        std.mem.indexOf(u8, line, "<-").?
    else
        std.mem.indexOf(u8, line, "=") orelse return error.SyntaxError;
    const name = trim(line[0..sep_idx]);
    const expr = trim(line[sep_idx + (if (is_substitution) @as(usize, 2) else @as(usize, 1)) ..]);
    try out.append(std.heap.page_allocator, ConstantAssignment{
        .name = try arena_dup(arena, name),
        .expr = try arena_dup(arena, expr),
        .is_substitution = is_substitution,
    });
}

fn is_directive(line: []const u8) bool {
    const first = first_token(line);
    const directives = [_][]const u8{
        "SPECIFICATION", "INIT",           "NEXT",
        "INVARIANT",     "INVARIANTS",     "CONSTANT",
        "CONSTANTS",     "PROPERTY",       "PROPERTIES",
        "ALIAS",         "VIEW",           "SYMMETRY",
        "POSTCONDITION", "CHECK_DEADLOCK", "CONSTRAINT",
        "CONSTRAINTS",
    };
    for (directives) |d| {
        if (eql(first, d)) return true;
    }
    return false;
}

fn is_comment(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "\\*") or std.mem.startsWith(u8, line, "(*");
}

fn first_token(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] != ' ' and s[i] != '\t') i += 1;
    return s[0..i];
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn arena_dup(arena: *Arena, s: []const u8) ![]const u8 {
    const copy = try arena.alloc(u8, s.len);
    @memcpy(copy, s);
    return copy;
}

fn dup_slice(arena: *Arena, comptime T: type, items: []const T) ![]const T {
    if (items.len == 0) return &[_]T{};
    const result = try arena.alloc(T, items.len);
    @memcpy(result, items);
    return result;
}
