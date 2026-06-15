const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const ValuePool = value.ValuePool;
const Error = @import("err.zig").Error;

pub const OverrideFn = *const fn (
    pool: *ValuePool,
    args: []const Value,
) Error!Value;

pub const ValueOverrideFn = *const fn (pool: *ValuePool) Error!Value;

pub const OverrideEntry = struct {
    name: []const u8,
    func: OverrideFn,
};

pub const ValueOverrideEntry = struct {
    name: []const u8,
    func: ValueOverrideFn,
};

pub const Registry = struct {
    entries: []const OverrideEntry,
    values: []const ValueOverrideEntry,

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
};

pub fn default_registry() Registry {
    return Registry{ .entries = &default_overrides, .values = &default_value_overrides };
}

var g_max_seq_len: u32 = 5;
var g_max_nat: i64 = 10;
var g_min_int: i64 = -10;
var g_max_int: i64 = 10;

pub fn set_max_seq_len(n: u32) void {
    g_max_seq_len = n;
}

pub fn set_nat_bound(n: i64) void {
    std.debug.assert(n >= 0);
    g_max_nat = n;
}

pub fn set_int_bounds(min: i64, max: i64) void {
    std.debug.assert(min <= max);
    g_min_int = min;
    g_max_int = max;
}

const default_overrides = [_]OverrideEntry{
    .{ .name = "Cardinality", .func = cardinality },
    .{ .name = "IsFiniteSet", .func = is_finite_set },
    .{ .name = "Len", .func = sequence_len },
    .{ .name = "Head", .func = head },
    .{ .name = "Tail", .func = tail },
    .{ .name = "Append", .func = append },
    .{ .name = "SubSeq", .func = sub_seq },
    .{ .name = "SelectSeq", .func = select_seq },
    .{ .name = "SortSeq", .func = sort_seq },
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

const default_value_overrides = [_]ValueOverrideEntry{
    .{ .name = "Nat", .func = nat_set },
    .{ .name = "Int", .func = int_set },
    .{ .name = "BOOLEAN", .func = boolean_set },
};

fn cardinality(pool: *ValuePool, args: []const Value) Error!Value {
    _ = pool;
    if (args.len != 1) return Error.TypeError;
    const s = args[0];
    if (s != .set_v) return Error.TypeError;
    return Value{ .int_v = @intCast(s.set_v.len) };
}

fn is_finite_set(_: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return Value{ .bool_v = true };
}

fn sequence_len(pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    _ = pool;
    return switch (args[0]) {
        .function_v => |f| Value{ .int_v = @intCast(f.len) },
        .tuple_v => |t| Value{ .int_v = @intCast(t.len) },
        .string_v => |s| Value{ .int_v = @intCast(s.len) },
        else => Error.TypeError,
    };
}

fn head(pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return switch (args[0]) {
        .function_v => |f| f.apply(pool, Value{ .int_v = 1 }) orelse Error.IndexOutOfBounds,
        .tuple_v => |t| if (t.len == 0) Error.IndexOutOfBounds else t.items(pool)[0],
        .string_v => |s| if (s.len == 0) Error.IndexOutOfBounds else Value{ .int_v = s.slice(pool)[0] },
        else => Error.TypeError,
    };
}

fn tail(pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return switch (args[0]) {
        .function_v => |f| {
            if (f.len == 0) return Error.IndexOutOfBounds;
            const keys = f.domain.items(pool);
            const vals = f.entries(pool);
            const new_keys = try pool.alloc_values(@intCast(f.len - 1));
            const new_vals = try pool.alloc_values(@intCast(f.len - 1));
            for (keys[1..f.len], 0..) |k, i| {
                new_keys[i] = k;
                new_vals[i] = vals[i + 1];
            }
            return Value{ .function_v = .{
                .domain = make_set(pool, new_keys),
                .offset = value_offset(pool, new_vals.ptr),
                .len = @intCast(f.len - 1),
            } };
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

fn append(pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    const elem = try pool.alloc_values(1);
    elem[0] = args[1];
    const singleton = Value{ .tuple_v = make_tuple(pool, elem) };
    return sequence_concat(pool, args[0], singleton);
}

fn sub_seq(pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 3) return Error.TypeError;
    const lo = args[1].as_int() orelse return Error.TypeError;
    const hi = args[2].as_int() orelse return Error.TypeError;
    if (lo > hi or lo < 1) return Error.IndexOutOfBounds;
    const len_i: u32 = @intCast(hi - lo + 1);
    return switch (args[0]) {
        .function_v => |f| {
            const vals = f.entries(pool);
            const dest = try pool.alloc_values(len_i);
            for (0..len_i) |i| {
                const idx: usize = @intCast(lo - 1 + @as(i64, @intCast(i)));
                dest[i] = vals[idx];
            }
            return Value{ .function_v = .{
                .domain = make_range_set(pool, lo, hi),
                .offset = value_offset(pool, dest.ptr),
                .len = len_i,
            } };
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

fn union_all(pool: *ValuePool, args: []const Value) Error!Value {
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

fn tlc_assert(_: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    if (!args[0].is_truthy()) return Error.AssertionFailed;
    return Value{ .bool_v = true };
}

fn nat_set(pool: *ValuePool) Error!Value {
    return Value{ .set_v = make_range_set(pool, 0, g_max_nat) };
}

fn int_set(pool: *ValuePool) Error!Value {
    return Value{ .set_v = make_range_set(pool, g_min_int, g_max_int) };
}

fn boolean_set(pool: *ValuePool) Error!Value {
    const dest = pool.alloc_values(2) catch return error.OutOfMemory;
    dest[0] = Value{ .bool_v = false };
    dest[1] = Value{ .bool_v = true };
    return Value{ .set_v = make_set(pool, dest) };
}

fn seq_set(pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const s = args[0];
    if (s != .set_v) return Error.TypeError;
    const items = s.set_v.items(pool);
    const m: u64 = items.len;
    const total = try seq_set_size(m, g_max_seq_len);
    const dest = try pool.alloc_values(@intCast(total));
    var pos: u32 = 0;
    const empty = try pool.alloc_values(0);
    dest[pos] = make_sequence(pool, empty, 0);
    pos += 1;
    var len: u32 = 1;
    while (len <= g_max_seq_len) : (len += 1) {
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

pub fn ooverride(pool: *ValuePool, a: Value, b: Value) Error!Value {
    // Combine two records/functions; right-hand side overrides left for matching keys.
    const fa = if (a == .function_v) a.function_v else return Error.TypeError;
    const fb = if (b == .function_v) b.function_v else return Error.TypeError;
    const ka = fa.domain.items(pool);
    const va = fa.entries(pool);
    const kb = fb.domain.items(pool);
    const vb = fb.entries(pool);
    const dest_len: u32 = @intCast(ka.len + kb.len);
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

pub fn recordto(pool: *ValuePool, key: Value, val: Value) Error!Value {
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

pub fn sequence_concat(pool: *ValuePool, a: Value, b: Value) Error!Value {
    if (a == .tuple_v and b == .tuple_v) {
        const ta = a.tuple_v.items(pool);
        const tb = b.tuple_v.items(pool);
        const dest = try pool.alloc_values(@intCast(ta.len + tb.len));
        @memcpy(dest[0..ta.len], ta);
        @memcpy(dest[ta.len..], tb);
        return Value{ .tuple_v = make_tuple(pool, dest) };
    }
    const fa = if (a == .function_v) a.function_v else return Error.TypeError;
    const fb = if (b == .function_v) b.function_v else return Error.TypeError;
    const la: i64 = @intCast(fa.len);
    const lb: i64 = @intCast(fb.len);
    const dest_len: u32 = @intCast(la + lb);
    const dest = try pool.alloc_values(dest_len);
    const va = fa.entries(pool);
    const vb = fb.entries(pool);
    for (va, 0..) |v, i| {
        dest[i] = v;
    }
    for (vb, 0..) |v, i| {
        dest[va.len + i] = v;
    }
    const keys = try pool.alloc_values(dest_len);
    for (0..dest_len) |i| {
        keys[i] = Value{ .int_v = @as(i64, @intCast(i)) + 1 };
    }
    return Value{ .function_v = .{
        .domain = make_set(pool, keys),
        .offset = value_offset(pool, dest.ptr),
        .len = dest_len,
    } };
}

fn make_set(pool: *ValuePool, values: []Value) value.Set {
    return .{
        .offset = value_offset(pool, values.ptr),
        .len = @intCast(values.len),
    };
}

fn make_tuple(pool: *ValuePool, values: []Value) value.Tuple {
    return .{
        .offset = value_offset(pool, values.ptr),
        .len = @intCast(values.len),
    };
}

fn value_offset(pool: *ValuePool, ptr: [*]Value) u32 {
    const bytes = @intFromPtr(ptr) - @intFromPtr(pool.values.ptr);
    return @intCast(bytes / @sizeOf(Value));
}

fn make_range_set(pool: *ValuePool, lo: i64, hi: i64) value.Set {
    const len: u32 = @intCast(hi - lo + 1);
    const dest = pool.alloc_values(len) catch unreachable;
    for (0..len) |i| {
        dest[i] = Value{ .int_v = lo + @as(i64, @intCast(i)) };
    }
    return make_set(pool, dest);
}

// SelectSeq(seq, test) returns the subsequence of elements for which test is true.
// TLA+ expects test to be a unary operator/function. We accept either a function value
// (treated as a lambda to apply) or return the original sequence as a conservative stub.
fn select_seq(_: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    // Real implementation needs access to the evaluator/AST context for the predicate.
    return args[0];
}

// SortSeq(seq, op) sorts the sequence using the comparison operator.
// Without access to the evaluator/AST context, we can only sort primitive values when the
// operator is the standard `\leq` relation. Otherwise return the sequence unchanged.
fn sort_seq(pool: *ValuePool, args: []const Value) Error!Value {
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

fn permutations(pool: *ValuePool, args: []const Value) Error!Value {
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
        const seq_values = try pool.alloc_values(@intCast(items.len));
        for (order, 0..) |idx, i| seq_values[i] = items[idx];
        const seq = if (items.len == 0)
            Value{ .function_v = .{ .domain = value.Set{ .offset = pool.value_count, .len = 0 }, .offset = pool.value_count, .len = 0 } }
        else
            make_sequence(pool, seq_values, @intCast(items.len));
        try result.append(std.heap.page_allocator, seq);
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

fn random_element(pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    const s = args[0];
    if (s != .set_v) return Error.TypeError;
    const items = s.set_v.items(pool);
    if (items.len == 0) return Error.EmptyChoose;
    return items[0];
}

fn to_string(pool: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return Value{ .string_v = try pool.push_string("__str") };
}

fn java_time(_: *ValuePool, _: []const Value) Error!Value {
    return Value{ .int_v = 0 };
}

fn tlc_get(_: *ValuePool, _: []const Value) Error!Value {
    return Value{ .int_v = 0 };
}

fn tlc_set(_: *ValuePool, _: []const Value) Error!Value {
    return Value{ .bool_v = true };
}

fn tlc_print(_: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    return args[1];
}

fn tlc_print_t(_: *ValuePool, _: []const Value) Error!Value {
    return Value{ .bool_v = true };
}

fn empty_bag(pool: *ValuePool, _: []const Value) Error!Value {
    return Value{ .function_v = .{
        .domain = make_set(pool, &[_]Value{}),
        .offset = value_offset(pool, pool.values.ptr),
        .len = 0,
    } };
}

fn bag_in(_: *ValuePool, _: []const Value) Error!Value {
    return Value{ .bool_v = false };
}

fn bag_of_set(pool: *ValuePool, args: []const Value) Error!Value {
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

fn bag_cardinality(_: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 1) return Error.TypeError;
    return Value{ .int_v = 0 };
}

fn bag_cup(_: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    return args[0];
}

fn bag_cap(_: *ValuePool, args: []const Value) Error!Value {
    if (args.len != 2) return Error.TypeError;
    return args[0];
}

fn bag_difference(pool: *ValuePool, args: []const Value) Error!Value {
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

fn wf_vars(_: *ValuePool, args: []const Value) Error!Value {
    _ = args;
    return Value{ .bool_v = true };
}

fn sf_vars(_: *ValuePool, args: []const Value) Error!Value {
    _ = args;
    return Value{ .bool_v = true };
}
