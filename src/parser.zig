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
        lparen,
        rparen,
        lbrace,
        rbrace,
        lbracket,
        rbracket,
        langle,
        rangle,
        comma,
        colon,
        semi,
        dot,
        arrow,
        mapsto,
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
        plus,
        minus,
        star,
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
                self.advance();
                return self.mk(.eq, "=", start_line, start_col);
            },
            '#' => {
                self.advance();
                return self.mk(.neq, "#", start_line, start_col);
            },
            '<' => {
                if (self.peek(1) == '=') {
                    self.advance2();
                    return self.mk(.le, "<=", start_line, start_col);
                }
                if (self.peek(1) == '>') {
                    self.advance();
                    self.advance();
                    self.advance();
                    return self.mk(.equiv, "<=>", start_line, start_col);
                }
                if (self.peek(1) == '<') {
                    self.advance2();
                    return self.mk(.langle, "<<", start_line, start_col);
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
                return self.mk(.not, "~", start_line, start_col);
            },
            '%' => {
                self.advance();
                return self.mk(.percent, "%", start_line, start_col);
            },
            '"' => return self.read_string(start_line, start_col),
            '0'...'9' => return self.read_number(start_line, start_col),
            'A'...'Z', 'a'...'z', '_' => return self.read_ident_or_keyword(start_line, start_col),
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
        return .{ .kind = switch_word(word), .text = text, .line = start_line, .col = start_col };
    }

    fn read_ident_or_keyword(self: *Lexer, start_line: u32, start_col: u32) Token {
        const start = self.pos;
        while (self.pos < self.source.len and self.is_ident_char(self.source[self.pos])) {
            self.advance();
        }
        const word = self.source[start..self.pos];
        return .{ .kind = switch_word(word), .text = word, .line = start_line, .col = start_col };
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
        .{ "EXCEPT", .except },
        .{ "in", .in },
        .{ "notin", .notin },
        .{ "subseteq", .subseteq },
        .{ "cup", .cup },
        .{ "union", .cup },
        .{ "cap", .cap },
        .{ "intersect", .cap },
    });
    return map.get(word) orelse .ident;
}

pub const Parser = struct {
    arena: *Arena,
    lexer: Lexer,
    current: Token,
    next: Token,

    pub fn init(arena: *Arena, source: []const u8) Parser {
        var lexer = Lexer.init(source);
        const first = lexer.next();
        const second = lexer.next();
        return Parser{
            .arena = arena,
            .lexer = lexer,
            .current = first,
            .next = second,
        };
    }

    pub fn parse_module(self: *Parser) !ast.Module {
        self.skip_dashes();
        try self.expect(.keyword_module);
        const name = try self.expect_ident_text();
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

        while (true) {
            self.skip_dashes();
            if (self.match(.keyword_variables)) {
                while (true) {
                    try variables.append(std.heap.page_allocator, try self.dup(try self.expect_ident_text()));
                    if (!self.match(.comma)) break;
                }
            } else if (self.match(.keyword_constants)) {
                while (true) {
                    try constants.append(std.heap.page_allocator, try self.dup(try self.expect_ident_text()));
                    if (!self.match(.comma)) break;
                }
            } else if (self.current.kind == .keyword_assume) {
                self.advance();
                if (self.current.kind == .ident and self.next.kind == .defeq) {
                    self.advance();
                    self.advance();
                }
                _ = try self.parse_expr();
                if (self.current.kind == .semi) self.advance();
            } else {
                break;
            }
        }

        var definitions = std.ArrayList(ast.Definition).empty;
        defer definitions.deinit(std.heap.page_allocator);
        while (true) {
            self.skip_dashes();
            if (self.current.kind != .ident) break;
            const saved = self.*;
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

        return ast.Module{
            .name = try self.dup(name),
            .extends = try self.dup_slice([]const u8, extends.items),
            .variables = try self.dup_slice([]const u8, variables.items),
            .constants = try self.dup_slice([]const u8, constants.items),
            .definitions = try self.dup_slice(ast.Definition, definitions.items),
            .init_name = init_name,
            .next_name = next_name,
            .invariants = try self.dup_slice([]const u8, invariants.items),
        };
    }

    fn parse_definition(self: *Parser) !ast.Definition {
        const name = try self.expect_ident_text();
        var params = std.ArrayList([]const u8).empty;
        defer params.deinit(std.heap.page_allocator);
        if (self.match(.lparen)) {
            if (self.current.kind != .rparen) {
                while (true) {
                    try params.append(std.heap.page_allocator, try self.dup(try self.expect_ident_text()));
                    if (!self.match(.comma)) break;
                }
            }
            try self.expect(.rparen);
        }
        try self.expect(.defeq);
        const body = try self.parse_expr();
        return ast.Definition{
            .name = try self.dup(name),
            .params = try self.dup_slice([]const u8, params.items),
            .body = body,
        };
    }

    fn parse_expr(self: *Parser) anyerror!*ast.Expr {
        if (self.match(.and_op)) return try self.parse_and();
        if (self.match(.or_op)) return try self.parse_or();
        return try self.parse_implies();
    }

    fn parse_implies(self: *Parser) !*ast.Expr {
        var left = try self.parse_equiv();
        while (self.match(.implies)) {
            const right = try self.parse_equiv();
            left = try self.expr_binary(.implies, left, right);
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
        while (self.match(.or_op)) {
            const right = try self.parse_and();
            left = try self.expr_binary(.or_op, left, right);
        }
        return left;
    }

    fn parse_and(self: *Parser) !*ast.Expr {
        var left = try self.parse_not();
        while (self.match(.and_op)) {
            const right = try self.parse_not();
            left = try self.expr_binary(.and_op, left, right);
        }
        return left;
    }

    fn parse_not(self: *Parser) !*ast.Expr {
        if (self.match(.not)) {
            const operand = try self.parse_not();
            return try self.expr_unary(.not, operand);
        }
        return try self.parse_comparison();
    }

    fn parse_comparison(self: *Parser) !*ast.Expr {
        const left = try self.parse_union();
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
            const right = try self.parse_union();
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

    fn parse_additive(self: *Parser) !*ast.Expr {
        var left = try self.parse_multiplicative();
        while (true) {
            const op: ?ast.BinaryOp = if (self.match(.plus)) .plus else if (self.match(.minus)) .minus else null;
            if (op) |o| {
                const right = try self.parse_multiplicative();
                left = try self.expr_binary(o, left, right);
            } else break;
        }
        return left;
    }

    fn parse_multiplicative(self: *Parser) !*ast.Expr {
        var left = try self.parse_unary();
        while (true) {
            const op: ?ast.BinaryOp = if (self.match(.star)) .times else if (self.match(.slash)) .div else if (self.match(.percent)) .mod else null;
            if (op) |o| {
                const right = try self.parse_unary();
                left = try self.expr_binary(o, left, right);
            } else break;
        }
        return left;
    }

    fn parse_unary(self: *Parser) !*ast.Expr {
        if (self.match(.minus)) return try self.expr_unary(.neg, try self.parse_unary());
        if (self.match(.keyword_subset)) return try self.expr_unary(.subset, try self.parse_unary());
        if (self.match(.keyword_union)) return try self.expr_unary(.union_all, try self.parse_unary());
        if (self.match(.keyword_domain)) return try self.expr_unary(.domain, try self.parse_unary());
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
                const name = self.current.text;
                self.advance();
                if (self.match(.bang)) {
                    const field = try self.expect_ident_text();
                    return try self.expr_field(try self.expr_ident(name), field);
                }
                if (self.match(.prime)) {
                    return try self.expr_primed(name);
                }
                if (self.match(.lparen)) {
                    const args = try self.parse_expr_list(.rparen);
                    return try self.expr_apply(try self.expr_ident(name), args);
                }
                if (self.match(.lbracket)) {
                    const args = try self.parse_expr_list(.rbracket);
                    return try self.expr_apply(try self.expr_ident(name), args);
                }
                return try self.expr_ident(name);
            },
            .lparen => {
                self.advance();
                const e = try self.parse_expr();
                try self.expect(.rparen);
                return e;
            },
            .lbrace => return try self.parse_set(),
            .lbracket => return try self.parse_function_or_record(),
            .at => {
                self.advance();
                return try self.expr_at();
            },
            .langle => return try self.parse_tuple(),
            .keyword_choose => return try self.parse_choose(),
            .keyword_if => return try self.parse_if(),
            .keyword_forall => return try self.parse_quantifier(.forall),
            .keyword_exists => return try self.parse_quantifier(.exists),
            .keyword_unchanged => return try self.parse_unchanged(),
            else => return error.SyntaxError,
        }
    }

    fn parse_set(self: *Parser) !*ast.Expr {
        try self.expect(.lbrace);
        if (self.current.kind == .ident and self.next.kind == .in) {
            const var_name = try self.expect_ident_text();
            try self.expect(.in);
            const domain = try self.parse_expr();
            try self.expect(.colon);
            const pred = try self.parse_expr();
            try self.expect(.rbrace);
            return try self.expr_set_filter(var_name, domain, pred);
        }
        const items = try self.parse_expr_list(.rbrace);
        return try self.expr_set_enum(items);
    }

    fn parse_function_or_record(self: *Parser) !*ast.Expr {
        try self.expect(.lbracket);
        if (self.current.kind == .ident and self.next.kind == .mapsto) {
            const fields = try self.parse_record_fields();
            try self.expect(.rbracket);
            return try self.expr_record(fields);
        }
        if (self.current.kind == .ident and self.next.kind == .in) {
            const var_name = try self.expect_ident_text();
            try self.expect(.in);
            const domain = try self.parse_expr();
            try self.expect(.mapsto);
            const body = try self.parse_expr();
            try self.expect(.rbracket);
            return try self.expr_function_literal(var_name, domain, body);
        }
        const func = try self.parse_expr();
        if (self.match(.arrow)) {
            const codomain = try self.parse_expr();
            try self.expect(.rbracket);
            return try self.expr_set_of_functions(func, codomain);
        }
        if (self.match(.except)) {
            const steps = try self.parse_except_steps();
            try self.expect(.eq);
            const value = try self.parse_expr();
            try self.expect(.rbracket);
            return try self.expr_except(func, steps, value);
        }
        try self.expect(.rbracket);
        return func;
    }

    fn parse_except_steps(self: *Parser) ![]const ast.AccessStep {
        var steps = std.ArrayList(ast.AccessStep).empty;
        defer steps.deinit(std.heap.page_allocator);
        while (true) {
            try self.expect(.bang);
            if (self.match(.dot)) {
                const field = try self.expect_ident_text();
                try steps.append(std.heap.page_allocator, ast.AccessStep{ .field = try self.dup(field) });
            } else if (self.match(.lbracket)) {
                const idx = try self.parse_expr();
                try self.expect(.rbracket);
                try steps.append(std.heap.page_allocator, ast.AccessStep{ .index = idx });
            } else {
                return error.SyntaxError;
            }
            if (!self.match(.comma)) break;
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

    fn parse_tuple(self: *Parser) !*ast.Expr {
        try self.expect(.langle);
        const items = try self.parse_expr_list(.rangle);
        return try self.expr_tuple(items);
    }

    fn parse_choose(self: *Parser) !*ast.Expr {
        try self.expect(.keyword_choose);
        const var_name = try self.expect_ident_text();
        try self.expect(.in);
        const domain = try self.parse_expr();
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
        while (true) {
            const name = try self.expect_ident_text();
            try self.expect(.in);
            const domain = try self.parse_expr();
            try vars.append(std.heap.page_allocator, .{ .name = try self.dup(name), .domain = domain });
            if (!self.match(.comma)) break;
        }
        try self.expect(.colon);
        const body = try self.parse_expr();
        return try self.expr_quantifier(kind, vars.items, body);
    }

    fn parse_unchanged(self: *Parser) !*ast.Expr {
        try self.expect(.keyword_unchanged);
        if (self.match(.langle)) {
            var vars = std.ArrayList([]const u8).empty;
            defer vars.deinit(std.heap.page_allocator);
            while (true) {
                const name = try self.expect_ident_text();
                try vars.append(std.heap.page_allocator, try self.dup(name));
                if (!self.match(.comma)) break;
            }
            try self.expect(.rangle);
            return try self.expr_unchanged(try self.dup_slice([]const u8, vars.items));
        }
        const name = try self.expect_ident_text();
        const arr = try self.arena.alloc([]const u8, 1);
        arr[0] = try self.dup(name);
        return try self.expr_unchanged(arr);
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
        while (self.current.kind == .minus) {
            self.advance();
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
        if (self.current.kind != kind) return error.SyntaxError;
        self.advance();
    }

    fn expect_ident_text(self: *Parser) ![]const u8 {
        if (self.current.kind != .ident) return error.SyntaxError;
        const text = self.current.text;
        self.advance();
        return text;
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

    fn expr_set_filter(self: *Parser, var_name: []const u8, domain: *ast.Expr, pred: *ast.Expr) !*ast.Expr {
        const sptr = try self.arena.alloc_object(ast.SetFilter);
        sptr.* = ast.SetFilter{ .var_name = try self.dup(var_name), .domain = domain, .pred = pred };
        const ptr = try self.arena.alloc_object(ast.Expr);
        ptr.* = ast.Expr{ .set_filter = sptr };
        return ptr;
    }

    fn expr_set_map(self: *Parser, var_name: []const u8, domain: *ast.Expr, value: *ast.Expr) !*ast.Expr {
        const sptr = try self.arena.alloc_object(ast.SetMap);
        sptr.* = ast.SetMap{ .var_name = try self.dup(var_name), .domain = domain, .value = value };
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

    fn expr_function_literal(self: *Parser, var_name: []const u8, domain: *ast.Expr, body: *ast.Expr) !*ast.Expr {
        const fptr = try self.arena.alloc_object(ast.FunctionLiteral);
        fptr.* = ast.FunctionLiteral{ .var_name = try self.dup(var_name), .domain = domain, .body = body };
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

    fn expr_choose(self: *Parser, var_name: []const u8, domain: *ast.Expr, body: *ast.Expr) !*ast.Expr {
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

    fn dup_slice(self: *Parser, comptime T: type, items: []const T) ![]const T {
        if (items.len == 0) return &[0]T{};
        const copy = try self.arena.alloc(T, items.len);
        @memcpy(copy, items);
        return copy;
    }

    fn skip_to_next_definition(self: *Parser) void {
        self.advance(); // skip the definition name that failed
        while (self.current.kind != .eof) {
            if (self.current.kind == .ident and self.current.col == 1) return;
            if (self.current.kind == .keyword_theorem) return;
            if (self.current.kind == .keyword_module) return;
            self.advance();
        }
    }
};
