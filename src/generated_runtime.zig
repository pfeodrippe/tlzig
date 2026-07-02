const std = @import("std");
const Value = @import("value.zig").Value;
const ValuePool = @import("value.zig").ValuePool;
const Set = @import("value.zig").Set;
const BinarySet = @import("value.zig").BinarySet;
const Function = @import("value.zig").Function;
const State = @import("state.zig").StateStore.State;
const Error = @import("err.zig").Error;

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
    ) Error!Value;

    eval_pool: *ValuePool,
    state_pool: *ValuePool,
    state: ?*State,
    next_state: ?*State,
    partial_values: []const ?Value,
    partial_value_pools: []const ?*const ValuePool,
    read_primed: bool,
    constants: []const NamedValue,
    constant_slots: []const ?Value,
    generated_cache: []?Value,
    generated_cache_pool: *ValuePool,
    native_context: *const anyopaque,
    native_call: NativeCall,
    max_seq_len: u32,
};

pub const OperatorFn = *const fn (*CallContext, []const Value) Error!Value;
pub const OperatorBoolFn = *const fn (*CallContext, []const Value) Error!bool;

pub const PathKey = union(enum) {
    value: Value,
    field: []const u8,
};

pub const QuantifierKind = enum {
    exists,
    forall,
};

pub const LetDefinition = struct {
    function: OperatorFn,
    arity: u16,
};

pub const Operator = struct {
    name: []const u8,
    arity: u16,
    function: ?OperatorFn,
};

pub const Expression = struct {
    identity: u32,
    arg_names: []const []const u8,
    arg_required: []const bool = &.{},
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
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_current_variable(context, index, &source_pool);
    return value.clone(source_pool, context.eval_pool);
}

fn resolve_current_variable(
    context: *CallContext,
    index: u32,
    source_pool: **const ValuePool,
) Error!Value {
    source_pool.* = context.eval_pool;
    const current = context.state orelse {
        if (index < context.partial_values.len) {
            if (context.partial_values[index]) |value| {
                if (index < context.partial_value_pools.len) {
                    source_pool.* = context.partial_value_pools[index] orelse
                        context.eval_pool;
                }
                return value;
            }
        }
        return Error.TypeError;
    };
    if (index >= current.values.len) return Error.TypeError;
    source_pool.* = current.value_pool(index, context.state_pool);
    return current.values[index];
}

pub fn primed_variable(context: *CallContext, index: u32) Error!Value {
    var source_pool: *const ValuePool = context.eval_pool;
    const value = try resolve_primed_variable(context, index, &source_pool);
    return value.clone(source_pool, context.eval_pool);
}

fn resolve_primed_variable(
    context: *CallContext,
    index: u32,
    source_pool: **const ValuePool,
) Error!Value {
    source_pool.* = context.eval_pool;
    if (index < context.partial_values.len) {
        if (context.partial_values[index]) |value| {
            if (index < context.partial_value_pools.len) {
                source_pool.* = context.partial_value_pools[index] orelse
                    context.eval_pool;
            }
            return value;
        }
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
    const current = context.state orelse return Error.TypeError;
    const next = context.next_state orelse return Error.TypeError;
    if (index >= current.values.len or index >= next.values.len) {
        return Error.TypeError;
    }
    if (index < 64 and
        (next.changed_mask & (@as(u64, 1) << @intCast(index))) == 0)
    {
        return true;
    }
    return Value.eql_cross_pool(
        current.values[index],
        current.value_pool(index, context.state_pool),
        next.values[index],
        next.value_pool(index, context.state_pool),
    );
}

pub fn unchanged_variables(
    context: *CallContext,
    indices: []const u32,
) Error!bool {
    const current = context.state orelse return Error.TypeError;
    const next = context.next_state orelse return Error.TypeError;
    for (indices) |index| {
        if (index >= current.values.len or index >= next.values.len) {
            return Error.TypeError;
        }
        if (index < 64 and
            (next.changed_mask & (@as(u64, 1) << @intCast(index))) == 0)
        {
            continue;
        }
        if (!Value.eql_cross_pool(
            current.values[index],
            current.value_pool(index, context.state_pool),
            next.values[index],
            next.value_pool(index, context.state_pool),
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
        return Error.UndefinedSymbol;
    }
    const value = context.constant_slots[index] orelse
        return Error.UndefinedSymbol;
    return value.clone(context.state_pool, context.eval_pool);
}

pub fn cached_definition(
    context: *CallContext,
    index: u32,
) Error!?Value {
    if (index >= context.generated_cache.len) return Error.TypeError;
    const value = context.generated_cache[index] orelse return null;
    return try value.clone(context.generated_cache_pool, context.eval_pool);
}

pub fn put_cached_definition(
    context: *CallContext,
    index: u32,
    value: Value,
) Error!Value {
    if (index >= context.generated_cache.len) return Error.TypeError;
    if (context.generated_cache[index]) |_| return value;
    context.generated_cache[index] = try value.clone(
        context.eval_pool,
        context.generated_cache_pool,
    );
    return value;
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
    if (args.len != 1) return Error.TypeError;
    return apply(context, function, args[0]);
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
        if (record_value.generated_operator_v.arity != 0) return Error.TypeError;
        return try field(context, try call(context, record_value, &.{}), name);
    }
    if (record_value != .record_v) return Error.TypeError;
    const fields = record_value.record_v.fields(context.eval_pool);
    var index: u32 = 0;
    while (index < record_value.record_v.len) : (index += 1) {
        if (std.mem.eql(
            u8,
            fields[index * 2].string_v.slice(context.eval_pool),
            name,
        )) return fields[index * 2 + 1];
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
    const materialized = try materialize_iterable(context, set_value);
    if (materialized != .set_v) return Error.TypeError;
    const items = materialized.set_v.items(context.eval_pool);
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
        const replacement = try call_bound(
            context,
            operator_args,
            &.{current},
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
            const replacement = try call_bound(
                context,
                operator_args,
                &.{current},
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
            const replacement = try call_bound(
                context,
                operator_args,
                &.{current},
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
        const replacement = try call_bound(
            context,
            operator_args,
            &.{current},
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
            const replacement = try call_bound(
                context,
                operator_args,
                &.{current},
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
            const replacement = try call_bound(
                context,
                operator_args,
                &.{current},
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
        function_pool,
        key,
        key_pool,
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

fn resolve_path(
    context: *CallContext,
    index: u32,
    keys: []const Value,
    source_pool: **const ValuePool,
) Error!Value {
    source_pool.* = context.eval_pool;
    var value: Value = undefined;

    if (context.read_primed) {
        if (index < context.partial_values.len and
            context.partial_values[index] != null)
        {
            value = context.partial_values[index].?;
            if (index < context.partial_value_pools.len) {
                source_pool.* = context.partial_value_pools[index] orelse
                    context.eval_pool;
            }
        } else if (context.next_state) |next| {
            if (index >= next.values.len) return Error.TypeError;
            value = next.values[index];
            source_pool.* = next.value_pool(index, context.state_pool);
        } else if (context.state) |current| {
            if (index >= current.values.len) return Error.TypeError;
            value = current.values[index];
            source_pool.* = current.value_pool(index, context.state_pool);
        } else {
            return Error.TypeError;
        }
    } else if (context.state) |current| {
        if (index >= current.values.len) return Error.TypeError;
        value = current.values[index];
        source_pool.* = current.value_pool(index, context.state_pool);
    } else {
        var partial_value = try current_variable(context, index);
        for (keys) |key| partial_value = try apply(context, partial_value, key);
        source_pool.* = context.eval_pool;
        return partial_value;
    }

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

fn apply_cross_pool(
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
                function_pool,
                key,
                key_pool,
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

fn function_dense_entry_probe(
    keys: []const Value,
    entries: []const Value,
    function_pool: *const ValuePool,
    key: Value,
    key_pool: *const ValuePool,
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
    if (!cross_pool_equal(keys[index_u], function_pool, key, key_pool)) {
        return null;
    }
    return entries[index_u];
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
    return materialize_binary_set(context, left, right, .cup);
}

pub fn set_intersection(
    context: *CallContext,
    left: Value,
    right: Value,
) Error!Value {
    return materialize_binary_set(context, left, right, .cap);
}

pub fn set_difference(
    context: *CallContext,
    left: Value,
    right: Value,
) Error!Value {
    return materialize_binary_set(context, left, right, .diff);
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
    const function_domain: Set = switch (domain_value) {
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
        const accepted = try boolean(try call_bound(
            context,
            operator_args,
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
                context.eval_pool.restore(iteration_snapshot);
                return .{ .bool_v = true };
            }
            if (kind == .forall and !result) {
                context.eval_pool.restore(iteration_snapshot);
                return .{ .bool_v = false };
            }
        }
        context.eval_pool.restore(iteration_snapshot);
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

    context.eval_pool.restore(iteration_snapshot);
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
    context.eval_pool.restore(snapshot);
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
            var duplicate = false;
            for (accepted_values[0..accepted_count]) |existing| {
                if (existing.eql(candidate, context.eval_pool)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                accepted_values[accepted_count] = candidate;
                accepted_count += 1;
            }
        }
    }
    return .{ .set_v = .{
        .offset = accepted_offset,
        .len = accepted_count,
    } };
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
        context.eval_pool.restore(scratch);
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
            context.eval_pool.restore(result_snapshot);
        }
    }
    return .{ .set_v = .{
        .offset = mapped_offset,
        .len = mapped_count,
    } };
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
        values[operator_args.len + index] =
            if (definition.arity == 0)
                try definition.function(context, captures)
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
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const candidate = try iterable_value(context, iterable, index);
        if (try boolean(try call_bound(
            context,
            operator_args,
            &.{candidate},
            predicate,
        ))) return candidate;
    }
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
    if (!set_value.is_set_like()) return Error.TypeError;
    return .{ .bool_v = set_value.member(context.eval_pool, element) };
}

pub fn member_bool(
    context: *CallContext,
    element: Value,
    set_value: Value,
) Error!bool {
    if (!set_value.is_set_like()) return Error.TypeError;
    return set_value.member(context.eval_pool, element);
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
    switch (left) {
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

test "generated finite values use only the value pool" {
    const Arena = @import("arena.zig").Arena;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 256, 256);
    var generated_cache = [_]?Value{};
    var context = CallContext{
        .eval_pool = &pool,
        .state_pool = &pool,
        .state = null,
        .next_state = null,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &generated_cache,
        .generated_cache_pool = &pool,
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
        .borrowed_mask = 0,
        .borrowed_pool = null,
        .values = current_values[0..],
    };
    var next_state = State{
        .level = 1,
        .pred = 0,
        .changed_mask = 0,
        .borrowed_mask = 0,
        .borrowed_pool = null,
        .values = next_values[0..],
    };
    context.state = &current_state;
    context.next_state = &next_state;
    try std.testing.expect(try unchanged_variables(&context, &.{ 0, 1 }));
    next_state.changed_mask = @as(u64, 1) << 1;
    try std.testing.expect(try unchanged_variable(&context, 1));
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
    var source_generated_cache = [_]?Value{};
    var source_context = CallContext{
        .eval_pool = &source_pool,
        .state_pool = &source_pool,
        .state = null,
        .next_state = null,
        .partial_values = &.{},
        .partial_value_pools = &.{},
        .read_primed = false,
        .constants = &.{},
        .constant_slots = &.{},
        .generated_cache = &source_generated_cache,
        .generated_cache_pool = &source_pool,
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

fn test_native_call(
    _: *const anyopaque,
    _: *ValuePool,
    _: []const u8,
    _: []const Value,
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
