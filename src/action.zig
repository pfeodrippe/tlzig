const std = @import("std");
const assert = std.debug.assert;
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

fn inline_expr(arena: *Arena, expr: *ast.Expr, params: []const []const u8, args: []const *ast.Expr) !*ast.Expr {
    switch (expr.*) {
        .ident => |name| {
            for (params, 0..) |p, i| {
                if (std.mem.eql(u8, name, p)) return args[i];
            }
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .ident = try arena.dup(name) };
            return ptr;
        },
        .primed => |name| {
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .primed = try arena.dup(name) };
            return ptr;
        },
        .bool_literal => |b| {
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .bool_literal = b };
            return ptr;
        },
        .int_literal => |i| {
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .int_literal = i };
            return ptr;
        },
        .string_literal => |s| {
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .string_literal = try arena.dup(s) };
            return ptr;
        },
        .at => {
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .at;
            return ptr;
        },
        .unchanged => |names| {
            const ptr = try arena.alloc_object(ast.Expr);
            const copy = try arena.alloc([]const u8, names.len);
            for (names, 0..) |n, i| copy[i] = try arena.dup(n);
            ptr.* = .{ .unchanged = copy };
            return ptr;
        },
        .binary => |b| {
            const bp = try arena.alloc_object(ast.Binary);
            bp.* = .{
                .op = b.op,
                .left = try inline_expr(arena, b.left, params, args),
                .right = try inline_expr(arena, b.right, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .binary = bp };
            return ptr;
        },
        .unary => |u| {
            const up = try arena.alloc_object(ast.Unary);
            up.* = .{
                .op = u.op,
                .operand = try inline_expr(arena, u.operand, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .unary = up };
            return ptr;
        },
        .apply => |a| {
            const new_args = try arena.alloc(*ast.Expr, a.args.len);
            for (a.args, 0..) |arg, i| new_args[i] = try inline_expr(arena, arg, params, args);
            const ap = try arena.alloc_object(ast.Apply);
            ap.* = .{ .func = try inline_expr(arena, a.func, params, args), .args = new_args };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .apply = ap };
            return ptr;
        },
        .field => |f| {
            const fp = try arena.alloc_object(ast.Field);
            fp.* = .{
                .expr = try inline_expr(arena, f.expr, params, args),
                .name = try arena.dup(f.name),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .field = fp };
            return ptr;
        },
        .tuple => |t| {
            const items = try arena.alloc(*ast.Expr, t.len);
            for (t, 0..) |it, i| items[i] = try inline_expr(arena, it, params, args);
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .tuple = items };
            return ptr;
        },
        .record => |r| {
            const fields = try arena.alloc(ast.FieldInit, r.len);
            for (r, 0..) |f, i| {
                fields[i] = .{
                    .name = try arena.dup(f.name),
                    .value = try inline_expr(arena, f.value, params, args),
                };
            }
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .record = fields };
            return ptr;
        },
        .set_enum => |s| {
            const items = try arena.alloc(*ast.Expr, s.len);
            for (s, 0..) |it, i| items[i] = try inline_expr(arena, it, params, args);
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .set_enum = items };
            return ptr;
        },
        .set_filter => |sf| {
            const sfp = try arena.alloc_object(ast.SetFilter);
            sfp.* = .{
                .var_name = try arena.dup(sf.var_name),
                .domain = try inline_expr(arena, sf.domain, params, args),
                .pred = try inline_expr(arena, sf.pred, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .set_filter = sfp };
            return ptr;
        },
        .set_map => |sm| {
            const smp = try arena.alloc_object(ast.SetMap);
            smp.* = .{
                .var_name = try arena.dup(sm.var_name),
                .domain = try inline_expr(arena, sm.domain, params, args),
                .value = try inline_expr(arena, sm.value, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .set_map = smp };
            return ptr;
        },
        .function_literal => |fl| {
            const vars = try arena.alloc(ast.BoundVar, fl.vars.len);
            for (fl.vars, 0..) |v, i| {
                vars[i] = .{
                    .name = try arena.dup(v.name),
                    .domain = try inline_expr(arena, v.domain, params, args),
                };
            }
            const flp = try arena.alloc_object(ast.FunctionLiteral);
            flp.* = .{ .vars = vars, .body = try inline_expr(arena, fl.body, params, args) };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .function_literal = flp };
            return ptr;
        },
        .if_then_else => |ie| {
            const iep = try arena.alloc_object(ast.IfThenElse);
            iep.* = .{
                .cond = try inline_expr(arena, ie.cond, params, args),
                .then_branch = try inline_expr(arena, ie.then_branch, params, args),
                .else_branch = try inline_expr(arena, ie.else_branch, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .if_then_else = iep };
            return ptr;
        },
        .quantifier => |q| {
            const vars = try arena.alloc(ast.BoundVar, q.vars.len);
            for (q.vars, 0..) |v, i| {
                vars[i] = .{
                    .name = try arena.dup(v.name),
                    .domain = try inline_expr(arena, v.domain, params, args),
                };
            }
            const qp = try arena.alloc_object(ast.Quantifier);
            qp.* = .{
                .kind = q.kind,
                .vars = vars,
                .body = try inline_expr(arena, q.body, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .quantifier = qp };
            return ptr;
        },
        .choose => |c| {
            const cp = try arena.alloc_object(ast.Choose);
            cp.* = .{
                .var_name = try arena.dup(c.var_name),
                .domain = if (c.domain) |d| try inline_expr(arena, d, params, args) else null,
                .body = try inline_expr(arena, c.body, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .choose = cp };
            return ptr;
        },
        .let_in => |l| {
            const defs = try arena.alloc(ast.Definition, l.defs.len);
            for (l.defs, 0..) |def, i| {
                defs[i] = .{
                    .name = try arena.dup(def.name),
                    .params = blk: {
                        const copy = try arena.alloc([]const u8, def.params.len);
                        for (def.params, 0..) |p, j| copy[j] = try arena.dup(p);
                        break :blk copy;
                    },
                    .body = try inline_expr(arena, def.body, params, args),
                };
            }
            const lp = try arena.alloc_object(ast.LetIn);
            lp.* = .{ .defs = defs, .body = try inline_expr(arena, l.body, params, args) };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .let_in = lp };
            return ptr;
        },
        .case_expr => |c| {
            const arms = try arena.alloc(ast.CaseArm, c.arms.len);
            for (c.arms, 0..) |a, i| {
                arms[i] = .{
                    .cond = try inline_expr(arena, a.cond, params, args),
                    .value = try inline_expr(arena, a.value, params, args),
                };
            }
            const cp = try arena.alloc_object(ast.CaseExpr);
            cp.* = .{
                .arms = arms,
                .otherwise = if (c.otherwise) |o| try inline_expr(arena, o, params, args) else null,
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .case_expr = cp };
            return ptr;
        },
        .set_binary => |sb| {
            const sbp = try arena.alloc_object(ast.SetBinary);
            sbp.* = .{
                .op = sb.op,
                .left = try inline_expr(arena, sb.left, params, args),
                .right = try inline_expr(arena, sb.right, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .set_binary = sbp };
            return ptr;
        },
        .set_of_functions => |sf| {
            const sfp = try arena.alloc_object(ast.SetOfFunctions);
            sfp.* = .{
                .domain = try inline_expr(arena, sf.domain, params, args),
                .codomain = try inline_expr(arena, sf.codomain, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .set_of_functions = sfp };
            return ptr;
        },
        .record_set => |rs| {
            const fields = try arena.alloc(ast.RecordFieldDomain, rs.fields.len);
            for (rs.fields, 0..) |f, i| {
                fields[i] = .{
                    .name = try arena.dup(f.name),
                    .domain = try inline_expr(arena, f.domain, params, args),
                };
            }
            const rsp = try arena.alloc_object(ast.RecordSet);
            rsp.* = .{ .fields = fields };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .record_set = rsp };
            return ptr;
        },
        .except => |e| {
            const steps = try arena.alloc(ast.AccessStep, e.steps.len);
            for (e.steps, 0..) |s, i| {
                steps[i] = switch (s) {
                    .field => |f| ast.AccessStep{ .field = try arena.dup(f) },
                    .index => |idx| ast.AccessStep{ .index = try inline_expr(arena, idx, params, args) },
                };
            }
            const ep = try arena.alloc_object(ast.Except);
            ep.* = .{
                .func = try inline_expr(arena, e.func, params, args),
                .steps = steps,
                .value = try inline_expr(arena, e.value, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .except = ep };
            return ptr;
        },
        .box_action => |ba| {
            const bap = try arena.alloc_object(ast.BoxAction);
            bap.* = .{
                .action_name = try arena.dup(ba.action_name),
                .vars = try inline_expr(arena, ba.vars, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .box_action = bap };
            return ptr;
        },
        .lambda => |l| {
            const params_copy = try arena.alloc([]const u8, l.params.len);
            for (l.params, 0..) |p, i| params_copy[i] = try arena.dup(p);
            const lp = try arena.alloc_object(ast.Lambda);
            lp.* = .{
                .params = params_copy,
                .body = try inline_expr(arena, l.body, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .lambda = lp };
            return ptr;
        },
    }
}

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
    is_membership: bool,
};

pub const AssignPrime = struct {
    var_name: []const u8,
    expr: *ast.Expr,
    is_membership: bool,
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
        return self.is_action_expr_inner(expr);
    }

    fn is_action_expr_inner(self: ActionCompiler, expr: *ast.Expr) bool {
        switch (expr.*) {
            .primed, .unchanged => return true,
            .ident => |name| {
                if (self.evaluator.find_definition(name)) |def| return self.is_action_expr_inner(def.body);
                return false;
            },
            .binary => |b| {
                if (b.op == .or_op) return self.is_action_expr(b.left) and self.is_action_expr(b.right);
                return self.is_action_expr(b.left) or self.is_action_expr(b.right);
            },
            .let_in => |l| return self.is_action_expr_inner(l.body),
            .if_then_else => |ite| return self.is_action_expr(ite.then_branch) or self.is_action_expr(ite.else_branch),
            .apply => |ap| {
                if (ap.func.* == .ident) {
                    if (self.evaluator.find_definition(ap.func.*.ident)) |def| return self.is_action_expr_inner(def.body);
                }
                return false;
            },
            .quantifier => |q| return self.is_action_expr_inner(q.body),
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
                if (b.op == .or_op) {
                    if (self.is_action_expr(b.left) and self.is_action_expr(b.right)) {
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
                }
                if (b.op == .eq) {
                    if (!is_init and b.left.* == .primed) {
                        try steps.append(std.heap.page_allocator, ActionStep{ .assign_prime = .{ .var_name = b.left.*.primed, .expr = b.right, .is_membership = false } });
                        return;
                    }
                    if (is_init and b.left.* == .ident) {
                        try steps.append(std.heap.page_allocator, ActionStep{ .assign_var = .{ .var_name = b.left.*.ident, .expr = b.right, .is_membership = false } });
                        return;
                    }
                }
                if (b.op == .in) {
                    if (is_init and b.left.* == .ident) {
                        try steps.append(std.heap.page_allocator, ActionStep{ .assign_var = .{ .var_name = b.left.*.ident, .expr = b.right, .is_membership = true } });
                        return;
                    }
                    if (!is_init and b.left.* == .primed) {
                        try steps.append(std.heap.page_allocator, ActionStep{ .assign_prime = .{ .var_name = b.left.*.primed, .expr = b.right, .is_membership = true } });
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
                    const func_name = self.evaluator.resolve_alias(ap.func.*.ident);
                    if (self.evaluator.find_definition(func_name)) |def| {
                        if (def.params.len == ap.args.len) {
                            const inlined = try inline_expr(self.arena, def.body, def.params, ap.args);
                            try self.collect_steps(inlined, steps, is_init);
                            return;
                        }
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
        assert(self.eval_pool.value_count <= self.eval_pool.value_cap);
        assert(self.state_store.values_pool.value_count <= self.state_store.values_pool.value_cap);
        if (steps.len == 0) {
            try self.commit_state(ctx, s0, out_states, is_init);
            return;
        }
        const step = steps[0];
        const rest = steps[1..];
        assert(rest.len == steps.len - 1);
        switch (step) {
            .assign_var => |a| {
                const val = try self.evaluator.eval_expr(a.expr, ctx, s0, self.eval_pool, &self.state_store.values_pool);
                if (a.is_membership and val == .set_v) {
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
                if (a.is_membership and val == .set_v) {
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
                const idx = self.evaluator.find_variable(name) orelse {
                    std.debug.print("UndefinedVariable in UNCHANGED: {s}\n", .{name});
                    return Error.UndefinedSymbol;
                };
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
