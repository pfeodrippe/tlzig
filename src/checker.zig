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
const ConstantAssignment = @import("config.zig").ConstantAssignment;
const Constant = eval.Constant;
const parser = @import("parser.zig");

pub const Checker = struct {
    arena: *Arena,
    state_store: StateStore,
    queue: StateQueue,
    fp_set: FpSet,
    evaluator: Evaluator,
    init_spec: action.CompiledInit,
    next_spec: action.CompiledNext,
    invariants: []const *ast.Expr,
    constraints: []const *ast.Expr,
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
        eval_arena_bytes: u64,
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
        evaluator.set_treat_unknown_as_model(true);
        const aliases = try evaluate_aliases(arena, cfg);
        evaluator.set_aliases(aliases);
        const constants = try evaluate_constants(arena, cfg, &evaluator, &state_store.values_pool);
        evaluator.set_constants(constants);
        evaluator.set_treat_unknown_as_model(false);
        const compiler = ActionCompiler.init(arena, evaluator);

        const init_name_v = cfg.init_name orelse blk: {
            if (cfg.spec_name) |sn| {
                if (extract_spec_names(module, sn)) |names| {
                    break :blk names.init;
                } else |_| {}
            }
            break :blk find_init_name(module) orelse return Error.ConfigError;
        };
        const next_name_v = cfg.next_name orelse blk: {
            if (cfg.spec_name) |sn| {
                if (extract_spec_names(module, sn)) |names| {
                    break :blk names.next;
                } else |_| {}
            }
            break :blk find_next_name(module) orelse return Error.ConfigError;
        };

        const init_def = evaluator.find_definition(init_name_v) orelse {
            std.debug.print("undefined init def: {s}\n", .{init_name_v});
            return Error.UndefinedSymbol;
        };
        const next_def = evaluator.find_definition(next_name_v) orelse {
            std.debug.print("undefined next def: {s}\n", .{next_name_v});
            return Error.UndefinedSymbol;
        };

        const compiled_init = try compiler.compile_init(init_def.body);
        const compiled_next = try compiler.compile_next(next_def.body);

        var invariant_exprs = std.ArrayList(*ast.Expr).empty;
        defer invariant_exprs.deinit(std.heap.page_allocator);
        for (cfg.invariants) |inv_name| {
            const def = evaluator.find_definition(inv_name) orelse {
                std.debug.print("undefined invariant: {s}\n", .{inv_name});
                return Error.UndefinedSymbol;
            };
            try invariant_exprs.append(std.heap.page_allocator, def.body);
        }

        const invariants: []const *ast.Expr = if (invariant_exprs.items.len == 0) &[_]*ast.Expr{} else blk: {
            const result = try arena.alloc(*ast.Expr, invariant_exprs.items.len);
            for (invariant_exprs.items, 0..) |inv, i| {
                result[i] = inv;
            }
            break :blk result;
        };

        var constraint_exprs = std.ArrayList(*ast.Expr).empty;
        defer constraint_exprs.deinit(std.heap.page_allocator);
        for (cfg.constraints) |cname| {
            const def = evaluator.find_definition(cname) orelse {
                std.debug.print("undefined constraint: {s}\n", .{cname});
                return Error.UndefinedSymbol;
            };
            try constraint_exprs.append(std.heap.page_allocator, def.body);
        }
        const constraints: []const *ast.Expr = if (constraint_exprs.items.len == 0) &[_]*ast.Expr{} else blk: {
            const result = try arena.alloc(*ast.Expr, constraint_exprs.items.len);
            for (constraint_exprs.items, 0..) |c, i| {
                result[i] = c;
            }
            break :blk result;
        };

        var eval_arena = try Arena.init(eval_arena_bytes);
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
            .constraints = constraints,
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
            self.eval_pool.restore(self.eval_pool.snapshot());
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
            const fp = fingerprint.hash_state(&self.state_store.values_pool, st.values);
            const snap = self.eval_pool.snapshot();
            const constraints_hold = try self.check_constraints(st);
            const invariants_hold = try self.check_invariants(st);
            self.eval_pool.restore(snap);
            if (!constraints_hold or !invariants_hold) {
                if (!invariants_hold) {
                    std.debug.print("InvariantViolated generated={d} distinct={d}\n", .{ self.generated, self.distinct });
                    return Error.InvariantViolated;
                }
                continue;
            }
            if (self.fp_set.put(fp)) {
                self.distinct += 1;
                if (!self.queue.enqueue(idx)) {
                    return Error.StateSpaceExhausted;
                }
            }
        }
    }

    fn check_constraints(self: *Checker, st: *StateStore.State) !bool {
        for (self.constraints) |c| {
            const v = try self.evaluator.eval_expr(c, Context.empty(), st, &self.eval_pool, &self.state_store.values_pool);
            if (!v.is_truthy()) return false;
        }
        return true;
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

const SpecNames = struct {
    init: []const u8,
    next: []const u8,
};

fn resolve_definition(module: ast.Module, name: []const u8) ?*ast.Expr {
    for (module.definitions) |d| {
        if (std.mem.eql(u8, d.name, name)) return d.body;
    }
    return null;
}

fn extract_spec_names(module: ast.Module, spec_name: []const u8) !SpecNames {
    for (module.definitions) |d| {
        if (!std.mem.eql(u8, d.name, spec_name)) continue;
        var conj: *ast.Expr = d.body;
        // Resolve aliases and ignore fairness/justice/property conjuncts.
        var steps: u32 = 0;
        while (steps < 16) : (steps += 1) {
            switch (conj.*) {
                .ident => |name| {
                    if (resolve_definition(module, name)) |b| {
                        conj = b;
                        continue;
                    }
                },
                .binary => |b| {
                    if (b.op == .and_op) {
                        var right = b.right;
                        for (0..4) |_| {
                            switch (right.*) {
                                .ident => |n| {
                                    if (resolve_definition(module, n)) |rb| {
                                        right = rb;
                                        continue;
                                    }
                                },
                                else => break,
                            }
                            break;
                        }
                        const right_name = try action_name(right);
                        if (right_name != null) {
                            return SpecNames{
                                .init = try init_name(b.left) orelse return Error.ConfigError,
                                .next = right_name.?,
                            };
                        }
                        // Right conjunct is not the action (fairness/property/print); drop it.
                        conj = b.left;
                        continue;
                    }
                },
                else => {},
            }
            break;
        }
        return Error.ConfigError;
    }
    return Error.ConfigError;
}

fn action_name(expr: *ast.Expr) error{ConfigError}!?[]const u8 {
    // [][Next]_vars
    switch (expr.*) {
        .box_action => |ba| return ba.action_name,
        .unary => |u| return try action_name(u.operand),
        .binary => |b| {
            if (b.op == .and_op) {
                const left = try action_name(b.left);
                if (left != null) return left;
                return try action_name(b.right);
            }
        },
        else => {},
    }
    return null;
}

fn init_name(expr: *ast.Expr) error{ConfigError}!?[]const u8 {
    switch (expr.*) {
        .ident => |name| return name,
        else => return null,
    }
}

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
    var values = std.ArrayList(Constant).empty;
    defer values.deinit(std.heap.page_allocator);
    for (cfg.constants) |ca| {
        if (ca.is_substitution and is_operator_alias(ca.expr)) continue;
        const value = try evaluate_config_expr(arena, ca, evaluator, state_pool);
        try values.append(std.heap.page_allocator, Constant{
            .name = ca.name,
            .value = value,
        });
    }
    return try dup_slice(arena, Constant, values.items);
}

fn dup_slice(arena: *Arena, comptime T: type, items: []const T) ![]const T {
    if (items.len == 0) return &[_]T{};
    const result = try arena.alloc(T, items.len);
    @memcpy(result, items);
    return result;
}

fn evaluate_aliases(arena: *Arena, cfg: Config) ![]const eval.Alias {
    var aliases = std.ArrayList(eval.Alias).empty;
    defer aliases.deinit(std.heap.page_allocator);
    for (cfg.constants) |ca| {
        if (!ca.is_substitution) continue;
        const trimmed = std.mem.trim(u8, ca.expr, " \t");
        if (is_operator_alias(trimmed)) {
            try aliases.append(std.heap.page_allocator, eval.Alias{
                .from = try arena.dup(ca.name),
                .to = try arena.dup(trimmed),
            });
        }
    }
    return try dup_slice(arena, eval.Alias, aliases.items);
}

fn is_operator_alias(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return false;
    if (!std.ascii.isAlphabetic(trimmed[0])) return false;
    for (trimmed[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn evaluate_config_expr(arena: *Arena, ca: ConstantAssignment, evaluator: *Evaluator, state_pool: *ValuePool) !Value {
    const trimmed = std.mem.trim(u8, ca.expr, " \t");
    if (trimmed.len == 0) return error.SyntaxError;

    if (ca.is_substitution) {
        const expr = try parser.Parser.parse_expr_string(arena, trimmed);
        return try evaluator.eval_expr(expr, Context.empty(), null, state_pool, state_pool);
    }

    // A constant assignment of the form C = C declares C to be a model value,
    // overriding any module definition of the same name.
    if (std.mem.eql(u8, trimmed, ca.name) and evaluator.treat_unknown_as_model) {
        const id = try evaluator.models.intern(ca.name);
        return Value{ .model_v = id };
    }

    // Parse the right-hand side as a TLA+ expression so nested sets, ranges,
    // and model values are handled by the real parser/evaluator.
    const expr = try parser.Parser.parse_expr_string(arena, trimmed);
    return try evaluator.eval_expr(expr, Context.empty(), null, state_pool, state_pool);
}
