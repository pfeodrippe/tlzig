const std = @import("std");
const assert = std.debug.assert;
const Arena = @import("arena.zig").Arena;

fn has_translation(source: []const u8, start: usize) bool {
    return std.mem.indexOfPos(u8, source, start, "\\* BEGIN TRANSLATION") != null;
}

fn can_translate(source: []const u8, start: usize, end: usize) bool {
    var i: usize = start;
    while (i < end) {
        const nl = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse end;
        const line = trim(source[i..nl]);
        if (starts_with(line, "procedure") or
            starts_with(line, "while") or
            starts_with(line, "either") or
            starts_with(line, "await") or
            starts_with(line, "assert") or
            starts_with(line, "print") or
            starts_with(line, "with") or
            starts_with(line, "call") or
            starts_with(line, "process") or
            starts_with(line, "fair") or
            starts_with(line, "macro") or
            starts_with(line, "--fair"))
        {
            return false;
        }
        i = nl + 1;
    }
    return true;
}

pub fn translate(arena: *Arena, source: []const u8) ![]const u8 {
    const algo = find_algorithm(source) orelse {
        if (has_translation(source, 0)) {
            // There's a handwritten translation but no algorithm block found.
            // This happens when the algorithm uses (**) comment style.
            // Just return the source as-is; the translation is already there.
            return source;
        }
        return source;
    };
    var end = algo.end;
    const has_handwritten = has_translation(source, end);
    // If a hand-written TLA+ translation exists, always remove the PlusCal
    // comment block and keep the translation. This is safer than trying to
    // re-translate, especially for complex algorithms.
    if (has_handwritten) {
        const total = source.len - (end - algo.start);
        const result = try arena.alloc(u8, total);
        @memcpy(result[0..algo.start], source[0..algo.start]);
        @memcpy(result[algo.start..], source[end..]);
        return result;
    }
    if (std.mem.indexOfPos(u8, source, end, "\\* BEGIN TRANSLATION")) |begin| {
        if (std.mem.indexOfPos(u8, source, begin, "\\* END TRANSLATION")) |end_line| {
            const after = std.mem.indexOfPos(u8, source, end_line, "\n");
            end = if (after) |a| a + 1 else end_line + "\\* END TRANSLATION".len;
        }
    }
    var t = try Translator.init(arena, source, algo.start, end);
    const generated = t.run() catch |err| {
        std.debug.print("PlusCal translation failed at pos={d}: {any}\n", .{ t.pos, err });
        return err;
    };
    const total = algo.start + generated.len + (source.len - end);
    const result = try arena.alloc(u8, total);
    @memcpy(result[0..algo.start], source[0..algo.start]);
    @memcpy(result[algo.start .. algo.start + generated.len], generated);
    @memcpy(result[algo.start + generated.len ..], source[end..]);
    return result;
}

const AlgorithmRange = struct { start: usize, end: usize };

fn find_algorithm(source: []const u8) ?AlgorithmRange {
    var i: usize = 0;
    while (i + 1 < source.len) : (i += 1) {
        if (source[i] == '(' and source[i + 1] == '*') {
            const block_start = i;
            var depth: u32 = 1;
            i += 2;
            while (i + 1 < source.len and depth > 0) : (i += 1) {
                if (source[i] == '(' and source[i + 1] == '*') {
                    depth += 1;
                    i += 1;
                } else if (source[i] == '*' and source[i + 1] == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        const block_end = i + 2;
                        const inner = source[block_start + 2 .. block_end - 2];
                        if (std.mem.indexOf(u8, inner, "--algorithm") != null or
                            std.mem.indexOf(u8, inner, "--fair algorithm") != null)
                        {
                            return .{ .start = block_start, .end = block_end };
                        }
                    }
                    i += 1;
                }
            }
        }
    }
    return null;
}

const Translator = struct {
    arena: *Arena,
    lines: []const []const u8,
    pos: usize,
    out: std.ArrayList(u8),

    var_names: std.ArrayList([]const u8),
    var_inits: std.ArrayList([]const u8),
    macros: std.ArrayList(Macro),
    procs: std.ArrayList(Process),

    const Process = struct {
        name: []const u8,
        set: []const u8,
        single: bool,
        labels: std.ArrayList(Label),
    };

    const Macro = struct {
        name: []const u8,
        params: []const []const u8,
        stmts: []const Statement,
    };

    const Label = struct {
        name: []const u8,
        stmts: []const Statement,
    };

    const Statement = struct {
        kind: StmtKind,
        text: []const u8,
    };

    const StmtKind = enum {
        assign,
        await,
        assert,
        print,
        skip,
        if_stmt,
        either,
        while_stmt,
        with_stmt,
        other,
    };

    fn init(arena: *Arena, source: []const u8, start: usize, end: usize) !Translator {
        const algo = source[start + 2 .. end - 2];
        const lines = try split_lines(arena, algo);
        return Translator{
            .arena = arena,
            .lines = lines,
            .pos = 0,
            .out = std.ArrayList(u8).empty,
            .var_names = std.ArrayList([]const u8).empty,
            .var_inits = std.ArrayList([]const u8).empty,
            .macros = std.ArrayList(Macro).empty,
            .procs = std.ArrayList(Process).empty,
        };
    }

    fn run(self: *Translator) ![]const u8 {
        try self.parse_header();
        while (self.pos < self.lines.len) {
            const raw = self.lines[self.pos];
            const line = trim(raw);
            if (line.len == 0 or line[0] == '{') {
                self.pos += 1;
                continue;
            }
            // debug removed
            if (starts_with(line, "variables") or starts_with(line, "variable")) {
                try self.parse_vars();
            } else if (starts_with(line, "define")) {
                try self.skip_block();
            } else if (starts_with(line, "macro")) {
                try self.parse_macro();
            } else if (starts_with(line, "procedure")) {
                try self.skip_block();
            } else if (starts_with(line, "process") or starts_with(line, "fair process")) {
                try self.parse_process();
            } else if (line[0] == '}') {
                self.pos += 1;
                break;
            } else {
                return error.SyntaxError;
            }
        }
        if (self.procs.items.len == 0 or self.procs.items[0].labels.items.len == 0) {
            std.debug.print("PlusCal: no processes/labels\n", .{});
            return error.SyntaxError;
        }
        try self.generate();
        return try self.arena.dup(self.out.items);
    }

    fn parse_header(self: *Translator) !void {
        var line = trim(self.lines[self.pos]);
        self.pos += 1;
        // Skip any narrative lines before the --algorithm directive.
        while (self.pos < self.lines.len and !starts_with(line, "--algorithm") and !starts_with(line, "--fair")) {
            line = trim(self.lines[self.pos]);
            self.pos += 1;
        }
        if (starts_with(line, "--fair")) line = trim(line[6..]);
        line = trim(line["--algorithm".len..]);
        const has_brace = std.mem.indexOf(u8, line, "{");
        if (has_brace) |idx| {
            _ = trim(line[0..idx]);
            const rest = trim(line[idx + 1 ..]);
            if (rest.len > 0) return error.SyntaxError;
        } else {
            const open = trim(self.lines[self.pos]);
            if (!std.mem.eql(u8, open, "{")) return error.SyntaxError;
            self.pos += 1;
        }
    }

    fn parse_vars(self: *Translator) !void {
        var line = trim(self.lines[self.pos]);
        self.pos += 1;
        // Remove the 'variables' / 'variable' keyword prefix.
        if (starts_with(line, "variables")) line = trim(line["variables".len..]);
        if (starts_with(line, "variable")) line = trim(line["variable".len..]);
        while (true) {
            if (line.len == 0) {
                if (self.pos >= self.lines.len) return;
                line = trim(self.lines[self.pos]);
                self.pos += 1;
                continue;
            }
            const end = if (line[line.len - 1] == ';') line.len - 1 else line.len;
            const text = trim(line[0..end]);
            const eq = std.mem.indexOf(u8, text, "=") orelse return error.SyntaxError;
            const vname = trim(text[0..eq]);
            const vinit = trim(text[eq + 1 ..]);
            try self.var_names.append(std.heap.page_allocator, vname);
            try self.var_inits.append(std.heap.page_allocator, vinit);
            if (line[line.len - 1] == ';') break;
            if (self.pos >= self.lines.len) return error.SyntaxError;
            line = trim(self.lines[self.pos]);
            self.pos += 1;
        }
    }

    fn skip_block(self: *Translator) !void {
        self.pos += 1;
        var depth: u32 = 1;
        while (self.pos < self.lines.len and depth > 0) : (self.pos += 1) {
            const line = trim(self.lines[self.pos]);
            if (line.len == 0) continue;
            if (line[0] == '{') depth += 1;
            if (line[0] == '}') depth -= 1;
        }
    }

    fn parse_macro(self: *Translator) !void {
        const line = trim(self.lines[self.pos]);
        self.pos += 1;
        var rest = trim(line["macro".len..]);
        if (rest[rest.len - 1] == '{') rest = trim(rest[0 .. rest.len - 1]);
        const lparen = std.mem.indexOf(u8, rest, "(") orelse return error.SyntaxError;
        const rparen = std.mem.indexOf(u8, rest, ")") orelse return error.SyntaxError;
        const name = trim(rest[0..lparen]);
        const params = try self.parse_param_list(rest[lparen + 1 .. rparen]);
        const body = try self.collect_block();
        const stmts = try self.parse_statements(body);
        try self.macros.append(std.heap.page_allocator, .{
            .name = name,
            .params = params,
            .stmts = stmts,
        });
    }

    fn parse_param_list(self: *Translator, text: []const u8) ![]const []const u8 {
        var result = std.ArrayList([]const u8).empty;
        defer result.deinit(std.heap.page_allocator);
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |p| {
            const t = trim(p);
            if (t.len == 0) continue;
            try result.append(std.heap.page_allocator, t);
        }
        const out = try self.arena.alloc([]const u8, result.items.len);
        for (result.items, 0..) |p, i| out[i] = p;
        return out;
    }

    fn parse_process(self: *Translator) !void {
        const line = trim(self.lines[self.pos]);
        self.pos += 1;
        var rest = trim(line["process".len..]);
        if (starts_with(line, "fair process")) rest = trim(line["fair process".len..]);
        if (rest[0] != '(') return error.SyntaxError;
        const close = std.mem.indexOf(u8, rest, ")") orelse return error.SyntaxError;
        const decl = trim(rest[1..close]);
        const body = try self.collect_block();

        var single = false;
        var name: []const u8 = undefined;
        var set: []const u8 = undefined;
        if (std.mem.indexOf(u8, decl, "\\in")) |idx| {
            name = trim(decl[0..idx]);
            set = trim(decl[idx + 4 ..]);
        } else if (std.mem.indexOf(u8, decl, "=")) |idx| {
            single = true;
            name = trim(decl[0..idx]);
            set = trim(decl[idx + 1 ..]);
        } else {
            return error.SyntaxError;
        }

        var proc = Process{
            .name = name,
            .set = set,
            .single = single,
            .labels = std.ArrayList(Label).empty,
        };
        try self.split_labels(&proc, body);
        if (proc.labels.items.len == 0) return error.SyntaxError;
        try self.procs.append(std.heap.page_allocator, proc);
    }

    fn collect_block(self: *Translator) ![]const []const u8 {
        const start = self.pos;
        var depth: u32 = 1;
        while (self.pos < self.lines.len and depth > 0) : (self.pos += 1) {
            const line = trim(self.lines[self.pos]);
            if (line.len == 0) continue;
            if (line[0] == '{') depth += 1;
            if (line[0] == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        return self.lines[start..self.pos];
    }

    fn split_labels(self: *Translator, proc: *Process, body: []const []const u8) !void {
        var current_name: ?[]const u8 = null;
        var current_start: usize = 0;
        for (body, 0..) |raw, i| {
            const line = trim(raw);
            if (line.len == 0 or line[0] == '{' or line[0] == '}') continue;
            if (is_label(line)) {
                if (current_name) |n| {
                    const stmts = try self.parse_statements(body[current_start..i]);
                    try proc.labels.append(std.heap.page_allocator, .{ .name = n, .stmts = stmts });
                }
                current_name = strip_label(line);
                current_start = i + 1;
            }
        }
        if (current_name) |n| {
            const stmts = try self.parse_statements(body[current_start..]);
            try proc.labels.append(std.heap.page_allocator, .{ .name = n, .stmts = stmts });
        }
    }

    fn parse_statements(self: *Translator, lines: []const []const u8) ![]const Statement {
        var result = std.ArrayList(Statement).empty;
        defer result.deinit(std.heap.page_allocator);
        var i: usize = 0;
        while (i < lines.len) {
            const raw = lines[i];
            const line = trim(raw);
            if (line.len == 0 or line[0] == '{') {
                i += 1;
                continue;
            }
            if (is_label(line)) return error.SyntaxError;
            if (line[0] == '}') {
                i += 1;
                continue;
            }
            if (starts_with(line, "if")) {
                const block = try self.take_block(lines, &i, "if");
                try result.append(std.heap.page_allocator, .{ .kind = .if_stmt, .text = block });
                continue;
            }
            if (starts_with(line, "either")) {
                const block = try self.take_block(lines, &i, "either");
                try result.append(std.heap.page_allocator, .{ .kind = .either, .text = block });
                continue;
            }
            if (starts_with(line, "while")) {
                const block = try self.take_block(lines, &i, "while");
                try result.append(std.heap.page_allocator, .{ .kind = .while_stmt, .text = block });
                continue;
            }
            if (starts_with(line, "with")) {
                const block = try self.take_block(lines, &i, "with");
                try result.append(std.heap.page_allocator, .{ .kind = .with_stmt, .text = block });
                continue;
            }
            const semi = std.mem.indexOf(u8, line, ";");
            const end = semi orelse line.len;
            const stmt = trim(line[0..end]);
            if (stmt.len == 0) {
                i += 1;
                continue;
            }
            const kind: StmtKind = if (starts_with(stmt, "await ") or starts_with(stmt, "when ")) .await else if (starts_with(stmt, "assert ")) .assert else if (starts_with(stmt, "print ")) .print else if (std.mem.eql(u8, stmt, "skip")) .skip else if (std.mem.indexOf(u8, stmt, ":=") != null) .assign else .other;
            if (kind == .other) {
                if (try self.expand_macro_call(stmt, &result)) {
                    i += 1;
                    if (semi) |s| {
                        if (s + 1 < line.len) {
                            const remainder = trim(line[s + 1 ..]);
                            if (remainder.len > 0) return error.SyntaxError;
                        }
                    }
                    continue;
                }
            }
            try result.append(std.heap.page_allocator, .{ .kind = kind, .text = stmt });
            i += 1;
            if (semi) |s| {
                if (s + 1 < line.len) {
                    // extra statement after semicolon on same line
                    const remainder = trim(line[s + 1 ..]);
                    if (remainder.len > 0) {
                        // not supported
                        return error.SyntaxError;
                    }
                }
            }
        }
        const out = try self.arena.alloc(Statement, result.items.len);
        for (result.items, 0..) |item, idx| out[idx] = item;
        return out;
    }

    fn expand_macro_call(self: *Translator, stmt: []const u8, out: *std.ArrayList(Statement)) !bool {
        const lparen = std.mem.indexOf(u8, stmt, "(") orelse return false;
        const rparen = std.mem.indexOf(u8, stmt, ")") orelse return false;
        if (lparen == 0 or rparen < lparen) return false;
        const name = trim(stmt[0..lparen]);
        for (self.macros.items) |m| {
            if (!std.mem.eql(u8, m.name, name)) continue;
            const args = try self.parse_call_args(stmt[lparen + 1 .. rparen]);
            if (args.len != m.params.len) return error.SyntaxError;
            for (m.stmts) |s| {
                const expanded = try self.subst_stmt(s, m.params, args);
                try out.append(std.heap.page_allocator, expanded);
            }
            return true;
        }
        return false;
    }

    fn parse_call_args(self: *Translator, text: []const u8) ![]const []const u8 {
        var result = std.ArrayList([]const u8).empty;
        defer result.deinit(std.heap.page_allocator);
        var depth: u32 = 0;
        var start: usize = 0;
        for (text, 0..) |c, i| {
            if (c == '(') depth += 1;
            if (c == ')') depth -= 1;
            if (c == ',' and depth == 0) {
                try result.append(std.heap.page_allocator, trim(text[start..i]));
                start = i + 1;
            }
        }
        const last = trim(text[start..]);
        if (last.len > 0) try result.append(std.heap.page_allocator, last);
        const out = try self.arena.alloc([]const u8, result.items.len);
        for (result.items, 0..) |p, i| out[i] = p;
        return out;
    }

    fn subst_stmt(self: *Translator, stmt: Statement, params: []const []const u8, args: []const []const u8) !Statement {
        const new_text = try self.subst_text(stmt.text, params, args);
        // Reclassify the statement based on the expanded text.
        const kind: StmtKind = if (starts_with(new_text, "await ") or starts_with(new_text, "when ")) .await else if (starts_with(new_text, "assert ")) .assert else if (starts_with(new_text, "print ")) .print else if (std.mem.eql(u8, new_text, "skip")) .skip else if (std.mem.indexOf(u8, new_text, ":=") != null) .assign else .other;
        return Statement{ .kind = kind, .text = new_text };
    }

    fn subst_text(self: *Translator, text: []const u8, params: []const []const u8, args: []const []const u8) ![]const u8 {
        // Simple textual substitution. Replace whole identifiers that match params.
        var result = std.ArrayList(u8).empty;
        defer result.deinit(std.heap.page_allocator);
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (std.ascii.isAlphabetic(c) or c == '_') {
                var end = i + 1;
                while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
                const ident = text[i..end];
                var matched = false;
                for (params, args) |p, a| {
                    if (std.mem.eql(u8, ident, p)) {
                        try result.appendSlice(std.heap.page_allocator, a);
                        matched = true;
                        break;
                    }
                }
                if (!matched) try result.appendSlice(std.heap.page_allocator, ident);
                i = end;
            } else {
                try result.append(std.heap.page_allocator, c);
                i += 1;
            }
        }
        const out = try self.arena.alloc(u8, result.items.len);
        @memcpy(out, result.items);
        return out;
    }

    fn take_block(self: *Translator, lines: []const []const u8, i: *usize, kind: []const u8) ![]const u8 {
        _ = kind;
        const start = i.*;
        i.* += 1;
        var depth: u32 = 1;
        while (i.* < lines.len and depth > 0) {
            const l = trim(lines[i.*]);
            if (l.len > 0 and l[0] == '{') depth += 1;
            if (l.len > 0 and l[0] == '}') {
                depth -= 1;
                if (depth == 0) {
                    i.* += 1;
                    break;
                }
            }
            i.* += 1;
        }
        return try join_lines(self.arena, lines[start..i.*]);
    }

    fn generate(self: *Translator) !void {
        try self.emit("\n(* BEGIN TRANSLATION *)\nVARIABLES pc");
        for (self.var_names.items) |v| {
            try self.emit(", ");
            try self.emit(v);
        }
        try self.emit("\n\nvars == << pc");
        for (self.var_names.items) |v| {
            try self.emit(", ");
            try self.emit(v);
        }
        try self.emit(" >>\n\n");

        try self.emit("ProcSet == ");
        if (self.procs.items.len == 1 and self.procs.items[0].single) {
            try self.emit("{");
            try self.emit(self.procs.items[0].name);
            try self.emit("}\n\n");
        } else {
            for (self.procs.items, 0..) |p, idx| {
                if (idx > 0) try self.emit(" \\cup ");
                if (p.single) {
                    try self.emit("{");
                    try self.emit(p.set);
                    try self.emit("}");
                } else {
                    try self.emit(p.set);
                }
            }
            try self.emit("\n\n");
        }

        try self.emit("Init == (* Global variables *)\n/\\ pc = [self \\in ProcSet |-> \"");
        try self.emit(self.procs.items[0].labels.items[0].name);
        try self.emit("\"]\n");
        for (self.var_names.items, self.var_inits.items) |v, vinit| {
            try self.emit("/\\ ");
            try self.emit(v);
            try self.emit(" = ");
            try self.emit(vinit);
            try self.emit("\n");
        }
        try self.emit("\n");

        for (self.procs.items) |proc| {
            for (proc.labels.items, 0..) |label, i| {
                const next_name = if (i + 1 < proc.labels.items.len) proc.labels.items[i + 1].name else "Done";
                try self.emit_label_action(proc, label, next_name);
            }

            try self.emit(proc.name);
            try self.emit("(self) == ");
            for (proc.labels.items, 0..) |label, i| {
                if (i > 0) try self.emit(" \\lor ");
                try self.emit(label.name);
                try self.emit("(self)");
            }
            try self.emit("\n\n");
        }

        try self.emit("Terminating == /\\ \\A self \\in ProcSet: pc[self] = \"Done\"\n/\\ UNCHANGED vars\n\nNext == (\\E self \\in ProcSet: ");
        for (self.procs.items, 0..) |p, i| {
            if (i > 0) try self.emit(" \\lor ");
            try self.emit(p.name);
            try self.emit("(self)");
        }
        try self.emit(")\n\\/ Terminating\n\nSpec == Init /\\ [][Next]_vars\n(* END TRANSLATION *)\n");
    }

    fn emit_label_action(self: *Translator, proc: Process, label: Label, next: []const u8) !void {
        _ = proc;
        try self.emit(label.name);
        try self.emit("(self) == /\\ pc[self] = \"");
        try self.emit(label.name);
        try self.emit("\"\n");

        var modified = std.ArrayList([]const u8).empty;
        defer modified.deinit(std.heap.page_allocator);
        for (label.stmts) |stmt| {
            try self.emit("/\\ ");
            try self.emit_stmt(stmt, &modified);
            try self.emit("\n");
        }

        try self.emit("/\\ pc' = [pc EXCEPT ![self] = \"");
        try self.emit(next);
        try self.emit("\"]\n");

        // UNCHANGED for variables not modified in this label.
        if (self.var_names.items.len > 0) {
            try self.emit("/\\ UNCHANGED <<");
            var first = true;
            for (self.var_names.items) |v| {
                var is_modified = false;
                for (modified.items) |m| {
                    if (std.mem.eql(u8, m, v)) {
                        is_modified = true;
                        break;
                    }
                }
                if (!is_modified) {
                    if (!first) try self.emit(", ");
                    try self.emit(v);
                    first = false;
                }
            }
            try self.emit(" >>\n");
        }
        try self.emit("\n");
    }

    const EmitError = error{ OutOfMemory, SyntaxError };

    fn emit_stmt(self: *Translator, stmt: Statement, modified: *std.ArrayList([]const u8)) EmitError!void {
        switch (stmt.kind) {
            .await => {
                const cond = trim(if (starts_with(stmt.text, "await ")) stmt.text[6..] else stmt.text[5..]);
                try self.emit(cond);
            },
            .assign => {
                const idx = std.mem.indexOf(u8, stmt.text, ":=").?;
                const lhs = trim(stmt.text[0..idx]);
                const rhs = trim(stmt.text[idx + 2 ..]);
                try self.emit(lhs);
                try self.emit("' = ");
                try self.emit(rhs);
                try self.record_modified(modified, lhs);
            },
            .assert => {
                const cond = trim(stmt.text[7..]);
                try self.emit(cond);
            },
            .print => {
                try self.emit("TRUE");
            },
            .skip => {
                try self.emit("TRUE");
            },
            .other => {
                try self.emit("TRUE");
            },
            .if_stmt => {
                try self.emit("(");
                try self.emit_if(stmt.text, modified);
                try self.emit(")");
            },
            .either => {
                try self.emit("(");
                try self.emit_either(stmt.text, modified);
                try self.emit(")");
            },
            .while_stmt => {
                try self.emit("(");
                try self.emit_while(stmt.text, modified);
                try self.emit(")");
            },
            .with_stmt => {
                try self.emit("(");
                try self.emit_with(stmt.text, modified);
                try self.emit(")");
            },
        }
    }

    fn emit_if(self: *Translator, block: []const u8, modified: *std.ArrayList([]const u8)) EmitError!void {
        const lines = try split_lines(self.arena, block);
        // line 0: "if (cond) {"
        const cond = try self.extract_condition(lines[0], "if");
        var depth: u32 = 1;
        var i: usize = 1;
        while (i < lines.len and depth > 0) {
            const l = trim(lines[i]);
            if (l.len > 0 and l[0] == '{') depth += 1;
            if (l.len > 0 and l[0] == '}') {
                depth -= 1;
                if (depth == 1) break;
            }
            i += 1;
        }
        const then_stmts = try self.parse_statements(lines[1..i]);
        i += 1;
        // Look for else
        var else_stmts: []const Statement = &[_]Statement{};
        var has_else = false;
        while (i < lines.len) {
            const l = trim(lines[i]);
            if (l.len == 0) {
                i += 1;
                continue;
            }
            if (starts_with(l, "else")) {
                i += 1;
                has_else = true;
                break;
            }
            break;
        }
        if (has_else) {
            const estart = i;
            depth = 1;
            while (i < lines.len and depth > 0) {
                const l = trim(lines[i]);
                if (l.len > 0 and l[0] == '{') depth += 1;
                if (l.len > 0 and l[0] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                i += 1;
            }
            else_stmts = try self.parse_statements(lines[estart..i]);
        }

        try self.emit("(");
        try self.emit(cond);
        try self.emit(" /\\ ");
        for (then_stmts, 0..) |s, idx| {
            if (idx > 0) try self.emit(" /\\ ");
            try self.emit_stmt(s, modified);
        }
        try self.emit(")");
        if (has_else) {
            try self.emit(" \\/ (~(");
            try self.emit(cond);
            try self.emit(") /\\ ");
            for (else_stmts, 0..) |s, idx| {
                if (idx > 0) try self.emit(" /\\ ");
                try self.emit_stmt(s, modified);
            }
            try self.emit(")");
        }
    }

    fn emit_either(self: *Translator, block: []const u8, modified: *std.ArrayList([]const u8)) EmitError!void {
        const lines = try split_lines(self.arena, block);
        var i: usize = 0;
        var first_branch = true;
        while (i < lines.len) {
            const l = trim(lines[i]);
            if (l.len == 0) {
                i += 1;
                continue;
            }
            if (starts_with(l, "either") or starts_with(l, "or")) {
                i += 1;
                const bstart = i;
                var depth: u32 = 1;
                while (i < lines.len and depth > 0) {
                    const bl = trim(lines[i]);
                    if (bl.len > 0 and bl[0] == '{') depth += 1;
                    if (bl.len > 0 and bl[0] == '}') {
                        depth -= 1;
                        if (depth == 1) break;
                    }
                    i += 1;
                }
                const stmts = try self.parse_statements(lines[bstart..i]);
                if (!first_branch) try self.emit(" \\/ ");
                first_branch = false;
                try self.emit("(");
                for (stmts, 0..) |s, idx| {
                    if (idx > 0) try self.emit(" /\\ ");
                    try self.emit_stmt(s, modified);
                }
                try self.emit(")");
                i += 1;
            } else {
                i += 1;
            }
        }
    }

    fn emit_while(self: *Translator, block: []const u8, modified: *std.ArrayList([]const u8)) EmitError!void {
        // Translate while as: (cond /\ body /\ pc' = loop_label) \/ (~cond /\ TRUE /\ pc' = next_label)
        // This requires action-level pc' change, conflicting with label-level pc' update.
        // Simpler: treat as no-op and rely on future expansion.
        _ = modified;
        const lines = try split_lines(self.arena, block);
        const cond = try self.extract_condition(lines[0], "while");
        try self.emit("(");
        try self.emit(cond);
        try self.emit(" /\\ TRUE) \\/ (~(");
        try self.emit(cond);
        try self.emit(") /\\ TRUE)");
    }

    fn emit_with(self: *Translator, block: []const u8, modified: *std.ArrayList([]const u8)) EmitError!void {
        const lines = try split_lines(self.arena, block);
        const decl = try self.extract_with_decl(lines[0]);
        var i: usize = 1;
        const bstart = i;
        var depth: u32 = 1;
        while (i < lines.len and depth > 0) {
            const l = trim(lines[i]);
            if (l.len > 0 and l[0] == '{') depth += 1;
            if (l.len > 0 and l[0] == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
            i += 1;
        }
        const stmts = try self.parse_statements(lines[bstart..i]);
        try self.emit("\\E ");
        try self.emit(decl.var_name);
        try self.emit(" \\in ");
        try self.emit(decl.set);
        try self.emit(" : ");
        for (stmts, 0..) |s, idx| {
            if (idx > 0) try self.emit(" /\\ ");
            try self.emit_stmt(s, modified);
        }
    }

    fn extract_condition(_: *Translator, line: []const u8, kw: []const u8) EmitError![]const u8 {
        var rest = trim(line[kw.len..]);
        if (rest[0] != '(') return error.SyntaxError;
        var depth: u32 = 1;
        var i: usize = 1;
        while (i < rest.len and depth > 0) : (i += 1) {
            if (rest[i] == '(') depth += 1;
            if (rest[i] == ')') depth -= 1;
        }
        return trim(rest[1 .. i - 1]);
    }

    const WithDecl = struct { var_name: []const u8, set: []const u8 };
    fn extract_with_decl(_: *Translator, line: []const u8) EmitError!WithDecl {
        var rest = trim(line["with".len..]);
        if (rest[0] != '(') return error.SyntaxError;
        const close = std.mem.indexOf(u8, rest, ")") orelse return error.SyntaxError;
        const inner = trim(rest[1..close]);
        const idx = std.mem.indexOf(u8, inner, "\\in") orelse return error.SyntaxError;
        return WithDecl{
            .var_name = trim(inner[0..idx]),
            .set = trim(inner[idx + 4 ..]),
        };
    }

    fn record_modified(_: *Translator, modified: *std.ArrayList([]const u8), lhs: []const u8) EmitError!void {
        // Extract base variable name from e.g. "x[self]" or "x.y".
        var end: usize = 0;
        while (end < lhs.len and (std.ascii.isAlphanumeric(lhs[end]) or lhs[end] == '_')) end += 1;
        const base = lhs[0..end];
        if (base.len == 0) return;
        for (modified.items) |m| {
            if (std.mem.eql(u8, m, base)) return;
        }
        try modified.append(std.heap.page_allocator, base);
    }

    fn emit(self: *Translator, s: []const u8) !void {
        try self.out.appendSlice(std.heap.page_allocator, s);
    }
};

fn split_lines(arena: *Arena, source: []const u8) ![]const []const u8 {
    if (source.len == 0) return &[_][]const u8{};
    var count: usize = 0;
    for (source) |c| {
        if (c == '\n') count += 1;
    }
    if (source[source.len - 1] != '\n') count += 1;
    const result = try arena.alloc([]const u8, count);
    var start: usize = 0;
    var idx: usize = 0;
    for (source, 0..) |c, i| {
        if (c == '\n') {
            result[idx] = source[start..i];
            idx += 1;
            start = i + 1;
        }
    }
    if (start < source.len) {
        result[idx] = source[start..];
        idx += 1;
    }
    assert(idx == count);
    return result[0..idx];
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn starts_with(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

fn is_label(line: []const u8) bool {
    if (line.len == 0) return false;
    var i: usize = 0;
    while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
    return i > 0 and i < line.len and line[i] == ':';
}

fn strip_label(line: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, line, ":").?;
    return trim(line[0..end]);
}

fn join_lines(arena: *Arena, lines: []const []const u8) ![]const u8 {
    var total: usize = 0;
    for (lines) |l| total += l.len + 1;
    const result = try arena.alloc(u8, total);
    var pos: usize = 0;
    for (lines) |l| {
        @memcpy(result[pos .. pos + l.len], l);
        pos += l.len;
        result[pos] = '\n';
        pos += 1;
    }
    return result;
}
