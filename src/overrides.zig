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
    .{ .name = "Seq", .func = seq_set },
    .{ .name = "UNION", .func = union_all },
    .{ .name = "Assert", .func = tlc_assert },
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
