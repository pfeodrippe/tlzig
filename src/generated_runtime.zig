const std = @import("std");
const Value = @import("value.zig").Value;
const ValuePool = @import("value.zig").ValuePool;
const ModelTable = @import("value.zig").ModelTable;
const Set = @import("value.zig").Set;
const BinarySet = @import("value.zig").BinarySet;
const Function = @import("value.zig").Function;
const Record = @import("value.zig").Record;
const State = @import("state.zig").StateStore.State;
const Error = @import("err.zig").Error;

pub const generated_model_abi_version: u32 = 2;

const variable_count_max = 64;
const materialized_variable_cache_count = variable_count_max * 2;
const MaterializedVariableCacheMask = u128;

pub const NamedValue = struct {
    name: []const u8,
    value: Value,
};

pub const CallContext = struct {
    pub const NativeCall = *const fn (
        *const anyopaque,
        *ValuePool,
        []const u8,
        []const Value,
        ?*State,
    ) Error!Value;
    pub const CachedCall = *const fn (
        *const anyopaque,
        []const u8,
        []const Value,
        *ValuePool,
        ?*State,
        ?*State,
    ) Error!?Value;
    pub const PutCachedCall = *const fn (
        *const anyopaque,
        []const u8,
        []const Value,
        Value,
        *ValuePool,
        ?*State,
        ?*State,
    ) Error!void;

    eval_pool: *ValuePool,
    state_pool: *ValuePool,
    state: ?*State,
    next_state: ?*State,
    partial_mask: u64,
    partial_values: []const Value,
    partial_value_pools: []const ?*const ValuePool,
    read_primed: bool,
    enabled_result: ?bool = null,
    constants: []const NamedValue,
    constant_slots: []const ?Value,
    generated_cache: []?Value,
    generated_cache_pool: *ValuePool,
    generated_cache_frozen: bool,
    late_generated_cache: []?Value = &.{},
    late_generated_cache_pool: ?*ValuePool = null,
    models: *const ModelTable,
    memo_context: ?*const anyopaque = null,
    cached_call: ?CachedCall = null,
    put_cached_call: ?PutCachedCall = null,
    cached_stable_call: ?CachedCall = null,
    put_cached_stable_call: ?PutCachedCall = null,
    native_context: *const anyopaque,
    native_call: NativeCall,
    max_seq_len: u32,
    materialized_variable_cache: [materialized_variable_cache_count]MaterializedVariableCacheEntry = undefined,
    materialized_variable_cache_mask: MaterializedVariableCacheMask = 0,
};

pub inline fn enabled_bool(context: *const CallContext) bool {
    return context.enabled_result orelse true;
}

pub inline fn enabled(context: *const CallContext) Value {
    return .{ .bool_v = enabled_bool(context) };
}

const MaterializedVariableCacheEntry = struct {
    value: Value,
    value_count: u32,
    string_count: u32,
    variable_index: u32,
    primed: bool,
};

pub fn cached_recursive_call(
    context: *CallContext,
    name: []const u8,
    args: []const Value,
) Error!?Value {
    const callback = context.cached_call orelse return null;
    return callback(
        context.memo_context orelse return null,
        name,
        args,
        context.eval_pool,
        context.state,
        context.next_state,
    );
}

pub fn put_cached_recursive_call(
    context: *CallContext,
    name: []const u8,
    args: []const Value,
    result: Value,
) Error!Value {
    if (context.put_cached_call) |callback| {
        if (context.memo_context) |memo_context| {
            try callback(
                memo_context,
                name,
                args,
                result,
                context.eval_pool,
                context.state,
                context.next_state,
            );
        }
    }
    return result;
}

pub fn cached_stable_call(
    context: *CallContext,
    name: []const u8,
    args: []const Value,
) Error!?Value {
    const callback = context.cached_stable_call orelse return null;
    return callback(
        context.memo_context orelse return null,
        name,
        args,
        context.eval_pool,
        context.state,
        context.next_state,
    );
}

pub fn put_cached_stable_call(
    context: *CallContext,
    name: []const u8,
    args: []const Value,
    result: Value,
) Error!Value {
    if (context.put_cached_stable_call) |callback| {
        if (context.memo_context) |memo_context| {
            try callback(
                memo_context,
                name,
                args,
                result,
                context.eval_pool,
                context.state,
                context.next_state,
            );
        }
    }
    return result;
}

pub const OperatorFn = *const fn (*CallContext, []const Value) Error!Value;
pub const OperatorBoolFn = *const fn (*CallContext, []const Value) Error!bool;

pub const PathKey = union(enum) {
    value: Value,
    field: []const u8,
};

pub const ResolvedPath = struct {
    value: Value,
    source_pool: *const ValuePool,
};

pub const FilterPathKey = union(enum) {
    argument: u8,
    bound,
    field: []const u8,
};

pub const QuantifierKind = enum {
    exists,
    forall,
};

pub const LetDefinition = struct {
    function: OperatorFn,
    arity: u16,
    recursive: bool = false,
};

pub const Operator = struct {
    name: []const u8,
    arity: u16,
    function: ?OperatorFn,
    cacheable: bool = false,
    eager_cache: bool = false,
    cache_index: ?u32 = null,
    state_memo_required: bool = false,
};

pub const Expression = struct {
    identity: u32,
    arg_names: []const []const u8,
    arg_depths: []const u8 = &.{},
    arg_required: []const bool = &.{},
    direct_arg_index: ?u8 = null,
    direct_value: ?Value = null,
    uses_primed: bool = true,
    function: OperatorFn,
    boolean_function: ?OperatorBoolFn = null,
};

pub inline fn keep_expression_parameters(
    context: *CallContext,
    args: []const Value,
) void {
    _ = context;
    _ = args;
}

pub fn variable(context: *CallContext, index: u32) Error!Value {
    if (context.read_primed) return primed_variable(context, index);
    return current_variable(context, index);
}

fn current_variable(context: *CallContext, index: u32) Error!Value {
    return materialized_variable(context, index, false);
}

fn materialized_variable(
    context: *CallContext,
    index: u32,
    primed: bool,
) Error!Value {
    if (index >= variable_count_max) return Error.TypeError;
    const slot: u7 = @intCast(index * 2 + @intFromBool(primed));
    std.debug.assert(slot < materialized_variable_cache_count);
    const slot_bit = @as(MaterializedVariableCacheMask, 1) << slot;
    if (context.materialized_variable_cache_mask & slot_bit != 0) {
        const entry = context.materialized_variable_cache[slot];
        if (entry.variable_index == index and entry.primed == primed) {
            std.debug.assert(entry.value_count <= context.eval_pool.value_count);
            std.debug.assert(entry.string_count <= context.eval_pool.string_count);
            return entry.value;
        }
    }

    var source_pool: *const ValuePool = context.eval_pool;
    const value = if (primed)
        try resolve_primed_variable(context, index, &source_pool)
    else
        try resolve_current_variable(context, index, &source_pool);
    switch (value) {
        .bool_v, .int_v, .model_v, .range_v => return value,
        else => {},
    }
    const cloned = try value.clone(source_pool, context.eval_pool);
    context.materialized_variable_cache[slot] = .{
        .value = cloned,
        .value_count = context.eval_pool.value_count,
        .string_count = context.eval_pool.string_count,
        .variable_index = index,
        .primed = primed,
    };
    context.materialized_variable_cache_mask |= slot_bit;
    return cloned;
}

fn resolve_current_variable(
    context: *CallContext,
    index: u32,
    source_pool: **const ValuePool,
) Error!Value {
    source_pool.* = context.eval_pool;
    const current = context.state orelse {
        if (index < context.partial_values.len and
            context.partial_mask & (@as(u64, 1) << @intCast(index)) != 0)
        {
            if (index < context.partial_value_pools.len) {
                source_pool.* = context.partial_value_pools[index] orelse
                    context.eval_pool;
            }
            return context.partial_values[index];
        }
        return Error.TypeError;
    };
    if (index >= current.values.len) return Error.TypeError;
    source_pool.* = current.value_pool(index, context.state_pool);
    return current.values[index];
}

pub fn primed_variable(context: *CallContext, index: u32) Error!Value {
    return materialized_variable(context, index, true);
}

fn restore_eval_pool(
    context: *CallContext,
    snapshot: ValuePool.Snapshot,
) void {
    var valid = context.materialized_variable_cache_mask;
    while (valid != 0) {
        const slot: u7 = @intCast(@ctz(valid));
        std.debug.assert(slot < materialized_variable_cache_count);
        const slot_bit = @as(MaterializedVariableCacheMask, 1) << slot;
        valid &= ~slot_bit;
        const entry = context.materialized_variable_cache[slot];
        if (entry.value_count > snapshot.value_count or
            entry.string_count > snapshot.string_count)
        {
            context.materialized_variable_cache_mask &= ~slot_bit;
        }
    }
    context.eval_pool.restore(snapshot);
}

fn resolve_primed_variable(
    context: *CallContext,
    index: u32,
    source_pool: **const ValuePool,
) Error!Value {
    source_pool.* = context.eval_pool;
    if (index < context.partial_values.len and
        context.partial_mask & (@as(u64, 1) << @intCast(index)) != 0)
    {
        if (index < context.partial_value_pools.len) {
            source_pool.* = context.partial_value_pools[index] orelse
                context.eval_pool;
        }
        return context.partial_values[index];
    }
    if (context.next_state) |next| {
        if (index >= next.values.len) return Error.TypeError;
        source_pool.* = next.value_pool(index, context.state_pool);
        return next.values[index];
    }
    return resolve_current_variable(context, index, source_pool);
}

pub fn variable_equal_bool(
    context: *CallContext,
    index: u32,
    rhs: Value,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = if (context.read_primed)
        try resolve_primed_variable(context, index, &source_pool)
    else
        try resolve_current_variable(context, index, &source_pool);
    return Value.eql_cross_pool(value, source_pool, rhs, context.eval_pool);
}

pub fn variable_not_equal_bool(
    context: *CallContext,
    index: u32,
    rhs: Value,
) Error!bool {
    return !try variable_equal_bool(context, index, rhs);
}

pub fn variables_equal_bool(
    context: *CallContext,
    left_index: u32,
    right_index: u32,
) Error!bool {
    var left_pool: *const ValuePool = context.eval_pool;
    const left = if (context.read_primed)
        try resolve_primed_variable(context, left_index, &left_pool)
    else
        try resolve_current_variable(context, left_index, &left_pool);
    var right_pool: *const ValuePool = context.eval_pool;
    const right = if (context.read_primed)
        try resolve_primed_variable(context, right_index, &right_pool)
    else
        try resolve_current_variable(context, right_index, &right_pool);
    return Value.eql_cross_pool(left, left_pool, right, right_pool);
}

pub fn variables_not_equal_bool(
    context: *CallContext,
    left_index: u32,
    right_index: u32,
) Error!bool {
    return !try variables_equal_bool(context, left_index, right_index);
}

pub fn variable_member_bool(
    context: *CallContext,
    index: u32,
    set_value: Value,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = if (context.read_primed)
        try resolve_primed_variable(context, index, &source_pool)
    else
        try resolve_current_variable(context, index, &source_pool);
    if (!set_value.is_set_like()) return Error.TypeError;
    return member_cross_pool(context, set_value, value, source_pool);
}

pub fn variable_not_member_bool(
    context: *CallContext,
    index: u32,
    set_value: Value,
) Error!bool {
    return !try variable_member_bool(context, index, set_value);
}

pub fn variable_contains_bool(
    context: *CallContext,
    index: u32,
    element: Value,
) Error!bool {
    var set_pool: *const ValuePool = context.eval_pool;
    const set_value = if (context.read_primed)
        try resolve_primed_variable(context, index, &set_pool)
    else
        try resolve_current_variable(context, index, &set_pool);
    if (!set_value.is_set_like()) return Error.TypeError;
    return set_value.member_cross_pool(
        set_pool,
        element,
        context.eval_pool,
    );
}

pub fn variable_not_contains_bool(
    context: *CallContext,
    index: u32,
    element: Value,
) Error!bool {
    return !try variable_contains_bool(context, index, element);
}

pub fn variable_subset_equal_bool(
    context: *CallContext,
    index: u32,
    right: Value,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const left = if (context.read_primed)
        try resolve_primed_variable(context, index, &source_pool)
    else
        try resolve_current_variable(context, index, &source_pool);
    if (!left.is_set_like() or !right.is_set_like()) return Error.TypeError;
    return switch (left) {
        .set_v => |left_set| blk: {
            for (left_set.items(source_pool)) |item| {
                if (!right.member_cross_pool(
                    context.eval_pool,
                    item,
                    source_pool,
                )) break :blk false;
            }
            break :blk true;
        },
        .range_v => |left_range| blk: {
            if (left_range.hi < left_range.lo) break :blk true;
            var item = left_range.lo;
            while (true) {
                if (!right.member(
                    context.eval_pool,
                    .{ .int_v = item },
                )) break :blk false;
                if (item == left_range.hi) break;
                item += 1;
            }
            break :blk true;
        },
        else => subset_equal_bool(
            context,
            try left.clone(source_pool, context.eval_pool),
            right,
        ),
    };
}

pub fn primed_variable_except_update_equal_bool(
    context: *CallContext,
    operator_args: []const Value,
    index: u32,
    path: []const Value,
    updater: OperatorFn,
) Error!bool {
    var current_pool: *const ValuePool = context.eval_pool;
    const current = try resolve_current_variable(
        context,
        index,
        &current_pool,
    );
    var next_pool: *const ValuePool = context.eval_pool;
    const next = try resolve_primed_variable(context, index, &next_pool);
    return try equal_except_update_path(
        context,
        operator_args,
        next,
        next_pool,
        current,
        current_pool,
        path,
        0,
        updater,
    );
}

pub fn primed_variable_except_update_path_equal_bool(
    context: *CallContext,
    operator_args: []const Value,
    index: u32,
    path: []const PathKey,
    updater: OperatorFn,
) Error!bool {
    var current_pool: *const ValuePool = context.eval_pool;
    const current = try resolve_current_variable(
        context,
        index,
        &current_pool,
    );
    var next_pool: *const ValuePool = context.eval_pool;
    const next = try resolve_primed_variable(context, index, &next_pool);
    return try equal_except_update_path_keys(
        context,
        operator_args,
        next,
        next_pool,
        current,
        current_pool,
        path,
        0,
        updater,
    );
}

pub fn primed_variable_double_except_update_equal_bool(
    context: *CallContext,
    operator_args: []const Value,
    index: u32,
    path_a: []const Value,
    updater_a: OperatorFn,
    path_b: []const Value,
    updater_b: OperatorFn,
) Error!bool {
    var current_pool: *const ValuePool = context.eval_pool;
    const current = try resolve_current_variable(
        context,
        index,
        &current_pool,
    );
    var next_pool: *const ValuePool = context.eval_pool;
    const next = try resolve_primed_variable(context, index, &next_pool);
    return try equal_double_except_update_path(
        context,
        operator_args,
        next,
        next_pool,
        current,
        current_pool,
        path_a,
        0,
        updater_a,
        path_b,
        0,
        updater_b,
    );
}

pub fn primed_variable_double_except_update_path_equal_bool(
    context: *CallContext,
    operator_args: []const Value,
    index: u32,
    path_a: []const PathKey,
    updater_a: OperatorFn,
    path_b: []const PathKey,
    updater_b: OperatorFn,
) Error!bool {
    var current_pool: *const ValuePool = context.eval_pool;
    const current = try resolve_current_variable(
        context,
        index,
        &current_pool,
    );
    var next_pool: *const ValuePool = context.eval_pool;
    const next = try resolve_primed_variable(context, index, &next_pool);
    return try equal_double_except_update_path_keys(
        context,
        operator_args,
        next,
        next_pool,
        current,
        current_pool,
        path_a,
        0,
        updater_a,
        path_b,
        0,
        updater_b,
    );
}

pub fn primed_expression(
    context: *CallContext,
    args: []const Value,
    expression: OperatorFn,
) Error!Value {
    const previous = context.read_primed;
    context.read_primed = true;
    defer context.read_primed = previous;
    return expression(context, args);
}

pub fn unchanged_expression(
    context: *CallContext,
    args: []const Value,
    expression: OperatorFn,
) Error!bool {
    const current = try expression(context, args);
    const next = try primed_expression(context, args, expression);
    return current.eql(next, context.eval_pool);
}

pub fn unchanged_variable(
    context: *CallContext,
    index: u32,
) Error!bool {
    var current_pool: *const ValuePool = context.eval_pool;
    const current = try resolve_current_variable(
        context,
        index,
        &current_pool,
    );
    var next_pool: *const ValuePool = context.eval_pool;
    const next = try resolve_primed_variable(context, index, &next_pool);
    return Value.eql_cross_pool(
        current,
        current_pool,
        next,
        next_pool,
    );
}

pub fn unchanged_variables(
    context: *CallContext,
    indices: []const u32,
) Error!bool {
    for (indices) |index| {
        var current_pool: *const ValuePool = context.eval_pool;
        const current = try resolve_current_variable(
            context,
            index,
            &current_pool,
        );
        var next_pool: *const ValuePool = context.eval_pool;
        const next = try resolve_primed_variable(context, index, &next_pool);
        if (!Value.eql_cross_pool(
            current,
            current_pool,
            next,
            next_pool,
        )) return false;
    }
    return true;
}

pub fn constant(context: *CallContext, name: []const u8) Error!Value {
    for (context.constants) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.value.clone(
                context.state_pool,
                context.eval_pool,
            );
        }
    }
    return Error.UndefinedSymbol;
}

pub fn constant_at(
    context: *CallContext,
    index: u32,
) Error!Value {
    if (index >= context.constant_slots.len) {
        if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
            std.debug.print(
                "generated constant slot out of bounds: index={d} slots={d}\n",
                .{ index, context.constant_slots.len },
            );
        }
        return Error.UndefinedSymbol;
    }
    const value = context.constant_slots[index] orelse {
        if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
            std.debug.print(
                "generated constant slot is unset: index={d} slots={d}\n",
                .{ index, context.constant_slots.len },
            );
        }
        return Error.UndefinedSymbol;
    };
    return value.clone(context.state_pool, context.eval_pool);
}

pub fn cached_definition(
    context: *CallContext,
    index: u32,
) Error!?Value {
    std.debug.assert(
        context.late_generated_cache.len == 0 or
            context.late_generated_cache.len == context.generated_cache.len,
    );
    std.debug.assert(
        (context.late_generated_cache.len == 0) ==
            (context.late_generated_cache_pool == null),
    );
    if (index >= context.generated_cache.len) return Error.TypeError;
    if (context.generated_cache[index]) |value_v| {
        if (context.generated_cache_pool == context.eval_pool) return value_v;
        return try value_v.clone(
            context.generated_cache_pool,
            context.eval_pool,
        );
    }
    if (index >= context.late_generated_cache.len) return null;
    const value_v = context.late_generated_cache[index] orelse return null;
    const cache_pool = context.late_generated_cache_pool orelse
        return Error.AssertionFailed;
    std.debug.assert(cache_pool != context.eval_pool);
    std.debug.assert(cache_pool.value_count <= cache_pool.value_cap);
    std.debug.assert(cache_pool.string_count <= cache_pool.string_cap);
    return try value_v.clone(cache_pool, context.eval_pool);
}

pub fn put_cached_definition(
    context: *CallContext,
    index: u32,
    value: Value,
) Error!Value {
    std.debug.assert(
        context.late_generated_cache.len == 0 or
            context.late_generated_cache.len == context.generated_cache.len,
    );
    std.debug.assert(
        (context.late_generated_cache.len == 0) ==
            (context.late_generated_cache_pool == null),
    );
    if (index >= context.generated_cache.len) return Error.TypeError;
    if (context.generated_cache[index]) |_| return value;
    if (!context.generated_cache_frozen) {
        context.generated_cache[index] = try value.clone(
            context.eval_pool,
            context.generated_cache_pool,
        );
        return value;
    }
    if (index >= context.late_generated_cache.len) return value;
    if (context.late_generated_cache[index] != null) return value;
    const cache_pool = context.late_generated_cache_pool orelse
        return Error.AssertionFailed;
    std.debug.assert(cache_pool != context.eval_pool);
    std.debug.assert(!cache_pool.growable);
    std.debug.assert(cache_pool.value_count <= cache_pool.value_cap);
    std.debug.assert(cache_pool.string_count <= cache_pool.string_cap);
    const snapshot = cache_pool.snapshot();
    context.late_generated_cache[index] = value.clone(
        context.eval_pool,
        cache_pool,
    ) catch {
        cache_pool.restore(snapshot);
        return value;
    };
    std.debug.assert(cache_pool.value_count <= cache_pool.value_cap);
    std.debug.assert(cache_pool.string_count <= cache_pool.string_cap);
    if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
        std.debug.print("generated late cache filled slot {d}\n", .{index});
    }
    return value;
}

test "frozen generated cache fills a bounded local late cache" {
    const Arena = @import("arena.zig").Arena;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 64, 64);
    var late_pool = try ValuePool.init(&arena, 64, 64);
    late_pool.growable = false;
    var models = try ModelTable.init(&arena, 4);
    var generated_cache = [_]?Value{null};
    var late_generated_cache = [_]?Value{null};
    var context = CallContext{
        .eval_pool = &pool,
        .state_pool = &pool,
        .state = null,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &pool,
        .generated_cache_frozen = true,
        .late_generated_cache = &late_generated_cache,
        .late_generated_cache_pool = &late_pool,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 4,
    };

    const snapshot = pool.snapshot();
    const offset = try pool.push_values(&.{.{ .int_v = 17 }});
    const value = Value{ .tuple_v = .{ .offset = offset, .len = 1 } };
    try std.testing.expectEqual(
        value,
        try put_cached_definition(&context, 0, value),
    );
    try std.testing.expectEqual(@as(?Value, null), generated_cache[0]);
    try std.testing.expect(late_generated_cache[0] != null);
    pool.restore(snapshot);
    const cached = (try cached_definition(&context, 0)).?;
    try std.testing.expectEqual(
        @as(i64, 17),
        cached.tuple_v.items(&pool)[0].int_v,
    );
}

test "frozen generated cache rolls back a rejected late entry" {
    const Arena = @import("arena.zig").Arena;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 64, 64);
    var late_pool = try ValuePool.init(&arena, 1, 1);
    late_pool.growable = false;
    var models = try ModelTable.init(&arena, 4);
    var generated_cache = [_]?Value{null};
    var late_generated_cache = [_]?Value{null};
    var context = CallContext{
        .eval_pool = &pool,
        .state_pool = &pool,
        .state = null,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &pool,
        .generated_cache_frozen = true,
        .late_generated_cache = &late_generated_cache,
        .late_generated_cache_pool = &late_pool,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 4,
    };

    const offset = try pool.push_values(&.{
        .{ .int_v = 17 },
        .{ .int_v = 23 },
    });
    const value = Value{ .tuple_v = .{ .offset = offset, .len = 2 } };
    const late_snapshot = late_pool.snapshot();
    try std.testing.expectEqual(
        value,
        try put_cached_definition(&context, 0, value),
    );
    try std.testing.expectEqual(@as(?Value, null), late_generated_cache[0]);
    try std.testing.expectEqual(late_snapshot, late_pool.snapshot());
}

pub fn cached_function_apply(
    context: *CallContext,
    index: u32,
    args: []const Value,
) Error!?Value {
    std.debug.assert(context.eval_pool.value_count <= context.eval_pool.value_cap);
    std.debug.assert(
        context.generated_cache_pool.value_count <=
            context.generated_cache_pool.value_cap,
    );
    if (index >= context.generated_cache.len) return Error.TypeError;
    const function_value = context.generated_cache[index] orelse return null;
    if (function_value != .function_v) return Error.AssertionFailed;
    if (args.len == 0) return Error.TypeError;

    const source_pool = context.generated_cache_pool;
    const function_v = function_value.function_v;
    const keys = function_v.domain.items(source_pool);
    const entries = function_v.entries(source_pool);
    std.debug.assert(keys.len == entries.len);

    for (keys, entries) |key, entry| {
        const matched = if (args.len == 1)
            values_equal_cross_pool(
                key,
                source_pool,
                args[0],
                context.eval_pool,
            )
        else
            function_key_matches_args(
                key,
                source_pool,
                args,
                context.eval_pool,
            );
        if (!matched) continue;
        return try entry.clone(source_pool, context.eval_pool);
    }
    return Error.TypeError;
}

fn function_key_matches_args(
    key: Value,
    key_pool: *const ValuePool,
    args: []const Value,
    args_pool: *const ValuePool,
) bool {
    if (key != .tuple_v or key.tuple_v.len != args.len) return false;
    for (key.tuple_v.items(key_pool), args) |key_item, arg| {
        if (!values_equal_cross_pool(key_item, key_pool, arg, args_pool)) {
            return false;
        }
    }
    return true;
}

fn values_equal_cross_pool(
    left: Value,
    left_pool: *const ValuePool,
    right: Value,
    right_pool: *const ValuePool,
) bool {
    return Value.eql_ordered_cross_pool(
        left,
        left_pool,
        right,
        right_pool,
    ) or Value.eql_cross_pool(
        left,
        left_pool,
        right,
        right_pool,
    );
}

test "cached functions apply across value pools without materializing functions" {
    const Arena = @import("arena.zig").Arena;
    var source_arena = try Arena.init(1024 * 1024);
    defer source_arena.deinit();
    var eval_arena = try Arena.init(1024 * 1024);
    defer eval_arena.deinit();
    var source_pool = try ValuePool.init(&source_arena, 64, 256);
    var eval_pool = try ValuePool.init(&eval_arena, 64, 256);
    var models = try ModelTable.init(&source_arena, 4);

    const source_key = Value{ .string_v = try source_pool.push_string("key") };
    const source_result = Value{
        .string_v = try source_pool.push_string("result"),
    };
    const keys_offset = try source_pool.push_values(&.{source_key});
    const entries_offset = try source_pool.push_values(&.{source_result});
    const unary = Value{ .function_v = .{
        .domain = .{ .offset = keys_offset, .len = 1 },
        .offset = entries_offset,
        .len = 1,
    } };

    const tuple_items_offset = try source_pool.push_values(&.{
        Value{ .int_v = 7 },
        source_key,
    });
    const tuple_key = Value{ .tuple_v = .{
        .offset = tuple_items_offset,
        .len = 2,
    } };
    const tuple_keys_offset = try source_pool.push_values(&.{tuple_key});
    const tuple_entries_offset = try source_pool.push_values(&.{
        Value{ .int_v = 11 },
    });
    const binary = Value{ .function_v = .{
        .domain = .{ .offset = tuple_keys_offset, .len = 1 },
        .offset = tuple_entries_offset,
        .len = 1,
    } };

    var generated_cache = [_]?Value{ unary, binary };
    var context = CallContext{
        .eval_pool = &eval_pool,
        .state_pool = &source_pool,
        .state = null,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &source_pool,
        .generated_cache_frozen = true,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 4,
    };

    _ = try eval_pool.push_string("padding");
    const eval_key = Value{ .string_v = try eval_pool.push_string("key") };
    const unary_result = (try cached_function_apply(
        &context,
        0,
        &.{eval_key},
    )).?;
    try std.testing.expectEqualStrings(
        "result",
        unary_result.string_v.slice(&eval_pool),
    );

    const binary_result = (try cached_function_apply(
        &context,
        1,
        &.{ Value{ .int_v = 7 }, eval_key },
    )).?;
    try std.testing.expectEqual(@as(i64, 11), binary_result.int_v);
    try std.testing.expectError(
        Error.TypeError,
        cached_function_apply(&context, 0, &.{.{ .int_v = 9 }}),
    );
}

pub fn nat_set(_: *CallContext) Error!Value {
    return Value{ .range_v = .{
        .lo = 0,
        .hi = std.math.maxInt(i64),
    } };
}

pub fn int_set(_: *CallContext) Error!Value {
    return Value{ .range_v = .{
        .lo = std.math.minInt(i64),
        .hi = std.math.maxInt(i64),
    } };
}

pub fn boolean_set(context: *CallContext) Error!Value {
    return set(context, &[_]Value{
        Value{ .bool_v = false },
        Value{ .bool_v = true },
    });
}

pub fn string_set(context: *CallContext) Error!Value {
    return string(context, "__STRING_SET__");
}

pub fn native(
    context: *CallContext,
    name: []const u8,
    args: []const Value,
) Error!Value {
    return context.native_call(
        context.native_context,
        context.eval_pool,
        name,
        args,
        context.state,
    );
}

pub fn native_binary(
    context: *CallContext,
    name: []const u8,
    left: Value,
    right: Value,
) Error!Value {
    const args = [_]Value{ left, right };
    return native(context, name, &args);
}

pub fn is_finite_set(
    _: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return .{ .bool_v = is_finite_set_bool(args[0]) };
}

pub inline fn is_finite_set_bool(_: Value) bool {
    return true;
}

pub fn constant_is_finite_set_at(
    context: *CallContext,
    index: u32,
) Error!bool {
    if (index >= context.constant_slots.len or
        context.constant_slots[index] == null)
    {
        return Error.UndefinedSymbol;
    }
    return true;
}

pub fn operator(
    context: *CallContext,
    function: OperatorFn,
    arity: u16,
    captures: []const Value,
) Error!Value {
    const source_offset = pool_slice_offset(context.eval_pool, captures);
    const captured = try context.eval_pool.alloc_values(
        @intCast(captures.len),
    );
    const source = if (source_offset) |offset|
        context.eval_pool.values[offset..][0..captures.len]
    else
        captures;
    @memcpy(captured, source);
    return .{ .generated_operator_v = .{
        .function_address = @intFromPtr(function),
        .arity = arity,
        .captured_offset = value_offset(
            context.eval_pool,
            captured.ptr,
        ),
        .captured_len = @intCast(captured.len),
    } };
}

fn StateReference(
    comptime variable_index: u32,
    comptime primed: bool,
) type {
    return struct {
        fn resolve(
            context: *CallContext,
            args: []const Value,
        ) Error!Value {
            std.debug.assert(args.len == 0);
            return if (primed)
                primed_variable(context, variable_index)
            else
                variable(context, variable_index);
        }
    };
}

pub fn state_reference(
    variable_index: u32,
    primed: bool,
) Error!Value {
    if (variable_index >= 64) return Error.TypeError;
    const function: OperatorFn = switch (variable_index) {
        inline 0...63 => |index| if (primed)
            StateReference(index, true).resolve
        else
            StateReference(index, false).resolve,
        else => unreachable,
    };
    return .{ .generated_operator_v = .{
        .function_address = @intFromPtr(function),
        .arity = 0,
        .captured_offset = 0,
        .captured_len = 0,
    } };
}

pub fn state_path_operator(
    context: *CallContext,
    variable_index: u32,
    prefix_keys: []const Value,
    arity: u16,
) Error!Value {
    if (variable_index >= 64 or arity == 0) return Error.TypeError;
    if (prefix_keys.len + 3 + arity > 64) return Error.NotImplemented;
    var captures: [64]Value = undefined;
    captures[0] = .{ .int_v = variable_index };
    captures[1] = .{ .int_v = @intCast(prefix_keys.len) };
    captures[2] = .{ .int_v = arity };
    @memcpy(captures[3..][0..prefix_keys.len], prefix_keys);
    return operator(
        context,
        state_path_operator_call,
        arity,
        captures[0 .. prefix_keys.len + 3],
    );
}

fn state_path_operator_call(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    var source_pool: *const ValuePool = context.eval_pool;
    const result = try resolve_state_path_operator_call(
        context,
        args,
        &source_pool,
    );
    return result.clone(source_pool, context.eval_pool);
}

fn resolve_state_path_operator_call(
    context: *CallContext,
    args: []const Value,
    source_pool: **const ValuePool,
) Error!Value {
    if (args.len < 4) return Error.TypeError;
    const variable_index = args[0].as_int() orelse return Error.TypeError;
    const prefix_count = args[1].as_int() orelse return Error.TypeError;
    const arity = args[2].as_int() orelse return Error.TypeError;
    if (variable_index < 0 or variable_index >= 64 or
        prefix_count < 0 or arity <= 0)
    {
        return Error.TypeError;
    }
    const prefix_len: usize = @intCast(prefix_count);
    const call_arity: usize = @intCast(arity);
    if (args.len != 3 + prefix_len + call_arity) {
        return Error.TypeError;
    }

    var keys: [64]Value = undefined;
    @memcpy(keys[0..prefix_len], args[3..][0..prefix_len]);
    const call_args = args[3 + prefix_len ..];
    keys[prefix_len] = if (call_args.len == 1)
        call_args[0]
    else
        try tuple(context, call_args);

    return resolve_path(
        context,
        @intCast(variable_index),
        keys[0 .. prefix_len + 1],
        source_pool,
    );
}

pub fn arguments_contain_state_path_operator(
    args: []const Value,
) bool {
    const path_operator_address = @intFromPtr(
        @as(OperatorFn, state_path_operator_call),
    );
    for (args) |argument| {
        if (argument == .generated_operator_v and
            argument.generated_operator_v.function_address ==
                path_operator_address)
        {
            return true;
        }
    }
    return false;
}

pub fn arguments_contain_generated_operator(args: []const Value) bool {
    for (args) |argument| {
        if (argument == .generated_operator_v) return true;
    }
    return false;
}

pub fn recursive_operator(
    context: *CallContext,
    function: OperatorFn,
    arity: u16,
    captures: []const Value,
) Error!Value {
    if (captures.len >= std.math.maxInt(u16)) return Error.NotImplemented;
    const source_offset = pool_slice_offset(context.eval_pool, captures);
    const captured = try context.eval_pool.alloc_values(
        @intCast(captures.len + 1),
    );
    const source = if (source_offset) |offset|
        context.eval_pool.values[offset..][0..captures.len]
    else
        captures;
    @memcpy(captured[0..captures.len], source);
    const result = Value{ .generated_operator_v = .{
        .function_address = @intFromPtr(function),
        .arity = arity,
        .captured_offset = value_offset(context.eval_pool, captured.ptr),
        .captured_len = @intCast(captured.len),
    } };
    captured[captures.len] = result;
    return result;
}

pub fn call(
    context: *CallContext,
    function: Value,
    args: []const Value,
) Error!Value {
    if (function == .generated_operator_v) {
        const operator_value = function.generated_operator_v;
        if (args.len != operator_value.arity) return Error.TypeError;
        if (operator_value.captured_len + args.len > 64) {
            return Error.NotImplemented;
        }
        const operator_function: OperatorFn = @ptrFromInt(
            operator_value.function_address,
        );
        var combined: [64]Value = undefined;
        const captured = context.eval_pool.values[operator_value.captured_offset..][0..operator_value.captured_len];
        @memcpy(combined[0..captured.len], captured);
        @memcpy(
            combined[captured.len..][0..args.len],
            args,
        );
        return operator_function(
            context,
            combined[0 .. captured.len + args.len],
        );
    }
    if (args.len == 1) return apply(context, function, args[0]);
    if (args.len > 1 and function == .function_v) {
        return apply(context, function, try tuple(context, args));
    }
    return Error.TypeError;
}

pub inline fn force(context: *CallContext, value: Value) Error!Value {
    if (!requires_force(value)) return value;
    return call(context, value, &.{});
}

pub inline fn requires_force(value: Value) bool {
    return value == .generated_operator_v and
        value.generated_operator_v.arity == 0;
}

pub fn string(context: *CallContext, bytes: []const u8) Error!Value {
    return .{ .string_v = try context.eval_pool.push_string(bytes) };
}

pub fn field(
    context: *CallContext,
    record_value: Value,
    name: []const u8,
) Error!Value {
    if (record_value == .generated_operator_v) {
        if (record_value.generated_operator_v.arity != 0) {
            return Error.TypeError;
        }
        return field(context, try call(context, record_value, &.{}), name);
    }
    return record_field(context.eval_pool, record_value, name);
}

pub inline fn call_field(
    context: *CallContext,
    function: Value,
    args: []const Value,
    name: []const u8,
) Error!Value {
    return call_field_path(context, function, args, &.{name});
}

pub inline fn call_field_path(
    context: *CallContext,
    function: Value,
    args: []const Value,
    names: []const []const u8,
) Error!Value {
    std.debug.assert(names.len > 0);
    std.debug.assert(context.eval_pool.value_count <= context.eval_pool.value_cap);
    if (function == .generated_operator_v and
        function.generated_operator_v.function_address ==
            @intFromPtr(@as(OperatorFn, state_path_operator_call)))
    {
        const operator_value = function.generated_operator_v;
        if (args.len != operator_value.arity) return Error.TypeError;
        if (operator_value.captured_len + args.len > 64) {
            return Error.NotImplemented;
        }
        const captured = context.eval_pool.values[operator_value.captured_offset..][0..operator_value.captured_len];
        var combined: [64]Value = undefined;
        @memcpy(combined[0..captured.len], captured);
        @memcpy(combined[captured.len..][0..args.len], args);

        var source_pool: *const ValuePool = context.eval_pool;
        var value = try resolve_state_path_operator_call(
            context,
            combined[0 .. captured.len + args.len],
            &source_pool,
        );
        for (names) |name| {
            value = try record_field(source_pool, value, name);
        }
        return value.clone(source_pool, context.eval_pool);
    }

    var value = try call(context, function, args);
    for (names) |name| {
        value = try record_field(context.eval_pool, value, name);
    }
    return value;
}

inline fn record_field(
    pool: *const ValuePool,
    record_value: Value,
    name: []const u8,
) Error!Value {
    if (record_value != .record_v) return Error.TypeError;
    const fields = record_value.record_v.fields(pool);
    var index: u32 = 0;
    while (index < record_value.record_v.len) : (index += 1) {
        const field_name = fields[index * 2];
        if (field_name != .string_v) return Error.TypeError;
        if (std.mem.eql(
            u8,
            field_name.string_v.slice(pool),
            name,
        )) return fields[index * 2 + 1];
    }
    if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
        std.debug.print(
            "generated record field is missing: requested={s} fields=",
            .{name},
        );
        for (0..record_value.record_v.len) |field_index| {
            if (field_index != 0) std.debug.print(",", .{});
            std.debug.print(
                "{s}",
                .{fields[field_index * 2].string_v.slice(pool)},
            );
        }
        std.debug.print("\n", .{});
    }
    return Error.UndefinedSymbol;
}

pub fn apply(
    context: *CallContext,
    function: Value,
    key: Value,
) Error!Value {
    return switch (function) {
        .function_v => |value| value.apply(
            context.eval_pool,
            key,
        ) orelse Error.IndexOutOfBounds,
        .tuple_v => |value| blk: {
            const index = key.as_int() orelse return Error.TypeError;
            if (index < 1 or index > value.len) {
                return Error.IndexOutOfBounds;
            }
            break :blk value.items(context.eval_pool)[@intCast(index - 1)];
        },
        .record_v => |value| blk: {
            if (key != .string_v) return Error.TypeError;
            break :blk try field(
                context,
                .{ .record_v = value },
                key.string_v.slice(context.eval_pool),
            );
        },
        else => Error.TypeError,
    };
}

pub fn variable_path(
    context: *CallContext,
    index: u32,
    keys: []const Value,
) Error!Value {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    return value.clone(source_pool, context.eval_pool);
}

pub fn variable_path_boolean(
    context: *CallContext,
    index: u32,
    keys: []const Value,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    if (value != .bool_v) return Error.TypeError;
    return value.bool_v;
}

pub fn variable_path_literal_string(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    literal: []const u8,
) Error!Value {
    const resolved = try resolve_path_literal_string(
        context,
        index,
        keys,
        literal,
    );
    return resolved.value.clone(resolved.source_pool, context.eval_pool);
}

pub fn variable_path_literal_string_boolean(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    literal: []const u8,
) Error!bool {
    const resolved = try resolve_path_literal_string(
        context,
        index,
        keys,
        literal,
    );
    if (resolved.value != .bool_v) return Error.TypeError;
    return resolved.value.bool_v;
}

inline fn resolve_path_literal_string(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    literal: []const u8,
) Error!ResolvedPath {
    var source_pool: *const ValuePool = context.eval_pool;
    const parent = try resolve_path(context, index, keys, &source_pool);
    const value = try apply_literal_string_cross_pool(
        parent,
        source_pool,
        literal,
    );
    return .{ .value = value, .source_pool = source_pool };
}

pub const CompareOp = enum {
    lt,
    le,
    gt,
    ge,
};

fn compare_int(left: i64, right: i64, op: CompareOp) bool {
    return switch (op) {
        .lt => left < right,
        .le => left <= right,
        .gt => left > right,
        .ge => left >= right,
    };
}

pub fn variable_path_int_compare_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    other: Value,
    op: CompareOp,
    path_left: bool,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const path_value = try resolve_path(context, index, keys, &source_pool);
    const path_int = path_value.as_int() orelse return Error.TypeError;
    const other_int = other.as_int() orelse return Error.TypeError;
    return if (path_left)
        compare_int(path_int, other_int, op)
    else
        compare_int(other_int, path_int, op);
}

pub fn variable_path_equal_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    rhs: Value,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    return Value.eql_cross_pool(value, source_pool, rhs, context.eval_pool);
}

pub fn variable_path_not_equal_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    rhs: Value,
) Error!bool {
    return !try variable_path_equal_bool(context, index, keys, rhs);
}

pub fn variable_path_literal_string_equal_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    literal: []const u8,
    rhs: Value,
) Error!bool {
    const resolved = try resolve_path_literal_string(
        context,
        index,
        keys,
        literal,
    );
    return Value.eql_cross_pool(
        resolved.value,
        resolved.source_pool,
        rhs,
        context.eval_pool,
    );
}

pub fn variable_path_literal_string_not_equal_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    literal: []const u8,
    rhs: Value,
) Error!bool {
    return !try variable_path_literal_string_equal_bool(
        context,
        index,
        keys,
        literal,
        rhs,
    );
}

pub fn variable_path_literal_string_equal_string_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    literal: []const u8,
    rhs_literal: []const u8,
) Error!bool {
    const resolved = try resolve_path_literal_string(
        context,
        index,
        keys,
        literal,
    );
    if (resolved.value != .string_v) return false;
    return std.mem.eql(
        u8,
        resolved.value.string_v.slice(resolved.source_pool),
        rhs_literal,
    );
}

pub fn variable_path_literal_string_not_equal_string_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    literal: []const u8,
    rhs_literal: []const u8,
) Error!bool {
    return !try variable_path_literal_string_equal_string_bool(
        context,
        index,
        keys,
        literal,
        rhs_literal,
    );
}

pub fn variable_path_member_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    element: Value,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const set_value = try resolve_path(context, index, keys, &source_pool);
    return set_member_cross_pool(
        set_value,
        source_pool,
        element,
        context.eval_pool,
    );
}

pub fn variable_path_not_member_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    element: Value,
) Error!bool {
    return !try variable_path_member_bool(
        context,
        index,
        keys,
        element,
    );
}

pub fn variable_path_literal_string_member_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    literal: []const u8,
    element: Value,
) Error!bool {
    const resolved = try resolve_path_literal_string(
        context,
        index,
        keys,
        literal,
    );
    return set_member_cross_pool(
        resolved.value,
        resolved.source_pool,
        element,
        context.eval_pool,
    );
}

pub fn variable_path_literal_string_not_member_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    literal: []const u8,
    element: Value,
) Error!bool {
    return !try variable_path_literal_string_member_bool(
        context,
        index,
        keys,
        literal,
        element,
    );
}

pub fn variable_path_field_equal_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
    rhs: Value,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    if (value != .record_v) return Error.TypeError;
    const field_value = value.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    return Value.eql_cross_pool(
        field_value,
        source_pool,
        rhs,
        context.eval_pool,
    );
}

fn domain_contains_string_literal(
    context: *CallContext,
    value: Value,
    source_pool: *const ValuePool,
    literal: []const u8,
) Error!bool {
    return switch (value) {
        .generated_operator_v => |operator_value| blk: {
            if (operator_value.arity != 0 or source_pool != context.eval_pool) {
                return Error.TypeError;
            }
            break :blk try domain_contains_string_literal(
                context,
                try call(context, value, &.{}),
                context.eval_pool,
                literal,
            );
        },
        .function_v => |function| blk: {
            for (function.domain.items(source_pool)) |key| {
                if (key == .string_v and std.mem.eql(
                    u8,
                    key.string_v.slice(source_pool),
                    literal,
                )) break :blk true;
            }
            break :blk false;
        },
        .tuple_v => false,
        .record_v => |record_value| record_value.lookup(
            source_pool,
            literal,
        ) != null,
        else => Error.TypeError,
    };
}

fn domain_member_cross_pool(
    context: *CallContext,
    value: Value,
    source_pool: *const ValuePool,
    element: Value,
    element_pool: *const ValuePool,
) Error!bool {
    return switch (value) {
        .generated_operator_v => |operator_value| blk: {
            if (operator_value.arity != 0 or source_pool != context.eval_pool) {
                return Error.TypeError;
            }
            break :blk try domain_member_cross_pool(
                context,
                try call(context, value, &.{}),
                context.eval_pool,
                element,
                element_pool,
            );
        },
        .function_v => |function| set_member_cross_pool(
            .{ .set_v = function.domain },
            source_pool,
            element,
            element_pool,
        ),
        .tuple_v => |tuple_value| blk: {
            const index = element.as_int() orelse break :blk false;
            break :blk index >= 1 and index <= tuple_value.len;
        },
        .record_v => |record_value| blk: {
            if (element != .string_v) break :blk false;
            break :blk record_value.lookup(
                source_pool,
                element.string_v.slice(element_pool),
            ) != null;
        },
        else => Error.TypeError,
    };
}

pub fn resolve_variable_path(
    context: *CallContext,
    index: u32,
    keys: []const Value,
) Error!ResolvedPath {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    return .{ .value = value, .source_pool = source_pool };
}

pub fn resolved_path_field(
    context: *CallContext,
    resolved: ResolvedPath,
    field_name: []const u8,
) Error!Value {
    if (resolved.value != .record_v) return Error.TypeError;
    const field_value = resolved.value.record_v.lookup(
        resolved.source_pool,
        field_name,
    ) orelse return Error.UndefinedSymbol;
    return field_value.clone(resolved.source_pool, context.eval_pool);
}

pub fn resolved_path_field_domain_member_bool(
    context: *CallContext,
    resolved: ResolvedPath,
    field_name: []const u8,
    element: Value,
) Error!bool {
    if (resolved.value != .record_v) return Error.TypeError;
    const field_value = resolved.value.record_v.lookup(
        resolved.source_pool,
        field_name,
    ) orelse return Error.UndefinedSymbol;
    return domain_member_cross_pool(
        context,
        field_value,
        resolved.source_pool,
        element,
        context.eval_pool,
    );
}

pub fn resolved_path_field_domain_not_member_bool(
    context: *CallContext,
    resolved: ResolvedPath,
    field_name: []const u8,
    element: Value,
) Error!bool {
    return !try resolved_path_field_domain_member_bool(
        context,
        resolved,
        field_name,
        element,
    );
}

pub fn variable_path_domain_member_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    element: Value,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    return domain_member_cross_pool(
        context,
        value,
        source_pool,
        element,
        context.eval_pool,
    );
}

pub fn variable_path_domain_not_member_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    element: Value,
) Error!bool {
    return !try variable_path_domain_member_bool(
        context,
        index,
        keys,
        element,
    );
}

pub fn variable_path_field_domain_member_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
    element: Value,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    if (value != .record_v) return Error.TypeError;
    const field_value = value.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    return domain_member_cross_pool(
        context,
        field_value,
        source_pool,
        element,
        context.eval_pool,
    );
}

pub fn variable_path_field_domain_not_member_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
    element: Value,
) Error!bool {
    return !try variable_path_field_domain_member_bool(
        context,
        index,
        keys,
        field_name,
        element,
    );
}

pub fn variable_path_domain_literal_member_field_argument_equal_bool(
    context: *CallContext,
    operator_args: []const Value,
    index: u32,
    keys: []const Value,
    domain_literal: []const u8,
    field_name: []const u8,
    rhs_argument: u8,
) Error!bool {
    std.debug.assert(rhs_argument < operator_args.len);
    if (rhs_argument >= operator_args.len) return Error.TypeError;

    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    if (!try domain_contains_string_literal(
        context,
        value,
        source_pool,
        domain_literal,
    )) return false;

    if (value != .record_v) return Error.TypeError;
    const field_value = value.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    const rhs = try force(context, operator_args[rhs_argument]);
    return Value.eql_cross_pool(
        field_value,
        source_pool,
        rhs,
        context.eval_pool,
    );
}

pub fn resolved_path_domain_literal_member_field_argument_equal_bool(
    context: *CallContext,
    operator_args: []const Value,
    resolved: ResolvedPath,
    domain_literal: []const u8,
    field_name: []const u8,
    rhs_argument: u8,
) Error!bool {
    std.debug.assert(rhs_argument < operator_args.len);
    if (rhs_argument >= operator_args.len) return Error.TypeError;

    if (!try domain_contains_string_literal(
        context,
        resolved.value,
        resolved.source_pool,
        domain_literal,
    )) return false;

    if (resolved.value != .record_v) return Error.TypeError;
    const field_value = resolved.value.record_v.lookup(
        resolved.source_pool,
        field_name,
    ) orelse return Error.UndefinedSymbol;
    const rhs = try force(context, operator_args[rhs_argument]);
    return Value.eql_cross_pool(
        field_value,
        resolved.source_pool,
        rhs,
        context.eval_pool,
    );
}

pub fn variable_path_field(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
) Error!Value {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    if (value != .record_v) return Error.TypeError;
    const field_value = value.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    return field_value.clone(source_pool, context.eval_pool);
}

pub fn variable_path_field_int_compare_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
    other: Value,
    op: CompareOp,
    path_left: bool,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    if (value != .record_v) return Error.TypeError;
    const field_value = value.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    const path_int = field_value.as_int() orelse return Error.TypeError;
    const other_int = other.as_int() orelse return Error.TypeError;
    return if (path_left)
        compare_int(path_int, other_int, op)
    else
        compare_int(other_int, path_int, op);
}

pub fn variable_path_field_not_equal_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
    rhs: Value,
) Error!bool {
    return !try variable_path_field_equal_bool(
        context,
        index,
        keys,
        field_name,
        rhs,
    );
}

pub fn variable_path_field_boolean(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    if (value != .record_v) return Error.TypeError;
    const field_value = value.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    if (field_value != .bool_v) return Error.TypeError;
    return field_value.bool_v;
}

pub fn variable_path_field_member_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
    set_value: Value,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    if (value != .record_v) return Error.TypeError;
    const field_value = value.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    return try member_cross_pool(context, set_value, field_value, source_pool);
}

pub fn variable_path_sequence_head_field_equal_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
    rhs: Value,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    const head = try sequence_head_cross_pool(value, source_pool);
    if (head != .record_v) return Error.TypeError;
    const field_value = head.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    return Value.eql_cross_pool(
        field_value,
        source_pool,
        rhs,
        context.eval_pool,
    );
}

pub fn variable_path_sequence_head_field(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
) Error!Value {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    const head = try sequence_head_cross_pool(value, source_pool);
    if (head != .record_v) return Error.TypeError;
    const field_value = head.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    return field_value.clone(source_pool, context.eval_pool);
}

pub fn variable_path_sequence_head_field_boolean(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    const head = try sequence_head_cross_pool(value, source_pool);
    if (head != .record_v) return Error.TypeError;
    const field_value = head.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    if (field_value != .bool_v) return Error.TypeError;
    return field_value.bool_v;
}

pub fn variable_path_sequence_head_field_member_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
    set_value: Value,
) Error!bool {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    const head = try sequence_head_cross_pool(value, source_pool);
    if (head != .record_v) return Error.TypeError;
    const field_value = head.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    return try member_cross_pool(context, set_value, field_value, source_pool);
}

fn member_cross_pool(
    context: *CallContext,
    set_value: Value,
    value: Value,
    value_pool: *const ValuePool,
) Error!bool {
    if (!set_value.is_set_like()) return Error.TypeError;
    if (set_value == .power_set_v) {
        if (!value.is_set_like()) return false;
        return subset_cross_pool(
            context,
            value,
            value_pool,
            set_value.power_set_v.set(context.eval_pool),
        );
    }
    if (set_value != .set_v) {
        return set_value.member_cross_pool(
            context.eval_pool,
            value,
            value_pool,
        );
    }
    const items = set_value.set_v.items(context.eval_pool);
    if (dense_set_contains_probe(
        items,
        context.eval_pool,
        value,
        value_pool,
    )) |contains| {
        return contains;
    }
    for (items) |item| {
        if (Value.eql_cross_pool(
            item,
            context.eval_pool,
            value,
            value_pool,
        )) return true;
    }
    return false;
}

fn subset_cross_pool(
    context: *CallContext,
    left: Value,
    left_pool: *const ValuePool,
    right: Value,
) Error!bool {
    std.debug.assert(left.is_set_like());
    std.debug.assert(right.is_set_like());
    std.debug.assert(context.eval_pool.value_count <= context.eval_pool.value_cap);
    if (left_pool == context.eval_pool) {
        return subset_equal_bool(context, left, right);
    }
    return switch (left) {
        .set_v => |left_set| blk: {
            for (left_set.items(left_pool)) |item| {
                if (!right.member_cross_pool(
                    context.eval_pool,
                    item,
                    left_pool,
                )) break :blk false;
            }
            break :blk true;
        },
        .range_v => |left_range| blk: {
            if (left_range.hi < left_range.lo) break :blk true;
            var item = left_range.lo;
            while (true) {
                if (!right.member(
                    context.eval_pool,
                    .{ .int_v = item },
                )) break :blk false;
                if (item == left_range.hi) break;
                item += 1;
            }
            break :blk true;
        },
        else => subset_equal_bool(
            context,
            try left.clone(left_pool, context.eval_pool),
            right,
        ),
    };
}

fn set_member_cross_pool(
    set_value: Value,
    set_pool: *const ValuePool,
    element: Value,
    element_pool: *const ValuePool,
) Error!bool {
    if (!set_value.is_set_like()) return Error.TypeError;
    switch (set_value) {
        .set_v => |set_value_items| {
            const items = set_value_items.items(set_pool);
            if (dense_set_contains_probe(
                items,
                set_pool,
                element,
                element_pool,
            )) |contains| {
                return contains;
            }
            for (items) |item| {
                if (Value.eql_cross_pool(
                    item,
                    set_pool,
                    element,
                    element_pool,
                )) return true;
            }
            return false;
        },
        .range_v => |range_value| {
            const int = element.as_int() orelse return false;
            return int >= range_value.lo and int <= range_value.hi;
        },
        else => return Error.NotImplemented,
    }
}

fn equal_except_update_path(
    context: *CallContext,
    operator_args: []const Value,
    next: Value,
    next_pool: *const ValuePool,
    current: Value,
    current_pool: *const ValuePool,
    path: []const Value,
    path_index: usize,
    updater: OperatorFn,
) Error!bool {
    if (path_index == path.len) {
        const current_local = try localize_updater_input(
            context,
            current,
            current_pool,
        );
        const replacement = try call_bound(
            context,
            operator_args,
            &.{current_local},
            updater,
        );
        return Value.eql_cross_pool(
            next,
            next_pool,
            replacement,
            context.eval_pool,
        );
    }

    const key = path[path_index];
    switch (current) {
        .function_v => |current_function| {
            if (next != .function_v) return false;
            const next_function = next.function_v;
            if (current_function.len != next_function.len) return false;
            const current_keys = current_function.domain.items(current_pool);
            const current_entries = current_function.entries(current_pool);
            var matched = false;
            for (current_keys, current_entries) |current_key, current_entry| {
                const next_entry = function_lookup_cross_pool(
                    next_function,
                    next_pool,
                    current_key,
                    current_pool,
                ) orelse return false;
                if (Value.eql_cross_pool(
                    current_key,
                    current_pool,
                    key,
                    context.eval_pool,
                )) {
                    matched = true;
                    if (!try equal_except_update_path(
                        context,
                        operator_args,
                        next_entry,
                        next_pool,
                        current_entry,
                        current_pool,
                        path,
                        path_index + 1,
                        updater,
                    )) return false;
                } else if (!Value.eql_cross_pool(
                    next_entry,
                    next_pool,
                    current_entry,
                    current_pool,
                )) return false;
            }
            if (!matched) return false;
            return true;
        },
        .tuple_v => |current_tuple| {
            if (next != .tuple_v) return false;
            const next_tuple = next.tuple_v;
            if (current_tuple.len != next_tuple.len) return false;
            const raw_index = key.as_int() orelse return Error.TypeError;
            if (raw_index < 1 or raw_index > current_tuple.len) return false;
            const update_index: usize = @intCast(raw_index - 1);
            const current_items = current_tuple.items(current_pool);
            const next_items = next_tuple.items(next_pool);
            for (current_items, next_items, 0..) |current_item, next_item, item_index| {
                if (item_index == update_index) {
                    if (!try equal_except_update_path(
                        context,
                        operator_args,
                        next_item,
                        next_pool,
                        current_item,
                        current_pool,
                        path,
                        path_index + 1,
                        updater,
                    )) return false;
                } else if (!Value.eql_cross_pool(
                    next_item,
                    next_pool,
                    current_item,
                    current_pool,
                )) return false;
            }
            return true;
        },
        .record_v => |current_record| {
            if (next != .record_v or key != .string_v) return false;
            const next_record = next.record_v;
            if (current_record.len != next_record.len) return false;
            const key_name = key.string_v.slice(context.eval_pool);
            const current_fields = current_record.fields(current_pool);
            var matched = false;
            var field_index: u32 = 0;
            while (field_index < current_record.len) : (field_index += 1) {
                const field_name = current_fields[field_index * 2].string_v;
                const current_field = current_fields[field_index * 2 + 1];
                const next_field = next_record.lookup(
                    next_pool,
                    field_name.slice(current_pool),
                ) orelse return false;
                if (std.mem.eql(u8, field_name.slice(current_pool), key_name)) {
                    matched = true;
                    if (!try equal_except_update_path(
                        context,
                        operator_args,
                        next_field,
                        next_pool,
                        current_field,
                        current_pool,
                        path,
                        path_index + 1,
                        updater,
                    )) return false;
                } else if (!Value.eql_cross_pool(
                    next_field,
                    next_pool,
                    current_field,
                    current_pool,
                )) return false;
            }
            if (!matched) return false;
            return true;
        },
        else => return Error.TypeError,
    }
}

fn equal_double_except_update_path(
    context: *CallContext,
    operator_args: []const Value,
    next: Value,
    next_pool: *const ValuePool,
    current: Value,
    current_pool: *const ValuePool,
    path_a: []const Value,
    path_index_a: ?usize,
    updater_a: OperatorFn,
    path_b: []const Value,
    path_index_b: ?usize,
    updater_b: OperatorFn,
) Error!bool {
    const active_a = path_index_a != null;
    const active_b = path_index_b != null;
    if (!active_a and !active_b) {
        return Value.eql_cross_pool(next, next_pool, current, current_pool);
    }

    if (path_index_a) |index_a| {
        if (index_a == path_a.len) {
            if (active_b) return Error.NotImplemented;
            const current_local = try localize_updater_input(
                context,
                current,
                current_pool,
            );
            const replacement = try call_bound(
                context,
                operator_args,
                &.{current_local},
                updater_a,
            );
            return Value.eql_cross_pool(
                next,
                next_pool,
                replacement,
                context.eval_pool,
            );
        }
    }
    if (path_index_b) |index_b| {
        if (index_b == path_b.len) {
            if (active_a) return Error.NotImplemented;
            const current_local = try localize_updater_input(
                context,
                current,
                current_pool,
            );
            const replacement = try call_bound(
                context,
                operator_args,
                &.{current_local},
                updater_b,
            );
            return Value.eql_cross_pool(
                next,
                next_pool,
                replacement,
                context.eval_pool,
            );
        }
    }

    switch (current) {
        .function_v => |current_function| {
            if (next != .function_v) return false;
            const next_function = next.function_v;
            if (current_function.len != next_function.len) return false;
            const current_keys = current_function.domain.items(current_pool);
            const current_entries = current_function.entries(current_pool);
            var matched_a = path_index_a == null;
            var matched_b = path_index_b == null;
            for (current_keys, current_entries) |current_key, current_entry| {
                const next_entry = function_lookup_cross_pool(
                    next_function,
                    next_pool,
                    current_key,
                    current_pool,
                ) orelse return false;
                const child_a = if (path_index_a) |index_a|
                    if (Value.eql_cross_pool(
                        current_key,
                        current_pool,
                        path_a[index_a],
                        context.eval_pool,
                    )) blk: {
                        matched_a = true;
                        break :blk index_a + 1;
                    } else null
                else
                    null;
                const child_b = if (path_index_b) |index_b|
                    if (Value.eql_cross_pool(
                        current_key,
                        current_pool,
                        path_b[index_b],
                        context.eval_pool,
                    )) blk: {
                        matched_b = true;
                        break :blk index_b + 1;
                    } else null
                else
                    null;
                if (child_a != null or child_b != null) {
                    if (!try equal_double_except_update_path(
                        context,
                        operator_args,
                        next_entry,
                        next_pool,
                        current_entry,
                        current_pool,
                        path_a,
                        child_a,
                        updater_a,
                        path_b,
                        child_b,
                        updater_b,
                    )) return false;
                } else if (!Value.eql_cross_pool(
                    next_entry,
                    next_pool,
                    current_entry,
                    current_pool,
                )) return false;
            }
            if (!matched_a or !matched_b) return false;
            return true;
        },
        .tuple_v => |current_tuple| {
            if (next != .tuple_v) return false;
            const next_tuple = next.tuple_v;
            if (current_tuple.len != next_tuple.len) return false;
            const current_items = current_tuple.items(current_pool);
            const next_items = next_tuple.items(next_pool);
            var matched_a = path_index_a == null;
            var matched_b = path_index_b == null;
            for (current_items, next_items, 0..) |current_item, next_item, item_index| {
                const item_number: i64 = @intCast(item_index + 1);
                const child_a = if (path_index_a) |index_a| blk: {
                    const raw_index = path_a[index_a].as_int() orelse
                        return Error.TypeError;
                    break :blk if (raw_index == item_number) matched: {
                        matched_a = true;
                        break :matched index_a + 1;
                    } else null;
                } else null;
                const child_b = if (path_index_b) |index_b| blk: {
                    const raw_index = path_b[index_b].as_int() orelse
                        return Error.TypeError;
                    break :blk if (raw_index == item_number) matched: {
                        matched_b = true;
                        break :matched index_b + 1;
                    } else null;
                } else null;
                if (child_a != null or child_b != null) {
                    if (!try equal_double_except_update_path(
                        context,
                        operator_args,
                        next_item,
                        next_pool,
                        current_item,
                        current_pool,
                        path_a,
                        child_a,
                        updater_a,
                        path_b,
                        child_b,
                        updater_b,
                    )) return false;
                } else if (!Value.eql_cross_pool(
                    next_item,
                    next_pool,
                    current_item,
                    current_pool,
                )) return false;
            }
            if (!matched_a or !matched_b) return false;
            return true;
        },
        .record_v => |current_record| {
            if (next != .record_v) return false;
            const next_record = next.record_v;
            if (current_record.len != next_record.len) return false;
            const current_fields = current_record.fields(current_pool);
            var matched_a = path_index_a == null;
            var matched_b = path_index_b == null;
            var field_index: u32 = 0;
            while (field_index < current_record.len) : (field_index += 1) {
                const field_name = current_fields[field_index * 2].string_v;
                const field_name_bytes = field_name.slice(current_pool);
                const current_field = current_fields[field_index * 2 + 1];
                const next_field = next_record.lookup(
                    next_pool,
                    field_name_bytes,
                ) orelse return false;
                const child_a = if (path_index_a) |index_a| blk: {
                    if (path_a[index_a] != .string_v) return Error.TypeError;
                    break :blk if (std.mem.eql(
                        u8,
                        field_name_bytes,
                        path_a[index_a].string_v.slice(context.eval_pool),
                    )) matched: {
                        matched_a = true;
                        break :matched index_a + 1;
                    } else null;
                } else null;
                const child_b = if (path_index_b) |index_b| blk: {
                    if (path_b[index_b] != .string_v) return Error.TypeError;
                    break :blk if (std.mem.eql(
                        u8,
                        field_name_bytes,
                        path_b[index_b].string_v.slice(context.eval_pool),
                    )) matched: {
                        matched_b = true;
                        break :matched index_b + 1;
                    } else null;
                } else null;
                if (child_a != null or child_b != null) {
                    if (!try equal_double_except_update_path(
                        context,
                        operator_args,
                        next_field,
                        next_pool,
                        current_field,
                        current_pool,
                        path_a,
                        child_a,
                        updater_a,
                        path_b,
                        child_b,
                        updater_b,
                    )) return false;
                } else if (!Value.eql_cross_pool(
                    next_field,
                    next_pool,
                    current_field,
                    current_pool,
                )) return false;
            }
            if (!matched_a or !matched_b) return false;
            return true;
        },
        else => return Error.TypeError,
    }
}

fn equal_except_update_path_keys(
    context: *CallContext,
    operator_args: []const Value,
    next: Value,
    next_pool: *const ValuePool,
    current: Value,
    current_pool: *const ValuePool,
    path: []const PathKey,
    path_index: usize,
    updater: OperatorFn,
) Error!bool {
    std.debug.assert(path_index <= path.len);

    if (path_index == path.len) {
        const current_local = try localize_updater_input(
            context,
            current,
            current_pool,
        );
        const replacement = try call_bound(
            context,
            operator_args,
            &.{current_local},
            updater,
        );
        return Value.eql_cross_pool(
            next,
            next_pool,
            replacement,
            context.eval_pool,
        );
    }

    const key = path[path_index];
    switch (current) {
        .function_v => |current_function| {
            if (next != .function_v) return false;
            const next_function = next.function_v;
            if (current_function.len != next_function.len) return false;
            const current_keys = current_function.domain.items(current_pool);
            const current_entries = current_function.entries(current_pool);
            var matched = false;
            for (current_keys, current_entries) |current_key, current_entry| {
                const next_entry = function_lookup_cross_pool(
                    next_function,
                    next_pool,
                    current_key,
                    current_pool,
                ) orelse return false;
                if (path_key_matches_value(key, current_key, current_pool, context.eval_pool)) {
                    matched = true;
                    if (!try equal_except_update_path_keys(
                        context,
                        operator_args,
                        next_entry,
                        next_pool,
                        current_entry,
                        current_pool,
                        path,
                        path_index + 1,
                        updater,
                    )) return false;
                } else if (!Value.eql_cross_pool(
                    next_entry,
                    next_pool,
                    current_entry,
                    current_pool,
                )) return false;
            }
            if (!matched) return false;
            return true;
        },
        .tuple_v => |current_tuple| {
            if (next != .tuple_v) return false;
            const next_tuple = next.tuple_v;
            if (current_tuple.len != next_tuple.len) return false;
            const raw_index = path_key_int(key) orelse return Error.TypeError;
            if (raw_index < 1 or raw_index > current_tuple.len) return false;
            const update_index: usize = @intCast(raw_index - 1);
            const current_items = current_tuple.items(current_pool);
            const next_items = next_tuple.items(next_pool);
            for (current_items, next_items, 0..) |current_item, next_item, item_index| {
                if (item_index == update_index) {
                    if (!try equal_except_update_path_keys(
                        context,
                        operator_args,
                        next_item,
                        next_pool,
                        current_item,
                        current_pool,
                        path,
                        path_index + 1,
                        updater,
                    )) return false;
                } else if (!Value.eql_cross_pool(
                    next_item,
                    next_pool,
                    current_item,
                    current_pool,
                )) return false;
            }
            return true;
        },
        .record_v => |current_record| {
            if (next != .record_v) return false;
            const next_record = next.record_v;
            if (current_record.len != next_record.len) return false;
            const key_name = path_key_field(key, context.eval_pool) orelse
                return Error.TypeError;
            const current_fields = current_record.fields(current_pool);
            var matched = false;
            var field_index: u32 = 0;
            while (field_index < current_record.len) : (field_index += 1) {
                const field_name = current_fields[field_index * 2].string_v;
                const field_name_bytes = field_name.slice(current_pool);
                const current_field = current_fields[field_index * 2 + 1];
                const next_field = next_record.lookup(
                    next_pool,
                    field_name_bytes,
                ) orelse return false;
                if (std.mem.eql(u8, field_name_bytes, key_name)) {
                    matched = true;
                    if (!try equal_except_update_path_keys(
                        context,
                        operator_args,
                        next_field,
                        next_pool,
                        current_field,
                        current_pool,
                        path,
                        path_index + 1,
                        updater,
                    )) return false;
                } else if (!Value.eql_cross_pool(
                    next_field,
                    next_pool,
                    current_field,
                    current_pool,
                )) return false;
            }
            if (!matched) return false;
            return true;
        },
        else => return Error.TypeError,
    }
}

fn equal_double_except_update_path_keys(
    context: *CallContext,
    operator_args: []const Value,
    next: Value,
    next_pool: *const ValuePool,
    current: Value,
    current_pool: *const ValuePool,
    path_a: []const PathKey,
    path_index_a: ?usize,
    updater_a: OperatorFn,
    path_b: []const PathKey,
    path_index_b: ?usize,
    updater_b: OperatorFn,
) Error!bool {
    const active_a = path_index_a != null;
    const active_b = path_index_b != null;
    if (!active_a and !active_b) {
        return Value.eql_cross_pool(next, next_pool, current, current_pool);
    }

    if (path_index_a) |index_a| {
        std.debug.assert(index_a <= path_a.len);
        if (index_a == path_a.len) {
            if (active_b) return Error.NotImplemented;
            const current_local = try localize_updater_input(
                context,
                current,
                current_pool,
            );
            const replacement = try call_bound(
                context,
                operator_args,
                &.{current_local},
                updater_a,
            );
            return Value.eql_cross_pool(
                next,
                next_pool,
                replacement,
                context.eval_pool,
            );
        }
    }
    if (path_index_b) |index_b| {
        std.debug.assert(index_b <= path_b.len);
        if (index_b == path_b.len) {
            if (active_a) return Error.NotImplemented;
            const current_local = try localize_updater_input(
                context,
                current,
                current_pool,
            );
            const replacement = try call_bound(
                context,
                operator_args,
                &.{current_local},
                updater_b,
            );
            return Value.eql_cross_pool(
                next,
                next_pool,
                replacement,
                context.eval_pool,
            );
        }
    }

    switch (current) {
        .function_v => |current_function| {
            if (next != .function_v) return false;
            const next_function = next.function_v;
            if (current_function.len != next_function.len) return false;
            const current_keys = current_function.domain.items(current_pool);
            const current_entries = current_function.entries(current_pool);
            var matched_a = path_index_a == null;
            var matched_b = path_index_b == null;
            for (current_keys, current_entries) |current_key, current_entry| {
                const next_entry = function_lookup_cross_pool(
                    next_function,
                    next_pool,
                    current_key,
                    current_pool,
                ) orelse return false;
                const child_a = if (path_index_a) |index_a|
                    if (path_key_matches_value(
                        path_a[index_a],
                        current_key,
                        current_pool,
                        context.eval_pool,
                    )) blk: {
                        matched_a = true;
                        break :blk index_a + 1;
                    } else null
                else
                    null;
                const child_b = if (path_index_b) |index_b|
                    if (path_key_matches_value(
                        path_b[index_b],
                        current_key,
                        current_pool,
                        context.eval_pool,
                    )) blk: {
                        matched_b = true;
                        break :blk index_b + 1;
                    } else null
                else
                    null;
                if (child_a != null or child_b != null) {
                    if (!try equal_double_except_update_path_keys(
                        context,
                        operator_args,
                        next_entry,
                        next_pool,
                        current_entry,
                        current_pool,
                        path_a,
                        child_a,
                        updater_a,
                        path_b,
                        child_b,
                        updater_b,
                    )) return false;
                } else if (!Value.eql_cross_pool(
                    next_entry,
                    next_pool,
                    current_entry,
                    current_pool,
                )) return false;
            }
            if (!matched_a or !matched_b) return false;
            return true;
        },
        .tuple_v => |current_tuple| {
            if (next != .tuple_v) return false;
            const next_tuple = next.tuple_v;
            if (current_tuple.len != next_tuple.len) return false;
            const current_items = current_tuple.items(current_pool);
            const next_items = next_tuple.items(next_pool);
            var matched_a = path_index_a == null;
            var matched_b = path_index_b == null;
            for (current_items, next_items, 0..) |current_item, next_item, item_index| {
                const item_number: i64 = @intCast(item_index + 1);
                const child_a = if (path_index_a) |index_a| blk: {
                    const raw_index = path_key_int(path_a[index_a]) orelse
                        return Error.TypeError;
                    break :blk if (raw_index == item_number) matched: {
                        matched_a = true;
                        break :matched index_a + 1;
                    } else null;
                } else null;
                const child_b = if (path_index_b) |index_b| blk: {
                    const raw_index = path_key_int(path_b[index_b]) orelse
                        return Error.TypeError;
                    break :blk if (raw_index == item_number) matched: {
                        matched_b = true;
                        break :matched index_b + 1;
                    } else null;
                } else null;
                if (child_a != null or child_b != null) {
                    if (!try equal_double_except_update_path_keys(
                        context,
                        operator_args,
                        next_item,
                        next_pool,
                        current_item,
                        current_pool,
                        path_a,
                        child_a,
                        updater_a,
                        path_b,
                        child_b,
                        updater_b,
                    )) return false;
                } else if (!Value.eql_cross_pool(
                    next_item,
                    next_pool,
                    current_item,
                    current_pool,
                )) return false;
            }
            if (!matched_a or !matched_b) return false;
            return true;
        },
        .record_v => |current_record| {
            if (next != .record_v) return false;
            const next_record = next.record_v;
            if (current_record.len != next_record.len) return false;
            const current_fields = current_record.fields(current_pool);
            var matched_a = path_index_a == null;
            var matched_b = path_index_b == null;
            var field_index: u32 = 0;
            while (field_index < current_record.len) : (field_index += 1) {
                const field_name = current_fields[field_index * 2].string_v;
                const field_name_bytes = field_name.slice(current_pool);
                const current_field = current_fields[field_index * 2 + 1];
                const next_field = next_record.lookup(
                    next_pool,
                    field_name_bytes,
                ) orelse return false;
                const child_a = if (path_index_a) |index_a| blk: {
                    const key_name = path_key_field(
                        path_a[index_a],
                        context.eval_pool,
                    ) orelse return Error.TypeError;
                    break :blk if (std.mem.eql(u8, field_name_bytes, key_name)) matched: {
                        matched_a = true;
                        break :matched index_a + 1;
                    } else null;
                } else null;
                const child_b = if (path_index_b) |index_b| blk: {
                    const key_name = path_key_field(
                        path_b[index_b],
                        context.eval_pool,
                    ) orelse return Error.TypeError;
                    break :blk if (std.mem.eql(u8, field_name_bytes, key_name)) matched: {
                        matched_b = true;
                        break :matched index_b + 1;
                    } else null;
                } else null;
                if (child_a != null or child_b != null) {
                    if (!try equal_double_except_update_path_keys(
                        context,
                        operator_args,
                        next_field,
                        next_pool,
                        current_field,
                        current_pool,
                        path_a,
                        child_a,
                        updater_a,
                        path_b,
                        child_b,
                        updater_b,
                    )) return false;
                } else if (!Value.eql_cross_pool(
                    next_field,
                    next_pool,
                    current_field,
                    current_pool,
                )) return false;
            }
            if (!matched_a or !matched_b) return false;
            return true;
        },
        else => return Error.TypeError,
    }
}

fn localize_updater_input(
    context: *CallContext,
    value: Value,
    value_pool: *const ValuePool,
) Error!Value {
    if (value_pool == context.eval_pool) return value;
    return value.clone(value_pool, context.eval_pool);
}

fn path_key_matches_value(
    key: PathKey,
    value: Value,
    value_pool: *const ValuePool,
    key_pool: *const ValuePool,
) bool {
    return switch (key) {
        .value => |key_value| cross_pool_equal(
            value,
            value_pool,
            key_value,
            key_pool,
        ),
        .field => |field_name| value == .string_v and
            std.mem.eql(u8, value.string_v.slice(value_pool), field_name),
    };
}

fn path_key_int(key: PathKey) ?i64 {
    return switch (key) {
        .value => |value| value.as_int(),
        .field => null,
    };
}

fn path_key_field(key: PathKey, pool: *const ValuePool) ?[]const u8 {
    return switch (key) {
        .value => |value| if (value == .string_v)
            value.string_v.slice(pool)
        else
            null,
        .field => |field_name| field_name,
    };
}

fn function_lookup_cross_pool(
    function: Function,
    function_pool: *const ValuePool,
    key: Value,
    key_pool: *const ValuePool,
) ?Value {
    const keys = function.domain.items(function_pool);
    const entries = function.entries(function_pool);
    if (function_dense_entry_probe(
        keys,
        entries,
        key,
    )) |entry| {
        return entry;
    }
    for (keys, entries) |candidate, entry| {
        if (cross_pool_equal(
            candidate,
            function_pool,
            key,
            key_pool,
        )) return entry;
    }
    return null;
}

pub fn variable_path_sequence_head_field_not_equal_bool(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
    rhs: Value,
) Error!bool {
    return !try variable_path_sequence_head_field_equal_bool(
        context,
        index,
        keys,
        field_name,
        rhs,
    );
}

inline fn resolve_path(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    source_pool: **const ValuePool,
) Error!Value {
    var value = try resolve_variable(context, index, source_pool);
    for (keys) |key| {
        value = try apply_cross_pool(
            value,
            source_pool.*,
            key,
            context.eval_pool,
        );
    }
    return value;
}

fn resolve_variable(
    context: *CallContext,
    index: u32,
    source_pool: **const ValuePool,
) Error!Value {
    source_pool.* = context.eval_pool;

    if (context.read_primed) {
        if (index < context.partial_values.len and
            context.partial_mask & (@as(u64, 1) << @intCast(index)) != 0)
        {
            const value = context.partial_values[index];
            if (index < context.partial_value_pools.len) {
                source_pool.* = context.partial_value_pools[index] orelse
                    context.eval_pool;
            }
            return value;
        } else if (context.next_state) |next| {
            if (index >= next.values.len) return Error.TypeError;
            source_pool.* = next.value_pool(index, context.state_pool);
            return next.values[index];
        } else if (context.state) |current| {
            if (index >= current.values.len) return Error.TypeError;
            source_pool.* = current.value_pool(index, context.state_pool);
            return current.values[index];
        } else {
            return Error.TypeError;
        }
    } else if (context.state) |current| {
        if (index >= current.values.len) return Error.TypeError;
        source_pool.* = current.value_pool(index, context.state_pool);
        return current.values[index];
    } else {
        return current_variable(context, index);
    }
}

fn sequence_head_cross_pool(
    sequence: Value,
    sequence_pool: *const ValuePool,
) Error!Value {
    return switch (sequence) {
        .function_v => |function| function.apply(
            sequence_pool,
            .{ .int_v = 1 },
        ) orelse Error.IndexOutOfBounds,
        .tuple_v => |tuple_value| if (tuple_value.len == 0)
            Error.IndexOutOfBounds
        else
            tuple_value.items(sequence_pool)[0],
        .string_v => |string_value| if (string_value.len == 0)
            Error.IndexOutOfBounds
        else
            .{ .int_v = string_value.slice(sequence_pool)[0] },
        else => Error.TypeError,
    };
}

inline fn apply_cross_pool(
    function: Value,
    function_pool: *const ValuePool,
    key: Value,
    key_pool: *const ValuePool,
) Error!Value {
    return switch (function) {
        .function_v => |function_value| blk: {
            const domain_values =
                function_value.domain.items(function_pool);
            const entries = function_value.entries(function_pool);
            if (function_dense_entry_probe(
                domain_values,
                entries,
                key,
            )) |entry| {
                break :blk entry;
            }
            for (domain_values, entries) |candidate, entry| {
                if (cross_pool_equal(
                    candidate,
                    function_pool,
                    key,
                    key_pool,
                )) break :blk entry;
            }
            return Error.IndexOutOfBounds;
        },
        .tuple_v => |tuple_value| blk: {
            const tuple_index = key.as_int() orelse return Error.TypeError;
            if (tuple_index < 1 or tuple_index > tuple_value.len) {
                return Error.IndexOutOfBounds;
            }
            break :blk tuple_value.items(
                function_pool,
            )[@intCast(tuple_index - 1)];
        },
        .record_v => |record_value| blk: {
            if (key != .string_v) return Error.TypeError;
            const name = key.string_v.slice(key_pool);
            break :blk record_value.lookup(function_pool, name) orelse
                return Error.UndefinedSymbol;
        },
        else => Error.TypeError,
    };
}

inline fn apply_literal_string_cross_pool(
    function: Value,
    function_pool: *const ValuePool,
    key: []const u8,
) Error!Value {
    return switch (function) {
        .function_v => |function_value| blk: {
            const keys = function_value.domain.items(function_pool);
            const entries = function_value.entries(function_pool);
            for (keys, entries) |candidate, entry| {
                if (candidate == .string_v and std.mem.eql(
                    u8,
                    candidate.string_v.slice(function_pool),
                    key,
                )) break :blk entry;
            }
            return Error.IndexOutOfBounds;
        },
        .record_v => |record_value| record_value.lookup(
            function_pool,
            key,
        ) orelse Error.UndefinedSymbol,
        else => Error.TypeError,
    };
}

inline fn record_lookup_literal_cached(
    record_value: Record,
    pool: *const ValuePool,
    field_name: []const u8,
    cached_index: *?u32,
) ?Value {
    const fields = record_value.fields(pool);
    if (cached_index.*) |field_index| {
        if (field_index < record_value.len) {
            const offset = field_index * 2;
            const key = fields[offset];
            if (key == .string_v and std.mem.eql(
                u8,
                key.string_v.slice(pool),
                field_name,
            )) {
                var preceding_index: u32 = 0;
                while (preceding_index < field_index) : (preceding_index += 1) {
                    const preceding_key = fields[preceding_index * 2];
                    std.debug.assert(preceding_key != .string_v or
                        !std.mem.eql(
                            u8,
                            preceding_key.string_v.slice(pool),
                            field_name,
                        ));
                }
                return fields[offset + 1];
            }
        }
    }
    var field_index: u32 = 0;
    while (field_index < record_value.len) : (field_index += 1) {
        const offset = field_index * 2;
        const key = fields[offset];
        if (key != .string_v or !std.mem.eql(
            u8,
            key.string_v.slice(pool),
            field_name,
        )) continue;
        cached_index.* = field_index;
        return fields[offset + 1];
    }
    return null;
}

test "record field slot cache validates heterogeneous layouts" {
    const Arena = @import("arena.zig").Arena;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 32, 64);

    const first_offset = try pool.push_values(&.{
        .{ .string_v = try pool.push_string("other") },
        .{ .int_v = 1 },
        .{ .string_v = try pool.push_string("active") },
        .{ .bool_v = true },
    });
    const second_offset = try pool.push_values(&.{
        .{ .string_v = try pool.push_string("active") },
        .{ .bool_v = false },
        .{ .string_v = try pool.push_string("other") },
        .{ .int_v = 2 },
    });
    const first = Record{ .offset = first_offset, .len = 2 };
    const second = Record{ .offset = second_offset, .len = 2 };
    var cached_index: ?u32 = null;

    try std.testing.expectEqual(
        true,
        record_lookup_literal_cached(
            first,
            &pool,
            "active",
            &cached_index,
        ).?.bool_v,
    );
    try std.testing.expectEqual(@as(?u32, 1), cached_index);
    try std.testing.expectEqual(
        false,
        record_lookup_literal_cached(
            second,
            &pool,
            "active",
            &cached_index,
        ).?.bool_v,
    );
    try std.testing.expectEqual(@as(?u32, 0), cached_index);
    try std.testing.expectEqual(
        true,
        record_lookup_literal_cached(
            first,
            &pool,
            "active",
            &cached_index,
        ).?.bool_v,
    );
    try std.testing.expectEqual(@as(?u32, 1), cached_index);
}

fn function_dense_entry_probe(
    keys: []const Value,
    entries: []const Value,
    key: Value,
) ?Value {
    std.debug.assert(keys.len == entries.len);
    if (keys.len == 0) return null;
    const index = switch (key) {
        .int_v => |key_int| blk: {
            if (keys[0] != .int_v) return null;
            const delta = std.math.sub(i64, key_int, keys[0].int_v) catch
                return null;
            if (delta < 0) return null;
            break :blk @as(u64, @intCast(delta));
        },
        .model_v => |key_model| blk: {
            if (keys[0] != .model_v or key_model < keys[0].model_v) {
                return null;
            }
            break :blk @as(u64, key_model - keys[0].model_v);
        },
        else => return null,
    };
    if (index >= keys.len) return null;
    const index_u: usize = @intCast(index);
    switch (key) {
        .int_v => |key_int| if (keys[index_u] != .int_v or
            keys[index_u].int_v != key_int) return null,
        .model_v => |key_model| if (keys[index_u] != .model_v or
            keys[index_u].model_v != key_model) return null,
        else => unreachable,
    }
    return entries[index_u];
}

test "dense function probe rejects holes without cross-pool dispatch" {
    const entries = [_]Value{
        .{ .string_v = .{ .offset = 0, .len = 0 } },
        .{ .bool_v = true },
    };
    const dense_int_keys = [_]Value{
        .{ .int_v = 1 },
        .{ .int_v = 2 },
    };
    try std.testing.expectEqual(
        entries[1],
        function_dense_entry_probe(
            &dense_int_keys,
            &entries,
            .{ .int_v = 2 },
        ).?,
    );
    const sparse_int_keys = [_]Value{
        .{ .int_v = 1 },
        .{ .int_v = 3 },
    };
    try std.testing.expectEqual(
        @as(?Value, null),
        function_dense_entry_probe(
            &sparse_int_keys,
            &entries,
            .{ .int_v = 2 },
        ),
    );
    const dense_model_keys = [_]Value{
        .{ .model_v = 7 },
        .{ .model_v = 8 },
    };
    try std.testing.expectEqual(
        entries[1],
        function_dense_entry_probe(
            &dense_model_keys,
            &entries,
            .{ .model_v = 8 },
        ).?,
    );
}

fn dense_set_contains_probe(
    items: []const Value,
    item_pool: *const ValuePool,
    value: Value,
    value_pool: *const ValuePool,
) ?bool {
    if (items.len == 0) return false;
    const index = switch (value) {
        .int_v => |value_int| blk: {
            if (items[0] != .int_v) return null;
            const delta = std.math.sub(i64, value_int, items[0].int_v) catch
                return null;
            if (delta < 0) return null;
            break :blk @as(u64, @intCast(delta));
        },
        .model_v => |value_model| blk: {
            if (items[0] != .model_v) return null;
            if (value_model < items[0].model_v) return null;
            break :blk @as(u64, value_model - items[0].model_v);
        },
        else => return null,
    };
    if (index >= items.len) return null;
    const index_u: usize = @intCast(index);
    if (!cross_pool_equal(items[index_u], item_pool, value, value_pool)) {
        return null;
    }
    return true;
}

fn cross_pool_equal(
    left: Value,
    left_pool: *const ValuePool,
    right: Value,
    right_pool: *const ValuePool,
) bool {
    if (left.tag() != right.tag()) return false;
    switch (left) {
        .bool_v => return left.bool_v == right.bool_v,
        .int_v => return left.int_v == right.int_v,
        .model_v => return left.model_v == right.model_v,
        .string_v => {
            if (left_pool == right_pool and
                left.string_v.offset == right.string_v.offset and
                left.string_v.len == right.string_v.len)
            {
                return true;
            }
            return std.mem.eql(
                u8,
                left.string_v.slice(left_pool),
                right.string_v.slice(right_pool),
            );
        },
        else => {},
    }
    return Value.eql_cross_pool(left, left_pool, right, right_pool);
}

pub fn tuple(context: *CallContext, items: []const Value) Error!Value {
    const source_offset = pool_slice_offset(context.eval_pool, items);
    const values = try context.eval_pool.alloc_values(
        @intCast(items.len),
    );
    const source = if (source_offset) |offset|
        context.eval_pool.values[offset..][0..items.len]
    else
        items;
    @memcpy(values, source);
    return .{ .tuple_v = .{
        .offset = value_offset(context.eval_pool, values.ptr),
        .len = @intCast(values.len),
    } };
}

pub fn record(context: *CallContext, fields: []const Value) Error!Value {
    if (fields.len % 2 != 0) return Error.TypeError;
    const source_offset = pool_slice_offset(context.eval_pool, fields);
    const values = try context.eval_pool.alloc_values(
        @intCast(fields.len),
    );
    const source = if (source_offset) |offset|
        context.eval_pool.values[offset..][0..fields.len]
    else
        fields;
    @memcpy(values, source);
    return .{ .record_v = .{
        .offset = value_offset(context.eval_pool, values.ptr),
        .len = @intCast(values.len / 2),
    } };
}

pub fn record_static(
    context: *CallContext,
    field_names: []const []const u8,
    field_values: []const Value,
) Error!Value {
    if (field_names.len != field_values.len) return Error.TypeError;
    const values = try context.eval_pool.alloc_values(
        @intCast(field_names.len * 2),
    );
    for (field_names, field_values, 0..) |field_name, field_value, index| {
        values[index * 2] = .{
            .string_v = try context.eval_pool.push_string(field_name),
        };
        values[index * 2 + 1] = field_value;
    }
    return .{ .record_v = .{
        .offset = value_offset(context.eval_pool, values.ptr),
        .len = @intCast(field_names.len),
    } };
}

pub fn set(context: *CallContext, items: []const Value) Error!Value {
    const source_offset = pool_slice_offset(context.eval_pool, items);
    const values = try context.eval_pool.alloc_values(
        @intCast(items.len),
    );
    const source = if (source_offset) |offset|
        context.eval_pool.values[offset..][0..items.len]
    else
        items;
    var count: u32 = 0;
    for (source) |candidate| {
        var duplicate = false;
        for (values[0..count]) |existing| {
            if (existing.eql(candidate, context.eval_pool)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            values[count] = candidate;
            count += 1;
        }
    }
    return .{ .set_v = .{
        .offset = value_offset(context.eval_pool, values.ptr),
        .len = count,
    } };
}

fn set_cross_pool(
    context: *CallContext,
    items: []const Value,
    item_pool: *const ValuePool,
) Error!Value {
    if (item_pool == context.eval_pool) return set(context, items);

    const values = try context.eval_pool.alloc_values(
        @intCast(items.len),
    );
    var count: u32 = 0;
    for (items) |candidate| {
        var duplicate = false;
        for (values[0..count]) |existing| {
            if (Value.eql_cross_pool(
                existing,
                context.eval_pool,
                candidate,
                item_pool,
            )) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            values[count] = try candidate.clone(
                item_pool,
                context.eval_pool,
            );
            count += 1;
        }
    }
    return .{ .set_v = .{
        .offset = value_offset(context.eval_pool, values.ptr),
        .len = count,
    } };
}

pub fn set_union(
    context: *CallContext,
    left: Value,
    right: Value,
) Error!Value {
    if (requires_lazy_set_operation(context, left, 0) or
        requires_lazy_set_operation(context, right, 0))
    {
        return binary_set(context, left, right, .cup);
    }
    return materialize_binary_set(context, left, right, .cup);
}

pub fn set_intersection(
    context: *CallContext,
    left: Value,
    right: Value,
) Error!Value {
    if (requires_lazy_set_operation(context, left, 0) or
        requires_lazy_set_operation(context, right, 0))
    {
        return binary_set(context, left, right, .cap);
    }
    return materialize_binary_set(context, left, right, .cap);
}

pub fn set_difference(
    context: *CallContext,
    left: Value,
    right: Value,
) Error!Value {
    if (requires_lazy_set_operation(context, left, 0) or
        requires_lazy_set_operation(context, right, 0))
    {
        return binary_set(context, left, right, .diff);
    }
    return materialize_binary_set(context, left, right, .diff);
}

fn requires_lazy_set_operation(
    context: *const CallContext,
    value: Value,
    depth: u8,
) bool {
    if (depth >= 64) return true;
    return switch (value) {
        .range_v => |range_value| blk: {
            if (range_value.hi < range_value.lo) break :blk false;
            const length = @as(i128, range_value.hi) -
                @as(i128, range_value.lo) + 1;
            break :blk length > std.math.maxInt(u32);
        },
        // Record-set unions are usually consumed by membership predicates.
        // Keeping their constructors symbolic avoids enumerating every record;
        // iteration and cardinality materialize the union on demand.
        .record_set_v => true,
        .tuple_set_v => |tuple_set_value| blk: {
            for (tuple_set_value.sets(context.eval_pool)) |component| {
                if (requires_lazy_set_operation(
                    context,
                    component,
                    depth + 1,
                )) break :blk true;
            }
            break :blk false;
        },
        .function_set_v => |function_set_value| blk: {
            break :blk requires_lazy_set_operation(
                context,
                function_set_value.domain(context.eval_pool),
                depth + 1,
            ) or requires_lazy_set_operation(
                context,
                function_set_value.codomain(context.eval_pool),
                depth + 1,
            );
        },
        // Seq(S) contains sequences of arbitrary finite length and cannot be
        // enumerated as one finite set, even when S itself is finite.
        .seq_set_v => true,
        .power_set_v => |power_set_value| requires_lazy_set_operation(
            context,
            power_set_value.set(context.eval_pool),
            depth + 1,
        ),
        .cup_v, .cap_v, .diff_v => |binary| blk: {
            break :blk requires_lazy_set_operation(
                context,
                binary.left(context.eval_pool),
                depth + 1,
            ) or requires_lazy_set_operation(
                context,
                binary.right(context.eval_pool),
                depth + 1,
            );
        },
        .union_v => |union_value| blk: {
            const outer = union_value.set(context.eval_pool);
            if (requires_lazy_set_operation(
                context,
                outer,
                depth + 1,
            )) break :blk true;
            if (outer != .set_v) break :blk false;
            for (outer.set_v.items(context.eval_pool)) |nested| {
                if (nested.is_set_like() and requires_lazy_set_operation(
                    context,
                    nested,
                    depth + 1,
                )) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn sequence_set(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 1 or !args[0].is_set_like()) return Error.TypeError;
    return .{ .seq_set_v = .{
        .element_set_offset = try context.eval_pool.push_value(args[0]),
    } };
}

pub fn cartesian_product(
    context: *CallContext,
    left_value: Value,
    right_value: Value,
) Error!Value {
    const left = try materialize_iterable(context, left_value);
    const right = try materialize_iterable(context, right_value);
    std.debug.assert(left == .set_v);
    std.debug.assert(right == .set_v);

    const left_items = left.set_v.items(context.eval_pool);
    const right_items = right.set_v.items(context.eval_pool);
    const tuple_width: u32 = if (left_items.len > 0 and
        left_items[0] == .tuple_v)
        left_items[0].tuple_v.len + 1
    else
        2;
    const count = std.math.mul(
        u32,
        left.set_v.len,
        right.set_v.len,
    ) catch return Error.OutOfMemory;
    const result = try context.eval_pool.alloc_values(count);
    const result_offset = value_offset(context.eval_pool, result.ptr);
    var result_index: u32 = 0;
    for (left_items) |left_item| {
        for (right_items) |right_item| {
            const tuple_items = try context.eval_pool.alloc_values(
                tuple_width,
            );
            if (left_item == .tuple_v) {
                const prefix = left_item.tuple_v.items(context.eval_pool);
                @memcpy(tuple_items[0..prefix.len], prefix);
                tuple_items[prefix.len] = right_item;
            } else {
                tuple_items[0] = left_item;
                tuple_items[1] = right_item;
            }
            context.eval_pool.values[result_offset + result_index] =
                .{ .tuple_v = .{
                    .offset = value_offset(
                        context.eval_pool,
                        tuple_items.ptr,
                    ),
                    .len = tuple_width,
                } };
            result_index += 1;
        }
    }
    std.debug.assert(result_index == count);
    return .{ .set_v = .{
        .offset = result_offset,
        .len = count,
    } };
}

pub fn cardinality(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const iterable = try materialize_iterable(context, args[0]);
    return .{ .int_v = @intCast(try iterable_count(iterable)) };
}

pub fn constant_cardinality_at(
    context: *CallContext,
    constant_index: u32,
) Error!Value {
    std.debug.assert(context.state_pool.value_count <= context.state_pool.value_cap);
    if (constant_index >= context.constant_slots.len) {
        return Error.UndefinedSymbol;
    }
    const value = context.constant_slots[constant_index] orelse
        return Error.UndefinedSymbol;
    return .{ .int_v = @intCast(try iterable_count(value)) };
}

pub fn set_to_bag(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const set_value = try materialize_iterable(context, args[0]);
    if (set_value != .set_v) return Error.TypeError;
    const entries = try context.eval_pool.alloc_values(set_value.set_v.len);
    @memset(entries, Value{ .int_v = 1 });
    return .{ .function_v = .{
        .domain = set_value.set_v,
        .offset = value_offset(context.eval_pool, entries.ptr),
        .len = set_value.set_v.len,
    } };
}

pub fn bag_cup(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 2) return Error.TypeError;
    const left = try bag_function(context, args[0]);
    const right = try bag_function(context, args[1]);
    const left_keys = left.domain.items(context.eval_pool);
    const left_entries = left.entries(context.eval_pool);
    const right_keys = right.domain.items(context.eval_pool);
    const right_entries = right.entries(context.eval_pool);

    var new_key_count: u32 = 0;
    for (right_keys) |key| {
        if (left.apply(context.eval_pool, key) == null) new_key_count += 1;
    }
    const count = left.len + new_key_count;
    const keys = try context.eval_pool.alloc_values(count);
    const entries = try context.eval_pool.alloc_values(count);
    @memcpy(keys[0..left.len], left_keys);
    @memcpy(entries[0..left.len], left_entries);

    var out: u32 = left.len;
    for (right_keys, right_entries) |key, right_value| {
        const right_count = right_value.as_int() orelse return Error.TypeError;
        if (left.apply(context.eval_pool, key)) |left_value| {
            const left_count = left_value.as_int() orelse return Error.TypeError;
            var index: u32 = 0;
            while (index < left.len) : (index += 1) {
                if (keys[index].eql(key, context.eval_pool)) {
                    entries[index] = .{ .int_v = left_count + right_count };
                    break;
                }
            }
            std.debug.assert(index < left.len);
        } else {
            keys[out] = key;
            entries[out] = .{ .int_v = right_count };
            out += 1;
        }
    }
    std.debug.assert(out == count);
    return .{ .function_v = .{
        .domain = .{
            .offset = value_offset(context.eval_pool, keys.ptr),
            .len = count,
        },
        .offset = value_offset(context.eval_pool, entries.ptr),
        .len = count,
    } };
}

pub fn bag_difference(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 2) return Error.TypeError;
    const left = try bag_function(context, args[0]);
    const right = try bag_function(context, args[1]);
    const left_keys = left.domain.items(context.eval_pool);
    const left_entries = left.entries(context.eval_pool);

    var count: u32 = 0;
    for (left_keys, left_entries) |key, left_value| {
        const left_count = left_value.as_int() orelse return Error.TypeError;
        const right_count = if (right.apply(context.eval_pool, key)) |value|
            value.as_int() orelse return Error.TypeError
        else
            0;
        if (left_count > right_count) count += 1;
    }

    const keys = try context.eval_pool.alloc_values(count);
    const entries = try context.eval_pool.alloc_values(count);
    var out: u32 = 0;
    for (left_keys, left_entries) |key, left_value| {
        const left_count = left_value.as_int() orelse return Error.TypeError;
        const right_count = if (right.apply(context.eval_pool, key)) |value|
            value.as_int() orelse return Error.TypeError
        else
            0;
        if (left_count > right_count) {
            keys[out] = key;
            entries[out] = .{ .int_v = left_count - right_count };
            out += 1;
        }
    }
    std.debug.assert(out == count);
    return .{ .function_v = .{
        .domain = .{
            .offset = value_offset(context.eval_pool, keys.ptr),
            .len = count,
        },
        .offset = value_offset(context.eval_pool, entries.ptr),
        .len = count,
    } };
}

fn bag_function(context: *CallContext, value: Value) Error!Function {
    return switch (value) {
        .function_v => |function| function,
        .tuple_v => |tuple_value| blk: {
            if (tuple_value.len != 0) return Error.TypeError;
            const offset = context.eval_pool.value_count;
            break :blk .{
                .domain = .{ .offset = offset, .len = 0 },
                .offset = offset,
                .len = 0,
            };
        },
        else => Error.TypeError,
    };
}

pub fn sequence_len(
    _: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return switch (args[0]) {
        .function_v => |function| .{ .int_v = @intCast(function.len) },
        .tuple_v => |tuple_value| .{ .int_v = @intCast(tuple_value.len) },
        .string_v => |string_value| .{ .int_v = @intCast(string_value.len) },
        else => Error.TypeError,
    };
}

pub fn variable_path_sequence_len(
    context: *CallContext,
    index: u32,
    keys: []const Value,
) Error!Value {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    return switch (value) {
        .function_v => |function| .{ .int_v = @intCast(function.len) },
        .tuple_v => |tuple_value| .{ .int_v = @intCast(tuple_value.len) },
        .string_v => |string_value| .{ .int_v = @intCast(string_value.len) },
        else => Error.TypeError,
    };
}

pub fn sequence_head(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return switch (args[0]) {
        .function_v => |function| function.apply(
            context.eval_pool,
            .{ .int_v = 1 },
        ) orelse Error.IndexOutOfBounds,
        .tuple_v => |tuple_value| if (tuple_value.len == 0)
            Error.IndexOutOfBounds
        else
            tuple_value.items(context.eval_pool)[0],
        .string_v => |string_value| if (string_value.len == 0)
            Error.IndexOutOfBounds
        else
            .{ .int_v = string_value.slice(context.eval_pool)[0] },
        else => Error.TypeError,
    };
}

pub fn sequence_tail(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const source = switch (args[0]) {
        .function_v => |function| function.entries(context.eval_pool),
        .tuple_v => |tuple_value| tuple_value.items(context.eval_pool),
        else => return Error.TypeError,
    };
    if (source.len == 0) return Error.IndexOutOfBounds;
    return tuple(context, source[1..]);
}

pub fn sequence_append(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 2) return Error.TypeError;
    const source = switch (args[0]) {
        .function_v => |function| function.entries(context.eval_pool),
        .tuple_v => |tuple_value| tuple_value.items(context.eval_pool),
        else => return Error.TypeError,
    };
    const source_offset = pool_slice_offset(context.eval_pool, source);
    const result = try context.eval_pool.alloc_values(
        @intCast(source.len + 1),
    );
    const source_after_growth = if (source_offset) |offset|
        context.eval_pool.values[offset..][0..source.len]
    else
        source;
    @memcpy(result[0..source.len], source_after_growth);
    result[source.len] = args[1];
    return .{ .tuple_v = .{
        .offset = value_offset(context.eval_pool, result.ptr),
        .len = @intCast(result.len),
    } };
}

pub fn sequence_subseq(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 3) return Error.TypeError;
    const lo = args[1].as_int() orelse return Error.TypeError;
    const hi = args[2].as_int() orelse return Error.TypeError;
    if (lo < 1) return Error.IndexOutOfBounds;
    if (hi < lo) {
        return tuple(context, &.{});
    }

    const result_len_i64 = hi - lo + 1;
    if (result_len_i64 > std.math.maxInt(u32)) return Error.OutOfMemory;
    const result_len: u32 = @intCast(result_len_i64);
    return switch (args[0]) {
        .function_v => |function| {
            if (hi > function.len) return Error.IndexOutOfBounds;
            const result = try context.eval_pool.alloc_values(result_len);
            const result_offset = value_offset(context.eval_pool, result.ptr);
            for (result, 0..) |*slot, index| {
                const source_index: usize = @intCast(lo - 1 + @as(i64, @intCast(index)));
                slot.* = context.eval_pool.values[function.offset + source_index];
            }
            return .{ .tuple_v = .{
                .offset = result_offset,
                .len = result_len,
            } };
        },
        .tuple_v => |tuple_value| {
            if (hi > tuple_value.len) return Error.IndexOutOfBounds;
            const source = tuple_value.items(context.eval_pool);
            const result = try context.eval_pool.alloc_values(result_len);
            @memcpy(result, source[@intCast(lo - 1)..@intCast(hi)]);
            return .{ .tuple_v = .{
                .offset = value_offset(context.eval_pool, result.ptr),
                .len = result_len,
            } };
        },
        else => Error.TypeError,
    };
}

pub fn sequence_concat(
    context: *CallContext,
    left: Value,
    right: Value,
) Error!Value {
    const left_len: u32 = switch (left) {
        .function_v => |function| function.len,
        .tuple_v => |tuple_value| tuple_value.len,
        else => return Error.TypeError,
    };
    const right_len: u32 = switch (right) {
        .function_v => |function| function.len,
        .tuple_v => |tuple_value| tuple_value.len,
        else => return Error.TypeError,
    };
    const result_len = std.math.add(u32, left_len, right_len) catch
        return Error.OutOfMemory;
    try context.eval_pool.ensure_value_capacity(result_len);
    const result = try context.eval_pool.alloc_values(result_len);
    const result_offset = value_offset(context.eval_pool, result.ptr);
    var index: u32 = 0;
    while (index < left_len) : (index += 1) {
        context.eval_pool.values[result_offset + index] =
            sequence_item(context.eval_pool, left, index) orelse
            return Error.TypeError;
    }
    index = 0;
    while (index < right_len) : (index += 1) {
        context.eval_pool.values[result_offset + left_len + index] =
            sequence_item(context.eval_pool, right, index) orelse
            return Error.TypeError;
    }
    return .{ .tuple_v = .{
        .offset = result_offset,
        .len = result_len,
    } };
}

pub fn record_to(
    context: *CallContext,
    key: Value,
    value_v: Value,
) Error!Value {
    try context.eval_pool.ensure_value_capacity(2);
    const key_values = try context.eval_pool.alloc_values(1);
    key_values[0] = key;
    const key_offset = value_offset(context.eval_pool, key_values.ptr);
    const entries = try context.eval_pool.alloc_values(1);
    entries[0] = value_v;
    return .{ .function_v = .{
        .domain = .{
            .offset = key_offset,
            .len = 1,
        },
        .offset = value_offset(context.eval_pool, entries.ptr),
        .len = 1,
    } };
}

pub fn override(
    context: *CallContext,
    left: Value,
    right: Value,
) Error!Value {
    if (left == .record_v and right == .record_v) {
        const left_record = left.record_v;
        const right_record = right.record_v;
        const capacity = left_record.len + right_record.len;
        try context.eval_pool.ensure_value_capacity(
            @as(u64, capacity) * 2,
        );
        const fields = try context.eval_pool.alloc_values(capacity * 2);
        const fields_offset = value_offset(context.eval_pool, fields.ptr);
        var count: u32 = 0;
        var left_index: u32 = 0;
        while (left_index < left_record.len) : (left_index += 1) {
            const left_fields = left_record.fields(context.eval_pool);
            const left_name = left_fields[left_index * 2].string_v;
            var overridden = false;
            var right_index: u32 = 0;
            while (right_index < right_record.len) : (right_index += 1) {
                const right_fields = right_record.fields(context.eval_pool);
                if (left_name.eql(
                    right_fields[right_index * 2].string_v,
                    context.eval_pool,
                )) {
                    overridden = true;
                    break;
                }
            }
            if (!overridden) {
                const current_left = left_record.fields(context.eval_pool);
                context.eval_pool.values[fields_offset + count * 2] =
                    current_left[left_index * 2];
                context.eval_pool.values[fields_offset + count * 2 + 1] =
                    current_left[left_index * 2 + 1];
                count += 1;
            }
        }
        const right_fields = right_record.fields(context.eval_pool);
        @memcpy(
            context.eval_pool.values[fields_offset + count * 2 ..][0 .. right_record.len * 2],
            right_fields,
        );
        count += right_record.len;
        return .{ .record_v = .{
            .offset = fields_offset,
            .len = count,
        } };
    }

    const left_function = if (left == .function_v)
        left.function_v
    else
        return Error.TypeError;
    const right_function = if (right == .function_v)
        right.function_v
    else
        return Error.TypeError;
    const capacity = left_function.len + right_function.len;
    try context.eval_pool.ensure_value_capacity(
        @as(u64, capacity) * 2,
    );
    const keys = try context.eval_pool.alloc_values(capacity);
    const keys_offset = value_offset(context.eval_pool, keys.ptr);
    const entries = try context.eval_pool.alloc_values(capacity);
    const entries_offset = value_offset(context.eval_pool, entries.ptr);
    var count: u32 = 0;
    var left_index: u32 = 0;
    while (left_index < left_function.len) : (left_index += 1) {
        const left_keys = left_function.domain.items(context.eval_pool);
        const left_key = left_keys[left_index];
        var overridden = false;
        for (right_function.domain.items(context.eval_pool)) |right_key| {
            if (left_key.eql(right_key, context.eval_pool)) {
                overridden = true;
                break;
            }
        }
        if (!overridden) {
            context.eval_pool.values[keys_offset + count] = left_key;
            context.eval_pool.values[entries_offset + count] =
                left_function.entries(context.eval_pool)[left_index];
            count += 1;
        }
    }
    const right_keys = right_function.domain.items(context.eval_pool);
    const right_entries = right_function.entries(context.eval_pool);
    @memcpy(
        context.eval_pool.values[keys_offset + count ..][0..right_function.len],
        right_keys,
    );
    @memcpy(
        context.eval_pool.values[entries_offset + count ..][0..right_function.len],
        right_entries,
    );
    count += right_function.len;
    return .{ .function_v = .{
        .domain = .{
            .offset = keys_offset,
            .len = count,
        },
        .offset = entries_offset,
        .len = count,
    } };
}

pub fn function_range(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const source = switch (args[0]) {
        .function_v => |function| function.entries(context.eval_pool),
        .tuple_v => |tuple_value| tuple_value.items(context.eval_pool),
        else => return Error.TypeError,
    };
    return set(context, source);
}

fn function_range_cross_pool(
    context: *CallContext,
    value: Value,
    source_pool: *const ValuePool,
) Error!Value {
    const source = switch (value) {
        .function_v => |function| function.entries(source_pool),
        .tuple_v => |tuple_value| tuple_value.items(source_pool),
        else => return Error.TypeError,
    };
    return set_cross_pool(context, source, source_pool);
}

pub fn variable_path_function_range(
    context: *CallContext,
    index: u32,
    keys: []const Value,
) Error!Value {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    return function_range_cross_pool(context, value, source_pool);
}

pub fn variable_path_field_function_range(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
) Error!Value {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    if (value != .record_v) return Error.TypeError;
    const field_value = value.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    return function_range_cross_pool(context, field_value, source_pool);
}

pub fn sequence_to_set(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const source = switch (args[0]) {
        .function_v => |function| function.entries(context.eval_pool),
        .tuple_v => |tuple_value| tuple_value.items(context.eval_pool),
        else => return Error.TypeError,
    };
    return set(context, source);
}

pub fn sequence_index(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 2) return Error.TypeError;
    const source = switch (args[0]) {
        .function_v => |function| function.entries(context.eval_pool),
        .tuple_v => |tuple_value| tuple_value.items(context.eval_pool),
        else => return Error.TypeError,
    };
    for (source, 0..) |item, index| {
        if (item.eql(args[1], context.eval_pool)) {
            return .{ .int_v = @as(i64, @intCast(index)) + 1 };
        }
    }
    return Error.EmptyChoose;
}

pub fn sequence_index_order_bool(
    context: *CallContext,
    args: []const Value,
    inclusive: bool,
) Error!bool {
    if (args.len != 3) return Error.TypeError;
    const source = switch (args[0]) {
        .function_v => |function| function.entries(context.eval_pool),
        .tuple_v => |tuple_value| tuple_value.items(context.eval_pool),
        else => return Error.TypeError,
    };
    var left_index: ?usize = null;
    var right_index: ?usize = null;
    for (source, 0..) |item, index| {
        if (left_index == null and item.eql(args[1], context.eval_pool)) {
            left_index = index;
        }
        if (right_index == null and item.eql(args[2], context.eval_pool)) {
            right_index = index;
        }
        if (left_index != null and right_index != null) {
            return if (inclusive)
                left_index.? <= right_index.?
            else
                left_index.? < right_index.?;
        }
    }
    return Error.EmptyChoose;
}

pub fn permutation_sequences(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 1 or args[0] != .set_v) return Error.TypeError;
    const items = args[0].set_v.items(context.eval_pool);
    if (items.len > 10) return Error.NotImplemented;
    const count = try permutation_count(items.len);
    try context.eval_pool.ensure_value_capacity(
        count + count * items.len,
    );
    const result = try context.eval_pool.alloc_values(count);
    const result_offset = value_offset(context.eval_pool, result.ptr);
    var scratch: [10]Value = undefined;
    var used: [10]bool = @splat(false);
    var output_index: u32 = 0;
    try generate_permutation_sequences(
        context,
        items,
        scratch[0..items.len],
        used[0..items.len],
        0,
        result_offset,
        &output_index,
    );
    std.debug.assert(output_index == count);
    return .{ .set_v = .{
        .offset = result_offset,
        .len = count,
    } };
}

fn generate_permutation_sequences(
    context: *CallContext,
    items: []const Value,
    scratch: []Value,
    used: []bool,
    depth: usize,
    result_offset: u32,
    output_index: *u32,
) Error!void {
    if (depth == items.len) {
        const tuple_value = try tuple(context, scratch);
        context.eval_pool.values[result_offset + output_index.*] =
            tuple_value;
        output_index.* += 1;
        return;
    }
    for (items, 0..) |item, item_index| {
        if (used[item_index]) continue;
        used[item_index] = true;
        scratch[depth] = item;
        try generate_permutation_sequences(
            context,
            items,
            scratch,
            used,
            depth + 1,
            result_offset,
            output_index,
        );
        used[item_index] = false;
    }
}

pub fn permutations(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 1 or args[0] != .set_v) return Error.TypeError;
    const function_domain = args[0].set_v;
    const items = function_domain.items(context.eval_pool);
    if (items.len > 10) return Error.NotImplemented;
    const count = try permutation_count(items.len);
    try context.eval_pool.ensure_value_capacity(
        count + count * items.len,
    );
    const result = try context.eval_pool.alloc_values(count);
    const result_offset = value_offset(context.eval_pool, result.ptr);
    var order: [10]u8 = undefined;
    for (order[0..items.len], 0..) |*entry, index| {
        entry.* = @intCast(index);
    }
    var output_index: u32 = 0;
    while (true) {
        const entries = try context.eval_pool.alloc_values(
            @intCast(items.len),
        );
        const entries_offset = value_offset(
            context.eval_pool,
            entries.ptr,
        );
        for (order[0..items.len], 0..) |source_index, index| {
            context.eval_pool.values[entries_offset + index] =
                items[source_index];
        }
        context.eval_pool.values[result_offset + output_index] =
            .{ .function_v = .{
                .domain = function_domain,
                .offset = entries_offset,
                .len = @intCast(items.len),
            } };
        output_index += 1;
        if (!next_permutation(order[0..items.len])) break;
    }
    std.debug.assert(output_index == count);
    return .{ .set_v = .{
        .offset = result_offset,
        .len = count,
    } };
}

pub fn permutations_union(
    context: *CallContext,
    domains: []const Value,
) Error!Value {
    var total_permutations: u64 = 0;
    var total_entries: u64 = 0;
    for (domains) |domain_value| {
        const domain_set_value = try materialize_iterable(context, domain_value);
        if (domain_set_value != .set_v) return Error.TypeError;
        const item_count = domain_set_value.set_v.len;
        if (item_count > 10) return Error.NotImplemented;
        const count = try permutation_count(item_count);
        total_permutations += count;
        total_entries += @as(u64, count) * item_count;
    }
    if (total_permutations > std.math.maxInt(u32)) return Error.OutOfMemory;
    try context.eval_pool.ensure_value_capacity(
        total_permutations + total_entries,
    );

    const result = try context.eval_pool.alloc_values(
        @intCast(total_permutations),
    );
    const result_offset = value_offset(context.eval_pool, result.ptr);
    var result_count: u32 = 0;
    for (domains) |domain_value| {
        const domain_set =
            (try materialize_iterable(context, domain_value)).set_v;
        try append_permutations(
            context,
            domain_set,
            result_offset,
            &result_count,
        );
    }
    return .{ .set_v = .{
        .offset = result_offset,
        .len = result_count,
    } };
}

fn append_permutations(
    context: *CallContext,
    function_domain: Set,
    result_offset: u32,
    result_count: *u32,
) Error!void {
    const items = function_domain.items(context.eval_pool);
    var order: [10]u8 = undefined;
    for (order[0..items.len], 0..) |*entry, index| {
        entry.* = @intCast(index);
    }
    while (true) {
        const entries = try context.eval_pool.alloc_values(
            @intCast(items.len),
        );
        const entries_offset = value_offset(
            context.eval_pool,
            entries.ptr,
        );
        for (order[0..items.len], 0..) |source_index, index| {
            context.eval_pool.values[entries_offset + index] =
                items[source_index];
        }
        const candidate = Value{ .function_v = .{
            .domain = function_domain,
            .offset = entries_offset,
            .len = @intCast(items.len),
        } };
        var duplicate = false;
        for (
            context.eval_pool.values[result_offset .. result_offset + result_count.*],
        ) |existing| {
            if (candidate.eql(existing, context.eval_pool)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            context.eval_pool.values[result_offset + result_count.*] =
                candidate;
            result_count.* += 1;
        }
        if (!next_permutation(order[0..items.len])) break;
    }
}

fn permutation_count(item_count: usize) Error!u32 {
    var count: u64 = 1;
    for (2..item_count + 1) |factor| {
        count = std.math.mul(u64, count, factor) catch
            return Error.OutOfMemory;
    }
    if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
    return @intCast(count);
}

fn next_permutation(order: []u8) bool {
    if (order.len < 2) return false;
    var pivot = order.len - 1;
    while (pivot > 0 and order[pivot - 1] >= order[pivot]) {
        pivot -= 1;
    }
    if (pivot == 0) return false;
    var successor = order.len - 1;
    while (order[successor] <= order[pivot - 1]) successor -= 1;
    std.mem.swap(u8, &order[pivot - 1], &order[successor]);
    std.mem.reverse(u8, order[pivot..]);
    return true;
}

pub fn intersection_all(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const outer = try materialize_iterable(context, args[0]);
    if (outer != .set_v) return Error.TypeError;
    const outer_set = outer.set_v;
    if (outer_set.len == 0) return set(context, &.{});
    var smallest = try materialize_iterable(
        context,
        context.eval_pool.values[outer_set.offset],
    );
    if (smallest != .set_v) return Error.TypeError;
    var set_index: u32 = 1;
    while (set_index < outer_set.len) : (set_index += 1) {
        const set_value =
            context.eval_pool.values[outer_set.offset + set_index];
        const candidate = try materialize_iterable(context, set_value);
        if (candidate != .set_v) return Error.TypeError;
        if (candidate.set_v.len < smallest.set_v.len) {
            smallest = candidate;
        }
    }
    const smallest_set = smallest.set_v;
    const accepted = try context.eval_pool.alloc_values(
        smallest_set.len,
    );
    const accepted_offset = value_offset(context.eval_pool, accepted.ptr);
    var accepted_count: u32 = 0;
    const candidates = smallest_set.items(context.eval_pool);
    for (candidates) |candidate| {
        var present = true;
        set_index = 0;
        while (set_index < outer_set.len) : (set_index += 1) {
            const set_value =
                context.eval_pool.values[outer_set.offset + set_index];
            if (!set_value.member(context.eval_pool, candidate)) {
                present = false;
                break;
            }
        }
        if (present) {
            context.eval_pool.values[accepted_offset + accepted_count] =
                candidate;
            accepted_count += 1;
        }
    }
    return .{ .set_v = .{
        .offset = accepted_offset,
        .len = accepted_count,
    } };
}

pub fn power_set(context: *CallContext, operand: Value) Error!Value {
    if (!operand.is_set_like()) return Error.TypeError;
    return .{ .power_set_v = .{
        .set_offset = try context.eval_pool.push_value(operand),
    } };
}

pub fn union_all(context: *CallContext, operand: Value) Error!Value {
    if (!operand.is_set_like()) return Error.TypeError;
    return .{ .union_v = .{
        .set_offset = try context.eval_pool.push_value(operand),
    } };
}

pub fn function_set(
    context: *CallContext,
    domain_value: Value,
    codomain_value: Value,
) Error!Value {
    if (!domain_value.is_set_like() or !codomain_value.is_set_like()) {
        return Error.TypeError;
    }
    return .{ .function_set_v = .{
        .domain_offset = try context.eval_pool.push_value(domain_value),
        .codomain_offset = try context.eval_pool.push_value(codomain_value),
    } };
}

/// Builds the symbolic union represented by
/// `UNION {[1..n -> elements] : n \in lengths}`. Domains are shared by
/// length and remain symbolic until a caller truly needs enumeration.
pub fn bounded_sequence_union(
    context: *CallContext,
    element_set: Value,
    length_domain: Value,
) Error!Value {
    if (!element_set.is_set_like() or !length_domain.is_set_like()) {
        return Error.TypeError;
    }
    const lengths = try iterable_for_iteration(context, length_domain);
    const length_count = try iterable_count(lengths);
    var outer_count: u32 = 0;
    var domain_value_count: u64 = 0;
    var index: u32 = 0;
    while (index < length_count) : (index += 1) {
        const length = try normalized_sequence_length(
            try iterable_value(context, lengths, index),
        );
        if (!try sequence_length_is_first(
            context,
            lengths,
            index,
            length,
        )) continue;
        outer_count = std.math.add(u32, outer_count, 1) catch
            return Error.OutOfMemory;
        domain_value_count = std.math.add(
            u64,
            domain_value_count,
            length,
        ) catch return Error.OutOfMemory;
    }
    const metadata_value_count = std.math.mul(
        u64,
        outer_count,
        3,
    ) catch return Error.OutOfMemory;
    var required = std.math.add(
        u64,
        domain_value_count,
        metadata_value_count,
    ) catch return Error.OutOfMemory;
    required = std.math.add(u64, required, 1) catch
        return Error.OutOfMemory;
    if (required > std.math.maxInt(u32)) return Error.OutOfMemory;
    try context.eval_pool.ensure_value_capacity(required);

    const outer_values = try context.eval_pool.alloc_values(outer_count);
    const outer_offset = value_offset(context.eval_pool, outer_values.ptr);
    var outer_index: u32 = 0;
    index = 0;
    while (index < length_count) : (index += 1) {
        const length = try normalized_sequence_length(
            try iterable_value(context, lengths, index),
        );
        if (!try sequence_length_is_first(
            context,
            lengths,
            index,
            length,
        )) continue;
        const keys = try context.eval_pool.alloc_values(length);
        const keys_offset = value_offset(context.eval_pool, keys.ptr);
        for (keys, 0..) |*key, key_index| {
            key.* = .{ .int_v = @as(i64, @intCast(key_index)) + 1 };
        }
        const domain_offset = try context.eval_pool.push_value(.{
            .set_v = .{ .offset = keys_offset, .len = length },
        });
        const codomain_offset = try context.eval_pool.push_value(element_set);
        context.eval_pool.values[outer_offset + outer_index] = .{
            .function_set_v = .{
                .domain_offset = domain_offset,
                .codomain_offset = codomain_offset,
            },
        };
        outer_index += 1;
    }
    std.debug.assert(outer_index == outer_count);
    const union_offset = try context.eval_pool.push_value(.{
        .set_v = .{ .offset = outer_offset, .len = outer_count },
    });
    std.debug.assert(context.eval_pool.value_count <= context.eval_pool.value_cap);
    return .{ .union_v = .{ .set_offset = union_offset } };
}

/// Generates exactly the nondecreasing sequences from a bounded sequence
/// domain. It shares each `1..n` domain and writes result payloads directly
/// into one pre-sized value pool, with no heap allocation in the generator.
pub fn sorted_sequences(
    context: *CallContext,
    element_set: Value,
    length_domain: Value,
) Error!Value {
    if (!element_set.is_set_like() or !length_domain.is_set_like()) {
        return Error.TypeError;
    }
    const materialized_elements = try materialize_iterable(
        context,
        element_set,
    );
    const lengths = try iterable_for_iteration(context, length_domain);
    const length_count = try iterable_count(lengths);
    const element_count = materialized_elements.set_v.len;

    var result_count: u64 = 0;
    var entry_value_count: u64 = 0;
    var domain_value_count: u64 = 0;
    var index: u32 = 0;
    while (index < length_count) : (index += 1) {
        const length = try normalized_sequence_length(
            try iterable_value(context, lengths, index),
        );
        if (!try sequence_length_is_first(
            context,
            lengths,
            index,
            length,
        )) continue;
        const count = try sorted_sequence_count(element_count, length);
        result_count = std.math.add(u64, result_count, count) catch
            return Error.OutOfMemory;
        entry_value_count = std.math.add(
            u64,
            entry_value_count,
            std.math.mul(u64, count, length) catch
                return Error.OutOfMemory,
        ) catch return Error.OutOfMemory;
        if (count > 0) {
            domain_value_count = std.math.add(
                u64,
                domain_value_count,
                length,
            ) catch return Error.OutOfMemory;
        }
        if (result_count > std.math.maxInt(u32)) return Error.OutOfMemory;
    }

    var required = std.math.add(
        u64,
        element_count,
        result_count,
    ) catch return Error.OutOfMemory;
    required = std.math.add(u64, required, entry_value_count) catch
        return Error.OutOfMemory;
    required = std.math.add(u64, required, domain_value_count) catch
        return Error.OutOfMemory;
    if (required > std.math.maxInt(u32)) return Error.OutOfMemory;
    try context.eval_pool.ensure_value_capacity(required);

    const sorted_values = try context.eval_pool.alloc_values(element_count);
    const sorted_offset = value_offset(context.eval_pool, sorted_values.ptr);
    @memcpy(
        sorted_values,
        materialized_elements.set_v.items(context.eval_pool),
    );
    try sort_sequence_elements(context.eval_pool, sorted_offset, element_count);

    const results = try context.eval_pool.alloc_values(@intCast(result_count));
    const result_offset = value_offset(context.eval_pool, results.ptr);
    var result_index: u32 = 0;
    index = 0;
    while (index < length_count) : (index += 1) {
        const length = try normalized_sequence_length(
            try iterable_value(context, lengths, index),
        );
        if (!try sequence_length_is_first(
            context,
            lengths,
            index,
            length,
        )) continue;
        const count = try sorted_sequence_count(element_count, length);
        if (count == 0) continue;
        const keys = try context.eval_pool.alloc_values(length);
        const keys_offset = value_offset(context.eval_pool, keys.ptr);
        for (keys, 0..) |*key, key_index| {
            key.* = .{ .int_v = @as(i64, @intCast(key_index)) + 1 };
        }
        const sequence_domain = Set{ .offset = keys_offset, .len = length };
        var ordinal: u64 = 0;
        while (ordinal < count) : (ordinal += 1) {
            const entries = try context.eval_pool.alloc_values(length);
            const entries_offset = value_offset(context.eval_pool, entries.ptr);
            try write_sorted_sequence(
                context.eval_pool,
                sorted_offset,
                element_count,
                entries_offset,
                length,
                ordinal,
            );
            context.eval_pool.values[result_offset + result_index] = .{
                .function_v = .{
                    .domain = sequence_domain,
                    .offset = entries_offset,
                    .len = length,
                },
            };
            result_index += 1;
        }
    }
    std.debug.assert(result_index == result_count);
    std.debug.assert(context.eval_pool.value_count <= context.eval_pool.value_cap);
    return .{ .set_v = .{
        .offset = result_offset,
        .len = @intCast(result_count),
    } };
}

fn normalized_sequence_length(value: Value) Error!u32 {
    const length = try integer(value);
    if (length <= 0) return 0;
    if (length > std.math.maxInt(u32)) return Error.OutOfMemory;
    return @intCast(length);
}

fn sequence_length_is_first(
    context: *CallContext,
    lengths: Value,
    index: u32,
    length: u32,
) Error!bool {
    var prior: u32 = 0;
    while (prior < index) : (prior += 1) {
        if (try normalized_sequence_length(
            try iterable_value(context, lengths, prior),
        ) == length) return false;
    }
    return true;
}

fn sorted_sequence_count(
    element_count: u32,
    length: u32,
) Error!u64 {
    if (length == 0) return 1;
    if (element_count == 0) return 0;
    if (element_count == 1) return 1;
    const total: u64 = @as(u64, element_count) + length - 1;
    const selected: u64 = @min(length, element_count - 1);
    var result: u128 = 1;
    var factor: u64 = 1;
    while (factor <= selected) : (factor += 1) {
        result = result * (total - selected + factor) / factor;
        if (result > std.math.maxInt(u32)) return Error.OutOfMemory;
    }
    return @intCast(result);
}

fn sort_sequence_elements(
    pool: *ValuePool,
    offset: u32,
    count: u32,
) Error!void {
    var index: u32 = 1;
    while (index < count) : (index += 1) {
        const key = pool.values[offset + index];
        var insertion = index;
        while (insertion > 0) {
            const order = pool.values[offset + insertion - 1].compare(
                key,
                pool,
            ) orelse return Error.TypeError;
            if (order <= 0) break;
            pool.values[offset + insertion] =
                pool.values[offset + insertion - 1];
            insertion -= 1;
        }
        pool.values[offset + insertion] = key;
    }
}

fn write_sorted_sequence(
    pool: *ValuePool,
    sorted_offset: u32,
    element_count: u32,
    entries_offset: u32,
    length: u32,
    ordinal: u64,
) Error!void {
    var remaining = ordinal;
    var minimum_element: u32 = 0;
    var position: u32 = 0;
    while (position < length) : (position += 1) {
        var selected = minimum_element;
        while (selected < element_count) : (selected += 1) {
            const suffix_count = try sorted_sequence_count(
                element_count - selected,
                length - position - 1,
            );
            if (remaining < suffix_count) break;
            remaining -= suffix_count;
        }
        std.debug.assert(selected < element_count);
        pool.values[entries_offset + position] =
            pool.values[sorted_offset + selected];
        minimum_element = selected;
    }
    std.debug.assert(remaining == 0);
}

test "bounded sorted sequences generate only canonical candidates" {
    const Arena = @import("arena.zig").Arena;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 16, 64);
    var models = try ModelTable.init(&arena, 4);
    var generated_cache = [_]?Value{};
    var context = CallContext{
        .eval_pool = &pool,
        .state_pool = &pool,
        .state = null,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &pool,
        .generated_cache_frozen = false,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 4,
    };
    const elements = try set(
        &context,
        &.{ .{ .int_v = 2 }, .{ .int_v = 1 } },
    );
    const lengths = try range(.{ .int_v = 1 }, .{ .int_v = 3 });
    const bounded = try bounded_sequence_union(
        &context,
        elements,
        lengths,
    );
    const ascending = try tuple(
        &context,
        &.{ .{ .int_v = 1 }, .{ .int_v = 2 } },
    );
    const descending = try tuple(
        &context,
        &.{ .{ .int_v = 2 }, .{ .int_v = 1 } },
    );
    const empty = try tuple(&context, &.{});
    try std.testing.expect(bounded.member(&pool, ascending));
    try std.testing.expect(bounded.member(&pool, descending));
    try std.testing.expect(!bounded.member(&pool, empty));

    const sorted = try sorted_sequences(&context, elements, lengths);
    try std.testing.expectEqual(@as(u32, 9), sorted.set_v.len);
    var counts_by_length = [_]u32{ 0, 0, 0, 0 };
    for (sorted.set_v.items(&pool)) |sequence| {
        try std.testing.expect(sequence == .function_v);
        counts_by_length[sequence.function_v.len] += 1;
        const entries = sequence.function_v.entries(&pool);
        for (entries[1..], entries[0 .. entries.len - 1]) |right, left| {
            try std.testing.expect(left.int_v <= right.int_v);
        }
    }
    try std.testing.expectEqualSlices(
        u32,
        &.{ 0, 2, 3, 4 },
        &counts_by_length,
    );
    try std.testing.expect(sorted.member(&pool, ascending));
    try std.testing.expect(!sorted.member(&pool, descending));

    const nonpositive_lengths = try range(
        .{ .int_v = -2 },
        .{ .int_v = 1 },
    );
    const with_empty = try sorted_sequences(
        &context,
        elements,
        nonpositive_lengths,
    );
    try std.testing.expectEqual(@as(u32, 3), with_empty.set_v.len);
    try std.testing.expect(with_empty.member(&pool, empty));
}

pub fn record_set(
    context: *CallContext,
    fields: []const Value,
) Error!Value {
    if (fields.len % 2 != 0) return Error.TypeError;
    const values = try context.eval_pool.alloc_values(
        @intCast(fields.len),
    );
    @memcpy(values, fields);
    var index: usize = 0;
    while (index < values.len) : (index += 2) {
        if (values[index] != .string_v or
            !values[index + 1].is_set_like())
        {
            return Error.TypeError;
        }
    }
    return .{ .record_set_v = .{
        .offset = value_offset(context.eval_pool, values.ptr),
        .len = @intCast(values.len / 2),
    } };
}

pub fn domain(context: *CallContext, operand: Value) Error!Value {
    return switch (operand) {
        .generated_operator_v => |operator_value| blk: {
            if (operator_value.arity != 0) return Error.TypeError;
            break :blk try domain(context, try call(context, operand, &.{}));
        },
        .function_v => |function| .{ .set_v = function.domain },
        .tuple_v => |tuple_value| .{ .range_v = .{
            .lo = 1,
            .hi = @intCast(tuple_value.len),
        } },
        .record_v => |record_value| blk: {
            const keys = try context.eval_pool.alloc_values(record_value.len);
            var index: u32 = 0;
            while (index < record_value.len) : (index += 1) {
                keys[index] = record_value.fields(
                    context.eval_pool,
                )[index * 2];
            }
            break :blk try set(context, keys);
        },
        else => Error.TypeError,
    };
}

fn domain_cross_pool(
    context: *CallContext,
    value: Value,
    source_pool: *const ValuePool,
) Error!Value {
    return switch (value) {
        .generated_operator_v => |operator_value| blk: {
            if (operator_value.arity != 0 or source_pool != context.eval_pool) {
                return Error.TypeError;
            }
            break :blk try domain(context, try call(context, value, &.{}));
        },
        .function_v => |function| .{
            .set_v = try function.domain.clone(source_pool, context.eval_pool),
        },
        .tuple_v => |tuple_value| .{ .range_v = .{
            .lo = 1,
            .hi = @intCast(tuple_value.len),
        } },
        .record_v => |record_value| blk: {
            const keys = try context.eval_pool.alloc_values(record_value.len);
            const fields = record_value.fields(source_pool);
            var index: u32 = 0;
            while (index < record_value.len) : (index += 1) {
                keys[index] = try fields[index * 2].clone(
                    source_pool,
                    context.eval_pool,
                );
            }
            break :blk try set(context, keys);
        },
        else => Error.TypeError,
    };
}

pub fn variable_path_domain(
    context: *CallContext,
    index: u32,
    keys: []const Value,
) Error!Value {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    return domain_cross_pool(context, value, source_pool);
}

pub fn variable_path_field_domain(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    field_name: []const u8,
) Error!Value {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_path(context, index, keys, &source_pool);
    if (value != .record_v) return Error.TypeError;
    const field_value = value.record_v.lookup(source_pool, field_name) orelse
        return Error.UndefinedSymbol;
    return domain_cross_pool(context, field_value, source_pool);
}

pub fn constant_function(
    context: *CallContext,
    domain_value: Value,
    result_value: Value,
) Error!Value {
    const materialized_domain = try iterable_for_iteration(
        context,
        domain_value,
    );
    const function_domain: Set = switch (materialized_domain) {
        .set_v => |set_value| set_value,
        .range_v => |range_value| blk: {
            if (range_value.hi < range_value.lo) {
                const empty = try context.eval_pool.alloc_values(0);
                break :blk .{
                    .offset = value_offset(
                        context.eval_pool,
                        empty.ptr,
                    ),
                    .len = 0,
                };
            }
            const length_i128 =
                @as(i128, range_value.hi) -
                @as(i128, range_value.lo) + 1;
            if (length_i128 > std.math.maxInt(u32)) {
                return Error.OutOfMemory;
            }
            const keys = try context.eval_pool.alloc_values(
                @intCast(length_i128),
            );
            for (keys, 0..) |*key, index| {
                key.* = .{
                    .int_v = range_value.lo + @as(i64, @intCast(index)),
                };
            }
            break :blk .{
                .offset = value_offset(context.eval_pool, keys.ptr),
                .len = @intCast(keys.len),
            };
        },
        else => return Error.TypeError,
    };
    const entries = try context.eval_pool.alloc_values(
        function_domain.len,
    );
    @memset(entries, result_value);
    return .{ .function_v = .{
        .domain = function_domain,
        .offset = value_offset(context.eval_pool, entries.ptr),
        .len = function_domain.len,
    } };
}

pub fn quantify(
    context: *CallContext,
    operator_args: []const Value,
    domains: []const Value,
    kind: QuantifierKind,
    predicate: OperatorFn,
) Error!Value {
    return quantify_at(
        context,
        operator_args,
        domains,
        kind,
        predicate,
        0,
    );
}

pub fn quantify_at(
    context: *CallContext,
    operator_args: []const Value,
    domains: []const Value,
    kind: QuantifierKind,
    predicate: OperatorFn,
    source_identity: u32,
) Error!Value {
    _ = source_identity;
    if (domains.len > 16 or operator_args.len + domains.len > 64) {
        return Error.NotImplemented;
    }
    var materialized: [16]Value = undefined;
    for (domains, 0..) |domain_value, index| {
        materialized[index] = try iterable_for_iteration(
            context,
            domain_value,
        );
    }
    var bound: [16]Value = undefined;
    const result = try quantify_recursive(
        context,
        operator_args,
        materialized[0..domains.len],
        kind,
        predicate,
        bound[0..domains.len],
        0,
    );
    return .{ .bool_v = result };
}

pub fn quantify_at_bool(
    context: *CallContext,
    operator_args: []const Value,
    domains: []const Value,
    kind: QuantifierKind,
    predicate: OperatorBoolFn,
    source_identity: u32,
) Error!bool {
    _ = source_identity;
    if (domains.len > 16 or operator_args.len + domains.len > 64) {
        return Error.NotImplemented;
    }
    var materialized: [16]Value = undefined;
    for (domains, 0..) |domain_value, index| {
        materialized[index] = try iterable_for_iteration(
            context,
            domain_value,
        );
    }
    var bound: [16]Value = undefined;
    return quantify_recursive_bool(
        context,
        operator_args,
        materialized[0..domains.len],
        kind,
        predicate,
        bound[0..domains.len],
        0,
    );
}

pub fn quantify_constant_at(
    context: *CallContext,
    operator_args: []const Value,
    constant_index: u32,
    kind: QuantifierKind,
    predicate: OperatorFn,
    source_identity: u32,
) Error!Value {
    _ = source_identity;
    std.debug.assert(context.eval_pool.value_count <= context.eval_pool.value_cap);
    std.debug.assert(context.state_pool.value_count <= context.state_pool.value_cap);
    if (constant_index >= context.constant_slots.len) {
        return Error.UndefinedSymbol;
    }
    if (operator_args.len + 1 > 64) return Error.NotImplemented;
    const domain_value = context.constant_slots[constant_index] orelse
        return Error.UndefinedSymbol;
    const count = try iterable_count(domain_value);
    var bound: [1]Value = undefined;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        bound[0] = try iterable_value_from_pool(
            context,
            domain_value,
            context.state_pool,
            index,
        );
        const accepted = try boolean(try call_bound(
            context,
            operator_args,
            &bound,
            predicate,
        ));
        if (kind == .exists and accepted) return .{ .bool_v = true };
        if (kind == .forall and !accepted) return .{ .bool_v = false };
    }
    return .{ .bool_v = kind == .forall };
}

pub fn quantify_constant_at_bool(
    context: *CallContext,
    operator_args: []const Value,
    constant_index: u32,
    kind: QuantifierKind,
    predicate: OperatorBoolFn,
    source_identity: u32,
) Error!bool {
    _ = source_identity;
    std.debug.assert(context.eval_pool.value_count <= context.eval_pool.value_cap);
    std.debug.assert(context.state_pool.value_count <= context.state_pool.value_cap);
    if (constant_index >= context.constant_slots.len) {
        return Error.UndefinedSymbol;
    }
    if (operator_args.len + 1 > 64) return Error.NotImplemented;
    const domain_value = context.constant_slots[constant_index] orelse
        return Error.UndefinedSymbol;
    const count = try iterable_count(domain_value);
    var bound: [1]Value = undefined;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        bound[0] = try iterable_value_from_pool(
            context,
            domain_value,
            context.state_pool,
            index,
        );
        const accepted = try call_bound_bool(
            context,
            operator_args,
            &bound,
            predicate,
        );
        if (kind == .exists and accepted) return true;
        if (kind == .forall and !accepted) return false;
    }
    return kind == .forall;
}

pub fn quantify_filtered_power_set(
    context: *CallContext,
    operator_args: []const Value,
    base_value: Value,
    kind: QuantifierKind,
    filter_predicate: OperatorFn,
    predicate: OperatorFn,
) Error!Value {
    return quantify_filtered_power_set_impl(
        context,
        operator_args,
        base_value,
        kind,
        filter_predicate,
        predicate,
        true,
    );
}

pub fn quantify_filtered_power_set_isolated_filter(
    context: *CallContext,
    operator_args: []const Value,
    base_value: Value,
    kind: QuantifierKind,
    filter_predicate: OperatorFn,
    predicate: OperatorFn,
) Error!Value {
    return quantify_filtered_power_set_impl(
        context,
        operator_args,
        base_value,
        kind,
        filter_predicate,
        predicate,
        false,
    );
}

fn quantify_filtered_power_set_impl(
    context: *CallContext,
    operator_args: []const Value,
    base_value: Value,
    kind: QuantifierKind,
    filter_predicate: OperatorFn,
    predicate: OperatorFn,
    filter_uses_operator_args: bool,
) Error!Value {
    if (operator_args.len + 1 > 64) return Error.NotImplemented;
    const base = try materialize_iterable(context, base_value);
    if (base != .set_v or base.set_v.len > 63) {
        return Error.NotImplemented;
    }

    const base_items = base.set_v.items(context.eval_pool);
    const subset_items = try context.eval_pool.alloc_values(base.set_v.len);
    const subset_offset = value_offset(context.eval_pool, subset_items.ptr);
    const iteration_snapshot = context.eval_pool.snapshot();
    const subset_count = @as(u64, 1) << @intCast(base_items.len);
    var mask: u64 = 0;
    while (mask < subset_count) : (mask += 1) {
        var item_count: u32 = 0;
        for (base_items, 0..) |item, bit| {
            if ((mask & (@as(u64, 1) << @intCast(bit))) != 0) {
                context.eval_pool.values[subset_offset + item_count] = item;
                item_count += 1;
            }
        }
        const subset = Value{ .set_v = .{
            .offset = subset_offset,
            .len = item_count,
        } };
        const filter_args = if (filter_uses_operator_args)
            operator_args
        else
            &.{};
        const accepted = try boolean(try call_bound(
            context,
            filter_args,
            &.{subset},
            filter_predicate,
        ));
        if (accepted) {
            const result = try boolean(try call_bound(
                context,
                operator_args,
                &.{subset},
                predicate,
            ));
            if (kind == .exists and result) {
                restore_eval_pool(context, iteration_snapshot);
                return .{ .bool_v = true };
            }
            if (kind == .forall and !result) {
                restore_eval_pool(context, iteration_snapshot);
                return .{ .bool_v = false };
            }
        }
        restore_eval_pool(context, iteration_snapshot);
    }
    return .{ .bool_v = kind == .forall };
}

pub fn exists_total_order_relation(
    context: *CallContext,
    operator_args: []const Value,
    base_value: Value,
    predicate: OperatorFn,
) Error!Value {
    if (operator_args.len + 1 > 64) return Error.NotImplemented;
    const base = try materialize_iterable(context, base_value);
    if (base != .set_v) return Error.NotImplemented;
    const total = base.set_v.len;
    if (total == 0) {
        const empty = try context.eval_pool.alloc_values(0);
        const relation = Value{ .set_v = .{
            .offset = value_offset(context.eval_pool, empty.ptr),
            .len = 0,
        } };
        return .{ .bool_v = try boolean(try call_bound(
            context,
            operator_args,
            &.{relation},
            predicate,
        )) };
    }

    const n_float = @sqrt(@as(f64, @floatFromInt(total)));
    const n: u32 = @intFromFloat(n_float + 0.5);
    if (n * n != total or n > 16) return Error.NotImplemented;

    const base_offset = base.set_v.offset;
    const relation_cap: u32 = n * (n - 1) / 2;
    const relation_items = try context.eval_pool.alloc_values(
        @max(relation_cap, 1),
    );
    const relation_offset = value_offset(context.eval_pool, relation_items.ptr);
    const iteration_snapshot = context.eval_pool.snapshot();

    var permutation: [16]u32 = undefined;
    var index: u32 = 0;
    while (index < n) : (index += 1) permutation[index] = index;

    var found = try test_total_order_relation(
        context,
        operator_args,
        predicate,
        base_offset,
        n,
        &permutation,
        relation_offset,
        relation_cap,
        iteration_snapshot,
    );
    var counters: [16]u32 = @splat(0);
    var k: u32 = 1;
    while (!found and k < n) {
        if (counters[k] < k) {
            if (k & 1 == 0) {
                std.mem.swap(u32, &permutation[0], &permutation[k]);
            } else {
                std.mem.swap(
                    u32,
                    &permutation[counters[k]],
                    &permutation[k],
                );
            }
            found = try test_total_order_relation(
                context,
                operator_args,
                predicate,
                base_offset,
                n,
                &permutation,
                relation_offset,
                relation_cap,
                iteration_snapshot,
            );
            counters[k] += 1;
            k = 1;
        } else {
            counters[k] = 0;
            k += 1;
        }
    }

    restore_eval_pool(context, iteration_snapshot);
    return .{ .bool_v = found };
}

fn test_total_order_relation(
    context: *CallContext,
    operator_args: []const Value,
    predicate: OperatorFn,
    base_offset: u32,
    n: u32,
    permutation: *const [16]u32,
    relation_offset: u32,
    relation_cap: u32,
    snapshot: ValuePool.Snapshot,
) Error!bool {
    var relation_index: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var j: u32 = i + 1;
        while (j < n) : (j += 1) {
            const base_index = permutation[i] * n + permutation[j];
            context.eval_pool.values[relation_offset + relation_index] =
                context.eval_pool.values[base_offset + base_index];
            relation_index += 1;
        }
    }
    std.debug.assert(relation_index == relation_cap);
    const relation = Value{ .set_v = .{
        .offset = relation_offset,
        .len = relation_cap,
    } };
    const result = try boolean(try call_bound(
        context,
        operator_args,
        &.{relation},
        predicate,
    ));
    restore_eval_pool(context, snapshot);
    return result;
}

pub fn filter(
    context: *CallContext,
    operator_args: []const Value,
    domain_value: Value,
    predicate: OperatorFn,
) Error!Value {
    return filter_at(
        context,
        operator_args,
        domain_value,
        predicate,
        0,
    );
}

pub fn filter_at(
    context: *CallContext,
    operator_args: []const Value,
    domain_value: Value,
    predicate: OperatorFn,
    source_identity: u32,
) Error!Value {
    _ = source_identity;
    if (domain_value == .function_set_v) {
        return filter_function_set(
            context,
            operator_args,
            domain_value.function_set_v,
            predicate,
        );
    }
    const iterable = try iterable_for_iteration(context, domain_value);
    const count = try iterable_count(iterable);
    const accepted = try context.eval_pool.alloc_values(count);
    const accepted_offset = value_offset(
        context.eval_pool,
        accepted.ptr,
    );
    var accepted_count: u32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const candidate = try iterable_value(context, iterable, index);
        const result = try call_bound(
            context,
            operator_args,
            &.{candidate},
            predicate,
        );
        if (try boolean(result)) {
            const accepted_values = context.eval_pool.values[accepted_offset..][0..count];
            accepted_values[accepted_count] = candidate;
            accepted_count += 1;
            std.debug.assert(accepted_count <= count);
        }
    }
    return .{ .set_v = .{
        .offset = accepted_offset,
        .len = accepted_count,
    } };
}

pub fn filter_variable_path_boolean(
    context: *CallContext,
    operator_args: []const Value,
    domain_value: Value,
    variable_index: u32,
    path: []const FilterPathKey,
) Error!Value {
    var bound_index: ?usize = null;
    for (path, 0..) |key, index| {
        switch (key) {
            .argument => |argument_index| {
                if (argument_index >= operator_args.len) return Error.TypeError;
            },
            .bound => {
                if (bound_index != null) return Error.TypeError;
                bound_index = index;
            },
            .field => {},
        }
    }
    const candidate_path_index = bound_index orelse return Error.TypeError;

    var source_pool: *const ValuePool = context.eval_pool;
    var prefix = try resolve_variable(
        context,
        variable_index,
        &source_pool,
    );
    for (path[0..candidate_path_index]) |key| {
        prefix = switch (key) {
            .argument => |argument_index| try apply_cross_pool(
                prefix,
                source_pool,
                try force(context, operator_args[argument_index]),
                context.eval_pool,
            ),
            .field => |field_name| try apply_literal_string_cross_pool(
                prefix,
                source_pool,
                field_name,
            ),
            .bound => unreachable,
        };
    }

    const iterable = try iterable_for_iteration(context, domain_value);
    const count = try iterable_count(iterable);
    const accepted = try context.eval_pool.alloc_values(count);
    const accepted_offset = value_offset(context.eval_pool, accepted.ptr);
    var accepted_count: u32 = 0;
    var first_field_index: ?u32 = null;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const candidate = try iterable_value(context, iterable, index);
        var value = try apply_cross_pool(
            prefix,
            source_pool,
            candidate,
            context.eval_pool,
        );
        for (path[candidate_path_index + 1 ..], 0..) |key, path_index| {
            value = switch (key) {
                .field => |field_name| if (path_index == 0 and
                    value == .record_v)
                    record_lookup_literal_cached(
                        value.record_v,
                        source_pool,
                        field_name,
                        &first_field_index,
                    ) orelse return Error.UndefinedSymbol
                else
                    try apply_literal_string_cross_pool(
                        value,
                        source_pool,
                        field_name,
                    ),
                .argument, .bound => return Error.TypeError,
            };
        }
        if (value != .bool_v) return Error.TypeError;
        if (value.bool_v) {
            const accepted_values = context.eval_pool.values[accepted_offset..][0..count];
            accepted_values[accepted_count] = candidate;
            accepted_count += 1;
            std.debug.assert(accepted_count <= count);
        }
    }
    return .{ .set_v = .{
        .offset = accepted_offset,
        .len = accepted_count,
    } };
}

/// Computes the structurally recognized recursive relation closure without
/// callbacks, temporary tuples, or one allocation per recursion level.
pub fn relation_descendants(
    context: *CallContext,
    vertices_value: Value,
    edges_value: Value,
    initial_frontier_value: Value,
) Error!Value {
    const vertices = try materialize_iterable(context, vertices_value);
    const edges = try materialize_iterable(context, edges_value);
    const initial_frontier = try materialize_iterable(
        context,
        initial_frontier_value,
    );
    std.debug.assert(vertices == .set_v);
    std.debug.assert(edges == .set_v);
    std.debug.assert(initial_frontier == .set_v);

    const vertices_count = vertices.set_v.len;
    const frontier_cap = @max(vertices_count, initial_frontier.set_v.len);
    const result_values = try context.eval_pool.alloc_values(vertices_count);
    const result_offset = value_offset(context.eval_pool, result_values.ptr);
    const frontier_a_values = try context.eval_pool.alloc_values(frontier_cap);
    const frontier_a_offset = value_offset(
        context.eval_pool,
        frontier_a_values.ptr,
    );
    const frontier_b_values = try context.eval_pool.alloc_values(frontier_cap);
    const frontier_b_offset = value_offset(
        context.eval_pool,
        frontier_b_values.ptr,
    );
    std.debug.assert(result_offset + vertices_count <= context.eval_pool.value_count);
    std.debug.assert(frontier_a_offset + frontier_cap <= context.eval_pool.value_count);
    std.debug.assert(frontier_b_offset + frontier_cap <= context.eval_pool.value_count);

    @memcpy(
        context.eval_pool.values[frontier_a_offset..][0..initial_frontier.set_v.len],
        initial_frontier.set_v.items(context.eval_pool),
    );
    var frontier_offset = frontier_a_offset;
    var next_offset = frontier_b_offset;
    var frontier_count = initial_frontier.set_v.len;
    var result_count: u32 = 0;

    while (frontier_count > 0) {
        const frontier = Set{
            .offset = frontier_offset,
            .len = frontier_count,
        };
        var next_count: u32 = 0;
        for (vertices.set_v.items(context.eval_pool)) |candidate| {
            var reachable = false;
            for (edges.set_v.items(context.eval_pool)) |edge| {
                const pair = relation_pair(context.eval_pool, edge) orelse
                    continue;
                if (pair[1].eql(candidate, context.eval_pool) and
                    frontier.contains(context.eval_pool, pair[0]))
                {
                    reachable = true;
                    break;
                }
            }
            if (!reachable) continue;

            context.eval_pool.values[next_offset + next_count] = candidate;
            next_count += 1;
            std.debug.assert(next_count <= vertices_count);

            const result = Set{
                .offset = result_offset,
                .len = result_count,
            };
            if (!result.contains(context.eval_pool, candidate)) {
                context.eval_pool.values[result_offset + result_count] = candidate;
                result_count += 1;
                std.debug.assert(result_count <= vertices_count);
            }
        }
        const old_frontier_offset = frontier_offset;
        frontier_offset = next_offset;
        next_offset = old_frontier_offset;
        frontier_count = next_count;
    }
    return .{ .set_v = .{
        .offset = result_offset,
        .len = result_count,
    } };
}

fn relation_pair(pool: *const ValuePool, value: Value) ?[2]Value {
    return switch (value) {
        .tuple_v => |tuple_value| blk: {
            if (tuple_value.len != 2) break :blk null;
            const items = tuple_value.items(pool);
            break :blk .{ items[0], items[1] };
        },
        .function_v => |function_value| blk: {
            if (function_value.len != 2) break :blk null;
            const first = function_value.apply(pool, .{ .int_v = 1 }) orelse
                break :blk null;
            const second = function_value.apply(pool, .{ .int_v = 2 }) orelse
                break :blk null;
            break :blk .{ first, second };
        },
        else => null,
    };
}

test "relation descendants uses iterative breadth-first set semantics" {
    const Arena = @import("arena.zig").Arena;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 128, 64);
    var models = try ModelTable.init(&arena, 4);
    var generated_cache = [_]?Value{};
    var context = CallContext{
        .eval_pool = &pool,
        .state_pool = &pool,
        .state = null,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &pool,
        .generated_cache_frozen = false,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 4,
    };

    const edge_12 = try tuple(
        &context,
        &.{ .{ .int_v = 1 }, .{ .int_v = 2 } },
    );
    const edge_23 = try tuple(
        &context,
        &.{ .{ .int_v = 2 }, .{ .int_v = 3 } },
    );
    const edge_14 = try tuple(
        &context,
        &.{ .{ .int_v = 1 }, .{ .int_v = 4 } },
    );
    const vertices = try set(
        &context,
        &.{
            .{ .int_v = 1 },
            .{ .int_v = 2 },
            .{ .int_v = 3 },
            .{ .int_v = 4 },
        },
    );
    const edges = try set(&context, &.{ edge_12, edge_23, edge_14 });
    const initial = try set(&context, &.{.{ .int_v = 1 }});
    const descendants = try relation_descendants(
        &context,
        vertices,
        edges,
        initial,
    );
    try std.testing.expectEqual(@as(u32, 3), descendants.set_v.len);
    try std.testing.expectEqualSlices(
        Value,
        &.{ .{ .int_v = 2 }, .{ .int_v = 4 }, .{ .int_v = 3 } },
        descendants.set_v.items(&pool),
    );

    const empty = try set(&context, &.{});
    const empty_descendants = try relation_descendants(
        &context,
        vertices,
        edges,
        empty,
    );
    try std.testing.expectEqual(@as(u32, 0), empty_descendants.set_v.len);
}

fn filter_function_set(
    context: *CallContext,
    operator_args: []const Value,
    function_set_value: @import("value.zig").FunctionSet,
    predicate: OperatorFn,
) Error!Value {
    const domain_value = try materialize_iterable(
        context,
        function_set_value.domain(context.eval_pool),
    );
    const codomain_value = try materialize_iterable(
        context,
        function_set_value.codomain(context.eval_pool),
    );
    const function_domain = domain_value.set_v;
    const codomain = codomain_value.set_v;
    var candidate_count: u64 = 1;
    var index: u32 = 0;
    while (index < function_domain.len) : (index += 1) {
        candidate_count = std.math.mul(
            u64,
            candidate_count,
            codomain.len,
        ) catch return Error.OutOfMemory;
        if (candidate_count > 262_144) return Error.NotImplemented;
    }
    var accepted_bits: [4096]u64 = undefined;
    const word_count: usize = @intCast((candidate_count + 63) / 64);
    @memset(accepted_bits[0..word_count], 0);
    const scratch = context.eval_pool.snapshot();
    var accepted_count: u32 = 0;
    var combination: u64 = 0;
    while (combination < candidate_count) : (combination += 1) {
        const entries = try context.eval_pool.alloc_values(
            function_domain.len,
        );
        const entries_offset = value_offset(
            context.eval_pool,
            entries.ptr,
        );
        var cursor = combination;
        index = 0;
        while (index < function_domain.len) : (index += 1) {
            const selected: u32 = @intCast(cursor % codomain.len);
            cursor /= codomain.len;
            context.eval_pool.values[entries_offset + index] =
                codomain.items(context.eval_pool)[selected];
        }
        const candidate = Value{ .function_v = .{
            .domain = function_domain,
            .offset = entries_offset,
            .len = function_domain.len,
        } };
        if (try boolean(try call_bound(
            context,
            operator_args,
            &.{candidate},
            predicate,
        ))) {
            const word: usize = @intCast(combination / 64);
            const bit: u6 = @intCast(combination % 64);
            accepted_bits[word] |= @as(u64, 1) << bit;
            accepted_count += 1;
        }
        restore_eval_pool(context, scratch);
    }

    try context.eval_pool.ensure_value_capacity(
        accepted_count +
            @as(u64, accepted_count) * function_domain.len,
    );
    const accepted = try context.eval_pool.alloc_values(accepted_count);
    const accepted_offset = value_offset(
        context.eval_pool,
        accepted.ptr,
    );
    var accepted_index: u32 = 0;
    combination = 0;
    while (combination < candidate_count) : (combination += 1) {
        const word: usize = @intCast(combination / 64);
        const bit: u6 = @intCast(combination % 64);
        if (accepted_bits[word] & (@as(u64, 1) << bit) == 0) continue;
        const entries = try context.eval_pool.alloc_values(
            function_domain.len,
        );
        const entries_offset = value_offset(
            context.eval_pool,
            entries.ptr,
        );
        var cursor = combination;
        index = 0;
        while (index < function_domain.len) : (index += 1) {
            const selected: u32 = @intCast(cursor % codomain.len);
            cursor /= codomain.len;
            context.eval_pool.values[entries_offset + index] =
                codomain.items(context.eval_pool)[selected];
        }
        context.eval_pool.values[accepted_offset + accepted_index] =
            .{ .function_v = .{
                .domain = function_domain,
                .offset = entries_offset,
                .len = function_domain.len,
            } };
        accepted_index += 1;
    }
    std.debug.assert(accepted_index == accepted_count);
    return .{ .set_v = .{
        .offset = accepted_offset,
        .len = accepted_count,
    } };
}

pub fn map_set(
    context: *CallContext,
    operator_args: []const Value,
    domain_value: Value,
    mapper: OperatorFn,
) Error!Value {
    const iterable = try iterable_for_iteration(context, domain_value);
    const count = try iterable_count(iterable);
    const mapped = try context.eval_pool.alloc_values(count);
    const mapped_offset = value_offset(context.eval_pool, mapped.ptr);
    var mapped_count: u32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const candidate = try iterable_value(context, iterable, index);
        const result_snapshot = context.eval_pool.snapshot();
        const result = try call_bound(
            context,
            operator_args,
            &.{candidate},
            mapper,
        );
        const mapped_values = context.eval_pool.values[mapped_offset..][0..count];
        var duplicate = false;
        for (mapped_values[0..mapped_count]) |existing| {
            if (existing.eql(result, context.eval_pool)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            mapped_values[mapped_count] = result;
            mapped_count += 1;
        } else {
            restore_eval_pool(context, result_snapshot);
        }
    }
    return .{ .set_v = .{
        .offset = mapped_offset,
        .len = mapped_count,
    } };
}

pub fn map_set_multi(
    context: *CallContext,
    operator_args: []const Value,
    domain_values: []const Value,
    mapper: OperatorFn,
) Error!Value {
    if (domain_values.len < 2 or
        domain_values.len > 16 or
        operator_args.len + domain_values.len > 64)
    {
        return Error.NotImplemented;
    }
    var domains: [16]Value = undefined;
    var mapped_capacity: u64 = 1;
    for (domain_values, 0..) |domain_value, index| {
        domains[index] = try iterable_for_iteration(context, domain_value);
        mapped_capacity = std.math.mul(
            u64,
            mapped_capacity,
            try iterable_count(domains[index]),
        ) catch return Error.OutOfMemory;
        if (mapped_capacity > std.math.maxInt(u32)) {
            return Error.OutOfMemory;
        }
    }
    const mapped = try context.eval_pool.alloc_values(
        @intCast(mapped_capacity),
    );
    const mapped_offset = value_offset(context.eval_pool, mapped.ptr);
    var mapped_count: u32 = 0;
    var bound: [16]Value = undefined;
    try map_set_multi_recursive(
        context,
        operator_args,
        domains[0..domain_values.len],
        mapper,
        bound[0..domain_values.len],
        0,
        mapped_offset,
        @intCast(mapped_capacity),
        &mapped_count,
    );
    std.debug.assert(mapped_count <= mapped_capacity);
    return .{ .set_v = .{
        .offset = mapped_offset,
        .len = mapped_count,
    } };
}

fn map_set_multi_recursive(
    context: *CallContext,
    operator_args: []const Value,
    domains: []const Value,
    mapper: OperatorFn,
    bound: []Value,
    depth: usize,
    mapped_offset: u32,
    mapped_capacity: u32,
    mapped_count: *u32,
) Error!void {
    if (depth == domains.len) {
        const result_snapshot = context.eval_pool.snapshot();
        const result = try call_bound(
            context,
            operator_args,
            bound,
            mapper,
        );
        const mapped_values = context.eval_pool.values[mapped_offset..][0..mapped_capacity];
        for (mapped_values[0..mapped_count.*]) |existing| {
            if (existing.eql(result, context.eval_pool)) {
                restore_eval_pool(context, result_snapshot);
                return;
            }
        }
        std.debug.assert(mapped_count.* < mapped_capacity);
        mapped_values[mapped_count.*] = result;
        mapped_count.* += 1;
        return;
    }
    const count = try iterable_count(domains[depth]);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        bound[depth] = try iterable_value(context, domains[depth], index);
        try map_set_multi_recursive(
            context,
            operator_args,
            domains,
            mapper,
            bound,
            depth + 1,
            mapped_offset,
            mapped_capacity,
            mapped_count,
        );
    }
}

pub fn function_map(
    context: *CallContext,
    operator_args: []const Value,
    domain_value: Value,
    mapper: OperatorFn,
) Error!Value {
    const iterable = try iterable_for_iteration(context, domain_value);
    const count = try iterable_count(iterable);
    const keys = try context.eval_pool.alloc_values(count);
    const keys_offset = value_offset(context.eval_pool, keys.ptr);
    const entries = try context.eval_pool.alloc_values(count);
    const entries_offset = value_offset(context.eval_pool, entries.ptr);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const key = try iterable_value(context, iterable, index);
        context.eval_pool.values[keys_offset + index] = key;
        const entry = try call_bound(
            context,
            operator_args,
            &.{key},
            mapper,
        );
        context.eval_pool.values[entries_offset + index] = entry;
    }
    return .{ .function_v = .{
        .domain = .{
            .offset = keys_offset,
            .len = count,
        },
        .offset = entries_offset,
        .len = count,
    } };
}

pub fn function_map_multi(
    context: *CallContext,
    operator_args: []const Value,
    domain_value: Value,
    arity: u16,
    mapper: OperatorFn,
) Error!Value {
    if (arity < 2) return Error.TypeError;
    if (arity > 64) return Error.NotImplemented;
    const iterable = try iterable_for_iteration(context, domain_value);
    const count = try iterable_count(iterable);
    const keys = try context.eval_pool.alloc_values(count);
    const keys_offset = value_offset(context.eval_pool, keys.ptr);
    const entries = try context.eval_pool.alloc_values(count);
    const entries_offset = value_offset(context.eval_pool, entries.ptr);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const key = try iterable_value(context, iterable, index);
        if (key != .tuple_v or key.tuple_v.len != arity) {
            return Error.TypeError;
        }
        context.eval_pool.values[keys_offset + index] = key;
        var bound_args: [64]Value = undefined;
        @memcpy(
            bound_args[0..arity],
            key.tuple_v.items(context.eval_pool),
        );
        const entry = try call_bound(
            context,
            operator_args,
            bound_args[0..arity],
            mapper,
        );
        context.eval_pool.values[entries_offset + index] = entry;
    }
    return .{ .function_v = .{
        .domain = .{
            .offset = keys_offset,
            .len = count,
        },
        .offset = entries_offset,
        .len = count,
    } };
}

pub fn let_expression(
    context: *CallContext,
    operator_args: []const Value,
    definitions: []const LetDefinition,
    body: OperatorFn,
) Error!Value {
    if (operator_args.len + definitions.len > 64) {
        return Error.NotImplemented;
    }
    var values: [64]Value = undefined;
    @memcpy(values[0..operator_args.len], operator_args);
    for (definitions, 0..) |definition, index| {
        const captures = values[0 .. operator_args.len + index];
        std.debug.assert(!definition.recursive or definition.arity > 0);
        values[operator_args.len + index] = if (definition.recursive)
            try recursive_operator(
                context,
                definition.function,
                definition.arity,
                captures,
            )
        else
            try operator(
                context,
                definition.function,
                definition.arity,
                captures,
            );
    }
    return body(
        context,
        values[0 .. operator_args.len + definitions.len],
    );
}

pub fn choose(
    context: *CallContext,
    operator_args: []const Value,
    domain_value: Value,
    predicate: OperatorFn,
    source_identity: u32,
) Error!Value {
    const iterable = try iterable_for_iteration(context, domain_value);
    const count = try iterable_count(iterable);
    var chosen: ?Value = null;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const candidate = try iterable_value(context, iterable, index);
        if (try boolean(try call_bound(
            context,
            operator_args,
            &.{candidate},
            predicate,
        ))) {
            if (chosen == null) {
                chosen = candidate;
            } else if (compare_choose_values(
                context,
                candidate,
                chosen.?,
            )) |comparison| {
                if (comparison < 0) chosen = candidate;
            }
        }
    }
    if (chosen) |value| return value;
    std.debug.print(
        "generated CHOOSE empty: expression={d} args={any} domain={d}\n",
        .{ source_identity, operator_args, count },
    );
    if (operator_args.len >= 3 and operator_args[2] == .record_v) {
        const fields = operator_args[2].record_v.fields(context.eval_pool);
        var field_index: u32 = 0;
        while (field_index < operator_args[2].record_v.len) : (field_index += 1) {
            const key = fields[field_index * 2];
            const value = fields[field_index * 2 + 1];
            if (key == .string_v) {
                if (value == .string_v) {
                    std.debug.print(
                        "  {s}=\"{s}\"\n",
                        .{
                            key.string_v.slice(context.eval_pool),
                            value.string_v.slice(context.eval_pool),
                        },
                    );
                } else {
                    std.debug.print(
                        "  {s}={any}\n",
                        .{ key.string_v.slice(context.eval_pool), value },
                    );
                }
            }
        }
    }
    return Error.EmptyChoose;
}

fn compare_choose_values(
    context: *const CallContext,
    left: Value,
    right: Value,
) ?i8 {
    if (left == .model_v) {
        if (right != .model_v) return -1;
        return switch (std.mem.order(
            u8,
            context.models.get_name(left.model_v),
            context.models.get_name(right.model_v),
        )) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }
    if (right == .model_v) return 1;
    if (left == .tuple_v and right == .tuple_v) {
        const left_items = left.tuple_v.items(context.eval_pool);
        const right_items = right.tuple_v.items(context.eval_pool);
        if (left_items.len != right_items.len) {
            return if (left_items.len < right_items.len) -1 else 1;
        }
        for (left_items, right_items) |left_item, right_item| {
            const comparison = compare_choose_values(
                context,
                left_item,
                right_item,
            ) orelse return null;
            if (comparison != 0) return comparison;
        }
        return 0;
    }
    return left.compare(right, context.eval_pool);
}

pub fn reduce_sequence(
    context: *CallContext,
    operator_args: []const Value,
    sequence: Value,
    initial: Value,
    reducer: OperatorFn,
) Error!Value {
    const length: u32 = switch (sequence) {
        .tuple_v => |tuple_value| tuple_value.len,
        .function_v => |function_value| function_value.len,
        else => return Error.TypeError,
    };
    var accumulator = initial;
    var index: u32 = 0;
    while (index < length) : (index += 1) {
        const element = try apply(
            context,
            sequence,
            .{ .int_v = @as(i64, @intCast(index)) + 1 },
        );
        accumulator = try call_bound(
            context,
            operator_args,
            &.{ element, accumulator },
            reducer,
        );
    }
    return accumulator;
}

pub fn fold_function_on_set(
    context: *CallContext,
    operator_args: []const Value,
    initial: Value,
    function: Value,
    indices_value: Value,
    reducer: OperatorFn,
) Error!Value {
    const indices = try iterable_for_iteration(context, indices_value);
    const count = try iterable_count(indices);
    var accumulator = initial;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const function_index = try iterable_value(context, indices, index);
        const mapped = try call(context, function, &.{function_index});
        accumulator = try call_bound(
            context,
            operator_args,
            &.{ mapped, accumulator },
            reducer,
        );
    }
    return accumulator;
}

pub fn sum_function_on_set(
    context: *CallContext,
    function: Value,
    indices_value: Value,
) Error!Value {
    std.debug.assert(context.eval_pool.value_count <= context.eval_pool.value_cap);
    const indices = try iterable_for_iteration(context, indices_value);
    const count = try iterable_count(indices);
    var accumulator: i64 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const function_index = try iterable_value(context, indices, index);
        const mapped = try call(context, function, &.{function_index});
        accumulator += try integer(mapped);
    }
    return .{ .int_v = accumulator };
}

test "function set fold iterates range indices without pool allocation" {
    const Arena = @import("arena.zig").Arena;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 64, 64);
    var models = try ModelTable.init(&arena, 4);
    var generated_cache = [_]?Value{};
    var context = CallContext{
        .eval_pool = &pool,
        .state_pool = &pool,
        .state = null,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &pool,
        .generated_cache_frozen = false,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 4,
    };

    const function_domain = try set(
        &context,
        &.{ .{ .int_v = 0 }, .{ .int_v = 1 }, .{ .int_v = 2 } },
    );
    const entries_offset = try pool.push_values(
        &.{ .{ .int_v = 2 }, .{ .int_v = 3 }, .{ .int_v = 4 } },
    );
    const function = Value{ .function_v = .{
        .domain = function_domain.set_v,
        .offset = entries_offset,
        .len = 3,
    } };
    const before = pool.snapshot();
    const result = try fold_function_on_set(
        &context,
        &.{},
        .{ .int_v = 0 },
        function,
        .{ .range_v = .{ .lo = 0, .hi = 2 } },
        test_add_reducer,
    );
    try std.testing.expectEqual(@as(i64, 9), result.int_v);
    try std.testing.expectEqual(before, pool.snapshot());

    const sum_result = try sum_function_on_set(
        &context,
        function,
        .{ .range_v = .{ .lo = 0, .hi = 2 } },
    );
    try std.testing.expectEqual(@as(i64, 9), sum_result.int_v);
    try std.testing.expectEqual(before, pool.snapshot());
}

pub fn select_sequence(
    context: *CallContext,
    operator_args: []const Value,
    sequence: Value,
    predicate: OperatorFn,
) Error!Value {
    const length: u32 = switch (sequence) {
        .tuple_v => |tuple_value| tuple_value.len,
        .function_v => |function_value| function_value.len,
        else => return Error.TypeError,
    };
    const result = try context.eval_pool.alloc_values(length);
    const result_offset = value_offset(context.eval_pool, result.ptr);
    var selected: u32 = 0;
    var index: u32 = 0;
    while (index < length) : (index += 1) {
        const element = try apply(
            context,
            sequence,
            .{ .int_v = @as(i64, @intCast(index)) + 1 },
        );
        if (try boolean(try call_bound(
            context,
            operator_args,
            &.{element},
            predicate,
        ))) {
            context.eval_pool.values[result_offset + selected] = element;
            selected += 1;
        }
    }
    return .{ .tuple_v = .{
        .offset = result_offset,
        .len = selected,
    } };
}

pub fn except(
    context: *CallContext,
    original: Value,
    path: []const Value,
    replacement: Value,
) Error!Value {
    if (path.len == 0) return replacement;
    return except_recursive(
        context,
        original,
        path,
        0,
        .{ .value = replacement },
    );
}

pub fn except_update(
    context: *CallContext,
    operator_args: []const Value,
    original: Value,
    path: []const Value,
    updater: OperatorFn,
) Error!Value {
    if (path.len == 0) {
        return call_bound(
            context,
            operator_args,
            &.{original},
            updater,
        );
    }
    return except_recursive(
        context,
        original,
        path,
        0,
        .{ .function = .{
            .operator_args = operator_args,
            .updater = updater,
        } },
    );
}

pub fn variable_except_update(
    context: *CallContext,
    operator_args: []const Value,
    variable_index: u32,
    path: []const Value,
    updater: OperatorFn,
) Error!Value {
    var source_pool: *const ValuePool = context.eval_pool;
    const original = if (context.read_primed)
        try resolve_primed_variable(context, variable_index, &source_pool)
    else
        try resolve_current_variable(context, variable_index, &source_pool);
    if (source_pool == context.eval_pool) {
        return except_update(
            context,
            operator_args,
            original,
            path,
            updater,
        );
    }
    return except_recursive_cross_pool(
        context,
        original,
        source_pool,
        path,
        0,
        .{ .function = .{
            .operator_args = operator_args,
            .updater = updater,
        } },
    );
}

pub fn range(left: Value, right: Value) Error!Value {
    return .{ .range_v = .{
        .lo = try integer(left),
        .hi = try integer(right),
    } };
}

pub fn member(
    context: *CallContext,
    element: Value,
    set_value: Value,
) Error!Value {
    return .{ .bool_v = try member_cross_pool(
        context,
        set_value,
        element,
        context.eval_pool,
    ) };
}

pub fn member_bool(
    context: *CallContext,
    element: Value,
    set_value: Value,
) Error!bool {
    return member_cross_pool(
        context,
        set_value,
        element,
        context.eval_pool,
    );
}

pub fn not_member(
    context: *CallContext,
    element: Value,
    set_value: Value,
) Error!Value {
    const result = try member(context, element, set_value);
    return .{ .bool_v = !result.bool_v };
}

pub fn not_member_bool(
    context: *CallContext,
    element: Value,
    set_value: Value,
) Error!bool {
    return !try member_bool(context, element, set_value);
}

pub fn string_literal_member_bool(
    context: *CallContext,
    element: Value,
    literals: []const []const u8,
) Error!bool {
    if (element != .string_v) return false;
    const bytes = element.string_v.slice(context.eval_pool);
    for (literals) |literal| {
        if (std.mem.eql(u8, bytes, literal)) return true;
    }
    return false;
}

pub fn subset_equal(
    context: *CallContext,
    left: Value,
    right: Value,
) Error!Value {
    if (!left.is_set_like() or !right.is_set_like()) {
        return Error.TypeError;
    }
    const enumerable_left = switch (left) {
        .set_v, .range_v => left,
        else => try materialize_iterable(context, left),
    };
    switch (enumerable_left) {
        .set_v => |left_set| {
            for (left_set.items(context.eval_pool)) |item| {
                if (!right.member(context.eval_pool, item)) {
                    return .{ .bool_v = false };
                }
            }
            return .{ .bool_v = true };
        },
        .range_v => |left_range| {
            if (left_range.hi < left_range.lo) {
                return .{ .bool_v = true };
            }
            var item = left_range.lo;
            while (item <= left_range.hi) : (item += 1) {
                if (!right.member(
                    context.eval_pool,
                    .{ .int_v = item },
                )) return .{ .bool_v = false };
                if (item == std.math.maxInt(i64)) break;
            }
            return .{ .bool_v = true };
        },
        else => return Error.NotImplemented,
    }
}

pub fn subset_equal_bool(
    context: *CallContext,
    left: Value,
    right: Value,
) Error!bool {
    return boolean(try subset_equal(context, left, right));
}

pub fn equivalent(left: Value, right: Value) Error!Value {
    return .{ .bool_v = (try boolean(left)) == (try boolean(right)) };
}

pub fn power(left: Value, right: Value) Error!Value {
    const base = try integer(left);
    const exponent = try integer(right);
    if (exponent < 0) return Error.DivisionByZero;
    var result: i64 = 1;
    var index: i64 = 0;
    while (index < exponent) : (index += 1) result *= base;
    return .{ .int_v = result };
}

fn value_offset(pool: *const ValuePool, pointer: [*]Value) u32 {
    const base = @intFromPtr(pool.values.ptr);
    const address = @intFromPtr(pointer);
    std.debug.assert(address >= base);
    const bytes = address - base;
    std.debug.assert(bytes % @sizeOf(Value) == 0);
    const offset: u32 = @intCast(bytes / @sizeOf(Value));
    std.debug.assert(offset <= pool.value_count);
    return offset;
}

fn sequence_item(pool: *const ValuePool, sequence: Value, index: u32) ?Value {
    return switch (sequence) {
        .tuple_v => |tuple_value| if (index < tuple_value.len)
            tuple_value.items(pool)[index]
        else
            null,
        .function_v => |function| if (index < function.len)
            function.apply(pool, .{ .int_v = @as(i64, index) + 1 })
        else
            null,
        else => null,
    };
}

fn pool_slice_offset(
    pool: *const ValuePool,
    values: []const Value,
) ?u32 {
    if (values.len == 0) return null;
    const base = @intFromPtr(pool.values.ptr);
    const end = base + pool.value_count * @sizeOf(Value);
    const address = @intFromPtr(values.ptr);
    if (address < base or address >= end) return null;
    const bytes = address - base;
    std.debug.assert(bytes % @sizeOf(Value) == 0);
    const offset: u32 = @intCast(bytes / @sizeOf(Value));
    std.debug.assert(offset + values.len <= pool.value_count);
    return offset;
}

const BinarySetKind = enum {
    cup,
    cap,
    diff,
};

fn binary_set(
    context: *CallContext,
    left: Value,
    right: Value,
    kind: BinarySetKind,
) Error!Value {
    if (!left.is_set_like() or !right.is_set_like()) {
        return Error.TypeError;
    }
    const left_offset = try context.eval_pool.push_value(left);
    const right_offset = try context.eval_pool.push_value(right);
    const value = BinarySet{
        .left_offset = left_offset,
        .right_offset = right_offset,
    };
    return switch (kind) {
        .cup => .{ .cup_v = value },
        .cap => .{ .cap_v = value },
        .diff => .{ .diff_v = value },
    };
}

fn quantify_recursive(
    context: *CallContext,
    operator_args: []const Value,
    domains: []const Value,
    kind: QuantifierKind,
    predicate: OperatorFn,
    bound: []Value,
    depth: usize,
) Error!bool {
    if (depth == domains.len) {
        return boolean(try call_bound(
            context,
            operator_args,
            bound,
            predicate,
        ));
    }
    const count = try iterable_count(domains[depth]);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        bound[depth] = try iterable_value(
            context,
            domains[depth],
            index,
        );
        const result = try quantify_recursive(
            context,
            operator_args,
            domains,
            kind,
            predicate,
            bound,
            depth + 1,
        );
        if (kind == .exists and result) return true;
        if (kind == .forall and !result) return false;
    }
    return kind == .forall;
}

fn quantify_recursive_bool(
    context: *CallContext,
    operator_args: []const Value,
    domains: []const Value,
    kind: QuantifierKind,
    predicate: OperatorBoolFn,
    bound: []Value,
    depth: usize,
) Error!bool {
    if (depth == domains.len) {
        return call_bound_bool(
            context,
            operator_args,
            bound,
            predicate,
        );
    }
    const count = try iterable_count(domains[depth]);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        bound[depth] = try iterable_value(
            context,
            domains[depth],
            index,
        );
        const result = try quantify_recursive_bool(
            context,
            operator_args,
            domains,
            kind,
            predicate,
            bound,
            depth + 1,
        );
        if (kind == .exists and result) return true;
        if (kind == .forall and !result) return false;
    }
    return kind == .forall;
}

fn call_bound(
    context: *CallContext,
    operator_args: []const Value,
    bound: []const Value,
    function: OperatorFn,
) Error!Value {
    if (operator_args.len + bound.len > 64) {
        return Error.NotImplemented;
    }
    var combined: [64]Value = undefined;
    @memcpy(combined[0..operator_args.len], operator_args);
    @memcpy(
        combined[operator_args.len..][0..bound.len],
        bound,
    );
    return function(
        context,
        combined[0 .. operator_args.len + bound.len],
    );
}

fn call_bound_bool(
    context: *CallContext,
    operator_args: []const Value,
    bound: []const Value,
    function: OperatorBoolFn,
) Error!bool {
    if (operator_args.len + bound.len > 64) {
        return Error.NotImplemented;
    }
    var combined: [64]Value = undefined;
    @memcpy(combined[0..operator_args.len], operator_args);
    @memcpy(
        combined[operator_args.len..][0..bound.len],
        bound,
    );
    return function(
        context,
        combined[0 .. operator_args.len + bound.len],
    );
}

fn iterable_for_iteration(
    context: *CallContext,
    value: Value,
) Error!Value {
    return switch (value) {
        .set_v,
        .range_v,
        => value,
        else => materialize_iterable(context, value),
    };
}

pub fn materialize_iterable(
    context: *CallContext,
    value: Value,
) Error!Value {
    return switch (value) {
        .set_v => value,
        .range_v => try materialize_range(context, value.range_v),
        .record_set_v => |record_set_value| try materialize_record_set(
            context,
            record_set_value,
        ),
        .function_set_v => |function_set_value| try materialize_function_set(
            context,
            function_set_value,
        ),
        .union_v => |union_value| try materialize_union(
            context,
            union_value.set(context.eval_pool),
        ),
        .cup_v => |binary| try materialize_binary_set(
            context,
            binary.left(context.eval_pool),
            binary.right(context.eval_pool),
            .cup,
        ),
        .cap_v => |binary| try materialize_binary_set(
            context,
            binary.left(context.eval_pool),
            binary.right(context.eval_pool),
            .cap,
        ),
        .diff_v => |binary| try materialize_binary_set(
            context,
            binary.left(context.eval_pool),
            binary.right(context.eval_pool),
            .diff,
        ),
        .power_set_v => |power_set_value| try materialize_power_set(
            context,
            power_set_value.set(context.eval_pool),
        ),
        else => Error.NotImplemented,
    };
}

fn materialize_range(
    context: *CallContext,
    range_value: @import("value.zig").Range,
) Error!Value {
    if (range_value.hi < range_value.lo) {
        const empty = try context.eval_pool.alloc_values(0);
        return .{ .set_v = .{
            .offset = value_offset(context.eval_pool, empty.ptr),
            .len = 0,
        } };
    }
    const count_i128 =
        @as(i128, range_value.hi) -
        @as(i128, range_value.lo) + 1;
    if (count_i128 > std.math.maxInt(u32)) return Error.OutOfMemory;
    const count: u32 = @intCast(count_i128);
    const items = try context.eval_pool.alloc_values(count);
    for (items, 0..) |*item, index| {
        item.* = .{
            .int_v = range_value.lo + @as(i64, @intCast(index)),
        };
    }
    return .{ .set_v = .{
        .offset = value_offset(context.eval_pool, items.ptr),
        .len = count,
    } };
}

fn materialize_record_set(
    context: *CallContext,
    record_set_value: @import("value.zig").RecordSet,
) Error!Value {
    if (record_set_value.len > 64) return Error.NotImplemented;
    var domains: [64]Value = undefined;
    var count: u64 = 1;
    var field_index: u32 = 0;
    while (field_index < record_set_value.len) : (field_index += 1) {
        domains[field_index] = try materialize_iterable(
            context,
            record_set_value.field_domain(
                context.eval_pool,
                field_index,
            ),
        );
        count = std.math.mul(
            u64,
            count,
            domains[field_index].set_v.len,
        ) catch return Error.OutOfMemory;
        if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
    }
    const records = try context.eval_pool.alloc_values(@intCast(count));
    const records_offset = value_offset(context.eval_pool, records.ptr);
    var combination: u64 = 0;
    while (combination < count) : (combination += 1) {
        const fields = try context.eval_pool.alloc_values(
            record_set_value.len * 2,
        );
        var cursor = combination;
        field_index = 0;
        while (field_index < record_set_value.len) : (field_index += 1) {
            const items = domains[field_index].set_v.items(
                context.eval_pool,
            );
            const selected: usize = @intCast(cursor % items.len);
            cursor /= items.len;
            fields[field_index * 2] = .{
                .string_v = record_set_value.field_name(
                    context.eval_pool,
                    field_index,
                ),
            };
            fields[field_index * 2 + 1] = items[selected];
        }
        const fields_offset = value_offset(context.eval_pool, fields.ptr);
        context.eval_pool.values[records_offset + combination] = .{ .record_v = .{
            .offset = fields_offset,
            .len = record_set_value.len,
        } };
    }
    return .{ .set_v = .{
        .offset = records_offset,
        .len = @intCast(count),
    } };
}

fn materialize_function_set(
    context: *CallContext,
    function_set_value: @import("value.zig").FunctionSet,
) Error!Value {
    const domain_value = try materialize_iterable(
        context,
        function_set_value.domain(context.eval_pool),
    );
    const codomain_value = try materialize_iterable(
        context,
        function_set_value.codomain(context.eval_pool),
    );
    const function_domain = domain_value.set_v;
    const codomain_items = codomain_value.set_v.items(context.eval_pool);
    var count: u64 = 1;
    var index: u32 = 0;
    while (index < function_domain.len) : (index += 1) {
        count = std.math.mul(
            u64,
            count,
            codomain_items.len,
        ) catch return Error.OutOfMemory;
        if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
    }
    const functions = try context.eval_pool.alloc_values(@intCast(count));
    const functions_offset = value_offset(
        context.eval_pool,
        functions.ptr,
    );
    var combination: u64 = 0;
    while (combination < count) : (combination += 1) {
        const entries = try context.eval_pool.alloc_values(
            function_domain.len,
        );
        var cursor = combination;
        index = 0;
        while (index < function_domain.len) : (index += 1) {
            if (codomain_items.len == 0) return Error.TypeError;
            const selected: usize = @intCast(cursor % codomain_items.len);
            cursor /= codomain_items.len;
            entries[index] = codomain_items[selected];
        }
        const entries_offset = value_offset(context.eval_pool, entries.ptr);
        context.eval_pool.values[functions_offset + combination] = .{ .function_v = .{
            .domain = function_domain,
            .offset = entries_offset,
            .len = function_domain.len,
        } };
    }
    return .{ .set_v = .{
        .offset = functions_offset,
        .len = @intCast(count),
    } };
}

fn materialize_union(
    context: *CallContext,
    outer_value: Value,
) Error!Value {
    const outer = try materialize_iterable(context, outer_value);
    if (outer.set_v.len > 256) return Error.NotImplemented;
    var inner_sets: [256]Value = undefined;
    var capacity: u64 = 0;
    for (outer.set_v.items(context.eval_pool), 0..) |inner, index| {
        inner_sets[index] = try materialize_iterable(context, inner);
        capacity += inner_sets[index].set_v.len;
        if (capacity > std.math.maxInt(u32)) return Error.OutOfMemory;
    }
    const result = try context.eval_pool.alloc_values(@intCast(capacity));
    var count: u32 = 0;
    for (inner_sets[0..outer.set_v.len]) |inner| {
        for (inner.set_v.items(context.eval_pool)) |candidate| {
            if (!contains_value(
                context.eval_pool,
                result[0..count],
                candidate,
            )) {
                result[count] = candidate;
                count += 1;
            }
        }
    }
    return .{ .set_v = .{
        .offset = value_offset(context.eval_pool, result.ptr),
        .len = count,
    } };
}

fn materialize_binary_set(
    context: *CallContext,
    left_value: Value,
    right_value: Value,
    kind: BinarySetKind,
) Error!Value {
    const left = try materialize_iterable(context, left_value);
    const right = try materialize_iterable(context, right_value);
    const capacity = switch (kind) {
        .cup => left.set_v.len + right.set_v.len,
        .cap => @min(left.set_v.len, right.set_v.len),
        .diff => left.set_v.len,
    };
    const result = try context.eval_pool.alloc_values(capacity);
    var count: u32 = 0;
    for (left.set_v.items(context.eval_pool)) |candidate| {
        const in_right = right.set_v.contains(
            context.eval_pool,
            candidate,
        );
        if (kind == .cap and !in_right) continue;
        if (kind == .diff and in_right) continue;
        result[count] = candidate;
        count += 1;
    }
    if (kind == .cup) {
        for (right.set_v.items(context.eval_pool)) |candidate| {
            if (!contains_value(
                context.eval_pool,
                result[0..count],
                candidate,
            )) {
                result[count] = candidate;
                count += 1;
            }
        }
    }
    return .{ .set_v = .{
        .offset = value_offset(context.eval_pool, result.ptr),
        .len = count,
    } };
}

fn materialize_power_set(
    context: *CallContext,
    base_value: Value,
) Error!Value {
    const base = try materialize_iterable(context, base_value);
    if (base.set_v.len > 30) return Error.OutOfMemory;
    const count: u32 = @as(u32, 1) << @intCast(base.set_v.len);
    const subsets = try context.eval_pool.alloc_values(count);
    const subsets_offset = value_offset(context.eval_pool, subsets.ptr);
    const base_items = base.set_v.items(context.eval_pool);
    var mask: u32 = 0;
    while (mask < count) : (mask += 1) {
        const items = try context.eval_pool.alloc_values(@popCount(mask));
        var item_count: u32 = 0;
        for (base_items, 0..) |item, bit| {
            if (mask & (@as(u32, 1) << @intCast(bit)) != 0) {
                items[item_count] = item;
                item_count += 1;
            }
        }
        const items_offset = value_offset(context.eval_pool, items.ptr);
        context.eval_pool.values[subsets_offset + mask] = .{ .set_v = .{
            .offset = items_offset,
            .len = item_count,
        } };
    }
    return .{ .set_v = .{
        .offset = subsets_offset,
        .len = count,
    } };
}

fn contains_value(
    pool: *const ValuePool,
    values: []const Value,
    candidate: Value,
) bool {
    for (values) |existing| {
        if (existing.eql(candidate, pool)) return true;
    }
    return false;
}

fn except_recursive(
    context: *CallContext,
    original: Value,
    path: []const Value,
    depth: usize,
    update: ExceptUpdate,
) Error!Value {
    if (depth == path.len) {
        return switch (update) {
            .value => |replacement| replacement,
            .function => |function| call_bound(
                context,
                function.operator_args,
                &.{original},
                function.updater,
            ),
        };
    }
    const key = path[depth];
    return switch (original) {
        .function_v => |function_value| blk: {
            const selected = function_value.apply(
                context.eval_pool,
                key,
            ) orelse return Error.IndexOutOfBounds;
            const updated = try except_recursive(
                context,
                selected,
                path,
                depth + 1,
                update,
            );
            const entries = try context.eval_pool.alloc_values(
                function_value.len,
            );
            @memcpy(
                entries,
                function_value.entries(context.eval_pool),
            );
            const keys = function_value.domain.items(context.eval_pool);
            var index: u32 = 0;
            while (index < function_value.len) : (index += 1) {
                if (keys[index].eql(key, context.eval_pool)) {
                    entries[index] = updated;
                    break;
                }
            }
            break :blk .{ .function_v = .{
                .domain = function_value.domain,
                .offset = value_offset(context.eval_pool, entries.ptr),
                .len = function_value.len,
            } };
        },
        .tuple_v => |tuple_value| blk: {
            const item_index = key.as_int() orelse return Error.TypeError;
            if (item_index < 1 or item_index > tuple_value.len) {
                return Error.IndexOutOfBounds;
            }
            const selected_index: usize = @intCast(item_index - 1);
            const updated = try except_recursive(
                context,
                tuple_value.items(context.eval_pool)[selected_index],
                path,
                depth + 1,
                update,
            );
            const items = try context.eval_pool.alloc_values(
                tuple_value.len,
            );
            @memcpy(items, tuple_value.items(context.eval_pool));
            items[selected_index] = updated;
            break :blk .{ .tuple_v = .{
                .offset = value_offset(context.eval_pool, items.ptr),
                .len = tuple_value.len,
            } };
        },
        .record_v => |record_value| blk: {
            if (key != .string_v) return Error.TypeError;
            const original_fields = record_value.fields(context.eval_pool);
            var selected: ?u32 = null;
            var search_index: u32 = 0;
            while (search_index < record_value.len) : (search_index += 1) {
                if (original_fields[search_index * 2].string_v.eql(
                    key.string_v,
                    context.eval_pool,
                )) {
                    selected = search_index;
                    break;
                }
            }
            const selected_index = selected orelse
                return Error.UndefinedSymbol;
            const updated = try except_recursive(
                context,
                record_value.fields(
                    context.eval_pool,
                )[selected_index * 2 + 1],
                path,
                depth + 1,
                update,
            );
            const fields = try context.eval_pool.alloc_values(
                record_value.len * 2,
            );
            @memcpy(fields, record_value.fields(context.eval_pool));
            fields[selected_index * 2 + 1] = updated;
            break :blk .{ .record_v = .{
                .offset = value_offset(context.eval_pool, fields.ptr),
                .len = record_value.len,
            } };
        },
        else => Error.TypeError,
    };
}

fn except_recursive_cross_pool(
    context: *CallContext,
    original: Value,
    source_pool: *const ValuePool,
    path: []const Value,
    depth: usize,
    update: ExceptUpdate,
) Error!Value {
    if (depth == path.len) {
        const original_local = try original.clone(
            source_pool,
            context.eval_pool,
        );
        return switch (update) {
            .value => |replacement| replacement,
            .function => |function| call_bound(
                context,
                function.operator_args,
                &.{original_local},
                function.updater,
            ),
        };
    }

    const key = path[depth];
    return switch (original) {
        .function_v => |function_value| blk: {
            const source_keys = function_value.domain.items(source_pool);
            const source_entries = function_value.entries(source_pool);
            var selected: ?usize = null;
            for (source_keys, 0..) |source_key, index| {
                if (Value.eql_cross_pool(
                    source_key,
                    source_pool,
                    key,
                    context.eval_pool,
                )) {
                    selected = index;
                    break;
                }
            }
            const selected_index = selected orelse
                return Error.IndexOutOfBounds;
            const updated = try except_recursive_cross_pool(
                context,
                source_entries[selected_index],
                source_pool,
                path,
                depth + 1,
                update,
            );

            const keys = try context.eval_pool.alloc_values(function_value.len);
            const keys_offset = value_offset(context.eval_pool, keys.ptr);
            const entries = try context.eval_pool.alloc_values(function_value.len);
            const entries_offset = value_offset(context.eval_pool, entries.ptr);
            for (source_keys, 0..) |source_key, index| {
                const cloned = try source_key.clone(
                    source_pool,
                    context.eval_pool,
                );
                context.eval_pool.values[keys_offset + index] = cloned;
            }
            for (source_entries, 0..) |source_entry, index| {
                const cloned = if (index == selected_index)
                    updated
                else
                    try source_entry.clone(source_pool, context.eval_pool);
                context.eval_pool.values[entries_offset + index] = cloned;
            }
            break :blk .{ .function_v = .{
                .domain = .{
                    .offset = keys_offset,
                    .len = function_value.len,
                },
                .offset = entries_offset,
                .len = function_value.len,
            } };
        },
        .tuple_v => |tuple_value| blk: {
            const item_index = key.as_int() orelse return Error.TypeError;
            if (item_index < 1 or item_index > tuple_value.len) {
                return Error.IndexOutOfBounds;
            }
            const selected_index: usize = @intCast(item_index - 1);
            const source_items = tuple_value.items(source_pool);
            const updated = try except_recursive_cross_pool(
                context,
                source_items[selected_index],
                source_pool,
                path,
                depth + 1,
                update,
            );

            const items = try context.eval_pool.alloc_values(tuple_value.len);
            const items_offset = value_offset(context.eval_pool, items.ptr);
            for (source_items, 0..) |source_item, index| {
                const cloned = if (index == selected_index)
                    updated
                else
                    try source_item.clone(source_pool, context.eval_pool);
                context.eval_pool.values[items_offset + index] = cloned;
            }
            break :blk .{ .tuple_v = .{
                .offset = items_offset,
                .len = tuple_value.len,
            } };
        },
        .record_v => |record_value| blk: {
            if (key != .string_v) return Error.TypeError;
            const source_fields = record_value.fields(source_pool);
            var selected: ?usize = null;
            var field_index: usize = 0;
            while (field_index < record_value.len) : (field_index += 1) {
                if (std.mem.eql(
                    u8,
                    source_fields[field_index * 2].string_v.slice(source_pool),
                    key.string_v.slice(context.eval_pool),
                )) {
                    selected = field_index;
                    break;
                }
            }
            const selected_index = selected orelse
                return Error.UndefinedSymbol;
            const selected_offset = selected_index * 2 + 1;
            const updated = try except_recursive_cross_pool(
                context,
                source_fields[selected_offset],
                source_pool,
                path,
                depth + 1,
                update,
            );

            const fields = try context.eval_pool.alloc_values(record_value.len * 2);
            const fields_offset = value_offset(context.eval_pool, fields.ptr);
            for (source_fields, 0..) |source_field, index| {
                const cloned = if (index == selected_offset)
                    updated
                else
                    try source_field.clone(source_pool, context.eval_pool);
                context.eval_pool.values[fields_offset + index] = cloned;
            }
            break :blk .{ .record_v = .{
                .offset = fields_offset,
                .len = record_value.len,
            } };
        },
        else => Error.TypeError,
    };
}

const ExceptUpdate = union(enum) {
    value: Value,
    function: struct {
        operator_args: []const Value,
        updater: OperatorFn,
    },
};

pub fn iterable_count(domain_value: Value) Error!u32 {
    return switch (domain_value) {
        .set_v => |set_value| set_value.len,
        .range_v => |range_value| blk: {
            if (range_value.hi < range_value.lo) break :blk 0;
            const count =
                @as(i128, range_value.hi) -
                @as(i128, range_value.lo) + 1;
            if (count > std.math.maxInt(u32)) {
                return Error.OutOfMemory;
            }
            break :blk @intCast(count);
        },
        else => Error.NotImplemented,
    };
}

pub fn iterable_value(
    context: *CallContext,
    domain_value: Value,
    index: u32,
) Error!Value {
    return switch (domain_value) {
        .set_v => |set_value| blk: {
            if (index >= set_value.len) return Error.IndexOutOfBounds;
            break :blk set_value.items(context.eval_pool)[index];
        },
        .range_v => |range_value| blk: {
            const count = try iterable_count(domain_value);
            if (index >= count) return Error.IndexOutOfBounds;
            break :blk .{
                .int_v = range_value.lo + @as(i64, @intCast(index)),
            };
        },
        else => Error.NotImplemented,
    };
}

fn iterable_value_from_pool(
    context: *CallContext,
    domain_value: Value,
    domain_pool: *const ValuePool,
    index: u32,
) Error!Value {
    std.debug.assert(context.eval_pool.value_count <= context.eval_pool.value_cap);
    std.debug.assert(domain_pool.value_count <= domain_pool.value_cap);
    return switch (domain_value) {
        .set_v => |set_value| blk: {
            if (index >= set_value.len) return Error.IndexOutOfBounds;
            const item = set_value.items(domain_pool)[index];
            break :blk switch (item) {
                .bool_v,
                .int_v,
                .model_v,
                .generated_operator_v,
                .lambda_v,
                => item,
                else => try item.clone(domain_pool, context.eval_pool),
            };
        },
        .range_v => |range_value| blk: {
            const count = try iterable_count(domain_value);
            if (index >= count) return Error.IndexOutOfBounds;
            break :blk .{
                .int_v = range_value.lo + @as(i64, @intCast(index)),
            };
        },
        else => Error.NotImplemented,
    };
}

test "materialized variable cache follows value-pool restores" {
    const Arena = @import("arena.zig").Arena;
    var source_arena = try Arena.init(1024 * 1024);
    defer source_arena.deinit();
    var eval_arena = try Arena.init(1024 * 1024);
    defer eval_arena.deinit();
    var source_pool = try ValuePool.init(&source_arena, 64, 64);
    var eval_pool = try ValuePool.init(&eval_arena, 64, 64);
    var models = try ModelTable.init(&source_arena, 4);
    var generated_cache = [_]?Value{};

    const status = Value{ .string_v = try source_pool.push_string("ready") };
    const tuple_offset = try source_pool.push_values(&.{status});
    const set_offset = try source_pool.push_values(&.{
        .{ .int_v = 1 },
        .{ .int_v = 2 },
    });
    const tuple_value = Value{ .tuple_v = .{
        .offset = tuple_offset,
        .len = 1,
    } };
    var state_values = [_]Value{
        tuple_value,
        .{ .set_v = .{ .offset = set_offset, .len = 2 } },
        .{ .int_v = 2 },
        .{ .int_v = 3 },
        tuple_value,
    };
    var current_state = State{
        .level = 0,
        .pred = 0,
        .changed_mask = 0,
        .borrowed_pool = null,
        .values = &state_values,
    };
    var context = CallContext{
        .eval_pool = &eval_pool,
        .state_pool = &source_pool,
        .state = &current_state,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &eval_pool,
        .generated_cache_frozen = false,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 4,
    };

    const empty = eval_pool.snapshot();
    try std.testing.expect(try variable_contains_bool(
        &context,
        1,
        .{ .int_v = 2 },
    ));
    try std.testing.expectEqual(empty, eval_pool.snapshot());
    const first = try variable(&context, 0);
    const cached = eval_pool.snapshot();
    const second = try variable(&context, 0);
    try std.testing.expect(value_same_representation(first, second));
    try std.testing.expectEqual(cached, eval_pool.snapshot());

    _ = try variable(&context, 4);
    const two_variables_cached = eval_pool.snapshot();
    _ = try variable(&context, 0);
    try std.testing.expectEqual(two_variables_cached, eval_pool.snapshot());

    _ = try eval_pool.push_value(.{ .int_v = 7 });
    restore_eval_pool(&context, cached);
    try std.testing.expect(context.materialized_variable_cache_mask != 0);
    _ = try variable(&context, 0);
    try std.testing.expectEqual(cached, eval_pool.snapshot());

    restore_eval_pool(&context, empty);
    try std.testing.expectEqual(
        @as(MaterializedVariableCacheMask, 0),
        context.materialized_variable_cache_mask,
    );
    _ = try variable(&context, 0);
    try std.testing.expectEqual(cached, eval_pool.snapshot());
}

test "state path operators apply without cloning intermediate functions" {
    const Arena = @import("arena.zig").Arena;
    var source_arena = try Arena.init(1024 * 1024);
    defer source_arena.deinit();
    var eval_arena = try Arena.init(1024 * 1024);
    defer eval_arena.deinit();
    var source_pool = try ValuePool.init(&source_arena, 64, 64);
    var eval_pool = try ValuePool.init(&eval_arena, 64, 64);
    var models = try ModelTable.init(&source_arena, 4);
    var generated_cache = [_]?Value{};

    const inner_domain = try source_pool.push_values(&.{.{ .int_v = 2 }});
    const inner_entries = try source_pool.push_values(&.{.{ .int_v = 99 }});
    const inner = Value{ .function_v = .{
        .domain = .{ .offset = inner_domain, .len = 1 },
        .offset = inner_entries,
        .len = 1,
    } };
    const outer_domain = try source_pool.push_values(&.{.{ .int_v = 1 }});
    const outer_entries = try source_pool.push_values(&.{inner});
    const type_name = Value{
        .string_v = try source_pool.push_string("type"),
    };
    const type_value = Value{
        .string_v = try source_pool.push_string("open"),
    };
    const block_fields = try source_pool.push_values(&.{
        type_name,
        type_value,
    });
    const block = Value{ .record_v = .{
        .offset = block_fields,
        .len = 1,
    } };
    const block_name = Value{
        .string_v = try source_pool.push_string("block"),
    };
    const signed_fields = try source_pool.push_values(&.{
        block_name,
        block,
    });
    const signed = Value{ .record_v = .{
        .offset = signed_fields,
        .len = 1,
    } };
    const signed_domain = try source_pool.push_values(&.{.{ .int_v = 1 }});
    const signed_entries = try source_pool.push_values(&.{signed});
    var state_values = [_]Value{
        .{ .function_v = .{
            .domain = .{ .offset = outer_domain, .len = 1 },
            .offset = outer_entries,
            .len = 1,
        } },
        .{ .function_v = .{
            .domain = .{ .offset = signed_domain, .len = 1 },
            .offset = signed_entries,
            .len = 1,
        } },
    };
    var current_state = State{
        .level = 0,
        .pred = 0,
        .changed_mask = 0,
        .borrowed_pool = null,
        .values = &state_values,
    };
    var context = CallContext{
        .eval_pool = &eval_pool,
        .state_pool = &source_pool,
        .state = &current_state,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &eval_pool,
        .generated_cache_frozen = false,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 4,
    };

    const path = try state_path_operator(
        &context,
        0,
        &.{.{ .int_v = 1 }},
        1,
    );
    try std.testing.expect(
        arguments_contain_state_path_operator(&.{path}),
    );
    try std.testing.expect(arguments_contain_generated_operator(&.{path}));
    try std.testing.expect(
        !arguments_contain_state_path_operator(&.{.{ .int_v = 1 }}),
    );
    try std.testing.expect(
        !arguments_contain_generated_operator(&.{.{ .int_v = 1 }}),
    );
    try std.testing.expectEqual(@as(u32, 4), eval_pool.value_count);
    try std.testing.expectEqual(
        Value{ .int_v = 99 },
        try call(&context, path, &.{.{ .int_v = 2 }}),
    );
    try std.testing.expectEqual(@as(u32, 4), eval_pool.value_count);

    const record_path = try state_path_operator(&context, 1, &.{}, 1);
    const before_projection = eval_pool.snapshot();
    const projected = try call_field_path(
        &context,
        record_path,
        &.{.{ .int_v = 1 }},
        &.{ "block", "type" },
    );
    try std.testing.expectEqualStrings(
        "open",
        projected.string_v.slice(&eval_pool),
    );
    try std.testing.expectEqual(
        before_projection.value_count,
        eval_pool.value_count,
    );
}

test "power set membership accepts symbolic range state values across pools" {
    const Arena = @import("arena.zig").Arena;
    var state_arena = try Arena.init(1024 * 1024);
    defer state_arena.deinit();
    var eval_arena = try Arena.init(1024 * 1024);
    defer eval_arena.deinit();
    var state_pool = try ValuePool.init(&state_arena, 64, 64);
    var eval_pool = try ValuePool.init(&eval_arena, 64, 64);
    var models = try ModelTable.init(&state_arena, 4);
    var generated_cache = [_]?Value{};

    var state_values = [_]Value{Value{ .range_v = .{ .lo = 1, .hi = 4 } }};
    var current_state = State{
        .level = 0,
        .pred = 0,
        .changed_mask = 0,
        .borrowed_pool = null,
        .values = &state_values,
    };
    var context = CallContext{
        .eval_pool = &eval_pool,
        .state_pool = &state_pool,
        .state = &current_state,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &eval_pool,
        .generated_cache_frozen = false,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 4,
    };

    const base = Value{ .range_v = .{ .lo = 1, .hi = 4 } };
    const subsets = try power_set(&context, base);
    try std.testing.expect(try variable_member_bool(&context, 0, subsets));
    try std.testing.expect(try member_bool(
        &context,
        Value{ .range_v = .{ .lo = 2, .hi = 3 } },
        subsets,
    ));
    try std.testing.expect(!try member_bool(
        &context,
        Value{ .range_v = .{ .lo = 0, .hi = 3 } },
        subsets,
    ));
}

test "set union preserves record sets with unbounded nested domains" {
    const Arena = @import("arena.zig").Arena;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 256, 256);
    var models = try ModelTable.init(&arena, 4);
    var generated_cache = [_]?Value{};
    var context = CallContext{
        .eval_pool = &pool,
        .state_pool = &pool,
        .state = null,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &pool,
        .generated_cache_frozen = false,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 4,
    };

    const token_messages = try record_set(&context, &.{
        try string(&context, "type"),
        try set(&context, &.{try string(&context, "tok")}),
        try string(&context, "q"),
        try int_set(&context),
    });
    const basic_messages = try record_set(&context, &.{
        try string(&context, "type"),
        try set(&context, &.{try string(&context, "pl")}),
    });
    const messages = try set_union(
        &context,
        token_messages,
        basic_messages,
    );
    try std.testing.expect(messages == .cup_v);

    const token = try record_static(
        &context,
        &.{ "type", "q" },
        &.{ try string(&context, "tok"), .{ .int_v = 42 } },
    );
    const basic = try record_static(
        &context,
        &.{"type"},
        &.{try string(&context, "pl")},
    );
    const invalid = try record_static(
        &context,
        &.{"type"},
        &.{try string(&context, "other")},
    );
    try std.testing.expect(try member_bool(&context, token, messages));
    try std.testing.expect(try member_bool(&context, basic, messages));
    try std.testing.expect(!try member_bool(&context, invalid, messages));
}

test "set union materializes finite record sets on demand" {
    const Arena = @import("arena.zig").Arena;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 512, 512);
    var models = try ModelTable.init(&arena, 4);
    var generated_cache = [_]?Value{};
    var context = CallContext{
        .eval_pool = &pool,
        .state_pool = &pool,
        .state = null,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &pool,
        .generated_cache_frozen = false,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 4,
    };

    const left = try record_set(&context, &.{
        try string(&context, "type"),
        try set(&context, &.{try string(&context, "left")}),
        try string(&context, "id"),
        Value{ .range_v = .{ .lo = 1, .hi = 2 } },
    });
    const right = try record_set(&context, &.{
        try string(&context, "type"),
        try set(&context, &.{try string(&context, "right")}),
    });
    const union_value = try set_union(&context, left, right);
    try std.testing.expect(union_value == .cup_v);

    const left_member = try record_static(
        &context,
        &.{ "type", "id" },
        &.{ try string(&context, "left"), .{ .int_v = 2 } },
    );
    const right_member = try record_static(
        &context,
        &.{"type"},
        &.{try string(&context, "right")},
    );
    try std.testing.expect(try member_bool(&context, left_member, union_value));
    try std.testing.expect(try member_bool(&context, right_member, union_value));
    try std.testing.expectEqual(
        Value{ .int_v = 3 },
        try cardinality(&context, &.{union_value}),
    );
}

test "fused EXCEPT equality localizes nested updater operands" {
    const Arena = @import("arena.zig").Arena;
    var state_arena = try Arena.init(1024 * 1024);
    defer state_arena.deinit();
    var eval_arena = try Arena.init(1024 * 1024);
    defer eval_arena.deinit();
    var state_pool = try ValuePool.init(&state_arena, 128, 64);
    var eval_pool = try ValuePool.init(&eval_arena, 128, 64);
    var models = try ModelTable.init(&state_arena, 4);
    var generated_cache = [_]?Value{};

    const person = Value{ .model_v = try models.intern("person") };
    const waiting_name = Value{
        .string_v = try state_pool.push_string("waiting"),
    };
    const current_fields_offset = try state_pool.push_values(&.{
        waiting_name,
        .{ .bool_v = false },
    });
    const next_fields_offset = try state_pool.push_values(&.{
        waiting_name,
        .{ .bool_v = true },
    });
    const current_record = Value{ .record_v = .{
        .offset = current_fields_offset,
        .len = 1,
    } };
    const next_record = Value{ .record_v = .{
        .offset = next_fields_offset,
        .len = 1,
    } };
    const domain_offset = try state_pool.push_values(&.{person});
    const current_entries_offset = try state_pool.push_values(&.{current_record});
    const next_entries_offset = try state_pool.push_values(&.{next_record});
    const function_domain = Set{ .offset = domain_offset, .len = 1 };

    var current_values = [_]Value{.{ .function_v = .{
        .domain = function_domain,
        .offset = current_entries_offset,
        .len = 1,
    } }};
    var next_values = [_]Value{.{ .function_v = .{
        .domain = function_domain,
        .offset = next_entries_offset,
        .len = 1,
    } }};
    var current_state = State{
        .level = 0,
        .pred = 0,
        .changed_mask = 0,
        .borrowed_pool = null,
        .values = &current_values,
    };
    var next_state = State{
        .level = 1,
        .pred = 0,
        .changed_mask = 1,
        .borrowed_pool = null,
        .values = &next_values,
    };
    var context = CallContext{
        .eval_pool = &eval_pool,
        .state_pool = &state_pool,
        .state = &current_state,
        .next_state = &next_state,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &eval_pool,
        .generated_cache_frozen = false,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 4,
    };

    try std.testing.expect(try primed_variable_except_update_path_equal_bool(
        &context,
        &.{person},
        0,
        &.{.{ .value = person }},
        test_nested_record_updater,
    ));
}

fn test_nested_record_updater(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    std.debug.assert(args.len == 2);
    return except_update(
        context,
        args,
        args[1],
        &.{try string(context, "waiting")},
        test_waiting_true_updater,
    );
}

fn test_waiting_true_updater(
    _: *CallContext,
    args: []const Value,
) Error!Value {
    std.debug.assert(args.len == 3);
    return .{ .bool_v = true };
}

fn value_same_representation(left: Value, right: Value) bool {
    return @import("value.zig").same_repr(left, right);
}

test "generated finite values use only the value pool" {
    const Arena = @import("arena.zig").Arena;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 256, 256);
    var models = try ModelTable.init(&arena, 16);
    var generated_cache = [_]?Value{};
    var context = CallContext{
        .eval_pool = &pool,
        .state_pool = &pool,
        .state = null,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &pool,
        .generated_cache_frozen = false,
        .models = &models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 5,
    };

    var current_values = [_]Value{ .{ .int_v = 1 }, .{ .int_v = 2 } };
    var next_values = [_]Value{ .{ .int_v = 1 }, .{ .int_v = 2 } };
    var current_state = State{
        .level = 0,
        .pred = 0,
        .changed_mask = 0,
        .borrowed_pool = null,
        .values = current_values[0..],
    };
    var next_state = State{
        .level = 1,
        .pred = 0,
        .changed_mask = 0,
        .borrowed_pool = null,
        .values = next_values[0..],
    };
    context.state = &current_state;
    context.next_state = &next_state;
    try std.testing.expect(try unchanged_variables(&context, &.{ 0, 1 }));
    next_state.changed_mask = @as(u64, 1) << 1;
    try std.testing.expect(try unchanged_variable(&context, 1));
    // A canonical state's changed mask belongs to its stored witness edge,
    // not necessarily to the edge currently replayed by temporal checking.
    next_state.changed_mask = 0;
    next_values[1] = .{ .int_v = 3 };
    try std.testing.expect(!try unchanged_variable(&context, 1));
    next_values[1] = .{ .int_v = 2 };

    const partial_values = [_]Value{ .{ .int_v = 1 }, .{ .int_v = 4 } };
    context.partial_mask = @as(u64, 1) << 1;
    context.partial_values = &partial_values;
    context.partial_value_pools = &.{ null, null };
    try std.testing.expect(!try unchanged_variable(&context, 1));
    context.partial_mask = 0;
    context.partial_values = &.{};
    context.partial_value_pools = &.{};
    context.state = null;
    context.next_state = null;

    const finite_set = try set(
        &context,
        &.{ .{ .int_v = 1 }, .{ .int_v = 2 }, .{ .int_v = 1 } },
    );
    try std.testing.expectEqual(@as(u32, 2), finite_set.set_v.len);
    try std.testing.expect(
        (try member(&context, .{ .int_v = 2 }, finite_set)).bool_v,
    );
    try std.testing.expect(
        (try subset_equal(
            &context,
            try range(.{ .int_v = 1 }, .{ .int_v = 2 }),
            finite_set,
        )).bool_v,
    );

    var source_arena = try Arena.init(1024 * 1024);
    defer source_arena.deinit();
    var source_pool = try ValuePool.init(&source_arena, 256, 256);
    var source_models = try ModelTable.init(&source_arena, 16);
    var source_generated_cache = [_]?Value{};
    var source_context = CallContext{
        .eval_pool = &source_pool,
        .state_pool = &source_pool,
        .state = null,
        .next_state = null,
        .partial_mask = 0,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &source_generated_cache,
        .generated_cache_pool = &source_pool,
        .generated_cache_frozen = false,
        .models = &source_models,
        .native_context = undefined,
        .native_call = test_native_call,
        .max_seq_len = 5,
    };
    const duplicate_a = try tuple(&source_context, &.{.{ .int_v = 9 }});
    const duplicate_b = try tuple(&source_context, &.{.{ .int_v = 9 }});
    const source_values = try source_pool.alloc_values(2);
    source_values[0] = duplicate_a;
    source_values[1] = duplicate_b;
    const before_range_values = pool.value_count;
    const cross_pool_range = try set_cross_pool(
        &context,
        source_values,
        &source_pool,
    );
    try std.testing.expectEqual(@as(u32, 1), cross_pool_range.set_v.len);
    try std.testing.expectEqual(
        before_range_values + 3,
        pool.value_count,
    );

    const unsorted_int_items = [_]Value{
        .{ .int_v = 5 },
        .{ .int_v = 1 },
    };
    const unsorted_int_offset = try source_pool.push_values(
        &unsorted_int_items,
    );
    const unsorted_int_set = Value{ .set_v = .{
        .offset = unsorted_int_offset,
        .len = unsorted_int_items.len,
    } };
    try std.testing.expect(try set_member_cross_pool(
        unsorted_int_set,
        &source_pool,
        .{ .int_v = 1 },
        &pool,
    ));
    try std.testing.expect(!try set_member_cross_pool(
        unsorted_int_set,
        &source_pool,
        .{ .int_v = 4 },
        &pool,
    ));

    const before_mapped_values = pool.value_count;
    const filtered_range = try filter_at(
        &context,
        &.{},
        try range(.{ .int_v = 1 }, .{ .int_v = 3 }),
        always_true_predicate,
        0,
    );
    try std.testing.expectEqual(@as(u32, 3), filtered_range.set_v.len);
    try std.testing.expectEqual(
        before_mapped_values + 3,
        pool.value_count,
    );

    const before_duplicate_map_values = pool.value_count;
    const mapped_duplicates = try map_set(
        &context,
        &.{},
        try range(.{ .int_v = 1 }, .{ .int_v = 3 }),
        duplicate_tuple_mapper,
    );
    try std.testing.expectEqual(@as(u32, 1), mapped_duplicates.set_v.len);
    // Three output slots and one accepted tuple payload. The range is not
    // materialized, and duplicate tuple payloads are restored.
    try std.testing.expectEqual(
        before_duplicate_map_values + 4,
        pool.value_count,
    );

    const finite_record = try record(
        &context,
        &.{
            try string(&context, "field"),
            .{ .int_v = 7 },
        },
    );
    const static_record = try record_static(
        &context,
        &.{"field"},
        &.{.{ .int_v = 7 }},
    );
    try std.testing.expect(static_record.eql(finite_record, &pool));
    try std.testing.expectEqual(
        @as(i64, 7),
        (try field(&context, finite_record, "field")).int_v,
    );
    try std.testing.expectEqual(
        @as(i64, 7),
        (try field(&context, static_record, "field")).int_v,
    );

    const left_sequence = try tuple(
        &context,
        &.{ .{ .int_v = 1 }, .{ .int_v = 2 } },
    );
    const right_sequence = try tuple(
        &context,
        &.{.{ .int_v = 3 }},
    );
    const concatenated = try sequence_concat(
        &context,
        left_sequence,
        right_sequence,
    );
    try std.testing.expectEqual(@as(u32, 3), concatenated.tuple_v.len);
    try std.testing.expectEqual(
        @as(i64, 3),
        concatenated.tuple_v.items(&pool)[2].int_v,
    );

    const singleton = try record_to(
        &context,
        .{ .int_v = 1 },
        .{ .int_v = 10 },
    );
    const replacement = try record_to(
        &context,
        .{ .int_v = 1 },
        .{ .int_v = 20 },
    );
    const overridden_function = try override(
        &context,
        singleton,
        replacement,
    );
    try std.testing.expectEqual(
        @as(i64, 20),
        overridden_function.function_v.apply(
            &pool,
            .{ .int_v = 1 },
        ).?.int_v,
    );

    const replacement_record = try record(
        &context,
        &.{
            try string(&context, "field"),
            .{ .int_v = 9 },
        },
    );
    const overridden_record = try override(
        &context,
        finite_record,
        replacement_record,
    );
    try std.testing.expectEqual(
        @as(i64, 9),
        (try field(&context, overridden_record, "field")).int_v,
    );

    const z_model = Value{ .model_v = try models.intern("z") };
    const a_model = Value{ .model_v = try models.intern("a") };
    const z_tuple = try tuple(&context, &.{ z_model, .{ .int_v = 1 } });
    const a_tuple = try tuple(&context, &.{ a_model, .{ .int_v = 1 } });
    const forward_domain = try set(&context, &.{ z_tuple, a_tuple });
    const reverse_domain = try set(&context, &.{ a_tuple, z_tuple });
    const forward_choice = try choose(
        &context,
        &.{},
        forward_domain,
        always_true_predicate,
        1,
    );
    const reverse_choice = try choose(
        &context,
        &.{},
        reverse_domain,
        always_true_predicate,
        2,
    );
    try std.testing.expect(forward_choice.eql(reverse_choice, &pool));
    try std.testing.expectEqual(
        a_model.model_v,
        forward_choice.tuple_v.items(&pool)[0].model_v,
    );
}

fn always_true_predicate(
    _: *CallContext,
    args: []const Value,
) Error!Value {
    std.debug.assert(args.len == 1);
    return .{ .bool_v = true };
}

fn duplicate_tuple_mapper(
    context: *CallContext,
    args: []const Value,
) Error!Value {
    std.debug.assert(args.len == 1);
    return tuple(context, &.{.{ .int_v = 9 }});
}

fn test_add_reducer(_: *CallContext, args: []const Value) Error!Value {
    std.debug.assert(args.len == 2);
    return add(args[0], args[1]);
}

fn test_native_call(
    _: *const anyopaque,
    _: *ValuePool,
    _: []const u8,
    _: []const Value,
    _: ?*State,
) Error!Value {
    return Error.UndefinedSymbol;
}

pub fn boolean(value: Value) Error!bool {
    return switch (value) {
        .bool_v => |boolean_v| boolean_v,
        else => Error.TypeError,
    };
}

pub fn integer(value: Value) Error!i64 {
    return value.as_int() orelse Error.TypeError;
}

pub fn negate(value: Value) Error!Value {
    return .{ .int_v = -(try integer(value)) };
}

pub fn logical_not(value: Value) Error!Value {
    return .{ .bool_v = !(try boolean(value)) };
}

pub fn add(left: Value, right: Value) Error!Value {
    return .{ .int_v = try integer(left) + try integer(right) };
}

pub fn subtract(left: Value, right: Value) Error!Value {
    return .{ .int_v = try integer(left) - try integer(right) };
}

pub fn multiply(left: Value, right: Value) Error!Value {
    return .{ .int_v = try integer(left) * try integer(right) };
}

pub fn divide(left: Value, right: Value) Error!Value {
    const divisor = try integer(right);
    if (divisor == 0) return Error.TypeError;
    return .{ .int_v = @divFloor(try integer(left), divisor) };
}

pub fn modulo(left: Value, right: Value) Error!Value {
    const divisor = try integer(right);
    if (divisor == 0) return Error.TypeError;
    return .{ .int_v = @mod(try integer(left), divisor) };
}

pub fn equal(pool: *const ValuePool, left: Value, right: Value) Value {
    return .{ .bool_v = left.eql(right, pool) };
}

pub fn equal_bool(
    pool: *const ValuePool,
    left: Value,
    right: Value,
) Error!bool {
    return left.eql(right, pool);
}

pub fn not_equal(pool: *const ValuePool, left: Value, right: Value) Value {
    const result = equal(pool, left, right);
    return .{ .bool_v = !result.bool_v };
}

pub fn not_equal_bool(
    pool: *const ValuePool,
    left: Value,
    right: Value,
) Error!bool {
    return !left.eql(right, pool);
}

pub fn less_than(pool: *const ValuePool, left: Value, right: Value) Error!Value {
    const order = left.compare(right, pool) orelse return Error.TypeError;
    return .{ .bool_v = order < 0 };
}

pub fn less_than_bool(
    pool: *const ValuePool,
    left: Value,
    right: Value,
) Error!bool {
    return (left.compare(right, pool) orelse return Error.TypeError) < 0;
}

pub fn less_equal(pool: *const ValuePool, left: Value, right: Value) Error!Value {
    const order = left.compare(right, pool) orelse return Error.TypeError;
    return .{ .bool_v = order <= 0 };
}

pub fn less_equal_bool(
    pool: *const ValuePool,
    left: Value,
    right: Value,
) Error!bool {
    return (left.compare(right, pool) orelse return Error.TypeError) <= 0;
}

pub fn greater_than(pool: *const ValuePool, left: Value, right: Value) Error!Value {
    const order = left.compare(right, pool) orelse return Error.TypeError;
    return .{ .bool_v = order > 0 };
}

pub fn greater_than_bool(
    pool: *const ValuePool,
    left: Value,
    right: Value,
) Error!bool {
    return (left.compare(right, pool) orelse return Error.TypeError) > 0;
}

pub fn greater_equal(pool: *const ValuePool, left: Value, right: Value) Error!Value {
    const order = left.compare(right, pool) orelse return Error.TypeError;
    return .{ .bool_v = order >= 0 };
}

pub fn greater_equal_bool(
    pool: *const ValuePool,
    left: Value,
    right: Value,
) Error!bool {
    return (left.compare(right, pool) orelse return Error.TypeError) >= 0;
}
