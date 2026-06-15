const std = @import("std");
const Arena = @import("arena.zig").Arena;
const ast = @import("ast.zig");
const value = @import("value.zig");
const Value = value.Value;
const ValuePool = value.ValuePool;
const Function = value.Function;
const Set = value.Set;
const state = @import("state.zig");
const StateStore = state.StateStore;
const Error = @import("err.zig").Error;
const ModelTable = value.ModelTable;
const overrides = @import("overrides.zig");

pub const Constant = struct {
    name: []const u8,
    value: Value,
};

pub const Context = struct {
    names: [32][]const u8,
    values: [32]Value,
    len: u32,

    pub fn empty() Context {
        return Context{ .names = undefined, .values = undefined, .len = 0 };
    }

    pub fn lookup(self: Context, name: []const u8) ?Value {
        var i: u32 = self.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.names[i], name)) return self.values[i];
        }
        return null;
    }

    pub fn extend(self: Context, name: []const u8, val: Value) Context {
        var copy = self;
        std.debug.assert(copy.len < 32);
        copy.names[copy.len] = name;
        copy.values[copy.len] = val;
        copy.len += 1;
        return copy;
    }
};

pub const Alias = struct {
    from: []const u8,
    to: []const u8,
};

pub const EvalLambda = struct {
    params: []const []const u8,
    body: *ast.Expr,
    ctx: Context,
};

pub const Evaluator = struct {
    module: ast.Module,
    constants: []const Constant,
    aliases: []const Alias,
    models: *ModelTable,
    override_registry: overrides.Registry,
    treat_unknown_as_model: bool,

    pub fn init(module: ast.Module, arena: *Arena) !Evaluator {
        const models = try arena.alloc_object(ModelTable);
        models.* = try ModelTable.init(arena, 1024);
        return Evaluator{
            .module = module,
            .constants = &[_]Constant{},
            .aliases = &[_]Alias{},
            .models = models,
            .override_registry = overrides.default_registry(),
            .treat_unknown_as_model = false,
        };
    }

    pub fn set_treat_unknown_as_model(self: *Evaluator, enable: bool) void {
        self.treat_unknown_as_model = enable;
    }

    pub fn set_constants(self: *Evaluator, constants: []const Constant) void {
        self.constants = constants;
    }

    pub fn set_aliases(self: *Evaluator, aliases: []const Alias) void {
        self.aliases = aliases;
    }

    fn resolve_alias(self: Evaluator, name: []const u8) []const u8 {
        for (self.aliases) |a| {
            if (std.mem.eql(u8, name, a.from)) return a.to;
        }
        return name;
    }

    pub fn find_constant(self: Evaluator, name: []const u8) ?Value {
        for (self.constants) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.value;
        }
        return null;
    }

    pub fn eval_expr(
        self: Evaluator,
        expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        switch (expr.*) {
            .bool_literal => |b| return Value{ .bool_v = b },
            .int_literal => |i| return Value{ .int_v = i },
            .string_literal => |s| return Value{ .string_v = try eval_pool.push_string(s) },
            .ident => |name| {
                if (s0) |st| {
                    if (self.find_variable(name)) |idx| {
                        return try st.values[idx].clone(state_pool, eval_pool);
                    }
                }
                if (ctx.lookup(name)) |v| return v;
                if (self.find_constant(name)) |v| return try v.clone(state_pool, eval_pool);
                const aliased = self.resolve_alias(name);
                if (self.override_registry.find_value(aliased)) |func| {
                    return try func(eval_pool);
                }
                if (self.find_definition(aliased)) |def| {
                    if (def.params.len != 0) return Error.TypeError;
                    return try self.eval_expr(def.body, ctx, s0, eval_pool, state_pool);
                }
                if (self.treat_unknown_as_model) {
                    const id = try self.models.intern(name);
                    return Value{ .model_v = id };
                }
                return Error.UndefinedSymbol;
            },
            .primed => |name| {
                if (ctx.lookup(name)) |v| return v;
                return Error.UndefinedSymbol;
            },
            .binary => |b| return try self.eval_binary(b, ctx, s0, eval_pool, state_pool),
            .unary => |u| return try self.eval_unary(u, ctx, s0, eval_pool, state_pool),
            .if_then_else => |ite| {
                const c = try self.eval_expr(ite.cond, ctx, s0, eval_pool, state_pool);
                if (c.as_bool() orelse return Error.TypeError) {
                    return try self.eval_expr(ite.then_branch, ctx, s0, eval_pool, state_pool);
                }
                return try self.eval_expr(ite.else_branch, ctx, s0, eval_pool, state_pool);
            },
            .set_enum => |items| {
                const dest = try eval_pool.alloc_values(@intCast(items.len));
                for (items, 0..) |it, i| {
                    dest[i] = try self.eval_expr(it, ctx, s0, eval_pool, state_pool);
                }
                return Value{ .set_v = make_set(eval_pool, dest) };
            },
            .set_filter => |sf| return try self.eval_set_filter(sf, ctx, s0, eval_pool, state_pool),
            .set_map => |sm| return try self.eval_set_map(sm, ctx, s0, eval_pool, state_pool),
            .set_binary => |sb| return try self.eval_set_binary(sb, ctx, s0, eval_pool, state_pool),
            .set_of_functions => |sf| return try self.eval_set_of_functions(sf, ctx, s0, eval_pool, state_pool),
            .record_set => |rs| return try self.eval_record_set(rs, ctx, s0, eval_pool, state_pool),
            .function_literal => |fl| return try self.eval_function_literal(fl, ctx, s0, eval_pool, state_pool),
            .apply => |ap| return try self.eval_apply(ap, ctx, s0, eval_pool, state_pool),
            .field => |f| return try self.eval_field(f, ctx, s0, eval_pool, state_pool),
            .tuple => |t| {
                const dest = try eval_pool.alloc_values(@intCast(t.len));
                for (t, 0..) |it, i| {
                    dest[i] = try self.eval_expr(it, ctx, s0, eval_pool, state_pool);
                }
                return Value{ .tuple_v = make_tuple(eval_pool, dest) };
            },
            .record => |r| {
                const dest = try eval_pool.alloc_values(@intCast(r.len * 2));
                for (r, 0..) |field, i| {
                    dest[i * 2] = Value{ .string_v = try eval_pool.push_string(field.name) };
                    dest[i * 2 + 1] = try self.eval_expr(field.value, ctx, s0, eval_pool, state_pool);
                }
                return Value{ .record_v = make_record(eval_pool, dest) };
            },
            .quantifier => |q| return try self.eval_quantifier(q, ctx, s0, eval_pool, state_pool),
            .choose => |c| return try self.eval_choose(c, ctx, s0, eval_pool, state_pool),
            .unchanged => return Value{ .bool_v = true },
            .except => |e| return try self.eval_except(e, ctx, s0, eval_pool, state_pool),
            .let_in => |l| return try self.eval_let_in(l, ctx, s0, eval_pool, state_pool),
            .case_expr => |c| return try self.eval_case_expr(c, ctx, s0, eval_pool, state_pool),
            .box_action => return Value{ .bool_v = true },
            .lambda => |l| {
                const lam = try eval_pool.arena.alloc_object(value.Lambda);
                const ctx_ptr = try eval_pool.arena.alloc_object(Context);
                ctx_ptr.* = ctx;
                const params_copy = try eval_pool.arena.alloc([]const u8, l.params.len);
                for (l.params, 0..) |p, i| params_copy[i] = p;
                lam.* = value.Lambda{
                    .params = params_copy,
                    .body = @ptrCast(l.body),
                    .ctx = @ptrCast(ctx_ptr),
                };
                return Value{ .lambda_v = lam };
            },
            .at => return ctx.lookup("@") orelse Error.SyntaxError,
        }
    }

    fn eval_binary(
        self: Evaluator,
        b: *ast.Binary,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const left = try self.eval_expr(b.left, ctx, s0, eval_pool, state_pool);
        switch (b.op) {
            .and_op => {
                if (!left.is_truthy()) return Value{ .bool_v = false };
                const right = try self.eval_expr(b.right, ctx, s0, eval_pool, state_pool);
                return Value{ .bool_v = right.is_truthy() };
            },
            .or_op => {
                if (left.is_truthy()) return Value{ .bool_v = true };
                const right = try self.eval_expr(b.right, ctx, s0, eval_pool, state_pool);
                return Value{ .bool_v = right.is_truthy() };
            },
            .implies => {
                if (!left.is_truthy()) return Value{ .bool_v = true };
                const right = try self.eval_expr(b.right, ctx, s0, eval_pool, state_pool);
                return Value{ .bool_v = right.is_truthy() };
            },
            .equiv => {
                const right = try self.eval_expr(b.right, ctx, s0, eval_pool, state_pool);
                return Value{ .bool_v = left.is_truthy() == right.is_truthy() };
            },
            .in => {
                if (b.right.* == .set_of_functions) {
                    if (left != .function_v) {
                        std.debug.print("function set membership left not function: {s}\n", .{@tagName(left)});
                        return Value{ .bool_v = false };
                    }
                    const fs = b.right.*.set_of_functions;
                    const domain = try self.eval_expr(fs.domain, ctx, s0, eval_pool, state_pool);
                    const codomain = try self.eval_expr(fs.codomain, ctx, s0, eval_pool, state_pool);
                    if (domain != .set_v or codomain != .set_v) return Error.TypeError;
                    return Value{ .bool_v = try self.is_function_in_set(left.function_v, domain.set_v, codomain.set_v, eval_pool) };
                }
                // Optimize `x \in a..b` without materializing the range set.
                if (b.right.* == .binary and b.right.*.binary.op == .range) {
                    const range = b.right.*.binary;
                    const lo = try self.eval_expr(range.left, ctx, s0, eval_pool, state_pool);
                    const hi = try self.eval_expr(range.right, ctx, s0, eval_pool, state_pool);
                    if (left != .int_v or lo != .int_v or hi != .int_v) return Error.TypeError;
                    return Value{ .bool_v = left.int_v >= lo.int_v and left.int_v <= hi.int_v };
                }
                const right = try self.eval_expr(b.right, ctx, s0, eval_pool, state_pool);
                if (right != .set_v) return Error.TypeError;
                return Value{ .bool_v = right.set_v.contains(eval_pool, left) };
            },
            .notin => {
                const right = try self.eval_expr(b.right, ctx, s0, eval_pool, state_pool);
                if (right != .set_v) return Error.TypeError;
                return Value{ .bool_v = !right.set_v.contains(eval_pool, left) };
            },
            else => {},
        }
        const right = try self.eval_expr(b.right, ctx, s0, eval_pool, state_pool);
        return switch (b.op) {
            .eq => Value{ .bool_v = left.eql(right, eval_pool) },
            .ne => Value{ .bool_v = !left.eql(right, eval_pool) },
            .lt => Value{ .bool_v = (left.as_int() orelse return Error.TypeError) < (right.as_int() orelse return Error.TypeError) },
            .le => Value{ .bool_v = (left.as_int() orelse return Error.TypeError) <= (right.as_int() orelse return Error.TypeError) },
            .gt => Value{ .bool_v = (left.as_int() orelse return Error.TypeError) > (right.as_int() orelse return Error.TypeError) },
            .ge => Value{ .bool_v = (left.as_int() orelse return Error.TypeError) >= (right.as_int() orelse return Error.TypeError) },
            .subseteq => {
                if (left != .set_v or right != .set_v) return Error.TypeError;
                return Value{ .bool_v = left.set_v.is_subset(eval_pool, right.set_v) };
            },
            .plus => Value{ .int_v = (left.as_int() orelse return Error.TypeError) + (right.as_int() orelse return Error.TypeError) },
            .minus => Value{ .int_v = (left.as_int() orelse return Error.TypeError) - (right.as_int() orelse return Error.TypeError) },
            .times => Value{ .int_v = (left.as_int() orelse return Error.TypeError) * (right.as_int() orelse return Error.TypeError) },
            .div => {
                const denom = right.as_int() orelse return Error.TypeError;
                if (denom == 0) return Error.DivisionByZero;
                return Value{ .int_v = @divTrunc(left.as_int() orelse return Error.TypeError, denom) };
            },
            .mod => {
                const denom = right.as_int() orelse return Error.TypeError;
                if (denom == 0) return Error.DivisionByZero;
                return Value{ .int_v = @mod(left.as_int() orelse return Error.TypeError, denom) };
            },
            .power => {
                const base = left.as_int() orelse return Error.TypeError;
                const exp = right.as_int() orelse return Error.TypeError;
                if (exp < 0) return Error.DivisionByZero;
                var result: i64 = 1;
                var i: i64 = 0;
                while (i < exp) : (i += 1) result *= base;
                return Value{ .int_v = result };
            },
            .range => {
                const lo = left.as_int() orelse return Error.TypeError;
                const hi = right.as_int() orelse return Error.TypeError;
                if (lo > hi) return Value{ .set_v = .{ .offset = eval_pool.value_count, .len = 0 } };
                const len: u32 = @intCast(hi - lo + 1);
                const dest = try eval_pool.alloc_values(len);
                for (0..len) |i| {
                    dest[i] = Value{ .int_v = lo + @as(i64, @intCast(i)) };
                }
                return Value{ .set_v = make_set(eval_pool, dest) };
            },
            .concat => return try overrides.sequence_concat(eval_pool, left, right),
            else => Error.NotImplemented,
        };
    }

    fn eval_unary(
        self: Evaluator,
        u: *ast.Unary,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const operand = try self.eval_expr(u.operand, ctx, s0, eval_pool, state_pool);
        return switch (u.op) {
            .not => Value{ .bool_v = !operand.is_truthy() },
            .neg => Value{ .int_v = -(operand.as_int() orelse return Error.TypeError) },
            .subset => try eval_subset(eval_pool, operand),
            .union_all => try eval_union_all(eval_pool, operand),
            .domain => {
                if (operand != .function_v) return Error.TypeError;
                return Value{ .set_v = operand.function_v.domain };
            },
        };
    }

    fn eval_set_filter(
        self: Evaluator,
        sf: *ast.SetFilter,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const domain = try self.eval_expr(sf.domain, ctx, s0, eval_pool, state_pool);
        if (domain != .set_v) return Error.TypeError;
        const items = domain.set_v.items(eval_pool);
        var count: u32 = 0;
        const dest = try eval_pool.alloc_values(@intCast(items.len));
        for (items) |it| {
            const new_ctx = ctx.extend(sf.var_name, it);
            const pred = try self.eval_expr(sf.pred, new_ctx, s0, eval_pool, state_pool);
            if (pred.is_truthy()) {
                dest[count] = it;
                count += 1;
            }
        }
        return Value{ .set_v = make_set(eval_pool, dest[0..count]) };
    }

    fn eval_set_map(
        self: Evaluator,
        sm: *ast.SetMap,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const domain = try self.eval_expr(sm.domain, ctx, s0, eval_pool, state_pool);
        if (domain != .set_v) return Error.TypeError;
        const items = domain.set_v.items(eval_pool);
        const dest = try eval_pool.alloc_values(@intCast(items.len));
        for (items, 0..) |it, i| {
            const new_ctx = ctx.extend(sm.var_name, it);
            dest[i] = try self.eval_expr(sm.value, new_ctx, s0, eval_pool, state_pool);
        }
        return Value{ .set_v = make_set(eval_pool, dest) };
    }

    fn eval_record_set(
        self: Evaluator,
        rs: *ast.RecordSet,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (rs.fields.len == 0) {
            const empty = try eval_pool.alloc_values(0);
            return Value{ .set_v = make_set(eval_pool, empty) };
        }
        var domains = std.ArrayList(Value).empty;
        defer domains.deinit(std.heap.page_allocator);
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(std.heap.page_allocator);
        for (rs.fields) |f| {
            const d = try self.eval_expr(f.domain, ctx, s0, eval_pool, state_pool);
            if (d != .set_v) return Error.TypeError;
            try domains.append(std.heap.page_allocator, d);
            try names.append(std.heap.page_allocator, f.name);
        }
        var count: u64 = 1;
        for (domains.items) |d| {
            count *= d.set_v.len;
            if (count > eval_pool.value_cap) return Error.OutOfMemory;
        }
        const dest = try eval_pool.alloc_values(@intCast(count));
        var combo: u64 = 0;
        while (combo < count) : (combo += 1) {
            const fields_dest = try eval_pool.alloc_values(@intCast(rs.fields.len * 2));
            var tmp = combo;
            var i: u32 = 0;
            while (i < rs.fields.len) : (i += 1) {
                const items = domains.items[i].set_v.items(eval_pool);
                const vi: usize = @intCast(tmp % items.len);
                tmp /= items.len;
                fields_dest[i * 2] = Value{ .string_v = try eval_pool.push_string(names.items[i]) };
                fields_dest[i * 2 + 1] = items[vi];
            }
            dest[combo] = Value{ .record_v = make_record(eval_pool, fields_dest) };
        }
        return Value{ .set_v = make_set(eval_pool, dest) };
    }

    fn is_function_in_set(_: Evaluator, func: Function, domain: Set, codomain: Set, eval_pool: *ValuePool) Error!bool {
        if (!func.domain.eql(domain, eval_pool)) return false;
        const keys = func.domain.items(eval_pool);
        for (keys) |k| {
            const v = func.apply(eval_pool, k) orelse return false;
            if (!codomain.contains(eval_pool, v)) return false;
        }
        return true;
    }

    fn eval_set_of_functions(
        self: Evaluator,
        sf: *ast.SetOfFunctions,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const domain = try self.eval_expr(sf.domain, ctx, s0, eval_pool, state_pool);
        const codomain = try self.eval_expr(sf.codomain, ctx, s0, eval_pool, state_pool);
        if (domain != .set_v or codomain != .set_v) return Error.TypeError;
        const keys = domain.set_v.items(eval_pool);
        const values = codomain.set_v.items(eval_pool);
        const n: u32 = @intCast(keys.len);
        const m: u32 = @intCast(values.len);
        if (n == 0) {
            const empty = try eval_pool.alloc_values(0);
            const func = Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, empty.ptr),
                .len = 0,
            } };
            const dest = try eval_pool.alloc_values(1);
            dest[0] = func;
            return Value{ .set_v = make_set(eval_pool, dest) };
        }
        var count: u64 = 1;
        for (0..n) |_| {
            count *= m;
            if (count > eval_pool.value_cap) return Error.OutOfMemory;
        }
        const func_values = try eval_pool.alloc_values(@intCast(count));
        var combo: u64 = 0;
        while (combo < count) : (combo += 1) {
            const entries = try eval_pool.alloc_values(n);
            var tmp = combo;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const vi: usize = @intCast(tmp % m);
                tmp /= m;
                entries[i] = values[vi];
            }
            func_values[combo] = Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, entries.ptr),
                .len = n,
            } };
        }
        return Value{ .set_v = make_set(eval_pool, func_values) };
    }

    fn eval_set_binary(
        self: Evaluator,
        sb: *ast.SetBinary,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const left = try self.eval_expr(sb.left, ctx, s0, eval_pool, state_pool);
        const right = try self.eval_expr(sb.right, ctx, s0, eval_pool, state_pool);
        if (left != .set_v or right != .set_v) return Error.TypeError;
        const a = left.set_v.items(eval_pool);
        const b = right.set_v.items(eval_pool);
        return switch (sb.op) {
            .cartesian_op => {
                const product = try self.cartesian_product(eval_pool, &[_]Value{ left, right });
                return Value{ .set_v = make_set(eval_pool, product) };
            },
            .union_op => {
                const dest = try eval_pool.alloc_values(@intCast(a.len + b.len));
                @memcpy(dest[0..a.len], a);
                var count: u32 = @intCast(a.len);
                for (b) |bv| {
                    if (!left.set_v.contains(eval_pool, bv)) {
                        dest[count] = bv;
                        count += 1;
                    }
                }
                return Value{ .set_v = make_set(eval_pool, dest[0..count]) };
            },
            .intersection_op => {
                const dest = try eval_pool.alloc_values(@intCast(@min(a.len, b.len)));
                var count: u32 = 0;
                for (a) |av| {
                    if (right.set_v.contains(eval_pool, av)) {
                        dest[count] = av;
                        count += 1;
                    }
                }
                return Value{ .set_v = make_set(eval_pool, dest[0..count]) };
            },
            .difference_op => {
                const dest = try eval_pool.alloc_values(@intCast(a.len));
                var count: u32 = 0;
                for (a) |av| {
                    if (!right.set_v.contains(eval_pool, av)) {
                        dest[count] = av;
                        count += 1;
                    }
                }
                return Value{ .set_v = make_set(eval_pool, dest[0..count]) };
            },
        };
    }

    fn eval_function_literal(
        self: Evaluator,
        fl: *ast.FunctionLiteral,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (fl.vars.len == 0) return Error.TypeError;
        if (fl.vars.len == 1) {
            const domain = try self.eval_expr(fl.vars[0].domain, ctx, s0, eval_pool, state_pool);
            if (domain != .set_v) return Error.TypeError;
            const items = domain.set_v.items(eval_pool);
            const dest = try eval_pool.alloc_values(@intCast(items.len));
            for (items, 0..) |it, i| {
                const new_ctx = ctx.extend(fl.vars[0].name, it);
                dest[i] = try self.eval_expr(fl.body, new_ctx, s0, eval_pool, state_pool);
            }
            return Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, dest.ptr),
                .len = @intCast(items.len),
            } };
        }
        var domains = std.ArrayList(Value).empty;
        defer domains.deinit(std.heap.page_allocator);
        for (fl.vars) |v| {
            const d = try self.eval_expr(v.domain, ctx, s0, eval_pool, state_pool);
            if (d != .set_v) return Error.TypeError;
            try domains.append(std.heap.page_allocator, d);
        }
        const product = try self.cartesian_product(eval_pool, domains.items);
        const dest = try eval_pool.alloc_values(@intCast(product.len));
        for (product, 0..) |tuple, i| {
            var new_ctx = ctx;
            const items = tuple.tuple_v.items(eval_pool);
            for (fl.vars, 0..) |v, j| {
                new_ctx = new_ctx.extend(v.name, items[j]);
            }
            dest[i] = try self.eval_expr(fl.body, new_ctx, s0, eval_pool, state_pool);
        }
        return Value{ .function_v = .{
            .domain = make_set(eval_pool, product),
            .offset = value_offset(eval_pool, dest.ptr),
            .len = @intCast(product.len),
        } };
    }

    fn cartesian_product(self: Evaluator, eval_pool: *ValuePool, sets: []const Value) error{ OutOfMemory, TypeError }![]Value {
        _ = self;
        if (sets.len == 0) {
            const empty = try eval_pool.alloc_values(0);
            const one = try eval_pool.alloc_values(1);
            one[0] = Value{ .tuple_v = make_tuple(eval_pool, empty) };
            return one;
        }
        var count: u64 = 1;
        for (sets) |s| count *= s.set_v.len;
        const dest = try eval_pool.alloc_values(@intCast(count));
        var combo: u64 = 0;
        while (combo < count) : (combo += 1) {
            const tuple_values = try eval_pool.alloc_values(@intCast(sets.len));
            var tmp = combo;
            var i: u32 = 0;
            while (i < sets.len) : (i += 1) {
                const items = sets[i].set_v.items(eval_pool);
                const vi: usize = @intCast(tmp % items.len);
                tmp /= items.len;
                tuple_values[i] = items[vi];
            }
            dest[combo] = Value{ .tuple_v = make_tuple(eval_pool, tuple_values) };
        }
        return dest;
    }

    fn eval_apply(
        self: Evaluator,
        ap: *ast.Apply,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (ap.func.* == .ident) {
            const name = self.resolve_alias(ap.func.*.ident);
            if (self.override_registry.find(name)) |func| {
                const values = try eval_pool.alloc_values(@intCast(ap.args.len));
                for (ap.args, 0..) |arg, i| {
                    values[i] = try self.eval_expr(arg, ctx, s0, eval_pool, state_pool);
                }
                return func(eval_pool, values);
            }
            if (self.find_definition(name)) |def| {
                const values = try eval_pool.alloc_values(@intCast(ap.args.len));
                for (ap.args, 0..) |arg, i| {
                    values[i] = try self.eval_expr(arg, ctx, s0, eval_pool, state_pool);
                }
                if (def.params.len == 0) {
                    const func = try self.eval_expr(def.body, ctx, s0, eval_pool, state_pool);
                    return try self.apply_values(func, values, eval_pool, state_pool, s0);
                }
                if (def.params.len != ap.args.len) return Error.TypeError;
                var new_ctx = Context{ .names = undefined, .values = undefined, .len = 0 };
                for (def.params, 0..) |p, i| {
                    new_ctx = new_ctx.extend(p, values[i]);
                }
                return try self.eval_expr(def.body, new_ctx, s0, eval_pool, state_pool);
            }
        }
        const func = try self.eval_expr(ap.func, ctx, s0, eval_pool, state_pool);
        const values = try eval_pool.alloc_values(@intCast(ap.args.len));
        for (ap.args, 0..) |a, i| {
            values[i] = try self.eval_expr(a, ctx, s0, eval_pool, state_pool);
        }
        return try self.apply_values(func, values, eval_pool, state_pool, s0);
    }

    fn apply_values(self: Evaluator, func: Value, args: []const Value, eval_pool: *ValuePool, state_pool: *ValuePool, s0: ?*StateStore.State) Error!Value {
        if (args.len == 0) return func;
        if (args.len == 1) return try self.apply_value(func, args[0], eval_pool, state_pool, s0);
        const tuple_values = try eval_pool.alloc_values(@intCast(args.len));
        @memcpy(tuple_values, args);
        const arg = Value{ .tuple_v = make_tuple(eval_pool, tuple_values) };
        return try self.apply_value(func, arg, eval_pool, state_pool, s0);
    }

    fn apply_value(self: Evaluator, func: Value, arg: Value, eval_pool: *ValuePool, state_pool: *ValuePool, s0: ?*StateStore.State) Error!Value {
        switch (func) {
            .function_v => |f| return f.apply(eval_pool, arg) orelse Error.UndefinedSymbol,
            .tuple_v => |t| {
                const idx = (arg.as_int() orelse return Error.TypeError) - 1;
                if (idx < 0 or idx >= t.len) return Error.IndexOutOfBounds;
                return t.items(eval_pool)[@intCast(idx)];
            },
            .record_v => |r| {
                const name = arg.string_v.slice(eval_pool);
                return r.lookup(eval_pool, name) orelse Error.UndefinedSymbol;
            },
            .lambda_v => |l| {
                const body: *ast.Expr = @ptrCast(@alignCast(l.body));
                const lambda_ctx: *Context = @ptrCast(@alignCast(l.ctx));
                var new_ctx = lambda_ctx.*;
                if (l.params.len == 1) {
                    new_ctx = new_ctx.extend(l.params[0], arg);
                } else {
                    if (arg != .tuple_v or arg.tuple_v.len != l.params.len) return Error.TypeError;
                    const items = arg.tuple_v.items(eval_pool);
                    for (l.params, 0..) |p, i| {
                        new_ctx = new_ctx.extend(p, items[i]);
                    }
                }
                return try self.eval_expr(body, new_ctx, s0, eval_pool, state_pool);
            },
            else => return Error.TypeError,
        }
    }

    fn eval_field(
        self: Evaluator,
        f: *ast.Field,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const rec = try self.eval_expr(f.expr, ctx, s0, eval_pool, state_pool);
        if (rec != .record_v) return Error.TypeError;
        return rec.record_v.lookup(eval_pool, f.name) orelse Error.UndefinedSymbol;
    }

    fn eval_quantifier(
        self: Evaluator,
        q: *ast.Quantifier,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        return try self.eval_quantifier_vars(q, 0, ctx, s0, eval_pool, state_pool);
    }

    fn eval_quantifier_vars(
        self: Evaluator,
        q: *ast.Quantifier,
        idx: u32,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (idx >= q.vars.len) {
            return try self.eval_expr(q.body, ctx, s0, eval_pool, state_pool);
        }
        const bv = q.vars[idx];
        const domain = try self.eval_expr(bv.domain, ctx, s0, eval_pool, state_pool);
        if (domain != .set_v) return Error.TypeError;
        const items = domain.set_v.items(eval_pool);
        const expected = q.kind == .forall;
        for (items) |it| {
            const new_ctx = ctx.extend(bv.name, it);
            const result = try self.eval_quantifier_vars(q, idx + 1, new_ctx, s0, eval_pool, state_pool);
            if (result.is_truthy() != expected) {
                return Value{ .bool_v = !expected };
            }
        }
        return Value{ .bool_v = expected };
    }

    fn eval_let_in(
        self: Evaluator,
        l: *ast.LetIn,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        var new_ctx = ctx;
        for (l.defs) |def| {
            const v = try self.eval_expr(def.body, new_ctx, s0, eval_pool, state_pool);
            new_ctx = new_ctx.extend(def.name, v);
        }
        return try self.eval_expr(l.body, new_ctx, s0, eval_pool, state_pool);
    }

    fn eval_case_expr(
        self: Evaluator,
        c: *ast.CaseExpr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        for (c.arms) |arm| {
            const cond = try self.eval_expr(arm.cond, ctx, s0, eval_pool, state_pool);
            if (cond.is_truthy()) {
                return try self.eval_expr(arm.value, ctx, s0, eval_pool, state_pool);
            }
        }
        if (c.otherwise) |other| {
            return try self.eval_expr(other, ctx, s0, eval_pool, state_pool);
        }
        return Error.EmptyChoose;
    }

    fn eval_choose(
        self: Evaluator,
        c: *ast.Choose,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (c.domain) |domain_expr| {
            const domain = try self.eval_expr(domain_expr, ctx, s0, eval_pool, state_pool);
            if (domain != .set_v) return Error.TypeError;
            const items = domain.set_v.items(eval_pool);
            var chosen: ?Value = null;
            for (items) |it| {
                const new_ctx = ctx.extend(c.var_name, it);
                const pred = try self.eval_expr(c.body, new_ctx, s0, eval_pool, state_pool);
                if (pred.is_truthy()) {
                    if (chosen == null) {
                        chosen = it;
                    } else if (it.compare(chosen.?, eval_pool)) |cmp| {
                        if (cmp < 0) chosen = it;
                    }
                }
            }
            return chosen orelse Error.EmptyChoose;
        }
        // Domain-free CHOOSE: try fresh model values until the predicate holds.
        var attempt: u32 = 0;
        while (attempt < 1024) : (attempt += 1) {
            const name = try std.fmt.allocPrint(std.heap.page_allocator, "__choose_{d}", .{attempt});
            defer std.heap.page_allocator.free(name);
            const id = try self.models.intern(name);
            const candidate = Value{ .model_v = id };
            const new_ctx = ctx.extend(c.var_name, candidate);
            const pred = try self.eval_expr(c.body, new_ctx, s0, eval_pool, state_pool);
            if (pred.is_truthy()) return candidate;
        }
        return Error.EmptyChoose;
    }

    fn eval_except(
        self: Evaluator,
        e: *ast.Except,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const original = try self.eval_expr(e.func, ctx, s0, eval_pool, state_pool);
        return try self.except_steps(original, e.steps, 0, e.value, ctx, s0, eval_pool, state_pool);
    }

    fn except_steps(
        self: Evaluator,
        original: Value,
        steps: []const ast.AccessStep,
        idx: u32,
        value_expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (idx >= steps.len) {
            return try self.eval_expr(value_expr, ctx, s0, eval_pool, state_pool);
        }
        const step = steps[idx];
        switch (step) {
            .index => |idx_expr| {
                const key = try self.eval_expr(idx_expr, ctx, s0, eval_pool, state_pool);
                const old_value = try self.except_lookup_index(original, key, eval_pool);
                const new_ctx = ctx.extend("@", old_value);
                const new_value = try self.except_steps(old_value, steps, idx + 1, value_expr, new_ctx, s0, eval_pool, state_pool);
                return try self.except_update_index(original, key, new_value, eval_pool);
            },
            .field => |field| {
                const old_value = try self.except_lookup_field(original, field, eval_pool);
                const new_ctx = ctx.extend("@", old_value);
                const new_value = try self.except_steps(old_value, steps, idx + 1, value_expr, new_ctx, s0, eval_pool, state_pool);
                return try self.except_update_field(original, field, new_value, eval_pool);
            },
        }
    }

    fn except_lookup_index(self: Evaluator, original: Value, key: Value, eval_pool: *ValuePool) Error!Value {
        _ = self;
        switch (original) {
            .function_v => |f| return f.apply(eval_pool, key) orelse Error.IndexOutOfBounds,
            .tuple_v => |t| {
                const i = (key.as_int() orelse return Error.TypeError) - 1;
                if (i < 0 or i >= t.len) return Error.IndexOutOfBounds;
                return t.items(eval_pool)[@intCast(i)];
            },
            else => return Error.TypeError,
        }
    }

    fn except_update_index(self: Evaluator, original: Value, key: Value, new_value: Value, eval_pool: *ValuePool) Error!Value {
        _ = self;
        switch (original) {
            .function_v => |f| {
                const entries = f.entries(eval_pool);
                const dest = try eval_pool.alloc_values(@intCast(entries.len));
                const keys = f.domain.items(eval_pool);
                for (entries, 0..) |v, i| {
                    dest[i] = if (keys[i].eql(key, eval_pool)) new_value else v;
                }
                return Value{ .function_v = .{
                    .domain = f.domain,
                    .offset = value_offset(eval_pool, dest.ptr),
                    .len = f.len,
                } };
            },
            .tuple_v => |t| {
                const i = (key.as_int() orelse return Error.TypeError) - 1;
                if (i < 0 or i >= t.len) return Error.IndexOutOfBounds;
                const items = t.items(eval_pool);
                const dest = try eval_pool.alloc_values(@intCast(items.len));
                @memcpy(dest, items);
                dest[@intCast(i)] = new_value;
                return Value{ .tuple_v = make_tuple(eval_pool, dest) };
            },
            else => return Error.TypeError,
        }
    }

    fn except_lookup_field(self: Evaluator, original: Value, field: []const u8, eval_pool: *ValuePool) Error!Value {
        _ = self;
        if (original != .record_v) return Error.TypeError;
        return original.record_v.lookup(eval_pool, field) orelse Error.UndefinedSymbol;
    }

    fn except_update_field(self: Evaluator, original: Value, field: []const u8, new_value: Value, eval_pool: *ValuePool) Error!Value {
        _ = self;
        if (original != .record_v) return Error.TypeError;
        const fs = original.record_v.fields(eval_pool);
        const dest = try eval_pool.alloc_values(@intCast(fs.len));
        @memcpy(dest, fs);
        var i: u32 = 0;
        while (i < original.record_v.len) : (i += 1) {
            const key = fs[i * 2].string_v.slice(eval_pool);
            if (std.mem.eql(u8, key, field)) {
                dest[i * 2 + 1] = new_value;
                break;
            }
        }
        return Value{ .record_v = make_record(eval_pool, dest) };
    }

    pub fn find_variable(self: Evaluator, name: []const u8) ?u32 {
        for (self.module.variables, 0..) |v, i| {
            if (std.mem.eql(u8, v, name)) return @intCast(i);
        }
        return null;
    }

    pub fn find_definition(self: Evaluator, name: []const u8) ?ast.Definition {
        for (self.module.definitions) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }
};

fn eval_union_all(eval_pool: *ValuePool, operand: Value) Error!Value {
    if (operand != .set_v) return Error.TypeError;
    const sets = operand.set_v.items(eval_pool);
    var total: u32 = 0;
    for (sets) |s| {
        if (s != .set_v) return Error.TypeError;
        total += s.set_v.len;
    }
    const dest = try eval_pool.alloc_values(total);
    var pos: u32 = 0;
    for (sets) |s| {
        const items = s.set_v.items(eval_pool);
        for (items) |it| {
            var found = false;
            var j: u32 = 0;
            while (j < pos) : (j += 1) {
                if (dest[j].eql(it, eval_pool)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                dest[pos] = it;
                pos += 1;
            }
        }
    }
    return Value{ .set_v = make_set(eval_pool, dest[0..pos]) };
}

fn eval_subset(eval_pool: *ValuePool, operand: Value) Error!Value {
    if (operand != .set_v) return Error.TypeError;
    const items = operand.set_v.items(eval_pool);
    if (items.len > 20) return Error.NotImplemented;
    const count: u32 = @as(u32, 1) << @intCast(items.len);
    const dest = try eval_pool.alloc_values(count);
    for (0..count) |mask| {
        const subset_len = @popCount(mask);
        const sub = try eval_pool.alloc_values(@intCast(subset_len));
        var j: u32 = 0;
        for (items, 0..) |it, k| {
            if (((mask >> @intCast(k)) & 1) == 1) {
                sub[j] = it;
                j += 1;
            }
        }
        dest[mask] = Value{ .set_v = make_set(eval_pool, sub) };
    }
    return Value{ .set_v = make_set(eval_pool, dest) };
}

fn make_set(eval_pool: *ValuePool, values: []Value) value.Set {
    return .{
        .offset = value_offset(eval_pool, values.ptr),
        .len = @intCast(values.len),
    };
}

fn make_tuple(eval_pool: *ValuePool, values: []Value) value.Tuple {
    return .{
        .offset = value_offset(eval_pool, values.ptr),
        .len = @intCast(values.len),
    };
}

fn make_record(eval_pool: *ValuePool, values: []Value) value.Record {
    return .{
        .offset = value_offset(eval_pool, values.ptr),
        .len = @intCast(values.len / 2),
    };
}

fn value_offset(eval_pool: *const ValuePool, ptr: [*]Value) u32 {
    const bytes = @intFromPtr(ptr) - @intFromPtr(eval_pool.values.ptr);
    return @intCast(bytes / @sizeOf(Value));
}
