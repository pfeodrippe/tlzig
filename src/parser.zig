const std = @import("std");
const Arena = @import("arena.zig").Arena;
const ast = @import("ast.zig");

pub const Token = struct {
    kind: Kind,
    text: []const u8,
    line: u32,
    col: u32,

    pub const Kind = enum(u8) {
        eof,
        ident,
        number,
        string,
        keyword_module,
        keyword_extends,
        keyword_variables,
        keyword_constant,
        keyword_constants,
        keyword_theorem,
        keyword_assume,
        keyword_init,
        keyword_next,
        keyword_spec,
        keyword_invariant,
        keyword_invariants,
        keyword_choose,
        keyword_if,
        keyword_then,
        keyword_else,
        keyword_true,
        keyword_false,
        keyword_un,
        keyword_unchanged,
        keyword_subset,
        keyword_union,
        keyword_domain,
        keyword_forall,
        keyword_exists,
        keyword_let,
        keyword_in,
        keyword_case,
        keyword_other,
        keyword_lambda,
        keyword_instance,
        keyword_with,
        cartesian,
        concat,
        subst,
        lparen,
        rparen,
        lbrace,
        rbrace,
        lbracket,
        rbracket,
        langle,
        rangle,
        diamond,
        comma,
        colon,
        semi,
        dot,
        arrow,
        mapsto,
        recordto,
        eq,
        defeq,
        neq,
        lt,
        le,
        gt,
        ge,
        and_op,
        or_op,
        implies,
        equiv,
        not,
        leads_to,
        plus,
        minus,
        star,
        power,
        slash,
        percent,
        range,
        cup,
        cap,
        setminus,
        in,
        notin,
        subseteq,
        except,
        at,
        ooverride,
        underscore,
        bang,
        prime,
    };
};

pub const Lexer = struct {
    source: []const u8,
    pos: u32,
    line: u32,
    col: u32,

    pub fn init(source: []const u8) Lexer {
        return Lexer{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }

    pub fn next(self: *Lexer) Token {
        self.skip_whitespace();
        if (self.pos >= self.source.len) {
            return self.token(.eof, "");
        }
        const start_line = self.line;
        const start_col = self.col;
        const c = self.source[self.pos];
        switch (c) {
            '(' => {
                self.advance();
                return self.mk(.lparen, "(", start_line, start_col);
            },
            ')' => {
                self.advance();
                return self.mk(.rparen, ")", start_line, start_col);
            },
            '{' => {
                self.advance();
                return self.mk(.lbrace, "{", start_line, start_col);
            },
            '}' => {
                self.advance();
                return self.mk(.rbrace, "}", start_line, start_col);
            },
            '[' => {
                self.advance();
                return self.mk(.lbracket, "[", start_line, start_col);
            },
            ']' => {
                self.advance();
                return self.mk(.rbracket, "]", start_line, start_col);
            },
            ',' => {
                self.advance();
                return self.mk(.comma, ",", start_line, start_col);
            },
            ':' => {
                if (self.peek(1) == '>') {
                    self.advance2();
                    return self.mk(.recordto, ":>", start_line, start_col);
                }
                self.advance();
                return self.mk(.colon, ":", start_line, start_col);
            },
            ';' => {
                self.advance();
                return self.mk(.semi, ";", start_line, start_col);
            },
            '.' => {
                if (self.peek(1) == '.') {
                    self.advance2();
                    return self.mk(.range, "..", start_line, start_col);
                }
                self.advance();
                return self.mk(.dot, ".", start_line, start_col);
            },
            '@' => {
                if (self.peek(1) == '@') {
                    self.advance2();
                    return self.mk(.ooverride, "@@", start_line, start_col);
                }
                self.advance();
                return self.mk(.at, "@", start_line, start_col);
            },
            '!' => {
                self.advance();
                return self.mk(.bang, "!", start_line, start_col);
            },
            '\'' => {
                self.advance();
                return self.mk(.prime, "'", start_line, start_col);
            },
            '+' => {
                self.advance();
                return self.mk(.plus, "+", start_line, start_col);
            },
            '*' => {
                self.advance();
                return self.mk(.star, "*", start_line, start_col);
            },
            '^' => {
                self.advance();
                return self.mk(.power, "^", start_line, start_col);
            },
            '/' => {
                if (self.peek(1) == '\\') {
                    self.advance2();
                    return self.mk(.and_op, "/\\", start_line, start_col);
                }
                if (self.peek(1) == '=') {
                    self.advance2();
                    return self.mk(.neq, "/=", start_line, start_col);
                }
                self.advance();
                return self.mk(.slash, "/", start_line, start_col);
            },
            '\\' => {
                const d = self.peek(1);
                if (d == '/') {
                    self.advance2();
                    return self.mk(.or_op, "\\/", start_line, start_col);
                }
                if (d == '*') {
                    self.skip_line_comment();
                    return self.next();
                }
                if (d == 'X' or d == 'x') {
                    self.advance2();
                    return self.mk(.cartesian, "\\X", start_line, start_col);
                }
                if (d == 'o' or d == 'O') {
                    self.advance2();
                    return self.mk(.concat, "\\o", start_line, start_col);
                }
                if (d == '\\' or !self.is_ident_char(d)) {
                    self.advance();
                    return self.mk(.setminus, "\\", start_line, start_col);
                }
                return self.read_backslash_keyword(start_line, start_col);
            },
            '-' => {
                if (self.peek(1) == '>') {
                    self.advance2();
                    return self.mk(.arrow, "->", start_line, start_col);
                }
                self.advance();
                return self.mk(.minus, "-", start_line, start_col);
            },
            '|' => {
                if (self.peek(1) == '-') {
                    self.advance();
                    self.advance();
                    self.advance();
                    return self.mk(.mapsto, "|->", start_line, start_col);
                }
                self.advance();
                return self.mk(.or_op, "|", start_line, start_col);
            },
            '=' => {
                if (self.peek(1) == '=') {
                    self.advance2();
                    return self.mk(.defeq, "==", start_line, start_col);
                }
                if (self.peek(1) == '>') {
                    self.advance2();
                    return self.mk(.implies, "=>", start_line, start_col);
                }
                if (self.peek(1) == '<') {
                    self.advance2();
                    return self.mk(.le, "=<", start_line, start_col);
                }
                self.advance();
                return self.mk(.eq, "=", start_line, start_col);
            },
            '#' => {
                self.advance();
                return self.mk(.neq, "#", start_line, start_col);
            },
            '<' => {
                if (self.peek(1) == '=' and self.peek(2) == '>') {
                    self.advance();
                    self.advance();
                    self.advance();
                    return self.mk(.equiv, "<=>", start_line, start_col);
                }
                if (self.peek(1) == '=') {
                    self.advance2();
                    return self.mk(.le, "<=", start_line, start_col);
                }
                if (self.peek(1) == '-') {
                    self.advance2();
                    return self.mk(.subst, "<-", start_line, start_col);
                }
                if (self.peek(1) == '<') {
                    self.advance2();
                    return self.mk(.langle, "<<", start_line, start_col);
                }
                if (self.peek(1) == '>') {
                    self.advance2();
                    return self.mk(.diamond, "<>", start_line, start_col);
                }
                self.advance();
                return self.mk(.lt, "<", start_line, start_col);
            },
            '>' => {
                if (self.peek(1) == '=') {
                    self.advance2();
                    return self.mk(.ge, ">=", start_line, start_col);
                }
                if (self.peek(1) == '>') {
                    self.advance2();
                    return self.mk(.rangle, ">>", start_line, start_col);
                }
                self.advance();
                return self.mk(.gt, ">", start_line, start_col);
            },
            '~' => {
                self.advance();
                if (self.peek(0) == '>') {
                    self.advance();
                    return self.mk(.leads_to, "~>", start_line, start_col);
                }
                return self.mk(.not, "~", start_line, start_col);
            },
            '%' => {
                self.advance();
                return self.mk(.percent, "%", start_line, start_col);
            },
            '"' => return self.read_string(start_line, start_col),
            '0'...'9' => return self.read_number(start_line, start_col),
            '_' => {
                // If _ is followed by an ident char AND the preceding character
                // is not a closing bracket (like ] or >), it's part of an
                // identifier (e.g. _msgs).  But [A]_v subscripts need _ to be
                // a standalone underscore after ].
                if (self.pos + 1 < self.source.len and self.is_ident_char(self.source[self.pos + 1]) and self.pos > 0) {
                    const prev = self.source[self.pos - 1];
                    if (prev != ']' and prev != '>' and prev != ')' and !self.is_ident_char(prev)) {
                        return self.read_ident_or_keyword(start_line, start_col);
                    }
                }
                self.advance();
                return self.mk(.underscore, "_", start_line, start_col);
            },
            'A'...'Z', 'a'...'z' => return self.read_ident_or_keyword(start_line, start_col),
            else => {
                self.advance();
                return self.mk(.ident, self.source[self.pos - 1 .. self.pos], start_line, start_col);
            },
        }
    }

    fn skip_whitespace(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t') {
                self.advance();
            } else if (c == '\n') {
                self.advance();
                self.line += 1;
                self.col = 1;
            } else if (c == '\r') {
                self.advance();
            } else if (c == '(' and self.peek(1) == '*') {
                self.skip_comment();
            } else if (c == '\\' and self.peek(1) == '*') {
                self.skip_line_comment();
            } else if (c == '-' and self.is_dash_line()) {
                self.skip_dash_line();
            } else {
                break;
            }
        }
    }

    fn is_dash_line(self: Lexer) bool {
        var p = self.pos;
        while (p < self.source.len and self.source[p] != '\n') {
            if (self.source[p] != '-') return false;
            p += 1;
        }
        return p - self.pos >= 4;
    }

    fn skip_dash_line(self: *Lexer) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.advance();
        }
    }

    fn skip_comment(self: *Lexer) void {
        self.advance2();
        while (self.pos + 1 < self.source.len) {
            if (self.source[self.pos] == '*' and self.source[self.pos + 1] == ')') {
                self.advance2();
                return;
            }
            if (self.source[self.pos] == '\n') {
                self.advance();
                self.line += 1;
                self.col = 1;
            } else {
                self.advance();
            }
        }
    }

    fn skip_line_comment(self: *Lexer) void {
        self.advance2(); // skip \*
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.advance();
        }
    }

    fn read_backslash_keyword(self: *Lexer, start_line: u32, start_col: u32) Token {
        self.advance();
        const after = self.pos;
        while (self.pos < self.source.len and self.is_ident_char(self.source[self.pos])) {
            self.advance();
        }
        const word = self.source[after..self.pos];
        const text = self.source[after - 1 .. self.pos];
        var kind = switch_word(word);
        if (std.mem.eql(u8, word, "times") or std.mem.eql(u8, word, "Times")) kind = .cartesian;
        return .{ .kind = kind, .text = text, .line = start_line, .col = start_col };
    }

    fn read_ident_or_keyword(self: *Lexer, start_line: u32, start_col: u32) Token {
        const start = self.pos;
        while (self.pos < self.source.len and self.is_ident_char(self.source[self.pos])) {
            self.advance();
        }
        const word = self.source[start..self.pos];
        var kind = switch_word(word);
        // Bare A/E are identifiers; \A/\E are quantifier keywords via read_backslash_keyword.
        if (kind == .keyword_forall or kind == .keyword_exists) kind = .ident;
        // The operator word "in" (\in) is also a legal identifier in some specs.
        if (kind == .in) kind = .ident;
        return .{ .kind = kind, .text = word, .line = start_line, .col = start_col };
    }

    fn read_number(self: *Lexer, start_line: u32, start_col: u32) Token {
        const start = self.pos;
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            self.advance();
        }
        return .{ .kind = .number, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
    }

    fn read_string(self: *Lexer, start_line: u32, start_col: u32) Token {
        const start = self.pos;
        self.advance();
        while (self.pos < self.source.len and self.source[self.pos] != '"') {
            if (self.source[self.pos] == '\n') {
                self.line += 1;
                self.col = 1;
            }
            self.advance();
        }
        if (self.pos < self.source.len) self.advance();
        return .{ .kind = .string, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
    }

    fn is_ident_char(self: Lexer, c: u8) bool {
        _ = self;
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn advance(self: *Lexer) void {
        if (self.pos >= self.source.len) return;
        self.pos += 1;
        self.col += 1;
    }

    fn advance2(self: *Lexer) void {
        self.advance();
        self.advance();
    }

    fn peek(self: Lexer, offset: u32) u8 {
        const p = self.pos + offset;
        if (p >= self.source.len) return 0;
        return self.source[p];
    }

    fn token(self: Lexer, kind: Token.Kind, text: []const u8) Token {
        return .{ .kind = kind, .text = text, .line = self.line, .col = self.col };
    }

    fn mk(_: Lexer, kind: Token.Kind, text: []const u8, line: u32, col: u32) Token {
        return .{ .kind = kind, .text = text, .line = line, .col = col };
    }
};

fn switch_word(word: []const u8) Token.Kind {
    const map = std.static_string_map.StaticStringMap(Token.Kind).initComptime(.{
        .{ "MODULE", .keyword_module },
        .{ "EXTENDS", .keyword_extends },
        .{ "VARIABLE", .keyword_variables },
        .{ "VARIABLES", .keyword_variables },
        .{ "CONSTANT", .keyword_constants },
        .{ "CONSTANTS", .keyword_constants },
        .{ "THEOREM", .keyword_theorem },
        .{ "ASSUME", .keyword_assume },
        .{ "INVARIANT", .keyword_invariant },
        .{ "INVARIANTS", .keyword_invariants },
        .{ "CHOOSE", .keyword_choose },
        .{ "IF", .keyword_if },
        .{ "THEN", .keyword_then },
        .{ "ELSE", .keyword_else },
        .{ "TRUE", .keyword_true },
        .{ "FALSE", .keyword_false },
        .{ "UN", .keyword_un },
        .{ "UNCHANGED", .keyword_unchanged },
        .{ "SUBSET", .keyword_subset },
        .{ "UNION", .keyword_union },
        .{ "DOMAIN", .keyword_domain },
        .{ "FORALL", .keyword_forall },
        .{ "EXISTS", .keyword_exists },
        .{ "A", .keyword_forall },
        .{ "E", .keyword_exists },
        .{ "LET", .keyword_let },
        .{ "IN", .keyword_in },
        .{ "CASE", .keyword_case },
        .{ "OTHER", .keyword_other },
        .{ "LAMBDA", .keyword_lambda },
        .{ "INSTANCE", .keyword_instance },
        .{ "WITH", .keyword_with },
        .{ "EXCEPT", .except },
        .{ "in", .in },
        .{ "notin", .notin },
        .{ "subseteq", .subseteq },
        .{ "cup", .cup },
        .{ "union", .cup },
        .{ "cap", .cap },
        .{ "intersect", .cap },
        .{ "leq", .le },
        .{ "geq", .ge },
        .{ "div", .slash },
        .{ "circ", .concat },
    });
    return map.get(word) orelse .ident;
}

pub const Parser = struct {
    arena: *Arena,
    lexer: Lexer,
    current: Token,
    next: Token,
    list_cols: [8]u32,
    list_cols_len: u32,
    def_col: u32,
    let_definition_depth: u16,
    hoisted_namespace_instances: [32]ast.NamespaceInstance,
    hoisted_namespace_count: u8,
    suppress_errors: bool = false,
    group_depth: u32,

    pub fn init(arena: *Arena, source: []const u8) Parser {
        var lexer = Lexer.init(source);
        const first = lexer.next();
        const second = lexer.next();
        return Parser{
            .arena = arena,
            .lexer = lexer,
            .current = first,
            .next = second,
            .list_cols = undefined,
            .list_cols_len = 0,
            .def_col = 0,
            .let_definition_depth = 0,
            .hoisted_namespace_instances = undefined,
            .hoisted_namespace_count = 0,
            .group_depth = 0,
        };
    }

    pub fn parse_expr_string(arena: *Arena, source: []const u8) !*ast.Expr {
        var p = Parser.init(arena, source);
        const expr = try p.parse_expr();
        if (p.current.kind != .eof) {
            std.debug.print("SyntaxError: unexpected trailing token {s} ({s}) at line {d} col {d}\n", .{ @tagName(p.current.kind), p.current.text, p.current.line, p.current.col });
            return error.SyntaxError;
        }
        return expr;
    }

    fn parse_module_name(self: *Parser) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(std.heap.page_allocator);
        const start_line = self.current.line;
        while (self.current.line == start_line and
            (self.current.kind == .ident or self.current.kind == .number or self.current.kind == .underscore))
        {
            try buf.appendSlice(std.heap.page_allocator, self.current.text);
            self.advance();
        }
        if (buf.items.len == 0) return error.SyntaxError;
        return try self.dup(buf.items);
    }

    pub fn parse_module(self: *Parser) !ast.Module {
        // Skip any preamble (narrative text, comments) before the MODULE header.
        while (self.current.kind != .eof and self.current.kind != .keyword_module) {
            self.advance();
        }
        try self.expect(.keyword_module);
        const name = try self.parse_module_name();
        self.skip_dashes();

        var extends = std.ArrayList([]const u8).empty;
        defer extends.deinit(std.heap.page_allocator);
        if (self.match(.keyword_extends)) {
            while (true) {
                const ext = try self.expect_ident_text();
                try extends.append(std.heap.page_allocator, try self.dup(ext));
                if (!self.match(.comma)) break;
            }
        }

        var variables = std.ArrayList([]const u8).empty;
        defer variables.deinit(std.heap.page_allocator);
        var constants = std.ArrayList([]const u8).empty;
        defer constants.deinit(std.heap.page_allocator);

        var definitions = std.ArrayList(ast.Definition).empty;
        defer definitions.deinit(std.heap.page_allocator);
        var assumptions = std.ArrayList(*ast.Expr).empty;
        defer assumptions.deinit(std.heap.page_allocator);
        var instances = std.ArrayList(ast.Instance).empty;
        defer instances.deinit(std.heap.page_allocator);
        var namespace_instances = std.ArrayList(ast.NamespaceInstance).empty;
        defer namespace_instances.deinit(std.heap.page_allocator);
        while (true) {
            self.skip_dashes();

            // At module scope, a definition must start with an identifier.
            // Thus any remaining `==` token belongs to the equals-line
            // terminator, even if expression lookahead consumed its first pair.
            if (self.current.kind == .defeq) {
                break;
            }

            if (self.current.kind == .setminus) {
                const start_line = self.current.line;
                self.advance();
                while (self.current.kind != .eof and self.current.line == start_line) {
                    self.advance();
                }
                continue;
            }
            if (self.current.kind == .keyword_variables) {
                self.advance();
                while (true) {
                    if (self.current.kind != .ident) break;
                    try variables.append(std.heap.page_allocator, try self.dup(try self.expect_ident_text()));
                    if (!self.match(.comma)) break;
                }
                continue;
            }
            if (self.current.kind == .keyword_constants) {
                self.advance();
                while (true) {
                    if (self.current.kind != .ident) break;
                    try constants.append(std.heap.page_allocator, try self.dup(try self.expect_ident_text()));
                    // Operator constants may be declared with parameters: Op(_,_).
                    if (self.current.kind == .lparen) {
                        var depth: u32 = 0;
                        while (self.current.kind != .eof) {
                            if (self.current.kind == .lparen) {
                                depth += 1;
                            } else if (self.current.kind == .rparen) {
                                depth -|= 1;
                                if (depth == 0) {
                                    self.advance();
                                    break;
                                }
                            }
                            self.advance();
                        }
                    }
                    if (!self.match(.comma)) break;
                    while (self.current.kind == .setminus) {
                        const start_line = self.current.line;
                        self.advance();
                        while (self.current.kind != .eof and self.current.line == start_line) {
                            self.advance();
                        }
                    }
                }
                continue;
            }
            if (self.current.kind == .keyword_assume) {
                self.advance();
                if (self.current.kind == .ident and
                    self.next.kind == .defeq and
                    self.current.line == self.next.line)
                {
                    const assumption = try self.parse_definition();
                    try assumptions.append(std.heap.page_allocator, assumption.body);
                } else {
                    // ASSUME can have labels (e.g. ASSUME Theorem!: body).
                    // Skip label if present.
                    if (self.current.kind == .ident and self.next.kind == .bang) {
                        self.advance(); // ident
                        self.advance(); // !
                        if (self.current.kind == .colon) self.advance(); // :
                    }
                    const assumption = self.parse_expr() catch {
                        self.skip_to_next_definition();
                        continue;
                    };
                    try assumptions.append(std.heap.page_allocator, assumption);
                }
                if (self.current.kind == .semi) self.advance();
                continue;
            }
            if (self.current.kind == .keyword_theorem or
                self.current.kind == .lbracket or
                self.current.kind == .langle)
            {
                self.skip_to_next_definition();
                continue;
            }
            // Skip TLA+ keyword-like identifiers that aren't definitions.
            if (self.current.kind == .ident) {
                const txt = self.current.text;
                if (std.mem.eql(u8, txt, "RECURSIVE") or
                    std.mem.eql(u8, txt, "LEMMA") or
                    std.mem.eql(u8, txt, "PROOF") or
                    std.mem.eql(u8, txt, "DEFINE") or
                    std.mem.eql(u8, txt, "QED") or
                    std.mem.eql(u8, txt, "SUFFICES") or
                    std.mem.eql(u8, txt, "PICK") or
                    std.mem.eql(u8, txt, "HAVE") or
                    std.mem.eql(u8, txt, "WITNESS") or
                    std.mem.eql(u8, txt, "HIDE") or
                    std.mem.eql(u8, txt, "USE") or
                    std.mem.eql(u8, txt, "BY"))
                {
                    self.skip_to_next_definition();
                    continue;
                }
            }
            if (self.current.kind == .keyword_instance or
                (self.current.kind == .ident and std.mem.eql(u8, self.current.text, "LOCAL") and self.next.kind == .keyword_instance))
            {
                if (self.current.kind == .ident) self.advance(); // skip LOCAL
                const inst = try self.parse_instance();
                try instances.append(std.heap.page_allocator, inst);
                continue;
            }
            if (self.current.kind != .ident) break;
            const saved = self.*;
            if (self.current.kind == .ident and std.mem.eql(u8, self.current.text, "LOCAL") and self.next.kind == .ident) {
                self.advance(); // skip LOCAL
                const def = self.parse_definition() catch {
                    self.* = saved;
                    self.skip_to_next_definition();
                    continue;
                };
                try definitions.append(std.heap.page_allocator, def);
                continue;
            }
            if (self.current.kind == .ident and self.next.kind == .defeq) {
                const alias = self.current.text;
                self.advance(); // alias
                self.advance(); // ==
                if (self.current.kind == .keyword_instance) {
                    const inst = try self.parse_instance();
                    try namespace_instances.append(std.heap.page_allocator, ast.NamespaceInstance{
                        .alias = try self.dup(alias),
                        .module_name = inst.module_name,
                        .substitutions = inst.substitutions,
                    });
                    continue;
                }
                // Not an instance alias; rewind and parse as normal definition.
                self.* = saved;
            }
            const def = self.parse_definition() catch {
                self.* = saved;
                self.skip_to_next_definition();
                continue;
            };
            try definitions.append(std.heap.page_allocator, def);
        }

        const init_name = try self.dup("Init");
        const next_name = try self.dup("Next");
        var invariants = std.ArrayList([]const u8).empty;
        defer invariants.deinit(std.heap.page_allocator);

        const namespace_count = namespace_instances.items.len + self.hoisted_namespace_count;
        const all_namespace_instances = try self.arena.alloc(ast.NamespaceInstance, namespace_count);
        @memcpy(
            all_namespace_instances[0..namespace_instances.items.len],
            namespace_instances.items,
        );
        for (self.hoisted_namespace_instances[0..self.hoisted_namespace_count], namespace_instances.items.len..) |instance, i| {
            all_namespace_instances[i] = instance;
        }

        return ast.Module{
            .name = try self.dup(name),
            .extends = try self.dup_slice([]const u8, extends.items),
            .variables = try self.dup_slice([]const u8, variables.items),
            .constants = try self.dup_slice([]const u8, constants.items),
            .definitions = try self.dup_slice(ast.Definition, definitions.items),
            .assumptions = try self.dup_slice(*ast.Expr, assumptions.items),
            .instances = try self.dup_slice(ast.Instance, instances.items),
            .namespace_instances = all_namespace_instances,
            .init_name = init_name,
            .next_name = next_name,
            .invariants = try self.dup_slice([]const u8, invariants.items),
        };
    }

    fn parse_instance(self: *Parser) !ast.Instance {
        try self.expect(.keyword_instance);
        const module_name = try self.expect_ident_text();
        var subs = std.ArrayList(ast.Substitution).empty;
        defer subs.deinit(std.heap.page_allocator);
        if (self.match(.keyword_with)) {
            while (true) {
                const local_name = try self.expect_ident_text();
                try self.expect(.subst);
                const expr = try self.parse_expr();
                try subs.append(std.heap.page_allocator, .{
                    .local_name = try self.dup(local_name),
                    .expr = expr,
                });
                if (!self.match(.comma)) break;
            }
        }
        return ast.Instance{
            .module_name = try self.dup(module_name),
            .substitutions = try self.dup_slice(ast.Substitution, subs.items),
        };
    }

    fn parse_definition(self: *Parser) !ast.Definition {
        const definition_col = self.current.col;
        const left_param = try self.parse_param_name();
        const saved_def_col = self.def_col;
        self.def_col = definition_col;
        defer self.def_col = saved_def_col;

        // Recursive function definition: F[x \in S] == body.
        if (self.current.kind == .lbracket) {
            try self.expect(.lbracket);
            var function_vars = std.ArrayList([]const u8).empty;
            defer function_vars.deinit(std.heap.page_allocator);
            var function_domain: ?*ast.Expr = null;
            var binder_count: u32 = 0;
            while (true) {
                var binder_vars: u32 = 0;
                if (self.match(.langle)) {
                    while (true) {
                        try function_vars.append(
                            std.heap.page_allocator,
                            try self.dup(try self.expect_ident_text()),
                        );
                        binder_vars += 1;
                        if (!self.match(.comma)) break;
                    }
                    try self.expect(.rangle);
                } else {
                    try function_vars.append(
                        std.heap.page_allocator,
                        try self.dup(try self.expect_ident_text()),
                    );
                    binder_vars = 1;
                }
                std.debug.assert(binder_vars > 0);
                try self.expect(.in);
                const binder_domain = try self.parse_expr();
                function_domain = if (function_domain) |domain|
                    try self.expr_set_binary(.cartesian_op, domain, binder_domain)
                else
                    binder_domain;
                binder_count += 1;
                if (!self.match(.comma)) break;
            }
            std.debug.assert(function_vars.items.len > 0);
            std.debug.assert(binder_count > 0);
            try self.expect(.rbracket);
            try self.expect(.defeq);
            const body = try self.parse_definition_body();
            return ast.Definition{
                .name = left_param,
                .params = &.{},
                .body = body,
                .is_function = true,
                .function_var = function_vars.items[0],
                .function_vars = try self.dup_slice([]const u8, function_vars.items),
                .function_domain = function_domain.?,
            };
        }

        // Infix operator definitions such as `a + b == ...`, `_ \cup _ == ...`,
        // `a \prec b == ...`, or `a ++ b == ...`. The operator name becomes the
        // definition name and the surrounding identifiers/underscores become the
        // parameters.
        if (try self.read_infix_operator_name_for_def()) |op_name| {
            const right_param = try self.parse_param_name();
            try self.expect(.defeq);
            const body = try self.parse_definition_body();
            var params = std.ArrayList([]const u8).empty;
            defer params.deinit(std.heap.page_allocator);
            try params.append(std.heap.page_allocator, left_param);
            try params.append(std.heap.page_allocator, right_param);
            return ast.Definition{
                .name = op_name,
                .params = try self.dup_slice([]const u8, params.items),
                .body = body,
            };
        }

        var params = std.ArrayList([]const u8).empty;
        defer params.deinit(std.heap.page_allocator);
        try params.append(std.heap.page_allocator, left_param);
        if (self.match(.lparen)) {
            if (self.current.kind != .rparen) {
                while (true) {
                    const pname = try self.expect_ident_text();
                    try params.append(std.heap.page_allocator, try self.dup(pname));
                    // Higher-order parameter syntax: Op(_) or Op(_,_) ; arity ignored for now.
                    if (self.current.kind == .lparen) {
                        try self.expect(.lparen);
                        while (self.current.kind != .rparen) {
                            if (self.current.kind == .underscore or self.current.kind == .ident) {
                                self.advance();
                            } else if (self.current.kind == .comma) {
                                self.advance();
                            } else {
                                return error.SyntaxError;
                            }
                        }
                        try self.expect(.rparen);
                    }
                    if (!self.match(.comma)) break;
                }
            }
            try self.expect(.rparen);
        }
        try self.expect(.defeq);

        const body = try self.parse_definition_body();
        return ast.Definition{
            .name = params.items[0],
            .params = try self.dup_slice([]const u8, params.items[1..]),
            .body = body,
        };
    }

    fn parse_param_name(self: *Parser) ![]const u8 {
        if (self.current.kind == .ident) {
            const name = self.current.text;
            self.advance();
            return try self.dup(name);
        }
        if (self.current.kind == .underscore) {
            const name = self.current.text;
            self.advance();
            return try self.dup(name);
        }
        return error.SyntaxError;
    }

    /// Read a user-defined infix operator name at a definition site. This
    /// recognizes identifiers (e.g. `\prec`), single operator tokens (e.g. `+`),
    /// and double-character operators (e.g. `++`, `--`). Returns null when the
    /// current token does not start an infix operator.
    fn read_infix_operator_name_for_def(self: *Parser) !?[]const u8 {
        if (self.current.kind == .ident) {
            const name = self.current.text;
            self.advance();
            return try self.dup(name);
        }
        // Single-character operator tokens that are valid infix operators.
        const single_op_kinds = [_]Token.Kind{
            .plus,  .minus,    .star,      .slash,    .percent,   .power,
            .range, .concat,   .ooverride, .recordto, .cartesian, .le,
            .ge,    .lt,       .gt,        .eq,       .neq,       .in,
            .notin, .subseteq, .leads_to,  .cup,      .cap,       .setminus,
        };
        for (single_op_kinds) |kind| {
            if (self.current.kind == kind and (self.next.kind == .ident or self.next.kind == .underscore)) {
                const name = self.current.text;
                self.advance();
                return try self.dup(name);
            }
        }
        // Double-character operators such as `++`, `--`, `**`, `//`, `%%`.
        const double_op_kinds = [_]Token.Kind{ .plus, .minus, .star, .slash, .percent };
        for (double_op_kinds) |kind| {
            if (self.current.kind == kind and self.next.kind == kind) {
                self.advance();
                self.advance();
                const text = try self.arena.alloc(u8, 2);
                text[0] = switch (kind) {
                    .plus => '+',
                    .minus => '-',
                    .star => '*',
                    .slash => '/',
                    .percent => '%',
                    else => unreachable,
                };
                text[1] = text[0];
                return text;
            }
        }
        return null;
    }

    /// Read a user-defined infix operator name in an expression. This does NOT
    /// consume single-character built-in operators such as `+` or `-`; those are
    /// handled by the dedicated arithmetic parsers. It does consume identifiers
    /// (e.g. `\prec`) and double-character operators (e.g. `++`).
    /// It refuses to consume an operator when it is immediately followed by `==`,
    /// because that signals the start of the next definition, not an infix
    /// application.
    fn read_infix_operator_name_for_expr(self: *Parser) !?[]const u8 {
        // A token at column 1 is the start of a new definition, not an infix
        // operator continuing the current expression. This prevents the
        // expression parser from swallowing the next definition name.
        // Also refuse operators at or to the left of the current definition
        // column so LET/definition bodies do not consume the next definition.
        if (self.current.kind == .ident and self.next.kind != .defeq and
            self.current.col > 1 and self.current.col > self.def_col)
        {
            const name = self.current.text;
            self.advance();
            return try self.dup(name);
        }
        const double_op_kinds = [_]Token.Kind{ .plus, .minus, .star, .slash, .percent };
        for (double_op_kinds) |kind| {
            if (self.current.kind == kind and self.next.kind == kind and
                self.current.col > 1 and self.current.col > self.def_col)
            {
                // Lookahead: the token after the double operator must not be `==`.
                // Since we only have `current` and `next`, we cannot peek two
                // ahead without advancing. Advance through the operator and then
                // check; if it is followed by `==`, restore the saved state.
                const saved = self.*;
                self.advance();
                self.advance();
                if (self.current.kind == .defeq) {
                    self.* = saved;
                    return null;
                }
                const text = try self.arena.alloc(u8, 2);
                text[0] = switch (kind) {
                    .plus => '+',
                    .minus => '-',
                    .star => '*',
                    .slash => '/',
                    .percent => '%',
                    else => unreachable,
                };
                text[1] = text[0];
                return text;
            }
        }
        return null;
    }

    fn parse_definition_body(self: *Parser) !*ast.Expr {
        if (self.current.kind == .and_op) return try self.parse_item_list(.and_op, true);
        if (self.current.kind == .or_op) return try self.parse_item_list(.or_op, true);
        return try self.parse_expr();
    }

    fn at_def_col(self: *Parser) bool {
        // Only block operators at column 1 when not inside any grouping and the
        // current definition started at column > 1. This prevents the parser
        // from consuming the first token of the NEXT definition as an infix
        // operator continuing the current expression.
        return self.current.col == 1 and self.group_depth == 0 and self.def_col > 1;
    }

    fn has_active_list_col(self: *Parser, col: u32) bool {
        var i: u32 = 0;
        while (i < self.list_cols_len) : (i += 1) {
            if (self.list_cols[i] == col) return true;
        }
        return false;
    }

    fn parse_expr(self: *Parser) anyerror!*ast.Expr {
        if (self.current.kind == .and_op and !self.has_active_list_col(self.current.col)) {
            return try self.parse_item_list(.and_op, false);
        }
        if (self.current.kind == .or_op and !self.has_active_list_col(self.current.col)) {
            return try self.parse_item_list(.or_op, false);
        }
        return try self.parse_implies();
    }

    fn push_list_col(self: *Parser, col: u32) void {
        std.debug.assert(self.list_cols_len < self.list_cols.len);
        self.list_cols[self.list_cols_len] = col;
        self.list_cols_len += 1;
    }

    fn pop_list_col(self: *Parser) void {
        std.debug.assert(self.list_cols_len > 0);
        self.list_cols_len -= 1;
    }

    fn parse_item_list(
        self: *Parser,
        op: ast.BinaryOp,
        allow_initial_dedent: bool,
    ) anyerror!*ast.Expr {
        var col = self.current.col;
        self.push_list_col(col);
        const first_line = self.current.line;
        self.advance();
        var left = try self.parse_list_item(first_line);
        const op_kind: Token.Kind = if (op == .and_op) .and_op else .or_op;
        if (allow_initial_dedent and
            self.current.kind == op_kind and
            self.current.col < col)
        {
            col = self.current.col;
            self.list_cols[self.list_cols_len - 1] = col;
        }
        while (self.current.kind == op_kind and self.current.col == col) {
            const item_line = self.current.line;
            self.advance();
            const right = try self.parse_list_item(item_line);
            left = try self.expr_binary(op, left, right);
        }
        self.pop_list_col();
        if (self.match(.implies)) {
            return try self.expr_binary(.implies, left, try self.parse_implies());
        }
        if (self.match(.leads_to)) {
            return try self.expr_binary(.leads_to, left, try self.parse_implies());
        }
        return left;
    }

    fn parse_list_item(self: *Parser, bullet_line: u32) !*ast.Expr {
        const left = try self.parse_equiv();
        if (self.current.line != bullet_line) return left;
        if (self.match(.implies)) {
            return try self.expr_binary(.implies, left, try self.parse_implies());
        }
        if (self.match(.leads_to)) {
            return try self.expr_binary(.leads_to, left, try self.parse_implies());
        }
        return left;
    }

    fn parse_implies(self: *Parser) !*ast.Expr {
        const left = try self.parse_equiv();
        if (self.match(.implies)) {
            const right = try self.parse_implies();
            return try self.expr_binary(.implies, left, right);
        }
        if (self.match(.leads_to)) {
            const right = try self.parse_implies();
            return try self.expr_binary(.leads_to, left, right);
        }
        return left;
    }

    fn parse_equiv(self: *Parser) !*ast.Expr {
        var left = try self.parse_or();
        while (self.match(.equiv)) {
            const right = try self.parse_or();
            left = try self.expr_binary(.equiv, left, right);
        }
        return left;
    }

    fn parse_or(self: *Parser) !*ast.Expr {
        var left = try self.parse_and();
        while (self.current.kind == .or_op and !self.is_list_separator()) {
            self.advance();
            const right = try self.parse_and();
            left = try self.expr_binary(.or_op, left, right);
        }
        return left;
    }

    fn parse_and(self: *Parser) !*ast.Expr {
        var left = try self.parse_not();
        while (self.current.kind == .and_op and !self.is_list_separator()) {
            self.advance();
            const right = try self.parse_not();
            left = try self.expr_binary(.and_op, left, right);
        }
        return left;
    }

    fn is_list_separator(self: *Parser) bool {
        if (self.current.kind != .and_op and self.current.kind != .or_op) return false;
        var i: u32 = 0;
        while (i < self.list_cols_len) : (i += 1) {
            if (self.current.col == self.list_cols[i]) return true;
        }
        return false;
    }

    fn parse_not(self: *Parser) !*ast.Expr {
        // TLA+ allows a bulleted conjunction/disjunction to appear as a
        // standalone primary.  The list column must be outside any enclosing
        // list scope.
        if (self.current.kind == .and_op and !self.has_active_list_col(self.current.col)) {
            return try self.parse_item_list(.and_op, false);
        }
        if (self.current.kind == .or_op and !self.has_active_list_col(self.current.col)) {
            return try self.parse_item_list(.or_op, false);
        }
        return try self.parse_comparison();
    }

    fn parse_cartesian(self: *Parser) !*ast.Expr {
        var left = try self.parse_concat();
        while (self.match(.cartesian)) {
            const right = try self.parse_concat();
            left = try self.expr_set_binary(.cartesian_op, left, right);
        }
        return left;
    }

    fn parse_comparison(self: *Parser) !*ast.Expr {
        const left = try self.parse_cartesian();
        if (self.current.kind == .in and
            self.let_definition_depth > 0 and
            self.group_depth == 0 and
            self.def_col > 0 and
            self.current.col < self.def_col)
        {
            return left;
        }
        const op: ?ast.BinaryOp = switch (self.current.kind) {
            .eq => .eq,
            .neq => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            .in => .in,
            .notin => .notin,
            .subseteq => .subseteq,
            else => null,
        };
        if (op) |o| {
            self.advance();
            const right = try self.parse_cartesian();
            return try self.expr_binary(o, left, right);
        }
        return left;
    }

    fn parse_union(self: *Parser) !*ast.Expr {
        var left = try self.parse_intersection();
        while (self.match(.cup)) {
            const right = try self.parse_intersection();
            left = try self.expr_set_binary(.union_op, left, right);
        }
        return left;
    }

    fn parse_intersection(self: *Parser) !*ast.Expr {
        var left = try self.parse_difference();
        while (self.match(.cap)) {
            const right = try self.parse_difference();
            left = try self.expr_set_binary(.intersection_op, left, right);
        }
        return left;
    }

    fn parse_difference(self: *Parser) !*ast.Expr {
        var left = try self.parse_range();
        while (self.match(.setminus)) {
            const right = try self.parse_range();
            left = try self.expr_set_binary(.difference_op, left, right);
        }
        return left;
    }

    fn parse_range(self: *Parser) !*ast.Expr {
        var left = try self.parse_additive();
        while (self.match(.range)) {
            const right = try self.parse_additive();
            left = try self.expr_binary(.range, left, right);
        }
        return left;
    }

    fn parse_concat(self: *Parser) !*ast.Expr {
        var left = try self.parse_recordto();
        while (true) {
            if (self.match(.concat)) {
                const right = try self.parse_recordto();
                left = try self.expr_binary(.concat, left, right);
            } else if (self.match(.ooverride)) {
                const right = try self.parse_recordto();
                left = try self.expr_binary(.ooverride, left, right);
            } else break;
        }
        return left;
    }

    fn parse_recordto(self: *Parser) !*ast.Expr {
        var left = try self.parse_union();
        while (self.match(.recordto)) {
            const right = try self.parse_union();
            left = try self.expr_binary(.recordto, left, right);
        }
        return left;
    }

    fn parse_additive(self: *Parser) !*ast.Expr {
        var left = try self.parse_multiplicative();
        while (true) {
            const infix_name = try self.read_infix_operator_name_for_expr();
            if (infix_name) |name| {
                const right = try self.parse_multiplicative();
                left = try self.expr_infix_apply(name, left, right);
                continue;
            }
            // Don't consume `-` when it is followed by `.` (prefix negation
            // definition `-. name == ...`).
            if (self.at_def_col()) break;
            const is_minus_dot = self.current.kind == .minus and self.next.kind == .dot;
            if (is_minus_dot) break;
            const op: ?ast.BinaryOp = if (self.match(.plus)) .plus else if (self.match(.minus)) .minus else null;
            if (op) |o| {
                const right = try self.parse_multiplicative();
                left = try self.expr_binary(o, left, right);
            } else break;
        }
        return left;
    }

    fn parse_multiplicative(self: *Parser) !*ast.Expr {
        var left = try self.parse_power();
        while (true) {
            const infix_name = try self.read_infix_operator_name_for_expr();
            if (infix_name) |name| {
                const right = try self.parse_power();
                left = try self.expr_infix_apply(name, left, right);
                continue;
            }
            const op: ?ast.BinaryOp = if (self.match(.star)) .times else if (self.match(.slash)) .div else if (self.match(.percent)) .mod else null;
            if (op) |o| {
                const right = try self.parse_power();
                left = try self.expr_binary(o, left, right);
            } else break;
        }
        return left;
    }

    fn parse_power(self: *Parser) !*ast.Expr {
        var left = try self.parse_unary();
        while (true) {
            const infix_name = try self.read_infix_operator_name_for_expr();
            if (infix_name) |name| {
                const right = try self.parse_unary();
                left = try self.expr_infix_apply(name, left, right);
                continue;
            }
            const op: ?ast.BinaryOp = if (self.match(.power)) .power else null;
            if (op) |o| {
                const right = try self.parse_unary();
                left = try self.expr_binary(o, left, right);
            } else break;
        }
        return left;
    }

    fn expr_infix_apply(self: *Parser, name: []const u8, left: *ast.Expr, right: *ast.Expr) !*ast.Expr {
        const func = try self.expr_ident(name);
        const args = try self.arena.alloc(*ast.Expr, 2);
        args[0] = left;
        args[1] = right;
        return try self.expr_apply(func, args);
    }

    fn parse_unary(self: *Parser) !*ast.Expr {
        // Proof/step labels such as P0:: expr are semantically no-ops.
        if (self.current.kind == .ident and self.next.kind == .colon) {
            const saved = self.*;
            self.advance(); // ident
            self.advance(); // first colon
            if (self.current.kind == .colon) {
                self.advance(); // second colon
                // Use parse_expr to handle bulleted lists after labels.
                return try self.parse_expr();
            }
            self.* = saved;
        }
        if (self.match(.not)) {
            // A prefix ~ can apply to a bulleted conjunction/disjunction, e.g.
            //   ~ /\ A /\ B
            if ((self.current.kind == .and_op or self.current.kind == .or_op) and
                !self.has_active_list_col(self.current.col))
            {
                const op: ast.BinaryOp = if (self.current.kind == .and_op) .and_op else .or_op;
                const operand = try self.parse_item_list(op, false);
                return try self.expr_unary(.not, operand);
            }
            return try self.expr_unary(.not, try self.parse_unary());
        }
        if (self.match(.minus)) return try self.expr_unary(.neg, try self.parse_unary());
        if (self.match(.keyword_subset)) return try self.expr_unary(.subset, try self.parse_unary());
        if (self.match(.keyword_union)) return try self.expr_unary(.union_all, try self.parse_unary());
        if (self.match(.keyword_domain)) return try self.expr_unary(.domain, try self.parse_unary());
        if (self.current.kind == .ident and std.mem.eql(u8, self.current.text, "ENABLED")) {
            self.advance();
            return try self.expr_unary(.enabled, try self.parse_unary());
        }
        return try self.parse_primary();
    }

    fn parse_primary(self: *Parser) anyerror!*ast.Expr {
        switch (self.current.kind) {
            .number => {
                const text = self.current.text;
                self.advance();
                return try self.expr_int(try std.fmt.parseInt(i64, text, 10));
            },
            .keyword_true => {
                self.advance();
                return try self.expr_bool(true);
            },
            .keyword_false => {
                self.advance();
                return try self.expr_bool(false);
            },
            .string => {
                const text = self.current.text;
                self.advance();
                return try self.expr_string(text[1 .. text.len - 1]);
            },
            .ident => {
                const name = try self.parse_qualified_ident_name();
                var expr = try self.expr_ident(name);
                if (self.match(.prime)) {
                    expr = try self.expr_primed(name);
                }
                return try self.parse_suffixes(expr);
            },
            .lparen => {
                self.advance();
                self.group_depth += 1;
                const e = try self.parse_expr();
                try self.expect(.rparen);
                self.group_depth -= 1;
                return try self.parse_suffixes(e);
            },
            .lbrace => {
                const expr = try self.parse_set();
                return try self.parse_suffixes(expr);
            },
            .lbracket => {
                if (self.next.kind == .rbracket) {
                    self.advance();
                    self.advance();
                    const operand = try self.parse_expr();
                    const u = try self.arena.alloc(ast.Unary, 1);
                    u[0] = .{ .op = .temporal_box, .operand = operand };
                    const ptr = try self.arena.alloc(ast.Expr, 1);
                    ptr[0] = .{ .unary = &u[0] };
                    return &ptr[0];
                }
                const expr = try self.parse_function_or_record();
                // [A]_v stuttering action
                if (self.match(.underscore)) {
                    const vars_expr = try self.parse_primary();
                    return try self.expr_box_action(expr, vars_expr);
                }
                return try self.parse_suffixes(expr);
            },
            .at => {
                self.advance();
                return try self.parse_suffixes(try self.expr_at());
            },
            .langle => {
                const expr = try self.parse_tuple();
                if (self.match(.underscore)) {
                    const vars_expr = try self.parse_primary();
                    return try self.expr_box_action(expr, vars_expr);
                }
                return try self.parse_suffixes(expr);
            },
            .keyword_choose => return try self.parse_choose(),
            .keyword_if => return try self.parse_if(),
            .keyword_forall => return try self.parse_quantifier(.forall),
            .keyword_exists => return try self.parse_quantifier(.exists),
            .keyword_unchanged => return try self.parse_unchanged(),
            .keyword_let => return try self.parse_let_in(),
            .keyword_case => return try self.parse_case_expr(),
            .keyword_lambda => return try self.parse_lambda(),
            .diamond => {
                self.advance();
                const operand = try self.parse_expr();
                const u = try self.arena.alloc(ast.Unary, 1);
                u[0] = .{ .op = .temporal_diamond, .operand = operand };
                const ptr = try self.arena.alloc(ast.Expr, 1);
                ptr[0] = .{ .unary = &u[0] };
                return &ptr[0];
            },
            // Operator references: `+`, `\cup`, etc. used as values.
            // We generate a 2-parameter lambda so higher-order application works.
            .plus, .minus, .cup, .cap, .setminus, .concat, .ooverride, .recordto, .star, .slash, .power, .range, .subseteq, .in, .notin, .lt, .le, .gt, .ge, .eq, .neq, .equiv, .implies, .leads_to, .and_op, .or_op, .cartesian => return try self.parse_operator_ref(),
            else => return error.SyntaxError,
        }
    }

    fn parse_operator_ref(self: *Parser) !*ast.Expr {
        const left = try self.expr_ident("__op_l");
        const right = try self.expr_ident("__op_r");
        const bin_op: ?ast.BinaryOp = switch (self.current.kind) {
            .plus => .plus,
            .minus => .minus,
            .star => .times,
            .slash => .div,
            .power => .power,
            .range => .range,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            .eq => .eq,
            .neq => .ne,
            .in => .in,
            .notin => .notin,
            .subseteq => .subseteq,
            .equiv => .equiv,
            .implies => .implies,
            .leads_to => .leads_to,
            .and_op => .and_op,
            .or_op => .or_op,
            .concat => .concat,
            .ooverride => .ooverride,
            .recordto => .recordto,
            else => null,
        };
        if (bin_op) |bop| {
            self.advance();
            const body = try self.expr_binary(bop, left, right);
            const params = try self.arena.alloc([]const u8, 2);
            params[0] = try self.dup("__op_l");
            params[1] = try self.dup("__op_r");
            return try self.expr_lambda(params, body);
        }
        // Set binary operators (\cup, \cap, \, \X).
        const set_op: ?ast.SetBinaryOp = switch (self.current.kind) {
            .cup => .union_op,
            .cap => .intersection_op,
            .setminus => .difference_op,
            .cartesian => .cartesian_op,
            else => null,
        };
        if (set_op) |sop| {
            self.advance();
            const body = try self.expr_set_binary(sop, left, right);
            const params = try self.arena.alloc([]const u8, 2);
            params[0] = try self.dup("__op_l");
            params[1] = try self.dup("__op_r");
            return try self.expr_lambda(params, body);
        }
        return error.SyntaxError;
    }

    fn parse_suffixes(self: *Parser, expr: *ast.Expr) anyerror!*ast.Expr {
        var result = expr;
        while (true) {
            if (self.match(.lparen)) {
                const args = try self.parse_expr_list(.rparen);
                result = try self.expr_apply(result, args);
                continue;
            }
            // Only treat `[...]` as a function/sequence application if it is
            // non-empty.  An empty `[]` is the CASE arm separator, not a suffix.
            if (self.current.kind == .lbracket and self.next.kind != .rbracket) {
                self.advance();
                const args = try self.parse_expr_list(.rbracket);
                result = try self.expr_apply(result, args);
                continue;
            }
            if (self.match(.dot)) {
                const field = try self.expect_ident_text();
                result = try self.expr_field(result, field);
                continue;
            }
            // Primed suffix: f[x]' means (f[x])' which equals f'[x].
            // Transform the expression: if it's apply(primed_var, args),
            // change to apply(primed, args). If it's just ident, make primed.
            if (self.match(.prime)) {
                switch (result.*) {
                    .ident => |name| {
                        result = try self.expr_primed(name);
                    },
                    .apply => |ap| {
                        // Transform f[x]' into f'[x]
                        const func = ap.func;
                        switch (func.*) {
                            .ident => |name| {
                                const primed_func = try self.expr_primed(name);
                                const new_ap = try self.arena.alloc_object(ast.Apply);
                                new_ap.* = ast.Apply{ .func = primed_func, .args = ap.args };
                                const ptr = try self.arena.alloc_object(ast.Expr);
                                ptr.* = ast.Expr{ .apply = new_ap };
                                result = ptr;
                            },
                            else => {
                                // Can't prime a complex expression.
                                // Leave as-is (error will surface during eval).
                            },
                        }
                    },
                    else => {
                        // Can't prime other expression types.
                    },
                }
                continue;
            }
            break;
        }
        return result;
    }

    fn parse_tuple_set_filter(self: *Parser) !*ast.Expr {
        self.group_depth += 1;
        self.advance(); // <<
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(std.heap.page_allocator);
        while (true) {
            const name = try self.expect_ident_text();
            try names.append(std.heap.page_allocator, try self.dup(name));
            if (!self.match(.comma)) break;
        }
        if (self.current.kind != .rangle) return error.SyntaxError;
        self.advance(); // >>
        self.group_depth -= 1;
        try self.expect(.in);
        const domain = try self.parse_expr();
        try self.expect(.colon);
        const pred = try self.parse_expr();
        try self.expect(.rbrace);
        const tup_name = try self.dup("__tup");
        const tup_var = ast.BoundVar{ .name = tup_name, .domain = domain };
        var let_defs = std.ArrayList(ast.Definition).empty;
        defer let_defs.deinit(std.heap.page_allocator);
        for (names.items, 0..) |n, idx| {
            const tup_ident = try self.expr_ident(tup_name);
            const idx_lit = try self.expr_int(@intCast(idx + 1));
            const args = try self.arena.alloc(*ast.Expr, 1);
            args[0] = idx_lit;
            const access = try self.expr_apply(tup_ident, args);
            let_defs.append(std.heap.page_allocator, ast.Definition{
                .name = n,
                .params = &.{},
                .body = access,
            }) catch return error.OutOfMemory;
        }
        const wrapped_pred = try self.expr_let_in(let_defs.items, pred);
        const single_var = try self.arena.alloc(ast.BoundVar, 1);
        single_var[0] = tup_var;
        return try self.expr_set_filter(single_var, wrapped_pred);
    }

    fn try_parse_function_literal(self: *Parser) !*ast.Expr {
        var vars = std.ArrayList(ast.BoundVar).empty;
        defer vars.deinit(std.heap.page_allocator);
        while (true) {
            var names = std.ArrayList([]const u8).empty;
            defer names.deinit(std.heap.page_allocator);
            while (true) {
                const name = try self.expect_ident_text();
                try names.append(std.heap.page_allocator, try self.dup(name));
                if (!self.match(.comma)) break;
            }
            try self.expect(.in);
            const domain = try self.parse_expr();
            for (names.items) |name| {
                try vars.append(std.heap.page_allocator, .{ .name = name, .domain = domain });
            }
            if (!self.match(.comma)) break;
        }
        try self.expect(.mapsto);
        const body = try self.parse_expr();
        try self.expect(.rbracket);
        return try self.expr_function_literal(vars.items, body);
    }

    fn parse_set(self: *Parser) !*ast.Expr {
        try self.expect(.lbrace);
        if (self.current.kind == .rbrace) {
            self.advance();
            return try self.expr_set_enum(&[_]*ast.Expr{});
        }
        if (self.current.kind == .ident and self.next.kind == .in) {
            var vars = std.ArrayList(ast.BoundVar).empty;
            defer vars.deinit(std.heap.page_allocator);
            while (true) {
                var names = std.ArrayList([]const u8).empty;
                defer names.deinit(std.heap.page_allocator);
                while (true) {
                    const name = try self.expect_ident_text();
                    try names.append(std.heap.page_allocator, try self.dup(name));
                    if (!self.match(.comma)) break;
                }
                try self.expect(.in);
                const domain = try self.parse_expr();
                for (names.items) |name| {
                    try vars.append(std.heap.page_allocator, .{ .name = name, .domain = domain });
                }
                if (!self.match(.comma)) break;
            }
            try self.expect(.colon);
            const pred = try self.parse_expr();
            try self.expect(.rbrace);
            return try self.expr_set_filter(vars.items, pred);
        }
        // Tuple destructuring set filter: {<<a, b>> \in S : P}
        if (self.current.kind == .langle) {
            const saved = self.*;
            self.suppress_errors = true;
            if (self.parse_tuple_set_filter()) |result| {
                self.suppress_errors = saved.suppress_errors;
                return result;
            } else |err| {
                if (err == error.OutOfMemory) return err;
                self.* = saved;
            }
        }
        const first = try self.parse_expr();
        if (self.current.kind == .colon) {
            self.advance();
            // Check for tuple destructuring in set map: {e : <<a, b>> \in S}
            if (self.current.kind == .langle) {
                self.advance(); // <<
                var names = std.ArrayList([]const u8).empty;
                defer names.deinit(std.heap.page_allocator);
                while (true) {
                    const name = try self.expect_ident_text();
                    try names.append(std.heap.page_allocator, try self.dup(name));
                    if (!self.match(.comma)) break;
                }
                try self.expect(.rangle);
                try self.expect(.in);
                const domain = try self.parse_expr();
                try self.expect(.rbrace);
                // Build set map with single variable __tup and wrap value in LET.
                const tup_name = try self.dup("__tup");
                var let_defs = std.ArrayList(ast.Definition).empty;
                defer let_defs.deinit(std.heap.page_allocator);
                for (names.items, 0..) |n, idx| {
                    const tup_ident = try self.expr_ident(tup_name);
                    const idx_lit = try self.expr_int(@intCast(idx + 1));
                    const args = try self.arena.alloc(*ast.Expr, 1);
                    args[0] = idx_lit;
                    const access = try self.expr_apply(tup_ident, args);
                    let_defs.append(std.heap.page_allocator, ast.Definition{
                        .name = n,
                        .params = &.{},
                        .body = access,
                    }) catch return error.OutOfMemory;
                }
                const wrapped_value = try self.expr_let_in(let_defs.items, first);
                const single_var = try self.arena.alloc(ast.BoundVar, 1);
                single_var[0] = ast.BoundVar{ .name = tup_name, .domain = domain };
                return try self.expr_set_map(single_var, wrapped_value);
            }
            var vars = std.ArrayList(ast.BoundVar).empty;
            defer vars.deinit(std.heap.page_allocator);
            while (true) {
                var names = std.ArrayList([]const u8).empty;
                defer names.deinit(std.heap.page_allocator);
                while (true) {
                    const name = try self.expect_ident_text();
                    try names.append(std.heap.page_allocator, try self.dup(name));
                    if (!self.match(.comma)) break;
                }
                try self.expect(.in);
                const domain = try self.parse_expr();
                for (names.items) |name| {
                    try vars.append(std.heap.page_allocator, .{ .name = name, .domain = domain });
                }
                if (!self.match(.comma)) break;
            }
            try self.expect(.rbrace);
            return try self.expr_set_map(vars.items, first);
        }
        var items = std.ArrayList(*ast.Expr).empty;
        defer items.deinit(std.heap.page_allocator);
        try items.append(std.heap.page_allocator, first);
        while (self.match(.comma)) {
            try items.append(std.heap.page_allocator, try self.parse_expr());
        }
        try self.expect(.rbrace);
        return try self.expr_set_enum(try self.dup_slice(*ast.Expr, items.items));
    }

    fn parse_function_or_record(self: *Parser) !*ast.Expr {
        try self.expect(.lbracket);
        if (self.match(.rbracket)) {
            // [] temporal box, or empty bracket grouping.
            const operand = try self.parse_expr();
            const u = try self.arena.alloc(ast.Unary, 1);
            u[0] = .{ .op = .temporal_box, .operand = operand };
            const ptr = try self.arena.alloc(ast.Expr, 1);
            ptr[0] = .{ .unary = &u[0] };
            return &ptr[0];
        }
        if (self.current.kind == .ident and self.next.kind == .mapsto) {
            const fields = try self.parse_record_fields();
            var expr = try self.expr_record(fields);
            if (self.match(.except)) {
                while (true) {
                    const steps = try self.parse_except_steps();
                    try self.expect(.eq);
                    const value = try self.parse_expr();
                    expr = try self.expr_except(expr, steps, value);
                    if (!self.match(.comma)) break;
                }
                try self.expect(.rbracket);
            } else {
                try self.expect(.rbracket);
            }
            return expr;
        }
        if (self.current.kind == .ident and self.next.kind == .colon) {
            const fields = try self.parse_record_set_fields();
            try self.expect(.rbracket);
            return try self.expr_record_set(fields);
        }
        // Function literal: [x \in S |-> body] or [x, y \in S |-> body]
        if (self.current.kind == .ident) {
            const saved = self.*;
            self.suppress_errors = true;
            const result = self.try_parse_function_literal();
            self.suppress_errors = false;
            if (result) |r| return r else |_| {
                self.* = saved;
            }
        }
        const func = try self.parse_expr();
        if (self.match(.arrow)) {
            const codomain = try self.parse_expr();
            try self.expect(.rbracket);
            return try self.expr_set_of_functions(func, codomain);
        }
        if (self.match(.except)) {
            var expr = func;
            while (true) {
                const steps = try self.parse_except_steps();
                try self.expect(.eq);
                const value = try self.parse_expr();
                expr = try self.expr_except(expr, steps, value);
                if (!self.match(.comma)) break;
            }
            try self.expect(.rbracket);
            return expr;
        }
        try self.expect(.rbracket);
        if (self.match(.underscore)) {
            const vars_expr = try self.parse_primary();
            return try self.expr_box_action(func, vars_expr);
        }
        return func;
    }

    fn parse_except_steps(self: *Parser) ![]const ast.AccessStep {
        var steps = std.ArrayList(ast.AccessStep).empty;
        defer steps.deinit(std.heap.page_allocator);
        try self.expect(.bang);
        while (true) {
            if (self.match(.dot)) {
                const field = try self.expect_ident_text();
                try steps.append(std.heap.page_allocator, ast.AccessStep{ .field = try self.dup(field) });
            } else if (self.match(.lbracket)) {
                // Handle tuple indices: ![a, b] means access at <<a, b>>.
                const first = try self.parse_expr();
                if (self.match(.comma)) {
                    var tuple_items = std.ArrayList(*ast.Expr).empty;
                    defer tuple_items.deinit(std.heap.page_allocator);
                    try tuple_items.append(std.heap.page_allocator, first);
                    while (true) {
                        try tuple_items.append(std.heap.page_allocator, try self.parse_expr());
                        if (!self.match(.comma)) break;
                    }
                    try self.expect(.rbracket);
                    const tup = try self.expr_tuple(try self.dup_slice(*ast.Expr, tuple_items.items));
                    try steps.append(std.heap.page_allocator, ast.AccessStep{ .index = tup });
                } else {
                    try self.expect(.rbracket);
                    try steps.append(std.heap.page_allocator, ast.AccessStep{ .index = first });
                }
            } else {
                return error.SyntaxError;
            }
            if (self.current.kind == .comma or self.current.kind == .eq) break;
        }
        return try self.dup_slice(ast.AccessStep, steps.items);
    }

    fn parse_record_fields(self: *Parser) ![]const ast.FieldInit {
        var fields = std.ArrayList(ast.FieldInit).empty;
        defer fields.deinit(std.heap.page_allocator);
        while (true) {
            const name = try self.expect_ident_text();
            try self.expect(.mapsto);
            const value = try self.parse_expr();
            try fields.append(std.heap.page_allocator, .{ .name = try self.dup(name), .value = value });
            if (!self.match(.comma)) break;
        }
        return try self.dup_slice(ast.FieldInit, fields.items);
    }

    fn parse_record_set_fields(self: *Parser) ![]const ast.RecordFieldDomain {
        var fields = std.ArrayList(ast.RecordFieldDomain).empty;
        defer fields.deinit(std.heap.page_allocator);
        while (true) {
            const name = try self.expect_ident_text();
            try self.expect(.colon);
            const domain = try self.parse_expr();
            try fields.append(std.heap.page_allocator, .{ .name = try self.dup(name), .domain = domain });
            if (!self.match(.comma)) break;
        }
        return try self.dup_slice(ast.RecordFieldDomain, fields.items);
    }

    fn parse_tuple(self: *Parser) !*ast.Expr {
        try self.expect(.langle);
        const items = try self.parse_expr_list(.rangle);
        return try self.expr_tuple(items);
    }

    fn parse_choose(self: *Parser) !*ast.Expr {
        try self.expect(.keyword_choose);
        const var_name = try self.expect_ident_text();
        const has_domain = self.current.kind == .in;
        var domain: ?*ast.Expr = null;
        if (has_domain) {
            self.advance();
            domain = try self.parse_expr();
        }
        try self.expect(.colon);
        const body = try self.parse_expr();
        return try self.expr_choose(var_name, domain, body);
    }

    fn parse_if(self: *Parser) !*ast.Expr {
        try self.expect(.keyword_if);
        const cond = try self.parse_expr();
        try self.expect(.keyword_then);
        const then_branch = try self.parse_expr();
        try self.expect(.keyword_else);
        const else_branch = try self.parse_expr();
        return try self.expr_if(cond, then_branch, else_branch);
    }

    fn parse_quantifier(self: *Parser, kind: ast.QuantifierKind) !*ast.Expr {
        self.advance();
        var vars = std.ArrayList(ast.BoundVar).empty;
        defer vars.deinit(std.heap.page_allocator);
        var tuple_names = std.ArrayList([]const []const u8).empty;
        defer tuple_names.deinit(std.heap.page_allocator);
        var tuple_vars = std.ArrayList([]const u8).empty;
        defer tuple_vars.deinit(std.heap.page_allocator);
        while (true) {
            if (self.match(.langle)) {
                var names = std.ArrayList([]const u8).empty;
                defer names.deinit(std.heap.page_allocator);
                while (true) {
                    try names.append(std.heap.page_allocator, try self.dup(try self.expect_ident_text()));
                    if (!self.match(.comma)) break;
                }
                try self.expect(.rangle);
                try self.expect(.in);
                const domain = try self.parse_expr();
                const tuple_var = try self.synthetic_name("__quant_tuple_", tuple_vars.items.len);
                try vars.append(std.heap.page_allocator, .{ .name = tuple_var, .domain = domain });
                try tuple_vars.append(std.heap.page_allocator, tuple_var);
                try tuple_names.append(
                    std.heap.page_allocator,
                    try self.dup_slice([]const u8, names.items),
                );
                if (!self.match(.comma)) break;
                continue;
            }
            var names = std.ArrayList([]const u8).empty;
            defer names.deinit(std.heap.page_allocator);
            while (true) {
                const name = try self.expect_ident_text();
                try names.append(std.heap.page_allocator, try self.dup(name));
                if (!self.match(.comma)) break;
            }
            try self.expect(.in);
            const domain = try self.parse_expr();
            for (names.items) |name| {
                try vars.append(std.heap.page_allocator, .{ .name = name, .domain = domain });
            }
            if (!self.match(.comma)) break;
        }
        try self.expect(.colon);
        var body = try self.parse_expr();
        if (tuple_vars.items.len > 0) {
            var defs = std.ArrayList(ast.Definition).empty;
            defer defs.deinit(std.heap.page_allocator);
            for (tuple_vars.items, tuple_names.items) |tuple_var, names| {
                for (names, 0..) |name, i| {
                    const tuple_expr = try self.expr_ident(tuple_var);
                    const index_expr = try self.expr_int(@intCast(i + 1));
                    const args = try self.arena.alloc(*ast.Expr, 1);
                    args[0] = index_expr;
                    try defs.append(std.heap.page_allocator, .{
                        .name = name,
                        .params = &.{},
                        .body = try self.expr_apply(tuple_expr, args),
                    });
                }
            }
            body = try self.expr_let_in(defs.items, body);
        }
        return try self.expr_quantifier(kind, vars.items, body);
    }

    fn synthetic_name(self: *Parser, prefix: []const u8, index: usize) ![]const u8 {
        var buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "{s}{d}", .{ prefix, index });
        return try self.dup(name);
    }

    fn parse_let_in(self: *Parser) !*ast.Expr {
        try self.expect(.keyword_let);
        var defs = std.ArrayList(ast.Definition).empty;
        defer defs.deinit(std.heap.page_allocator);
        while (true) {
            if (self.current.kind == .keyword_in) break;
            if (self.current.kind == .ident and self.next.kind == .defeq) {
                const saved = self.*;
                const alias = self.current.text;
                self.advance();
                self.advance();
                if (self.current.kind == .keyword_instance) {
                    const instance = try self.parse_instance();
                    if (instance.substitutions.len != 0) return error.NotImplemented;
                    std.debug.assert(self.hoisted_namespace_count < self.hoisted_namespace_instances.len);
                    self.hoisted_namespace_instances[self.hoisted_namespace_count] = .{
                        .alias = try self.dup(alias),
                        .module_name = instance.module_name,
                        .substitutions = instance.substitutions,
                    };
                    self.hoisted_namespace_count += 1;
                    continue;
                }
                self.* = saved;
            }
            self.let_definition_depth += 1;
            const def = self.parse_definition() catch |err| {
                self.let_definition_depth -= 1;
                return err;
            };
            self.let_definition_depth -= 1;
            try defs.append(std.heap.page_allocator, def);
            if (self.current.kind == .keyword_in) break;
        }
        try self.expect(.keyword_in);
        const body = try self.parse_expr();
        return try self.expr_let_in(defs.items, body);
    }

    fn parse_lambda(self: *Parser) !*ast.Expr {
        try self.expect(.keyword_lambda);
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(std.heap.page_allocator);
        while (true) {
            const name = try self.expect_ident_text();
            try names.append(std.heap.page_allocator, try self.dup(name));
            if (!self.match(.comma)) break;
        }
        try self.expect(.colon);
        const body = try self.parse_expr();
        return try self.expr_lambda(names.items, body);
    }

    fn expr_lambda(self: *Parser, params: []const []const u8, body: *ast.Expr) !*ast.Expr {
        const lptr = try self.arena.alloc_object(ast.Lambda);
        const dup_params = try self.arena.alloc([]const u8, params.len);
        for (params, 0..) |p, i| dup_params[i] = p;
        lptr.* = ast.Lambda{ .params = dup_params, .body = body };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .lambda = lptr };
        return ptr;
    }

    fn parse_case_expr(self: *Parser) !*ast.Expr {
        try self.expect(.keyword_case);
        var arms = std.ArrayList(ast.CaseArm).empty;
        defer arms.deinit(std.heap.page_allocator);
        while (true) {
            const cond = try self.parse_expr();
            try self.expect(.arrow);
            const value = try self.parse_expr();
            try arms.append(std.heap.page_allocator, .{ .cond = cond, .value = value });
            if (self.current.kind == .lbracket and self.next.kind == .rbracket) {
                self.advance();
                self.advance();
                if (self.current.kind == .keyword_other) break;
                continue;
            }
            break;
        }
        var otherwise: ?*ast.Expr = null;
        if (self.match(.keyword_other)) {
            try self.expect(.arrow);
            otherwise = try self.parse_expr();
        }
        return try self.expr_case_expr(arms.items, otherwise);
    }

    fn parse_unchanged(self: *Parser) !*ast.Expr {
        try self.expect(.keyword_unchanged);
        if (self.current.kind == .lparen) {
            return try self.expr_unchanged_expr(try self.parse_primary());
        }
        if (self.match(.langle)) {
            var vars = std.ArrayList([]const u8).empty;
            defer vars.deinit(std.heap.page_allocator);
            while (true) {
                const name = try self.parse_qualified_ident_name();
                try vars.append(std.heap.page_allocator, try self.dup(name));
                if (!self.match(.comma)) break;
            }
            try self.expect(.rangle);
            return try self.expr_unchanged(try self.dup_slice([]const u8, vars.items));
        }
        const name = try self.parse_qualified_ident_name();
        const arr = try self.arena.alloc([]const u8, 1);
        arr[0] = try self.dup(name);
        return try self.expr_unchanged(arr);
    }

    fn parse_qualified_ident_name(self: *Parser) ![]const u8 {
        var name = try self.expect_ident_text();
        while (self.match(.bang)) {
            const field = switch (self.current.kind) {
                .ident, .number => blk: {
                    const text = self.current.text;
                    self.advance();
                    break :blk text;
                },
                else => return error.SyntaxError,
            };
            name = try self.arena_concat_three(name, "!", field);
        }
        return name;
    }

    fn parse_expr_list(self: *Parser, end: Token.Kind) ![]const *ast.Expr {
        var items = std.ArrayList(*ast.Expr).empty;
        defer items.deinit(std.heap.page_allocator);
        if (self.current.kind != end) {
            while (true) {
                try items.append(std.heap.page_allocator, try self.parse_expr());
                if (!self.match(.comma)) break;
            }
        }
        try self.expect(end);
        return try self.dup_slice(*ast.Expr, items.items);
    }

    fn skip_dashes(self: *Parser) void {
        while (true) {
            if (self.current.kind == .minus) {
                self.advance();
                continue;
            }
            if (self.current.kind == .lparen and self.next.kind == .star) {
                self.skip_comment_block();
                continue;
            }
            break;
        }
    }

    fn skip_comment_block(self: *Parser) void {
        // current is '(' and next is '*'
        self.advance(); // '('
        self.advance(); // '*'
        var depth: u32 = 1;
        while (self.current.kind != .eof and depth > 0) {
            if (self.current.kind == .lparen and self.next.kind == .star) {
                self.advance();
                self.advance();
                depth += 1;
            } else if (self.current.kind == .star and self.next.kind == .rparen) {
                self.advance();
                self.advance();
                depth -= 1;
            } else {
                self.advance();
            }
        }
    }

    fn advance(self: *Parser) void {
        self.current = self.next;
        self.next = self.lexer.next();
    }

    fn match(self: *Parser, kind: Token.Kind) bool {
        if (self.current.kind == kind) {
            self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, kind: Token.Kind) !void {
        if (self.current.kind != kind) {
            if (!self.suppress_errors) {
                std.debug.print("SyntaxError: expected {s}, got {s} ({s}) at line {d} col {d}\n", .{ @tagName(kind), @tagName(self.current.kind), self.current.text, self.current.line, self.current.col });
            }
            return error.SyntaxError;
        }
        self.advance();
    }

    fn expect_ident_text(self: *Parser) ![]const u8 {
        return try self.parse_ident_name();
    }

    fn parse_ident_name(self: *Parser) ![]const u8 {
        if (self.current.kind != .ident) return error.SyntaxError;
        const first = self.current.text;
        self.advance();
        if (self.current.kind != .underscore) return first;
        var parts: [8][]const u8 = undefined;
        parts[0] = first;
        var count: u32 = 1;
        while (self.current.kind == .underscore and self.next.kind == .ident) {
            self.advance(); // _
            std.debug.assert(count < parts.len);
            parts[count] = self.current.text;
            count += 1;
            self.advance(); // ident
        }
        if (count == 1) return first;
        var len: usize = count - 1; // underscores
        var i: u32 = 0;
        while (i < count) : (i += 1) len += parts[i].len;
        const result = try self.arena.alloc(u8, len);
        var pos: usize = 0;
        i = 0;
        while (i < count) : (i += 1) {
            if (i > 0) {
                result[pos] = '_';
                pos += 1;
            }
            @memcpy(result[pos .. pos + parts[i].len], parts[i]);
            pos += parts[i].len;
        }
        return result;
    }

    fn expr_bool(self: *Parser, b: bool) !*ast.Expr {
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .bool_literal = b };
        return ptr;
    }

    fn expr_int(self: *Parser, i: i64) !*ast.Expr {
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .int_literal = i };
        return ptr;
    }

    fn expr_string(self: *Parser, s: []const u8) !*ast.Expr {
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .string_literal = try self.dup(s) };
        return ptr;
    }

    fn expr_ident(self: *Parser, name: []const u8) !*ast.Expr {
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .ident = try self.dup(name) };
        return ptr;
    }

    fn expr_primed(self: *Parser, name: []const u8) !*ast.Expr {
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .primed = try self.dup(name) };
        return ptr;
    }

    fn expr_unchanged(self: *Parser, names: []const []const u8) !*ast.Expr {
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .unchanged = names };
        return ptr;
    }

    fn expr_unchanged_expr(self: *Parser, operand: *ast.Expr) !*ast.Expr {
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .unchanged_expr = operand };
        return ptr;
    }

    fn expr_binary(self: *Parser, op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) !*ast.Expr {
        const bptr = try self.arena.alloc_object(ast.Binary);
        bptr.* = ast.Binary{ .op = op, .left = left, .right = right };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .binary = bptr };
        return ptr;
    }

    fn expr_unary(self: *Parser, op: ast.UnaryOp, operand: *ast.Expr) !*ast.Expr {
        const uptr = try self.arena.alloc_object(ast.Unary);
        uptr.* = ast.Unary{ .op = op, .operand = operand };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .unary = uptr };
        return ptr;
    }

    fn expr_set_filter(self: *Parser, vars: []const ast.BoundVar, pred: *ast.Expr) !*ast.Expr {
        const sptr = try self.arena.alloc_object(ast.SetFilter);
        const dup_vars = try self.arena.alloc(ast.BoundVar, vars.len);
        for (vars, 0..) |v, i| dup_vars[i] = .{ .name = try self.dup(v.name), .domain = v.domain };
        sptr.* = ast.SetFilter{ .vars = dup_vars, .pred = pred };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .set_filter = sptr };
        return ptr;
    }

    fn expr_set_map(self: *Parser, vars: []const ast.BoundVar, value: *ast.Expr) !*ast.Expr {
        const sptr = try self.arena.alloc_object(ast.SetMap);
        const dup_vars = try self.arena.alloc(ast.BoundVar, vars.len);
        for (vars, 0..) |v, i| dup_vars[i] = .{ .name = try self.dup(v.name), .domain = v.domain };
        sptr.* = ast.SetMap{ .vars = dup_vars, .value = value };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .set_map = sptr };
        return ptr;
    }

    fn expr_set_enum(self: *Parser, items: []const *ast.Expr) !*ast.Expr {
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .set_enum = items };
        return ptr;
    }

    fn expr_set_binary(self: *Parser, op: ast.SetBinaryOp, left: *ast.Expr, right: *ast.Expr) !*ast.Expr {
        const bptr = try self.arena.alloc_object(ast.SetBinary);
        bptr.* = ast.SetBinary{ .op = op, .left = left, .right = right };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .set_binary = bptr };
        return ptr;
    }

    fn expr_let_in(self: *Parser, defs: []const ast.Definition, body: *ast.Expr) !*ast.Expr {
        const lptr = try self.arena.alloc_object(ast.LetIn);
        lptr.* = ast.LetIn{ .defs = try self.dup_slice(ast.Definition, defs), .body = body };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .let_in = lptr };
        return ptr;
    }

    fn expr_case_expr(self: *Parser, arms: []const ast.CaseArm, otherwise: ?*ast.Expr) !*ast.Expr {
        const cptr = try self.arena.alloc_object(ast.CaseExpr);
        cptr.* = ast.CaseExpr{ .arms = try self.dup_slice(ast.CaseArm, arms), .otherwise = otherwise };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .case_expr = cptr };
        return ptr;
    }

    fn expr_box_action(self: *Parser, action: *ast.Expr, vars: *ast.Expr) !*ast.Expr {
        const bptr = try self.arena.alloc_object(ast.BoxAction);
        bptr.* = ast.BoxAction{ .action = action, .vars = vars };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .box_action = bptr };
        return ptr;
    }

    fn expr_except(self: *Parser, func: *ast.Expr, steps: []const ast.AccessStep, value: *ast.Expr) !*ast.Expr {
        const eptr = try self.arena.alloc_object(ast.Except);
        eptr.* = ast.Except{ .func = func, .steps = steps, .value = value };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .except = eptr };
        return ptr;
    }

    fn expr_set_of_functions(self: *Parser, domain: *ast.Expr, codomain: *ast.Expr) !*ast.Expr {
        const sptr = try self.arena.alloc_object(ast.SetOfFunctions);
        sptr.* = ast.SetOfFunctions{ .domain = domain, .codomain = codomain };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .set_of_functions = sptr };
        return ptr;
    }

    fn expr_record_set(self: *Parser, fields: []const ast.RecordFieldDomain) !*ast.Expr {
        const rptr = try self.arena.alloc_object(ast.RecordSet);
        rptr.* = ast.RecordSet{ .fields = fields };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .record_set = rptr };
        return ptr;
    }

    fn expr_function_literal(self: *Parser, vars: []const ast.BoundVar, body: *ast.Expr) !*ast.Expr {
        const fptr = try self.arena.alloc_object(ast.FunctionLiteral);
        const vars_copy = try self.dup_slice(ast.BoundVar, vars);
        fptr.* = ast.FunctionLiteral{ .vars = vars_copy, .body = body };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .function_literal = fptr };
        return ptr;
    }

    fn expr_at(self: *Parser) !*ast.Expr {
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .at = {} };
        return ptr;
    }

    fn expr_apply(self: *Parser, func: *ast.Expr, args: []const *ast.Expr) !*ast.Expr {
        const aptr = try self.arena.alloc_object(ast.Apply);
        aptr.* = ast.Apply{ .func = func, .args = args };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .apply = aptr };
        return ptr;
    }

    fn expr_field(self: *Parser, expr: *ast.Expr, name: []const u8) !*ast.Expr {
        const fptr = try self.arena.alloc_object(ast.Field);
        fptr.* = ast.Field{ .expr = expr, .name = try self.dup(name) };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .field = fptr };
        return ptr;
    }

    fn expr_tuple(self: *Parser, items: []const *ast.Expr) !*ast.Expr {
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .tuple = items };
        return ptr;
    }

    fn expr_record(self: *Parser, fields: []const ast.FieldInit) !*ast.Expr {
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .record = fields };
        return ptr;
    }

    fn expr_choose(self: *Parser, var_name: []const u8, domain: ?*ast.Expr, body: *ast.Expr) !*ast.Expr {
        const cptr = try self.arena.alloc_object(ast.Choose);
        cptr.* = ast.Choose{ .var_name = try self.dup(var_name), .domain = domain, .body = body };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .choose = cptr };
        return ptr;
    }

    fn expr_if(self: *Parser, cond: *ast.Expr, then_branch: *ast.Expr, else_branch: *ast.Expr) !*ast.Expr {
        const iptr = try self.arena.alloc_object(ast.IfThenElse);
        iptr.* = ast.IfThenElse{ .cond = cond, .then_branch = then_branch, .else_branch = else_branch };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .if_then_else = iptr };
        return ptr;
    }

    fn expr_quantifier(self: *Parser, kind: ast.QuantifierKind, vars: []const ast.BoundVar, body: *ast.Expr) !*ast.Expr {
        const qptr = try self.arena.alloc_object(ast.Quantifier);
        const vars_copy = try self.dup_slice(ast.BoundVar, vars);
        qptr.* = ast.Quantifier{ .kind = kind, .vars = vars_copy, .body = body };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .quantifier = qptr };
        return ptr;
    }

    fn dup(self: *Parser, s: []const u8) ![]const u8 {
        const copy = try self.arena.alloc(u8, s.len);
        @memcpy(copy, s);
        return copy;
    }

    fn arena_concat_three(self: *Parser, a: []const u8, sep: []const u8, b: []const u8) ![]const u8 {
        const total = a.len + sep.len + b.len;
        const result = try self.arena.alloc(u8, total);
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len .. a.len + sep.len], sep);
        @memcpy(result[a.len + sep.len ..], b);
        return result;
    }

    fn dup_slice(self: *Parser, comptime T: type, items: []const T) ![]const T {
        if (items.len == 0) return &[0]T{};
        const copy = try self.arena.alloc(T, items.len);
        @memcpy(copy, items);
        return copy;
    }

    fn skip_to_next_definition(self: *Parser) void {
        self.advance(); // skip the definition name that failed
        while (self.current.kind != .eof) {
            // Stop at the module terminator ====.
            if (self.current.kind == .defeq and self.next.kind == .defeq) return;
            switch (self.current.kind) {
                .ident => if (self.current.col == 1) return,
                .keyword_variables, .keyword_constants, .keyword_theorem => return,
                .keyword_module => return,
                .keyword_instance => return,
                .lbracket, .langle => {
                    self.advance();
                    continue;
                },
                else => {},
            }
            self.advance();
        }
    }
};
