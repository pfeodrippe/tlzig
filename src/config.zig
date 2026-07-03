const std = @import("std");
const Arena = @import("arena.zig").Arena;
const ast = @import("ast.zig");

pub const ConstantAssignment = struct {
    name: []const u8,
    expr: []const u8,
    is_substitution: bool,
};

pub fn is_operator_alias(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "TRUE") or
        std.mem.eql(u8, trimmed, "FALSE"))
    {
        return false;
    }
    if (!std.ascii.isAlphabetic(trimmed[0])) return false;
    for (trimmed[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

pub const Config = struct {
    spec_name: ?[]const u8,
    init_name: ?[]const u8,
    next_name: ?[]const u8,
    invariants: []const []const u8,
    properties: []const []const u8,
    constants: []const ConstantAssignment,
    constraints: []const []const u8,
    action_constraints: []const []const u8,
    symmetry_name: ?[]const u8 = null,
    check_deadlock: bool,
    strict_constants: bool = false,

    pub fn empty() Config {
        return Config{
            .spec_name = null,
            .init_name = null,
            .next_name = null,
            .invariants = &[_][]const u8{},
            .properties = &[_][]const u8{},
            .constants = &[_]ConstantAssignment{},
            .constraints = &[_][]const u8{},
            .action_constraints = &[_][]const u8{},
            .symmetry_name = null,
            .check_deadlock = true,
            .strict_constants = false,
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
            .action_constraints = &[_][]const u8{},
            .symmetry_name = null,
            .check_deadlock = true,
            .strict_constants = false,
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
            .action_constraints = &[_][]const u8{},
            .symmetry_name = null,
            .check_deadlock = true,
            .strict_constants = false,
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
    var action_constraints = std.ArrayList([]const u8).empty;
    defer action_constraints.deinit(std.heap.page_allocator);

    // Pre-process: strip all (* ... *) block comments from the config source.
    const cleaned = strip_block_comments(arena, source) catch return error.OutOfMemory;
    const lines = try split_lines(arena, cleaned);
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const trimmed = trim(lines[i]);
        if (trimmed.len == 0) continue;
        if (is_comment(trimmed)) continue;

        const first_word = first_token(trimmed);
        const rest_raw = trim(trimmed[first_word.len..]);
        // Strip block comments (* ... *) from the rest of the line.
        const rest = blk: {
            if (std.mem.indexOf(u8, rest_raw, "(*")) |start| {
                if (std.mem.indexOf(u8, rest_raw[start..], "*)")) |end_rel| {
                    var combined = std.ArrayList(u8).empty;
                    defer combined.deinit(std.heap.page_allocator);
                    combined.appendSlice(std.heap.page_allocator, rest_raw[0..start]) catch return error.OutOfMemory;
                    const after = start + end_rel + 2;
                    if (after < rest_raw.len) {
                        combined.appendSlice(std.heap.page_allocator, rest_raw[after..]) catch return error.OutOfMemory;
                    }
                    break :blk try arena_dup(arena, trim(combined.items));
                }
            }
            break :blk rest_raw;
        };
        if (eql(first_word, "SPECIFICATION")) {
            if (rest.len > 0) {
                cfg.spec_name = try arena_dup(arena, rest);
            } else {
                i += 1;
                while (i < lines.len) : (i += 1) {
                    const t = trim(lines[i]);
                    if (t.len == 0) continue;
                    if (is_comment(t)) continue;
                    if (is_directive(t)) {
                        i -= 1;
                        break;
                    }
                    cfg.spec_name = try arena_dup(arena, t);
                    break;
                }
            }
        } else if (eql(first_word, "INIT")) {
            if (rest.len > 0) {
                cfg.init_name = try arena_dup(arena, rest);
            } else {
                i += 1;
                while (i < lines.len) : (i += 1) {
                    const t = trim(lines[i]);
                    if (t.len == 0) continue;
                    if (is_comment(t)) continue;
                    if (is_directive(t)) {
                        i -= 1;
                        break;
                    }
                    cfg.init_name = try arena_dup(arena, t);
                    break;
                }
            }
        } else if (eql(first_word, "NEXT")) {
            if (rest.len > 0) {
                cfg.next_name = try arena_dup(arena, rest);
            } else {
                i += 1;
                while (i < lines.len) : (i += 1) {
                    const t = trim(lines[i]);
                    if (t.len == 0) continue;
                    if (is_comment(t)) continue;
                    if (is_directive(t)) {
                        i -= 1;
                        break;
                    }
                    cfg.next_name = try arena_dup(arena, t);
                    break;
                }
            }
        } else if (eql(first_word, "INVARIANT")) {
            if (rest.len > 0) {
                try parse_name_list(arena, rest, &invariants);
            } else {
                i += 1;
                while (i < lines.len) : (i += 1) {
                    const t = trim(lines[i]);
                    if (t.len == 0) continue;
                    if (is_comment(t)) continue;
                    if (is_directive(t)) {
                        i -= 1;
                        break;
                    }
                    try invariants.append(std.heap.page_allocator, try arena_dup(arena, t));
                }
            }
        } else if (eql(first_word, "INVARIANTS")) {
            if (rest.len > 0) {
                try parse_name_list(arena, rest, &invariants);
            } else {
                i += 1;
                while (i < lines.len) : (i += 1) {
                    const t = trim(lines[i]);
                    if (t.len == 0) continue;
                    if (is_comment(t)) continue;
                    if (is_directive(t)) {
                        i -= 1; // let outer loop process the directive
                        break;
                    }
                    try parse_name_list(arena, t, &invariants);
                }
            }
        } else if (eql(first_word, "CONSTANT") or eql(first_word, "CONSTANTS")) {
            if (rest.len > 0) {
                parse_constant_assignments_line(arena, rest, &constants) catch {};
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
                parse_constant_assignments_line(arena, t, &constants) catch continue;
            }
        } else if (eql(first_word, "PROPERTY")) {
            if (rest.len > 0) {
                try parse_name_list(arena, rest, &properties);
            } else {
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
            }
        } else if (eql(first_word, "PROPERTIES")) {
            if (rest.len > 0) {
                try parse_name_list(arena, rest, &properties);
            } else {
                i += 1;
                while (i < lines.len) : (i += 1) {
                    const t = trim(lines[i]);
                    if (t.len == 0) continue;
                    if (is_comment(t)) continue;
                    if (is_directive(t)) {
                        i -= 1;
                        break;
                    }
                    try parse_name_list(arena, t, &properties);
                }
            }
        } else if (eql(first_word, "CONSTRAINT") or eql(first_word, "ACTION_CONSTRAINT")) {
            const destination = if (eql(first_word, "ACTION_CONSTRAINT"))
                &action_constraints
            else
                &constraints;
            if (rest.len > 0) {
                try parse_name_list(arena, rest, destination);
            } else {
                i += 1;
                while (i < lines.len) : (i += 1) {
                    const t = trim(lines[i]);
                    if (t.len == 0) continue;
                    if (is_comment(t)) continue;
                    if (is_directive(t)) {
                        i -= 1;
                        break;
                    }
                    try destination.append(std.heap.page_allocator, try arena_dup(arena, t));
                }
            }
        } else if (eql(first_word, "CONSTRAINTS") or eql(first_word, "ACTION_CONSTRAINTS")) {
            const destination = if (eql(first_word, "ACTION_CONSTRAINTS"))
                &action_constraints
            else
                &constraints;
            if (rest.len > 0) {
                try parse_name_list(arena, rest, destination);
            } else {
                i += 1;
                while (i < lines.len) : (i += 1) {
                    const t = trim(lines[i]);
                    if (t.len == 0) continue;
                    if (is_comment(t)) continue;
                    if (is_directive(t)) {
                        i -= 1;
                        break;
                    }
                    try parse_name_list(arena, t, destination);
                }
            }
        } else if (eql(first_word, "CHECK_DEADLOCK")) {
            if (rest.len > 0) {
                cfg.check_deadlock = !eql(first_token(rest), "FALSE");
            }
        } else if (eql(first_word, "SYMMETRY")) {
            if (rest.len > 0) {
                cfg.symmetry_name = try arena_dup(arena, first_token(rest));
            } else {
                i += 1;
                while (i < lines.len) : (i += 1) {
                    const t = trim(lines[i]);
                    if (t.len == 0) continue;
                    if (is_comment(t)) continue;
                    if (is_directive(t)) {
                        i -= 1;
                        break;
                    }
                    cfg.symmetry_name = try arena_dup(arena, first_token(t));
                    break;
                }
            }
        } else if (eql(first_word, "ALIAS") or
            eql(first_word, "VIEW") or
            eql(first_word, "POSTCONDITION"))
        {
            // Not implemented yet; parse and ignore for now.
            if (eql(first_word, "ALIAS") or eql(first_word, "VIEW") or
                eql(first_word, "POSTCONDITION"))
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
        .action_constraints = try dup_slice(
            arena,
            []const u8,
            action_constraints.items,
        ),
        .symmetry_name = cfg.symmetry_name,
        .check_deadlock = cfg.check_deadlock,
        .strict_constants = true,
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

fn parse_name_list(arena: *Arena, line: []const u8, out: *std.ArrayList([]const u8)) !void {
    // Strip trailing line comments (\* ...).
    const commentless = blk: {
        if (std.mem.indexOf(u8, line, "\\*")) |idx| break :blk line[0..idx];
        break :blk line;
    };
    var it = std.mem.splitScalar(u8, commentless, ' ');
    while (it.next()) |part| {
        const t = trim(part);
        if (t.len == 0) continue;
        try out.append(std.heap.page_allocator, try arena_dup(arena, t));
    }
}

fn parse_constant_assignment(arena: *Arena, line: []const u8, out: *std.ArrayList(ConstantAssignment)) !void {
    const is_substitution = std.mem.indexOf(u8, line, "<-") != null;
    const sep_idx = if (is_substitution)
        std.mem.indexOf(u8, line, "<-").?
    else
        std.mem.indexOf(u8, line, "=") orelse return error.SyntaxError;
    const name = trim(line[0..sep_idx]);
    const expr_start = sep_idx + (if (is_substitution) @as(usize, 2) else @as(usize, 1));
    var expr = trim(line[expr_start..]);
    // Handle parameterized substitutions like Ballot <-[Voting] MCBallot
    if (is_substitution and std.mem.startsWith(u8, expr, "[")) {
        const bracket_end = std.mem.indexOf(u8, expr, "]") orelse return error.SyntaxError;
        expr = trim(expr[bracket_end + 1 ..]);
    }
    if (name.len == 0 or expr.len == 0) return error.SyntaxError;
    std.debug.assert(name.len > 0);
    std.debug.assert(expr.len > 0);
    try out.append(std.heap.page_allocator, ConstantAssignment{
        .name = try arena_dup(arena, name),
        .expr = try arena_dup(arena, expr),
        .is_substitution = is_substitution,
    });
}

fn parse_constant_assignments_line(
    arena: *Arena,
    line_raw: []const u8,
    out: *std.ArrayList(ConstantAssignment),
) !void {
    const line = trim(line_raw);
    if (line.len == 0) return;

    var assignment_start: usize = 0;
    while (assignment_start < line.len) {
        const assignment_end = find_next_assignment_start(line, assignment_start) orelse line.len;
        const assignment = trim(line[assignment_start..assignment_end]);
        if (assignment.len == 0) return error.SyntaxError;
        try parse_constant_assignment(arena, assignment, out);
        assignment_start = assignment_end;
        while (assignment_start < line.len and is_space(line[assignment_start])) {
            assignment_start += 1;
        }
    }
}

fn find_next_assignment_start(line: []const u8, assignment_start: usize) ?usize {
    std.debug.assert(assignment_start < line.len);

    var paren_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var brace_depth: u32 = 0;
    var tuple_depth: u32 = 0;
    var in_string = false;
    var escaped = false;
    var i = assignment_start;

    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }

        if (c == '"') {
            in_string = true;
        } else if (c == '(') {
            paren_depth += 1;
        } else if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
        } else if (c == '[') {
            bracket_depth += 1;
        } else if (c == ']') {
            if (bracket_depth > 0) bracket_depth -= 1;
        } else if (c == '{') {
            brace_depth += 1;
        } else if (c == '}') {
            if (brace_depth > 0) brace_depth -= 1;
        } else if (c == '<' and i + 1 < line.len and line[i + 1] == '<') {
            tuple_depth += 1;
            i += 1;
        } else if (c == '>' and i + 1 < line.len and line[i + 1] == '>') {
            if (tuple_depth > 0) tuple_depth -= 1;
            i += 1;
        } else if (is_space(c) and
            paren_depth == 0 and
            bracket_depth == 0 and
            brace_depth == 0 and
            tuple_depth == 0)
        {
            var candidate = i;
            while (candidate < line.len and is_space(line[candidate])) {
                candidate += 1;
            }
            if (candidate > assignment_start and is_assignment_start(line, candidate)) {
                return candidate;
            }
        }
    }
    return null;
}

fn is_assignment_start(line: []const u8, start: usize) bool {
    if (start >= line.len or !is_identifier_start(line[start])) return false;

    var i = start + 1;
    while (i < line.len and is_identifier_continue(line[i])) : (i += 1) {}
    while (i < line.len and is_space(line[i])) : (i += 1) {}

    return (i < line.len and line[i] == '=') or
        (i + 1 < line.len and line[i] == '<' and line[i + 1] == '-');
}

fn is_identifier_start(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn is_identifier_continue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '!';
}

fn is_space(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn is_directive(line: []const u8) bool {
    const first = first_token(line);
    const directives = [_][]const u8{
        "SPECIFICATION", "INIT",              "NEXT",
        "INVARIANT",     "INVARIANTS",        "CONSTANT",
        "CONSTANTS",     "PROPERTY",          "PROPERTIES",
        "ALIAS",         "VIEW",              "SYMMETRY",
        "POSTCONDITION", "CHECK_DEADLOCK",    "CONSTRAINT",
        "CONSTRAINTS",   "ACTION_CONSTRAINT", "ACTION_CONSTRAINTS",
    };
    for (directives) |d| {
        if (eql(first, d)) return true;
    }
    return false;
}

fn strip_block_comments(arena: *Arena, source: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(std.heap.page_allocator);
    var i: usize = 0;
    while (i < source.len) {
        if (i + 1 < source.len and source[i] == '(' and source[i + 1] == '*') {
            i += 2;
            var depth: u32 = 1;
            while (i + 1 < source.len and depth > 0) : (i += 1) {
                if (source[i] == '(' and source[i + 1] == '*') {
                    depth += 1;
                    i += 1;
                } else if (source[i] == '*' and source[i + 1] == ')') {
                    depth -= 1;
                    i += 1;
                    if (depth == 0) break;
                }
            }
            try result.append(std.heap.page_allocator, ' ');
            i += 1;
        } else if (source[i] == '\\' and i + 1 < source.len and source[i + 1] == '*') {
            while (i < source.len and source[i] != '\n') i += 1;
        } else {
            try result.append(std.heap.page_allocator, source[i]);
            i += 1;
        }
    }
    return try arena.dup(result.items);
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

test "parse multiple constant assignments on one line" {
    const source =
        \\CONSTANTS
        \\  a1=a1  a2=a2  Values = {1, 2, {3, 4}} Message = "x = y"
        \\  Ballot <-[Voting] MCBallot
        \\SPECIFICATION Spec
        \\INVARIANT Inv
    ;
    var arena = try Arena.init(4096);
    defer arena.deinit();

    const cfg = try parse(&arena, source);
    try std.testing.expectEqual(@as(usize, 5), cfg.constants.len);
    try std.testing.expectEqualStrings("a1", cfg.constants[0].name);
    try std.testing.expectEqualStrings("a1", cfg.constants[0].expr);
    try std.testing.expectEqualStrings("a2", cfg.constants[1].name);
    try std.testing.expectEqualStrings("{1, 2, {3, 4}}", cfg.constants[2].expr);
    try std.testing.expectEqualStrings("\"x = y\"", cfg.constants[3].expr);
    try std.testing.expectEqualStrings("Ballot", cfg.constants[4].name);
    try std.testing.expectEqualStrings("MCBallot", cfg.constants[4].expr);
    try std.testing.expect(cfg.constants[4].is_substitution);
    try std.testing.expectEqualStrings("Spec", cfg.spec_name.?);
    try std.testing.expectEqualStrings("Inv", cfg.invariants[0]);
}

test "parse boolean operator substitutions" {
    const source =
        \\CONSTANT
        \\  Enabled <- TRUE
        \\  Disabled <- FALSE
        \\INIT Init
        \\NEXT Next
    ;
    var arena = try Arena.init(4096);
    defer arena.deinit();

    const cfg = try parse(&arena, source);
    try std.testing.expectEqual(@as(usize, 2), cfg.constants.len);
    try std.testing.expectEqualStrings("Enabled", cfg.constants[0].name);
    try std.testing.expectEqualStrings("TRUE", cfg.constants[0].expr);
    try std.testing.expect(cfg.constants[0].is_substitution);
    try std.testing.expectEqualStrings("Disabled", cfg.constants[1].name);
    try std.testing.expectEqualStrings("FALSE", cfg.constants[1].expr);
    try std.testing.expect(cfg.constants[1].is_substitution);
}

test "state and action constraints remain distinct" {
    const source =
        \\CONSTRAINT StateLimit
        \\ACTION_CONSTRAINT NoStutter
        \\ACTION_CONSTRAINTS
        \\  Monotonic
    ;
    var arena = try Arena.init(4096);
    defer arena.deinit();

    const cfg = try parse(&arena, source);
    try std.testing.expectEqual(@as(usize, 1), cfg.constraints.len);
    try std.testing.expectEqualStrings("StateLimit", cfg.constraints[0]);
    try std.testing.expectEqual(@as(usize, 2), cfg.action_constraints.len);
    try std.testing.expectEqualStrings(
        "NoStutter",
        cfg.action_constraints[0],
    );
    try std.testing.expectEqualStrings(
        "Monotonic",
        cfg.action_constraints[1],
    );
}

test "parse symmetry operator" {
    const source =
        \\INIT Init
        \\NEXT Next
        \\SYMMETRY ModelSymmetry
    ;
    var arena = try Arena.init(4096);
    defer arena.deinit();

    const cfg = try parse(&arena, source);
    try std.testing.expectEqualStrings(
        "ModelSymmetry",
        cfg.symmetry_name.?,
    );
}

test "parse block symmetry operator" {
    const source =
        \\INIT Init
        \\NEXT Next
        \\SYMMETRY
        \\    ModelSymmetry
    ;
    var arena = try Arena.init(4096);
    defer arena.deinit();

    const cfg = try parse(&arena, source);
    try std.testing.expectEqualStrings(
        "ModelSymmetry",
        cfg.symmetry_name.?,
    );
}
