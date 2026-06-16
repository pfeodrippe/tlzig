const std = @import("std");
const assert = std.debug.assert;
const Arena = @import("arena.zig").Arena;

pub const ValueTag = enum(u8) {
    bool_v,
    int_v,
    set_v,
    function_v,
    tuple_v,
    record_v,
    string_v,
    model_v,
    lambda_v,
    // Lazy symbolic set constructors (never enumerate unless forced).
    function_set_v,
    record_set_v,
    tuple_set_v,
    union_v,
    cup_v,
    cap_v,
    diff_v,
    range_v,
};

pub const Lambda = struct {
    params: []const []const u8,
    body: *anyopaque,
    ctx: *anyopaque,
};

pub const FunctionSet = extern struct {
    domain_offset: u32,
    codomain_offset: u32,

    pub fn domain(self: FunctionSet, pool: *const ValuePool) Value {
        assert(self.domain_offset < pool.value_count);
        return pool.values[self.domain_offset];
    }

    pub fn codomain(self: FunctionSet, pool: *const ValuePool) Value {
        assert(self.codomain_offset < pool.value_count);
        return pool.values[self.codomain_offset];
    }
};

pub const RecordSet = extern struct {
    offset: u32,
    len: u32,

    pub fn field_name(self: RecordSet, pool: *const ValuePool, i: u32) String {
        assert(i < self.len);
        const v = pool.values[self.offset + i * 2];
        assert(v == .string_v);
        return v.string_v;
    }

    pub fn field_domain(self: RecordSet, pool: *const ValuePool, i: u32) Value {
        assert(i < self.len);
        return pool.values[self.offset + i * 2 + 1];
    }

    pub fn member(self: RecordSet, pool: *const ValuePool, elem: Value) bool {
        assert(self.offset + self.len * 2 <= pool.value_count);
        if (elem != .record_v) return false;
        const r = elem.record_v;
        if (r.len != self.len) return false;
        const rfs = r.fields(pool);
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            if (!rfs[i * 2].string_v.eql(self.field_name(pool, i), pool)) return false;
            const val = rfs[i * 2 + 1];
            if (!self.field_domain(pool, i).member(pool, val)) return false;
        }
        return true;
    }

    pub fn eql(self: RecordSet, other: RecordSet, pool: *const ValuePool) bool {
        assert(self.offset + self.len * 2 <= pool.value_count);
        assert(other.offset + other.len * 2 <= pool.value_count);
        if (self.len != other.len) return false;
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            if (!self.field_name(pool, i).eql(other.field_name(pool, i), pool)) return false;
            if (!self.field_domain(pool, i).eql(other.field_domain(pool, i), pool)) return false;
        }
        return true;
    }

    pub fn clone(self: RecordSet, source: *const ValuePool, target: *ValuePool) error{ OutOfMemory, NotImplemented }!RecordSet {
        assert(self.offset + self.len * 2 <= source.value_count);
        assert(target.value_count + self.len * 2 <= target.value_cap);
        const dest = try target.alloc_values(self.len * 2);
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            const name = try self.field_name(source, i).clone(source, target);
            const dom = try self.field_domain(source, i).clone(source, target);
            dest[i * 2] = Value{ .string_v = name };
            dest[i * 2 + 1] = dom;
        }
        const offset: u32 = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(target.values.ptr)) / @sizeOf(Value));
        return RecordSet{ .offset = offset, .len = self.len };
    }
};

pub const TupleSet = extern struct {
    offset: u32,
    len: u32,

    pub fn sets(self: TupleSet, pool: *const ValuePool) []const Value {
        assert(self.offset + self.len <= pool.value_count);
        return pool.values[self.offset..][0..self.len];
    }

    pub fn member(self: TupleSet, pool: *const ValuePool, elem: Value) bool {
        assert(self.offset + self.len <= pool.value_count);
        if (elem == .tuple_v) {
            const t = elem.tuple_v;
            if (t.len != self.len) return false;
            const items = t.items(pool);
            const ss = self.sets(pool);
            for (items, ss) |it, s| {
                if (!s.member(pool, it)) return false;
            }
            return true;
        }
        // Tuples are functions with domain 1..n; accept function form too.
        if (elem != .function_v) return false;
        const f = elem.function_v;
        if (f.len != self.len) return false;
        const ss = self.sets(pool);
        var i: i64 = 1;
        while (i <= self.len) : (i += 1) {
            const v = f.apply(pool, Value{ .int_v = i }) orelse return false;
            if (!ss[@intCast(i - 1)].member(pool, v)) return false;
        }
        return true;
    }

    pub fn eql(self: TupleSet, other: TupleSet, pool: *const ValuePool) bool {
        assert(self.offset + self.len <= pool.value_count);
        assert(other.offset + other.len <= pool.value_count);
        if (self.len != other.len) return false;
        const a = self.sets(pool);
        const b = other.sets(pool);
        for (a, b) |x, y| {
            if (!x.eql(y, pool)) return false;
        }
        return true;
    }

    pub fn clone(self: TupleSet, source: *const ValuePool, target: *ValuePool) error{ OutOfMemory, NotImplemented }!TupleSet {
        assert(self.offset + self.len <= source.value_count);
        assert(target.value_count + self.len <= target.value_cap);
        const src = self.sets(source);
        const dest = try target.alloc_values(self.len);
        for (src, 0..) |v, i| {
            dest[i] = try v.clone(source, target);
        }
        const offset: u32 = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(target.values.ptr)) / @sizeOf(Value));
        return TupleSet{ .offset = offset, .len = self.len };
    }
};

pub const UnionSet = extern struct {
    set_offset: u32,

    pub fn set(self: UnionSet, pool: *const ValuePool) Value {
        assert(self.set_offset < pool.value_count);
        return pool.values[self.set_offset];
    }
};

pub const BinarySet = extern struct {
    left_offset: u32,
    right_offset: u32,

    pub fn left(self: BinarySet, pool: *const ValuePool) Value {
        assert(self.left_offset < pool.value_count);
        return pool.values[self.left_offset];
    }

    pub fn right(self: BinarySet, pool: *const ValuePool) Value {
        assert(self.right_offset < pool.value_count);
        return pool.values[self.right_offset];
    }
};

pub const Range = extern struct {
    lo: i64,
    hi: i64,

    pub fn member(self: Range, elem: Value) bool {
        const i = elem.as_int() orelse return false;
        return i >= self.lo and i <= self.hi;
    }

    pub fn eql(self: Range, other: Range) bool {
        return self.lo == other.lo and self.hi == other.hi;
    }
};

pub const Value = union(ValueTag) {
    bool_v: bool,
    int_v: i64,
    set_v: Set,
    function_v: Function,
    tuple_v: Tuple,
    record_v: Record,
    string_v: String,
    model_v: u32,
    lambda_v: *Lambda,
    function_set_v: FunctionSet,
    record_set_v: RecordSet,
    tuple_set_v: TupleSet,
    union_v: UnionSet,
    cup_v: BinarySet,
    cap_v: BinarySet,
    diff_v: BinarySet,
    range_v: Range,

    pub fn is_truthy(self: Value) bool {
        return switch (self) {
            .bool_v => |b| b,
            else => false,
        };
    }

    pub fn as_int(self: Value) ?i64 {
        return switch (self) {
            .int_v => |i| i,
            else => null,
        };
    }

    pub fn as_bool(self: Value) ?bool {
        return switch (self) {
            .bool_v => |b| b,
            else => null,
        };
    }

    pub fn tag(self: Value) ValueTag {
        return std.meta.activeTag(self);
    }

    pub fn is_set_like(self: Value) bool {
        return switch (self) {
            .set_v,
            .function_set_v,
            .record_set_v,
            .tuple_set_v,
            .union_v,
            .cup_v,
            .cap_v,
            .diff_v,
            .range_v,
            => true,
            else => false,
        };
    }

    pub fn eql(a: Value, b: Value, pool: *const ValuePool) bool {
        assert(pool.value_count <= pool.value_cap);
        assert(pool.string_count <= pool.string_cap);
        const tag_a = std.meta.activeTag(a);
        const tag_b = std.meta.activeTag(b);
        const tags_equal = tag_a == tag_b;
        return switch (a) {
            .set_v => |sa| blk: {
                if (!tags_equal and b == .range_v) break :blk range_equals_set(b.range_v, sa, pool);
                if (!tags_equal) break :blk false;
                break :blk sa.eql(b.set_v, pool);
            },
            .range_v => |ra| blk: {
                if (!tags_equal and b == .set_v) break :blk range_equals_set(ra, b.set_v, pool);
                if (!tags_equal) break :blk false;
                break :blk ra.eql(b.range_v);
            },
            .bool_v => |ba| tags_equal and ba == b.bool_v,
            .int_v => |ia| tags_equal and ia == b.int_v,
            .model_v => |ma| tags_equal and ma == b.model_v,
            .function_v => |fa| tags_equal and fa.eql(b.function_v, pool),
            .tuple_v => |ta| tags_equal and ta.eql(b.tuple_v, pool),
            .record_v => |ra| tags_equal and ra.eql(b.record_v, pool),
            .string_v => |sa| tags_equal and sa.eql(b.string_v, pool),
            .lambda_v => false,
            .function_set_v => tags_equal and a.function_set_v.domain(pool).eql(b.function_set_v.domain(pool), pool) and
                a.function_set_v.codomain(pool).eql(b.function_set_v.codomain(pool), pool),
            .record_set_v => tags_equal and a.record_set_v.eql(b.record_set_v, pool),
            .tuple_set_v => tags_equal and a.tuple_set_v.eql(b.tuple_set_v, pool),
            .union_v => tags_equal and a.union_v.set(pool).eql(b.union_v.set(pool), pool),
            .cup_v => tags_equal and a.cup_v.left(pool).eql(b.cup_v.left(pool), pool) and a.cup_v.right(pool).eql(b.cup_v.right(pool), pool),
            .cap_v => tags_equal and a.cap_v.left(pool).eql(b.cap_v.left(pool), pool) and a.cap_v.right(pool).eql(b.cap_v.right(pool), pool),
            .diff_v => tags_equal and a.diff_v.left(pool).eql(b.diff_v.left(pool), pool) and a.diff_v.right(pool).eql(b.diff_v.right(pool), pool),
        };
    }

    pub fn compare(a: Value, b: Value, pool: *const ValuePool) ?i8 {
        assert(pool.value_count <= pool.value_cap);
        assert(pool.string_count <= pool.string_cap);
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return null;
        return switch (a) {
            .bool_v => |ba| if (ba == b.bool_v) 0 else if (ba) 1 else -1,
            .int_v => |ia| {
                const ib = b.int_v;
                return if (ia < ib) -1 else if (ia > ib) 1 else 0;
            },
            .string_v => |sa| sa.compare(b.string_v, pool),
            .lambda_v => null,
            else => null,
        };
    }

    pub fn clone(self: Value, source: *const ValuePool, target: *ValuePool) error{ OutOfMemory, NotImplemented }!Value {
        assert(source.value_count <= source.value_cap);
        assert(source.string_count <= source.string_cap);
        assert(target.value_count <= target.value_cap);
        assert(target.string_count <= target.string_cap);
        return switch (self) {
            .bool_v => |b| Value{ .bool_v = b },
            .int_v => |i| Value{ .int_v = i },
            .model_v => |m| Value{ .model_v = m },
            .string_v => |s| Value{ .string_v = try s.clone(source, target) },
            .set_v => |s| Value{ .set_v = try s.clone(source, target) },
            .function_v => |f| Value{ .function_v = try f.clone(source, target) },
            .tuple_v => |t| Value{ .tuple_v = try t.clone(source, target) },
            .record_v => |r| Value{ .record_v = try r.clone(source, target) },
            .lambda_v => return error.NotImplemented,
            .function_set_v => |fs| Value{
                .function_set_v = .{
                    .domain_offset = try target.push_value(try fs.domain(source).clone(source, target)),
                    .codomain_offset = try target.push_value(try fs.codomain(source).clone(source, target)),
                },
            },
            .record_set_v => |rs| Value{ .record_set_v = try rs.clone(source, target) },
            .tuple_set_v => |ts| Value{ .tuple_set_v = try ts.clone(source, target) },
            .union_v => |u| Value{ .union_v = .{ .set_offset = try target.push_value(try u.set(source).clone(source, target)) } },
            .cup_v => |bs| Value{
                .cup_v = .{
                    .left_offset = try target.push_value(try bs.left(source).clone(source, target)),
                    .right_offset = try target.push_value(try bs.right(source).clone(source, target)),
                },
            },
            .cap_v => |bs| Value{
                .cap_v = .{
                    .left_offset = try target.push_value(try bs.left(source).clone(source, target)),
                    .right_offset = try target.push_value(try bs.right(source).clone(source, target)),
                },
            },
            .diff_v => |bs| Value{
                .diff_v = .{
                    .left_offset = try target.push_value(try bs.left(source).clone(source, target)),
                    .right_offset = try target.push_value(try bs.right(source).clone(source, target)),
                },
            },
            .range_v => |r| Value{ .range_v = r },
        };
    }

    /// Check if `elem` is a member of this set-like value without materializing
    /// the set.  This mirrors TLC's symbolic membership tests.
    pub fn member(self: Value, pool: *const ValuePool, elem: Value) bool {
        return switch (self) {
            .set_v => |s| s.contains(pool, elem),
            .function_set_v => |fs| function_set_member(pool, fs, elem),
            .record_set_v => |rs| rs.member(pool, elem),
            .tuple_set_v => |ts| ts.member(pool, elem),
            .union_v => |u| union_member(pool, u.set(pool), elem),
            .cup_v => |bs| bs.left(pool).member(pool, elem) or bs.right(pool).member(pool, elem),
            .cap_v => |bs| bs.left(pool).member(pool, elem) and bs.right(pool).member(pool, elem),
            .diff_v => |bs| bs.left(pool).member(pool, elem) and !bs.right(pool).member(pool, elem),
            .range_v => |r| r.member(elem),
            else => {
                assert(false); // member called on non-set value
                return false;
            },
        };
    }
};

fn range_equals_set(r: Range, s: Set, pool: *const ValuePool) bool {
    const items = s.items(pool);
    if (items.len != @as(u64, @intCast(r.hi - r.lo + 1))) return false;
    for (items, 0..) |it, i| {
        const expected = r.lo + @as(i64, @intCast(i));
        if (it.as_int() != expected) return false;
    }
    return true;
}

fn function_set_member(pool: *const ValuePool, fs: FunctionSet, elem: Value) bool {
    if (elem != .function_v) return false;
    const f = elem.function_v;
    const domain = fs.domain(pool);
    const codomain = fs.codomain(pool);
    if (!domain_matches_function_domain(domain, f, pool)) return false;
    const keys = f.domain.items(pool);
    for (keys) |k| {
        const v = f.apply(pool, k) orelse return false;
        if (!codomain.member(pool, v)) return false;
    }
    return true;
}

fn domain_matches_function_domain(domain: Value, f: Function, pool: *const ValuePool) bool {
    switch (domain) {
        .set_v => return f.domain.eql(domain.set_v, pool),
        .range_v => |r| {
            const keys = f.domain.items(pool);
            if (keys.len != @as(u64, @intCast(r.hi - r.lo + 1))) return false;
            for (keys, 0..) |k, i| {
                const expected = r.lo + @as(i64, @intCast(i));
                if (k.as_int() != expected) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn union_member(pool: *const ValuePool, set: Value, elem: Value) bool {
    if (set != .set_v) {
        assert(false); // UNION operand must be an enumerated set of sets
        return false;
    }
    const items = set.set_v.items(pool);
    for (items) |it| {
        if (it.member(pool, elem)) return true;
    }
    return false;
}

pub const Set = extern struct {
    offset: u32,
    len: u32,

    pub fn items(self: Set, pool: *const ValuePool) []const Value {
        assert(self.offset + self.len <= pool.value_count);
        return pool.values[self.offset..][0..self.len];
    }

    pub fn contains(self: Set, pool: *const ValuePool, v: Value) bool {
        assert(self.offset + self.len <= pool.value_count);
        for (self.items(pool)) |it| {
            if (it.eql(v, pool)) return true;
        }
        return false;
    }

    pub fn is_subset(self: Set, pool: *const ValuePool, other: Set) bool {
        assert(self.offset + self.len <= pool.value_count);
        assert(other.offset + other.len <= pool.value_count);
        for (self.items(pool)) |it| {
            if (!other.contains(pool, it)) return false;
        }
        return true;
    }

    pub fn eql(self: Set, other: Set, pool: *const ValuePool) bool {
        assert(self.offset + self.len <= pool.value_count);
        assert(other.offset + other.len <= pool.value_count);
        if (self.len != other.len) return false;
        return self.is_subset(pool, other);
    }

    pub fn clone(self: Set, source: *const ValuePool, target: *ValuePool) error{ OutOfMemory, NotImplemented }!Set {
        assert(self.offset + self.len <= source.value_count);
        assert(target.value_count <= target.value_cap);
        const src_items = self.items(source);
        const dest = try target.alloc_values(@intCast(src_items.len));
        assert(dest.len == src_items.len);
        for (src_items, 0..) |it, i| {
            dest[i] = try it.clone(source, target);
        }
        const offset: u32 = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(target.values.ptr)) / @sizeOf(Value));
        assert(offset + dest.len <= target.value_cap);
        return Set{ .offset = offset, .len = @intCast(src_items.len) };
    }
};

pub const Function = extern struct {
    domain: Set,
    offset: u32,
    len: u32,

    pub fn entries(self: Function, pool: *const ValuePool) []const Value {
        assert(self.len == self.domain.len);
        assert(self.offset + self.len <= pool.value_count);
        return pool.values[self.offset..][0..self.len];
    }

    pub fn apply(self: Function, pool: *const ValuePool, key: Value) ?Value {
        assert(self.offset + self.len <= pool.value_count);
        const keys = self.domain.items(pool);
        assert(keys.len == self.len);
        for (keys, 0..) |k, i| {
            if (k.eql(key, pool)) return self.entries(pool)[i];
        }
        return null;
    }

    pub fn eql(self: Function, other: Function, pool: *const ValuePool) bool {
        assert(self.offset + self.len <= pool.value_count);
        assert(other.offset + other.len <= pool.value_count);
        if (!self.domain.eql(other.domain, pool)) return false;
        const a = self.entries(pool);
        const b = other.entries(pool);
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!x.eql(y, pool)) return false;
        }
        return true;
    }

    pub fn clone(self: Function, source: *const ValuePool, target: *ValuePool) error{ OutOfMemory, NotImplemented }!Function {
        assert(self.offset + self.len <= source.value_count);
        assert(target.value_count <= target.value_cap);
        const dom = try self.domain.clone(source, target);
        const vals = self.entries(source);
        const dest = try target.alloc_values(@intCast(vals.len));
        assert(dest.len == vals.len);
        for (vals, 0..) |v, i| {
            dest[i] = try v.clone(source, target);
        }
        const offset: u32 = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(target.values.ptr)) / @sizeOf(Value));
        assert(offset + dest.len <= target.value_cap);
        return Function{
            .domain = dom,
            .offset = offset,
            .len = @intCast(vals.len),
        };
    }
};

pub const Tuple = extern struct {
    offset: u32,
    len: u32,

    pub fn items(self: Tuple, pool: *const ValuePool) []const Value {
        assert(self.offset + self.len <= pool.value_count);
        return pool.values[self.offset..][0..self.len];
    }

    pub fn eql(self: Tuple, other: Tuple, pool: *const ValuePool) bool {
        assert(self.offset + self.len <= pool.value_count);
        assert(other.offset + other.len <= pool.value_count);
        if (self.len != other.len) return false;
        for (self.items(pool), other.items(pool)) |a, b| {
            if (!a.eql(b, pool)) return false;
        }
        return true;
    }

    pub fn clone(self: Tuple, source: *const ValuePool, target: *ValuePool) error{ OutOfMemory, NotImplemented }!Tuple {
        assert(self.offset + self.len <= source.value_count);
        assert(target.value_count <= target.value_cap);
        const src_items = self.items(source);
        const dest = try target.alloc_values(@intCast(src_items.len));
        assert(dest.len == src_items.len);
        for (src_items, 0..) |it, i| {
            dest[i] = try it.clone(source, target);
        }
        const offset: u32 = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(target.values.ptr)) / @sizeOf(Value));
        assert(offset + dest.len <= target.value_cap);
        return Tuple{ .offset = offset, .len = @intCast(src_items.len) };
    }
};

pub const Record = extern struct {
    offset: u32,
    len: u32,

    pub fn fields(self: Record, pool: *const ValuePool) []const Value {
        assert(self.offset + self.len * 2 <= pool.value_count);
        return pool.values[self.offset..][0 .. self.len * 2];
    }

    pub fn lookup(self: Record, pool: *const ValuePool, name: []const u8) ?Value {
        assert(self.offset + self.len * 2 <= pool.value_count);
        const fs = self.fields(pool);
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            const key = fs[i * 2].string_v;
            if (std.mem.eql(u8, key.slice(pool), name)) {
                return fs[i * 2 + 1];
            }
        }
        return null;
    }

    pub fn eql(self: Record, other: Record, pool: *const ValuePool) bool {
        assert(self.offset + self.len * 2 <= pool.value_count);
        assert(other.offset + other.len * 2 <= pool.value_count);
        if (self.len != other.len) return false;
        const a = self.fields(pool);
        const b = other.fields(pool);
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            if (!a[i * 2].string_v.eql(b[i * 2].string_v, pool)) return false;
            if (!a[i * 2 + 1].eql(b[i * 2 + 1], pool)) return false;
        }
        return true;
    }

    pub fn clone(self: Record, source: *const ValuePool, target: *ValuePool) error{ OutOfMemory, NotImplemented }!Record {
        assert(self.offset + self.len * 2 <= source.value_count);
        assert(target.value_count <= target.value_cap);
        const fs = self.fields(source);
        const dest = try target.alloc_values(@intCast(fs.len));
        assert(dest.len == fs.len);
        for (fs, 0..) |v, i| {
            dest[i] = try v.clone(source, target);
        }
        const offset: u32 = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(target.values.ptr)) / @sizeOf(Value));
        assert(offset + dest.len <= target.value_cap);
        return Record{ .offset = offset, .len = self.len };
    }
};

pub const String = extern struct {
    offset: u32,
    len: u32,

    pub fn slice(self: String, pool: *const ValuePool) []const u8 {
        assert(self.offset + self.len <= pool.string_count);
        return pool.strings[self.offset..][0..self.len];
    }

    pub fn eql(self: String, other: String, pool: *const ValuePool) bool {
        assert(self.offset + self.len <= pool.string_count);
        assert(other.offset + other.len <= pool.string_count);
        return std.mem.eql(u8, self.slice(pool), other.slice(pool));
    }

    pub fn compare(self: String, other: String, pool: *const ValuePool) i8 {
        assert(self.offset + self.len <= pool.string_count);
        assert(other.offset + other.len <= pool.string_count);
        const order = std.mem.order(u8, self.slice(pool), other.slice(pool));
        return switch (order) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    pub fn clone(self: String, source: *const ValuePool, target: *ValuePool) error{OutOfMemory}!String {
        assert(self.offset + self.len <= source.string_count);
        assert(target.string_count <= target.string_cap);
        return try target.push_string(self.slice(source));
    }
};


pub const ModelTable = struct {
    arena: *Arena,
    names: [][]const u8,
    count: u32,
    cap: u32,

    pub fn init(arena: *Arena, cap: u32) !ModelTable {
        assert(cap > 0);
        const names = try arena.alloc([]const u8, cap);
        assert(names.len == cap);
        return ModelTable{
            .arena = arena,
            .names = names,
            .count = 0,
            .cap = cap,
        };
    }

    pub fn intern(self: *ModelTable, name: []const u8) !u32 {
        assert(self.count <= self.cap);
        for (0..self.count) |i| {
            assert(i < self.cap);
            if (std.mem.eql(u8, self.names[i], name)) return @intCast(i);
        }
        if (self.count >= self.cap) return error.OutOfMemory;
        const copy = try self.arena.alloc(u8, name.len);
        assert(copy.len == name.len);
        @memcpy(copy, name);
        const id = self.count;
        self.names[id] = copy;
        self.count += 1;
        assert(self.count <= self.cap);
        return id;
    }

    pub fn get_name(self: *const ModelTable, id: u32) []const u8 {
        assert(id < self.count);
        assert(self.count <= self.cap);
        return self.names[id];
    }
};

pub const ValuePool = struct {
    arena: *Arena,
    values: []Value,
    strings: []u8,
    value_count: u32,
    string_count: u32,
    value_cap: u32,
    string_cap: u32,

    pub fn init(arena: *Arena, value_cap: u32, string_cap: u32) !ValuePool {
        assert(value_cap > 0);
        assert(string_cap > 0);
        const values = try arena.alloc(Value, value_cap);
        assert(values.len == value_cap);
        const strings = try arena.alloc(u8, string_cap);
        assert(strings.len == string_cap);
        return ValuePool{
            .arena = arena,
            .values = values,
            .strings = strings,
            .value_count = 0,
            .string_count = 0,
            .value_cap = value_cap,
            .string_cap = string_cap,
        };
    }

    pub fn push_value(self: *ValuePool, v: Value) !u32 {
        assert(self.value_count <= self.value_cap);
        if (self.value_count >= self.value_cap) return error.OutOfMemory;
        const idx = self.value_count;
        self.values[idx] = v;
        self.value_count += 1;
        assert(self.value_count <= self.value_cap);
        return idx;
    }

    pub fn push_values(self: *ValuePool, vs: []const Value) !u32 {
        assert(self.value_count <= self.value_cap);
        if (self.value_count + vs.len > self.value_cap) return error.OutOfMemory;
        const start = self.value_count;
        @memcpy(self.values[start..][0..vs.len], vs);
        self.value_count += @intCast(vs.len);
        assert(self.value_count <= self.value_cap);
        return start;
    }

    pub fn alloc_values(self: *ValuePool, count: u32) ![]Value {
        assert(self.value_count <= self.value_cap);
        if (self.value_count + count > self.value_cap) return error.OutOfMemory;
        const start = self.value_count;
        self.value_count += count;
        assert(self.value_count <= self.value_cap);
        return self.values[start..][0..count];
    }

    pub fn push_string(self: *ValuePool, s: []const u8) !String {
        assert(self.string_count <= self.string_cap);
        if (self.string_count + s.len > self.string_cap) return error.OutOfMemory;
        const start = self.string_count;
        @memcpy(self.strings[start..][0..s.len], s);
        self.string_count += @intCast(s.len);
        assert(self.string_count <= self.string_cap);
        return String{ .offset = start, .len = @intCast(s.len) };
    }

    pub fn snapshot(self: ValuePool) Snapshot {
        assert(self.value_count <= self.value_cap);
        assert(self.string_count <= self.string_cap);
        return .{
            .value_count = self.value_count,
            .string_count = self.string_count,
        };
    }

    pub fn restore(self: *ValuePool, snap: Snapshot) void {
        assert(snap.value_count <= self.value_cap);
        assert(snap.string_count <= self.string_cap);
        self.value_count = snap.value_count;
        self.string_count = snap.string_count;
    }

    pub const Snapshot = struct {
        value_count: u32,
        string_count: u32,
    };
};
