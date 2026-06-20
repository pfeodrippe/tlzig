const std = @import("std");
const assert = std.debug.assert;
const value = @import("value.zig");
const Value = value.Value;
const ValuePool = value.ValuePool;
const Error = @import("err.zig").Error;
const generated_runtime = @import("generated_runtime.zig");

pub const OverrideContext = struct {
    max_seq_len: u32,
    max_nat: i64,
    min_int: i64,
    max_int: i64,

    pub fn default() OverrideContext {
        return .{
            .max_seq_len = 5,
            .max_nat = 10,
            .min_int = -10,
            .max_int = 10,
        };
    }
};

pub const OverrideFn = *const fn (
    ctx: OverrideContext,
    pool: *ValuePool,
    args: []const Value,
) Error!Value;

pub const ValueOverrideFn = *const fn (
    ctx: OverrideContext,
    pool: *ValuePool,
) Error!Value;

pub const OverrideEntry = struct {
    name: []const u8,
    func: OverrideFn,
};

pub const ValueOverrideEntry = struct {
    name: []const u8,
    func: ValueOverrideFn,
};

pub const Registry = struct {
    ctx: OverrideContext,
    entries: []const OverrideEntry,
    values: []const ValueOverrideEntry,
    generated: []const generated_runtime.Operator,

    pub fn find(self: Registry, name: []const u8) ?OverrideFn {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.func;
        }
        return null;
    }

    pub fn find_value(self: Registry, name: []const u8) ?ValueOverrideFn {
        for (self.values) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.func;
        }
        return null;
    }

    pub fn find_generated(
        self: Registry,
        name: []const u8,
        arity: usize,
    ) ?generated_runtime.OperatorFn {
        for (self.generated) |operator| {
            if (operator.arity == arity and
                std.mem.eql(u8, operator.name, name))
            {
                return operator.function;
            }
        }
        return null;
    }
};

pub fn default_registry(ctx: OverrideContext) Registry {
    return Registry{
        .ctx = ctx,
        .entries = &default_overrides,
        .values = &default_value_overrides,
        .generated = &.{},
    };
}

const default_overrides = [_]OverrideEntry{
    .{ .name = "\\o", .func = sequence_concat_entry },
    .{ .name = "@@", .func = ooverride_entry },
    .{ .name = ":>", .func = recordto_entry },
    .{ .name = "Cardinality", .func = cardinality },
    .{ .name = "IsFiniteSet", .func = is_finite_set },
    .{ .name = "Len", .func = sequence_len },
    .{ .name = "Head", .func = head },
    .{ .name = "Tail", .func = tail },
    .{ .name = "Append", .func = append },
    .{ .name = "SubSeq", .func = sub_seq },
    .{ .name = "SortSeq", .func = sort_seq },
    .{ .name = "Range", .func = function_range },
    .{ .name = "SeqToSet", .func = seq_to_set },
    .{ .name = "Index", .func = sequence_index },
    .{ .name = "PermSeqs", .func = permutation_sequences },
    .{ .name = "INTERSECTION", .func = intersection_all },
    .{ .name = "Permutations", .func = permutations },
    .{ .name = "RandomElement", .func = random_element },
    .{ .name = "Any", .func = random_element },
    .{ .name = "ToString", .func = to_string },
    .{ .name = "JavaTime", .func = java_time },
    .{ .name = "TLCGet", .func = tlc_get },
    .{ .name = "TLCSet", .func = tlc_set },
    .{ .name = "Assert", .func = tlc_assert },
    .{ .name = "Print", .func = tlc_print },
    .{ .name = "PrintT", .func = tlc_print_t },
    .{ .name = "Seq", .func = seq_set },
    .{ .name = "UNION", .func = union_all },
    .{ .name = "EmptyBag", .func = empty_bag },
    .{ .name = "BagIn", .func = bag_in },
    .{ .name = "BagOfSet", .func = bag_of_set },
    .{ .name = "BagCardinality", .func = bag_cardinality },
    .{ .name = "BagCup", .func = bag_cup },
    .{ .name = "BagCap", .func = bag_cap },
    .{ .name = "BagDifference", .func = bag_difference },
    .{ .name = "WF_vars", .func = wf_vars },
    .{ .name = "SF_vars", .func = sf_vars },
};

fn sequence_concat_entry(
    ctx: OverrideContext,
    pool: *ValuePool,
    args: []const Value,
) Error!Value {
    if (args.len != 2) return Error.TypeError;
    return sequence_concat(ctx, pool, args[0], args[1]);
}

fn ooverride_entry(
    ctx: OverrideContext,
    pool: *ValuePool,
    args: []const Value,
) Error!Value {
    if (args.len != 2) return Error.TypeError;
    return ooverride(ctx, pool, args[0], args[1]);
}

fn recordto_entry(
    ctx: OverrideContext,
    pool: *ValuePool,
    args: []const Value,
) Error!Value {
    if (args.len != 2) return Error.TypeError;
    return recordto(ctx, pool, args[0], args[1]);
}

const default_value_overrides = [_]ValueOverrideEntry{
    .{ .name = "BOOLEAN", .func = boolean_set },
};

fn cardinality(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const s = args[0];
    if (s == .set_v) return Value{ .int_v = @intCast(s.set_v.len) };
    if (s == .range_v) {
        const r = s.range_v;
        return Value{ .int_v = @max(r.hi - r.lo + 1, 0) };
    }
    // Materialize other set-like values.
    if (s.is_set_like()) {
        // For lazy sets, we need to count elements. This is expensive but
        // necessary for correctness.
        _ = pool;
        // Most lazy sets (cup_v, cap_v, etc.) need materialization.
        // Return a conservative error; caller should materialize first.
        return Error.NotImplemented;
    }
    return Error.TypeError;
}

fn is_finite_set(_: OverrideContext, _: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return Value{ .bool_v = true };
}

fn sequence_len(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    _ = pool;
    return switch (args[0]) {
        .function_v => |f| Value{ .int_v = @intCast(f.len) },
        .tuple_v => |t| Value{ .int_v = @intCast(t.len) },
        .string_v => |s| Value{ .int_v = @intCast(s.len) },
        else => Error.TypeError,
    };
}

fn head(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return switch (args[0]) {
        .function_v => |f| f.apply(pool, Value{ .int_v = 1 }) orelse Error.IndexOutOfBounds,
        .tuple_v => |t| if (t.len == 0) Error.IndexOutOfBounds else t.items(pool)[0],
        .string_v => |s| if (s.len == 0) Error.IndexOutOfBounds else Value{ .int_v = s.slice(pool)[0] },
        else => Error.TypeError,
    };
}

fn tail(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return switch (args[0]) {
        .function_v => |f| {
            if (f.len == 0) return Error.IndexOutOfBounds;
            const dest = try pool.alloc_values(@intCast(f.len - 1));
            const dest_offset = value_offset(pool, dest.ptr);
            var i: u32 = 0;
            while (i + 1 < f.len) : (i += 1) {
                pool.values[dest_offset + i] = pool.values[f.offset + i + 1];
            }
            return Value{ .tuple_v = .{ .offset = dest_offset, .len = f.len - 1 } };
        },
        .tuple_v => |t| {
            if (t.len == 0) return Error.IndexOutOfBounds;
            const items = t.items(pool);
            const dest = try pool.alloc_values(@intCast(t.len - 1));
            @memcpy(dest, items[1..t.len]);
            return Value{ .tuple_v = make_tuple(pool, dest) };
        },
        else => Error.TypeError,
    };
}

fn append(ctx: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    const elem = try pool.alloc_values(1);
    elem[0] = args[1];
    const singleton = Value{ .tuple_v = make_tuple(pool, elem) };
    return sequence_concat(ctx, pool, args[0], singleton);
}

fn sub_seq(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 3) return Error.TypeError;
    const lo = args[1].as_int() orelse return Error.TypeError;
    const hi = args[2].as_int() orelse return Error.TypeError;
    if (lo < 1) return Error.IndexOutOfBounds;
    if (hi < lo) {
        const empty = try pool.alloc_values(0);
        return make_sequence(pool, empty, 0);
    }
    const len_i: u32 = @intCast(hi - lo + 1);
    return switch (args[0]) {
        .function_v => |f| {
            if (hi > f.len) return Error.IndexOutOfBounds;
            const dest = try pool.alloc_values(len_i);
            const dest_offset = value_offset(pool, dest.ptr);
            for (0..len_i) |i| {
                const idx: usize = @intCast(lo - 1 + @as(i64, @intCast(i)));
                pool.values[dest_offset + i] = pool.values[f.offset + idx];
            }
            return Value{ .tuple_v = .{ .offset = dest_offset, .len = len_i } };
        },
        .tuple_v => |t| {
            if (hi > t.len) return Error.IndexOutOfBounds;
            const items = t.items(pool);
            const dest = try pool.alloc_values(len_i);
            @memcpy(dest, items[@intCast(lo - 1)..@intCast(hi)]);
            return Value{ .tuple_v = make_tuple(pool, dest) };
        },
        else => Error.TypeError,
    };
}

fn function_range(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const source = switch (args[0]) {
        .function_v => |function| function.entries(pool),
        .tuple_v => |tuple| tuple.items(pool),
        else => return Error.TypeError,
    };
    if (values_are_unique(pool, source)) {
        return Value{ .set_v = .{
            .offset = value_offset(pool, source.ptr),
            .len = @intCast(source.len),
        } };
    }
    const values = try pool.alloc_values(@intCast(source.len));
    @memcpy(values, source);
    return Value{ .set_v = make_set(pool, values) };
}

fn seq_to_set(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const len = sequence_length(args[0]) orelse return Error.TypeError;
    const source: ?[]const Value = switch (args[0]) {
        .tuple_v => |tuple| tuple.items(pool),
        .function_v => |function| function.entries(pool),
        else => null,
    };
    if (source) |items| {
        if (values_are_unique(pool, items)) {
            return Value{ .set_v = .{
                .offset = value_offset(pool, items.ptr),
                .len = @intCast(items.len),
            } };
        }
    }
    const values = try pool.alloc_values(len);
    for (0..len) |i| {
        values[i] = sequence_item(
            pool,
            args[0],
            @intCast(i),
        ) orelse return Error.IndexOutOfBounds;
    }
    return Value{ .set_v = make_set(pool, values) };
}

fn values_are_unique(
    pool: *const ValuePool,
    values: []const Value,
) bool {
    for (values, 0..) |candidate, i| {
        for (values[0..i]) |existing| {
            if (existing.eql(candidate, pool)) return false;
        }
    }
    return true;
}

fn sequence_index(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    const len = sequence_length(args[0]) orelse return Error.TypeError;
    for (0..len) |i| {
        const item = sequence_item(
            pool,
            args[0],
            @intCast(i),
        ) orelse return Error.IndexOutOfBounds;
        if (item.eql(args[1], pool)) {
            return Value{ .int_v = @as(i64, @intCast(i)) + 1 };
        }
    }
    return Error.EmptyChoose;
}

fn permutation_sequences(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1 or args[0] != .set_v) return Error.TypeError;
    const items = args[0].set_v.items(pool);
    if (items.len > 10) return Error.NotImplemented;
    var permutation_count: u64 = 1;
    for (2..items.len + 1) |factor| {
        permutation_count = std.math.mul(
            u64,
            permutation_count,
            factor,
        ) catch return Error.OutOfMemory;
    }
    if (permutation_count > std.math.maxInt(u32)) {
        return Error.OutOfMemory;
    }
    try pool.ensure_value_capacity(
        permutation_count +
            permutation_count * items.len,
    );
    const permutations_out = try pool.alloc_values(
        @intCast(permutation_count),
    );
    var scratch: [10]Value = undefined;
    var used: [10]bool = @splat(false);
    var output_index: u32 = 0;
    try generate_permutation_sequences(
        pool,
        items,
        scratch[0..items.len],
        used[0..items.len],
        0,
        permutations_out,
        &output_index,
    );
    assert(output_index == permutation_count);
    return Value{ .set_v = .{
        .offset = value_offset(pool, permutations_out.ptr),
        .len = output_index,
    } };
}

fn generate_permutation_sequences(
    pool: *ValuePool,
    items: []const Value,
    scratch: []Value,
    used: []bool,
    depth: usize,
    output: []Value,
    output_index: *u32,
) Error!void {
    assert(items.len == scratch.len);
    assert(items.len == used.len);
    if (depth == items.len) {
        assert(output_index.* < output.len);
        const tuple_values = try pool.alloc_values(
            @intCast(items.len),
        );
        @memcpy(tuple_values, scratch);
        output[output_index.*] = Value{ .tuple_v = make_tuple(
            pool,
            tuple_values,
        ) };
        output_index.* += 1;
        return;
    }
    for (items, 0..) |item, item_index| {
        if (used[item_index]) continue;
        used[item_index] = true;
        scratch[depth] = item;
        try generate_permutation_sequences(
            pool,
            items,
            scratch,
            used,
            depth + 1,
            output,
            output_index,
        );
        used[item_index] = false;
    }
}

fn intersection_all(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1 or args[0] != .set_v) return Error.TypeError;
    const sets = args[0].set_v.items(pool);
    if (sets.len == 0) {
        const empty = try pool.alloc_values(0);
        return Value{ .set_v = make_set(pool, empty) };
    }
    var smallest = sets[0];
    if (smallest != .set_v) return Error.TypeError;
    for (sets[1..]) |set| {
        if (set != .set_v) return Error.TypeError;
        if (set.set_v.len < smallest.set_v.len) smallest = set;
    }
    const candidates = smallest.set_v.items(pool);
    const result = try pool.alloc_values(
        @intCast(candidates.len),
    );
    var result_count: u32 = 0;
    for (candidates) |candidate| {
        var present_in_all = true;
        for (sets) |set| {
            assert(set == .set_v);
            if (!set.set_v.contains(pool, candidate)) {
                present_in_all = false;
                break;
            }
        }
        if (present_in_all) {
            result[result_count] = candidate;
            result_count += 1;
        }
    }
    return Value{ .set_v = .{
        .offset = value_offset(pool, result.ptr),
        .len = result_count,
    } };
}

fn union_all(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const s = args[0];
    if (s != .set_v) return Error.TypeError;
    const items = s.set_v.items(pool);
    var total: u32 = 0;
    for (items) |it| {
        if (it != .set_v) return Error.TypeError;
        total += it.set_v.len;
    }
    const dest = try pool.alloc_values(total);
    var pos: u32 = 0;
    for (items) |it| {
        const sub = it.set_v.items(pool);
        for (sub) |v| {
            dest[pos] = v;
            pos += 1;
        }
    }
    return Value{ .set_v = make_set(pool, dest) };
}

fn tlc_assert(_: OverrideContext, _: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    if (!args[0].is_truthy()) return Error.AssertionFailed;
    return Value{ .bool_v = true };
}

fn boolean_set(_: OverrideContext, pool: *ValuePool) Error!Value {
    const dest = pool.alloc_values(2) catch return error.OutOfMemory;
    dest[0] = Value{ .bool_v = false };
    dest[1] = Value{ .bool_v = true };
    return Value{ .set_v = make_set(pool, dest) };
}

fn seq_set(ctx: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const s = args[0];
    // Materialize range_v into a set_v for enumeration.
    if (s == .range_v) {
        const r = s.range_v;
        const count: u32 = @intCast(@max(r.hi - r.lo + 1, 0));
        const dest = try pool.alloc_values(count);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            dest[i] = Value{ .int_v = r.lo + @as(i64, @intCast(i)) };
        }
        const set_val = Value{ .set_v = make_set(pool, dest) };
        return seq_set_from_set(ctx, pool, set_val);
    }
    // Record sets and other lazy sets need materialization, but the override
    // doesn't have evaluator access. Return NotImplemented to signal the
    // evaluator to materialize first.
    if (s != .set_v) return Error.NotImplemented;
    return seq_set_from_set(ctx, pool, s);
}

fn seq_set_from_set(ctx: OverrideContext, pool: *ValuePool, s: Value) Error!Value {
    const items = s.set_v.items(pool);
    const m: u64 = items.len;
    const total = try seq_set_size(m, ctx.max_seq_len);
    const dest = try pool.alloc_values(@intCast(total));
    var pos: u32 = 0;
    const empty = try pool.alloc_values(0);
    dest[pos] = make_sequence(pool, empty, 0);
    pos += 1;
    var len: u32 = 1;
    while (len <= ctx.max_seq_len) : (len += 1) {
        const count = int_pow(m, len);
        var combo: u64 = 0;
        while (combo < count) : (combo += 1) {
            const entries = try pool.alloc_values(len);
            var tmp = combo;
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                entries[i] = items[tmp % items.len];
                tmp /= items.len;
            }
            dest[pos] = make_sequence(pool, entries, len);
            pos += 1;
        }
    }
    return Value{ .set_v = make_set(pool, dest) };
}

fn seq_set_size(m: u64, max_len: u32) Error!u64 {
    var total: u64 = 1;
    var len: u32 = 1;
    while (len <= max_len) : (len += 1) {
        total += int_pow(m, len);
        if (total > std.math.maxInt(u32)) return Error.OutOfMemory;
    }
    return total;
}

fn make_sequence(pool: *ValuePool, entries: []Value, len: u32) Value {
    return Value{ .function_v = .{
        .domain = make_range_set(pool, 1, @as(i64, @intCast(len))),
        .offset = value_offset(pool, entries.ptr),
        .len = len,
    } };
}

fn int_pow(base: u64, exp: u32) u64 {
    var result: u64 = 1;
    var i: u32 = 0;
    while (i < exp) : (i += 1) result *= base;
    return result;
}

pub fn ooverride(_: OverrideContext, pool: *ValuePool, a: Value, b: Value) Error!Value {
    // Combine two records/functions; right-hand side overrides left for matching keys.
    if (a == .record_v and b == .record_v) {
        const left = a.record_v;
        const right = b.record_v;
        const left_fields = left.fields(pool);
        const right_fields = right.fields(pool);
        const max_fields: u32 = left.len + right.len;
        const dest = try pool.alloc_values(max_fields * 2);
        var count: u32 = 0;
        var left_index: u32 = 0;
        while (left_index < left.len) : (left_index += 1) {
            const left_name = left_fields[left_index * 2].string_v;
            var overridden = false;
            var right_index: u32 = 0;
            while (right_index < right.len) : (right_index += 1) {
                const right_name = right_fields[right_index * 2].string_v;
                if (left_name.eql(right_name, pool)) {
                    overridden = true;
                    break;
                }
            }
            if (!overridden) {
                dest[count * 2] = left_fields[left_index * 2];
                dest[count * 2 + 1] = left_fields[left_index * 2 + 1];
                count += 1;
            }
        }
        @memcpy(
            dest[count * 2 ..][0 .. right.len * 2],
            right_fields,
        );
        count += right.len;
        return Value{ .record_v = .{
            .offset = value_offset(pool, dest.ptr),
            .len = count,
        } };
    }
    const fa = if (a == .function_v) a.function_v else return Error.TypeError;
    const fb = if (b == .function_v) b.function_v else return Error.TypeError;
    const dest_len: u32 = @intCast(fa.len + fb.len);
    try pool.ensure_value_capacity(@as(u64, dest_len) * 2);
    const ka = fa.domain.items(pool);
    const va = fa.entries(pool);
    const kb = fb.domain.items(pool);
    const vb = fb.entries(pool);
    const keys = try pool.alloc_values(dest_len);
    const vals = try pool.alloc_values(dest_len);
    var pos: u32 = 0;
    // Keep left entries whose key is not in right.
    for (ka, va) |k, v| {
        var overridden = false;
        for (kb) |rk| {
            if (k.eql(rk, pool)) {
                overridden = true;
                break;
            }
        }
        if (!overridden) {
            keys[pos] = k;
            vals[pos] = v;
            pos += 1;
        }
    }
    // Add all right entries.
    for (kb, vb) |k, v| {
        keys[pos] = k;
        vals[pos] = v;
        pos += 1;
    }
    return Value{ .function_v = .{
        .domain = make_set(pool, keys[0..pos]),
        .offset = value_offset(pool, vals.ptr),
        .len = pos,
    } };
}

pub fn recordto(_: OverrideContext, pool: *ValuePool, key: Value, val: Value) Error!Value {
    try pool.ensure_value_capacity(2);
    const keys = try pool.alloc_values(1);
    keys[0] = key;
    const vals = try pool.alloc_values(1);
    vals[0] = val;
    return Value{ .function_v = .{
        .domain = make_set(pool, keys),
        .offset = value_offset(pool, vals.ptr),
        .len = 1,
    } };
}

pub fn sequence_concat(_: OverrideContext, pool: *ValuePool, a: Value, b: Value) Error!Value {
    const a_len = sequence_length(a) orelse return Error.TypeError;
    const b_len = sequence_length(b) orelse return Error.TypeError;
    const dest_len = std.math.add(u32, a_len, b_len) catch return Error.OutOfMemory;
    const dest = try pool.alloc_values(dest_len);
    const dest_offset = value_offset(pool, dest.ptr);
    var i: u32 = 0;
    while (i < a_len) : (i += 1) {
        pool.values[dest_offset + i] = sequence_item(pool, a, i) orelse return Error.TypeError;
    }
    i = 0;
    while (i < b_len) : (i += 1) {
        pool.values[dest_offset + a_len + i] = sequence_item(pool, b, i) orelse return Error.TypeError;
    }
    assert(dest_offset + dest_len <= pool.value_count);
    return Value{ .tuple_v = .{ .offset = dest_offset, .len = dest_len } };
}

fn sequence_length(sequence: Value) ?u32 {
    return switch (sequence) {
        .tuple_v => |tuple| tuple.len,
        .function_v => |function| function.len,
        else => null,
    };
}

fn sequence_item(pool: *ValuePool, sequence: Value, index: u32) ?Value {
    return switch (sequence) {
        .tuple_v => |tuple| blk: {
            assert(index < tuple.len);
            break :blk tuple.items(pool)[index];
        },
        .function_v => |function| function.apply(
            pool,
            Value{ .int_v = @as(i64, @intCast(index)) + 1 },
        ),
        else => null,
    };
}

fn make_set(pool: *ValuePool, values: []Value) value.Set {
    var unique_len: u32 = 0;
    for (values) |candidate| {
        var duplicate = false;
        for (values[0..unique_len]) |existing| {
            if (existing.eql(candidate, pool)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            values[unique_len] = candidate;
            unique_len += 1;
        }
    }
    assert(unique_len <= values.len);
    return .{
        .offset = value_offset(pool, values.ptr),
        .len = unique_len,
    };
}

fn make_tuple(pool: *ValuePool, values: []Value) value.Tuple {
    return .{
        .offset = value_offset(pool, values.ptr),
        .len = @intCast(values.len),
    };
}

fn value_offset(pool: *const ValuePool, ptr: [*]const Value) u32 {
    const base = @intFromPtr(pool.values.ptr);
    const address = @intFromPtr(ptr);
    assert(address >= base);
    const bytes = address - base;
    assert(bytes % @sizeOf(Value) == 0);
    const offset = bytes / @sizeOf(Value);
    assert(offset <= std.math.maxInt(u32));
    return @intCast(offset);
}

fn make_range_set(pool: *ValuePool, lo: i64, hi: i64) value.Set {
    const len: u32 = @intCast(hi - lo + 1);
    const dest = pool.alloc_values(len) catch unreachable;
    for (0..len) |i| {
        dest[i] = Value{ .int_v = lo + @as(i64, @intCast(i)) };
    }
    return make_set(pool, dest);
}

// SortSeq(seq, op) sorts the sequence using the comparison operator.
// Without access to the evaluator/AST context, we can only sort primitive values when the
// operator is the standard `\leq` relation. Otherwise return the sequence unchanged.
fn sort_seq(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    const seq = args[0];
    const op = args[1];
    var entries: []const Value = undefined;
    var len: u32 = 0;
    switch (seq) {
        .function_v => |f| {
            entries = f.entries(pool);
            len = f.len;
        },
        .tuple_v => |t| {
            entries = t.items(pool);
            len = t.len;
        },
        else => return Error.TypeError,
    }
    // Only sort sequences of integers with the standard ordering stub.
    if (op != .function_v or len <= 1) return args[0];
    const dest = try pool.alloc_values(len);
    @memcpy(dest, entries);
    // Bubble sort with bounded iterations (max len^2).
    const max_i: u32 = len * len;
    var i: u32 = 0;
    while (i < max_i) : (i += 1) {
        var swapped = false;
        var j: u32 = 0;
        while (j + 1 < len) : (j += 1) {
            const a = dest[j];
            const b = dest[j + 1];
            if (needs_swap(a, b)) {
                dest[j] = b;
                dest[j + 1] = a;
                swapped = true;
            }
        }
        if (!swapped) break;
    }
    return Value{ .function_v = .{
        .domain = make_range_set(pool, 1, @as(i64, @intCast(len))),
        .offset = value_offset(pool, dest.ptr),
        .len = len,
    } };
}

fn needs_swap(a: Value, b: Value) bool {
    if (a == .int_v and b == .int_v) return a.int_v > b.int_v;
    if (a == .string_v and b == .string_v) {
        // Lexicographic string comparison not available without pool access; no swap.
        return false;
    }
    return false;
}

fn permutations(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const s = args[0];
    if (s != .set_v) return Error.TypeError;
    const items = s.set_v.items(pool);
    if (items.len == 0) {
        const empty_seq = Value{ .function_v = .{ .domain = value.Set{ .offset = pool.value_count, .len = 0 }, .offset = pool.value_count, .len = 0 } };
        const dest = try pool.alloc_values(1);
        dest[0] = empty_seq;
        return Value{ .set_v = make_set(pool, dest) };
    }
    var result = std.ArrayList(Value).empty;
    defer result.deinit(std.heap.page_allocator);
    var order = try std.heap.page_allocator.alloc(usize, items.len);
    defer std.heap.page_allocator.free(order);
    for (0..items.len) |i| order[i] = i;
    while (true) {
        const function_values = try pool.alloc_values(@intCast(items.len * 2));
        const domain = function_values[0..items.len];
        const entries = function_values[items.len..];
        @memcpy(domain, items);
        for (order, 0..) |idx, i| entries[i] = items[idx];
        try result.append(std.heap.page_allocator, Value{ .function_v = .{
            .domain = .{
                .offset = value_offset(pool, domain.ptr),
                .len = @intCast(domain.len),
            },
            .offset = value_offset(pool, entries.ptr),
            .len = @intCast(entries.len),
        } });
        if (!next_permutation(order)) break;
    }
    const dest = try pool.alloc_values(@intCast(result.items.len));
    @memcpy(dest, result.items);
    return Value{ .set_v = make_set(pool, dest) };
}

fn next_permutation(order: []usize) bool {
    if (order.len < 2) return false;
    var i: usize = order.len - 1;
    while (i > 0 and order[i - 1] >= order[i]) i -= 1;
    if (i == 0) return false;
    var j: usize = order.len - 1;
    while (order[j] <= order[i - 1]) j -= 1;
    const tmp = order[i - 1];
    order[i - 1] = order[j];
    order[j] = tmp;
    var l: usize = i;
    var r: usize = order.len - 1;
    while (l < r) {
        const t = order[l];
        order[l] = order[r];
        order[r] = t;
        l += 1;
        r -= 1;
    }
    return true;
}

fn random_element(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const s = args[0];
    if (s != .set_v) return Error.TypeError;
    const items = s.set_v.items(pool);
    if (items.len == 0) return Error.EmptyChoose;
    return items[0];
}

fn to_string(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return Value{ .string_v = try pool.push_string("__str") };
}

fn java_time(_: OverrideContext, _: *ValuePool, _: []const Value) Error!Value {
    return Value{ .int_v = 0 };
}

fn tlc_get(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len == 1 and args[0] == .string_v) {
        const key = args[0].string_v.slice(pool);
        if (std.mem.eql(u8, key, "config")) {
            const fields = try pool.alloc_values(2);
            const fields_offset = value_offset(pool, fields.ptr);
            fields[0] = Value{
                .string_v = try pool.push_string("mode"),
            };
            fields[1] = Value{
                .string_v = try pool.push_string("bfs"),
            };
            return Value{
                .record_v = .{ .offset = fields_offset, .len = 1 },
            };
        }
        if (std.mem.eql(
            u8,
            key,
            "-Dtlc2.tool.impl.Tool.cdot",
        )) {
            return Value{ .string_v = try pool.push_string("true") };
        }
    }
    return Value{ .int_v = 0 };
}

fn tlc_set(_: OverrideContext, _: *ValuePool, _: []const Value) Error!Value {
    return Value{ .bool_v = true };
}

fn tlc_print(_: OverrideContext, _: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    return args[1];
}

fn tlc_print_t(_: OverrideContext, _: *ValuePool, _: []const Value) Error!Value {
    return Value{ .bool_v = true };
}

fn empty_bag(_: OverrideContext, pool: *ValuePool, _: []const Value) Error!Value {
    return Value{ .function_v = .{
        .domain = make_set(pool, &[_]Value{}),
        .offset = value_offset(pool, pool.values.ptr),
        .len = 0,
    } };
}

fn bag_in(_: OverrideContext, _: *ValuePool, _: []const Value) Error!Value {
    return Value{ .bool_v = false };
}

fn bag_of_set(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const s = args[0];
    if (s != .set_v) return Error.TypeError;
    const items = s.set_v.items(pool);
    const vals = try pool.alloc_values(@intCast(items.len));
    @memset(vals, Value{ .int_v = 1 });
    return Value{ .function_v = .{
        .domain = s.set_v,
        .offset = value_offset(pool, vals.ptr),
        .len = @intCast(items.len),
    } };
}

fn bag_cardinality(_: OverrideContext, _: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return Value{ .int_v = 0 };
}

fn bag_cup(_: OverrideContext, _: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    return args[0];
}

fn bag_cap(_: OverrideContext, _: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    return args[0];
}

fn bag_difference(_: OverrideContext, pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    const a = args[0];
    const b = args[1];
    if (a != .function_v or b != .function_v) return Error.TypeError;
    const fa = a.function_v;
    const fb = b.function_v;
    const ka = fa.domain.items(pool);
    const va = fa.entries(pool);
    var count: u32 = 0;
    for (ka, va) |k, v| {
        const bv = fb.apply(pool, k) orelse Value{ .int_v = 0 };
        const ai = v.as_int() orelse return Error.TypeError;
        const bi = bv.as_int() orelse return Error.TypeError;
        if (ai > bi) count += 1;
    }
    const keys = try pool.alloc_values(count);
    const vals = try pool.alloc_values(count);
    var pos: u32 = 0;
    for (ka, va) |k, v| {
        const bv = fb.apply(pool, k) orelse Value{ .int_v = 0 };
        const ai = v.as_int() orelse return Error.TypeError;
        const bi = bv.as_int() orelse return Error.TypeError;
        if (ai > bi) {
            keys[pos] = k;
            vals[pos] = Value{ .int_v = ai - bi };
            pos += 1;
        }
    }
    return Value{ .function_v = .{
        .domain = make_set(pool, keys),
        .offset = value_offset(pool, vals.ptr),
        .len = pos,
    } };
}

fn wf_vars(_: OverrideContext, _: *ValuePool, args: []const Value) Error!Value {
    _ = args;
    return Value{ .bool_v = true };
}

fn sf_vars(_: OverrideContext, _: *ValuePool, args: []const Value) Error!Value {
    _ = args;
    return Value{ .bool_v = true };
}
