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
const generated_runtime = @import("generated_runtime.zig");
const codegen = @import("codegen.zig");

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
        .primed_expr => |operand| {
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .primed_expr = try inline_expr(arena, operand, params, args) };
            return ptr;
        },
        .unchanged => |names| {
            const ptr = try arena.alloc_object(ast.Expr);
            const copy = try arena.alloc([]const u8, names.len);
            for (names, 0..) |n, i| copy[i] = try arena.dup(n);
            ptr.* = .{ .unchanged = copy };
            return ptr;
        },
        .unchanged_expr => |operand| {
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .unchanged_expr = try inline_expr(arena, operand, params, args) };
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
            const vars = try arena.alloc(ast.BoundVar, sf.vars.len);
            for (sf.vars, 0..) |v, i| {
                vars[i] = .{ .name = try arena.dup(v.name), .domain = try inline_expr(arena, v.domain, params, args) };
            }
            sfp.* = .{
                .vars = vars,
                .pred = try inline_expr(arena, sf.pred, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .set_filter = sfp };
            return ptr;
        },
        .set_map => |sm| {
            const smp = try arena.alloc_object(ast.SetMap);
            const vars = try arena.alloc(ast.BoundVar, sm.vars.len);
            for (sm.vars, 0..) |v, i| {
                vars[i] = .{ .name = try arena.dup(v.name), .domain = try inline_expr(arena, v.domain, params, args) };
            }
            smp.* = .{
                .vars = vars,
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
                .action = try inline_expr(arena, ba.action, params, args),
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

fn inline_local_operator_call(
    arena: *Arena,
    expr: *ast.Expr,
    definition: ast.Definition,
) !*ast.Expr {
    switch (expr.*) {
        .apply => |application| {
            const new_args = try arena.alloc(*ast.Expr, application.args.len);
            for (application.args, 0..) |argument, index| {
                new_args[index] = try inline_local_operator_call(
                    arena,
                    argument,
                    definition,
                );
            }
            if (application.func.* == .ident and
                std.mem.eql(u8, application.func.ident, definition.name) and
                application.args.len == definition.params.len)
            {
                return inline_expr(
                    arena,
                    definition.body,
                    definition.params,
                    new_args,
                );
            }
            const apply = try arena.alloc_object(ast.Apply);
            apply.* = .{
                .func = try inline_local_operator_call(
                    arena,
                    application.func,
                    definition,
                ),
                .args = new_args,
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .apply = apply };
            return ptr;
        },
        .binary => |binary| {
            const copy = try arena.alloc_object(ast.Binary);
            copy.* = .{
                .op = binary.op,
                .left = try inline_local_operator_call(
                    arena,
                    binary.left,
                    definition,
                ),
                .right = try inline_local_operator_call(
                    arena,
                    binary.right,
                    definition,
                ),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .binary = copy };
            return ptr;
        },
        .unary => |unary| {
            const copy = try arena.alloc_object(ast.Unary);
            copy.* = .{
                .op = unary.op,
                .operand = try inline_local_operator_call(
                    arena,
                    unary.operand,
                    definition,
                ),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .unary = copy };
            return ptr;
        },
        .if_then_else => |conditional| {
            const copy = try arena.alloc_object(ast.IfThenElse);
            copy.* = .{
                .cond = try inline_local_operator_call(
                    arena,
                    conditional.cond,
                    definition,
                ),
                .then_branch = try inline_local_operator_call(
                    arena,
                    conditional.then_branch,
                    definition,
                ),
                .else_branch = try inline_local_operator_call(
                    arena,
                    conditional.else_branch,
                    definition,
                ),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .if_then_else = copy };
            return ptr;
        },
        else => return inline_expr(arena, expr, &.{}, &.{}),
    }
}

pub const ActionStep = union(enum(u8)) {
    assign_var: AssignVar,
    assign_prime: AssignPrime,
    condition: CompiledExpr,
    mark_action: MarkAction,
    choose: Choose,
    branch: Branch,
    if_branch: IfBranch,
    case_branch: CaseBranch,
    call: Call,
    compose: Composition,
    let_bind: LetBind,
    unchanged: Unchanged,
};

pub const AssignVar = struct {
    var_name: []const u8,
    var_index: u32,
    expr: CompiledExpr,
    is_membership: bool,
};

pub const AssignPrime = struct {
    var_name: []const u8,
    var_index: u32,
    expr: CompiledExpr,
    is_membership: bool,
};

pub const Unchanged = struct {
    var_name: []const u8,
    var_index: u32,
};

pub const CompiledExpr = struct {
    expr: *ast.Expr,
    generated: ?generated_runtime.Expression,
};

pub const MarkAction = struct {
    name: []const u8,
    args: []const CompiledExpr,
};

pub const FairnessBinding = struct {
    name: []const u8,
    value: Value,
};

pub const FairnessMarker = struct {
    action: *ast.Expr,
    bindings: []const FairnessBinding,
    bit_index: u6,
};

pub const Choose = struct {
    var_name: []const u8,
    domain: CompiledExpr,
    body_steps: []const ActionStep,
};

pub const Call = struct {
    def: ast.Definition,
    args: []const CompiledExpr,
    body_steps: []const ActionStep,
};

pub const LetBind = struct {
    name: []const u8,
    expr: CompiledExpr,
    operator_arity: ?u16,
};

pub const Composition = struct {
    left_steps: []const ActionStep,
    right_steps: []const ActionStep,
};

pub const Branch = struct {
    options: []const []const ActionStep,
};

pub const IfBranch = struct {
    cond: CompiledExpr,
    then_steps: []const ActionStep,
    else_steps: []const ActionStep,
};

pub const CaseActionArm = struct {
    cond: CompiledExpr,
    steps: []const ActionStep,
};

pub const CaseBranch = struct {
    arms: []const CaseActionArm,
    otherwise_steps: ?[]const ActionStep,
};

pub const CompiledInit = struct {
    steps: []const ActionStep,
};

pub const CompiledNext = struct {
    steps: []const ActionStep,
};

pub const StateBuffer = struct {
    storage: []u32,
    items: []u32,

    pub fn init(arena: *Arena, capacity: u32) !StateBuffer {
        assert(capacity > 0);
        const storage = try arena.alloc(u32, capacity);
        return .{ .storage = storage, .items = storage[0..0] };
    }

    pub fn append(self: *StateBuffer, state_index: u32) Error!void {
        if (self.items.len >= self.storage.len) return Error.StateSpaceExhausted;
        self.storage[self.items.len] = state_index;
        self.items = self.storage[0 .. self.items.len + 1];
    }

    pub fn clear(self: *StateBuffer) void {
        self.items = self.storage[0..0];
    }

    pub fn shrink(self: *StateBuffer, len: u32) void {
        assert(len <= self.items.len);
        self.items = self.storage[0..len];
    }
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

    fn is_constant_replacement(self: ActionCompiler, name: []const u8) bool {
        for (self.evaluator.module.config_replacements) |replacement| {
            if (std.mem.eql(u8, replacement.name, name)) {
                return replacement.kind == .constant;
            }
        }
        return false;
    }

    fn compile_expr(self: ActionCompiler, expr: *ast.Expr) !CompiledExpr {
        const identity = codegen.find_expression_identity(
            self.evaluator.module,
            expr,
        );
        if (self.evaluator.generated_expression_count() > 0 and
            identity == null)
        {
            return .{
                .expr = expr,
                .generated = null,
            };
        }
        const generated = if (identity) |expression_id|
            self.evaluator.find_generated_expression(@intCast(expression_id))
        else
            null;
        if (self.evaluator.generated_expression_count() > 0 and
            generated == null)
        {
            std.debug.print(
                "generated action expression is not native: id={d} tag={s}\n",
                .{ identity.?, @tagName(expr.*) },
            );
            return Error.NotImplemented;
        }
        return .{
            .expr = expr,
            .generated = generated,
        };
    }

    fn compile_exprs(
        self: ActionCompiler,
        expressions: []const *ast.Expr,
    ) ![]const CompiledExpr {
        const compiled = try self.arena.alloc(CompiledExpr, expressions.len);
        for (expressions, compiled) |expression, *result| {
            result.* = try self.compile_expr(expression);
        }
        return compiled;
    }

    fn is_action_expr(self: ActionCompiler, expr: *ast.Expr) bool {
        return self.is_action_expr_inner(expr);
    }

    fn is_init_action(self: ActionCompiler, expr: *ast.Expr) bool {
        switch (expr.*) {
            .binary => |b| {
                if (b.op == .eq and b.left.* == .ident) {
                    const name = b.left.ident;
                    if (self.evaluator.find_variable(name) != null) return true;
                }
                if (b.op == .in and b.left.* == .ident) {
                    const name = b.left.ident;
                    if (self.evaluator.find_variable(name) != null) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn is_action_expr_inner(self: ActionCompiler, expr: *ast.Expr) bool {
        switch (expr.*) {
            .primed, .primed_expr, .unchanged, .unchanged_expr => return true,
            .ident => |name| {
                if (self.is_constant_replacement(name)) return false;
                if (self.evaluator.find_constant(name) != null) return false;
                if (self.evaluator.find_definition(name)) |def| return self.is_action_expr_inner(def.body);
                return false;
            },
            .binary => |b| {
                if (b.op == .or_op) return self.is_action_expr(b.left) or self.is_action_expr(b.right);
                if (b.op == .and_op) return self.is_action_expr(b.left) or self.is_action_expr(b.right);
                return self.is_action_expr(b.left) or self.is_action_expr(b.right) or self.is_init_action(expr);
            },
            .let_in => |l| return self.is_action_expr_inner(l.body),
            .if_then_else => |ite| return self.is_action_expr(ite.then_branch) or self.is_action_expr(ite.else_branch),
            .case_expr => |case| {
                for (case.arms) |arm| {
                    if (self.is_action_expr(arm.value)) return true;
                }
                if (case.otherwise) |otherwise| return self.is_action_expr(otherwise);
                return false;
            },
            .apply => |ap| {
                if (ap.func.* == .ident) {
                    if (std.mem.eql(u8, ap.func.*.ident, "\\cdot")) {
                        return ap.args.len == 2 and
                            self.is_action_expr(ap.args[0]) and
                            self.is_action_expr(ap.args[1]);
                    }
                    if (self.is_constant_replacement(ap.func.*.ident)) {
                        return false;
                    }
                    if (self.evaluator.find_constant(ap.func.*.ident) != null) {
                        return false;
                    }
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
                    if (self.is_action_expr(b.left) or self.is_action_expr(b.right)) {
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
                        const name = b.left.*.primed;
                        const index = self.evaluator.find_variable(name) orelse
                            return Error.UndefinedSymbol;
                        try steps.append(std.heap.page_allocator, ActionStep{ .assign_prime = .{ .var_name = name, .var_index = index, .expr = try self.compile_expr(b.right), .is_membership = false } });
                        return;
                    }
                    if (is_init and b.left.* == .ident) {
                        const name = b.left.*.ident;
                        const index = self.evaluator.find_variable(name) orelse
                            return Error.UndefinedSymbol;
                        try steps.append(std.heap.page_allocator, ActionStep{ .assign_var = .{ .var_name = name, .var_index = index, .expr = try self.compile_expr(b.right), .is_membership = false } });
                        return;
                    }
                }
                if (b.op == .in) {
                    if (is_init and b.left.* == .ident) {
                        const name = b.left.*.ident;
                        const index = self.evaluator.find_variable(name) orelse
                            return Error.UndefinedSymbol;
                        try steps.append(std.heap.page_allocator, ActionStep{ .assign_var = .{ .var_name = name, .var_index = index, .expr = try self.compile_expr(b.right), .is_membership = true } });
                        return;
                    }
                    if (!is_init and b.left.* == .primed) {
                        const name = b.left.*.primed;
                        const index = self.evaluator.find_variable(name) orelse
                            return Error.UndefinedSymbol;
                        try steps.append(std.heap.page_allocator, ActionStep{ .assign_prime = .{ .var_name = name, .var_index = index, .expr = try self.compile_expr(b.right), .is_membership = true } });
                        return;
                    }
                }
                try steps.append(std.heap.page_allocator, ActionStep{ .condition = try self.compile_expr(expr) });
            },
            .ident => |name| {
                if (self.evaluator.find_constant(name) != null) {
                    try steps.append(
                        std.heap.page_allocator,
                        ActionStep{ .condition = try self.compile_expr(expr) },
                    );
                } else if (self.evaluator.find_definition(name)) |def| {
                    try steps.append(
                        std.heap.page_allocator,
                        ActionStep{ .mark_action = .{
                            .name = name,
                            .args = &.{},
                        } },
                    );
                    try self.collect_steps(def.body, steps, is_init);
                } else {
                    try steps.append(std.heap.page_allocator, ActionStep{ .condition = try self.compile_expr(expr) });
                }
            },
            .quantifier => |q| {
                if (q.kind == .exists and q.vars.len > 0) {
                    var body_steps = std.ArrayList(ActionStep).empty;
                    defer body_steps.deinit(std.heap.page_allocator);
                    try self.collect_steps(q.body, &body_steps, is_init);
                    const body = try self.dup_slice(ActionStep, body_steps.items);
                    try steps.append(std.heap.page_allocator, try self.compile_existential(q.vars, body));
                    return;
                }
                try steps.append(std.heap.page_allocator, ActionStep{ .condition = try self.compile_expr(expr) });
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
                        .cond = try self.compile_expr(ite.cond),
                        .then_steps = try self.dup_slice(ActionStep, then_steps.items),
                        .else_steps = try self.dup_slice(ActionStep, else_steps.items),
                    } });
                    return;
                }
                try steps.append(std.heap.page_allocator, ActionStep{ .condition = try self.compile_expr(expr) });
            },
            .case_expr => |case| {
                if (!self.is_action_expr(expr)) {
                    try steps.append(std.heap.page_allocator, ActionStep{ .condition = try self.compile_expr(expr) });
                    return;
                }
                const arms = try self.arena.alloc(CaseActionArm, case.arms.len);
                for (case.arms, 0..) |arm, i| {
                    var arm_steps = std.ArrayList(ActionStep).empty;
                    defer arm_steps.deinit(std.heap.page_allocator);
                    try self.collect_steps(arm.value, &arm_steps, is_init);
                    arms[i] = .{
                        .cond = try self.compile_expr(arm.cond),
                        .steps = try self.dup_slice(ActionStep, arm_steps.items),
                    };
                }
                const otherwise_steps: ?[]const ActionStep = if (case.otherwise) |otherwise| blk: {
                    var otherwise_list = std.ArrayList(ActionStep).empty;
                    defer otherwise_list.deinit(std.heap.page_allocator);
                    try self.collect_steps(otherwise, &otherwise_list, is_init);
                    break :blk try self.dup_slice(ActionStep, otherwise_list.items);
                } else null;
                try steps.append(std.heap.page_allocator, .{ .case_branch = .{
                    .arms = arms,
                    .otherwise_steps = otherwise_steps,
                } });
            },
            .let_in => |l| {
                if (self.evaluator.generated_expression_count() == 0) {
                    var body = l.body;
                    var let_names = std.ArrayList([]const u8).empty;
                    defer let_names.deinit(std.heap.page_allocator);
                    var let_exprs = std.ArrayList(*ast.Expr).empty;
                    defer let_exprs.deinit(std.heap.page_allocator);
                    for (l.defs) |def| {
                        var def_body = def.body;
                        for (
                            let_names.items,
                            let_exprs.items,
                        ) |name, local_expr| {
                            def_body = try inline_expr(
                                self.arena,
                                def_body,
                                &.{name},
                                &.{local_expr},
                            );
                        }
                        if (def.params.len == 0 and !def.is_function) {
                            try let_names.append(
                                std.heap.page_allocator,
                                def.name,
                            );
                            try let_exprs.append(
                                std.heap.page_allocator,
                                def_body,
                            );
                            body = try inline_expr(
                                self.arena,
                                body,
                                &.{def.name},
                                &.{def_body},
                            );
                        } else {
                            if (def.params.len > 0 and !def.is_function) {
                                body = try inline_local_operator_call(
                                    self.arena,
                                    body,
                                    def,
                                );
                            }
                            const binding = if (def.params.len > 0)
                                try self.lambda_expr(
                                    def.params,
                                    def_body,
                                )
                            else
                                def_body;
                            try steps.append(
                                std.heap.page_allocator,
                                ActionStep{ .let_bind = .{
                                    .name = def.name,
                                    .expr = try self.compile_expr(binding),
                                    .operator_arity = null,
                                } },
                            );
                        }
                    }
                    try self.collect_steps(body, steps, is_init);
                    return;
                }
                var action_body = l.body;
                for (l.defs) |def| {
                    if (def.params.len > 0 and !def.is_function) {
                        action_body = try inline_local_operator_call(
                            self.arena,
                            action_body,
                            def,
                        );
                    }
                }
                if (action_body.* == .binary and
                    action_body.binary.op == .and_op)
                {
                    var operands: [256]*ast.Expr = undefined;
                    var operand_count: usize = 0;
                    flatten_conjunction(
                        action_body,
                        &operands,
                        &operand_count,
                    );
                    var emitted: [64]bool = @splat(false);
                    for (operands[0..operand_count]) |operand| {
                        var required: [64]bool = @splat(false);
                        for (l.defs, 0..) |def, definition_index| {
                            if (codegen.expression_references_identifier(
                                operand,
                                def.name,
                            )) {
                                mark_required_let_bindings(
                                    l,
                                    definition_index,
                                    &required,
                                );
                            }
                        }
                        for (l.defs, 0..) |def, definition_index| {
                            if (!required[definition_index] or
                                emitted[definition_index])
                            {
                                continue;
                            }
                            try self.append_generated_let_binding(
                                steps,
                                def,
                            );
                            emitted[definition_index] = true;
                        }
                        try self.collect_steps(operand, steps, is_init);
                    }
                    return;
                }
                for (l.defs) |def| {
                    try self.append_generated_let_binding(steps, def);
                }
                try self.collect_steps(action_body, steps, is_init);
            },
            .apply => |ap| {
                if (ap.func.* == .ident) {
                    const func_name = self.evaluator.resolve_alias(ap.func.*.ident);
                    if (std.mem.eql(u8, func_name, "\\cdot")) {
                        if (is_init or ap.args.len != 2) return Error.TypeError;
                        var left_steps = std.ArrayList(ActionStep).empty;
                        defer left_steps.deinit(std.heap.page_allocator);
                        try self.collect_steps(ap.args[0], &left_steps, false);
                        var right_steps = std.ArrayList(ActionStep).empty;
                        defer right_steps.deinit(std.heap.page_allocator);
                        try self.collect_steps(ap.args[1], &right_steps, false);
                        try steps.append(std.heap.page_allocator, .{
                            .compose = .{
                                .left_steps = try self.dup_slice(
                                    ActionStep,
                                    left_steps.items,
                                ),
                                .right_steps = try self.dup_slice(
                                    ActionStep,
                                    right_steps.items,
                                ),
                            },
                        });
                        return;
                    }
                    if (self.evaluator.find_constant(func_name) != null) {
                        try steps.append(
                            std.heap.page_allocator,
                            ActionStep{ .condition = try self.compile_expr(expr) },
                        );
                        return;
                    }
                    if (self.is_constant_replacement(func_name)) {
                        try steps.append(
                            std.heap.page_allocator,
                            ActionStep{ .condition = try self.compile_expr(expr) },
                        );
                        return;
                    }
                    if (self.evaluator.find_definition(func_name)) |def| {
                        if (def.params.len == ap.args.len) {
                            const mark_args = try self.compile_exprs(ap.args);
                            try steps.append(
                                std.heap.page_allocator,
                                ActionStep{ .mark_action = .{
                                    .name = func_name,
                                    .args = mark_args,
                                } },
                            );
                            if (self.evaluator.generated_expression_count() ==
                                0)
                            {
                                const inlined = try inline_expr(
                                    self.arena,
                                    def.body,
                                    def.params,
                                    ap.args,
                                );
                                try self.collect_steps(
                                    inlined,
                                    steps,
                                    is_init,
                                );
                                return;
                            }
                            var body_steps = std.ArrayList(ActionStep).empty;
                            defer body_steps.deinit(std.heap.page_allocator);
                            try self.collect_steps(
                                def.body,
                                &body_steps,
                                is_init,
                            );
                            try steps.append(
                                std.heap.page_allocator,
                                .{ .call = .{
                                    .def = def,
                                    .args = try self.compile_exprs(ap.args),
                                    .body_steps = try self.dup_slice(
                                        ActionStep,
                                        body_steps.items,
                                    ),
                                } },
                            );
                            return;
                        }
                    }
                }
                try steps.append(std.heap.page_allocator, ActionStep{ .condition = try self.compile_expr(expr) });
            },
            .unchanged => |vars| {
                for (vars) |v| {
                    if (self.evaluator.find_variable(v)) |index| {
                        try steps.append(std.heap.page_allocator, ActionStep{ .unchanged = .{
                            .var_name = v,
                            .var_index = index,
                        } });
                    } else if (self.evaluator.find_definition(v)) |def| {
                        if (def.params.len == 0 and def.body.* == .tuple) {
                            for (def.body.*.tuple) |it| {
                                if (it.* != .ident) return Error.TypeError;
                                const name = it.*.ident;
                                const index = self.evaluator.find_variable(name) orelse
                                    return Error.UndefinedSymbol;
                                try steps.append(std.heap.page_allocator, ActionStep{ .unchanged = .{
                                    .var_name = name,
                                    .var_index = index,
                                } });
                            }
                            continue;
                        }
                        return Error.TypeError;
                    } else {
                        return Error.UndefinedSymbol;
                    }
                }
            },
            .unchanged_expr => {
                try steps.append(std.heap.page_allocator, ActionStep{ .condition = try self.compile_expr(expr) });
            },
            else => {
                try steps.append(std.heap.page_allocator, ActionStep{ .condition = try self.compile_expr(expr) });
            },
        }
    }

    fn append_generated_let_binding(
        self: ActionCompiler,
        steps: *std.ArrayList(ActionStep),
        def: ast.Definition,
    ) !void {
        const use_generated_operator =
            def.params.len > 0 and
            self.evaluator.generated_expression_count() > 0;
        const binding = if (def.params.len > 0 and
            !use_generated_operator)
            try self.lambda_expr(def.params, def.body)
        else
            def.body;
        try steps.append(
            std.heap.page_allocator,
            ActionStep{ .let_bind = .{
                .name = def.name,
                .expr = try self.compile_expr(binding),
                .operator_arity = if (use_generated_operator)
                    @intCast(def.params.len)
                else
                    null,
            } },
        );
    }

    fn lambda_expr(self: ActionCompiler, params: []const []const u8, body: *ast.Expr) !*ast.Expr {
        assert(params.len > 0);
        const lambda = try self.arena.alloc_object(ast.Lambda);
        lambda.* = .{
            .params = params,
            .body = body,
        };
        const expr = try self.arena.alloc_object(ast.Expr);
        expr.* = .{ .lambda = lambda };
        return expr;
    }

    fn compile_existential(
        self: ActionCompiler,
        vars: []const ast.BoundVar,
        body_steps: []const ActionStep,
    ) !ActionStep {
        assert(vars.len > 0);
        var nested = body_steps;
        var i = vars.len;
        while (i > 1) {
            i -= 1;
            const wrapper = try self.arena.alloc(ActionStep, 1);
            wrapper[0] = .{ .choose = .{
                .var_name = vars[i].name,
                .domain = try self.compile_expr(vars[i].domain),
                .body_steps = nested,
            } };
            nested = wrapper;
        }
        return .{ .choose = .{
            .var_name = vars[0].name,
            .domain = try self.compile_expr(vars[0].domain),
            .body_steps = nested,
        } };
    }

    fn dup_slice(self: ActionCompiler, comptime T: type, items: []const T) ![]const T {
        const copy = try self.arena.alloc(T, items.len);
        @memcpy(copy, items);
        return copy;
    }
};

fn flatten_conjunction(
    expr: *ast.Expr,
    operands: *[256]*ast.Expr,
    count: *usize,
) void {
    if (expr.* == .binary and expr.binary.op == .and_op) {
        flatten_conjunction(expr.binary.left, operands, count);
        flatten_conjunction(expr.binary.right, operands, count);
        return;
    }
    assert(count.* < operands.len);
    operands[count.*] = expr;
    count.* += 1;
}

fn mark_required_let_bindings(
    let_value: *const ast.LetIn,
    definition_index: usize,
    required: *[64]bool,
) void {
    assert(definition_index < let_value.defs.len);
    if (required[definition_index]) return;
    required[definition_index] = true;
    const body = let_value.defs[definition_index].body;
    for (let_value.defs[0..definition_index], 0..) |
        dependency,
        dependency_index,
    | {
        if (codegen.expression_references_identifier(
            body,
            dependency.name,
        )) {
            mark_required_let_bindings(
                let_value,
                dependency_index,
                required,
            );
        }
    }
}

pub const ActionExecutor = struct {
    evaluator: Evaluator,
    source_state_store: *StateStore,
    candidate_store: *StateStore,
    eval_pool: *ValuePool,
    compose_states: ?*StateBuffer = null,
    composition_generated: ?*u64 = null,
    fairness_markers: []const FairnessMarker = &.{},
    edge_action_masks: ?[]u64 = null,

    const Continuation = struct {
        steps: []const ActionStep,
        next: ?*const Continuation,
    };

    pub fn execute_init(
        self: ActionExecutor,
        compiled: CompiledInit,
        out_states: *StateBuffer,
    ) !void {
        assert(compiled.steps.len >= 0);
        assert(out_states.items.len == 0);
        self.evaluator.reset_context_pool();
        try self.execute_steps(compiled.steps, null, Context.empty(), null, out_states, true, 0);
    }

    pub fn execute_next(
        self: ActionExecutor,
        compiled: CompiledNext,
        s0_idx: u32,
        out_states: *StateBuffer,
    ) !void {
        const s0 = self.source_state_store.get(s0_idx);
        self.evaluator.reset_context_pool();
        try self.execute_steps(compiled.steps, null, Context.empty(), s0, out_states, false, 0);
    }

    fn eval_compiled_expr(
        self: ActionExecutor,
        compiled: CompiledExpr,
        context: Context,
        state: ?*StateStore.State,
    ) !Value {
        if (compiled.generated) |generated| generated: {
            if (!generated_args_available(generated, context)) {
                break :generated;
            }
            return self.evaluator.eval_generated_expression(
                generated,
                context,
                state,
                self.eval_pool,
                &self.source_state_store.values_pool,
            );
        }
        return self.evaluator.eval_expr(
            compiled.expr,
            context,
            state,
            self.eval_pool,
            &self.source_state_store.values_pool,
        );
    }

    fn eval_compiled_bool(
        self: ActionExecutor,
        compiled: CompiledExpr,
        context: Context,
        state: ?*StateStore.State,
    ) !bool {
        if (compiled.generated) |generated| generated: {
            if (!generated_args_available(generated, context)) {
                break :generated;
            }
            return self.evaluator.eval_generated_expression_bool(
                generated,
                context,
                state,
                self.eval_pool,
                &self.source_state_store.values_pool,
            );
        }
        const result = try self.evaluator.eval_expr(
            compiled.expr,
            context,
            state,
            self.eval_pool,
            &self.source_state_store.values_pool,
        );
        return result.is_truthy();
    }

    fn generated_args_available(
        generated: generated_runtime.Expression,
        context: Context,
    ) bool {
        if (generated.arg_names.len == 0) return true;
        for (generated.arg_names) |name| {
            if (context.lookup(name) == null) return false;
        }
        return true;
    }

    fn execute_steps(
        self: ActionExecutor,
        steps: []const ActionStep,
        continuation: ?*const Continuation,
        ctx: Context,
        s0: ?*StateStore.State,
        out_states: *StateBuffer,
        is_init: bool,
        action_mask: u64,
    ) !void {
        assert(self.eval_pool.value_count <= self.eval_pool.value_cap);
        assert(self.source_state_store.values_pool.value_count <=
            self.source_state_store.values_pool.value_cap);
        assert(self.candidate_store.values_pool.value_count <=
            self.candidate_store.values_pool.value_cap);
        var current_steps = steps;
        var current_ctx = ctx;
        while (true) {
            if (current_steps.len == 0) {
                if (continuation) |next| {
                    try self.execute_steps(
                        next.steps,
                        next.next,
                        current_ctx,
                        s0,
                        out_states,
                        is_init,
                        action_mask,
                    );
                    return;
                }
                try self.commit_state(
                    current_ctx,
                    s0,
                    out_states,
                    is_init,
                    action_mask,
                );
                return;
            }
            const step = current_steps[0];
            const rest = current_steps[1..];
            assert(rest.len == current_steps.len - 1);
            switch (step) {
                .assign_var => |a| {
                    const val = try self.eval_compiled_expr(a.expr, current_ctx, s0);
                    if (a.is_membership and val.is_set_like()) {
                        const mat = try self.evaluator.materialize_set(val, current_ctx, s0, self.eval_pool, &self.source_state_store.values_pool);
                        if (mat != .set_v) return Error.TypeError;
                        const items = mat.set_v.items(self.eval_pool);
                        const snap = self.eval_pool.snapshot();
                        const context_snap = self.evaluator.context_snapshot();
                        for (items) |it| {
                            const new_ctx = try self.evaluator.extend_state_context(
                                current_ctx,
                                a.var_name,
                                a.var_index,
                                it,
                                .changed,
                            );
                            try self.execute_steps(rest, continuation, new_ctx, s0, out_states, is_init, action_mask);
                            self.eval_pool.restore(snap);
                            self.evaluator.restore_context_pool(context_snap);
                        }
                        return;
                    } else {
                        current_ctx = try self.evaluator.extend_state_context(
                            current_ctx,
                            a.var_name,
                            a.var_index,
                            val,
                            .changed,
                        );
                        current_steps = rest;
                        continue;
                    }
                },
                .assign_prime => |a| {
                    const val = try self.eval_compiled_expr(a.expr, current_ctx, s0);
                    if (a.is_membership and val.is_set_like()) {
                        const mat = try self.evaluator.materialize_set(val, current_ctx, s0, self.eval_pool, &self.source_state_store.values_pool);
                        if (mat != .set_v) return Error.TypeError;
                        const items = mat.set_v.items(self.eval_pool);
                        const snap = self.eval_pool.snapshot();
                        const context_snap = self.evaluator.context_snapshot();
                        for (items) |it| {
                            const new_ctx = try self.evaluator.extend_state_context(
                                current_ctx,
                                a.var_name,
                                a.var_index,
                                it,
                                .changed,
                            );
                            try self.execute_steps(rest, continuation, new_ctx, s0, out_states, is_init, action_mask);
                            self.eval_pool.restore(snap);
                            self.evaluator.restore_context_pool(context_snap);
                        }
                        return;
                    } else {
                        current_ctx = try self.evaluator.extend_state_context(
                            current_ctx,
                            a.var_name,
                            a.var_index,
                            val,
                            .changed,
                        );
                        current_steps = rest;
                        continue;
                    }
                },
                .condition => |e| {
                    if (!try self.eval_compiled_bool(e, current_ctx, s0)) return;
                    current_steps = rest;
                    continue;
                },
                .mark_action => |marker| {
                    current_steps = rest;
                    mask_update: {
                        const additional_mask = try self.fairness_marker_mask(
                            marker,
                            current_ctx,
                            s0,
                        );
                        if (additional_mask == 0) break :mask_update;
                        try self.execute_steps(
                            rest,
                            continuation,
                            current_ctx,
                            s0,
                            out_states,
                            is_init,
                            action_mask | additional_mask,
                        );
                        return;
                    }
                    continue;
                },
                .choose => |c| {
                    const set_v = try self.eval_compiled_expr(c.domain, current_ctx, s0);
                    if (!set_v.is_set_like()) return Error.TypeError;
                    const mat = try self.evaluator.materialize_set(set_v, current_ctx, s0, self.eval_pool, &self.source_state_store.values_pool);
                    if (mat != .set_v) return Error.TypeError;
                    const items = mat.set_v.items(self.eval_pool);
                    const next = Continuation{ .steps = rest, .next = continuation };
                    const snap = self.eval_pool.snapshot();
                    const context_snap = self.evaluator.context_snapshot();
                    for (items) |it| {
                        const new_ctx = try self.evaluator.extend_context(current_ctx, c.var_name, it);
                        try self.execute_steps(c.body_steps, &next, new_ctx, s0, out_states, is_init, action_mask);
                        self.eval_pool.restore(snap);
                        self.evaluator.restore_context_pool(context_snap);
                    }
                    return;
                },
                .let_bind => |l| {
                    const v = if (l.operator_arity) |arity|
                        try self.evaluator.make_generated_expression_operator(
                            l.expr.generated orelse
                                return Error.NotImplemented,
                            arity,
                            current_ctx,
                            self.eval_pool,
                        )
                    else
                        try self.eval_compiled_expr(
                            l.expr,
                            current_ctx,
                            s0,
                        );
                    current_ctx = try self.evaluator.extend_context(current_ctx, l.name, v);
                    current_steps = rest;
                    continue;
                },
                .call => |c| {
                    if (c.def.params.len != c.args.len) return Error.TypeError;
                    const context_snap = self.evaluator.context_snapshot();
                    const values = try self.eval_pool.alloc_values(@intCast(c.args.len));
                    for (c.args, 0..) |arg, i| {
                        values[i] = try self.eval_compiled_expr(
                            arg,
                            current_ctx,
                            s0,
                        );
                    }
                    var call_ctx = current_ctx;
                    for (c.def.params, 0..) |p, i| {
                        call_ctx = try self.evaluator.extend_context(call_ctx, p, values[i]);
                    }
                    const next = Continuation{ .steps = rest, .next = continuation };
                    const snap = self.eval_pool.snapshot();
                    try self.execute_steps(c.body_steps, &next, call_ctx, s0, out_states, is_init, action_mask);
                    self.eval_pool.restore(snap);
                    self.evaluator.restore_context_pool(context_snap);
                    return;
                },
                .compose => |composition| {
                    const intermediates = self.compose_states orelse
                        return Error.NotImplemented;
                    assert(intermediates.items.len == 0);
                    const left_context_snapshot = self.evaluator.context_snapshot();
                    try self.execute_steps(
                        composition.left_steps,
                        null,
                        current_ctx,
                        s0,
                        intermediates,
                        false,
                        action_mask,
                    );
                    self.evaluator.restore_context_pool(left_context_snapshot);
                    const next = Continuation{
                        .steps = rest,
                        .next = continuation,
                    };
                    const snapshot = self.eval_pool.snapshot();
                    const context_snapshot = self.evaluator.context_snapshot();
                    const intermediate_items = intermediates.items;
                    if (self.composition_generated) |generated| {
                        generated.* += intermediate_items.len;
                    }
                    for (intermediate_items) |intermediate_idx| {
                        assert(intermediate_idx < self.candidate_store.count);
                        var second = ActionExecutor{
                            .evaluator = self.evaluator,
                            .source_state_store = self.candidate_store,
                            .candidate_store = self.candidate_store,
                            .eval_pool = self.eval_pool,
                            .compose_states = null,
                            .composition_generated = self.composition_generated,
                            .fairness_markers = self.fairness_markers,
                            .edge_action_masks = self.edge_action_masks,
                        };
                        try second.execute_steps(
                            composition.right_steps,
                            &next,
                            current_ctx,
                            self.candidate_store.get(intermediate_idx),
                            out_states,
                            false,
                            action_mask,
                        );
                        self.eval_pool.restore(snapshot);
                        self.evaluator.restore_context_pool(context_snapshot);
                    }
                    intermediates.clear();
                    return;
                },
                .branch => |b| {
                    const next = Continuation{ .steps = rest, .next = continuation };
                    const snap = self.eval_pool.snapshot();
                    const context_snap = self.evaluator.context_snapshot();
                    for (b.options) |opt| {
                        try self.execute_steps(opt, &next, current_ctx, s0, out_states, is_init, action_mask);
                        self.eval_pool.restore(snap);
                        self.evaluator.restore_context_pool(context_snap);
                    }
                    return;
                },
                .if_branch => |ib| {
                    const taken = if (try self.eval_compiled_bool(
                        ib.cond,
                        current_ctx,
                        s0,
                    )) ib.then_steps else ib.else_steps;
                    const next = Continuation{ .steps = rest, .next = continuation };
                    const snap = self.eval_pool.snapshot();
                    const context_snap = self.evaluator.context_snapshot();
                    try self.execute_steps(taken, &next, current_ctx, s0, out_states, is_init, action_mask);
                    self.eval_pool.restore(snap);
                    self.evaluator.restore_context_pool(context_snap);
                    return;
                },
                .case_branch => |case| {
                    const next = Continuation{ .steps = rest, .next = continuation };
                    const snap = self.eval_pool.snapshot();
                    const context_snap = self.evaluator.context_snapshot();
                    for (case.arms) |arm| {
                        if (!try self.eval_compiled_bool(
                            arm.cond,
                            current_ctx,
                            s0,
                        )) {
                            self.eval_pool.restore(snap);
                            self.evaluator.restore_context_pool(context_snap);
                            continue;
                        }
                        try self.execute_steps(arm.steps, &next, current_ctx, s0, out_states, is_init, action_mask);
                        self.eval_pool.restore(snap);
                        self.evaluator.restore_context_pool(context_snap);
                        return;
                    }
                    if (case.otherwise_steps) |otherwise| {
                        try self.execute_steps(otherwise, &next, current_ctx, s0, out_states, is_init, action_mask);
                        self.eval_pool.restore(snap);
                        self.evaluator.restore_context_pool(context_snap);
                    }
                    return;
                },
                .unchanged => |unchanged| {
                    if (s0 == null) return Error.TypeError;
                    const source_state = s0.?;
                    assert(unchanged.var_index < source_state.values.len);
                    const source_pool = source_state.value_pool(
                        unchanged.var_index,
                        &self.source_state_store.values_pool,
                    );
                    current_ctx = try self.evaluator.extend_state_context_from_pool(
                        current_ctx,
                        unchanged.var_name,
                        unchanged.var_index,
                        source_state.values[unchanged.var_index],
                        source_pool,
                        .unchanged,
                    );
                    current_steps = rest;
                    continue;
                },
            }
        }
    }

    fn fairness_marker_mask(
        self: ActionExecutor,
        marker: MarkAction,
        ctx: Context,
        s0: ?*StateStore.State,
    ) !u64 {
        if (self.fairness_markers.len == 0) return 0;
        assert(self.fairness_markers.len <= 64);
        var mask: u64 = 0;
        for (self.fairness_markers) |fairness| {
            if (try self.fairness_marker_matches(
                marker,
                fairness,
                ctx,
                s0,
            )) {
                mask |= @as(u64, 1) << fairness.bit_index;
            }
        }
        return mask;
    }

    fn fairness_marker_matches(
        self: ActionExecutor,
        marker: MarkAction,
        fairness: FairnessMarker,
        ctx: Context,
        s0: ?*StateStore.State,
    ) !bool {
        switch (fairness.action.*) {
            .ident => |name| {
                if (!std.mem.eql(u8, marker.name, name)) return false;
                if (marker.args.len != 0) return false;
            },
            .apply => |ap| {
                if (ap.func.* != .ident) return false;
                if (!std.mem.eql(u8, marker.name, ap.func.*.ident)) {
                    return false;
                }
                if (marker.args.len != ap.args.len) return false;
                var i: usize = 0;
                while (i < marker.args.len) : (i += 1) {
                    const actual = try self.eval_compiled_expr(
                        marker.args[i],
                        ctx,
                        s0,
                    );
                    const expected = try self.eval_fairness_arg(
                        ap.args[i],
                        fairness.bindings,
                    );
                    if (!Value.eql_cross_pool(
                        actual,
                        self.eval_pool,
                        expected,
                        self.eval_pool,
                    )) return false;
                }
            },
            else => return false,
        }
        return try self.fairness_bindings_match(fairness.bindings, ctx);
    }

    fn eval_fairness_arg(
        self: ActionExecutor,
        expr: *ast.Expr,
        bindings: []const FairnessBinding,
    ) !Value {
        if (expr.* == .ident) {
            for (bindings) |binding| {
                if (std.mem.eql(u8, expr.*.ident, binding.name)) {
                    return binding.value;
                }
            }
        }
        const context_snapshot = self.evaluator.context_snapshot();
        defer self.evaluator.restore_context_pool(context_snapshot);
        var fairness_ctx = Context.empty();
        for (bindings) |binding| {
            fairness_ctx = try self.evaluator.extend_context(
                fairness_ctx,
                binding.name,
                binding.value,
            );
        }
        return self.evaluator.eval_expr(
            expr,
            fairness_ctx,
            null,
            self.eval_pool,
            &self.source_state_store.values_pool,
        );
    }

    fn fairness_bindings_match(
        self: ActionExecutor,
        bindings: []const FairnessBinding,
        ctx: Context,
    ) !bool {
        for (bindings) |binding| {
            const actual = (try ctx.lookup_value(binding.name, self.eval_pool)) orelse
                return false;
            if (!Value.eql_cross_pool(
                actual,
                self.eval_pool,
                binding.value,
                self.eval_pool,
            )) return false;
        }
        return true;
    }

    fn commit_state(
        self: ActionExecutor,
        ctx: Context,
        s0: ?*StateStore.State,
        out_states: *StateBuffer,
        is_init: bool,
        action_mask: u64,
    ) !void {
        _ = is_init;
        const new_idx = try self.candidate_store.alloc_state();
        const new_state = self.candidate_store.get(new_idx);
        if (s0) |parent| {
            new_state.level = parent.level + 1;
            const pred_idx = @divExact(
                @intFromPtr(parent) - @intFromPtr(self.source_state_store.states.ptr),
                @sizeOf(StateStore.State),
            );
            new_state.pred = @intCast(pred_idx);
        } else {
            new_state.level = 0;
            new_state.pred = 0;
        }
        new_state.changed_mask = 0;
        new_state.borrowed_mask = 0;
        new_state.borrowed_pool = null;
        var assignments: [64]?eval.StateContextValue = @splat(null);
        assert(new_state.values.len <= assignments.len);
        ctx.collect_state_assignments(assignments[0..new_state.values.len]);
        for (new_state.values, 0..) |*destination, variable_index| {
            if (assignments[variable_index]) |assigned| {
                if (assigned.assignment == .changed) {
                    new_state.changed_mask |= @as(u64, 1) << @intCast(variable_index);
                    const source_pool = assigned.value_pool orelse
                        self.eval_pool;
                    destination.* = try assigned.value.clone(
                        source_pool,
                        &self.candidate_store.values_pool,
                    );
                    assert(Value.eql_cross_pool(
                        assigned.value,
                        source_pool,
                        destination.*,
                        &self.candidate_store.values_pool,
                    ));
                } else if (s0) |parent| {
                    destination.* = parent.values[variable_index];
                    const parent_pool = parent.value_pool(
                        @intCast(variable_index),
                        &self.source_state_store.values_pool,
                    );
                    if (parent_pool !=
                        &self.candidate_store.values_pool)
                    {
                        new_state.borrowed_mask |=
                            @as(u64, 1) << @intCast(variable_index);
                        assert(new_state.borrowed_pool == null or
                            new_state.borrowed_pool == parent_pool);
                        new_state.borrowed_pool = parent_pool;
                    }
                } else {
                    const source_pool = assigned.value_pool orelse
                        self.eval_pool;
                    destination.* = try assigned.value.clone(
                        source_pool,
                        &self.candidate_store.values_pool,
                    );
                }
            } else if (s0) |parent| {
                destination.* = parent.values[variable_index];
                const parent_pool = parent.value_pool(
                    @intCast(variable_index),
                    &self.source_state_store.values_pool,
                );
                if (parent_pool != &self.candidate_store.values_pool) {
                    new_state.borrowed_mask |=
                        @as(u64, 1) << @intCast(variable_index);
                    assert(new_state.borrowed_pool == null or
                        new_state.borrowed_pool == parent_pool);
                    new_state.borrowed_pool = parent_pool;
                }
            } else {
                destination.* = Value{ .bool_v = false };
            }
        }
        if (self.edge_action_masks) |masks| {
            assert(out_states.items.len < masks.len);
            masks[out_states.items.len] = action_mask;
        }
        try out_states.append(new_idx);
    }
};
