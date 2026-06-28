const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Arena = @import("arena.zig").Arena;
const ast = @import("ast.zig");
const value = @import("value.zig");
const Value = value.Value;
const ValuePool = value.ValuePool;
const Function = value.Function;
const Set = value.Set;
const fingerprint = @import("fingerprint.zig");
const state = @import("state.zig");
const StateStore = state.StateStore;
const Error = @import("err.zig").Error;
const ModelTable = value.ModelTable;
const overrides = @import("overrides.zig");
const generated_runtime = @import("generated_runtime.zig");

pub const Constant = generated_runtime.NamedValue;

pub const Context = struct {
    head: ?*const ContextBinding,
    len: u8,

    pub fn empty() Context {
        return .{ .head = null, .len = 0 };
    }

    pub fn lookup(self: Context, name: []const u8) ?Value {
        const binding = self.lookup_binding(name) orelse return null;
        return binding.value;
    }

    fn lookup_binding(self: Context, name: []const u8) ?*const ContextBinding {
        var binding = self.head;
        while (binding) |current| {
            if (name_eql(current.name, name)) return current;
            binding = current.parent;
        }
        return null;
    }

    pub fn lookup_state(self: Context, variable_index: u32) ?StateContextValue {
        var binding = self.head;
        while (binding) |current| {
            if (current.variable_index == variable_index) {
                assert(current.assignment != .local);
                return .{
                    .value = current.value,
                    .assignment = current.assignment,
                };
            }
            binding = current.parent;
        }
        return null;
    }

    pub fn collect_state_assignments(
        self: Context,
        assignments: []?StateContextValue,
    ) void {
        var binding = self.head;
        while (binding) |current| : (binding = current.parent) {
            const variable_index = current.variable_index orelse continue;
            assert(current.assignment != .local);
            assert(variable_index < assignments.len);
            if (assignments[variable_index] != null) continue;
            assignments[variable_index] = .{
                .value = current.value,
                .assignment = current.assignment,
            };
        }
    }
};

pub const StateContextValue = struct {
    value: Value,
    assignment: AssignmentKind,
};

const ContextBinding = struct {
    parent: ?*const ContextBinding,
    name: []const u8,
    variable_index: ?u32,
    value: Value,
    assignment: AssignmentKind,
};

pub const AssignmentKind = enum {
    local,
    changed,
    unchanged,
};

const ContextPool = struct {
    bindings: []ContextBinding,
    count: u32,

    fn init(arena: *Arena) !ContextPool {
        return .{
            .bindings = try arena.alloc(ContextBinding, 131_072),
            .count = 0,
        };
    }

    fn reset(self: *ContextPool) void {
        assert(self.count <= self.bindings.len);
        self.count = 0;
    }

    fn snapshot(self: *const ContextPool) u32 {
        assert(self.count <= self.bindings.len);
        return self.count;
    }

    fn restore(self: *ContextPool, saved_count: u32) void {
        assert(saved_count <= self.count);
        self.count = saved_count;
    }

    fn extend(
        self: *ContextPool,
        context: Context,
        name: []const u8,
        variable_index: ?u32,
        value_v: Value,
        assignment: AssignmentKind,
    ) Error!Context {
        assert(context.len < 32);
        assert((assignment == .local) == (variable_index == null));
        if (self.count >= self.bindings.len) return Error.OutOfMemory;
        const binding = &self.bindings[self.count];
        self.count += 1;
        binding.* = .{
            .parent = context.head,
            .name = name,
            .variable_index = variable_index,
            .value = value_v,
            .assignment = assignment,
        };
        return .{
            .head = binding,
            .len = context.len + 1,
        };
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

const ApplicationGroup = struct {
    args: []const *ast.Expr,
};

pub const ErrorContext = struct {
    context: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    active: bool = false,
};

const MemoEntry = struct {
    name: []const u8,
    value: Value,
};

const DefinitionMemo = struct {
    pool: ?*ValuePool = null,
    frozen: bool = false,
    count: u16 = 0,
    entries: [1024]MemoEntry = undefined,

    fn reset(self: *DefinitionMemo, pool: ?*ValuePool) void {
        self.pool = pool;
        self.frozen = false;
        self.count = 0;
    }

    fn freeze(self: *DefinitionMemo) void {
        assert(self.pool != null);
        self.frozen = true;
    }

    fn get(
        self: *const DefinitionMemo,
        pool: *ValuePool,
        name: []const u8,
    ) ?Value {
        if (self.pool != pool) return null;
        for (self.entries[0..self.count]) |entry| {
            if (name_eql(entry.name, name)) return entry.value;
        }
        return null;
    }

    fn put(
        self: *DefinitionMemo,
        pool: *ValuePool,
        name: []const u8,
        value_v: Value,
    ) Error!void {
        if (self.pool != pool or self.frozen) return;
        if (self.count >= self.entries.len) return Error.OutOfMemory;
        self.entries[self.count] = .{ .name = name, .value = value_v };
        self.count += 1;
        assert(self.count <= self.entries.len);
    }
};

pub const Evaluator = struct {
    module: ast.Module,
    constants: []const Constant,
    constant_slots: []?Value,
    aliases: []const Alias,
    models: *ModelTable,
    override_registry: overrides.Registry,
    treat_unknown_as_model: bool,
    next_state: ?*state.StateStore.State,
    enabled_result: ?bool,
    definition_memo: *DefinitionMemo,
    generated_cache_pool: *ValuePool,
    generated_cache: []?Value,
    context_pool: *ContextPool,
    /// Error context stored via pointer so all by-value copies share state.
    err_ctx: *ErrorContext,

    pub fn init(module: ast.Module, arena: *Arena, override_ctx: overrides.OverrideContext) !Evaluator {
        return init_generated(module, arena, override_ctx, &.{}, &.{});
    }

    pub fn init_generated(
        module: ast.Module,
        arena: *Arena,
        override_ctx: overrides.OverrideContext,
        generated: []const generated_runtime.Operator,
        generated_expressions: []const generated_runtime.Expression,
    ) !Evaluator {
        const models = try arena.alloc_object(ModelTable);
        models.* = try ModelTable.init(arena, 1024);
        const err_ctx = try arena.alloc_object(ErrorContext);
        err_ctx.* = .{};
        const definition_memo = try arena.alloc_object(DefinitionMemo);
        definition_memo.* = .{};
        const generated_cache_pool = try arena.alloc_object(ValuePool);
        generated_cache_pool.* = try ValuePool.init(arena, 4096, 4096);
        const generated_cache = try arena.alloc(?Value, module.definitions.len);
        @memset(generated_cache, null);
        const context_pool = try arena.alloc_object(ContextPool);
        context_pool.* = try ContextPool.init(arena);
        const constant_slots = try arena.alloc(?Value, module.constants.len);
        @memset(constant_slots, null);
        var override_registry = overrides.default_registry(override_ctx);
        override_registry.generated = generated;
        override_registry.generated_expressions = generated_expressions;
        return Evaluator{
            .module = module,
            .constants = &[_]Constant{},
            .constant_slots = constant_slots,
            .aliases = &[_]Alias{},
            .models = models,
            .override_registry = override_registry,
            .treat_unknown_as_model = false,
            .next_state = null,
            .enabled_result = null,
            .definition_memo = definition_memo,
            .generated_cache_pool = generated_cache_pool,
            .generated_cache = generated_cache,
            .context_pool = context_pool,
            .err_ctx = err_ctx,
        };
    }

    pub fn set_treat_unknown_as_model(self: *Evaluator, enable: bool) void {
        self.treat_unknown_as_model = enable;
    }

    pub fn fork(self: Evaluator, arena: *Arena) !Evaluator {
        const err_ctx = try arena.alloc_object(ErrorContext);
        err_ctx.* = .{};
        const definition_memo = try arena.alloc_object(DefinitionMemo);
        definition_memo.* = .{};
        const generated_cache_pool = try arena.alloc_object(ValuePool);
        generated_cache_pool.* = try ValuePool.init(arena, 4096, 4096);
        const generated_cache = try arena.alloc(?Value, self.module.definitions.len);
        @memset(generated_cache, null);
        const context_pool = try arena.alloc_object(ContextPool);
        context_pool.* = try ContextPool.init(arena);
        const constant_slots = try arena.alloc(
            ?Value,
            self.module.constants.len,
        );
        @memset(constant_slots, null);
        var copy = self;
        copy.next_state = null;
        copy.enabled_result = null;
        copy.definition_memo = definition_memo;
        copy.generated_cache_pool = generated_cache_pool;
        copy.generated_cache = generated_cache;
        copy.context_pool = context_pool;
        copy.constant_slots = constant_slots;
        copy.err_ctx = err_ctx;
        return copy;
    }

    pub fn reset_context_pool(self: Evaluator) void {
        self.context_pool.reset();
    }

    pub fn context_snapshot(self: Evaluator) u32 {
        return self.context_pool.snapshot();
    }

    pub fn restore_context_pool(self: Evaluator, saved_count: u32) void {
        self.context_pool.restore(saved_count);
    }

    pub fn extend_context(
        self: Evaluator,
        context: Context,
        name: []const u8,
        value_v: Value,
    ) Error!Context {
        return self.context_pool.extend(context, name, null, value_v, .local);
    }

    pub fn extend_state_context(
        self: Evaluator,
        context: Context,
        name: []const u8,
        variable_index: u32,
        value_v: Value,
        assignment: AssignmentKind,
    ) Error!Context {
        assert(assignment != .local);
        assert(variable_index < self.module.variables.len);
        assert(name_eql(name, self.module.variables[variable_index]));
        return self.context_pool.extend(
            context,
            name,
            variable_index,
            value_v,
            assignment,
        );
    }

    pub fn context_assignment(
        self: Evaluator,
        context: Context,
        name: []const u8,
    ) AssignmentKind {
        _ = self;
        return if (context.lookup_binding(name)) |binding|
            binding.assignment
        else
            .local;
    }

    pub fn eval_named_zero(
        self: Evaluator,
        name: []const u8,
        context: Context,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const resolved = self.resolve_alias(name);
        if (self.override_registry.find_generated(resolved, 0)) |function| {
            return self.call_generated(
                function,
                &.{},
                context,
                current_state,
                eval_pool,
                state_pool,
            );
        }
        const definition = self.find_definition(resolved) orelse
            return Error.UndefinedSymbol;
        if (definition.params.len != 0) return Error.TypeError;
        return self.eval_expr(
            definition.body,
            context,
            current_state,
            eval_pool,
            state_pool,
        );
    }

    pub fn find_generated_expression(
        self: Evaluator,
        identity: u32,
    ) ?generated_runtime.Expression {
        return self.override_registry.find_generated_expression(identity);
    }

    pub fn generated_expression_count(self: Evaluator) usize {
        return self.override_registry.generated_expressions.len;
    }

    pub fn eval_generated_expression(
        self: Evaluator,
        expression: generated_runtime.Expression,
        context: Context,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (expression.arg_names.len > 32) return Error.NotImplemented;
        if (expression.arg_required.len != 0 and
            expression.arg_required.len != expression.arg_names.len)
        {
            return Error.TypeError;
        }
        var args: [32]Value = undefined;
        for (expression.arg_names, 0..) |name, index| {
            args[index] = context.lookup(name) orelse
                if (expression.arg_required.len == 0 or
                    expression.arg_required[index])
                    return Error.UndefinedSymbol
                else
                    Value{ .bool_v = false };
        }
        const result = try self.call_generated(
            expression.function,
            args[0..expression.arg_names.len],
            context,
            current_state,
            eval_pool,
            state_pool,
        );
        return result;
    }

    pub fn eval_generated_expression_bool(
        self: Evaluator,
        expression: generated_runtime.Expression,
        context: Context,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!bool {
        const boolean_function = expression.boolean_function orelse {
            const result = try self.eval_generated_expression(
                expression,
                context,
                current_state,
                eval_pool,
                state_pool,
            );
            return result.is_truthy();
        };
        if (expression.arg_names.len > 32) return Error.NotImplemented;
        if (expression.arg_required.len != 0 and
            expression.arg_required.len != expression.arg_names.len)
        {
            return Error.TypeError;
        }
        var args: [32]Value = undefined;
        for (expression.arg_names, 0..) |name, index| {
            args[index] = context.lookup(name) orelse
                if (expression.arg_required.len == 0 or
                    expression.arg_required[index])
                    return Error.UndefinedSymbol
                else
                    Value{ .bool_v = false };
        }
        return try self.call_generated_bool(
            boolean_function,
            args[0..expression.arg_names.len],
            context,
            current_state,
            eval_pool,
            state_pool,
        );
    }

    pub fn make_generated_expression_operator(
        self: Evaluator,
        expression: generated_runtime.Expression,
        arity: u16,
        context: Context,
        eval_pool: *ValuePool,
    ) Error!Value {
        _ = self;
        if (arity > expression.arg_names.len) return Error.TypeError;
        const capture_count = expression.arg_names.len - arity;
        const captures = try eval_pool.alloc_values(@intCast(capture_count));
        for (expression.arg_names[0..capture_count], 0..) |name, index| {
            captures[index] = context.lookup(name) orelse
                return Error.UndefinedSymbol;
        }
        const offset: u32 = if (captures.len == 0)
            0
        else
            @intCast(
                (@intFromPtr(captures.ptr) -
                    @intFromPtr(eval_pool.values.ptr)) /
                    @sizeOf(Value),
            );
        return .{ .generated_operator_v = .{
            .function_address = @intFromPtr(expression.function),
            .arity = arity,
            .captured_offset = offset,
            .captured_len = @intCast(captures.len),
        } };
    }

    pub fn set_next_state(self: *Evaluator, st: ?*state.StateStore.State) void {
        self.next_state = st;
    }

    pub fn set_enabled_result(self: *Evaluator, enabled: ?bool) void {
        self.enabled_result = enabled;
    }

    pub fn set_definition_memo_pool(
        self: *Evaluator,
        pool: ?*ValuePool,
    ) void {
        self.definition_memo.reset(pool);
    }

    pub fn freeze_definition_memo(self: *Evaluator) void {
        self.definition_memo.freeze();
    }

    pub fn set_constants(self: *Evaluator, constants: []const Constant) void {
        self.constants = constants;
        @memset(self.constant_slots, null);
        for (self.module.constants, 0..) |name, index| {
            for (constants) |constant| {
                if (name_eql(name, constant.name)) {
                    self.constant_slots[index] = constant.value;
                    break;
                }
            }
        }
    }

    pub fn set_aliases(self: *Evaluator, aliases: []const Alias) void {
        self.aliases = aliases;
    }

    /// Record error context and return the error. Always use this in hot paths
    /// so the top-level handler can print what went wrong.
    pub fn fail(self: Evaluator, err: Error, context: []const u8, detail: []const u8) Error {
        self.err_ctx.context = context;
        self.err_ctx.detail = detail;
        return err;
    }

    pub fn resolve_alias(self: Evaluator, name: []const u8) []const u8 {
        for (self.aliases) |a| {
            if (name_eql(name, a.from)) return a.to;
        }
        return name;
    }

    pub fn find_constant(self: Evaluator, name: []const u8) ?Value {
        for (self.constants) |c| {
            if (name_eql(c.name, name)) return c.value;
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
        assert(@intFromPtr(expr) != 0);
        assert(eval_pool.value_count <= eval_pool.value_cap);
        assert(state_pool.value_count <= state_pool.value_cap);
        const root_call = !self.err_ctx.active;
        if (root_call) {
            if (ctx.len == 0) self.context_pool.reset();
            self.err_ctx.context = null;
            self.err_ctx.detail = null;
            self.err_ctx.active = true;
        }
        defer if (root_call) {
            assert(self.err_ctx.active);
            self.err_ctx.active = false;
        };
        const result = self.eval_expr_inner(expr, ctx, s0, eval_pool, state_pool);
        return result catch |err| {
            if (err == Error.TypeError and self.err_ctx.context == null) {
                self.err_ctx.context = "expr";
                self.err_ctx.detail = @tagName(expr.*);
            }
            return err;
        };
    }

    fn eval_expr_inner(
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
                        return try st.values[idx].clone(
                            st.value_pool(idx, state_pool),
                            eval_pool,
                        );
                    }
                }
                if (ctx.lookup(name)) |v| return v;
                if (self.find_constant(name)) |v| return try v.clone(state_pool, eval_pool);
                const aliased = self.resolve_alias(name);
                if (self.override_registry.find_value(aliased)) |func| {
                    return try func(self.override_registry.ctx, eval_pool);
                }
                // Check if the aliased name is a constant.
                if (!std.mem.eql(u8, aliased, name)) {
                    if (self.find_constant(aliased)) |v| return try v.clone(state_pool, eval_pool);
                }
                // Built-in constant sets.
                if (std.mem.eql(u8, aliased, "Nat")) {
                    // Nat = set of all natural numbers. Represent as a special
                    // range_v with hi = maxInt so membership checks work.
                    return Value{ .range_v = .{ .lo = 0, .hi = std.math.maxInt(i64) } };
                }
                if (std.mem.eql(u8, aliased, "Int")) {
                    return Value{ .range_v = .{
                        .lo = std.math.minInt(i64),
                        .hi = std.math.maxInt(i64),
                    } };
                }
                if (std.mem.eql(u8, aliased, "BOOLEAN")) {
                    const dest = try eval_pool.alloc_values(2);
                    dest[0] = Value{ .bool_v = false };
                    dest[1] = Value{ .bool_v = true };
                    return Value{ .set_v = make_set(eval_pool, dest) };
                }
                if (std.mem.eql(u8, aliased, "STRING")) {
                    // STRING (set of all strings) — represented as a model value
                    // that can be checked for membership.
                    return Value{ .string_v = try eval_pool.push_string("__STRING_SET__") };
                }
                if (self.override_registry.find_generated(
                    aliased,
                    0,
                )) |func| {
                    return try self.call_generated(
                        func,
                        &.{},
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                }
                if (self.find_definition(aliased)) |def| {
                    if (def.is_function) {
                        return try self.make_recursive_function(def, ctx, eval_pool);
                    }
                    if (def.params.len != 0) {
                        return try self.make_lambda(def, ctx, eval_pool);
                    }
                    if (s0 == null and ctx.len == 0) {
                        if (self.definition_memo.get(eval_pool, aliased)) |v| {
                            return v;
                        }
                        const v = try self.eval_expr(
                            def.body,
                            ctx,
                            s0,
                            eval_pool,
                            state_pool,
                        );
                        try self.definition_memo.put(
                            eval_pool,
                            aliased,
                            v,
                        );
                        return v;
                    }
                    return try self.eval_expr(
                        def.body,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                }
                if (self.find_subexpression(aliased)) |body| {
                    return try self.eval_expr(body, ctx, s0, eval_pool, state_pool);
                }
                if (self.treat_unknown_as_model) {
                    const id = try self.models.intern(name);
                    return Value{ .model_v = id };
                }
                return self.fail(Error.UndefinedSymbol, "ident", name);
            },
            .primed => |name| {
                if (ctx.lookup(name)) |v| return v;
                const ns = self.next_state;
                if (ns) |nst| {
                    if (self.find_variable(name)) |idx| {
                        return try nst.values[idx].clone(
                            nst.value_pool(idx, state_pool),
                            eval_pool,
                        );
                    }
                    const aliased = self.resolve_alias(name);
                    if (self.find_definition(aliased)) |def| {
                        if (def.params.len != 0) return Error.TypeError;
                        return try self.eval_expr(def.body, ctx, ns, eval_pool, state_pool);
                    }
                }
                if (s0) |st| {
                    if (self.find_variable(name)) |idx| {
                        return try st.values[idx].clone(
                            st.value_pool(idx, state_pool),
                            eval_pool,
                        );
                    }
                }
                const aliased = self.resolve_alias(name);
                if (self.find_definition(aliased)) |def| {
                    if (def.params.len != 0) return Error.TypeError;
                    if (ns) |next| {
                        return try self.eval_expr(
                            def.body,
                            ctx,
                            next,
                            eval_pool,
                            state_pool,
                        );
                    }
                    const current = s0 orelse
                        return self.fail(
                            Error.TypeError,
                            "primed definition without current state",
                            name,
                        );
                    return try self.eval_primed_definition(
                        def,
                        ctx,
                        current,
                        eval_pool,
                        state_pool,
                    );
                }
                return self.fail(Error.UndefinedSymbol, "primed", name);
            },
            .primed_expr => |operand| {
                const child = self.next_state orelse
                    return self.fail(Error.TypeError, "primed expression", "missing next state");
                return try self.eval_expr(
                    operand,
                    ctx,
                    child,
                    eval_pool,
                    state_pool,
                );
            },
            .binary => |b| {
                return self.eval_binary(
                    b,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                ) catch |err| {
                    if (err == Error.TypeError and
                        self.err_ctx.context == null)
                    {
                        self.err_ctx.context = "binary";
                        self.err_ctx.detail = @tagName(b.op);
                    }
                    return err;
                };
            },
            .unary => |u| {
                if (try eval_symbolic_set(self, expr, ctx, s0, eval_pool, state_pool)) |sv| return sv;
                return try self.eval_unary(u, ctx, s0, eval_pool, state_pool);
            },
            .if_then_else => |ite| {
                const c = try self.eval_expr(ite.cond, ctx, s0, eval_pool, state_pool);
                if (c.as_bool() orelse return Error.TypeError) {
                    return try self.eval_expr(ite.then_branch, ctx, s0, eval_pool, state_pool);
                }
                return try self.eval_expr(ite.else_branch, ctx, s0, eval_pool, state_pool);
            },
            .set_enum => |items| {
                if (items.len > 256) return self.fail(Error.NotImplemented, "set literal", "more than 256 elements");
                var scratch: [256]Value = undefined;
                for (items, 0..) |it, i| {
                    scratch[i] = try self.eval_expr(it, ctx, s0, eval_pool, state_pool);
                }
                const dest = try eval_pool.alloc_values(@intCast(items.len));
                @memcpy(dest, scratch[0..items.len]);
                return Value{ .set_v = make_set(eval_pool, dest) };
            },
            .set_filter => |sf| return try self.eval_set_filter(sf, ctx, s0, eval_pool, state_pool),
            .set_map => |sm| {
                if (try eval_symbolic_set(self, expr, ctx, s0, eval_pool, state_pool)) |sv| return sv;
                return try self.eval_set_map(sm, ctx, s0, eval_pool, state_pool);
            },
            .set_binary => |sb| {
                if (try eval_symbolic_set(self, expr, ctx, s0, eval_pool, state_pool)) |sv| return sv;
                return try self.eval_set_binary(sb, ctx, s0, eval_pool, state_pool);
            },
            .set_of_functions => |sf| return try self.eval_set_of_functions(sf, ctx, s0, eval_pool, state_pool),
            .record_set => |rs| {
                if (try eval_symbolic_set(self, expr, ctx, s0, eval_pool, state_pool)) |sv| return sv;
                return try self.eval_record_set(rs, ctx, s0, eval_pool, state_pool);
            },
            .function_literal => |fl| return try self.eval_function_literal(fl, ctx, s0, eval_pool, state_pool),
            .apply => |ap| return try self.eval_apply(ap, ctx, s0, eval_pool, state_pool),
            .field => |f| return try self.eval_field(f, ctx, s0, eval_pool, state_pool),
            .tuple => |t| {
                if (t.len > 64) return self.fail(Error.NotImplemented, "tuple literal", "more than 64 elements");
                var scratch: [64]Value = undefined;
                for (t, 0..) |it, i| {
                    scratch[i] = try self.eval_expr(it, ctx, s0, eval_pool, state_pool);
                }
                const dest = try eval_pool.alloc_values(@intCast(t.len));
                @memcpy(dest, scratch[0..t.len]);
                return Value{ .tuple_v = make_tuple(eval_pool, dest) };
            },
            .record => |r| {
                if (r.len > 64) return self.fail(Error.NotImplemented, "record literal", "more than 64 fields");
                var scratch: [128]Value = undefined;
                for (r, 0..) |field, i| {
                    scratch[i * 2] = Value{ .string_v = try eval_pool.push_string(field.name) };
                    scratch[i * 2 + 1] = try self.eval_expr(field.value, ctx, s0, eval_pool, state_pool);
                }
                const value_count = r.len * 2;
                const dest = try eval_pool.alloc_values(@intCast(value_count));
                @memcpy(dest, scratch[0..value_count]);
                return Value{ .record_v = make_record(eval_pool, dest) };
            },
            .quantifier => |q| return try self.eval_quantifier(q, ctx, s0, eval_pool, state_pool),
            .choose => |c| return try self.eval_choose(c, ctx, s0, eval_pool, state_pool),
            .unchanged => |names| {
                const parent = s0 orelse
                    return self.fail(Error.TypeError, "UNCHANGED", "missing parent state");
                const child = self.next_state orelse
                    return self.fail(Error.TypeError, "UNCHANGED", "missing next state");
                for (names) |name| {
                    if (self.find_variable(name)) |idx| {
                        if (!parent.values[idx].eql(child.values[idx], state_pool)) {
                            return Value{ .bool_v = false };
                        }
                        continue;
                    }
                    const def = self.find_definition(name) orelse
                        return self.fail(Error.UndefinedSymbol, "UNCHANGED", name);
                    if (def.params.len != 0) {
                        return self.fail(Error.TypeError, "UNCHANGED", name);
                    }
                    const parent_value = try self.eval_expr(
                        def.body,
                        ctx,
                        parent,
                        eval_pool,
                        state_pool,
                    );
                    const child_value = try self.eval_expr(
                        def.body,
                        ctx,
                        child,
                        eval_pool,
                        state_pool,
                    );
                    if (!parent_value.eql(child_value, eval_pool)) {
                        return Value{ .bool_v = false };
                    }
                }
                return Value{ .bool_v = true };
            },
            .unchanged_expr => |operand| {
                const parent = s0 orelse
                    return self.fail(Error.TypeError, "UNCHANGED", "missing parent state");
                const child = self.next_state orelse
                    return self.fail(Error.TypeError, "UNCHANGED", "missing next state");
                const parent_value = try self.eval_expr(
                    operand,
                    ctx,
                    parent,
                    eval_pool,
                    state_pool,
                );
                const child_value = try self.eval_expr(
                    operand,
                    ctx,
                    child,
                    eval_pool,
                    state_pool,
                );
                return Value{ .bool_v = parent_value.eql(child_value, eval_pool) };
            },
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
        const left = try self.eval_binary_operand(
            b,
            b.left,
            "left",
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        switch (b.op) {
            .and_op => {
                if (!left.is_truthy()) return Value{ .bool_v = false };
                const right = try self.eval_binary_operand(b, b.right, "right", ctx, s0, eval_pool, state_pool);
                return Value{ .bool_v = right.is_truthy() };
            },
            .or_op => {
                if (left.is_truthy()) return Value{ .bool_v = true };
                const right = try self.eval_binary_operand(b, b.right, "right", ctx, s0, eval_pool, state_pool);
                return Value{ .bool_v = right.is_truthy() };
            },
            .implies => {
                if (!left.is_truthy()) return Value{ .bool_v = true };
                const right = try self.eval_binary_operand(b, b.right, "right", ctx, s0, eval_pool, state_pool);
                return Value{ .bool_v = right.is_truthy() };
            },
            .equiv => {
                const right = try self.eval_binary_operand(b, b.right, "right", ctx, s0, eval_pool, state_pool);
                return Value{ .bool_v = left.is_truthy() == right.is_truthy() };
            },
            .in => {
                if (is_seq_application(b.right)) {
                    return Value{ .bool_v = try self.sequence_member(
                        left,
                        b.right.apply.args[0],
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    ) };
                }
                // Lazy SUBSET membership: x \in SUBSET S ⟺ x ⊆ S.
                // Check each element of x for membership in S without
                // materializing S (S could be Seq(...) or another lazy set).
                if (b.right.* == .unary and b.right.unary.op == .subset) {
                    const inner = b.right.unary.operand;
                    const s = try self.eval_expr(inner, ctx, s0, eval_pool, state_pool);
                    if (!s.is_set_like()) return self.fail(Error.TypeError, "\\in SUBSET", "rhs not set");
                    if (!left.is_set_like()) return Value{ .bool_v = false };
                    const lmat = try self.materialize_set(left, ctx, s0, eval_pool, state_pool);
                    if (lmat != .set_v) return self.fail(Error.TypeError, "\\in SUBSET", "lhs materialize failed");
                    // Check each element of left is a member of s.
                    const items = lmat.set_v.items(eval_pool);
                    for (items) |item| {
                        if (!s.member(eval_pool, item)) return Value{ .bool_v = false };
                    }
                    return Value{ .bool_v = true };
                }
                if (try eval_symbolic_set(self, b.right, ctx, s0, eval_pool, state_pool)) |right| {
                    assert(right.is_set_like());
                    return Value{ .bool_v = right.member(eval_pool, left) };
                }
                const right = try self.eval_expr(b.right, ctx, s0, eval_pool, state_pool);
                if (!right.is_set_like()) {
                    return self.fail(
                        Error.TypeError,
                        "\\in: rhs not a set",
                        @tagName(right),
                    );
                }
                return Value{ .bool_v = right.member(eval_pool, left) };
            },
            .notin => {
                if (is_seq_application(b.right)) {
                    return Value{ .bool_v = !try self.sequence_member(
                        left,
                        b.right.apply.args[0],
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    ) };
                }
                if (try eval_symbolic_set(self, b.right, ctx, s0, eval_pool, state_pool)) |right| {
                    assert(right.is_set_like());
                    return Value{ .bool_v = !right.member(eval_pool, left) };
                }
                const right = try self.eval_expr(b.right, ctx, s0, eval_pool, state_pool);
                if (!right.is_set_like()) return self.fail(Error.TypeError, "\\notin: rhs not a set", @tagName(right));
                return Value{ .bool_v = !right.member(eval_pool, left) };
            },
            else => {},
        }
        const right = try self.eval_binary_operand(
            b,
            b.right,
            "right",
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        return switch (b.op) {
            .eq => Value{ .bool_v = left.eql(right, eval_pool) },
            .ne => Value{ .bool_v = !left.eql(right, eval_pool) },
            .lt => Value{ .bool_v = (left.as_int() orelse return self.fail(Error.TypeError, "<", @tagName(left))) < (right.as_int() orelse return self.fail(Error.TypeError, "<", @tagName(right))) },
            .le => Value{ .bool_v = (left.as_int() orelse return self.fail(Error.TypeError, "<=", @tagName(left))) <= (right.as_int() orelse return self.fail(Error.TypeError, "<=", @tagName(right))) },
            .gt => Value{ .bool_v = (left.as_int() orelse return self.fail(Error.TypeError, ">", @tagName(left))) > (right.as_int() orelse return self.fail(Error.TypeError, ">", @tagName(right))) },
            .ge => Value{ .bool_v = (left.as_int() orelse return self.fail(Error.TypeError, ">=", @tagName(left))) >= (right.as_int() orelse return self.fail(Error.TypeError, ">=", @tagName(right))) },
            .subseteq => {
                if (!left.is_set_like() or !right.is_set_like()) return self.fail(Error.TypeError, "\\subseteq", @tagName(left));
                const lmat = try self.materialize_set(left, ctx, s0, eval_pool, state_pool);
                if (lmat != .set_v) return self.fail(Error.TypeError, "\\subseteq", "lhs materialize failed");
                for (lmat.set_v.items(eval_pool)) |item| {
                    if (!right.member(eval_pool, item)) return Value{ .bool_v = false };
                }
                return Value{ .bool_v = true };
            },
            .plus => {
                const lv = left.as_int() orelse return self.fail(Error.TypeError, "+", @tagName(left));
                const rv = right.as_int() orelse return self.fail(Error.TypeError, "+ right", @tagName(right));
                return Value{ .int_v = lv + rv };
            },
            .minus => Value{ .int_v = (left.as_int() orelse return self.fail(Error.TypeError, "-", @tagName(left))) - (right.as_int() orelse return self.fail(Error.TypeError, "-", @tagName(right))) },
            .times => Value{ .int_v = (left.as_int() orelse return self.fail(Error.TypeError, "*", @tagName(left))) * (right.as_int() orelse return self.fail(Error.TypeError, "*", @tagName(right))) },
            .div => {
                const denom = right.as_int() orelse return self.fail(Error.TypeError, "\\div", @tagName(right));
                if (denom == 0) return Error.DivisionByZero;
                return Value{ .int_v = @divTrunc(left.as_int() orelse return self.fail(Error.TypeError, "\\div", @tagName(left)), denom) };
            },
            .mod => {
                const denom = right.as_int() orelse return self.fail(Error.TypeError, "%", @tagName(right));
                if (denom == 0) return Error.DivisionByZero;
                return Value{ .int_v = @mod(left.as_int() orelse return self.fail(Error.TypeError, "%", @tagName(left)), denom) };
            },
            .power => {
                const base = left.as_int() orelse return self.fail(Error.TypeError, "^", @tagName(left));
                const exp = right.as_int() orelse return self.fail(Error.TypeError, "^", @tagName(right));
                if (exp < 0) return Error.DivisionByZero;
                var result: i64 = 1;
                var i: i64 = 0;
                while (i < exp) : (i += 1) result *= base;
                return Value{ .int_v = result };
            },
            .range => {
                const lo = left.as_int() orelse return self.fail(Error.TypeError, "..", @tagName(left));
                const hi = right.as_int() orelse return self.fail(Error.TypeError, "..", @tagName(right));
                return Value{ .range_v = .{ .lo = lo, .hi = hi } };
            },
            .concat => return try overrides.sequence_concat(self.override_registry.ctx, eval_pool, left, right),
            .ooverride => return try overrides.ooverride(self.override_registry.ctx, eval_pool, left, right),
            .recordto => return try overrides.recordto(self.override_registry.ctx, eval_pool, left, right),
            .leads_to => {
                // P ~> Q is a temporal operator; normal expression evaluation
                // should not encounter it.  Return true as a conservative stub
                // to avoid errors during state/action evaluation.
                return Value{ .bool_v = true };
            },
            else => {
                return self.fail(Error.NotImplemented, "binary", @tagName(b.op));
            },
        };
    }

    fn eval_binary_operand(
        self: Evaluator,
        binary: *ast.Binary,
        operand: *ast.Expr,
        side: []const u8,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        return self.eval_expr(
            operand,
            ctx,
            s0,
            eval_pool,
            state_pool,
        ) catch |err| {
            if (err == Error.TypeError and
                self.err_ctx.context != null and
                std.mem.eql(u8, self.err_ctx.context.?, "expr"))
            {
                self.err_ctx.context = side;
                self.err_ctx.detail = @tagName(binary.op);
            }
            return err;
        };
    }

    fn sequence_member(
        self: Evaluator,
        sequence: Value,
        element_set_expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!bool {
        const element_set = if (try eval_symbolic_set(self, element_set_expr, ctx, s0, eval_pool, state_pool)) |set|
            set
        else
            try self.eval_expr(element_set_expr, ctx, s0, eval_pool, state_pool);
        if (!element_set.is_set_like()) {
            return self.fail(Error.TypeError, "Seq", "argument is not a set");
        }

        switch (sequence) {
            .tuple_v => |tuple| {
                assert(tuple.offset + tuple.len <= eval_pool.value_count);
                for (tuple.items(eval_pool)) |element| {
                    if (!element_set.member(eval_pool, element)) return false;
                }
                return true;
            },
            .function_v => |function| {
                assert(function.offset + function.len <= eval_pool.value_count);
                assert(function.domain.len == function.len);
                var i: u32 = 0;
                while (i < function.len) : (i += 1) {
                    const element = function.apply(
                        eval_pool,
                        Value{ .int_v = @as(i64, @intCast(i)) + 1 },
                    ) orelse return false;
                    if (!element_set.member(eval_pool, element)) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    fn eval_unary(
        self: Evaluator,
        u: *ast.Unary,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        switch (u.op) {
            .enabled => return Value{ .bool_v = self.enabled_result orelse true },
            .temporal_box, .temporal_diamond => {
                // These operators are interpreted over the completed state
                // graph. Their operands must not be evaluated as state
                // expressions here (notably ENABLED actions have no next
                // state in this path).
                return Value{ .bool_v = true };
            },
            else => {},
        }
        const operand = try self.eval_expr(u.operand, ctx, s0, eval_pool, state_pool);
        return switch (u.op) {
            .not => Value{ .bool_v = !operand.is_truthy() },
            .neg => Value{ .int_v = -(operand.as_int() orelse return self.fail(Error.TypeError, "-", @tagName(operand))) },
            .subset => blk: {
                if (!operand.is_set_like()) return self.fail(Error.TypeError, "SUBSET", "non-set operand");
                const mat = try self.materialize_set(operand, ctx, s0, eval_pool, state_pool);
                break :blk try eval_subset(eval_pool, mat);
            },
            .union_all => blk: {
                if (!operand.is_set_like()) return self.fail(Error.TypeError, "UNION", "non-set operand");
                const mat = try self.materialize_set(operand, ctx, s0, eval_pool, state_pool);
                break :blk try eval_union_all(eval_pool, mat);
            },
            .domain => {
                if (operand == .function_v) return Value{ .set_v = operand.function_v.domain };
                if (operand == .record_v) {
                    const fields = operand.record_v.fields(eval_pool);
                    const names = try eval_pool.alloc_values(
                        operand.record_v.len,
                    );
                    var i: u32 = 0;
                    while (i < operand.record_v.len) : (i += 1) {
                        assert(fields[i * 2] == .string_v);
                        names[i] = fields[i * 2];
                    }
                    return Value{ .set_v = make_set(eval_pool, names) };
                }
                // Tuples (sequences) have domain 1..Len.
                if (operand == .tuple_v) {
                    const n = operand.tuple_v.len;
                    if (n == 0) {
                        const empty = try eval_pool.alloc_values(0);
                        return Value{ .set_v = make_set(eval_pool, empty) };
                    }
                    return Value{ .range_v = .{ .lo = 1, .hi = @intCast(n) } };
                }
                return self.fail(Error.TypeError, "DOMAIN", @tagName(operand));
            },
            .enabled, .temporal_box, .temporal_diamond => unreachable,
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
        if (sf.vars.len == 1) {
            const bv = sf.vars[0];
            if (try self.eval_function_set_filter(
                sf,
                bv,
                ctx,
                s0,
                eval_pool,
                state_pool,
            )) |filtered| {
                return filtered;
            }
            if (try self.eval_sorted_sequence_filter(sf, bv, ctx, s0, eval_pool, state_pool)) |sorted| {
                return sorted;
            }
            const domain = try self.eval_set_materialized(bv.domain, ctx, s0, eval_pool, state_pool);
            const items = domain.set_v.items(eval_pool);
            const accepted = try eval_pool.alloc_values(domain.set_v.len);
            const scratch_snapshot = eval_pool.snapshot();
            const context_snap = self.context_snapshot();
            var accepted_count: u32 = 0;
            for (items) |it| {
                const new_ctx = try self.extend_context(ctx, bv.name, it);
                const pred = try self.eval_expr(sf.pred, new_ctx, s0, eval_pool, state_pool);
                if (pred.is_truthy()) {
                    assert(accepted_count < accepted.len);
                    accepted[accepted_count] = it;
                    accepted_count += 1;
                }
                eval_pool.restore(scratch_snapshot);
                self.restore_context_pool(context_snap);
            }
            return Value{ .set_v = make_set(
                eval_pool,
                accepted[0..accepted_count],
            ) };
        }
        return try self.eval_set_filter_tuples(sf, 0, ctx, s0, eval_pool, state_pool);
    }

    fn eval_function_set_filter(
        self: Evaluator,
        sf: *ast.SetFilter,
        bv: ast.BoundVar,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        const function_set = switch (bv.domain.*) {
            .set_of_functions => |function_set| function_set,
            else => return null,
        };
        var domain = try self.eval_expr(
            function_set.domain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        var codomain = try self.eval_expr(
            function_set.codomain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (!domain.is_set_like() or !codomain.is_set_like()) {
            return Error.TypeError;
        }
        domain = try self.materialize_set(
            domain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        codomain = try self.materialize_set(
            codomain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (domain != .set_v or codomain != .set_v) return Error.TypeError;

        if (try self.eval_pointwise_function_set_filter(
            sf,
            bv,
            domain,
            codomain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        )) |filtered| {
            return filtered;
        }

        const domain_count = domain.set_v.len;
        const codomain_count = codomain.set_v.len;
        var candidate_count: u64 = 1;
        for (0..domain_count) |_| {
            candidate_count *= codomain_count;
            if (candidate_count > 262_144) return null;
        }
        assert(candidate_count <= 262_144);

        var accepted_bits: [4096]u64 = undefined;
        const word_count: usize = @intCast((candidate_count + 63) / 64);
        @memset(accepted_bits[0..word_count], 0);
        const scratch_snapshot = eval_pool.snapshot();
        const context_snap = self.context_snapshot();
        const codomain_values = codomain.set_v.items(eval_pool);
        var accepted_count: u32 = 0;
        var combo: u64 = 0;
        while (combo < candidate_count) : (combo += 1) {
            const entries = try eval_pool.alloc_values(domain_count);
            var tmp = combo;
            var i: u32 = 0;
            while (i < domain_count) : (i += 1) {
                const value_index: usize = @intCast(tmp % codomain_count);
                tmp /= codomain_count;
                entries[i] = codomain_values[value_index];
            }
            const candidate = Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, entries.ptr),
                .len = domain_count,
            } };
            const new_ctx = try self.extend_context(ctx, bv.name, candidate);
            const pred = try self.eval_expr(
                sf.pred,
                new_ctx,
                s0,
                eval_pool,
                state_pool,
            );
            if (pred.is_truthy()) {
                const word: usize = @intCast(combo / 64);
                const bit: u6 = @intCast(combo % 64);
                accepted_bits[word] |= @as(u64, 1) << bit;
                accepted_count += 1;
            }
            eval_pool.restore(scratch_snapshot);
            self.restore_context_pool(context_snap);
        }

        try eval_pool.ensure_value_capacity(
            accepted_count +
                @as(u64, accepted_count) * domain_count,
        );
        const accepted = try eval_pool.alloc_values(accepted_count);
        var accepted_index: u32 = 0;
        combo = 0;
        while (combo < candidate_count) : (combo += 1) {
            const word: usize = @intCast(combo / 64);
            const bit: u6 = @intCast(combo % 64);
            if (accepted_bits[word] & (@as(u64, 1) << bit) == 0) continue;

            const entries = try eval_pool.alloc_values(domain_count);
            var tmp = combo;
            var i: u32 = 0;
            while (i < domain_count) : (i += 1) {
                const value_index: usize = @intCast(tmp % codomain_count);
                tmp /= codomain_count;
                entries[i] = codomain_values[value_index];
            }
            assert(accepted_index < accepted_count);
            accepted[accepted_index] = Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, entries.ptr),
                .len = domain_count,
            } };
            accepted_index += 1;
        }
        assert(accepted_index == accepted_count);
        return Value{ .set_v = .{
            .offset = value_offset(eval_pool, accepted.ptr),
            .len = accepted_count,
        } };
    }

    fn eval_pointwise_function_set_filter(
        self: Evaluator,
        sf: *ast.SetFilter,
        bv: ast.BoundVar,
        domain: Value,
        codomain: Value,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        assert(domain == .set_v);
        assert(codomain == .set_v);
        const quantifier = switch (sf.pred.*) {
            .quantifier => |quantifier| quantifier,
            else => return null,
        };
        if (quantifier.kind != .forall or quantifier.vars.len != 1) {
            return null;
        }
        const key_var = quantifier.vars[0];
        if (!is_pointwise_function_predicate(
            quantifier.body,
            bv.name,
            key_var.name,
        )) return null;

        const quantified_domain = try self.eval_set_materialized(
            key_var.domain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (quantified_domain != .set_v or
            !quantified_domain.set_v.eql(domain.set_v, eval_pool))
        {
            return null;
        }

        const domain_count = domain.set_v.len;
        const codomain_count = codomain.set_v.len;
        if (domain_count > 256) return null;
        const pair_count =
            @as(u64, domain_count) * codomain_count;
        if (pair_count > 262_144) return null;

        var allowed_bits: [4096]u64 = undefined;
        const word_count: usize = @intCast((pair_count + 63) / 64);
        @memset(allowed_bits[0..word_count], 0);
        var allowed_counts: [256]u32 = @splat(0);
        const domain_values = domain.set_v.items(eval_pool);
        const codomain_values = codomain.set_v.items(eval_pool);
        const scratch_snapshot = eval_pool.snapshot();
        const context_snap = self.context_snapshot();

        for (domain_values, 0..) |key, domain_index| {
            for (codomain_values, 0..) |candidate_value, value_index| {
                const entries = try eval_pool.alloc_values(domain_count);
                @memset(entries, candidate_value);
                const candidate = Value{ .function_v = .{
                    .domain = domain.set_v,
                    .offset = value_offset(eval_pool, entries.ptr),
                    .len = domain_count,
                } };
                var predicate_ctx = try self.extend_context(
                    ctx,
                    bv.name,
                    candidate,
                );
                predicate_ctx = try self.extend_context(
                    predicate_ctx,
                    key_var.name,
                    key,
                );
                const predicate = try self.eval_expr(
                    quantifier.body,
                    predicate_ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                if (predicate.is_truthy()) {
                    const pair_index =
                        domain_index * codomain_count + value_index;
                    const word: usize = @intCast(pair_index / 64);
                    const bit: u6 = @intCast(pair_index % 64);
                    allowed_bits[word] |= @as(u64, 1) << bit;
                    allowed_counts[domain_index] += 1;
                }
                eval_pool.restore(scratch_snapshot);
                self.restore_context_pool(context_snap);
            }
            if (allowed_counts[domain_index] == 0) {
                const empty = try eval_pool.alloc_values(0);
                return Value{ .set_v = .{
                    .offset = value_offset(eval_pool, empty.ptr),
                    .len = 0,
                } };
            }
        }

        var accepted_count: u64 = 1;
        for (allowed_counts[0..domain_count]) |count| {
            accepted_count *= count;
            if (accepted_count > 262_144) return null;
        }
        try eval_pool.ensure_value_capacity(
            accepted_count +
                accepted_count * domain_count,
        );
        const accepted = try eval_pool.alloc_values(
            @intCast(accepted_count),
        );
        var combo: u64 = 0;
        while (combo < accepted_count) : (combo += 1) {
            const entries = try eval_pool.alloc_values(domain_count);
            var ordinal = combo;
            for (0..domain_count) |domain_index| {
                const allowed_ordinal =
                    ordinal % allowed_counts[domain_index];
                ordinal /= allowed_counts[domain_index];
                var seen: u32 = 0;
                var value_index: u32 = 0;
                while (value_index < codomain_count) : (value_index += 1) {
                    const pair_index =
                        domain_index * codomain_count + value_index;
                    const word: usize = @intCast(pair_index / 64);
                    const bit: u6 = @intCast(pair_index % 64);
                    if (allowed_bits[word] &
                        (@as(u64, 1) << bit) == 0) continue;
                    if (seen == allowed_ordinal) break;
                    seen += 1;
                }
                assert(value_index < codomain_count);
                entries[domain_index] = codomain_values[value_index];
            }
            accepted[combo] = Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, entries.ptr),
                .len = domain_count,
            } };
        }
        return Value{ .set_v = .{
            .offset = value_offset(eval_pool, accepted.ptr),
            .len = @intCast(accepted_count),
        } };
    }

    fn eval_set_filter_tuples(
        self: Evaluator,
        sf: *ast.SetFilter,
        var_idx: usize,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (var_idx >= sf.vars.len) {
            const pred = try self.eval_expr(sf.pred, ctx, s0, eval_pool, state_pool);
            return if (pred.is_truthy()) Value{ .bool_v = true } else Value{ .bool_v = false };
        }
        const bv = sf.vars[var_idx];
        const domain = try self.eval_set_materialized(bv.domain, ctx, s0, eval_pool, state_pool);
        var items = std.ArrayList(Value).empty;
        defer items.deinit(std.heap.page_allocator);
        try items.appendSlice(std.heap.page_allocator, domain.set_v.items(eval_pool));
        var tuples = std.ArrayList(Value).empty;
        defer tuples.deinit(std.heap.page_allocator);
        for (items.items) |it| {
            const new_ctx = try self.extend_context(ctx, bv.name, it);
            const nested = try self.eval_set_filter_tuples(sf, var_idx + 1, new_ctx, s0, eval_pool, state_pool);
            if (var_idx + 1 < sf.vars.len) {
                if (nested != .set_v) return Error.TypeError;
                var sub = std.ArrayList(Value).empty;
                defer sub.deinit(std.heap.page_allocator);
                try sub.appendSlice(std.heap.page_allocator, nested.set_v.items(eval_pool));
                for (sub.items) |t| {
                    var tuple_items = std.ArrayList(Value).empty;
                    defer tuple_items.deinit(std.heap.page_allocator);
                    try tuple_items.appendSlice(std.heap.page_allocator, t.tuple_v.items(eval_pool));
                    const extended = try eval_pool.alloc_values(@intCast(tuple_items.items.len + 1));
                    extended[0] = it;
                    @memcpy(extended[1..], tuple_items.items);
                    try tuples.append(std.heap.page_allocator, Value{ .tuple_v = make_tuple(eval_pool, extended) });
                }
            } else if (nested.is_truthy()) {
                const single = try eval_pool.alloc_values(1);
                single[0] = it;
                try tuples.append(std.heap.page_allocator, Value{ .tuple_v = make_tuple(eval_pool, single) });
            }
        }
        const dest = try eval_pool.alloc_values(@intCast(tuples.items.len));
        @memcpy(dest, tuples.items);
        return Value{ .set_v = make_set(eval_pool, dest) };
    }

    fn eval_sorted_sequence_filter(
        self: Evaluator,
        sf: *ast.SetFilter,
        bv: ast.BoundVar,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        if (!is_sorted_sequence_predicate(sf.pred, bv.name)) return null;
        const symbolic_domain = (try eval_symbolic_set(self, bv.domain, ctx, s0, eval_pool, state_pool)) orelse return null;

        var lengths = std.ArrayList(u32).empty;
        defer lengths.deinit(std.heap.page_allocator);
        const codomain = (try extract_sequence_codomain_and_lengths(eval_pool, symbolic_domain, &lengths)) orelse return null;
        if (lengths.items.len == 0) return null;

        const codomain_mat = try self.materialize_set(codomain, ctx, s0, eval_pool, state_pool);
        if (codomain_mat != .set_v) return null;
        var values = std.ArrayList(Value).empty;
        defer values.deinit(std.heap.page_allocator);
        try values.appendSlice(std.heap.page_allocator, codomain_mat.set_v.items(eval_pool));
        sort_values(eval_pool, values.items) orelse return null;

        var generated = std.ArrayList(Value).empty;
        defer generated.deinit(std.heap.page_allocator);
        var current = std.ArrayList(Value).empty;
        defer current.deinit(std.heap.page_allocator);
        for (lengths.items) |len| {
            try generate_sorted_sequences(eval_pool, values.items, len, 0, &current, &generated);
        }

        const dest = try eval_pool.alloc_values(@intCast(generated.items.len));
        @memcpy(dest, generated.items);
        // Generation is lexicographic over nondecreasing value indices, so
        // each sequence is produced exactly once. Running make_set here would
        // perform a quadratic equality scan over an already-canonical set.
        return Value{ .set_v = .{
            .offset = value_offset(eval_pool, dest.ptr),
            .len = @intCast(dest.len),
        } };
    }

    fn eval_set_map(
        self: Evaluator,
        sm: *ast.SetMap,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        var domains: [32]Value = undefined;
        if (sm.vars.len > domains.len) {
            return self.fail(
                Error.NotImplemented,
                "set map",
                "more than 32 bound variables",
            );
        }
        var total: u64 = 1;
        for (sm.vars, 0..) |bv, i| {
            const mat = try self.eval_set_materialized(bv.domain, ctx, s0, eval_pool, state_pool);
            assert(mat == .set_v);
            domains[i] = mat;
            total *= mat.set_v.len;
            if (total > eval_pool.value_cap) return Error.OutOfMemory;
        }
        if (total > 4096) return self.fail(Error.NotImplemented, "set map", "more than 4096 results");
        var scratch: [4096]Value = undefined;
        const results = scratch[0..@intCast(total)];
        _ = try self.eval_set_map_vars(
            sm,
            0,
            domains[0..sm.vars.len],
            ctx,
            s0,
            eval_pool,
            state_pool,
            results,
            0,
        );
        const dest = try eval_pool.alloc_values(@intCast(total));
        @memcpy(dest, results);
        return Value{ .set_v = make_set(eval_pool, dest) };
    }

    fn eval_set_map_vars(
        self: Evaluator,
        sm: *ast.SetMap,
        var_idx: usize,
        domains: []const Value,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
        dest: []Value,
        start: usize,
    ) Error!void {
        if (var_idx >= sm.vars.len) {
            dest[start] = try self.eval_expr(sm.value, ctx, s0, eval_pool, state_pool);
            return;
        }
        const bv = sm.vars[var_idx];
        const item_count = domains[var_idx].set_v.len;
        const context_snap = self.context_snapshot();
        var stride: usize = 1;
        var j: usize = var_idx + 1;
        while (j < domains.len) : (j += 1) stride *= domains[j].set_v.len;
        for (0..item_count) |i| {
            const it = domains[var_idx].set_v.items(eval_pool)[i];
            const new_ctx = try self.extend_context(ctx, bv.name, it);
            try self.eval_set_map_vars(sm, var_idx + 1, domains, new_ctx, s0, eval_pool, state_pool, dest, start + i * stride);
            self.restore_context_pool(context_snap);
        }
    }

    /// Evaluate an expression and return a materialized `set_v`, expanding
    /// symbolic sets such as ranges and record sets on demand.
    pub fn eval_set_materialized(
        self: Evaluator,
        expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const v = try self.eval_expr(expr, ctx, s0, eval_pool, state_pool);
        if (!v.is_set_like()) return Error.TypeError;
        return self.materialize_set(v, ctx, s0, eval_pool, state_pool);
    }

    /// Materialize a set-like value into an enumerated `set_v`.  Symbolic
    /// sets are expanded on demand; already-materialized sets pass through.
    pub fn materialize_set(
        self: Evaluator,
        set: Value,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        switch (set) {
            .set_v => return set,
            .power_set_v => |ps| {
                const base = try self.materialize_set(ps.set(eval_pool), ctx, s0, eval_pool, state_pool);
                return try eval_subset(eval_pool, base);
            },
            .seq_set_v => |ss| {
                const bounded = try make_seq_set_value(
                    eval_pool,
                    ss.element_set(eval_pool),
                    self.override_registry.ctx.max_seq_len,
                );
                return try self.materialize_set(bounded, ctx, s0, eval_pool, state_pool);
            },
            .range_v => |r| {
                if (r.lo > r.hi) {
                    const empty = try eval_pool.alloc_values(0);
                    return Value{ .set_v = make_set(eval_pool, empty) };
                }
                const span = std.math.sub(i64, r.hi, r.lo) catch return Error.NotImplemented;
                const len_i64 = std.math.add(i64, span, 1) catch return Error.NotImplemented;
                if (len_i64 > std.math.maxInt(u32)) return Error.NotImplemented;
                const len: u32 = @intCast(len_i64);
                const dest = try eval_pool.alloc_values(@intCast(len));
                for (0..len) |i| {
                    dest[i] = Value{ .int_v = r.lo + @as(i64, @intCast(i)) };
                }
                return Value{ .set_v = make_set(eval_pool, dest) };
            },
            .record_set_v => |rs| {
                var domains = std.ArrayList(Value).empty;
                defer domains.deinit(std.heap.page_allocator);
                var names = std.ArrayList([]const u8).empty;
                defer names.deinit(std.heap.page_allocator);
                var i: u32 = 0;
                while (i < rs.len) : (i += 1) {
                    const d = rs.field_domain(eval_pool, i);
                    const mat = try self.materialize_set(d, ctx, s0, eval_pool, state_pool);
                    if (mat != .set_v) return Error.TypeError;
                    try domains.append(std.heap.page_allocator, mat);
                    try names.append(std.heap.page_allocator, rs.field_name(eval_pool, i).slice(eval_pool));
                }
                var count: u64 = 1;
                for (domains.items) |d| {
                    count *= d.set_v.len;
                    if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
                }
                try eval_pool.ensure_value_capacity(count + count * rs.len * 2);
                const dest = try eval_pool.alloc_values(@intCast(count));
                var combo: u64 = 0;
                while (combo < count) : (combo += 1) {
                    const fields_dest = try eval_pool.alloc_values(@intCast(rs.len * 2));
                    var tmp = combo;
                    var fi: u32 = 0;
                    while (fi < rs.len) : (fi += 1) {
                        const items = domains.items[fi].set_v.items(eval_pool);
                        const vi: usize = @intCast(tmp % items.len);
                        tmp /= items.len;
                        const name = try eval_pool.push_string(names.items[fi]);
                        fields_dest[fi * 2] = Value{ .string_v = name };
                        fields_dest[fi * 2 + 1] = items[vi];
                    }
                    dest[combo] = Value{ .record_v = make_record(eval_pool, fields_dest) };
                }
                return Value{ .set_v = make_set(eval_pool, dest) };
            },
            .tuple_set_v => |ts| {
                const ss = ts.sets(eval_pool);
                var domains = std.ArrayList(Value).empty;
                defer domains.deinit(std.heap.page_allocator);
                for (ss) |s| {
                    const mat = try self.materialize_set(s, ctx, s0, eval_pool, state_pool);
                    if (mat != .set_v) return Error.TypeError;
                    try domains.append(std.heap.page_allocator, mat);
                }
                var count: u64 = 1;
                for (domains.items) |d| {
                    count *= d.set_v.len;
                    if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
                }
                try eval_pool.ensure_value_capacity(count + count * domains.items.len);
                const dest = try eval_pool.alloc_values(@intCast(count));
                var combo: u64 = 0;
                while (combo < count) : (combo += 1) {
                    const tuple_dest = try eval_pool.alloc_values(@intCast(domains.items.len));
                    var tmp = combo;
                    for (domains.items, 0..) |d, fi| {
                        const items = d.set_v.items(eval_pool);
                        const vi: usize = @intCast(tmp % items.len);
                        tmp /= items.len;
                        tuple_dest[fi] = items[vi];
                    }
                    dest[combo] = Value{ .tuple_v = make_tuple(eval_pool, tuple_dest) };
                }
                return Value{ .set_v = make_set(eval_pool, dest) };
            },
            .function_set_v => |fs| {
                const domain = fs.domain(eval_pool);
                const codomain = fs.codomain(eval_pool);
                const dmat = try self.materialize_set(domain, ctx, s0, eval_pool, state_pool);
                const cmat = try self.materialize_set(codomain, ctx, s0, eval_pool, state_pool);
                if (dmat != .set_v or cmat != .set_v) return Error.TypeError;
                const n = dmat.set_v.len;
                const m = cmat.set_v.len;
                if (n == 0) {
                    const empty = try eval_pool.alloc_values(0);
                    const func = Value{ .function_v = .{
                        .domain = dmat.set_v,
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
                    if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
                }
                try eval_pool.ensure_value_capacity(count + count * n);
                const values = cmat.set_v.items(eval_pool);
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
                        .domain = dmat.set_v,
                        .offset = value_offset(eval_pool, entries.ptr),
                        .len = n,
                    } };
                }
                return Value{ .set_v = make_set(eval_pool, func_values) };
            },
            .union_v => |u| {
                const inner = u.set(eval_pool);
                const mat = try self.materialize_set(inner, ctx, s0, eval_pool, state_pool);
                if (mat != .set_v) return Error.TypeError;
                var sets = std.ArrayList(Value).empty;
                defer sets.deinit(std.heap.page_allocator);
                try sets.appendSlice(std.heap.page_allocator, mat.set_v.items(eval_pool));
                var materialized = std.ArrayList(Value).empty;
                defer materialized.deinit(std.heap.page_allocator);
                var total: u64 = 0;
                for (sets.items) |s| {
                    const smat = try self.materialize_set(s, ctx, s0, eval_pool, state_pool);
                    if (smat != .set_v) return Error.TypeError;
                    try materialized.append(std.heap.page_allocator, smat);
                    total += smat.set_v.len;
                    if (total > std.math.maxInt(u32)) return Error.OutOfMemory;
                }
                const dest = try eval_pool.alloc_values(@intCast(total));
                var pos: u32 = 0;
                const disjoint = function_sets_have_distinct_domain_sizes(eval_pool, sets.items);
                for (materialized.items) |smat| {
                    const items = smat.set_v.items(eval_pool);
                    for (items) |it| {
                        if (disjoint) {
                            dest[pos] = it;
                            pos += 1;
                            continue;
                        }
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
            },
            .cup_v => |bs| {
                const l = try self.materialize_set(bs.left(eval_pool), ctx, s0, eval_pool, state_pool);
                const r = try self.materialize_set(bs.right(eval_pool), ctx, s0, eval_pool, state_pool);
                if (l != .set_v or r != .set_v) return Error.TypeError;
                const a = l.set_v.items(eval_pool);
                const b = r.set_v.items(eval_pool);
                const dest = try eval_pool.alloc_values(@intCast(a.len + b.len));
                @memcpy(dest[0..a.len], a);
                var count: u32 = @intCast(a.len);
                for (b) |bv| {
                    if (!l.set_v.contains(eval_pool, bv)) {
                        dest[count] = bv;
                        count += 1;
                    }
                }
                return Value{ .set_v = make_set(eval_pool, dest[0..count]) };
            },
            .cap_v => |bs| {
                const l = try self.materialize_set(bs.left(eval_pool), ctx, s0, eval_pool, state_pool);
                const r = try self.materialize_set(bs.right(eval_pool), ctx, s0, eval_pool, state_pool);
                if (l != .set_v or r != .set_v) return Error.TypeError;
                const a = l.set_v.items(eval_pool);
                const b = r.set_v.items(eval_pool);
                const dest = try eval_pool.alloc_values(@intCast(@min(a.len, b.len)));
                var count: u32 = 0;
                for (a) |av| {
                    if (r.set_v.contains(eval_pool, av)) {
                        dest[count] = av;
                        count += 1;
                    }
                }
                return Value{ .set_v = make_set(eval_pool, dest[0..count]) };
            },
            .diff_v => |bs| {
                const l = try self.materialize_set(bs.left(eval_pool), ctx, s0, eval_pool, state_pool);
                const r = try self.materialize_set(bs.right(eval_pool), ctx, s0, eval_pool, state_pool);
                if (l != .set_v or r != .set_v) return Error.TypeError;
                const a = l.set_v.items(eval_pool);
                const dest = try eval_pool.alloc_values(@intCast(a.len));
                var count: u32 = 0;
                for (a) |av| {
                    if (!r.set_v.contains(eval_pool, av)) {
                        dest[count] = av;
                        count += 1;
                    }
                }
                return Value{ .set_v = make_set(eval_pool, dest[0..count]) };
            },
            else => return Error.TypeError,
        }
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
            const d = try self.eval_set_materialized(f.domain, ctx, s0, eval_pool, state_pool);
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
        var domain = try self.eval_expr(sf.domain, ctx, s0, eval_pool, state_pool);
        var codomain = try self.eval_expr(sf.codomain, ctx, s0, eval_pool, state_pool);
        if (!domain.is_set_like() or !codomain.is_set_like()) return Error.TypeError;
        domain = try self.materialize_set(domain, ctx, s0, eval_pool, state_pool);
        codomain = try self.materialize_set(codomain, ctx, s0, eval_pool, state_pool);
        if (domain != .set_v or codomain != .set_v) return Error.TypeError;
        const n = domain.set_v.len;
        const m = codomain.set_v.len;
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
            if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
        }
        try eval_pool.ensure_value_capacity(count + count * n);
        const values = codomain.set_v.items(eval_pool);
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
        var left = try self.eval_expr(sb.left, ctx, s0, eval_pool, state_pool);
        var right = try self.eval_expr(sb.right, ctx, s0, eval_pool, state_pool);
        if (!left.is_set_like() or !right.is_set_like()) return Error.TypeError;
        left = try self.materialize_set(left, ctx, s0, eval_pool, state_pool);
        right = try self.materialize_set(right, ctx, s0, eval_pool, state_pool);
        if (left != .set_v or right != .set_v) return Error.TypeError;
        const a = left.set_v.items(eval_pool);
        const b = right.set_v.items(eval_pool);
        return switch (sb.op) {
            .cartesian_op => {
                // Flatten nested \X: collect all component sets, then product.
                var components = std.ArrayList(Value).empty;
                defer components.deinit(std.heap.page_allocator);
                collect_cartesian_sets(eval_pool, left, &components) catch return Error.TypeError;
                collect_cartesian_sets(eval_pool, right, &components) catch return Error.TypeError;
                if (components.items.len > 1) {
                    const product = try self.cartesian_product(eval_pool, components.items);
                    return Value{ .set_v = make_set(eval_pool, product) };
                }
                // Fallback: simple 2-way product.
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
        if (try self.eval_sequence_field_projection(
            fl,
            ctx,
            s0,
            eval_pool,
            state_pool,
        )) |projection| {
            return projection;
        }
        if (fl.vars.len == 1) {
            const domain = try self.eval_set_materialized(fl.vars[0].domain, ctx, s0, eval_pool, state_pool);
            const item_count = domain.set_v.len;
            if (item_count > 4096) return self.fail(Error.NotImplemented, "function literal", "domain larger than 4096");
            var scratch: [4096]Value = undefined;
            const context_snap = self.context_snapshot();
            for (0..item_count) |i| {
                const it = domain.set_v.items(eval_pool)[i];
                const new_ctx = try self.extend_context(ctx, fl.vars[0].name, it);
                scratch[i] = try self.eval_expr(fl.body, new_ctx, s0, eval_pool, state_pool);
                self.restore_context_pool(context_snap);
            }
            const dest = try eval_pool.alloc_values(item_count);
            @memcpy(dest, scratch[0..item_count]);
            return Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, dest.ptr),
                .len = item_count,
            } };
        }
        var domains: [32]Value = undefined;
        if (fl.vars.len > domains.len) {
            return self.fail(
                Error.NotImplemented,
                "function literal",
                "more than 32 bound variables",
            );
        }
        for (fl.vars, 0..) |v, i| {
            const d = try self.eval_set_materialized(v.domain, ctx, s0, eval_pool, state_pool);
            assert(d == .set_v);
            domains[i] = d;
        }
        const product = try self.cartesian_product(eval_pool, domains[0..fl.vars.len]);
        const product_set = make_set(eval_pool, product);
        if (product_set.len > 4096) return self.fail(Error.NotImplemented, "function literal", "product domain larger than 4096");
        var scratch: [4096]Value = undefined;
        const context_snap = self.context_snapshot();
        for (0..product_set.len) |i| {
            const tuple = product_set.items(eval_pool)[i];
            var new_ctx = ctx;
            const items = tuple.tuple_v.items(eval_pool);
            for (fl.vars, 0..) |v, j| {
                new_ctx = try self.extend_context(new_ctx, v.name, items[j]);
            }
            scratch[i] = try self.eval_expr(fl.body, new_ctx, s0, eval_pool, state_pool);
            self.restore_context_pool(context_snap);
        }
        const dest = try eval_pool.alloc_values(product_set.len);
        @memcpy(dest, scratch[0..product_set.len]);
        return Value{ .function_v = .{
            .domain = product_set,
            .offset = value_offset(eval_pool, dest.ptr),
            .len = product_set.len,
        } };
    }

    fn eval_sequence_field_projection(
        self: Evaluator,
        fl: *ast.FunctionLiteral,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        if (fl.vars.len != 1 or fl.body.* != .field) return null;
        const bound_var = fl.vars[0];
        const field = fl.body.*.field;
        if (field.expr.* != .apply) return null;
        const item_access = field.expr.*.apply;
        if (item_access.func.* != .ident or
            item_access.args.len != 1 or
            item_access.args[0].* != .ident or
            !name_eql(item_access.args[0].*.ident, bound_var.name))
        {
            return null;
        }
        const source_name = item_access.func.*.ident;
        if (bound_var.domain.* != .binary or
            bound_var.domain.*.binary.op != .range)
        {
            return null;
        }
        const range = bound_var.domain.*.binary;
        if (range.left.* != .int_literal or
            range.left.*.int_literal != 1 or
            range.right.* != .apply)
        {
            return null;
        }
        const upper = range.right.*.apply;
        if (upper.func.* != .ident or
            !name_eql(upper.func.*.ident, "Len") or
            upper.args.len != 1 or
            upper.args[0].* != .ident or
            !name_eql(upper.args[0].*.ident, source_name))
        {
            return null;
        }

        const source = try self.eval_expr(
            item_access.func,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        const len: u32 = switch (source) {
            .tuple_v => |tuple| tuple.len,
            .function_v => |function| function.len,
            else => return null,
        };
        try eval_pool.ensure_value_capacity(
            @as(u64, len) * 2,
        );
        const domain_values = try eval_pool.alloc_values(len);
        const result_values = try eval_pool.alloc_values(len);
        for (0..len) |i| {
            domain_values[i] = Value{
                .int_v = @as(i64, @intCast(i)) + 1,
            };
            const item = switch (source) {
                .tuple_v => |tuple| tuple.items(eval_pool)[i],
                .function_v => |function| function.apply(
                    eval_pool,
                    domain_values[i],
                ) orelse return self.fail(
                    Error.IndexOutOfBounds,
                    "sequence field projection",
                    source_name,
                ),
                else => unreachable,
            };
            if (item != .record_v) return null;
            result_values[i] = item.record_v.lookup(
                eval_pool,
                field.name,
            ) orelse return self.fail(
                Error.UndefinedSymbol,
                "sequence field projection",
                field.name,
            );
        }
        return Value{ .function_v = .{
            .domain = .{
                .offset = value_offset(eval_pool, domain_values.ptr),
                .len = len,
            },
            .offset = value_offset(eval_pool, result_values.ptr),
            .len = len,
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
        // If the first set's elements are tuples (from nested \X),
        // flatten them. Compute the effective tuple length.
        var first_elem_len: u32 = 1;
        if (sets[0].set_v.len > 0) {
            const first_items = sets[0].set_v.items(eval_pool);
            if (first_items[0] == .tuple_v) {
                first_elem_len = first_items[0].tuple_v.len;
            }
        }
        const flat_len: u32 = first_elem_len + @as(u32, @intCast(sets.len - 1));
        var count: u64 = 1;
        for (sets) |s| count *= s.set_v.len;
        const dest = try eval_pool.alloc_values(@intCast(count));
        var combo: u64 = 0;
        while (combo < count) : (combo += 1) {
            const tuple_values = try eval_pool.alloc_values(flat_len);
            var tmp = combo;
            var pos: u32 = 0;
            var i: u32 = 0;
            while (i < sets.len) : (i += 1) {
                const items = sets[i].set_v.items(eval_pool);
                const vi: usize = @intCast(tmp % items.len);
                tmp /= items.len;
                if (i == 0 and first_elem_len > 1 and items[vi] == .tuple_v) {
                    // Flatten the first element's inner tuple.
                    const inner = items[vi].tuple_v.items(eval_pool);
                    for (inner) |it| {
                        tuple_values[pos] = it;
                        pos += 1;
                    }
                } else {
                    tuple_values[pos] = items[vi];
                    pos += 1;
                }
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
        if (ap.func.* == .primed) {
            const name = self.resolve_alias(ap.func.*.primed);
            if (self.find_definition(name)) |def| {
                if (def.params.len != ap.args.len) {
                    return self.fail(Error.TypeError, "primed apply arity", name);
                }
                var new_ctx = ctx;
                for (def.params, ap.args) |param, arg| {
                    const arg_value = try self.eval_expr(arg, ctx, s0, eval_pool, state_pool);
                    new_ctx = try self.extend_context(new_ctx, param, arg_value);
                }
                if (self.next_state) |next| {
                    return try self.eval_expr(
                        def.body,
                        new_ctx,
                        next,
                        eval_pool,
                        state_pool,
                    );
                }

                const current = s0 orelse
                    return self.fail(
                        Error.TypeError,
                        "primed apply without current state",
                        name,
                    );
                return try self.eval_primed_definition(
                    def,
                    new_ctx,
                    current,
                    eval_pool,
                    state_pool,
                );
            }
        }
        if (s0) |state_v| {
            var root_name: []const u8 = "";
            var groups: [8]ApplicationGroup = undefined;
            var group_count: u8 = 0;
            if (collect_application_groups(
                ap,
                &root_name,
                &groups,
                &group_count,
            )) {
                if (self.find_variable(root_name)) |variable_index| {
                    assert(variable_index < state_v.values.len);
                    var current = state_v.values[variable_index];
                    const current_pool = state_v.value_pool(
                        variable_index,
                        state_pool,
                    );
                    for (groups[0..group_count]) |group| {
                        if (group.args.len > 8) {
                            return self.fail(
                                Error.NotImplemented,
                                "state application",
                                "more than 8 grouped arguments",
                            );
                        }
                        var arguments: [8]Value = undefined;
                        for (group.args, 0..) |arg, i| {
                            arguments[i] = try self.eval_expr(
                                arg,
                                ctx,
                                s0,
                                eval_pool,
                                state_pool,
                            );
                        }
                        const key = if (group.args.len == 1)
                            arguments[0]
                        else blk: {
                            const tuple_values = try eval_pool.alloc_values(
                                @intCast(group.args.len),
                            );
                            @memcpy(
                                tuple_values,
                                arguments[0..group.args.len],
                            );
                            break :blk Value{ .tuple_v = make_tuple(
                                eval_pool,
                                tuple_values,
                            ) };
                        };
                        current = try apply_cross_pool(
                            self,
                            current,
                            current_pool,
                            key,
                            eval_pool,
                        );
                    }
                    return try current.clone(current_pool, eval_pool);
                }
            }
        }
        if (ap.func.* == .ident) {
            const name = self.resolve_alias(ap.func.*.ident);
            if (std.mem.eql(u8, name, "ReduceSeq") and
                ap.args.len == 3)
            {
                return try self.eval_sequence_fold(
                    ap.args[0],
                    ap.args[2],
                    ap.args[1],
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
            }
            if (std.mem.eql(u8, name, "FoldFunction") and
                ap.args.len == 3)
            {
                return try self.eval_sequence_fold(
                    ap.args[0],
                    ap.args[1],
                    ap.args[2],
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
            }
            // For set operations that require materialized sets, materialize
            // the arguments first.
            if (std.mem.eql(u8, name, "Cardinality") and ap.args.len == 1) {
                const arg_val = try self.eval_expr(ap.args[0], ctx, s0, eval_pool, state_pool);
                const mat = try self.materialize_set(arg_val, ctx, s0, eval_pool, state_pool);
                if (mat == .set_v) return Value{ .int_v = @intCast(mat.set_v.len) };
                if (mat == .range_v) return Value{ .int_v = @max(mat.range_v.hi - mat.range_v.lo + 1, 0) };
                return self.fail(Error.TypeError, "Cardinality", @tagName(mat));
            }
            if (std.mem.eql(u8, name, "Seq") and ap.args.len == 1) {
                const element_set = try self.eval_expr(ap.args[0], ctx, s0, eval_pool, state_pool);
                if (!element_set.is_set_like()) {
                    return self.fail(Error.TypeError, "Seq", "argument is not a set");
                }
                return try make_sequence_set_value(eval_pool, element_set);
            }
            if (std.mem.eql(u8, name, "SelectSeq")) {
                return try self.eval_select_seq(ap, ctx, s0, eval_pool, state_pool);
            }
            if (std.mem.eql(u8, name, "FoldFunctionOnSet") and ap.args.len == 4) {
                return try self.eval_fold_function_on_set(ap, ctx, s0, eval_pool, state_pool);
            }
            if (ctx.lookup(name)) |local_function| {
                const values = try eval_pool.alloc_values(
                    @intCast(ap.args.len),
                );
                for (ap.args, 0..) |arg, i| {
                    values[i] = try self.eval_expr(
                        arg,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                }
                return try self.apply_values(
                    local_function,
                    values,
                    eval_pool,
                    state_pool,
                    s0,
                );
            }
            if (self.override_registry.find(name)) |func| {
                const values = try eval_pool.alloc_values(@intCast(ap.args.len));
                for (ap.args, 0..) |arg, i| {
                    values[i] = try self.eval_expr(arg, ctx, s0, eval_pool, state_pool);
                }
                return func(self.override_registry.ctx, eval_pool, values) catch |err| blk: {
                    if (err == Error.NotImplemented) {
                        const mat_values = try eval_pool.alloc_values(@intCast(ap.args.len));
                        for (values, 0..) |v2, i| {
                            mat_values[i] = if (v2.is_set_like())
                                try self.materialize_set(v2, ctx, s0, eval_pool, state_pool)
                            else
                                v2;
                        }
                        break :blk func(self.override_registry.ctx, eval_pool, mat_values) catch |err2| {
                            if (err2 == Error.TypeError) return self.fail(Error.TypeError, "apply override", name);
                            return err2;
                        };
                    }
                    if (err == Error.TypeError) return self.fail(Error.TypeError, "apply override", name);
                    return err;
                };
            }
            if (self.override_registry.find_generated(
                name,
                ap.args.len,
            )) |func| {
                const values = try eval_pool.alloc_values(
                    @intCast(ap.args.len),
                );
                for (ap.args, 0..) |arg, i| {
                    values[i] = try self.eval_expr(
                        arg,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                }
                return self.call_generated(
                    func,
                    values,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                ) catch |err| {
                    if (err == Error.TypeError) {
                        return self.fail(
                            Error.TypeError,
                            "apply generated override",
                            name,
                        );
                    }
                    return err;
                };
            }
            if (self.find_constant(name)) |constant| {
                switch (constant) {
                    .function_v, .lambda_v => {
                        const values = try eval_pool.alloc_values(
                            @intCast(ap.args.len),
                        );
                        for (ap.args, 0..) |arg, i| {
                            values[i] = try self.eval_expr(
                                arg,
                                ctx,
                                s0,
                                eval_pool,
                                state_pool,
                            );
                        }
                        return try self.apply_values(
                            constant,
                            values,
                            eval_pool,
                            state_pool,
                            s0,
                        );
                    },
                    else => {
                        // A config replacement such as `Op <- FALSE` replaces
                        // the complete operator body. Its formal arguments are
                        // therefore intentionally not evaluated.
                        return try constant.clone(state_pool, eval_pool);
                    },
                }
            }
            if (self.find_definition(name)) |def| {
                const values = try eval_pool.alloc_values(@intCast(ap.args.len));
                for (ap.args, 0..) |arg, i| {
                    values[i] = try self.eval_expr(arg, ctx, s0, eval_pool, state_pool);
                }
                if (def.is_function) {
                    const func = try self.make_recursive_function(def, ctx, eval_pool);
                    return try self.apply_values(func, values, eval_pool, state_pool, s0);
                }
                if (def.params.len == 0) {
                    const func = try self.eval_expr(def.body, ctx, s0, eval_pool, state_pool);
                    return try self.apply_values(func, values, eval_pool, state_pool, s0);
                }
                if (def.params.len != ap.args.len) {
                    std.debug.print(
                        "definition apply arity: {s} expected={d} actual={d}\n",
                        .{ name, def.params.len, ap.args.len },
                    );
                    return self.fail(
                        Error.TypeError,
                        "definition apply arity",
                        name,
                    );
                }
                var new_ctx = ctx;
                for (def.params, 0..) |p, i| {
                    new_ctx = try self.extend_context(new_ctx, p, values[i]);
                }
                return try self.eval_expr(
                    def.body,
                    new_ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
            }
        }
        const func = try self.eval_expr(ap.func, ctx, s0, eval_pool, state_pool);
        const values = try eval_pool.alloc_values(@intCast(ap.args.len));
        for (ap.args, 0..) |a, i| {
            values[i] = try self.eval_expr(a, ctx, s0, eval_pool, state_pool);
        }
        return try self.apply_values(func, values, eval_pool, state_pool, s0);
    }

    fn eval_primed_definition(
        self: Evaluator,
        def: ast.Definition,
        ctx: Context,
        current: *StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const next_values = try eval_pool.alloc_values(
            @intCast(self.module.variables.len),
        );
        for (next_values, current.values, 0..) |
            *next_value,
            current_value,
            variable_index,
        | {
            next_value.* = if (ctx.lookup_state(
                @intCast(variable_index),
            )) |assigned|
                assigned.value
            else
                try current_value.clone(
                    current.value_pool(
                        @intCast(variable_index),
                        state_pool,
                    ),
                    eval_pool,
                );
        }
        var partial_next = StateStore.State{
            .level = current.level + 1,
            .pred = current.pred,
            .changed_mask = 0,
            .borrowed_mask = 0,
            .borrowed_pool = null,
            .values = next_values,
        };

        var constant_scratch: [256]Constant = undefined;
        if (self.constants.len > constant_scratch.len) {
            return self.fail(
                Error.NotImplemented,
                "primed definition constants",
                "more than 256 constants",
            );
        }
        for (self.constants, 0..) |constant, index| {
            constant_scratch[index] = .{
                .name = constant.name,
                .value = try constant.value.clone(
                    state_pool,
                    eval_pool,
                ),
            };
        }
        var primed_evaluator = self;
        primed_evaluator.constants =
            constant_scratch[0..self.constants.len];
        primed_evaluator.next_state = &partial_next;
        return primed_evaluator.eval_expr(
            def.body,
            ctx,
            &partial_next,
            eval_pool,
            eval_pool,
        );
    }

    fn call_generated(
        self: Evaluator,
        function: generated_runtime.OperatorFn,
        args: []const Value,
        evaluator_context: Context,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        var partial_values: [64]?Value = @splat(null);
        assert(self.module.variables.len <= partial_values.len);
        var binding = evaluator_context.head;
        while (binding) |current| : (binding = current.parent) {
            const index = current.variable_index orelse continue;
            assert(index < self.module.variables.len);
            if (partial_values[index] == null) {
                partial_values[index] = current.value;
            }
        }
        var context = generated_runtime.CallContext{
            .eval_pool = eval_pool,
            .state_pool = state_pool,
            .state = current_state,
            .next_state = self.next_state,
            .partial_values = partial_values[0..self.module.variables.len],
            .read_primed = false,
            .constants = self.constants,
            .constant_slots = self.constant_slots,
            .generated_cache = self.generated_cache,
            .generated_cache_pool = self.generated_cache_pool,
            .native_context = &self.override_registry,
            .native_call = generated_native_call,
            .max_seq_len = self.override_registry.ctx.max_seq_len,
        };
        return function(&context, args);
    }

    fn call_generated_bool(
        self: Evaluator,
        function: generated_runtime.OperatorBoolFn,
        args: []const Value,
        evaluator_context: Context,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!bool {
        var partial_values: [64]?Value = @splat(null);
        assert(self.module.variables.len <= partial_values.len);
        var binding = evaluator_context.head;
        while (binding) |current| : (binding = current.parent) {
            const index = current.variable_index orelse continue;
            assert(index < self.module.variables.len);
            if (partial_values[index] == null) {
                partial_values[index] = current.value;
            }
        }
        var context = generated_runtime.CallContext{
            .eval_pool = eval_pool,
            .state_pool = state_pool,
            .state = current_state,
            .next_state = self.next_state,
            .partial_values = partial_values[0..self.module.variables.len],
            .read_primed = false,
            .constants = self.constants,
            .constant_slots = self.constant_slots,
            .generated_cache = self.generated_cache,
            .generated_cache_pool = self.generated_cache_pool,
            .native_context = &self.override_registry,
            .native_call = generated_native_call,
            .max_seq_len = self.override_registry.ctx.max_seq_len,
        };
        return function(&context, args);
    }

    fn eval_sequence_fold(
        self: Evaluator,
        operator_expr: *ast.Expr,
        accumulator_expr: *ast.Expr,
        sequence_expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const operator = try self.eval_expr(
            operator_expr,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        var accumulator = try self.eval_expr(
            accumulator_expr,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        const sequence = try self.eval_expr(
            sequence_expr,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        const len: u32 = switch (sequence) {
            .tuple_v => |tuple| tuple.len,
            .function_v => |function| function.len,
            else => return self.fail(
                Error.TypeError,
                "sequence fold",
                @tagName(sequence),
            ),
        };
        const context_snap = self.context_snapshot();
        var index: u32 = 0;
        while (index < len) : (index += 1) {
            const element = switch (sequence) {
                .tuple_v => |tuple| tuple.items(eval_pool)[index],
                .function_v => |function| function.apply(
                    eval_pool,
                    Value{ .int_v = @as(i64, index) + 1 },
                ) orelse return self.fail(
                    Error.IndexOutOfBounds,
                    "sequence fold",
                    "function domain is not 1..Len",
                ),
                else => unreachable,
            };
            const args = [_]Value{ element, accumulator };
            accumulator = try self.apply_values(
                operator,
                &args,
                eval_pool,
                state_pool,
                s0,
            );
            self.restore_context_pool(context_snap);
        }
        return accumulator;
    }

    fn eval_fold_function_on_set(
        self: Evaluator,
        ap: *ast.Apply,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        assert(ap.args.len == 4);
        const op = try self.eval_expr(ap.args[0], ctx, s0, eval_pool, state_pool);
        var accumulator = try self.eval_expr(ap.args[1], ctx, s0, eval_pool, state_pool);
        const function = try self.eval_expr(ap.args[2], ctx, s0, eval_pool, state_pool);
        const indices = try self.eval_set_materialized(ap.args[3], ctx, s0, eval_pool, state_pool);
        if (indices != .set_v) return self.fail(Error.TypeError, "FoldFunctionOnSet", "indices");

        for (indices.set_v.items(eval_pool)) |index| {
            const mapped = try self.apply_value(function, index, eval_pool, state_pool, s0);
            const args = [_]Value{ mapped, accumulator };
            accumulator = try self.apply_values(op, &args, eval_pool, state_pool, s0);
        }
        return accumulator;
    }

    fn eval_select_seq(
        self: Evaluator,
        ap: *ast.Apply,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (ap.args.len != 2) return self.fail(Error.TypeError, "SelectSeq", "expected two arguments");

        const sequence = try self.eval_expr(ap.args[0], ctx, s0, eval_pool, state_pool);
        const predicate = try self.eval_expr(ap.args[1], ctx, s0, eval_pool, state_pool);
        const len: u32 = switch (sequence) {
            .tuple_v => |tuple| tuple.len,
            .function_v => |function| function.len,
            else => return self.fail(Error.TypeError, "SelectSeq", "first argument is not a sequence"),
        };
        if (len == 0) return Value{ .tuple_v = .{ .offset = 0, .len = 0 } };

        // Reserve the complete result before invoking the predicate. Predicate
        // evaluation may grow the pool, but the offset remains stable.
        const result = try eval_pool.alloc_values(len);
        const result_offset = value_offset(eval_pool, result.ptr);
        assert(result_offset + len <= eval_pool.value_count);

        var selected: u32 = 0;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const element = switch (sequence) {
                .tuple_v => |tuple| blk: {
                    assert(tuple.offset + tuple.len <= eval_pool.value_count);
                    break :blk eval_pool.values[tuple.offset + i];
                },
                .function_v => |function| function.apply(
                    eval_pool,
                    Value{ .int_v = @as(i64, @intCast(i)) + 1 },
                ) orelse return self.fail(Error.TypeError, "SelectSeq", "function domain is not 1..Len(sequence)"),
                else => unreachable,
            };
            const keep = try self.apply_value(predicate, element, eval_pool, state_pool, s0);
            if (keep != .bool_v) {
                return self.fail(Error.TypeError, "SelectSeq", "predicate did not return BOOLEAN");
            }
            if (keep.bool_v) {
                assert(selected < len);
                eval_pool.values[result_offset + selected] = element;
                selected += 1;
            }
        }
        assert(selected <= len);
        return Value{ .tuple_v = .{ .offset = result_offset, .len = selected } };
    }

    fn apply_values(self: Evaluator, func: Value, args: []const Value, eval_pool: *ValuePool, state_pool: *ValuePool, s0: ?*StateStore.State) Error!Value {
        if (args.len == 0) return func;
        if (args.len == 1) return try self.apply_value(func, args[0], eval_pool, state_pool, s0);
        if (func == .lambda_v) {
            const lambda = func.lambda_v;
            if (lambda.params.len != args.len) return Error.TypeError;
            const body: *ast.Expr = @ptrCast(@alignCast(lambda.body));
            const lambda_ctx: *Context = @ptrCast(@alignCast(lambda.ctx));
            var new_ctx = lambda_ctx.*;
            for (lambda.params, args) |param, arg| {
                new_ctx = try self.extend_context(new_ctx, param, arg);
            }
            return try self.eval_expr(body, new_ctx, s0, eval_pool, state_pool);
        }
        const tuple_values = try eval_pool.alloc_values(@intCast(args.len));
        @memcpy(tuple_values, args);
        const arg = Value{ .tuple_v = make_tuple(eval_pool, tuple_values) };
        return try self.apply_value(func, arg, eval_pool, state_pool, s0);
    }

    fn make_recursive_function(
        self: Evaluator,
        def: ast.Definition,
        ctx: Context,
        eval_pool: *ValuePool,
    ) Error!Value {
        std.debug.assert(def.is_function);
        const body = def.body;
        const source_params = if (def.function_vars.len > 0)
            def.function_vars
        else
            &[_][]const u8{def.function_var};
        const params_copy = try eval_pool.arena.alloc([]const u8, source_params.len);
        @memcpy(params_copy, source_params);

        // Allocate the lambda and context first; the context binds the
        // function name to the lambda itself, allowing recursive calls.
        const lam = try eval_pool.arena.alloc_object(value.Lambda);
        const ctx_ptr = try eval_pool.arena.alloc_object(Context);
        const func_val = Value{ .lambda_v = lam };
        ctx_ptr.* = try self.extend_context(ctx, def.name, func_val);
        lam.* = value.Lambda{
            .params = params_copy,
            .body = @ptrCast(body),
            .ctx = @ptrCast(ctx_ptr),
        };
        return func_val;
    }

    fn apply_value(self: Evaluator, func: Value, arg: Value, eval_pool: *ValuePool, state_pool: *ValuePool, s0: ?*StateStore.State) Error!Value {
        switch (func) {
            .function_v => |f| return f.apply(eval_pool, arg) orelse self.fail(Error.IndexOutOfBounds, "apply function", @tagName(arg)),
            .tuple_v => |t| {
                const idx = (arg.as_int() orelse return Error.TypeError) - 1;
                if (idx < 0 or idx >= t.len) return self.fail(Error.IndexOutOfBounds, "apply tuple", @tagName(arg));
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
                    new_ctx = try self.extend_context(new_ctx, l.params[0], arg);
                } else {
                    if (arg != .tuple_v or arg.tuple_v.len != l.params.len) return Error.TypeError;
                    const items = arg.tuple_v.items(eval_pool);
                    for (l.params, 0..) |p, i| {
                        new_ctx = try self.extend_context(new_ctx, p, items[i]);
                    }
                }
                return try self.eval_expr(body, new_ctx, s0, eval_pool, state_pool);
            },
            else => return self.fail(
                Error.TypeError,
                "apply value",
                @tagName(func),
            ),
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
        if (try self.eval_state_function_quantifier(
            q,
            ctx,
            s0,
            eval_pool,
            state_pool,
        )) |result| {
            return result;
        }
        return try self.eval_quantifier_vars(q, 0, ctx, s0, eval_pool, state_pool);
    }

    fn eval_state_function_quantifier(
        self: Evaluator,
        q: *ast.Quantifier,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        const state_v = s0 orelse return null;
        if (q.kind != .forall or q.vars.len == 0 or q.vars.len > 8 or
            q.body.* != .binary)
        {
            return null;
        }
        const comparison = q.body.*.binary;
        switch (comparison.op) {
            .eq, .ne, .lt, .le, .gt, .ge => {},
            else => return null,
        }
        if (comparison.left.* != .apply) return null;

        var root_name: []const u8 = "";
        var groups: [8]ApplicationGroup = undefined;
        var group_count: u8 = 0;
        if (!collect_application_groups(
            comparison.left.*.apply,
            &root_name,
            &groups,
            &group_count,
        )) return null;
        const variable_index = self.find_variable(root_name) orelse
            return null;
        assert(variable_index < state_v.values.len);

        var group_var_indices: [8]u8 = undefined;
        for (groups[0..group_count], 0..) |group, group_index| {
            if (group.args.len != 1 or group.args[0].* != .ident) {
                return null;
            }
            const argument_name = group.args[0].*.ident;
            var found: ?u8 = null;
            for (q.vars, 0..) |bound_var, bound_index| {
                if (name_eql(bound_var.name, argument_name)) {
                    found = @intCast(bound_index);
                    break;
                }
            }
            group_var_indices[group_index] = found orelse return null;
        }
        if (expr_mentions_bound_names(comparison.right, q.vars)) {
            return null;
        }

        var domains: [8]Value = undefined;
        for (q.vars, 0..) |bound_var, i| {
            domains[i] = try self.eval_set_materialized(
                bound_var.domain,
                ctx,
                s0,
                eval_pool,
                state_pool,
            );
            if (domains[i] != .set_v) return null;
        }
        const right = try self.eval_expr(
            comparison.right,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        var assignments: [8]Value = undefined;
        const holds = try self.eval_state_quantifier_combinations(
            domains[0..q.vars.len],
            0,
            &assignments,
            state_v.values[variable_index],
            state_v.value_pool(variable_index, state_pool),
            groups[0..group_count],
            group_var_indices[0..group_count],
            comparison.op,
            right,
            eval_pool,
            state_pool,
        );
        return Value{ .bool_v = holds };
    }

    fn eval_state_quantifier_combinations(
        self: Evaluator,
        domains: []const Value,
        depth: usize,
        assignments: *[8]Value,
        root: Value,
        root_pool: *const ValuePool,
        groups: []const ApplicationGroup,
        group_var_indices: []const u8,
        comparison: ast.BinaryOp,
        right: Value,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!bool {
        if (depth < domains.len) {
            for (domains[depth].set_v.items(eval_pool)) |item| {
                assignments[depth] = item;
                if (!try self.eval_state_quantifier_combinations(
                    domains,
                    depth + 1,
                    assignments,
                    root,
                    root_pool,
                    groups,
                    group_var_indices,
                    comparison,
                    right,
                    eval_pool,
                    state_pool,
                )) return false;
            }
            return true;
        }

        var current = root;
        for (groups, group_var_indices) |_, bound_index| {
            current = try apply_cross_pool(
                self,
                current,
                root_pool,
                assignments[bound_index],
                eval_pool,
            );
        }
        return compare_cross_pool_scalars(
            current,
            root_pool,
            right,
            eval_pool,
            comparison,
        ) orelse return Error.TypeError;
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
        const saved_context_count = self.context_pool.snapshot();
        defer self.context_pool.restore(saved_context_count);
        if (idx >= q.vars.len) {
            return try self.eval_expr(q.body, ctx, s0, eval_pool, state_pool);
        }
        const bv = q.vars[idx];
        if (try self.eval_filtered_power_set_quantifier(
            q,
            idx,
            bv,
            ctx,
            s0,
            eval_pool,
            state_pool,
        )) |result| {
            return result;
        }
        const domain = try self.eval_set_materialized(bv.domain, ctx, s0, eval_pool, state_pool);
        assert(domain == .set_v);
        const item_offset = domain.set_v.offset;
        const item_count = domain.set_v.len;
        assert(item_offset + item_count <= eval_pool.value_count);
        const expected = q.kind == .forall;
        var item_index: u32 = 0;
        while (item_index < item_count) : (item_index += 1) {
            assert(item_offset + item_index < eval_pool.value_count);
            const it = eval_pool.values[item_offset + item_index];
            const new_ctx = try self.extend_context(ctx, bv.name, it);
            const result = try self.eval_quantifier_vars(q, idx + 1, new_ctx, s0, eval_pool, state_pool);
            if (result.is_truthy() != expected) {
                return Value{ .bool_v = !expected };
            }
        }
        return Value{ .bool_v = expected };
    }

    fn eval_filtered_power_set_quantifier(
        self: Evaluator,
        q: *ast.Quantifier,
        idx: u32,
        quantified_var: ast.BoundVar,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        const domain_expr = blk: {
            if (quantified_var.domain.* == .ident) {
                const name = self.resolve_alias(quantified_var.domain.ident);
                const definition = self.find_definition(name) orelse
                    return null;
                if (definition.params.len != 0) return null;
                break :blk definition.body;
            }
            break :blk quantified_var.domain;
        };
        if (domain_expr.* != .set_filter) return null;
        const filter = domain_expr.set_filter;
        if (filter.vars.len != 1) return null;

        const symbolic_domain = try self.eval_expr(
            filter.vars[0].domain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (symbolic_domain != .power_set_v) return null;
        const base = try self.materialize_set(
            symbolic_domain.power_set_v.set(eval_pool),
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (base != .set_v or base.set_v.len > 63) return null;

        const base_items = base.set_v.items(eval_pool);
        const subset_storage = try eval_pool.alloc_values(base.set_v.len);
        const iteration_snapshot = eval_pool.snapshot();
        const saved_context_count = self.context_pool.snapshot();
        const expected = q.kind == .forall;
        const subset_count = @as(u64, 1) << @intCast(base_items.len);
        var mask: u64 = 0;
        while (mask < subset_count) : (mask += 1) {
            var item_count: u32 = 0;
            for (base_items, 0..) |item, bit| {
                if ((mask & (@as(u64, 1) << @intCast(bit))) != 0) {
                    subset_storage[item_count] = item;
                    item_count += 1;
                }
            }
            const subset = Value{ .set_v = make_set(
                eval_pool,
                subset_storage[0..item_count],
            ) };
            const filter_ctx = try self.extend_context(
                ctx,
                filter.vars[0].name,
                subset,
            );
            const accepted = try self.eval_expr(
                filter.pred,
                filter_ctx,
                s0,
                eval_pool,
                state_pool,
            );
            if (accepted.is_truthy()) {
                const quantified_ctx = try self.extend_context(
                    ctx,
                    quantified_var.name,
                    subset,
                );
                const result = try self.eval_quantifier_vars(
                    q,
                    idx + 1,
                    quantified_ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                if (result.is_truthy() != expected) {
                    eval_pool.restore(iteration_snapshot);
                    self.context_pool.restore(saved_context_count);
                    return Value{ .bool_v = !expected };
                }
            }
            eval_pool.restore(iteration_snapshot);
            self.context_pool.restore(saved_context_count);
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
            const v = if (def.is_function)
                try self.make_recursive_function(def, new_ctx, eval_pool)
            else if (def.params.len > 0)
                try self.make_lambda(def, new_ctx, eval_pool)
            else
                try self.eval_expr(def.body, new_ctx, s0, eval_pool, state_pool);
            new_ctx = try self.extend_context(new_ctx, def.name, v);
        }
        return try self.eval_expr(l.body, new_ctx, s0, eval_pool, state_pool);
    }

    fn make_lambda(
        self: Evaluator,
        def: ast.Definition,
        ctx: Context,
        eval_pool: *ValuePool,
    ) Error!Value {
        _ = self;
        const lam = try eval_pool.arena.alloc_object(value.Lambda);
        const ctx_ptr = try eval_pool.arena.alloc_object(Context);
        ctx_ptr.* = ctx;
        const params_copy = try eval_pool.arena.alloc([]const u8, def.params.len);
        for (def.params, 0..) |p, i| params_copy[i] = p;
        lam.* = value.Lambda{
            .params = params_copy,
            .body = @ptrCast(def.body),
            .ctx = @ptrCast(ctx_ptr),
        };
        return Value{ .lambda_v = lam };
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
            const domain = try self.eval_set_materialized(domain_expr, ctx, s0, eval_pool, state_pool);
            const items = domain.set_v.items(eval_pool);
            const scratch_snapshot = eval_pool.snapshot();
            const context_snap = self.context_snapshot();
            var chosen: ?Value = null;
            for (items) |it| {
                const new_ctx = try self.extend_context(ctx, c.var_name, it);
                const pred = try self.eval_expr(c.body, new_ctx, s0, eval_pool, state_pool);
                if (pred.is_truthy()) {
                    if (chosen == null) {
                        chosen = it;
                    } else if (it.compare(chosen.?, eval_pool)) |cmp| {
                        if (cmp < 0) chosen = it;
                    }
                }
                eval_pool.restore(scratch_snapshot);
                self.restore_context_pool(context_snap);
            }
            return chosen orelse self.fail(
                Error.EmptyChoose,
                "CHOOSE",
                c.var_name,
            );
        }
        // Domain-free CHOOSE: try fresh model values until the predicate holds.
        var attempt: u32 = 0;
        while (attempt < 1024) : (attempt += 1) {
            var name_buffer: [32]u8 = undefined;
            const name = std.fmt.bufPrint(
                &name_buffer,
                "__choose_{d}",
                .{attempt},
            ) catch return Error.OutOfMemory;
            const id = try self.models.intern(name);
            const candidate = Value{ .model_v = id };
            const new_ctx = try self.extend_context(ctx, c.var_name, candidate);
            const pred = try self.eval_expr(c.body, new_ctx, s0, eval_pool, state_pool);
            if (pred.is_truthy()) return candidate;
        }
        return self.fail(Error.EmptyChoose, "CHOOSE", c.var_name);
    }

    fn eval_except(
        self: Evaluator,
        e: *ast.Except,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (s0) |state_v| {
            if (e.func.* == .ident) {
                if (self.find_variable(e.func.*.ident)) |variable_index| {
                    assert(variable_index < state_v.values.len);
                    return try self.except_steps_cross_pool(
                        state_v.values[variable_index],
                        state_v.value_pool(variable_index, state_pool),
                        e.steps,
                        0,
                        e.value,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                }
            }
        }
        const original = try self.eval_expr(e.func, ctx, s0, eval_pool, state_pool);
        return try self.except_steps(original, e.steps, 0, e.value, ctx, s0, eval_pool, state_pool);
    }

    fn except_steps_cross_pool(
        self: Evaluator,
        original: Value,
        original_pool: *const ValuePool,
        steps: []const ast.AccessStep,
        idx: u32,
        value_expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        assert(idx < steps.len);
        const step = steps[idx];
        switch (step) {
            .index => |index_expr| {
                const key = try self.eval_expr(
                    index_expr,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                switch (original) {
                    .function_v => |function| {
                        const keys = function.domain.items(original_pool);
                        const entries = function.entries(original_pool);
                        var selected: ?u32 = null;
                        for (keys, 0..) |candidate, i| {
                            if (cross_pool_eql(
                                candidate,
                                original_pool,
                                key,
                                eval_pool,
                            )) {
                                selected = @intCast(i);
                                break;
                            }
                        }
                        const selected_index = selected orelse
                            return self.fail(
                                Error.IndexOutOfBounds,
                                "except cross-pool function",
                                @tagName(key),
                            );
                        const new_value = try self.except_cross_pool_child(
                            entries[selected_index],
                            original_pool,
                            steps,
                            idx,
                            value_expr,
                            ctx,
                            s0,
                            eval_pool,
                            state_pool,
                        );
                        const domain_values = try eval_pool.alloc_values(
                            function.len,
                        );
                        const result_values = try eval_pool.alloc_values(
                            function.len,
                        );
                        const domain_offset = value_offset(
                            eval_pool,
                            domain_values.ptr,
                        );
                        const result_offset = value_offset(
                            eval_pool,
                            result_values.ptr,
                        );
                        for (keys, entries, 0..) |
                            source_key,
                            source_value,
                            i,
                        | {
                            eval_pool.values[domain_offset + i] =
                                try source_key.clone(
                                    original_pool,
                                    eval_pool,
                                );
                            eval_pool.values[result_offset + i] =
                                if (i == selected_index)
                                    new_value
                                else
                                    try source_value.clone(
                                        original_pool,
                                        eval_pool,
                                    );
                        }
                        return Value{ .function_v = .{
                            .domain = .{
                                .offset = domain_offset,
                                .len = function.len,
                            },
                            .offset = result_offset,
                            .len = function.len,
                        } };
                    },
                    .tuple_v => |tuple| {
                        const selected_index_i64 =
                            (key.as_int() orelse return self.fail(
                                Error.TypeError,
                                "except cross-pool tuple",
                                @tagName(key),
                            )) - 1;
                        if (selected_index_i64 < 0 or
                            selected_index_i64 >= tuple.len)
                        {
                            return self.fail(
                                Error.IndexOutOfBounds,
                                "except cross-pool tuple",
                                @tagName(key),
                            );
                        }
                        const selected_index: u32 =
                            @intCast(selected_index_i64);
                        const items = tuple.items(original_pool);
                        const new_value = try self.except_cross_pool_child(
                            items[selected_index],
                            original_pool,
                            steps,
                            idx,
                            value_expr,
                            ctx,
                            s0,
                            eval_pool,
                            state_pool,
                        );
                        const result = try eval_pool.alloc_values(tuple.len);
                        const result_offset = value_offset(
                            eval_pool,
                            result.ptr,
                        );
                        for (items, 0..) |item, i| {
                            eval_pool.values[result_offset + i] =
                                if (i == selected_index)
                                    new_value
                                else
                                    try item.clone(original_pool, eval_pool);
                        }
                        return Value{ .tuple_v = .{
                            .offset = result_offset,
                            .len = tuple.len,
                        } };
                    },
                    .record_v => {
                        if (key != .string_v) {
                            return self.fail(
                                Error.TypeError,
                                "except cross-pool record",
                                @tagName(key),
                            );
                        }
                        return try self.except_cross_pool_record(
                            original.record_v,
                            original_pool,
                            key.string_v.slice(eval_pool),
                            steps,
                            idx,
                            value_expr,
                            ctx,
                            s0,
                            eval_pool,
                            state_pool,
                        );
                    },
                    else => return self.fail(
                        Error.TypeError,
                        "except cross-pool index",
                        @tagName(original),
                    ),
                }
            },
            .field => |field| {
                if (original != .record_v) {
                    return self.fail(
                        Error.TypeError,
                        "except cross-pool field",
                        @tagName(original),
                    );
                }
                return try self.except_cross_pool_record(
                    original.record_v,
                    original_pool,
                    field,
                    steps,
                    idx,
                    value_expr,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
            },
        }
    }

    fn except_cross_pool_child(
        self: Evaluator,
        old_value: Value,
        original_pool: *const ValuePool,
        steps: []const ast.AccessStep,
        idx: u32,
        value_expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (idx + 1 < steps.len) {
            return try self.except_steps_cross_pool(
                old_value,
                original_pool,
                steps,
                idx + 1,
                value_expr,
                ctx,
                s0,
                eval_pool,
                state_pool,
            );
        }
        const old_value_eval = try old_value.clone(
            original_pool,
            eval_pool,
        );
        const new_ctx = try self.extend_context(
            ctx,
            "@",
            old_value_eval,
        );
        return try self.eval_expr(
            value_expr,
            new_ctx,
            s0,
            eval_pool,
            state_pool,
        );
    }

    fn except_cross_pool_record(
        self: Evaluator,
        record: value.Record,
        original_pool: *const ValuePool,
        field: []const u8,
        steps: []const ast.AccessStep,
        idx: u32,
        value_expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const fields = record.fields(original_pool);
        var selected: ?u32 = null;
        var i: u32 = 0;
        while (i < record.len) : (i += 1) {
            if (std.mem.eql(
                u8,
                fields[i * 2].string_v.slice(original_pool),
                field,
            )) {
                selected = i;
                break;
            }
        }
        const selected_index = selected orelse
            return self.fail(
                Error.UndefinedSymbol,
                "except cross-pool record",
                field,
            );
        const new_value = try self.except_cross_pool_child(
            fields[selected_index * 2 + 1],
            original_pool,
            steps,
            idx,
            value_expr,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        const result = try eval_pool.alloc_values(record.len * 2);
        const result_offset = value_offset(eval_pool, result.ptr);
        i = 0;
        while (i < record.len) : (i += 1) {
            eval_pool.values[result_offset + i * 2] =
                try fields[i * 2].clone(
                    original_pool,
                    eval_pool,
                );
            eval_pool.values[result_offset + i * 2 + 1] =
                if (i == selected_index)
                    new_value
                else
                    try fields[i * 2 + 1].clone(
                        original_pool,
                        eval_pool,
                    );
        }
        return Value{ .record_v = .{
            .offset = result_offset,
            .len = record.len,
        } };
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
                const new_ctx = try self.extend_context(ctx, "@", old_value);
                const new_value = try self.except_steps(old_value, steps, idx + 1, value_expr, new_ctx, s0, eval_pool, state_pool);
                return try self.except_update_index(original, key, new_value, eval_pool);
            },
            .field => |field| {
                const old_value = try self.except_lookup_field(original, field, eval_pool);
                const new_ctx = try self.extend_context(ctx, "@", old_value);
                const new_value = try self.except_steps(old_value, steps, idx + 1, value_expr, new_ctx, s0, eval_pool, state_pool);
                return try self.except_update_field(original, field, new_value, eval_pool);
            },
        }
    }

    fn except_lookup_index(self: Evaluator, original: Value, key: Value, eval_pool: *ValuePool) Error!Value {
        switch (original) {
            .function_v => |f| return f.apply(eval_pool, key) orelse self.fail(Error.IndexOutOfBounds, "except lookup function", @tagName(key)),
            .tuple_v => |t| {
                const i = (key.as_int() orelse
                    return self.fail(
                        Error.TypeError,
                        "except tuple index",
                        @tagName(key),
                    )) - 1;
                if (i < 0 or i >= t.len) return self.fail(Error.IndexOutOfBounds, "except lookup tuple", @tagName(key));
                return t.items(eval_pool)[@intCast(i)];
            },
            .record_v => |record| {
                if (key != .string_v) {
                    return self.fail(
                        Error.TypeError,
                        "except record index",
                        @tagName(key),
                    );
                }
                const field = key.string_v.slice(eval_pool);
                return record.lookup(eval_pool, field) orelse
                    self.fail(
                        Error.UndefinedSymbol,
                        "except record index",
                        field,
                    );
            },
            else => return self.fail(
                Error.TypeError,
                "except index lookup",
                @tagName(original),
            ),
        }
    }

    fn except_update_index(self: Evaluator, original: Value, key: Value, new_value: Value, eval_pool: *ValuePool) Error!Value {
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
                const i = (key.as_int() orelse
                    return self.fail(
                        Error.TypeError,
                        "except tuple index",
                        @tagName(key),
                    )) - 1;
                if (i < 0 or i >= t.len) return self.fail(Error.IndexOutOfBounds, "except update tuple", @tagName(key));
                const items = t.items(eval_pool);
                const dest = try eval_pool.alloc_values(@intCast(items.len));
                @memcpy(dest, items);
                dest[@intCast(i)] = new_value;
                return Value{ .tuple_v = make_tuple(eval_pool, dest) };
            },
            .record_v => {
                if (key != .string_v) {
                    return self.fail(
                        Error.TypeError,
                        "except record index",
                        @tagName(key),
                    );
                }
                return try self.except_update_field(
                    original,
                    key.string_v.slice(eval_pool),
                    new_value,
                    eval_pool,
                );
            },
            else => return self.fail(
                Error.TypeError,
                "except index update",
                @tagName(original),
            ),
        }
    }

    fn except_lookup_field(self: Evaluator, original: Value, field: []const u8, eval_pool: *ValuePool) Error!Value {
        if (original != .record_v) {
            return self.fail(
                Error.TypeError,
                "except field lookup",
                @tagName(original),
            );
        }
        return original.record_v.lookup(eval_pool, field) orelse Error.UndefinedSymbol;
    }

    fn except_update_field(self: Evaluator, original: Value, field: []const u8, new_value: Value, eval_pool: *ValuePool) Error!Value {
        if (original != .record_v) {
            return self.fail(
                Error.TypeError,
                "except field update",
                @tagName(original),
            );
        }
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
        for (self.module.variables, 0..) |variable, index| {
            if (name_eql(variable, name)) return @intCast(index);
        }
        return null;
    }

    pub fn find_definition(self: Evaluator, name: []const u8) ?ast.Definition {
        for (self.module.definitions) |definition| {
            if (name_eql(definition.name, name)) return definition;
        }
        return null;
    }

    pub fn find_subexpression(self: Evaluator, name: []const u8) ?*ast.Expr {
        const bang = std.mem.lastIndexOfScalar(u8, name, '!') orelse return null;
        if (bang == 0 or bang + 1 >= name.len) return null;
        const selector = std.fmt.parseInt(usize, name[bang + 1 ..], 10) catch return null;
        if (selector == 0) return null;

        const base_name = name[0..bang];
        const base = if (self.find_definition(base_name)) |def|
            def.body
        else
            self.find_subexpression(base_name) orelse return null;
        return select_subexpression(base, selector);
    }
};

inline fn name_eql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    if (left.ptr == right.ptr) return true;
    return std.mem.eql(u8, left, right);
}

fn generated_native_call(
    context: *const anyopaque,
    pool: *ValuePool,
    name: []const u8,
    args: []const Value,
) Error!Value {
    const registry: *const overrides.Registry = @ptrCast(
        @alignCast(context),
    );
    const function = registry.find(name) orelse
        return Error.UndefinedSymbol;
    return function(registry.ctx, pool, args);
}

fn expr_mentions_bound_names(
    expr: *const ast.Expr,
    vars: []const ast.BoundVar,
) bool {
    return switch (expr.*) {
        .bool_literal, .int_literal, .string_literal => false,
        .ident => |name| blk: {
            for (vars) |bound_var| {
                if (name_eql(name, bound_var.name)) break :blk true;
            }
            break :blk false;
        },
        else => true,
    };
}

fn compare_cross_pool_scalars(
    left: Value,
    left_pool: *const ValuePool,
    right: Value,
    right_pool: *const ValuePool,
    comparison: ast.BinaryOp,
) ?bool {
    return switch (comparison) {
        .eq => cross_pool_eql(
            left,
            left_pool,
            right,
            right_pool,
        ),
        .ne => !cross_pool_eql(
            left,
            left_pool,
            right,
            right_pool,
        ),
        .lt, .le, .gt, .ge => blk: {
            const left_int = left.as_int() orelse break :blk null;
            const right_int = right.as_int() orelse break :blk null;
            break :blk switch (comparison) {
                .lt => left_int < right_int,
                .le => left_int <= right_int,
                .gt => left_int > right_int,
                .ge => left_int >= right_int,
                else => unreachable,
            };
        },
        else => null,
    };
}

fn is_pointwise_function_predicate(
    expr: *const ast.Expr,
    function_name: []const u8,
    key_name: []const u8,
) bool {
    return switch (expr.*) {
        .bool_literal, .int_literal, .string_literal => true,
        .ident => |name| !name_eql(name, function_name),
        .binary => |binary| is_pointwise_function_predicate(
            binary.left,
            function_name,
            key_name,
        ) and is_pointwise_function_predicate(
            binary.right,
            function_name,
            key_name,
        ),
        .unary => |unary| is_pointwise_function_predicate(
            unary.operand,
            function_name,
            key_name,
        ),
        .quantifier => |quantifier| blk: {
            for (quantifier.vars) |bound_var| {
                if (name_eql(bound_var.name, function_name) or
                    name_eql(bound_var.name, key_name) or
                    !is_pointwise_function_predicate(
                        bound_var.domain,
                        function_name,
                        key_name,
                    ))
                {
                    break :blk false;
                }
            }
            break :blk is_pointwise_function_predicate(
                quantifier.body,
                function_name,
                key_name,
            );
        },
        .if_then_else => |conditional| is_pointwise_function_predicate(
            conditional.cond,
            function_name,
            key_name,
        ) and is_pointwise_function_predicate(
            conditional.then_branch,
            function_name,
            key_name,
        ) and is_pointwise_function_predicate(
            conditional.else_branch,
            function_name,
            key_name,
        ),
        .apply => |application| blk: {
            if (application.func.* == .ident and
                name_eql(
                    application.func.*.ident,
                    function_name,
                ))
            {
                break :blk application.args.len == 1 and
                    application.args[0].* == .ident and
                    name_eql(
                        application.args[0].*.ident,
                        key_name,
                    );
            }
            if (!is_pointwise_function_predicate(
                application.func,
                function_name,
                key_name,
            )) break :blk false;
            for (application.args) |argument| {
                if (!is_pointwise_function_predicate(
                    argument,
                    function_name,
                    key_name,
                )) break :blk false;
            }
            break :blk true;
        },
        .field => |field| is_pointwise_function_predicate(
            field.expr,
            function_name,
            key_name,
        ),
        .tuple, .set_enum => |items| blk: {
            for (items) |item| {
                if (!is_pointwise_function_predicate(
                    item,
                    function_name,
                    key_name,
                )) break :blk false;
            }
            break :blk true;
        },
        .record => |fields| blk: {
            for (fields) |field| {
                if (!is_pointwise_function_predicate(
                    field.value,
                    function_name,
                    key_name,
                )) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn select_subexpression(expr: *ast.Expr, selector: usize) ?*ast.Expr {
    if (expr.* != .binary) return if (selector == 1) expr else null;
    const op = expr.binary.op;
    if (op != .and_op and op != .or_op) return if (selector == 1) expr else null;

    var remaining = selector;
    return select_list_item(expr, op, &remaining);
}

fn select_list_item(expr: *ast.Expr, op: ast.BinaryOp, remaining: *usize) ?*ast.Expr {
    if (expr.* == .binary and expr.binary.op == op) {
        if (select_list_item(expr.binary.left, op, remaining)) |selected| return selected;
        return select_list_item(expr.binary.right, op, remaining);
    }
    if (remaining.* == 1) return expr;
    remaining.* -= 1;
    return null;
}

fn function_sets_have_distinct_domain_sizes(pool: *ValuePool, sets: []const Value) bool {
    var seen: [64]bool = undefined;
    @memset(&seen, false);
    for (sets) |set| {
        if (set != .function_set_v) return false;
        const domain = set.function_set_v.domain(pool);
        const size: usize = switch (domain) {
            .set_v => |s| s.len,
            .range_v => |r| blk: {
                if (r.hi < r.lo) break :blk 0;
                break :blk @intCast(r.hi - r.lo + 1);
            },
            else => return false,
        };
        if (size >= seen.len) return false;
        if (seen[size]) return false;
        seen[size] = true;
    }
    return true;
}

fn is_sorted_sequence_predicate(expr: *ast.Expr, seq_name: []const u8) bool {
    if (expr.* != .quantifier) return false;
    const q = expr.quantifier;
    if (q.kind != .forall or q.vars.len != 2) return false;
    const i_name = q.vars[0].name;
    const j_name = q.vars[1].name;
    if (!is_one_to_len_range(q.vars[0].domain, seq_name)) return false;
    if (!is_one_to_len_range(q.vars[1].domain, seq_name)) return false;
    if (q.body.* != .binary) return false;
    const implies = q.body.binary;
    if (implies.op != .implies) return false;
    if (!is_binary_ident_ident(implies.left, .lt, i_name, j_name)) return false;
    return is_sequence_index_order(implies.right, .le, seq_name, i_name, j_name);
}

fn is_one_to_len_range(expr: *ast.Expr, seq_name: []const u8) bool {
    if (expr.* != .binary) return false;
    const b = expr.binary;
    if (b.op != .range) return false;
    if (b.left.* != .int_literal or b.left.int_literal != 1) return false;
    if (b.right.* != .apply) return false;
    const ap = b.right.apply;
    if (ap.func.* != .ident or !std.mem.eql(u8, ap.func.ident, "Len")) return false;
    return ap.args.len == 1 and is_ident(ap.args[0], seq_name);
}

fn is_binary_ident_ident(expr: *ast.Expr, op: ast.BinaryOp, left_name: []const u8, right_name: []const u8) bool {
    if (expr.* != .binary) return false;
    const b = expr.binary;
    return b.op == op and is_ident(b.left, left_name) and is_ident(b.right, right_name);
}

fn is_seq_application(expr: *ast.Expr) bool {
    if (expr.* != .apply) return false;
    const application = expr.apply;
    return application.args.len == 1 and
        application.func.* == .ident and
        std.mem.eql(u8, application.func.ident, "Seq");
}

fn is_sequence_index_order(expr: *ast.Expr, op: ast.BinaryOp, seq_name: []const u8, left_index: []const u8, right_index: []const u8) bool {
    if (expr.* != .binary) return false;
    const b = expr.binary;
    return b.op == op and
        is_sequence_index(b.left, seq_name, left_index) and
        is_sequence_index(b.right, seq_name, right_index);
}

fn is_sequence_index(expr: *ast.Expr, seq_name: []const u8, index_name: []const u8) bool {
    if (expr.* != .apply) return false;
    const ap = expr.apply;
    return is_ident(ap.func, seq_name) and ap.args.len == 1 and is_ident(ap.args[0], index_name);
}

fn is_ident(expr: *ast.Expr, name: []const u8) bool {
    return expr.* == .ident and std.mem.eql(u8, expr.ident, name);
}

fn extract_sequence_codomain_and_lengths(pool: *ValuePool, seq_set: Value, lengths: *std.ArrayList(u32)) Error!?Value {
    if (seq_set != .union_v) return null;
    const inner = seq_set.union_v.set(pool);
    if (inner != .set_v) return null;

    var codomain: ?Value = null;
    const sets = inner.set_v.items(pool);
    for (sets) |set| {
        if (set != .function_set_v) return null;
        const fs = set.function_set_v;
        const len = sequence_domain_size(pool, fs.domain(pool)) orelse return null;
        const fs_codomain = fs.codomain(pool);
        if (codomain) |existing| {
            if (!existing.eql(fs_codomain, pool)) return null;
        } else {
            codomain = fs_codomain;
        }
        try lengths.append(std.heap.page_allocator, len);
    }
    return codomain;
}

fn sequence_domain_size(pool: *ValuePool, domain: Value) ?u32 {
    return switch (domain) {
        .set_v => |s| blk: {
            const items = s.items(pool);
            for (items, 0..) |it, i| {
                if (it != .int_v or it.int_v != @as(i64, @intCast(i + 1))) return null;
            }
            break :blk s.len;
        },
        .range_v => |r| blk: {
            if (r.lo != 1 or r.hi < 0) return null;
            break :blk @intCast(@max(r.hi, 0));
        },
        else => null,
    };
}

fn sort_values(pool: *ValuePool, items: []Value) ?void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0) {
            const cmp = items[j - 1].compare(key, pool) orelse return null;
            if (cmp <= 0) break;
            items[j] = items[j - 1];
            j -= 1;
        }
        items[j] = key;
    }
}

fn generate_sorted_sequences(
    eval_pool: *ValuePool,
    values: []const Value,
    target_len: u32,
    start: usize,
    current: *std.ArrayList(Value),
    generated: *std.ArrayList(Value),
) Error!void {
    if (current.items.len == target_len) {
        try generated.append(std.heap.page_allocator, try make_sequence_function(eval_pool, current.items));
        return;
    }
    var i = start;
    while (i < values.len) : (i += 1) {
        try current.append(std.heap.page_allocator, values[i]);
        try generate_sorted_sequences(eval_pool, values, target_len, i, current, generated);
        current.items.len -= 1;
    }
}

fn make_sequence_function(eval_pool: *ValuePool, items: []const Value) Error!Value {
    const len: u32 = @intCast(items.len);
    const entries = try eval_pool.alloc_values(len);
    @memcpy(entries, items);
    const entries_offset = value_offset(eval_pool, entries.ptr);

    const dom = try eval_pool.alloc_values(len);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        dom[i] = Value{ .int_v = @as(i64, @intCast(i + 1)) };
    }
    return Value{ .function_v = .{
        .domain = make_set(eval_pool, dom),
        .offset = entries_offset,
        .len = len,
    } };
}

fn collect_cartesian_sets(pool: *ValuePool, val: Value, out: *std.ArrayList(Value)) !void {
    _ = pool;
    try out.append(std.heap.page_allocator, val);
}

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
    if (items.len >= 32) {
        std.debug.print("NotImplemented: SUBSET with {d} elements (max 31)\n", .{items.len});
        return Error.NotImplemented;
    }
    const count: u32 = @as(u32, 1) << @intCast(items.len);
    const subset_items: u64 = if (items.len == 0) 0 else @as(u64, count / 2) * items.len;
    try eval_pool.ensure_value_capacity(@as(u64, count) + subset_items);
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
    var hashes: [65_536]fingerprint.Fingerprint = undefined;
    const use_hashes = values.len <= hashes.len;
    var table: [131_072]u32 = undefined;
    var table_len: usize = 1;
    while (table_len < values.len * 2) table_len *= 2;
    const use_table = use_hashes and values.len >= 32;
    if (use_table) @memset(table[0..table_len], 0);

    var unique_len: u32 = 0;
    for (values) |candidate| {
        const candidate_hash = if (use_hashes)
            fingerprint.hash_value(
                eval_pool,
                candidate,
                fingerprint.hash_init(),
            )
        else
            0;
        var duplicate = false;
        var insert_slot: usize = 0;
        if (use_table) {
            insert_slot = @as(usize, @truncate(candidate_hash)) &
                (table_len - 1);
            while (table[insert_slot] != 0) {
                const existing_index = table[insert_slot] - 1;
                if (hashes[existing_index] == candidate_hash) {
                    if (builtin.mode == .ReleaseFast or
                        values[existing_index].eql(candidate, eval_pool))
                    {
                        duplicate = true;
                        break;
                    }
                }
                insert_slot = (insert_slot + 1) & (table_len - 1);
            }
        } else {
            for (values[0..unique_len], 0..) |existing, i| {
                if (use_hashes and hashes[i] != candidate_hash) continue;
                if (use_hashes and builtin.mode == .ReleaseFast) {
                    // TLC also uses 64-bit fingerprints as its identity boundary.
                    // Debug and safe builds retain structural verification so a
                    // collision is observable during development.
                    duplicate = true;
                    break;
                }
                if (existing.eql(candidate, eval_pool)) {
                    duplicate = true;
                    break;
                }
            }
        }
        if (!duplicate) {
            values[unique_len] = candidate;
            if (use_hashes) hashes[unique_len] = candidate_hash;
            if (use_table) table[insert_slot] = unique_len + 1;
            unique_len += 1;
        }
    }
    assert(unique_len <= values.len);
    return .{
        .offset = value_offset(eval_pool, values.ptr),
        .len = unique_len,
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
    const base = @intFromPtr(eval_pool.values.ptr);
    const addr = @intFromPtr(ptr);
    assert(addr >= base);
    const bytes = addr - base;
    assert(bytes % @sizeOf(Value) == 0);
    const offset: u32 = @intCast(bytes / @sizeOf(Value));
    assert(offset <= eval_pool.value_count);
    return offset;
}

fn collect_application_groups(
    application: *ast.Apply,
    root_name: *[]const u8,
    groups: []ApplicationGroup,
    group_count: *u8,
) bool {
    switch (application.func.*) {
        .ident => |name| root_name.* = name,
        .apply => |parent| {
            if (!collect_application_groups(
                parent,
                root_name,
                groups,
                group_count,
            )) return false;
        },
        else => return false,
    }
    if (group_count.* >= groups.len) return false;
    groups[group_count.*] = .{ .args = application.args };
    group_count.* += 1;
    return true;
}

fn apply_cross_pool(
    evaluator: Evaluator,
    function: Value,
    function_pool: *const ValuePool,
    key: Value,
    key_pool: *const ValuePool,
) Error!Value {
    return switch (function) {
        .function_v => |function_v| blk: {
            const keys = function_v.domain.items(function_pool);
            const entries = function_v.entries(function_pool);
            for (keys, entries) |candidate, entry| {
                if (cross_pool_eql(
                    candidate,
                    function_pool,
                    key,
                    key_pool,
                )) break :blk entry;
            }
            return evaluator.fail(
                Error.IndexOutOfBounds,
                "state function application",
                @tagName(key),
            );
        },
        .tuple_v => |tuple| blk: {
            const index = (key.as_int() orelse
                return evaluator.fail(
                    Error.TypeError,
                    "state tuple application",
                    @tagName(key),
                )) - 1;
            if (index < 0 or index >= tuple.len) {
                return evaluator.fail(
                    Error.IndexOutOfBounds,
                    "state tuple application",
                    @tagName(key),
                );
            }
            break :blk tuple.items(function_pool)[@intCast(index)];
        },
        .record_v => |record| blk: {
            if (key != .string_v) {
                return evaluator.fail(
                    Error.TypeError,
                    "state record application",
                    @tagName(key),
                );
            }
            const name = key.string_v.slice(key_pool);
            break :blk record.lookup(function_pool, name) orelse
                return evaluator.fail(
                    Error.UndefinedSymbol,
                    "state record application",
                    name,
                );
        },
        else => evaluator.fail(
            Error.TypeError,
            "state application",
            @tagName(function),
        ),
    };
}

fn cross_pool_eql(
    left: Value,
    left_pool: *const ValuePool,
    right: Value,
    right_pool: *const ValuePool,
) bool {
    return Value.eql_cross_pool(left, left_pool, right, right_pool);
}

/// Try to evaluate an expression to a symbolic set value without materializing
/// its elements.  Used for membership tests (`x \in S`).  Returns null when the
/// expression is not a recognized symbolic-set pattern.
fn eval_symbolic_set(
    self: Evaluator,
    expr: *ast.Expr,
    ctx: Context,
    s0: ?*StateStore.State,
    eval_pool: *ValuePool,
    state_pool: *ValuePool,
) Error!?Value {
    switch (expr.*) {
        .ident, .set_enum => {
            const set = try self.eval_expr(expr, ctx, s0, eval_pool, state_pool);
            return if (set.is_set_like()) set else null;
        },
        .set_of_functions => |sf| {
            const domain = (try eval_symbolic_set(
                self,
                sf.domain,
                ctx,
                s0,
                eval_pool,
                state_pool,
            )) orelse try self.eval_expr(
                sf.domain,
                ctx,
                s0,
                eval_pool,
                state_pool,
            );
            const codomain = (try eval_symbolic_set(
                self,
                sf.codomain,
                ctx,
                s0,
                eval_pool,
                state_pool,
            )) orelse try self.eval_expr(
                sf.codomain,
                ctx,
                s0,
                eval_pool,
                state_pool,
            );
            if (!domain.is_set_like() or !codomain.is_set_like()) return null;
            return try make_function_set_value(eval_pool, domain, codomain);
        },
        .record_set => |rs| {
            const dest = try eval_pool.alloc_values(@intCast(rs.fields.len * 2));
            for (rs.fields, 0..) |f, i| {
                const domain = (try eval_symbolic_set(
                    self,
                    f.domain,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                )) orelse try self.eval_expr(
                    f.domain,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                if (!domain.is_set_like()) return null;
                const name = try eval_pool.push_string(f.name);
                dest[i * 2] = Value{ .string_v = name };
                dest[i * 2 + 1] = domain;
            }
            return Value{ .record_set_v = .{
                .offset = value_offset(eval_pool, dest.ptr),
                .len = @intCast(rs.fields.len),
            } };
        },
        .set_binary => |sb| {
            switch (sb.op) {
                .cartesian_op => {
                    const left = (try eval_symbolic_set(
                        self,
                        sb.left,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    )) orelse try self.eval_expr(
                        sb.left,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                    const right = (try eval_symbolic_set(
                        self,
                        sb.right,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    )) orelse try self.eval_expr(
                        sb.right,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                    if (!left.is_set_like() or !right.is_set_like()) return null;
                    // Flatten: if left is a tuple_set_v, extend it with right.
                    if (left == .tuple_set_v) {
                        const ts = left.tuple_set_v;
                        const ss = ts.sets(eval_pool);
                        const dest = try eval_pool.alloc_values(@intCast(ss.len + 1));
                        @memcpy(dest[0..ss.len], ss);
                        dest[ss.len] = right;
                        return Value{ .tuple_set_v = .{
                            .offset = value_offset(eval_pool, dest.ptr),
                            .len = @intCast(ss.len + 1),
                        } };
                    }
                    const dest = try eval_pool.alloc_values(2);
                    dest[0] = left;
                    dest[1] = right;
                    return Value{ .tuple_set_v = .{
                        .offset = value_offset(eval_pool, dest.ptr),
                        .len = 2,
                    } };
                },
                .union_op => {
                    const left = try eval_symbolic_set(self, sb.left, ctx, s0, eval_pool, state_pool);
                    const right = try eval_symbolic_set(self, sb.right, ctx, s0, eval_pool, state_pool);
                    if (left == null or right == null) return null;
                    if (left.? == .set_v and right.? == .set_v) return null;
                    return try make_binary_set_value(eval_pool, .cup_v, left.?, right.?);
                },
                .intersection_op => {
                    const left = try eval_symbolic_set(self, sb.left, ctx, s0, eval_pool, state_pool);
                    const right = try eval_symbolic_set(self, sb.right, ctx, s0, eval_pool, state_pool);
                    if (left == null or right == null) return null;
                    if (left.? == .set_v and right.? == .set_v) return null;
                    return try make_binary_set_value(eval_pool, .cap_v, left.?, right.?);
                },
                .difference_op => {
                    const left = try eval_symbolic_set(self, sb.left, ctx, s0, eval_pool, state_pool);
                    const right = try eval_symbolic_set(self, sb.right, ctx, s0, eval_pool, state_pool);
                    if (left == null or right == null) return null;
                    if (left.? == .set_v and right.? == .set_v) return null;
                    return try make_binary_set_value(eval_pool, .diff_v, left.?, right.?);
                },
            }
        },
        .unary => |u| {
            if (u.op == .subset) {
                const base = (try eval_symbolic_set(
                    self,
                    u.operand,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                )) orelse try self.eval_expr(
                    u.operand,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                if (!base.is_set_like()) return null;
                return Value{ .power_set_v = .{
                    .set_offset = try eval_pool.push_value(base),
                } };
            }
            if (u.op != .union_all) return null;
            if (try eval_symbolic_set(self, u.operand, ctx, s0, eval_pool, state_pool)) |inner| {
                return try make_union_value(eval_pool, inner);
            }
            const set = try self.eval_expr(u.operand, ctx, s0, eval_pool, state_pool);
            if (!set.is_set_like()) return null;
            return try make_union_value(eval_pool, set);
        },
        .set_map => |sm| {
            // Recognize { [1..n -> S] : n \in Domain } as a sequence set.
            const maybe_seq = try eval_symbolic_seq_map(self, sm, ctx, s0, eval_pool, state_pool);
            if (maybe_seq) |sv| return sv;
            return null;
        },
        .apply => |ap| {
            if (ap.func.* != .ident) return null;
            const name = self.resolve_alias(ap.func.*.ident);
            if (std.mem.eql(u8, name, "Seq") and ap.args.len == 1) {
                const arg = try self.eval_expr(ap.args[0], ctx, s0, eval_pool, state_pool);
                if (!arg.is_set_like()) return null;
                return try make_sequence_set_value(eval_pool, arg);
            }
            if (self.find_definition(name)) |def| {
                if (def.params.len != ap.args.len) return null;
                const values = try eval_pool.alloc_values(@intCast(ap.args.len));
                for (ap.args, 0..) |arg, i| {
                    values[i] = try self.eval_expr(arg, ctx, s0, eval_pool, state_pool);
                }
                var new_ctx = Context.empty();
                for (def.params, 0..) |p, i| {
                    new_ctx = try self.extend_context(new_ctx, p, values[i]);
                }
                return try eval_symbolic_set(self, def.body, new_ctx, s0, eval_pool, state_pool);
            }
            return null;
        },
        .binary => |b2| {
            if (b2.op != .range) return null;
            const lo = try self.eval_expr(b2.left, ctx, s0, eval_pool, state_pool);
            const hi = try self.eval_expr(b2.right, ctx, s0, eval_pool, state_pool);
            if (lo != .int_v or hi != .int_v) return null;
            if (hi.int_v < lo.int_v) return Value{ .set_v = .{ .offset = 0, .len = 0 } };
            const count: u32 = @intCast(hi.int_v - lo.int_v + 1);
            const dest = try eval_pool.alloc_values(count);
            var i: i64 = lo.int_v;
            for (dest) |*slot| {
                slot.* = Value{ .int_v = i };
                i += 1;
            }
            return Value{ .set_v = .{ .offset = value_offset(eval_pool, dest.ptr), .len = count } };
        },
        else => return null,
    }
}

fn make_function_set_value(eval_pool: *ValuePool, domain: Value, codomain: Value) Error!Value {
    assert(domain.is_set_like());
    assert(codomain.is_set_like());
    const dom_offset = try eval_pool.push_value(domain);
    const cod_offset = try eval_pool.push_value(codomain);
    return Value{ .function_set_v = .{ .domain_offset = dom_offset, .codomain_offset = cod_offset } };
}

fn make_sequence_set_value(eval_pool: *ValuePool, element_set: Value) Error!Value {
    assert(element_set.is_set_like());
    return Value{ .seq_set_v = .{
        .element_set_offset = try eval_pool.push_value(element_set),
    } };
}

fn make_binary_set_value(eval_pool: *ValuePool, tag: value.ValueTag, left: Value, right: Value) Error!Value {
    assert(left.is_set_like());
    assert(right.is_set_like());
    const lo = try eval_pool.push_value(left);
    const ro = try eval_pool.push_value(right);
    return switch (tag) {
        .cup_v => Value{ .cup_v = .{ .left_offset = lo, .right_offset = ro } },
        .cap_v => Value{ .cap_v = .{ .left_offset = lo, .right_offset = ro } },
        .diff_v => Value{ .diff_v = .{ .left_offset = lo, .right_offset = ro } },
        else => unreachable,
    };
}

fn make_seq_set_value(eval_pool: *ValuePool, value_set: Value, max_len: u32) Error!Value {
    assert(value_set.is_set_like());
    if (max_len == 0) {
        const empty_set = try eval_pool.push_value(Value{ .set_v = .{ .offset = 0, .len = 0 } });
        return Value{ .union_v = .{ .set_offset = @intCast(empty_set) } };
    }
    const slots = try eval_pool.alloc_values(@intCast(max_len + 1));
    var n: i64 = 0;
    for (slots) |*slot| {
        const dom = try eval_pool.alloc_values(@intCast(n));
        var i: i64 = 1;
        for (dom) |*d| {
            d.* = Value{ .int_v = i };
            i += 1;
        }
        slot.* = try make_function_set_value(
            eval_pool,
            Value{ .set_v = .{ .offset = value_offset(eval_pool, dom.ptr), .len = @intCast(n) } },
            value_set,
        );
        n += 1;
    }
    const union_set = Value{ .set_v = .{ .offset = value_offset(eval_pool, slots.ptr), .len = @intCast(slots.len) } };
    return Value{ .union_v = .{ .set_offset = try eval_pool.push_value(union_set) } };
}

fn make_union_value(eval_pool: *ValuePool, set: Value) Error!Value {
    assert(set.is_set_like());
    return Value{ .union_v = .{ .set_offset = try eval_pool.push_value(set) } };
}

fn eval_symbolic_seq_map(
    self: Evaluator,
    sm: *ast.SetMap,
    ctx: Context,
    s0: ?*StateStore.State,
    eval_pool: *ValuePool,
    state_pool: *ValuePool,
) Error!?Value {
    // Recognize { [1..n -> S] : n \in Domain } as a sequence set.
    if (sm.vars.len != 1) return null;
    const map_var = sm.vars[0];
    if (sm.value.* != .set_of_functions) return null;
    const fs = sm.value.*.set_of_functions;
    if (fs.domain.* != .binary or fs.domain.*.binary.op != .range) return null;
    const range = fs.domain.*.binary;
    if (range.left.* != .int_literal or range.left.*.int_literal != 1) return null;
    if (range.right.* != .ident or !std.mem.eql(u8, range.right.*.ident, map_var.name)) return null;

    const codomain = try self.eval_expr(fs.codomain, ctx, s0, eval_pool, state_pool);
    if (!codomain.is_set_like()) return null;

    const domain = try self.eval_expr(map_var.domain, ctx, s0, eval_pool, state_pool);
    if (!domain.is_set_like()) return null;

    const slots = switch (domain) {
        .set_v => |s| blk: {
            const vals = s.items(eval_pool);
            const dest = try eval_pool.alloc_values(@intCast(vals.len));
            for (vals, 0..) |v, i| {
                if (v != .int_v or v.int_v < 0) return null;
                dest[i] = try make_symbolic_function_set(eval_pool, @intCast(v.int_v), codomain);
            }
            break :blk dest;
        },
        .range_v => |r| blk: {
            if (r.lo < 0 or r.hi < r.lo) return null;
            const len: u32 = @intCast(r.hi - r.lo + 1);
            const dest = try eval_pool.alloc_values(len);
            var v: i64 = r.lo;
            for (0..len) |i| {
                if (v < 0) return null;
                dest[i] = try make_symbolic_function_set(eval_pool, @intCast(v), codomain);
                v += 1;
            }
            break :blk dest;
        },
        else => return null,
    };

    return Value{ .set_v = .{ .offset = value_offset(eval_pool, slots.ptr), .len = @intCast(slots.len) } };
}

fn make_symbolic_function_set(eval_pool: *ValuePool, n: u32, codomain: Value) error{OutOfMemory}!Value {
    const dom = try eval_pool.alloc_values(n);
    var k: i64 = 1;
    for (dom) |*d| {
        d.* = Value{ .int_v = k };
        k += 1;
    }
    const domain_set = Value{ .set_v = .{ .offset = value_offset(eval_pool, dom.ptr), .len = n } };
    return Value{ .function_set_v = .{
        .domain_offset = try eval_pool.push_value(domain_set),
        .codomain_offset = try eval_pool.push_value(codomain),
    } };
}

test "pointwise function predicate requires access by bound key" {
    const parser = @import("parser.zig");
    const source =
        \\---------------------- MODULE Pointwise ----------------------
        \\CONSTANTS D, C
        \\Good == {f \in [D -> C] : \A x \in D : f[x] = x}
        \\Bad == {f \in [D -> C] : \A x \in D : f["other"] = x}
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    const module = try module_parser.parse_module();
    try std.testing.expectEqual(@as(usize, 2), module.definitions.len);

    const good = module.definitions[0].body.set_filter;
    const good_quantifier = good.pred.quantifier;
    try std.testing.expect(is_pointwise_function_predicate(
        good_quantifier.body,
        good.vars[0].name,
        good_quantifier.vars[0].name,
    ));

    const bad = module.definitions[1].body.set_filter;
    const bad_quantifier = bad.pred.quantifier;
    try std.testing.expect(!is_pointwise_function_predicate(
        bad_quantifier.body,
        bad.vars[0].name,
        bad_quantifier.vars[0].name,
    ));
}
