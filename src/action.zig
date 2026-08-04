const std = @import("std");
const builtin = @import("builtin");
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
const set_patterns = @import("set_patterns.zig");

const InlinedBoundExpression = struct {
    vars: []const ast.BoundVar,
    body: *ast.Expr,
};

const Substitutions = struct {
    params: []const []const u8,
    args: []const *ast.Expr,
};

fn filtered_substitutions(
    arena: *Arena,
    params: []const []const u8,
    args: []const *ast.Expr,
    bound_vars: []const ast.BoundVar,
    bound_count: usize,
) Error!Substitutions {
    assert(params.len == args.len);
    assert(bound_count <= bound_vars.len);
    const filtered_params = try arena.alloc([]const u8, params.len);
    const filtered_args = try arena.alloc(*ast.Expr, args.len);
    var count: usize = 0;
    for (params, args) |parameter, argument| {
        var shadowed = false;
        for (bound_vars[0..bound_count]) |bound| {
            if (std.mem.eql(u8, parameter, bound.name)) {
                shadowed = true;
                break;
            }
        }
        if (shadowed) continue;
        filtered_params[count] = parameter;
        filtered_args[count] = argument;
        count += 1;
    }
    return .{
        .params = filtered_params[0..count],
        .args = filtered_args[0..count],
    };
}

fn arguments_reference_identifier(
    args: []const *ast.Expr,
    name: []const u8,
) bool {
    for (args) |argument| {
        if (codegen.expression_references_identifier(argument, name)) {
            return true;
        }
    }
    return false;
}

fn value_offset(pool: *const ValuePool, pointer: [*]Value) u32 {
    const base = @intFromPtr(pool.values.ptr);
    const address = @intFromPtr(pointer);
    assert(address >= base);
    const bytes = address - base;
    assert(bytes % @sizeOf(Value) == 0);
    const offset: u32 = @intCast(bytes / @sizeOf(Value));
    assert(offset <= pool.value_count);
    return offset;
}

fn inline_bound_expression(
    arena: *Arena,
    owner: *const anyopaque,
    vars: []const ast.BoundVar,
    body: *ast.Expr,
    params: []const []const u8,
    args: []const *ast.Expr,
) Error!InlinedBoundExpression {
    assert(params.len == args.len);
    const result_vars = try arena.alloc(ast.BoundVar, vars.len);
    const domains = try arena.alloc(*ast.Expr, vars.len);
    for (vars, 0..) |bound, index| domains[index] = bound.domain;
    var result_body = body;

    for (vars, 0..) |bound, index| {
        var result_name = bound.name;
        if (arguments_reference_identifier(args, bound.name)) {
            var name_buffer: [96]u8 = undefined;
            const fresh_name = std.fmt.bufPrint(
                &name_buffer,
                "__tlzig_bound_{x}_{d}",
                .{ @intFromPtr(owner), index },
            ) catch return Error.OutOfMemory;
            result_name = try arena.dup(fresh_name);
            const fresh_ident = try arena.alloc_object(ast.Expr);
            fresh_ident.* = .{ .ident = result_name };
            result_body = try inline_expr(
                arena,
                result_body,
                &.{bound.name},
                &.{fresh_ident},
            );
            for (domains[index + 1 ..]) |*domain| {
                domain.* = try inline_expr(
                    arena,
                    domain.*,
                    &.{bound.name},
                    &.{fresh_ident},
                );
            }
        } else {
            result_name = try arena.dup(result_name);
        }
        const domain_substitutions = try filtered_substitutions(
            arena,
            params,
            args,
            vars,
            index,
        );
        result_vars[index] = .{
            .name = result_name,
            .domain = try inline_expr(
                arena,
                domains[index],
                domain_substitutions.params,
                domain_substitutions.args,
            ),
        };
    }

    const body_substitutions = try filtered_substitutions(
        arena,
        params,
        args,
        vars,
        vars.len,
    );
    return .{
        .vars = result_vars,
        .body = try inline_expr(
            arena,
            result_body,
            body_substitutions.params,
            body_substitutions.args,
        ),
    };
}

fn inline_expr(
    arena: *Arena,
    expr: *ast.Expr,
    params: []const []const u8,
    args: []const *ast.Expr,
) Error!*ast.Expr {
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
            for (params, 0..) |param, i| {
                if (!std.mem.eql(u8, name, param)) continue;
                const ptr = try arena.alloc_object(ast.Expr);
                if (args[i].* == .ident) {
                    ptr.* = .{ .primed = try arena.dup(args[i].ident) };
                } else {
                    ptr.* = .{ .primed_expr = try inline_expr(
                        arena,
                        args[i],
                        params,
                        args,
                    ) };
                }
                return ptr;
            }
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
            var result: ?*ast.Expr = null;
            for (names) |name| {
                const item = try arena.alloc_object(ast.Expr);
                var substituted = false;
                for (params, 0..) |param, i| {
                    if (!std.mem.eql(u8, name, param)) continue;
                    if (args[i].* == .ident) {
                        const one = try arena.alloc([]const u8, 1);
                        one[0] = try arena.dup(args[i].ident);
                        item.* = .{ .unchanged = one };
                    } else {
                        item.* = .{ .unchanged_expr = try inline_expr(
                            arena,
                            args[i],
                            params,
                            args,
                        ) };
                    }
                    substituted = true;
                    break;
                }
                if (!substituted) {
                    const one = try arena.alloc([]const u8, 1);
                    one[0] = try arena.dup(name);
                    item.* = .{ .unchanged = one };
                }
                if (result) |left| {
                    const binary = try arena.alloc_object(ast.Binary);
                    binary.* = .{
                        .op = .and_op,
                        .left = left,
                        .right = item,
                    };
                    const combined = try arena.alloc_object(ast.Expr);
                    combined.* = .{ .binary = binary };
                    result = combined;
                } else {
                    result = item;
                }
            }
            if (result) |expression| return expression;
            const empty = try arena.alloc_object(ast.Expr);
            empty.* = .{ .unchanged = &.{} };
            return empty;
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
                vars[i] = .{
                    .name = try arena.dup(v.name),
                    .domain = try inline_expr(arena, v.domain, params, args),
                };
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
                vars[i] = .{
                    .name = try arena.dup(v.name),
                    .domain = try inline_expr(arena, v.domain, params, args),
                };
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
            var capture = false;
            for (fl.vars) |bound| {
                if (arguments_reference_identifier(args, bound.name)) {
                    capture = true;
                    break;
                }
            }
            if (capture) {
                const inlined = try inline_bound_expression(
                    arena,
                    fl,
                    fl.vars,
                    fl.body,
                    params,
                    args,
                );
                const flp = try arena.alloc_object(ast.FunctionLiteral);
                flp.* = .{ .vars = inlined.vars, .body = inlined.body };
                const ptr = try arena.alloc_object(ast.Expr);
                ptr.* = .{ .function_literal = flp };
                return ptr;
            }
            const vars = try arena.alloc(ast.BoundVar, fl.vars.len);
            for (fl.vars, 0..) |v, i| {
                vars[i] = .{
                    .name = try arena.dup(v.name),
                    .domain = try inline_expr(arena, v.domain, params, args),
                };
            }
            const flp = try arena.alloc_object(ast.FunctionLiteral);
            flp.* = .{
                .vars = vars,
                .body = try inline_expr(arena, fl.body, params, args),
            };
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
                .domain = if (c.domain) |domain|
                    try inline_expr(arena, domain, params, args)
                else
                    null,
                .body = try inline_expr(arena, c.body, params, args),
            };
            const ptr = try arena.alloc_object(ast.Expr);
            ptr.* = .{ .choose = cp };
            return ptr;
        },
        .let_in => |l| {
            if (l.defs.len > 64) return Error.NotImplemented;
            var renamed_from: [64][]const u8 = undefined;
            var renamed_to: [64]*ast.Expr = undefined;
            var renamed_count: usize = 0;
            for (l.defs, 0..) |def, definition_index| {
                var collides = false;
                for (args) |argument| {
                    if (codegen.expression_references_identifier(
                        argument,
                        def.name,
                    )) {
                        collides = true;
                        break;
                    }
                }
                if (!collides) continue;
                var name_buffer: [96]u8 = undefined;
                const fresh_name = std.fmt.bufPrint(
                    &name_buffer,
                    "__tlzig_inline_{x}_{d}",
                    .{ @intFromPtr(l), definition_index },
                ) catch return Error.OutOfMemory;
                const fresh_ident = try arena.alloc_object(ast.Expr);
                fresh_ident.* = .{ .ident = try arena.dup(fresh_name) };
                renamed_from[renamed_count] = def.name;
                renamed_to[renamed_count] = fresh_ident;
                renamed_count += 1;
            }

            const defs = try arena.alloc(ast.Definition, l.defs.len);
            for (l.defs, 0..) |def, i| {
                var definition_body = def.body;
                for (0..renamed_count) |rename_index| {
                    definition_body = try inline_expr(
                        arena,
                        definition_body,
                        &.{renamed_from[rename_index]},
                        &.{renamed_to[rename_index]},
                    );
                }
                var definition_name = def.name;
                for (0..renamed_count) |rename_index| {
                    if (std.mem.eql(
                        u8,
                        definition_name,
                        renamed_from[rename_index],
                    )) {
                        definition_name = renamed_to[rename_index].ident;
                        break;
                    }
                }
                defs[i] = .{
                    .name = try arena.dup(definition_name),
                    .params = blk: {
                        const copy = try arena.alloc([]const u8, def.params.len);
                        for (def.params, 0..) |p, j| copy[j] = try arena.dup(p);
                        break :blk copy;
                    },
                    .body = try inline_expr(
                        arena,
                        definition_body,
                        params,
                        args,
                    ),
                };
            }
            var let_body = l.body;
            for (0..renamed_count) |rename_index| {
                let_body = try inline_expr(
                    arena,
                    let_body,
                    &.{renamed_from[rename_index]},
                    &.{renamed_to[rename_index]},
                );
            }
            const lp = try arena.alloc_object(ast.LetIn);
            lp.* = .{
                .defs = defs,
                .body = try inline_expr(arena, let_body, params, args),
            };
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
            for (l.params, 0..) |parameter, index| {
                params_copy[index] = try arena.dup(parameter);
            }
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
    enabled_check: EnabledCheck,
    mark_action: MarkAction,
    choose: Choose,
    bounded_power_set_choose: BoundedPowerSetChoose,
    branch: Branch,
    if_branch: IfBranch,
    case_branch: CaseBranch,
    call: Call,
    compose: Composition,
    let_bind: LetBind,
    unchanged: Unchanged,
};

pub fn steps_contain_composition(steps: []const ActionStep) bool {
    return steps_contain_composition_depth(steps, 0);
}

fn steps_contain_composition_depth(
    steps: []const ActionStep,
    depth: u32,
) bool {
    if (depth >= 64) return true;
    for (steps) |step| {
        const nested = switch (step) {
            .compose => return true,
            .enabled_check => |enabled| steps_contain_composition_depth(
                enabled.steps,
                depth + 1,
            ),
            .choose => |choose| steps_contain_composition_depth(
                choose.body_steps,
                depth + 1,
            ),
            .bounded_power_set_choose => |choose| steps_contain_composition_depth(
                choose.body_steps,
                depth + 1,
            ),
            .branch => |branch| blk: {
                for (branch.options) |option| {
                    if (steps_contain_composition_depth(option, depth + 1)) {
                        break :blk true;
                    }
                }
                break :blk false;
            },
            .if_branch => |conditional| steps_contain_composition_depth(
                conditional.then_steps,
                depth + 1,
            ) or steps_contain_composition_depth(
                conditional.else_steps,
                depth + 1,
            ),
            .case_branch => |case_branch| blk: {
                for (case_branch.arms) |arm| {
                    if (steps_contain_composition_depth(arm.steps, depth + 1)) {
                        break :blk true;
                    }
                }
                if (case_branch.otherwise_steps) |otherwise| {
                    if (steps_contain_composition_depth(otherwise, depth + 1)) {
                        break :blk true;
                    }
                }
                break :blk false;
            },
            .call => |call| steps_contain_composition_depth(
                call.body_steps,
                depth + 1,
            ),
            .assign_var,
            .assign_prime,
            .condition,
            .mark_action,
            .let_bind,
            .unchanged,
            => false,
        };
        if (nested) return true;
    }
    return false;
}

pub const AssignVar = struct {
    var_name: []const u8,
    var_index: u32,
    expr: CompiledExpr,
    is_membership: bool,
};

pub const AssignPrime = AssignVar;

pub const Unchanged = struct {
    var_name: []const u8,
    var_index: u32,
};

pub const CompiledExpr = struct {
    expr: *ast.Expr,
    generated: ?*const generated_runtime.Expression,
};

pub const MarkAction = struct {
    name: []const u8,
    args: []const CompiledExpr,
};

pub const EnabledCheck = struct {
    steps: []const ActionStep,
    expected: bool,
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

pub const BoundedPowerSetChoose = struct {
    var_name: []const u8,
    base: CompiledExpr,
    upper: CompiledExpr,
    lower: ?CompiledExpr,
    body_steps: []const ActionStep,
};

pub const ActionStateArgument = struct {
    variable_name: []const u8,
    variable_index: u32,
    primed: bool,
};

const ActionParameterBinding = struct {
    name: []const u8,
    state_argument: ?ActionStateArgument,
};

pub const Call = struct {
    name: []const u8,
    params: []const []const u8,
    args: []const CompiledExpr,
    state_args: []const ?ActionStateArgument,
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

pub const CandidateSink = struct {
    target: *StateBuffer,
    context: *anyopaque,
    consume: *const fn (*anyopaque, *StateBuffer) Error!void,
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
    canonical_names: *CanonicalNames,
    action_parameters: []const ActionParameterBinding = &.{},

    const CanonicalNames = struct {
        arena: *Arena,
        names: [][]const u8,
        count: u16 = 0,

        fn init(arena: *Arena) !CanonicalNames {
            return .{
                .arena = arena,
                .names = try arena.alloc([]const u8, 4096),
            };
        }

        fn intern(self: *CanonicalNames, name: []const u8) ![]const u8 {
            assert(self.count <= self.names.len);
            for (self.names[0..self.count]) |existing| {
                if (std.mem.eql(u8, existing, name)) return existing;
            }
            if (self.count >= self.names.len) return Error.OutOfMemory;
            const canonical = try self.arena.dup(name);
            self.names[self.count] = canonical;
            self.count += 1;
            return canonical;
        }
    };

    pub fn init(arena: *Arena, evaluator: Evaluator) !ActionCompiler {
        const canonical_names = try arena.alloc_object(CanonicalNames);
        canonical_names.* = try CanonicalNames.init(arena);
        return .{
            .arena = arena,
            .evaluator = evaluator,
            .canonical_names = canonical_names,
            .action_parameters = &.{},
        };
    }

    pub fn compile_init(self: ActionCompiler, expr: *ast.Expr) !CompiledInit {
        var steps = std.ArrayList(ActionStep).empty;
        defer steps.deinit(std.heap.page_allocator);
        try self.collect_steps(expr, &steps, true);
        const compiled = CompiledInit{
            .steps = try self.dup_slice(ActionStep, steps.items),
        };
        if (std.c.getenv("TLZIG_DUMP_ACTION_STEPS") != null) {
            dump_action_steps("INIT", compiled.steps, 0);
        }
        return compiled;
    }

    pub fn compile_next(self: ActionCompiler, expr: *ast.Expr) !CompiledNext {
        var steps = std.ArrayList(ActionStep).empty;
        defer steps.deinit(std.heap.page_allocator);
        try self.collect_steps(expr, &steps, false);
        const compiled = CompiledNext{
            .steps = try self.dup_slice(ActionStep, steps.items),
        };
        if (std.c.getenv("TLZIG_DUMP_ACTION_STEPS") != null) {
            dump_action_steps("NEXT", compiled.steps, 0);
        }
        return compiled;
    }

    fn is_constant_replacement(self: ActionCompiler, name: []const u8) bool {
        for (self.evaluator.module.config_replacements) |replacement| {
            if (std.mem.eql(u8, replacement.name, name)) {
                return replacement.kind == .constant;
            }
        }
        return false;
    }

    fn action_parameter(
        self: ActionCompiler,
        name: []const u8,
    ) ?ActionParameterBinding {
        for (self.action_parameters) |binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding;
        }
        return null;
    }

    fn module_state_argument(
        self: ActionCompiler,
        name: []const u8,
        primed: bool,
    ) ?ActionStateArgument {
        const resolved = self.evaluator.resolve_alias(name);
        const index = self.evaluator.find_variable(resolved) orelse
            return null;
        assert(index < self.evaluator.module.variables.len);
        return .{
            .variable_name = self.evaluator.module.variables[index],
            .variable_index = index,
            .primed = primed,
        };
    }

    fn resolve_state_argument(
        self: ActionCompiler,
        expr: *const ast.Expr,
    ) ?ActionStateArgument {
        return switch (expr.*) {
            .ident => |name| if (self.action_parameter(name)) |binding|
                binding.state_argument
            else
                self.module_state_argument(name, false),
            .primed => |name| if (self.action_parameter(name)) |binding| blk: {
                var target = binding.state_argument orelse break :blk null;
                if (target.primed) break :blk null;
                target.primed = true;
                break :blk target;
            } else self.module_state_argument(name, true),
            else => null,
        };
    }

    fn assignment_target(
        self: ActionCompiler,
        expr: *const ast.Expr,
        is_init: bool,
    ) ?ActionStateArgument {
        const target = self.resolve_state_argument(expr) orelse return null;
        if (is_init == target.primed) return null;
        return target;
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
        const canonical_generated = if (generated) |expression| generated: {
            const canonical = try self.arena.alloc_object(
                generated_runtime.Expression,
            );
            canonical.* = expression;
            canonical.arg_names = try self.canonical_name_slice(
                expression.arg_names,
            );
            break :generated canonical;
        } else null;
        return .{
            .expr = expr,
            .generated = canonical_generated,
        };
    }

    fn canonical_name(self: ActionCompiler, name: []const u8) ![]const u8 {
        return self.canonical_names.intern(name);
    }

    fn canonical_name_slice(
        self: ActionCompiler,
        names: []const []const u8,
    ) ![]const []const u8 {
        if (names.len == 0) return &.{};
        const canonical = try self.arena.alloc([]const u8, names.len);
        for (names, canonical) |name, *target| {
            target.* = try self.canonical_name(name);
        }
        return canonical;
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

    fn is_action_expr(
        self: ActionCompiler,
        expr: *ast.Expr,
        is_init: bool,
    ) bool {
        var path: [128]*ast.Expr = undefined;
        return self.is_action_expr_inner(expr, &path, 0, is_init);
    }

    fn is_init_action(self: ActionCompiler, expr: *ast.Expr) bool {
        switch (expr.*) {
            .binary => |b| {
                if (b.op == .eq and b.left.* == .ident) {
                    const name = self.evaluator.resolve_alias(b.left.ident);
                    if (self.evaluator.find_variable(name) != null) return true;
                }
                if (b.op == .in and b.left.* == .ident) {
                    const name = self.evaluator.resolve_alias(b.left.ident);
                    if (self.evaluator.find_variable(name) != null) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn is_action_expr_inner(
        self: ActionCompiler,
        expr: *ast.Expr,
        path: *[128]*ast.Expr,
        depth: u8,
        is_init: bool,
    ) bool {
        if (depth >= path.len) return false;
        for (path[0..depth]) |ancestor| {
            if (ancestor == expr) return false;
        }
        path[depth] = expr;
        const next_depth = depth + 1;
        switch (expr.*) {
            .primed, .primed_expr, .unchanged, .unchanged_expr => return true,
            .ident => |name| {
                if (self.action_parameter(name)) |binding| {
                    const target = binding.state_argument orelse return false;
                    return is_init != target.primed;
                }
                const resolved = self.evaluator.resolve_alias(name);
                if (std.c.getenv("TLZIG_DUMP_ACTION_STEPS") != null and
                    !std.mem.eql(u8, name, resolved))
                {
                    std.debug.print("NEXT alias {s} -> {s}\n", .{ name, resolved });
                }
                if (self.is_constant_replacement(resolved)) return false;
                if (self.evaluator.find_constant(resolved) != null) return false;
                if (self.evaluator.find_definition(resolved)) |def| {
                    return self.is_action_expr_inner(
                        def.body,
                        path,
                        next_depth,
                        is_init,
                    );
                }
                return false;
            },
            .binary => |b| {
                return self.is_action_expr_inner(
                    b.left,
                    path,
                    next_depth,
                    is_init,
                ) or self.is_action_expr_inner(
                    b.right,
                    path,
                    next_depth,
                    is_init,
                ) or (is_init and self.is_init_action(expr));
            },
            .let_in => |l| return self.is_action_expr_inner(
                l.body,
                path,
                next_depth,
                is_init,
            ),
            .if_then_else => |ite| return self.is_action_expr_inner(
                ite.then_branch,
                path,
                next_depth,
                is_init,
            ) or self.is_action_expr_inner(
                ite.else_branch,
                path,
                next_depth,
                is_init,
            ),
            .case_expr => |case| {
                for (case.arms) |arm| {
                    if (self.is_action_expr_inner(
                        arm.value,
                        path,
                        next_depth,
                        is_init,
                    )) return true;
                }
                if (case.otherwise) |otherwise| return self.is_action_expr_inner(
                    otherwise,
                    path,
                    next_depth,
                    is_init,
                );
                return false;
            },
            .apply => |ap| {
                if (ap.func.* == .ident) {
                    if (std.mem.eql(u8, ap.func.*.ident, "\\cdot")) {
                        return ap.args.len == 2 and
                            self.is_action_expr_inner(
                                ap.args[0],
                                path,
                                next_depth,
                                is_init,
                            ) and
                            self.is_action_expr_inner(
                                ap.args[1],
                                path,
                                next_depth,
                                is_init,
                            );
                    }
                    if (self.is_constant_replacement(ap.func.*.ident)) {
                        return false;
                    }
                    if (self.evaluator.find_constant(ap.func.*.ident) != null) {
                        return false;
                    }
                    if (self.evaluator.find_definition(ap.func.*.ident)) |def| {
                        return self.is_action_expr_inner(
                            def.body,
                            path,
                            next_depth,
                            is_init,
                        );
                    }
                }
                return false;
            },
            .quantifier => |q| return self.is_action_expr_inner(
                q.body,
                path,
                next_depth,
                is_init,
            ),
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
            .unary => |unary| {
                var enabled_operand: ?*ast.Expr = null;
                var expected = true;
                if (unary.op == .enabled) {
                    enabled_operand = unary.operand;
                } else if (unary.op == .not and
                    unary.operand.* == .unary and
                    unary.operand.unary.op == .enabled)
                {
                    enabled_operand = unary.operand.unary.operand;
                    expected = false;
                }
                if (enabled_operand) |operand| {
                    var enabled_steps = std.ArrayList(ActionStep).empty;
                    defer enabled_steps.deinit(std.heap.page_allocator);
                    try self.collect_steps(operand, &enabled_steps, false);
                    try steps.append(std.heap.page_allocator, .{
                        .enabled_check = .{
                            .steps = try self.dup_slice(
                                ActionStep,
                                enabled_steps.items,
                            ),
                            .expected = expected,
                        },
                    });
                    return;
                }
                try steps.append(std.heap.page_allocator, .{
                    .condition = try self.compile_expr(expr),
                });
            },
            .binary => |b| {
                if (std.c.getenv("TLZIG_DUMP_ACTION_STEPS") != null) {
                    std.debug.print("NEXT binary {s}\n", .{@tagName(b.op)});
                }
                if (b.op == .and_op) {
                    try self.collect_steps(b.left, steps, is_init);
                    try self.collect_steps(b.right, steps, is_init);
                    return;
                }
                if (b.op == .or_op) {
                    if (self.is_action_expr(b.left, is_init) or
                        self.is_action_expr(b.right, is_init))
                    {
                        var operands: [256]*ast.Expr = undefined;
                        var operand_count: usize = 0;
                        flatten_action_disjunction(
                            self,
                            expr,
                            &operands,
                            &operand_count,
                            is_init,
                        );
                        var options = std.ArrayList([]const ActionStep).empty;
                        defer options.deinit(std.heap.page_allocator);
                        try options.ensureTotalCapacity(
                            std.heap.page_allocator,
                            operand_count,
                        );
                        for (operands[0..operand_count]) |operand| {
                            var option_steps = std.ArrayList(ActionStep).empty;
                            defer option_steps.deinit(std.heap.page_allocator);
                            try self.collect_steps(
                                operand,
                                &option_steps,
                                is_init,
                            );
                            try options.append(
                                std.heap.page_allocator,
                                try self.dup_slice(
                                    ActionStep,
                                    option_steps.items,
                                ),
                            );
                        }
                        try steps.append(std.heap.page_allocator, ActionStep{ .branch = .{ .options = try self.dup_slice([]const ActionStep, options.items) } });
                        return;
                    }
                }
                if (b.op == .eq) {
                    if (self.assignment_target(b.left, is_init)) |target| {
                        const assignment = AssignVar{
                            .var_name = try self.canonical_name(
                                target.variable_name,
                            ),
                            .var_index = target.variable_index,
                            .expr = try self.compile_expr(b.right),
                            .is_membership = false,
                        };
                        try steps.append(
                            std.heap.page_allocator,
                            if (is_init)
                                ActionStep{ .assign_var = assignment }
                            else
                                ActionStep{ .assign_prime = assignment },
                        );
                        return;
                    }
                }
                if (b.op == .in) {
                    if (self.assignment_target(b.left, is_init)) |target| {
                        if (b.right.* == .set_filter and
                            set_patterns.hereditary_power_set_filter(
                                b.right.set_filter,
                            ) == null)
                        {
                            try self.append_filtered_membership(
                                steps,
                                try self.canonical_name(
                                    target.variable_name,
                                ),
                                target.variable_index,
                                b.right.set_filter,
                                !is_init,
                            );
                            return;
                        }
                        const assignment = AssignVar{
                            .var_name = try self.canonical_name(
                                target.variable_name,
                            ),
                            .var_index = target.variable_index,
                            .expr = try self.compile_expr(b.right),
                            .is_membership = true,
                        };
                        try steps.append(
                            std.heap.page_allocator,
                            if (is_init)
                                ActionStep{ .assign_var = assignment }
                            else
                                ActionStep{ .assign_prime = assignment },
                        );
                        return;
                    }
                }
                try steps.append(std.heap.page_allocator, ActionStep{ .condition = try self.compile_expr(expr) });
            },
            .ident => |name| {
                const resolved = self.evaluator.resolve_alias(name);
                if (self.evaluator.find_constant(resolved) != null) {
                    try steps.append(
                        std.heap.page_allocator,
                        ActionStep{ .condition = try self.compile_expr(expr) },
                    );
                } else if (self.evaluator.find_definition(resolved)) |def| {
                    try steps.append(
                        std.heap.page_allocator,
                        ActionStep{ .mark_action = .{
                            .name = resolved,
                            .args = &.{},
                        } },
                    );
                    try self.collect_steps(def.body, steps, is_init);
                } else {
                    try steps.append(std.heap.page_allocator, ActionStep{ .condition = try self.compile_expr(expr) });
                }
            },
            .quantifier => |q| {
                if (std.c.getenv("TLZIG_DUMP_ACTION_STEPS") != null) {
                    std.debug.print("NEXT quantifier body {s}\n", .{
                        @tagName(q.body.*),
                    });
                }
                if (q.kind == .exists and
                    q.vars.len > 0 and
                    self.is_action_expr(q.body, is_init))
                {
                    if (bounded_power_set_pattern(
                        self,
                        q,
                        is_init,
                    )) |bounded| {
                        var body_steps = std.ArrayList(ActionStep).empty;
                        defer body_steps.deinit(std.heap.page_allocator);
                        var operands: [256]*ast.Expr = undefined;
                        var operand_count: usize = 0;
                        flatten_conjunction(
                            q.body,
                            &operands,
                            &operand_count,
                        );
                        for (operands[0..operand_count]) |operand| {
                            if (operand == bounded.upper_constraint) continue;
                            if (bounded.lower_constraint) |constraint| {
                                if (operand == constraint) continue;
                            }
                            try self.collect_steps(
                                operand,
                                &body_steps,
                                is_init,
                            );
                        }
                        try steps.append(
                            std.heap.page_allocator,
                            .{ .bounded_power_set_choose = .{
                                .var_name = try self.canonical_name(
                                    q.vars[0].name,
                                ),
                                .base = try self.compile_expr(bounded.base),
                                .upper = try self.compile_expr(bounded.upper),
                                .lower = if (bounded.lower) |lower|
                                    try self.compile_expr(lower)
                                else
                                    null,
                                .body_steps = try self.dup_slice(
                                    ActionStep,
                                    body_steps.items,
                                ),
                            } },
                        );
                        return;
                    }
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
                const then_action = self.is_action_expr(
                    ite.then_branch,
                    is_init,
                );
                const else_action = self.is_action_expr(
                    ite.else_branch,
                    is_init,
                );
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
                if (!self.is_action_expr(expr, is_init)) {
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
                                    .name = try self.canonical_name(def.name),
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
                            const state_args = try self.arena.alloc(
                                ?ActionStateArgument,
                                ap.args.len,
                            );
                            const parameter_bindings = try self.arena.alloc(
                                ActionParameterBinding,
                                def.params.len,
                            );
                            for (
                                def.params,
                                ap.args,
                                state_args,
                                parameter_bindings,
                            ) |param, arg, *state_arg, *binding| {
                                state_arg.* = self.resolve_state_argument(arg);
                                binding.* = .{
                                    .name = param,
                                    .state_argument = state_arg.*,
                                };
                            }
                            var call_compiler = self;
                            call_compiler.action_parameters =
                                parameter_bindings;
                            try call_compiler.collect_steps(
                                def.body,
                                &body_steps,
                                is_init,
                            );
                            try steps.append(
                                std.heap.page_allocator,
                                .{ .call = .{
                                    .name = try self.canonical_name(def.name),
                                    .params = try self.canonical_name_slice(
                                        def.params,
                                    ),
                                    .args = try self.compile_exprs(ap.args),
                                    .state_args = state_args,
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
                    const resolved = self.evaluator.resolve_alias(v);
                    if (self.evaluator.find_variable(resolved)) |index| {
                        try steps.append(std.heap.page_allocator, ActionStep{ .unchanged = .{
                            .var_name = try self.canonical_name(resolved),
                            .var_index = index,
                        } });
                    } else if (self.evaluator.find_definition(v)) |def| {
                        if (def.params.len == 0 and def.body.* == .tuple) {
                            for (def.body.*.tuple) |it| {
                                if (it.* != .ident) return Error.TypeError;
                                const name = self.evaluator.resolve_alias(it.*.ident);
                                const index = self.evaluator.find_variable(name) orelse {
                                    std.debug.print("unknown UNCHANGED variable: {s}\n", .{name});
                                    return Error.UndefinedSymbol;
                                };
                                try steps.append(std.heap.page_allocator, ActionStep{ .unchanged = .{
                                    .var_name = try self.canonical_name(name),
                                    .var_index = index,
                                } });
                            }
                            continue;
                        }
                        return Error.TypeError;
                    } else {
                        std.debug.print("unknown UNCHANGED tuple/operator: {s}\n", .{v});
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
            self.evaluator.generated_expression_count() > 0;
        const binding = if (def.params.len > 0 and
            !use_generated_operator)
            try self.lambda_expr(def.params, def.body)
        else
            def.body;
        try steps.append(
            std.heap.page_allocator,
            ActionStep{ .let_bind = .{
                .name = try self.canonical_name(def.name),
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
                .var_name = try self.canonical_name(vars[i].name),
                .domain = try self.compile_expr(vars[i].domain),
                .body_steps = nested,
            } };
            nested = wrapper;
        }
        return .{ .choose = .{
            .var_name = try self.canonical_name(vars[0].name),
            .domain = try self.compile_expr(vars[0].domain),
            .body_steps = nested,
        } };
    }

    fn append_filtered_membership(
        self: ActionCompiler,
        steps: *std.ArrayList(ActionStep),
        variable_name: []const u8,
        variable_index: u32,
        filter: *ast.SetFilter,
        primed: bool,
    ) !void {
        assert(filter.vars.len > 0);
        const element = try self.filtered_element_expr(filter.vars);
        const compiled_element = try self.compile_expr(element);
        const body = try self.arena.alloc(ActionStep, 2);
        body[0] = .{ .condition = try self.compile_expr(filter.pred) };
        body[1] = if (primed)
            .{ .assign_prime = .{
                .var_name = variable_name,
                .var_index = variable_index,
                .expr = compiled_element,
                .is_membership = false,
            } }
        else
            .{ .assign_var = .{
                .var_name = variable_name,
                .var_index = variable_index,
                .expr = compiled_element,
                .is_membership = false,
            } };
        try steps.append(
            std.heap.page_allocator,
            try self.compile_existential(filter.vars, body),
        );
    }

    fn filtered_element_expr(
        self: ActionCompiler,
        vars: []const ast.BoundVar,
    ) !*ast.Expr {
        assert(vars.len > 0);
        if (vars.len == 1) {
            const element = try self.arena.alloc_object(ast.Expr);
            element.* = .{ .ident = try self.canonical_name(vars[0].name) };
            return element;
        }
        const items = try self.arena.alloc(*ast.Expr, vars.len);
        for (vars, items) |bound, *item| {
            item.* = try self.arena.alloc_object(ast.Expr);
            item.*.* = .{ .ident = try self.canonical_name(bound.name) };
        }
        const element = try self.arena.alloc_object(ast.Expr);
        element.* = .{ .tuple = items };
        return element;
    }

    fn dup_slice(self: ActionCompiler, comptime T: type, items: []const T) ![]const T {
        const copy = try self.arena.alloc(T, items.len);
        @memcpy(copy, items);
        return copy;
    }
};

fn dump_action_steps(label: []const u8, steps: []const ActionStep, depth: u32) void {
    for (steps) |step| {
        var indent: u32 = 0;
        while (indent < depth) : (indent += 1) {
            std.debug.print("  ", .{});
        }
        switch (step) {
            .assign_var => |assign| std.debug.print(
                "{s}: assign {s}\n",
                .{ label, assign.var_name },
            ),
            .assign_prime => |assign| std.debug.print(
                "{s}: assign' {s}\n",
                .{ label, assign.var_name },
            ),
            .condition => std.debug.print("{s}: condition\n", .{label}),
            .enabled_check => |enabled| {
                std.debug.print(
                    "{s}: enabled expected={}\n",
                    .{ label, enabled.expected },
                );
                dump_action_steps(label, enabled.steps, depth + 1);
            },
            .mark_action => |marker| std.debug.print(
                "{s}: mark {s}\n",
                .{ label, marker.name },
            ),
            .choose => |choose| {
                std.debug.print("{s}: choose {s}\n", .{ label, choose.var_name });
                dump_action_steps(label, choose.body_steps, depth + 1);
            },
            .bounded_power_set_choose => |choose| {
                std.debug.print(
                    "{s}: bounded power-set choose {s}\n",
                    .{ label, choose.var_name },
                );
                dump_action_steps(label, choose.body_steps, depth + 1);
            },
            .branch => |branch| {
                std.debug.print("{s}: branch options={d}\n", .{
                    label,
                    branch.options.len,
                });
                for (branch.options) |option| {
                    dump_action_steps(label, option, depth + 1);
                }
            },
            .if_branch => |branch| {
                std.debug.print("{s}: if\n", .{label});
                dump_action_steps(label, branch.then_steps, depth + 1);
                dump_action_steps(label, branch.else_steps, depth + 1);
            },
            .case_branch => |branch| {
                std.debug.print("{s}: case arms={d}\n", .{
                    label,
                    branch.arms.len,
                });
                for (branch.arms) |arm| {
                    dump_action_steps(label, arm.steps, depth + 1);
                }
                if (branch.otherwise_steps) |otherwise| {
                    dump_action_steps(label, otherwise, depth + 1);
                }
            },
            .call => |call| {
                std.debug.print("{s}: call {s}\n", .{ label, call.name });
                dump_action_steps(label, call.body_steps, depth + 1);
            },
            .compose => |compose| {
                std.debug.print("{s}: compose left\n", .{label});
                dump_action_steps(label, compose.left_steps, depth + 1);
                std.debug.print("{s}: compose right\n", .{label});
                dump_action_steps(label, compose.right_steps, depth + 1);
            },
            .let_bind => |binding| std.debug.print(
                "{s}: let {s}\n",
                .{ label, binding.name },
            ),
            .unchanged => |unchanged| std.debug.print(
                "{s}: unchanged {s}\n",
                .{ label, unchanged.var_name },
            ),
        }
    }
}

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

const BoundedPowerSetPattern = struct {
    base: *ast.Expr,
    upper: *ast.Expr,
    lower: ?*ast.Expr,
    upper_constraint: *ast.Expr,
    lower_constraint: ?*ast.Expr,
};

/// Recognizes an existential power-set choice constrained by an upper set and,
/// optionally, a required lower set. The executor can enumerate only values
/// between those bounds instead of materializing and filtering the full power
/// set.
fn bounded_power_set_pattern(
    compiler: ActionCompiler,
    quantifier: *const ast.Quantifier,
    is_init: bool,
) ?BoundedPowerSetPattern {
    if (quantifier.kind != .exists or quantifier.vars.len != 1) return null;
    const bound = quantifier.vars[0];
    if (bound.domain.* != .unary or
        bound.domain.unary.op != .subset)
    {
        return null;
    }

    var operands: [256]*ast.Expr = undefined;
    var operand_count: usize = 0;
    flatten_conjunction(
        quantifier.body,
        &operands,
        &operand_count,
    );
    if (operand_count == 0 or operands[0].* != .binary) return null;
    const upper_binary = operands[0].binary;
    if (upper_binary.op != .subseteq or
        upper_binary.left.* != .ident or
        !std.mem.eql(u8, upper_binary.left.ident, bound.name) or
        codegen.expression_references_identifier(
            upper_binary.right,
            bound.name,
        ) or
        compiler.is_action_expr(upper_binary.right, is_init) or
        !codegen.expression_reordering_safe(
            compiler.evaluator.module,
            upper_binary.right,
        ))
    {
        return null;
    }

    var lower: ?*ast.Expr = null;
    var lower_constraint: ?*ast.Expr = null;
    if (operand_count > 1 and operands[1].* == .binary) {
        const lower_binary = operands[1].binary;
        if (lower_binary.op == .subseteq and
            lower_binary.right.* == .ident and
            std.mem.eql(u8, lower_binary.right.ident, bound.name) and
            !codegen.expression_references_identifier(
                lower_binary.left,
                bound.name,
            ) and
            !compiler.is_action_expr(lower_binary.left, is_init) and
            codegen.expression_reordering_safe(
                compiler.evaluator.module,
                lower_binary.left,
            ))
        {
            lower = lower_binary.left;
            lower_constraint = operands[1];
        }
    }
    return .{
        .base = bound.domain.unary.operand,
        .upper = upper_binary.right,
        .lower = lower,
        .upper_constraint = operands[0],
        .lower_constraint = lower_constraint,
    };
}

fn flatten_action_disjunction(
    compiler: ActionCompiler,
    expr: *ast.Expr,
    operands: *[256]*ast.Expr,
    count: *usize,
    is_init: bool,
) void {
    if (expr.* == .binary and
        expr.binary.op == .or_op and
        compiler.is_action_expr(expr, is_init))
    {
        flatten_action_disjunction(
            compiler,
            expr.binary.left,
            operands,
            count,
            is_init,
        );
        flatten_action_disjunction(
            compiler,
            expr.binary.right,
            operands,
            count,
            is_init,
        );
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
    evaluator: *const Evaluator,
    source_state_store: *StateStore,
    candidate_store: *StateStore,
    eval_pool: *ValuePool,
    compose_states: ?*StateBuffer = null,
    composition_generated: ?*u64 = null,
    fairness_markers: []const FairnessMarker = &.{},
    edge_action_masks: ?[]u64 = null,
    enabled_probe: ?*bool = null,
    candidate_sink: ?CandidateSink = null,
    diagnostics: bool = false,

    const Continuation = struct {
        steps: []const ActionStep,
        next: ?*const Continuation,
        return_context: ?Context = null,
    };

    pub fn execute_init(
        self: *const ActionExecutor,
        compiled: CompiledInit,
        out_states: *StateBuffer,
    ) !void {
        assert(compiled.steps.len >= 0);
        assert(out_states.items.len == 0);
        self.evaluator.reset_context_pool();
        self.evaluator.begin_action_evaluation();
        defer self.evaluator.end_action_evaluation();
        try self.execute_steps(compiled.steps, null, Context.empty(), null, out_states, true, 0);
    }

    pub fn execute_next(
        self: *const ActionExecutor,
        compiled: CompiledNext,
        s0_idx: u32,
        out_states: *StateBuffer,
    ) !void {
        const s0 = self.source_state_store.get(s0_idx);
        self.evaluator.reset_context_pool();
        self.evaluator.begin_action_evaluation();
        defer self.evaluator.end_action_evaluation();
        try self.execute_steps(compiled.steps, null, Context.empty(), s0, out_states, false, 0);
    }

    fn eval_direct_generated_expr(
        self: *const ActionExecutor,
        expression: *const generated_runtime.Expression,
        context: Context,
    ) Error!?Value {
        _ = self;
        if (expression.direct_value) |direct| return direct;
        const index = expression.direct_arg_index orelse return null;
        if (index >= expression.arg_names.len or
            index >= expression.arg_depths.len)
        {
            return Error.TypeError;
        }
        const direct = context.lookup_value_at_depth(
            expression.arg_names[index],
            expression.arg_depths[index],
        ) orelse return null;
        if (generated_runtime.requires_force(direct)) return null;
        return direct;
    }

    fn eval_generated_compiled_expr(
        self: *const ActionExecutor,
        generated: *const generated_runtime.Expression,
        context: Context,
        state: ?*StateStore.State,
    ) !?Value {
        return self.evaluator.eval_generated_expression_if_args_available(
            generated,
            context,
            state,
            self.eval_pool,
            &self.source_state_store.values_pool,
        ) catch |err| {
            if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                std.debug.print(
                    "generated expression {d} failed with {any}; args={any}\n",
                    .{ generated.identity, err, generated.arg_names },
                );
            }
            return err;
        };
    }

    fn eval_generated_compiled_bool(
        self: *const ActionExecutor,
        generated: *const generated_runtime.Expression,
        context: Context,
        state: ?*StateStore.State,
    ) !?bool {
        return self.evaluator.eval_generated_expression_bool_if_args_available(
            generated,
            context,
            state,
            self.eval_pool,
            &self.source_state_store.values_pool,
        ) catch |err| {
            if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                std.debug.print(
                    "generated boolean expression {d} failed with {any}; args={any}\n",
                    .{ generated.identity, err, generated.arg_names },
                );
            }
            return err;
        };
    }

    fn eval_compiled_expr(
        self: *const ActionExecutor,
        compiled: CompiledExpr,
        context: Context,
        state: ?*StateStore.State,
    ) !Value {
        if (compiled.generated) |generated| {
            if (try self.eval_direct_generated_expr(
                generated,
                context,
            )) |direct| return direct;
        }
        if (compiled.generated) |generated| generated: {
            const result = if (self.evaluator.generated_requires_state_memo()) result: {
                self.evaluator.begin_state_evaluation(self.eval_pool);
                defer self.evaluator.end_state_evaluation();
                break :result try self.eval_generated_compiled_expr(
                    generated,
                    context,
                    state,
                );
            } else try self.eval_generated_compiled_expr(
                generated,
                context,
                state,
            );
            if (result) |value_v| return value_v;
            break :generated;
        }
        self.evaluator.begin_state_evaluation(self.eval_pool);
        defer self.evaluator.end_state_evaluation();
        return self.evaluator.eval_expr(
            compiled.expr,
            context,
            state,
            self.eval_pool,
            &self.source_state_store.values_pool,
        );
    }

    fn eval_compiled_bool(
        self: *const ActionExecutor,
        compiled: CompiledExpr,
        context: Context,
        state: ?*StateStore.State,
    ) !bool {
        if (compiled.generated) |generated| {
            if (try self.eval_direct_generated_expr(
                generated,
                context,
            )) |direct| return try generated_runtime.boolean(direct);
        }
        if (compiled.generated) |generated| generated: {
            const result = if (self.evaluator.generated_requires_state_memo()) result: {
                self.evaluator.begin_state_evaluation(self.eval_pool);
                defer self.evaluator.end_state_evaluation();
                break :result try self.eval_generated_compiled_bool(
                    generated,
                    context,
                    state,
                );
            } else try self.eval_generated_compiled_bool(
                generated,
                context,
                state,
            );
            if (result) |value_b| return value_b;
            break :generated;
        }
        self.evaluator.begin_state_evaluation(self.eval_pool);
        defer self.evaluator.end_state_evaluation();
        const result = try self.evaluator.eval_expr(
            compiled.expr,
            context,
            state,
            self.eval_pool,
            &self.source_state_store.values_pool,
        );
        return result.is_truthy();
    }

    fn existing_assignment_compatible(
        self: *const ActionExecutor,
        context: Context,
        variable_index: u32,
        value_v: Value,
        is_membership: bool,
    ) Error!?bool {
        const assigned = context.lookup_state(variable_index) orelse return null;
        const assigned_pool = assigned.value_pool orelse self.eval_pool;
        if (!is_membership) {
            return Value.eql_cross_pool(
                assigned.value,
                assigned_pool,
                value_v,
                self.eval_pool,
            );
        }
        if (!value_v.is_set_like()) return Error.TypeError;
        const member = if (assigned_pool == self.eval_pool)
            assigned.value
        else
            try assigned.value.clone(assigned_pool, self.eval_pool);
        return value_v.member(self.eval_pool, member);
    }

    fn execute_function_set_membership(
        self: *const ActionExecutor,
        function_set: value.FunctionSet,
        rest: []const ActionStep,
        continuation: ?*const Continuation,
        context: Context,
        state: ?*StateStore.State,
        out_states: *StateBuffer,
        is_init: bool,
        action_mask: u64,
        variable_name: []const u8,
        variable_index: u32,
    ) Error!void {
        const domain = try self.evaluator.materialize_set(
            function_set.domain(self.eval_pool),
            context,
            state,
            self.eval_pool,
            &self.source_state_store.values_pool,
        );
        const codomain = try self.evaluator.materialize_set(
            function_set.codomain(self.eval_pool),
            context,
            state,
            self.eval_pool,
            &self.source_state_store.values_pool,
        );
        if (domain != .set_v or codomain != .set_v) {
            return Error.TypeError;
        }

        const domain_count = domain.set_v.len;
        const codomain_count = codomain.set_v.len;
        var candidate_count: u64 = 1;
        var domain_index: u32 = 0;
        while (domain_index < domain_count) : (domain_index += 1) {
            candidate_count = std.math.mul(
                u64,
                candidate_count,
                codomain_count,
            ) catch return Error.OutOfMemory;
            if (candidate_count > std.math.maxInt(u32)) {
                return Error.OutOfMemory;
            }
        }

        const snapshot = self.eval_pool.snapshot();
        const context_snapshot = self.evaluator.context_snapshot();
        const codomain_values = codomain.set_v.items(self.eval_pool);
        var combination: u64 = 0;
        while (combination < candidate_count) : (combination += 1) {
            const entries = try self.eval_pool.alloc_values(domain_count);
            var cursor = combination;
            domain_index = 0;
            while (domain_index < domain_count) : (domain_index += 1) {
                assert(codomain_count > 0);
                const selected: usize = @intCast(cursor % codomain_count);
                cursor /= codomain_count;
                entries[domain_index] = codomain_values[selected];
            }
            assert(cursor == 0);
            const function = Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(self.eval_pool, entries.ptr),
                .len = domain_count,
            } };
            const next_context = try self.evaluator.extend_state_context(
                context,
                variable_name,
                variable_index,
                function,
                .changed,
            );
            try self.execute_steps(
                rest,
                continuation,
                next_context,
                state,
                out_states,
                is_init,
                action_mask,
            );
            self.eval_pool.restore(snapshot);
            self.evaluator.restore_context_pool(context_snapshot);
            if (self.enabled_probe) |probe| {
                if (probe.*) return;
            }
        }
    }

    const RecordSetIteration = struct {
        record_set: value.RecordSet,
        domains_offset: u32,
        candidate_count: u32,
    };

    fn prepare_record_set_iteration(
        self: *const ActionExecutor,
        record_set: value.RecordSet,
        context: Context,
        state: ?*StateStore.State,
    ) Error!RecordSetIteration {
        const domains = try self.eval_pool.alloc_values(record_set.len);
        const domains_offset = value_offset(self.eval_pool, domains.ptr);
        var candidate_count: u64 = if (record_set.len == 0) 0 else 1;
        var field_index: u32 = 0;
        while (field_index < record_set.len) : (field_index += 1) {
            const domain = try self.evaluator.materialize_set(
                record_set.field_domain(self.eval_pool, field_index),
                context,
                state,
                self.eval_pool,
                &self.source_state_store.values_pool,
            );
            if (domain != .set_v) return Error.TypeError;
            self.eval_pool.values[domains_offset + field_index] = domain;
            candidate_count = std.math.mul(
                u64,
                candidate_count,
                domain.set_v.len,
            ) catch return Error.OutOfMemory;
            if (candidate_count > std.math.maxInt(u32)) {
                return Error.OutOfMemory;
            }
        }
        return .{
            .record_set = record_set,
            .domains_offset = domains_offset,
            .candidate_count = @intCast(candidate_count),
        };
    }

    fn record_set_candidate(
        self: *const ActionExecutor,
        iteration: RecordSetIteration,
        combination: u32,
    ) Error!Value {
        assert(combination < iteration.candidate_count);
        const field_value_count = std.math.mul(
            u32,
            iteration.record_set.len,
            2,
        ) catch return Error.OutOfMemory;
        const fields = try self.eval_pool.alloc_values(
            field_value_count,
        );
        const fields_offset = value_offset(self.eval_pool, fields.ptr);
        var cursor = combination;
        var field_index: u32 = 0;
        while (field_index < iteration.record_set.len) : (field_index += 1) {
            const domain = self.eval_pool.values[
                iteration.domains_offset + field_index
            ];
            assert(domain == .set_v);
            assert(domain.set_v.len > 0);
            const selected = cursor % domain.set_v.len;
            cursor /= domain.set_v.len;
            self.eval_pool.values[fields_offset + field_index * 2] = .{
                .string_v = iteration.record_set.field_name(
                    self.eval_pool,
                    field_index,
                ),
            };
            self.eval_pool.values[fields_offset + field_index * 2 + 1] =
                self.eval_pool.values[domain.set_v.offset + selected];
        }
        assert(cursor == 0);
        return .{ .record_v = .{
            .offset = fields_offset,
            .len = iteration.record_set.len,
        } };
    }

    fn execute_record_set_membership(
        self: *const ActionExecutor,
        record_set: value.RecordSet,
        rest: []const ActionStep,
        continuation: ?*const Continuation,
        context: Context,
        state: ?*StateStore.State,
        out_states: *StateBuffer,
        is_init: bool,
        action_mask: u64,
        variable_name: []const u8,
        variable_index: u32,
    ) Error!void {
        const iteration = try self.prepare_record_set_iteration(
            record_set,
            context,
            state,
        );
        const snapshot = self.eval_pool.snapshot();
        const context_snapshot = self.evaluator.context_snapshot();
        var combination: u32 = 0;
        while (combination < iteration.candidate_count) : (combination += 1) {
            const candidate = try self.record_set_candidate(
                iteration,
                combination,
            );
            const next_context = try self.evaluator.extend_state_context(
                context,
                variable_name,
                variable_index,
                candidate,
                .changed,
            );
            try self.execute_steps(
                rest,
                continuation,
                next_context,
                state,
                out_states,
                is_init,
                action_mask,
            );
            self.eval_pool.restore(snapshot);
            self.evaluator.restore_context_pool(context_snapshot);
            if (self.enabled_probe) |probe| {
                if (probe.*) return;
            }
        }
    }

    fn execute_record_set_choice(
        self: *const ActionExecutor,
        record_set: value.RecordSet,
        choice: Choose,
        rest: []const ActionStep,
        continuation: ?*const Continuation,
        context: Context,
        state: ?*StateStore.State,
        out_states: *StateBuffer,
        is_init: bool,
        action_mask: u64,
    ) Error!void {
        const iteration = try self.prepare_record_set_iteration(
            record_set,
            context,
            state,
        );
        const snapshot = self.eval_pool.snapshot();
        const context_snapshot = self.evaluator.context_snapshot();
        const next = Continuation{
            .steps = rest,
            .next = continuation,
            .return_context = context,
        };
        var combination: u32 = 0;
        while (combination < iteration.candidate_count) : (combination += 1) {
            const candidate = try self.record_set_candidate(
                iteration,
                combination,
            );
            const next_context = try self.evaluator.extend_context(
                context,
                choice.var_name,
                candidate,
            );
            try self.execute_steps(
                choice.body_steps,
                if (rest.len == 0 and continuation == null) null else &next,
                next_context,
                state,
                out_states,
                is_init,
                action_mask,
            );
            self.eval_pool.restore(snapshot);
            self.evaluator.restore_context_pool(context_snapshot);
            if (self.enabled_probe) |probe| {
                if (probe.*) return;
            }
        }
    }

    fn execute_bounded_power_set_choice(
        self: *const ActionExecutor,
        choice: BoundedPowerSetChoose,
        rest: []const ActionStep,
        continuation: ?*const Continuation,
        context: Context,
        state: ?*StateStore.State,
        out_states: *StateBuffer,
        is_init: bool,
        action_mask: u64,
    ) Error!void {
        const base_value = try self.eval_compiled_expr(
            choice.base,
            context,
            state,
        );
        const upper_value = try self.eval_compiled_expr(
            choice.upper,
            context,
            state,
        );
        if (!base_value.is_set_like() or !upper_value.is_set_like()) {
            return Error.TypeError;
        }
        const base = try self.evaluator.materialize_set(
            base_value,
            context,
            state,
            self.eval_pool,
            &self.source_state_store.values_pool,
        );
        const upper = try self.evaluator.materialize_set(
            upper_value,
            context,
            state,
            self.eval_pool,
            &self.source_state_store.values_pool,
        );
        if (base != .set_v or upper != .set_v) return Error.TypeError;
        if (base.set_v.len > 30) return Error.OutOfMemory;

        const lower = if (choice.lower) |compiled| lower: {
            const lower_value = try self.eval_compiled_expr(
                compiled,
                context,
                state,
            );
            if (!lower_value.is_set_like()) return Error.TypeError;
            const materialized = try self.evaluator.materialize_set(
                lower_value,
                context,
                state,
                self.eval_pool,
                &self.source_state_store.values_pool,
            );
            if (materialized != .set_v) return Error.TypeError;
            break :lower materialized;
        } else Value{ .set_v = .{
            .offset = base.set_v.offset,
            .len = 0,
        } };

        const base_items = base.set_v.items(self.eval_pool);
        const upper_set = upper.set_v;
        const lower_set = lower.set_v;
        const lower_items = lower_set.items(self.eval_pool);
        for (lower_items) |item| {
            if (!base.set_v.contains(self.eval_pool, item) or
                !upper_set.contains(self.eval_pool, item))
            {
                return;
            }
        }

        const optional = try self.eval_pool.alloc_values(base.set_v.len);
        var optional_count: u32 = 0;
        for (base_items) |item| {
            if (!upper_set.contains(self.eval_pool, item) or
                lower_set.contains(self.eval_pool, item))
            {
                continue;
            }
            optional[optional_count] = item;
            optional_count += 1;
        }
        assert(lower_set.len + optional_count <= base.set_v.len);
        const candidate_storage = try self.eval_pool.alloc_values(
            lower_set.len + optional_count,
        );
        @memcpy(candidate_storage[0..lower_set.len], lower_items);
        const candidate_offset = value_offset(
            self.eval_pool,
            candidate_storage.ptr,
        );
        const snapshot = self.eval_pool.snapshot();
        const context_snapshot = self.evaluator.context_snapshot();
        const next = Continuation{
            .steps = rest,
            .next = continuation,
            .return_context = context,
        };
        const candidate_count = @as(u64, 1) << @intCast(optional_count);
        var mask: u64 = 0;
        while (mask < candidate_count) : (mask += 1) {
            var candidate_len = lower_set.len;
            for (optional[0..optional_count], 0..) |item, bit| {
                if (mask & (@as(u64, 1) << @intCast(bit)) == 0) continue;
                candidate_storage[candidate_len] = item;
                candidate_len += 1;
            }
            assert(candidate_len <= lower_set.len + optional_count);
            const candidate = Value{ .set_v = .{
                .offset = candidate_offset,
                .len = candidate_len,
            } };
            const next_context = try self.evaluator.extend_context(
                context,
                choice.var_name,
                candidate,
            );
            try self.execute_steps(
                choice.body_steps,
                if (rest.len == 0 and continuation == null) null else &next,
                next_context,
                state,
                out_states,
                is_init,
                action_mask,
            );
            self.eval_pool.restore(snapshot);
            self.evaluator.restore_context_pool(context_snapshot);
            if (self.enabled_probe) |probe| {
                if (probe.*) return;
            }
        }
    }

    fn execute_steps(
        self: *const ActionExecutor,
        steps: []const ActionStep,
        continuation: ?*const Continuation,
        ctx: Context,
        s0: ?*StateStore.State,
        out_states: *StateBuffer,
        is_init: bool,
        action_mask: u64,
    ) Error!void {
        const previous_context_floor = self.evaluator.pin_context_pool();
        defer self.evaluator.unpin_context_pool(previous_context_floor);
        assert(self.eval_pool.value_count <= self.eval_pool.value_cap);
        assert(self.source_state_store.values_pool.value_count <=
            self.source_state_store.values_pool.value_cap);
        assert(self.candidate_store.values_pool.value_count <=
            self.candidate_store.values_pool.value_cap);
        var current_steps = steps;
        var current_cont = continuation;
        var current_ctx = ctx;
        while (true) {
            if (self.enabled_probe) |probe| {
                if (probe.*) return;
            }
            if (current_steps.len == 0) {
                if (current_cont) |next| {
                    if (next.return_context) |caller_context| {
                        current_ctx = caller_context.restore_locals(
                            current_ctx,
                        );
                    }
                    current_steps = next.steps;
                    current_cont = next.next;
                    continue;
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
                    if (try self.existing_assignment_compatible(
                        current_ctx,
                        a.var_index,
                        val,
                        a.is_membership,
                    )) |compatible| {
                        if (!compatible) return;
                        current_steps = rest;
                        continue;
                    }
                    if (a.is_membership) {
                        if (!val.is_set_like()) return Error.TypeError;
                        if (val == .function_set_v) {
                            try self.execute_function_set_membership(
                                val.function_set_v,
                                rest,
                                current_cont,
                                current_ctx,
                                s0,
                                out_states,
                                is_init,
                                action_mask,
                                a.var_name,
                                a.var_index,
                            );
                            return;
                        }
                        if (val == .record_set_v) {
                            try self.execute_record_set_membership(
                                val.record_set_v,
                                rest,
                                current_cont,
                                current_ctx,
                                s0,
                                out_states,
                                is_init,
                                action_mask,
                                a.var_name,
                                a.var_index,
                            );
                            return;
                        }
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
                            try self.execute_steps(rest, current_cont, new_ctx, s0, out_states, is_init, action_mask);
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
                    if (try self.existing_assignment_compatible(
                        current_ctx,
                        a.var_index,
                        val,
                        a.is_membership,
                    )) |compatible| {
                        if (!compatible) return;
                        current_steps = rest;
                        continue;
                    }
                    if (a.is_membership) {
                        if (!val.is_set_like()) return Error.TypeError;
                        if (val == .function_set_v) {
                            try self.execute_function_set_membership(
                                val.function_set_v,
                                rest,
                                current_cont,
                                current_ctx,
                                s0,
                                out_states,
                                is_init,
                                action_mask,
                                a.var_name,
                                a.var_index,
                            );
                            return;
                        }
                        if (val == .record_set_v) {
                            try self.execute_record_set_membership(
                                val.record_set_v,
                                rest,
                                current_cont,
                                current_ctx,
                                s0,
                                out_states,
                                is_init,
                                action_mask,
                                a.var_name,
                                a.var_index,
                            );
                            return;
                        }
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
                            try self.execute_steps(rest, current_cont, new_ctx, s0, out_states, is_init, action_mask);
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
                    if (!try self.eval_compiled_bool(e, current_ctx, s0)) {
                        if (self.diagnostics and
                            std.c.getenv(
                                "TLZIG_ACTION_DIAGNOSTICS",
                            ) != null)
                        {
                            if (e.generated) |generated| {
                                std.debug.print(
                                    "action condition rejected: expression={d} kind={s}\n",
                                    .{ generated.identity, @tagName(e.expr.*) },
                                );
                            } else {
                                std.debug.print(
                                    "action condition rejected: interpreted kind={s}\n",
                                    .{@tagName(e.expr.*)},
                                );
                            }
                        }
                        return;
                    }
                    current_steps = rest;
                    continue;
                },
                .enabled_check => |enabled_check| {
                    const pool_snapshot = self.eval_pool.snapshot();
                    const context_snapshot = self.evaluator.context_snapshot();
                    var enabled = false;
                    var probe_executor = self.*;
                    probe_executor.enabled_probe = &enabled;
                    var probe_storage: [1]u32 = undefined;
                    var probe_states = StateBuffer{
                        .storage = &probe_storage,
                        .items = probe_storage[0..0],
                    };
                    try probe_executor.execute_steps(
                        enabled_check.steps,
                        null,
                        current_ctx,
                        s0,
                        &probe_states,
                        false,
                        action_mask,
                    );
                    self.eval_pool.restore(pool_snapshot);
                    self.evaluator.restore_context_pool(context_snapshot);
                    if (enabled != enabled_check.expected) return;
                    current_steps = rest;
                    continue;
                },
                .mark_action => |marker| {
                    current_steps = rest;
                    if (self.fairness_markers.len == 0) continue;
                    mask_update: {
                        const additional_mask = try self.fairness_marker_mask(
                            marker,
                            current_ctx,
                            s0,
                        );
                        if (additional_mask == 0) break :mask_update;
                        try self.execute_steps(
                            rest,
                            current_cont,
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
                    if (set_v == .record_set_v) {
                        try self.execute_record_set_choice(
                            set_v.record_set_v,
                            c,
                            rest,
                            current_cont,
                            current_ctx,
                            s0,
                            out_states,
                            is_init,
                            action_mask,
                        );
                        return;
                    }
                    const mat = try self.evaluator.materialize_set(set_v, current_ctx, s0, self.eval_pool, &self.source_state_store.values_pool);
                    if (mat != .set_v) return Error.TypeError;
                    const items = mat.set_v.items(self.eval_pool);
                    if (items.len == 0) return;
                    const snap = self.eval_pool.snapshot();
                    const context_snap = self.evaluator.context_snapshot();
                    if (rest.len == 0 and current_cont == null) {
                        for (items[0 .. items.len - 1]) |it| {
                            const new_ctx = try self.evaluator.extend_context(current_ctx, c.var_name, it);
                            try self.execute_steps(c.body_steps, null, new_ctx, s0, out_states, is_init, action_mask);
                            self.eval_pool.restore(snap);
                            self.evaluator.restore_context_pool(context_snap);
                        }
                        current_ctx = try self.evaluator.extend_context(
                            current_ctx,
                            c.var_name,
                            items[items.len - 1],
                        );
                        current_steps = c.body_steps;
                        continue;
                    }
                    const next = Continuation{
                        .steps = rest,
                        .next = current_cont,
                        .return_context = current_ctx,
                    };
                    for (items) |it| {
                        const new_ctx = try self.evaluator.extend_context(current_ctx, c.var_name, it);
                        try self.execute_steps(c.body_steps, &next, new_ctx, s0, out_states, is_init, action_mask);
                        self.eval_pool.restore(snap);
                        self.evaluator.restore_context_pool(context_snap);
                    }
                    return;
                },
                .bounded_power_set_choose => |choice| {
                    try self.execute_bounded_power_set_choice(
                        choice,
                        rest,
                        current_cont,
                        current_ctx,
                        s0,
                        out_states,
                        is_init,
                        action_mask,
                    );
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
                    if (c.params.len != c.args.len or
                        c.state_args.len != c.args.len)
                    {
                        return Error.TypeError;
                    }
                    if (c.args.len > 32) return Error.NotImplemented;
                    const context_snap = self.evaluator.context_snapshot();
                    var values: [32]Value = undefined;
                    for (c.args, 0..) |arg, i| {
                        values[i] = if (c.state_args[i]) |state_arg|
                            try generated_runtime.state_reference(
                                state_arg.variable_index,
                                state_arg.primed,
                            )
                        else
                            try self.eval_compiled_expr(
                                arg,
                                current_ctx,
                                s0,
                            );
                    }
                    var call_ctx = current_ctx.operator_frame();
                    for (c.params, 0..) |p, i| {
                        call_ctx = try self.evaluator.extend_context(call_ctx, p, values[i]);
                    }
                    if (rest.len == 0 and current_cont == null) {
                        current_ctx = call_ctx;
                        current_steps = c.body_steps;
                        continue;
                    }
                    const next = Continuation{
                        .steps = rest,
                        .next = current_cont,
                        .return_context = current_ctx,
                    };
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
                        .next = current_cont,
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
                            .candidate_sink = self.candidate_sink,
                            .diagnostics = self.diagnostics,
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
                    if (b.options.len == 0) return;
                    if (rest.len == 0 and current_cont == null) {
                        const snap = self.eval_pool.snapshot();
                        const context_snap = self.evaluator.context_snapshot();
                        for (b.options[0 .. b.options.len - 1]) |opt| {
                            try self.execute_steps(opt, null, current_ctx, s0, out_states, is_init, action_mask);
                            self.eval_pool.restore(snap);
                            self.evaluator.restore_context_pool(context_snap);
                        }
                        current_steps = b.options[b.options.len - 1];
                        continue;
                    }
                    const next = Continuation{ .steps = rest, .next = current_cont };
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
                    if (rest.len == 0 and current_cont == null) {
                        current_steps = taken;
                        continue;
                    }
                    const next = Continuation{ .steps = rest, .next = current_cont };
                    const snap = self.eval_pool.snapshot();
                    const context_snap = self.evaluator.context_snapshot();
                    try self.execute_steps(taken, &next, current_ctx, s0, out_states, is_init, action_mask);
                    self.eval_pool.restore(snap);
                    self.evaluator.restore_context_pool(context_snap);
                    return;
                },
                .case_branch => |case| {
                    const next = Continuation{ .steps = rest, .next = current_cont };
                    const next_ptr: ?*const Continuation = if (rest.len == 0 and
                        current_cont == null) null else &next;
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
                        try self.execute_steps(arm.steps, next_ptr, current_ctx, s0, out_states, is_init, action_mask);
                        self.eval_pool.restore(snap);
                        self.evaluator.restore_context_pool(context_snap);
                        return;
                    }
                    if (case.otherwise_steps) |otherwise| {
                        try self.execute_steps(otherwise, next_ptr, current_ctx, s0, out_states, is_init, action_mask);
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
                    if (current_ctx.lookup_state(unchanged.var_index)) |assigned| {
                        const assigned_pool = assigned.value_pool orelse self.eval_pool;
                        if (!Value.eql_cross_pool(
                            assigned.value,
                            assigned_pool,
                            source_state.values[unchanged.var_index],
                            source_pool,
                        )) return;
                        current_steps = rest;
                        continue;
                    }
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
        self: *const ActionExecutor,
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
        self: *const ActionExecutor,
        marker: MarkAction,
        fairness: FairnessMarker,
        ctx: Context,
        s0: ?*StateStore.State,
    ) !bool {
        if (!try self.fairness_action_marker_matches(
            marker,
            fairness.action,
            fairness.bindings,
            ctx,
            s0,
            0,
        )) return false;
        return try self.fairness_bindings_match(fairness.bindings, ctx);
    }

    fn fairness_action_marker_matches(
        self: *const ActionExecutor,
        marker: MarkAction,
        fairness_action: *ast.Expr,
        bindings: []const FairnessBinding,
        ctx: Context,
        s0: ?*StateStore.State,
        depth: u8,
    ) !bool {
        if (depth == 64) return Error.NotImplemented;
        switch (fairness_action.*) {
            .ident => |name| {
                if (std.mem.eql(u8, marker.name, name)) {
                    return marker.args.len == 0;
                }
                const definition = self.evaluator.find_definition(name) orelse
                    return false;
                if (definition.params.len != 0) return false;
                return self.fairness_action_marker_matches(
                    marker,
                    definition.body,
                    bindings,
                    ctx,
                    s0,
                    depth + 1,
                );
            },
            .apply => |ap| {
                if (ap.func.* != .ident) return false;
                if (std.mem.eql(u8, marker.name, ap.func.*.ident) and
                    marker.args.len == ap.args.len)
                {
                    var i: usize = 0;
                    while (i < marker.args.len) : (i += 1) {
                        const actual = try self.eval_compiled_expr(
                            marker.args[i],
                            ctx,
                            s0,
                        );
                        const expected = try self.eval_fairness_arg(
                            ap.args[i],
                            bindings,
                            ctx,
                            s0,
                        );
                        if (!Value.eql_cross_pool(
                            actual,
                            self.eval_pool,
                            expected.value,
                            expected.pool,
                        )) return false;
                    }
                    return true;
                }
                return false;
            },
            .quantifier => |quantifier| {
                if (quantifier.kind != .exists) return false;
                return self.fairness_action_marker_matches(
                    marker,
                    quantifier.body,
                    bindings,
                    ctx,
                    s0,
                    depth + 1,
                );
            },
            .binary => |binary| {
                if (binary.op != .or_op) return false;
                return try self.fairness_action_marker_matches(
                    marker,
                    binary.left,
                    bindings,
                    ctx,
                    s0,
                    depth + 1,
                ) or try self.fairness_action_marker_matches(
                    marker,
                    binary.right,
                    bindings,
                    ctx,
                    s0,
                    depth + 1,
                );
            },
            else => return false,
        }
    }

    fn eval_fairness_arg(
        self: *const ActionExecutor,
        expr: *ast.Expr,
        bindings: []const FairnessBinding,
        ctx: Context,
        s0: ?*StateStore.State,
    ) !struct { value: Value, pool: *const ValuePool } {
        if (expr.* == .ident) {
            for (bindings) |binding| {
                if (std.mem.eql(u8, expr.*.ident, binding.name)) {
                    return .{
                        .value = binding.value,
                        .pool = &self.source_state_store.values_pool,
                    };
                }
            }
            if (try ctx.lookup_value(expr.*.ident, self.eval_pool)) |local| {
                return .{ .value = local, .pool = self.eval_pool };
            }
        }
        const context_snapshot = self.evaluator.context_snapshot();
        defer self.evaluator.restore_context_pool(context_snapshot);
        var fairness_ctx = ctx;
        for (bindings) |binding| {
            const local_value = try binding.value.clone(
                &self.source_state_store.values_pool,
                self.eval_pool,
            );
            fairness_ctx = try self.evaluator.extend_context(
                fairness_ctx,
                binding.name,
                local_value,
            );
        }
        return .{
            .value = try self.evaluator.eval_expr(
                expr,
                fairness_ctx,
                s0,
                self.eval_pool,
                &self.source_state_store.values_pool,
            ),
            .pool = self.eval_pool,
        };
    }

    fn fairness_bindings_match(
        self: *const ActionExecutor,
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
                &self.source_state_store.values_pool,
            )) return false;
        }
        return true;
    }

    fn commit_state(
        self: *const ActionExecutor,
        ctx: Context,
        s0: ?*StateStore.State,
        out_states: *StateBuffer,
        is_init: bool,
        action_mask: u64,
    ) !void {
        _ = is_init;
        if (self.enabled_probe) |probe| {
            probe.* = true;
            return;
        }
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
        new_state.changed_mask = if (s0 != null and
            self.source_state_store == self.candidate_store)
            s0.?.changed_mask
        else
            0;
        if (s0) |parent| {
            @memcpy(new_state.values, parent.values);
            if (self.source_state_store == self.candidate_store) {
                new_state.borrowed_mask = parent.borrowed_mask;
                new_state.borrowed_pool = parent.borrowed_pool;
            } else {
                new_state.borrowed_mask = if (new_state.values.len == 64)
                    std.math.maxInt(u64)
                else
                    (@as(u64, 1) << @as(u6, @intCast(new_state.values.len))) - 1;
                new_state.borrowed_pool = &self.source_state_store.values_pool;
                assert(parent.borrowed_mask == 0);
            }
        } else {
            @memset(new_state.values, Value{ .bool_v = false });
            new_state.borrowed_mask = 0;
            new_state.borrowed_pool = null;
        }

        var assignments = ctx.state_assignments();
        while (assignments.next()) |indexed| {
            const variable_index = indexed.variable_index;
            const assigned = indexed.value;
            assert(variable_index < new_state.values.len);
            const variable_bit = @as(u64, 1) << @intCast(variable_index);
            if (assigned.assignment != .changed) {
                if (s0 != null) continue;
                const source_pool = assigned.value_pool orelse self.eval_pool;
                new_state.values[variable_index] = try assigned.value.clone(
                    source_pool,
                    &self.candidate_store.values_pool,
                );
                continue;
            }

            const source_pool = assigned.value_pool orelse self.eval_pool;
            const no_change_check_worthwhile = switch (assigned.value) {
                .bool_v, .int_v, .model_v, .range_v => false,
                else => true,
            };
            if (no_change_check_worthwhile) {
                if (s0) |parent| {
                    const parent_pool = parent.value_pool(
                        variable_index,
                        &self.source_state_store.values_pool,
                    );
                    if (Value.eql_ordered_cross_pool(
                        assigned.value,
                        source_pool,
                        parent.values[variable_index],
                        parent_pool,
                    )) continue;
                }
            }
            new_state.changed_mask |= variable_bit;
            new_state.borrowed_mask &= ~variable_bit;
            new_state.values[variable_index] = try assigned.value.clone(
                source_pool,
                &self.candidate_store.values_pool,
            );
            if (builtin.mode == .debug or builtin.mode == .safe) {
                assert(Value.eql_cross_pool(
                    assigned.value,
                    source_pool,
                    new_state.values[variable_index],
                    &self.candidate_store.values_pool,
                ));
            }
        }
        if (self.edge_action_masks) |masks| {
            assert(out_states.items.len < masks.len);
            masks[out_states.items.len] = action_mask;
        }
        try out_states.append(new_idx);
        if (self.candidate_sink) |sink| {
            if (out_states == sink.target and
                out_states.items.len == out_states.storage.len)
            {
                try sink.consume(sink.context, out_states);
            }
        }
    }
};

test "action inlining avoids capture by nested function binders" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();

    const node_domain = try arena.alloc_object(ast.Expr);
    node_domain.* = .{ .ident = "Node" };
    const prospect = try arena.alloc_object(ast.Expr);
    prospect.* = .{ .ident = "prospect" };
    const function_literal = try arena.alloc_object(ast.FunctionLiteral);
    function_literal.* = .{
        .vars = &.{.{ .name = "n", .domain = node_domain }},
        .body = prospect,
    };
    const expression = try arena.alloc_object(ast.Expr);
    expression.* = .{ .function_literal = function_literal };
    const argument = try arena.alloc_object(ast.Expr);
    argument.* = .{ .ident = "n" };

    const inlined = try inline_expr(
        &arena,
        expression,
        &.{"prospect"},
        &.{argument},
    );
    try std.testing.expect(inlined.* == .function_literal);
    try std.testing.expect(!std.mem.eql(
        u8,
        inlined.function_literal.vars[0].name,
        "n",
    ));
    try std.testing.expect(inlined.function_literal.body.* == .ident);
    try std.testing.expectEqualStrings(
        "n",
        inlined.function_literal.body.ident,
    );
}

test "action compiler branches only existential assignments" {
    const parser = @import("parser.zig");
    const overrides = @import("overrides.zig");
    const source =
        \\---------------- MODULE ExistentialActions ----------------
        \\VARIABLE x
        \\Pure == \E i \in {1, 2} : i = x
        \\InitAction == \E i \in {1, 2} : x = i
        \\NextAction == \E i \in {1, 2} : x' = i
        \\=============================================================
        \\
    ;
    var arena = try Arena.init(4 * 1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    const module = try module_parser.parse_module();
    const evaluator = try Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    const compiler = try ActionCompiler.init(&arena, evaluator);

    const pure = evaluator.find_definition("Pure").?;
    const pure_init = try compiler.compile_init(pure.body);
    try std.testing.expectEqual(@as(usize, 1), pure_init.steps.len);
    try std.testing.expect(pure_init.steps[0] == .condition);

    const init_action = evaluator.find_definition("InitAction").?;
    const compiled_init = try compiler.compile_init(init_action.body);
    try std.testing.expectEqual(@as(usize, 1), compiled_init.steps.len);
    try std.testing.expect(compiled_init.steps[0] == .choose);

    const pure_next = try compiler.compile_next(init_action.body);
    try std.testing.expectEqual(@as(usize, 1), pure_next.steps.len);
    try std.testing.expect(pure_next.steps[0] == .condition);

    const next_action = evaluator.find_definition("NextAction").?;
    const compiled_next = try compiler.compile_next(next_action.body);
    try std.testing.expectEqual(@as(usize, 1), compiled_next.steps.len);
    try std.testing.expect(compiled_next.steps[0] == .choose);
}

test "action compiler enumerates bounded power-set choices directly" {
    const parser = @import("parser.zig");
    const overrides = @import("overrides.zig");
    const source =
        \\---------------- MODULE BoundedPowerSetAction ----------------
        \\VARIABLE x
        \\D == {1, 2, 3}
        \\Init == x = {}
        \\Next == \E r \in SUBSET D:
        \\          /\ r \subseteq {1, 2}
        \\          /\ {1} \subseteq r
        \\          /\ x' = r
        \\===============================================================
        \\
    ;
    var arena = try Arena.init(4 * 1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    const module = try module_parser.parse_module();
    const evaluator = try Evaluator.init(
        module,
        &arena,
        overrides.OverrideContext.default(),
    );
    const compiler = try ActionCompiler.init(&arena, evaluator);

    const next = evaluator.find_definition("Next").?;
    const compiled = try compiler.compile_next(next.body);
    try std.testing.expectEqual(@as(usize, 1), compiled.steps.len);
    try std.testing.expect(compiled.steps[0] == .bounded_power_set_choose);
    const choice = compiled.steps[0].bounded_power_set_choose;
    try std.testing.expect(choice.lower != null);
    try std.testing.expectEqual(@as(usize, 1), choice.body_steps.len);
    try std.testing.expect(choice.body_steps[0] == .assign_prime);
}
