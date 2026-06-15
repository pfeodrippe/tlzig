const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");
const Value = value.Value;
const ValuePool = value.ValuePool;
const eval = @import("eval.zig");
const Context = eval.Context;
const Evaluator = eval.Evaluator;
const StateStore = @import("state.zig").StateStore;
const Arena = @import("arena.zig").Arena;
const Error = @import("err.zig").Error;

pub const ActionStep = union(enum(u8)) {
    assign_var: AssignVar,
    assign_prime: AssignPrime,
    condition: *ast.Expr,
    choose: Choose,
    branch: Branch,
    if_branch: IfBranch,
    call: Call,
    let_bind: LetBind,
    unchanged: []const u8,
};

pub const AssignVar = struct {
    var_name: []const u8,
    expr: *ast.Expr,
};

pub const AssignPrime = struct {
    var_name: []const u8,
    expr: *ast.Expr,
};

pub const Choose = struct {
    var_name: []const u8,
    domain: *ast.Expr,
    body_steps: []const ActionStep,
};

pub const Call = struct {
    def: ast.Definition,
    args: []const *ast.Expr,
    body_steps: []const ActionStep,
};

pub const LetBind = struct {
    name: []const u8,
    expr: *ast.Expr,
};

pub const Branch = struct {
    options: []const []const ActionStep,
};

pub const IfBranch = struct {
    cond: *ast.Expr,
    then_steps: []const ActionStep,
    else_steps: []const ActionStep,
};

pub const CompiledInit = struct {
    steps: []const ActionStep,
};

pub const CompiledNext = struct {
    steps: []const ActionStep,
};

pub const ActionCompiler = struct {
    arena: *Arena,
    evaluator: Evaluator,

    pub fn init(arena: *Arena, evaluator: Evaluator) ActionCompiler {
        return ActionCompiler{ .arena = arena, .evaluator = evaluator };
    }

    pub fn compile_init(self: ActionCompiler, expr: *ast.Expr) !CompiledInit {
        var steps = std.ArrayList(ActionStep).empty;
        defer steps.deinit(std.heap.page_allocator);
        try self.collect_steps(expr, &steps, true);
        return CompiledInit{ .steps = try self.dup_slice(ActionStep, steps.items) };
    }

    pub fn compile_next(self: ActionCompiler, expr: *ast.Expr) !CompiledNext {
        var steps = std.ArrayList(ActionStep).empty;
        defer steps.deinit(std.heap.page_allocator);
        try self.collect_steps(expr, &steps, false);
        return CompiledNext{ .steps = try self.dup_slice(ActionStep, steps.items) };
    }

    fn is_action_expr(self: ActionCompiler, expr: *ast.Expr) bool {
        switch (expr.*) {
            .primed, .unchanged => return true,
            .ident => |name| {
                if (self.evaluator.find_definition(name)) |def| return self.is_action_expr(def.body);
                return false;
            },
            .binary => |b| {
                if (b.op == .or_op) return self.is_action_expr(b.left) and self.is_action_expr(b.right);
                return self.is_action_expr(b.left) or self.is_action_expr(b.right);
            },
            .let_in => |l| return self.is_action_expr(l.body),
            .if_then_else => |ite| return self.is_action_expr(ite.then_branch) or self.is_action_expr(ite.else_branch),
            .apply => |ap| {
                if (ap.func.* == .ident) {
                    if (self.evaluator.find_definition(ap.func.*.ident)) |def| return self.is_action_expr(def.body);
                }
                return false;
            },
            .quantifier => |q| return self.is_action_expr(q.body),
            else => return false,
        }
    }

    fn collect_steps(
        self: ActionCompiler,
        expr: *ast.Expr,
        steps: *std.ArrayList(ActionStep),
        is_init: bool,
    ) !void {
        switch (expr.*) {
            .binary => |b| {
                if (b.op == .and_op) {
                    try self.collect_steps(b.left, steps, is_init);
                    try self.collect_steps(b.right, steps, is_init);
                    return;
                }
                if (b.op == .or_op and self.is_action_expr(b.left) and self.is_action_expr(b.right)) {
                    var options = std.ArrayList([]const ActionStep).empty;
                    defer options.deinit(std.heap.page_allocator);
                    var left_steps = std.ArrayList(ActionStep).empty;
                    defer left_steps.deinit(std.heap.page_allocator);
                    try self.collect_steps(b.left, &left_steps, is_init);
                    try options.append(std.heap.page_allocator, try self.dup_slice(ActionStep, left_steps.items));
                    var right_steps = std.ArrayList(ActionStep).empty;
                    defer right_steps.deinit(std.heap.page_allocator);
                    try self.collect_steps(b.right, &right_steps, is_init);
                    try options.append(std.heap.page_allocator, try self.dup_slice(ActionStep, right_steps.items));
                    try steps.append(std.heap.page_allocator, ActionStep{ .branch = .{ .options = try self.dup_slice([]const ActionStep, options.items) } });
                    return;
                }
                if (b.op == .eq) {
                    if (!is_init and b.left.* == .primed) {
                        try steps.append(std.heap.page_allocator, ActionStep{ .assign_prime = .{ .var_name = b.left.*.primed, .expr = b.right } });
                        return;
                    }
                    if (is_init and b.left.* == .ident) {
                        try steps.append(std.heap.page_allocator, ActionStep{ .assign_var = .{ .var_name = b.left.*.ident, .expr = b.right } });
                        return;
                    }
                }
                if (b.op == .in) {
                    if (is_init and b.left.* == .ident) {
                        try steps.append(std.heap.page_allocator, ActionStep{ .assign_var = .{ .var_name = b.left.*.ident, .expr = b.right } });
                        return;
                    }
                    if (!is_init and b.left.* == .primed) {
                        try steps.append(std.heap.page_allocator, ActionStep{ .assign_prime = .{ .var_name = b.left.*.primed, .expr = b.right } });
                        return;
                    }
                }
                try steps.append(std.heap.page_allocator, ActionStep{ .condition = expr });
            },
            .ident => |name| {
                if (self.evaluator.find_definition(name)) |def| {
                    try self.collect_steps(def.body, steps, is_init);
                } else {
                    try steps.append(std.heap.page_allocator, ActionStep{ .condition = expr });
                }
            },
            .quantifier => |q| {
                if (q.kind == .exists and q.vars.len == 1) {
                    var body_steps = std.ArrayList(ActionStep).empty;
                    defer body_steps.deinit(std.heap.page_allocator);
                    try self.collect_steps(q.body, &body_steps, is_init);
                    try steps.append(std.heap.page_allocator, ActionStep{ .choose = .{
                        .var_name = q.vars[0].name,
                        .domain = q.vars[0].domain,
                        .body_steps = try self.dup_slice(ActionStep, body_steps.items),
                    } });
                    return;
                }
                try steps.append(std.heap.page_allocator, ActionStep{ .condition = expr });
            },
            .if_then_else => |ite| {
                const then_action = self.is_action_expr(ite.then_branch);
                const else_action = self.is_action_expr(ite.else_branch);
                if (then_action or else_action) {
                    var then_steps = std.ArrayList(ActionStep).empty;
                    defer then_steps.deinit(std.heap.page_allocator);
                    try self.collect_steps(ite.then_branch, &then_steps, is_init);
                    var else_steps = std.ArrayList(ActionStep).empty;
                    defer else_steps.deinit(std.heap.page_allocator);
                    try self.collect_steps(ite.else_branch, &else_steps, is_init);
                    try steps.append(std.heap.page_allocator, ActionStep{ .if_branch = .{
                        .cond = ite.cond,
                        .then_steps = try self.dup_slice(ActionStep, then_steps.items),
                        .else_steps = try self.dup_slice(ActionStep, else_steps.items),
                    } });
                    return;
                }
                try steps.append(std.heap.page_allocator, ActionStep{ .condition = expr });
            },
            .let_in => |l| {
                for (l.defs) |def| {
                    try steps.append(std.heap.page_allocator, ActionStep{ .let_bind = .{ .name = def.name, .expr = def.body } });
                }
                try self.collect_steps(l.body, steps, is_init);
            },
            .apply => |ap| {
                if (ap.func.* == .ident) {
                    if (self.evaluator.find_definition(ap.func.*.ident)) |def| {
                        var body_steps = std.ArrayList(ActionStep).empty;
                        defer body_steps.deinit(std.heap.page_allocator);
                        try self.collect_steps(def.body, &body_steps, is_init);
                        try steps.append(std.heap.page_allocator, ActionStep{ .call = .{
                            .def = def,
                            .args = ap.args,
                            .body_steps = try self.dup_slice(ActionStep, body_steps.items),
                        } });
                        return;
                    }
                }
                try steps.append(std.heap.page_allocator, ActionStep{ .condition = expr });
            },
            .unchanged => |vars| {
                for (vars) |v| {
                    if (self.evaluator.find_variable(v) != null) {
                        try steps.append(std.heap.page_allocator, ActionStep{ .unchanged = v });
                    } else if (self.evaluator.find_definition(v)) |def| {
                        if (def.params.len == 0 and def.body.* == .tuple) {
                            for (def.body.*.tuple) |it| {
                                if (it.* != .ident) return Error.TypeError;
                                try steps.append(std.heap.page_allocator, ActionStep{ .unchanged = it.*.ident });
                            }
                            continue;
                        }
                        try steps.append(std.heap.page_allocator, ActionStep{ .unchanged = v });
                    } else {
                        try steps.append(std.heap.page_allocator, ActionStep{ .unchanged = v });
                    }
                }
            },
            else => {
                try steps.append(std.heap.page_allocator, ActionStep{ .condition = expr });
            },
        }
    }

    fn dup_slice(self: ActionCompiler, comptime T: type, items: []const T) ![]const T {
        const copy = try self.arena.alloc(T, items.len);
        @memcpy(copy, items);
        return copy;
    }
};

pub const ActionExecutor = struct {
    evaluator: Evaluator,
    state_store: *StateStore,
    eval_pool: *ValuePool,

    pub fn execute_init(
        self: ActionExecutor,
        compiled: CompiledInit,
        out_states: *std.ArrayList(u32),
    ) !void {
        try self.execute_steps(compiled.steps, Context.empty(), null, out_states, true);
    }

    pub fn execute_next(
        self: ActionExecutor,
        compiled: CompiledNext,
        s0_idx: u32,
        out_states: *std.ArrayList(u32),
    ) !void {
        const s0 = self.state_store.get(s0_idx);
        try self.execute_steps(compiled.steps, Context.empty(), s0, out_states, false);
    }

    fn execute_steps(
        self: ActionExecutor,
        steps: []const ActionStep,
        ctx: Context,
        s0: ?*StateStore.State,
        out_states: *std.ArrayList(u32),
        is_init: bool,
    ) !void {
        if (steps.len == 0) {
            try self.commit_state(ctx, s0, out_states, is_init);
            return;
        }
        const step = steps[0];
        const rest = steps[1..];
        switch (step) {
            .assign_var => |a| {
                const val = try self.evaluator.eval_expr(a.expr, ctx, s0, self.eval_pool, &self.state_store.values_pool);
                if (val == .set_v) {
                    const items = val.set_v.items(self.eval_pool);
                    const snap = self.eval_pool.snapshot();
                    for (items) |it| {
                        const new_ctx = ctx.extend(a.var_name, it);
                        try self.execute_steps(rest, new_ctx, s0, out_states, is_init);
                        self.eval_pool.restore(snap);
                    }
                } else {
                    const new_ctx = ctx.extend(a.var_name, val);
                    try self.execute_steps(rest, new_ctx, s0, out_states, is_init);
                }
            },
            .assign_prime => |a| {
                const val = try self.evaluator.eval_expr(a.expr, ctx, s0, self.eval_pool, &self.state_store.values_pool);
                if (val == .set_v) {
                    const items = val.set_v.items(self.eval_pool);
                    const snap = self.eval_pool.snapshot();
                    for (items) |it| {
                        const new_ctx = ctx.extend(a.var_name, it);
                        try self.execute_steps(rest, new_ctx, s0, out_states, is_init);
                        self.eval_pool.restore(snap);
                    }
                } else {
                    const new_ctx = ctx.extend(a.var_name, val);
                    try self.execute_steps(rest, new_ctx, s0, out_states, is_init);
                }
            },
            .condition => |e| {
                const v = try self.evaluator.eval_expr(e, ctx, s0, self.eval_pool, &self.state_store.values_pool);
                if (!v.is_truthy()) return;
                try self.execute_steps(rest, ctx, s0, out_states, is_init);
            },
            .choose => |c| {
                const set_v = try self.evaluator.eval_expr(c.domain, ctx, s0, self.eval_pool, &self.state_store.values_pool);
                if (set_v != .set_v) return Error.TypeError;
                const items = set_v.set_v.items(self.eval_pool);
                var combined = std.ArrayList(ActionStep).empty;
                defer combined.deinit(std.heap.page_allocator);
                try combined.appendSlice(std.heap.page_allocator, c.body_steps);
                try combined.appendSlice(std.heap.page_allocator, rest);
                const snap = self.eval_pool.snapshot();
                for (items) |it| {
                    const new_ctx = ctx.extend(c.var_name, it);
                    try self.execute_steps(combined.items, new_ctx, s0, out_states, is_init);
                    self.eval_pool.restore(snap);
                }
            },
            .let_bind => |l| {
                const v = try self.evaluator.eval_expr(l.expr, ctx, s0, self.eval_pool, &self.state_store.values_pool);
                const new_ctx = ctx.extend(l.name, v);
                try self.execute_steps(rest, new_ctx, s0, out_states, is_init);
            },
            .call => |c| {
                if (c.def.params.len != c.args.len) return Error.TypeError;
                const values = try self.eval_pool.alloc_values(@intCast(c.args.len));
                for (c.args, 0..) |arg, i| {
                    values[i] = try self.evaluator.eval_expr(arg, ctx, s0, self.eval_pool, &self.state_store.values_pool);
                }
                var call_ctx = ctx;
                for (c.def.params, 0..) |p, i| {
                    call_ctx = call_ctx.extend(p, values[i]);
                }
                var combined = std.ArrayList(ActionStep).empty;
                defer combined.deinit(std.heap.page_allocator);
                try combined.appendSlice(std.heap.page_allocator, c.body_steps);
                try combined.appendSlice(std.heap.page_allocator, rest);
                const snap = self.eval_pool.snapshot();
                try self.execute_steps(combined.items, call_ctx, s0, out_states, is_init);
                self.eval_pool.restore(snap);
            },
            .branch => |b| {
                var combined = std.ArrayList(ActionStep).empty;
                defer combined.deinit(std.heap.page_allocator);
                const snap = self.eval_pool.snapshot();
                for (b.options) |opt| {
                    combined.clearRetainingCapacity();
                    try combined.appendSlice(std.heap.page_allocator, opt);
                    try combined.appendSlice(std.heap.page_allocator, rest);
                    try self.execute_steps(combined.items, ctx, s0, out_states, is_init);
                    self.eval_pool.restore(snap);
                }
            },
            .if_branch => |ib| {
                const cond_val = try self.evaluator.eval_expr(ib.cond, ctx, s0, self.eval_pool, &self.state_store.values_pool);
                const taken = if (cond_val.is_truthy()) ib.then_steps else ib.else_steps;
                var combined = std.ArrayList(ActionStep).empty;
                defer combined.deinit(std.heap.page_allocator);
                try combined.appendSlice(std.heap.page_allocator, taken);
                try combined.appendSlice(std.heap.page_allocator, rest);
                const snap = self.eval_pool.snapshot();
                try self.execute_steps(combined.items, ctx, s0, out_states, is_init);
                self.eval_pool.restore(snap);
            },
            .unchanged => |name| {
                if (s0 == null) return Error.TypeError;
                const idx = self.evaluator.find_variable(name) orelse return Error.UndefinedSymbol;
                const v = try s0.?.values[idx].clone(&self.state_store.values_pool, self.eval_pool);
                const new_ctx = ctx.extend(name, v);
                try self.execute_steps(rest, new_ctx, s0, out_states, is_init);
            },
        }
    }

    fn commit_state(
        self: ActionExecutor,
        ctx: Context,
        s0: ?*StateStore.State,
        out_states: *std.ArrayList(u32),
        is_init: bool,
    ) !void {
        _ = is_init;
        const new_idx = try self.state_store.alloc_state();
        const new_state = self.state_store.get(new_idx);
        if (s0) |parent| {
            new_state.level = parent.level + 1;
            const pred_idx = @divExact(@intFromPtr(parent) - @intFromPtr(self.state_store.states.ptr), @sizeOf(StateStore.State));
            new_state.pred = @intCast(pred_idx);
        } else {
            new_state.level = 0;
            new_state.pred = 0;
        }
        for (new_state.values) |*v| v.* = Value{ .bool_v = false };
        var i: u32 = 0;
        while (i < ctx.len) : (i += 1) {
            const name = ctx.names[i];
            const v = ctx.values[i];
            const var_idx = self.evaluator.find_variable(name) orelse continue;
            new_state.values[var_idx] = try v.clone(self.eval_pool, &self.state_store.values_pool);
        }
        if (s0) |parent| {
            for (new_state.values, 0..) |*v, vi| {
                if (v.* == .bool_v) {
                    v.* = try parent.values[vi].clone(&self.state_store.values_pool, &self.state_store.values_pool);
                }
            }
        }
        try out_states.append(std.heap.page_allocator, new_idx);
    }
};
