const std = @import("std");
const Arena = @import("arena.zig").Arena;
const ast = @import("ast.zig");
const eval = @import("eval.zig");
const Context = eval.Context;
const Evaluator = eval.Evaluator;
const action = @import("action.zig");
const ActionCompiler = action.ActionCompiler;
const ActionExecutor = action.ActionExecutor;
const StateStore = @import("state.zig").StateStore;
const StateQueue = @import("queue.zig").StateQueue;
const FpSet = @import("fp_set.zig").FpSet;
const fingerprint = @import("fingerprint.zig");
const ValuePool = @import("value.zig").ValuePool;
const Value = @import("value.zig").Value;
const Error = @import("err.zig").Error;
const Config = @import("config.zig").Config;
const Constant = eval.Constant;

pub const Checker = struct {
    arena: *Arena,
    state_store: StateStore,
    queue: StateQueue,
    fp_set: FpSet,
    evaluator: Evaluator,
    init_spec: action.CompiledInit,
    next_spec: action.CompiledNext,
    invariants: []const *ast.Expr,
    eval_arena: Arena,
    eval_pool: ValuePool,
    max_states: u32,
    generated: u64,
    distinct: u64,

    pub fn init(
        arena: *Arena,
        module: ast.Module,
        cfg: Config,
        max_states: u32,
        eval_value_cap: u32,
        eval_string_cap: u32,
        state_value_cap: u32,
        state_string_cap: u32,
    ) !Checker {
        var state_store = try StateStore.init(
            arena,
            module.variables,
            max_states,
            state_value_cap,
            state_string_cap,
        );
        const queue = try StateQueue.init(arena, max_states);
        const fp_set = try FpSet.init(arena, max_states * 2);
        var evaluator = try Evaluator.init(module, arena);
        const constants = try evaluate_constants(arena, cfg, &evaluator, &state_store.values_pool);
        evaluator.set_constants(constants);
        const compiler = ActionCompiler.init(arena, evaluator);

        const init_name = cfg.init_name orelse find_init_name(module) orelse return Error.ConfigError;
        const next_name = cfg.next_name orelse find_next_name(module) orelse return Error.ConfigError;

        const init_def = evaluator.find_definition(init_name) orelse {
            std.debug.print("undefined init: {s}\n", .{init_name});
            return Error.UndefinedSymbol;
        };
        const next_def = evaluator.find_definition(next_name) orelse {
            std.debug.print("undefined next: {s}\n", .{next_name});
            return Error.UndefinedSymbol;
        };

        const compiled_init = try compiler.compile_init(init_def.body);
        const compiled_next = try compiler.compile_next(next_def.body);

        var invariant_exprs = std.ArrayList(*ast.Expr).empty;
        defer invariant_exprs.deinit(std.heap.page_allocator);
        for (cfg.invariants) |inv_name| {
            const def = evaluator.find_definition(inv_name) orelse return Error.UndefinedSymbol;
            try invariant_exprs.append(std.heap.page_allocator, def.body);
        }

        const invariants: []const *ast.Expr = if (invariant_exprs.items.len == 0) &[_]*ast.Expr{} else blk: {
            const result = try arena.alloc(*ast.Expr, invariant_exprs.items.len);
            for (invariant_exprs.items, 0..) |inv, i| {
                result[i] = inv;
            }
            break :blk result;
        };

        var eval_arena = try Arena.init(64 * 1024 * 1024);
        const eval_pool = try ValuePool.init(&eval_arena, eval_value_cap, eval_string_cap);

        return Checker{
            .arena = arena,
            .state_store = state_store,
            .queue = queue,
            .fp_set = fp_set,
            .evaluator = evaluator,
            .init_spec = compiled_init,
            .next_spec = compiled_next,
            .invariants = invariants,
            .eval_arena = eval_arena,
            .eval_pool = eval_pool,
            .max_states = max_states,
            .generated = 0,
            .distinct = 0,
        };
    }

    pub fn check(self: *Checker) !Result {
        var out_states = std.ArrayList(u32).empty;
        defer out_states.deinit(std.heap.page_allocator);

        var executor = ActionExecutor{
            .evaluator = self.evaluator,
            .state_store = &self.state_store,
            .eval_pool = &self.eval_pool,
        };

        try executor.execute_init(self.init_spec, &out_states);
        try self.process_generated(&out_states);

        while (self.queue.dequeue()) |idx| {
            out_states.clearRetainingCapacity();
            self.eval_pool.restore(self.eval_pool.snapshot());
            try executor.execute_next(self.next_spec, idx, &out_states);
            try self.process_generated(&out_states);
        }

        return Result{
            .generated = self.generated,
            .distinct = self.distinct,
            .error_state = null,
        };
    }

    fn process_generated(self: *Checker, out_states: *std.ArrayList(u32)) !void {
        for (out_states.items) |idx| {
            self.generated += 1;
            const st = self.state_store.get(idx);
            if (!try self.check_invariants(st)) {
                return Error.InvariantViolated;
            }
            const fp = fingerprint.hash_state(&self.state_store.values_pool, st.values);
            if (self.fp_set.put(fp)) {
                self.distinct += 1;
                if (!self.queue.enqueue(idx)) return Error.StateSpaceExhausted;
            }
        }
    }

    fn check_invariants(self: *Checker, st: *StateStore.State) !bool {
        for (self.invariants) |inv| {
            const v = try self.evaluator.eval_expr(inv, Context.empty(), st, &self.eval_pool, &self.state_store.values_pool);
            if (!v.is_truthy()) return false;
        }
        return true;
    }
};

pub const Result = struct {
    generated: u64,
    distinct: u64,
    error_state: ?u32,
};

fn find_init_name(module: ast.Module) ?[]const u8 {
    for (module.definitions) |d| {
        if (std.mem.eql(u8, d.name, "Init")) return d.name;
    }
    return null;
}

fn find_next_name(module: ast.Module) ?[]const u8 {
    for (module.definitions) |d| {
        if (std.mem.eql(u8, d.name, "Next")) return d.name;
    }
    return null;
}

fn evaluate_constants(arena: *Arena, cfg: Config, evaluator: *Evaluator, state_pool: *ValuePool) ![]const Constant {
    if (cfg.constants.len == 0) return &[_]Constant{};
    const result = try arena.alloc(Constant, cfg.constants.len);
    for (cfg.constants, 0..) |ca, i| {
        result[i] = Constant{
            .name = ca.name,
            .value = try evaluate_config_expr(ca.expr, evaluator, state_pool),
        };
    }
    return result;
}

fn evaluate_config_expr(expr: []const u8, evaluator: *Evaluator, state_pool: *ValuePool) !Value {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return error.SyntaxError;

    if (trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
        var items = std.ArrayList(Value).empty;
        defer items.deinit(std.heap.page_allocator);
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t");
            if (t.len == 0) continue;
            try items.append(std.heap.page_allocator, try parse_config_value(t, evaluator));
        }
        const dest = try state_pool.alloc_values(@intCast(items.items.len));
        @memcpy(dest, items.items);
        return Value{ .set_v = .{
            .offset = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(state_pool.values.ptr)) / @sizeOf(Value)),
            .len = @intCast(dest.len),
        } };
    }

    if (std.mem.indexOf(u8, trimmed, "..") != null) {
        const dots = std.mem.indexOf(u8, trimmed, "..").?;
        const lo = std.fmt.parseInt(i64, std.mem.trim(u8, trimmed[0..dots], " \t"), 10) catch return error.SyntaxError;
        const hi = std.fmt.parseInt(i64, std.mem.trim(u8, trimmed[dots + 2 ..], " \t"), 10) catch return error.SyntaxError;
        if (lo > hi) return Value{ .set_v = .{ .offset = state_pool.value_count, .len = 0 } };
        const len: u32 = @intCast(hi - lo + 1);
        const dest = try state_pool.alloc_values(len);
        for (0..len) |i| {
            dest[i] = Value{ .int_v = lo + @as(i64, @intCast(i)) };
        }
        return Value{ .set_v = .{
            .offset = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(state_pool.values.ptr)) / @sizeOf(Value)),
            .len = len,
        } };
    }

    return parse_config_value(trimmed, evaluator);
}

fn parse_config_value(text: []const u8, evaluator: *Evaluator) !Value {
    if (std.fmt.parseInt(i64, text, 10)) |i| {
        return Value{ .int_v = i };
    } else |_| {}
    const id = try evaluator.models.intern(text);
    return Value{ .model_v = id };
}
