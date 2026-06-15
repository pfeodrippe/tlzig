const std = @import("std");
const Arena = @import("arena.zig").Arena;
const ast = @import("ast.zig");
const value = @import("value.zig");
const Value = value.Value;
const ValuePool = value.ValuePool;
const state = @import("state.zig");
const StateStore = state.StateStore;
const Error = @import("err.zig").Error;
const ModelTable = value.ModelTable;

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

pub const Evaluator = struct {
    module: ast.Module,
    constants: []const Constant,
    models: ModelTable,

    pub fn init(module: ast.Module, arena: *Arena) !Evaluator {
        return Evaluator{
            .module = module,
            .constants = &[_]Constant{},
            .models = try ModelTable.init(arena, 1024),
        };
    }

    pub fn set_constants(self: *Evaluator, constants: []const Constant) void {
        self.constants = constants;
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
                if (self.find_definition(name)) |def| {
                    if (def.params.len != 0) return Error.TypeError;
                    return try self.eval_expr(def.body, ctx, s0, eval_pool, state_pool);
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
            .in => {
                if (right != .set_v) return Error.TypeError;
                return Value{ .bool_v = right.set_v.contains(eval_pool, left) };
            },
            .notin => {
                if (right != .set_v) return Error.TypeError;
                return Value{ .bool_v = !right.set_v.contains(eval_pool, left) };
            },
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
            .union_all => Error.NotImplemented,
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
        const domain = try self.eval_expr(fl.domain, ctx, s0, eval_pool, state_pool);
        if (domain != .set_v) return Error.TypeError;
        const items = domain.set_v.items(eval_pool);
        const dest = try eval_pool.alloc_values(@intCast(items.len));
        for (items, 0..) |it, i| {
            const new_ctx = ctx.extend(fl.var_name, it);
            dest[i] = try self.eval_expr(fl.body, new_ctx, s0, eval_pool, state_pool);
        }
        return Value{ .function_v = .{
            .domain = domain.set_v,
            .offset = value_offset(eval_pool, dest.ptr),
            .len = @intCast(items.len),
        } };
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
            const name = ap.func.*.ident;
            if (self.find_definition(name)) |def| {
                if (def.params.len != ap.args.len) return Error.TypeError;
                const values = try eval_pool.alloc_values(@intCast(ap.args.len));
                for (ap.args, 0..) |arg, i| {
                    values[i] = try self.eval_expr(arg, ctx, s0, eval_pool, state_pool);
                }
                var new_ctx = Context{ .names = undefined, .values = undefined, .len = 0 };
                for (def.params, 0..) |p, i| {
                    new_ctx = new_ctx.extend(p, values[i]);
                }
                return try self.eval_expr(def.body, new_ctx, s0, eval_pool, state_pool);
            }
        }
        const func = try self.eval_expr(ap.func, ctx, s0, eval_pool, state_pool);
        if (ap.args.len == 0) return func;
        const first_arg = try self.eval_expr(ap.args[0], ctx, s0, eval_pool, state_pool);
        switch (func) {
            .function_v => |f| {
                if (ap.args.len != 1) return Error.TypeError;
                return f.apply(eval_pool, first_arg) orelse Error.UndefinedSymbol;
            },
            .tuple_v => |t| {
                if (ap.args.len != 1) return Error.TypeError;
                const idx = (first_arg.as_int() orelse return Error.TypeError) - 1;
                if (idx < 0 or idx >= t.len) return Error.IndexOutOfBounds;
                return t.items(eval_pool)[@intCast(idx)];
            },
            .record_v => |r| {
                if (ap.args.len != 1) return Error.TypeError;
                const name = first_arg.string_v.slice(eval_pool);
                return r.lookup(eval_pool, name) orelse Error.UndefinedSymbol;
            },
            else => {
                return Error.TypeError;
            },
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

    fn eval_choose(
        self: Evaluator,
        c: *ast.Choose,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const domain = try self.eval_expr(c.domain, ctx, s0, eval_pool, state_pool);
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

    fn eval_except(
        self: Evaluator,
        e: *ast.Except,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (e.steps.len != 1) return Error.NotImplemented;
        const original = try self.eval_expr(e.func, ctx, s0, eval_pool, state_pool);
        const step = e.steps[0];
        switch (step) {
            .index => |idx_expr| {
                const key = try self.eval_expr(idx_expr, ctx, s0, eval_pool, state_pool);
                const old_value = try self.except_lookup_index(original, key, eval_pool);
                const new_ctx = ctx.extend("@", old_value);
                const new_value = try self.eval_expr(e.value, new_ctx, s0, eval_pool, state_pool);
                return try self.except_update_index(original, key, new_value, eval_pool);
            },
            .field => |field| {
                const old_value = try self.except_lookup_field(original, field, eval_pool);
                const new_ctx = ctx.extend("@", old_value);
                const new_value = try self.eval_expr(e.value, new_ctx, s0, eval_pool, state_pool);
                return try self.except_update_field(original, field, new_value, eval_pool);
            },
        }
    }

    fn except_lookup_index(self: Evaluator, original: Value, key: Value, eval_pool: *ValuePool) Error!Value {
        _ = self;
        switch (original) {
            .function_v => |f| return f.apply(eval_pool, key) orelse Error.IndexOutOfBounds,
            .tuple_v => |t| {
                const idx = (key.as_int() orelse return Error.TypeError) - 1;
                if (idx < 0 or idx >= t.len) return Error.IndexOutOfBounds;
                return t.items(eval_pool)[@intCast(idx)];
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
                const idx = (key.as_int() orelse return Error.TypeError) - 1;
                if (idx < 0 or idx >= t.len) return Error.IndexOutOfBounds;
                const items = t.items(eval_pool);
                const dest = try eval_pool.alloc_values(@intCast(items.len));
                @memcpy(dest, items);
                dest[@intCast(idx)] = new_value;
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
