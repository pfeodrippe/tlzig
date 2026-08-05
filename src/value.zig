const std = @import("std");
const assert = std.debug.assert;
const Arena = @import("arena.zig").Arena;

pub inline fn same_repr(a: Value, b: Value) bool {
    return switch (a) {
        .bool_v => |value| b == .bool_v and value == b.bool_v,
        .int_v => |value| b == .int_v and value == b.int_v,
        .model_v => |value| b == .model_v and value == b.model_v,
        .string_v => |value| b == .string_v and
            value.offset == b.string_v.offset and value.len == b.string_v.len,
        .set_v => |value| b == .set_v and
            value.offset == b.set_v.offset and value.len == b.set_v.len,
        .function_v => |value| b == .function_v and
            value.offset == b.function_v.offset and
            value.len == b.function_v.len and
            value.domain.offset == b.function_v.domain.offset and
            value.domain.len == b.function_v.domain.len,
        .tuple_v => |value| b == .tuple_v and
            value.offset == b.tuple_v.offset and value.len == b.tuple_v.len,
        .record_v => |value| b == .record_v and
            value.offset == b.record_v.offset and value.len == b.record_v.len,
        .range_v => |value| b == .range_v and
            value.lo == b.range_v.lo and value.hi == b.range_v.hi,
        .union_v => |value| b == .union_v and
            value.set_offset == b.union_v.set_offset,
        .cup_v => |value| b == .cup_v and
            value.left_offset == b.cup_v.left_offset and
            value.right_offset == b.cup_v.right_offset,
        .cap_v => |value| b == .cap_v and
            value.left_offset == b.cap_v.left_offset and
            value.right_offset == b.cap_v.right_offset,
        .diff_v => |value| b == .diff_v and
            value.left_offset == b.diff_v.left_offset and
            value.right_offset == b.diff_v.right_offset,
        .power_set_v => |value| b == .power_set_v and
            value.set_offset == b.power_set_v.set_offset,
        .function_set_v => |value| b == .function_set_v and
            value.domain_offset == b.function_set_v.domain_offset and
            value.codomain_offset == b.function_set_v.codomain_offset,
        .record_set_v => |value| b == .record_set_v and
            value.offset == b.record_set_v.offset and
            value.len == b.record_set_v.len,
        .tuple_set_v => |value| b == .tuple_set_v and
            value.offset == b.tuple_set_v.offset and
            value.len == b.tuple_set_v.len,
        .seq_set_v => |value| b == .seq_set_v and
            value.element_set_offset == b.seq_set_v.element_set_offset,
        .generated_operator_v => |value| b == .generated_operator_v and
            value.function_address == b.generated_operator_v.function_address and
            value.arity == b.generated_operator_v.arity and
            value.captured_offset == b.generated_operator_v.captured_offset and
            value.captured_len == b.generated_operator_v.captured_len,
        .lambda_v => false,
    };
}

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
    generated_operator_v,
    // Lazy symbolic set constructors (never enumerate unless forced).
    function_set_v,
    record_set_v,
    tuple_set_v,
    union_v,
    cup_v,
    cap_v,
    diff_v,
    range_v,
    seq_set_v,
    power_set_v,
};

pub const Lambda = struct {
    params: []const []const u8,
    body: *anyopaque,
    ctx: *anyopaque,
};

pub const GeneratedOperator = extern struct {
    function_address: usize,
    captured_offset: u32,
    arity: u16,
    captured_len: u16,
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
        const fields = r.fields(pool);
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            const expected_name = self.field_name(pool, i).slice(pool);
            const field_offset = i * 2;
            const field_key = fields[field_offset];
            assert(field_key == .string_v);
            const val = if (std.mem.eql(
                u8,
                expected_name,
                field_key.string_v.slice(pool),
            ))
                fields[field_offset + 1]
            else
                r.lookup(pool, expected_name) orelse return false;
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
            const expected_name = self.field_name(pool, i).slice(pool);
            var matched = false;
            var j: u32 = 0;
            while (j < other.len) : (j += 1) {
                if (!std.mem.eql(u8, expected_name, other.field_name(pool, j).slice(pool))) {
                    continue;
                }
                matched = true;
                if (!self.field_domain(pool, i).eql(other.field_domain(pool, j), pool)) {
                    return false;
                }
                break;
            }
            if (!matched) return false;
        }
        return true;
    }

    pub fn clone(self: RecordSet, source: *const ValuePool, target: *ValuePool) error{ OutOfMemory, NotImplemented }!RecordSet {
        assert(self.offset + self.len * 2 <= source.value_count);
        const dest = try target.alloc_values(self.len * 2);
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            const name = try self.field_name(source, i).clone(source, target);
            const dom = try self.field_domain(source, i).clone_assume_capacity(
                source,
                target,
            );
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
        const src = self.sets(source);
        const dest = try target.alloc_values(self.len);
        for (src, 0..) |v, i| {
            dest[i] = try v.clone_assume_capacity(source, target);
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

pub const SequenceSet = extern struct {
    element_set_offset: u32,

    pub fn element_set(self: SequenceSet, pool: *const ValuePool) Value {
        assert(self.element_set_offset < pool.value_count);
        return pool.values[self.element_set_offset];
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
    generated_operator_v: GeneratedOperator,
    function_set_v: FunctionSet,
    record_set_v: RecordSet,
    tuple_set_v: TupleSet,
    union_v: UnionSet,
    cup_v: BinarySet,
    cap_v: BinarySet,
    diff_v: BinarySet,
    range_v: Range,
    seq_set_v: SequenceSet,
    power_set_v: UnionSet,

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
            .seq_set_v,
            .power_set_v,
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
        if (tags_equal and a != .lambda_v and same_repr(a, b)) {
            return true;
        }
        if (!tags_equal and a == .set_v and b.is_set_like()) {
            if (concrete_finite_set_equal(a.set_v, b, pool)) |equal| {
                return equal;
            }
        }
        if (!tags_equal and b == .set_v and a.is_set_like()) {
            if (concrete_finite_set_equal(b.set_v, a, pool)) |equal| {
                return equal;
            }
        }
        if ((is_symbolic_finite_set(a) or is_symbolic_finite_set(b)) and
            a.is_set_like() and b.is_set_like())
        {
            if (finite_set_extensional_equal(a, b, pool)) |equal| {
                return equal;
            }
        }
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
            .function_v => |fa| blk: {
                if (tags_equal) break :blk fa.eql(b.function_v, pool);
                if (b == .tuple_v) break :blk function_equals_tuple(fa, b.tuple_v, pool);
                break :blk false;
            },
            .tuple_v => |ta| blk: {
                if (tags_equal) break :blk ta.eql(b.tuple_v, pool);
                if (b == .function_v) break :blk function_equals_tuple(b.function_v, ta, pool);
                break :blk false;
            },
            .record_v => |ra| tags_equal and ra.eql(b.record_v, pool),
            .string_v => |sa| tags_equal and sa.eql(b.string_v, pool),
            .lambda_v => false,
            .generated_operator_v => |operator| tags_equal and
                std.meta.eql(operator, b.generated_operator_v),
            .function_set_v => tags_equal and a.function_set_v.domain(pool).eql(b.function_set_v.domain(pool), pool) and
                a.function_set_v.codomain(pool).eql(b.function_set_v.codomain(pool), pool),
            .record_set_v => tags_equal and a.record_set_v.eql(b.record_set_v, pool),
            .tuple_set_v => tags_equal and a.tuple_set_v.eql(b.tuple_set_v, pool),
            .union_v => tags_equal and a.union_v.set(pool).eql(b.union_v.set(pool), pool),
            .cup_v => tags_equal and a.cup_v.left(pool).eql(b.cup_v.left(pool), pool) and a.cup_v.right(pool).eql(b.cup_v.right(pool), pool),
            .cap_v => tags_equal and a.cap_v.left(pool).eql(b.cap_v.left(pool), pool) and a.cap_v.right(pool).eql(b.cap_v.right(pool), pool),
            .diff_v => tags_equal and a.diff_v.left(pool).eql(b.diff_v.left(pool), pool) and a.diff_v.right(pool).eql(b.diff_v.right(pool), pool),
            .seq_set_v => tags_equal and
                a.seq_set_v.element_set(pool).eql(b.seq_set_v.element_set(pool), pool),
            .power_set_v => tags_equal and
                a.power_set_v.set(pool).eql(b.power_set_v.set(pool), pool),
        };
    }

    pub fn eql_cross_pool(
        left: Value,
        left_pool: *const ValuePool,
        right: Value,
        right_pool: *const ValuePool,
    ) bool {
        assert(left_pool.value_count <= left_pool.value_cap);
        assert(left_pool.string_count <= left_pool.string_cap);
        assert(right_pool.value_count <= right_pool.value_cap);
        assert(right_pool.string_count <= right_pool.string_cap);
        const tags_equal = left.tag() == right.tag();
        if (!tags_equal) {
            if (left == .set_v and right.is_set_like()) {
                if (concrete_finite_set_equal_cross_pool(
                    left.set_v,
                    left_pool,
                    right,
                    right_pool,
                )) |equal| return equal;
            }
            if (right == .set_v and left.is_set_like()) {
                if (concrete_finite_set_equal_cross_pool(
                    right.set_v,
                    right_pool,
                    left,
                    left_pool,
                )) |equal| return equal;
            }
            if (left == .function_v and right == .tuple_v) {
                return function_equals_tuple_cross_pool(
                    left.function_v,
                    left_pool,
                    right.tuple_v,
                    right_pool,
                );
            }
            if (left == .tuple_v and right == .function_v) {
                return function_equals_tuple_cross_pool(
                    right.function_v,
                    right_pool,
                    left.tuple_v,
                    left_pool,
                );
            }
            if (left == .range_v and right == .set_v) {
                return range_equals_set_cross_pool(
                    left.range_v,
                    right.set_v,
                    right_pool,
                );
            }
            if (left == .set_v and right == .range_v) {
                return range_equals_set_cross_pool(
                    right.range_v,
                    left.set_v,
                    left_pool,
                );
            }
            return false;
        }
        if (left_pool == right_pool and
            left != .lambda_v and
            same_repr(left, right))
        {
            return true;
        }
        return switch (left) {
            .bool_v => |value_v| value_v == right.bool_v,
            .int_v => |value_v| value_v == right.int_v,
            .model_v => |value_v| value_v == right.model_v,
            .string_v => |value_v| std.mem.eql(
                u8,
                value_v.slice(left_pool),
                right.string_v.slice(right_pool),
            ),
            .set_v => |set_v| blk: {
                const right_set = right.set_v;
                if (set_v.len != right_set.len) break :blk false;
                for (set_v.items(left_pool)) |left_item| {
                    var found = false;
                    for (right_set.items(right_pool)) |right_item| {
                        if (eql_cross_pool(
                            left_item,
                            left_pool,
                            right_item,
                            right_pool,
                        )) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) break :blk false;
                }
                break :blk true;
            },
            .function_v => |function_v| function_eql_cross_pool(
                function_v,
                left_pool,
                right.function_v,
                right_pool,
            ),
            .tuple_v => |tuple_v| blk: {
                const right_tuple = right.tuple_v;
                if (tuple_v.len != right_tuple.len) break :blk false;
                for (
                    tuple_v.items(left_pool),
                    right_tuple.items(right_pool),
                ) |left_item, right_item| {
                    if (!eql_cross_pool(
                        left_item,
                        left_pool,
                        right_item,
                        right_pool,
                    )) break :blk false;
                }
                break :blk true;
            },
            .record_v => |record_v| record_eql_cross_pool(
                record_v,
                left_pool,
                right.record_v,
                right_pool,
            ),
            .range_v => |range_v| range_v.eql(right.range_v),
            .function_set_v => |set_v| eql_cross_pool(
                set_v.domain(left_pool),
                left_pool,
                right.function_set_v.domain(right_pool),
                right_pool,
            ) and eql_cross_pool(
                set_v.codomain(left_pool),
                left_pool,
                right.function_set_v.codomain(right_pool),
                right_pool,
            ),
            .record_set_v => |set_v| blk: {
                const right_set = right.record_set_v;
                if (set_v.len != right_set.len) break :blk false;
                var index: u32 = 0;
                while (index < set_v.len) : (index += 1) {
                    const left_name =
                        set_v.field_name(left_pool, index).slice(left_pool);
                    var matched = false;
                    var right_index: u32 = 0;
                    while (right_index < right_set.len) : (right_index += 1) {
                        const right_name =
                            right_set.field_name(right_pool, right_index).slice(right_pool);
                        if (!std.mem.eql(u8, left_name, right_name)) continue;
                        matched = true;
                        if (!eql_cross_pool(
                            set_v.field_domain(left_pool, index),
                            left_pool,
                            right_set.field_domain(right_pool, right_index),
                            right_pool,
                        )) break :blk false;
                        break;
                    }
                    if (!matched) break :blk false;
                }
                break :blk true;
            },
            .tuple_set_v => |set_v| blk: {
                const right_set = right.tuple_set_v;
                if (set_v.len != right_set.len) break :blk false;
                for (
                    set_v.sets(left_pool),
                    right_set.sets(right_pool),
                ) |left_set, right_set_value| {
                    if (!eql_cross_pool(
                        left_set,
                        left_pool,
                        right_set_value,
                        right_pool,
                    )) break :blk false;
                }
                break :blk true;
            },
            .union_v => |set_v| eql_cross_pool(
                set_v.set(left_pool),
                left_pool,
                right.union_v.set(right_pool),
                right_pool,
            ),
            .cup_v, .cap_v, .diff_v => |set_v| eql_cross_pool(
                set_v.left(left_pool),
                left_pool,
                switch (right) {
                    .cup_v => |right_set| right_set.left(right_pool),
                    .cap_v => |right_set| right_set.left(right_pool),
                    .diff_v => |right_set| right_set.left(right_pool),
                    else => unreachable,
                },
                right_pool,
            ) and eql_cross_pool(
                set_v.right(left_pool),
                left_pool,
                switch (right) {
                    .cup_v => |right_set| right_set.right(right_pool),
                    .cap_v => |right_set| right_set.right(right_pool),
                    .diff_v => |right_set| right_set.right(right_pool),
                    else => unreachable,
                },
                right_pool,
            ),
            .seq_set_v => |set_v| eql_cross_pool(
                set_v.element_set(left_pool),
                left_pool,
                right.seq_set_v.element_set(right_pool),
                right_pool,
            ),
            .power_set_v => |set_v| eql_cross_pool(
                set_v.set(left_pool),
                left_pool,
                right.power_set_v.set(right_pool),
                right_pool,
            ),
            .generated_operator_v => |operator| std.meta.eql(
                operator,
                right.generated_operator_v,
            ),
            .lambda_v => false,
        };
    }

    /// A linear, sufficient proof of equality for values whose concrete
    /// representation order matches. False does not imply semantic inequality.
    pub fn eql_ordered_cross_pool(
        left: Value,
        left_pool: *const ValuePool,
        right: Value,
        right_pool: *const ValuePool,
    ) bool {
        assert(left_pool.value_count <= left_pool.value_cap);
        assert(left_pool.string_count <= left_pool.string_cap);
        assert(right_pool.value_count <= right_pool.value_cap);
        assert(right_pool.string_count <= right_pool.string_cap);
        if (left.tag() != right.tag()) return false;
        if (left_pool == right_pool and
            left != .lambda_v and
            same_repr(left, right))
        {
            return true;
        }
        return switch (left) {
            .bool_v => |value_v| value_v == right.bool_v,
            .int_v => |value_v| value_v == right.int_v,
            .model_v => |value_v| value_v == right.model_v,
            .range_v => |value_v| value_v.eql(right.range_v),
            .string_v => |value_v| std.mem.eql(
                u8,
                value_v.slice(left_pool),
                right.string_v.slice(right_pool),
            ),
            .set_v => |value_v| ordered_values_eql_cross_pool(
                value_v.items(left_pool),
                left_pool,
                right.set_v.items(right_pool),
                right_pool,
            ),
            .tuple_v => |value_v| ordered_values_eql_cross_pool(
                value_v.items(left_pool),
                left_pool,
                right.tuple_v.items(right_pool),
                right_pool,
            ),
            .function_v => |value_v| blk: {
                const right_value = right.function_v;
                break :blk ordered_values_eql_cross_pool(
                    value_v.domain.items(left_pool),
                    left_pool,
                    right_value.domain.items(right_pool),
                    right_pool,
                ) and ordered_values_eql_cross_pool(
                    value_v.entries(left_pool),
                    left_pool,
                    right_value.entries(right_pool),
                    right_pool,
                );
            },
            .record_v => |value_v| ordered_record_eql_cross_pool(
                value_v,
                left_pool,
                right.record_v,
                right_pool,
            ),
            .generated_operator_v => |operator| std.meta.eql(
                operator,
                right.generated_operator_v,
            ),
            .lambda_v,
            .function_set_v,
            .record_set_v,
            .tuple_set_v,
            .union_v,
            .cup_v,
            .cap_v,
            .diff_v,
            .seq_set_v,
            .power_set_v,
            => false,
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
            .lambda_v, .generated_operator_v => null,
            else => null,
        };
    }

    pub fn clone(self: Value, source: *const ValuePool, target: *ValuePool) error{ OutOfMemory, NotImplemented }!Value {
        assert(source.value_count <= source.value_cap);
        assert(source.string_count <= source.string_cap);
        assert(target.value_count <= target.value_cap);
        assert(target.string_count <= target.string_cap);
        if (source == target) return self;
        switch (self) {
            .bool_v, .int_v, .model_v, .range_v => return self,
            else => {},
        }
        if (!target.growable) {
            return self.clone_assume_capacity(source, target);
        }

        const snapshot = target.snapshot();
        target.growable = false;
        const cloned = self.clone_assume_capacity(source, target) catch |err| {
            target.growable = true;
            target.restore(snapshot);
            if (err != error.OutOfMemory) return err;
            try target.ensure_value_capacity(self.clone_value_count(source));
            return self.clone_assume_capacity(source, target);
        };
        target.growable = true;
        return cloned;
    }

    fn clone_assume_capacity(
        self: Value,
        source: *const ValuePool,
        target: *ValuePool,
    ) error{ OutOfMemory, NotImplemented }!Value {
        assert(source.value_count <= source.value_cap);
        assert(target.value_count <= target.value_cap);
        return switch (self) {
            .bool_v => |b| Value{ .bool_v = b },
            .int_v => |i| Value{ .int_v = i },
            .model_v => |m| Value{ .model_v = m },
            .string_v => |s| Value{ .string_v = try s.clone(source, target) },
            .set_v => |s| Value{ .set_v = try s.clone(source, target) },
            .function_v => |f| Value{ .function_v = try f.clone(source, target) },
            .tuple_v => |t| Value{ .tuple_v = try t.clone(source, target) },
            .record_v => |r| Value{ .record_v = try r.clone(source, target) },
            .lambda_v => |l| Value{ .lambda_v = l },
            .generated_operator_v => |operator| Value{
                .generated_operator_v = operator,
            },
            .function_set_v => |fs| Value{
                .function_set_v = .{
                    .domain_offset = try target.push_value(try fs.domain(source).clone_assume_capacity(source, target)),
                    .codomain_offset = try target.push_value(try fs.codomain(source).clone_assume_capacity(source, target)),
                },
            },
            .record_set_v => |rs| Value{ .record_set_v = try rs.clone(source, target) },
            .tuple_set_v => |ts| Value{ .tuple_set_v = try ts.clone(source, target) },
            .union_v => |u| Value{ .union_v = .{ .set_offset = try target.push_value(try u.set(source).clone_assume_capacity(source, target)) } },
            .cup_v => |bs| Value{
                .cup_v = .{
                    .left_offset = try target.push_value(try bs.left(source).clone_assume_capacity(source, target)),
                    .right_offset = try target.push_value(try bs.right(source).clone_assume_capacity(source, target)),
                },
            },
            .cap_v => |bs| Value{
                .cap_v = .{
                    .left_offset = try target.push_value(try bs.left(source).clone_assume_capacity(source, target)),
                    .right_offset = try target.push_value(try bs.right(source).clone_assume_capacity(source, target)),
                },
            },
            .diff_v => |bs| Value{
                .diff_v = .{
                    .left_offset = try target.push_value(try bs.left(source).clone_assume_capacity(source, target)),
                    .right_offset = try target.push_value(try bs.right(source).clone_assume_capacity(source, target)),
                },
            },
            .range_v => |r| Value{ .range_v = r },
            .seq_set_v => |ss| Value{ .seq_set_v = .{
                .element_set_offset = try target.push_value(
                    try ss.element_set(source).clone_assume_capacity(source, target),
                ),
            } },
            .power_set_v => |ps| Value{ .power_set_v = .{
                .set_offset = try target.push_value(try ps.set(source).clone_assume_capacity(source, target)),
            } },
        };
    }

    fn clone_value_count(self: Value, source: *const ValuePool) u64 {
        return switch (self) {
            .bool_v,
            .int_v,
            .model_v,
            .string_v,
            .lambda_v,
            .generated_operator_v,
            .range_v,
            => 0,
            .set_v => |s| clone_slice_value_count(s.items(source), source),
            .tuple_v => |t| clone_slice_value_count(t.items(source), source),
            .record_v => |r| clone_slice_value_count(r.fields(source), source),
            .function_v => |f| clone_slice_value_count(f.domain.items(source), source) +
                clone_slice_value_count(f.entries(source), source),
            .function_set_v => |fs| 2 +
                fs.domain(source).clone_value_count(source) +
                fs.codomain(source).clone_value_count(source),
            .record_set_v => |rs| blk: {
                var count: u64 = rs.len * 2;
                var i: u32 = 0;
                while (i < rs.len) : (i += 1) {
                    count += rs.field_domain(source, i).clone_value_count(source);
                }
                break :blk count;
            },
            .tuple_set_v => |ts| clone_slice_value_count(ts.sets(source), source),
            .union_v => |u| 1 + u.set(source).clone_value_count(source),
            .cup_v => |bs| 2 +
                bs.left(source).clone_value_count(source) +
                bs.right(source).clone_value_count(source),
            .cap_v => |bs| 2 +
                bs.left(source).clone_value_count(source) +
                bs.right(source).clone_value_count(source),
            .diff_v => |bs| 2 +
                bs.left(source).clone_value_count(source) +
                bs.right(source).clone_value_count(source),
            .seq_set_v => |ss| 1 + ss.element_set(source).clone_value_count(source),
            .power_set_v => |ps| 1 + ps.set(source).clone_value_count(source),
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
            .seq_set_v => |ss| sequence_set_member(pool, ss.element_set(pool), elem),
            .power_set_v => |ps| power_set_member(pool, ps.set(pool), elem),
            else => return false,
        };
    }

    /// Membership where the set and element live in different stable pools.
    /// This avoids cloning canonical state values into a scratch pool merely
    /// to inspect them.
    pub fn member_cross_pool(
        self: Value,
        set_pool: *const ValuePool,
        elem: Value,
        elem_pool: *const ValuePool,
    ) bool {
        if (set_pool == elem_pool) return self.member(set_pool, elem);
        return switch (self) {
            .set_v => |set| set_contains_cross_pool(
                set,
                set_pool,
                elem,
                elem_pool,
            ),
            .function_set_v => |function_set| function_set_member_cross_pool(
                set_pool,
                function_set,
                elem,
                elem_pool,
            ),
            .record_set_v => |record_set| record_set_member_cross_pool(
                set_pool,
                record_set,
                elem,
                elem_pool,
            ),
            .tuple_set_v => |tuple_set| tuple_set_member_cross_pool(
                set_pool,
                tuple_set,
                elem,
                elem_pool,
            ),
            .union_v => |union_set| union_member_cross_pool(
                set_pool,
                union_set.set(set_pool),
                elem,
                elem_pool,
            ),
            .cup_v => |binary_set| binary_set.left(set_pool).member_cross_pool(
                set_pool,
                elem,
                elem_pool,
            ) or binary_set.right(set_pool).member_cross_pool(
                set_pool,
                elem,
                elem_pool,
            ),
            .cap_v => |binary_set| binary_set.left(set_pool).member_cross_pool(
                set_pool,
                elem,
                elem_pool,
            ) and binary_set.right(set_pool).member_cross_pool(
                set_pool,
                elem,
                elem_pool,
            ),
            .diff_v => |binary_set| binary_set.left(set_pool).member_cross_pool(
                set_pool,
                elem,
                elem_pool,
            ) and !binary_set.right(set_pool).member_cross_pool(
                set_pool,
                elem,
                elem_pool,
            ),
            .range_v => |range_value| range_value.member(elem),
            .seq_set_v => |sequence_set| sequence_set_member_cross_pool(
                set_pool,
                sequence_set.element_set(set_pool),
                elem,
                elem_pool,
            ),
            .power_set_v => |power_set| power_set_member_cross_pool(
                set_pool,
                power_set.set(set_pool),
                elem,
                elem_pool,
            ),
            else => false,
        };
    }
};

test "value representation remains compact" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(GeneratedOperator));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Value));
}

fn ordered_values_eql_cross_pool(
    left: []const Value,
    left_pool: *const ValuePool,
    right: []const Value,
    right_pool: *const ValuePool,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_item, right_item| {
        if (!Value.eql_ordered_cross_pool(
            left_item,
            left_pool,
            right_item,
            right_pool,
        )) return false;
    }
    return true;
}

fn ordered_record_eql_cross_pool(
    left: Record,
    left_pool: *const ValuePool,
    right: Record,
    right_pool: *const ValuePool,
) bool {
    if (left.len != right.len) return false;
    const left_fields = left.fields(left_pool);
    const right_fields = right.fields(right_pool);
    var index: u32 = 0;
    while (index < left.len) : (index += 1) {
        const offset = index * 2;
        if (!std.mem.eql(
            u8,
            left_fields[offset].string_v.slice(left_pool),
            right_fields[offset].string_v.slice(right_pool),
        )) return false;
        if (!Value.eql_ordered_cross_pool(
            left_fields[offset + 1],
            left_pool,
            right_fields[offset + 1],
            right_pool,
        )) return false;
    }
    return true;
}

fn function_eql_cross_pool(
    left: Function,
    left_pool: *const ValuePool,
    right: Function,
    right_pool: *const ValuePool,
) bool {
    if (left.len != right.len) return false;
    const left_keys = left.domain.items(left_pool);
    const left_entries = left.entries(left_pool);
    const right_keys = right.domain.items(right_pool);
    const right_entries = right.entries(right_pool);
    assert(left_keys.len == left_entries.len);
    assert(right_keys.len == right_entries.len);

    for (left_keys, left_entries, right_keys, right_entries) |
        left_key,
        left_entry,
        right_key,
        right_entry,
    | {
        if (!Value.eql_cross_pool(
            left_key,
            left_pool,
            right_key,
            right_pool,
        )) break;
        if (!Value.eql_cross_pool(
            left_entry,
            left_pool,
            right_entry,
            right_pool,
        )) return false;
    } else {
        return true;
    }

    for (left_keys, left_entries) |left_key, left_entry| {
        var found = false;
        for (right_keys, right_entries) |right_key, right_entry| {
            if (!Value.eql_cross_pool(
                left_key,
                left_pool,
                right_key,
                right_pool,
            )) continue;
            found = true;
            if (!Value.eql_cross_pool(
                left_entry,
                left_pool,
                right_entry,
                right_pool,
            )) return false;
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn record_eql_cross_pool(
    left: Record,
    left_pool: *const ValuePool,
    right: Record,
    right_pool: *const ValuePool,
) bool {
    if (left.len != right.len) return false;
    const left_fields = left.fields(left_pool);
    const right_fields = right.fields(right_pool);

    var field_index: u32 = 0;
    while (field_index < left.len) : (field_index += 1) {
        const offset = field_index * 2;
        const left_name = left_fields[offset].string_v.slice(left_pool);
        const right_name = right_fields[offset].string_v.slice(right_pool);
        if (!std.mem.eql(u8, left_name, right_name)) break;
        if (!Value.eql_cross_pool(
            left_fields[offset + 1],
            left_pool,
            right_fields[offset + 1],
            right_pool,
        )) return false;
    } else {
        return true;
    }

    field_index = 0;
    while (field_index < left.len) : (field_index += 1) {
        const left_offset = field_index * 2;
        const left_name =
            left_fields[left_offset].string_v.slice(left_pool);
        var found = false;
        var right_index: u32 = 0;
        while (right_index < right.len) : (right_index += 1) {
            const right_offset = right_index * 2;
            const right_name =
                right_fields[right_offset].string_v.slice(right_pool);
            if (!std.mem.eql(u8, left_name, right_name)) continue;
            found = true;
            if (!Value.eql_cross_pool(
                left_fields[left_offset + 1],
                left_pool,
                right_fields[right_offset + 1],
                right_pool,
            )) return false;
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn set_contains_cross_pool(
    set: Set,
    set_pool: *const ValuePool,
    elem: Value,
    elem_pool: *const ValuePool,
) bool {
    if (set_pool == elem_pool) return set.contains(set_pool, elem);
    const items = set.items(set_pool);
    if (dense_contains_probe(items, elem)) |found| return found;
    switch (elem) {
        .bool_v => |elem_value| {
            for (items) |item| {
                if (item == .bool_v and item.bool_v == elem_value) return true;
            }
            return false;
        },
        .int_v => |elem_value| {
            for (items) |item| {
                if (item == .int_v and item.int_v == elem_value) return true;
            }
            return false;
        },
        .model_v => |elem_value| {
            for (items) |item| {
                if (item == .model_v and item.model_v == elem_value) return true;
            }
            return false;
        },
        .string_v => |elem_value| {
            const elem_bytes = elem_value.slice(elem_pool);
            for (items) |item| {
                if (item == .string_v and std.mem.eql(
                    u8,
                    item.string_v.slice(set_pool),
                    elem_bytes,
                )) return true;
            }
            return false;
        },
        else => {},
    }
    for (items) |item| {
        if (Value.eql_cross_pool(
            item,
            set_pool,
            elem,
            elem_pool,
        )) return true;
    }
    return false;
}

fn record_set_member_cross_pool(
    set_pool: *const ValuePool,
    record_set: RecordSet,
    elem: Value,
    elem_pool: *const ValuePool,
) bool {
    if (elem != .record_v or elem.record_v.len != record_set.len) return false;
    const fields = elem.record_v.fields(elem_pool);
    var field_index: u32 = 0;
    while (field_index < record_set.len) : (field_index += 1) {
        const field_name = record_set.field_name(
            set_pool,
            field_index,
        ).slice(set_pool);
        const field_offset = field_index * 2;
        const candidate_name = fields[field_offset];
        assert(candidate_name == .string_v);
        const field_value = if (std.mem.eql(
            u8,
            field_name,
            candidate_name.string_v.slice(elem_pool),
        ))
            fields[field_offset + 1]
        else
            elem.record_v.lookup(elem_pool, field_name) orelse return false;
        if (!record_set.field_domain(set_pool, field_index).member_cross_pool(
            set_pool,
            field_value,
            elem_pool,
        )) return false;
    }
    return true;
}

fn tuple_set_member_cross_pool(
    set_pool: *const ValuePool,
    tuple_set: TupleSet,
    elem: Value,
    elem_pool: *const ValuePool,
) bool {
    const component_sets = tuple_set.sets(set_pool);
    switch (elem) {
        .tuple_v => |tuple_value| {
            if (tuple_value.len != tuple_set.len) return false;
            for (component_sets, tuple_value.items(elem_pool)) |set, item| {
                if (!set.member_cross_pool(
                    set_pool,
                    item,
                    elem_pool,
                )) return false;
            }
            return true;
        },
        .function_v => |function_value| {
            if (function_value.len != tuple_set.len) return false;
            var index: u32 = 0;
            while (index < tuple_set.len) : (index += 1) {
                const item = function_value.apply(
                    elem_pool,
                    .{ .int_v = @as(i64, @intCast(index)) + 1 },
                ) orelse return false;
                if (!component_sets[index].member_cross_pool(
                    set_pool,
                    item,
                    elem_pool,
                )) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn function_set_member_cross_pool(
    set_pool: *const ValuePool,
    function_set: FunctionSet,
    elem: Value,
    elem_pool: *const ValuePool,
) bool {
    const domain = function_set.domain(set_pool);
    const codomain = function_set.codomain(set_pool);
    switch (elem) {
        .tuple_v => |tuple_value| {
            if (!domain_matches_counted_keys_cross_pool(
                domain,
                set_pool,
                tuple_value.len,
                null,
                elem_pool,
            )) return false;
            for (tuple_value.items(elem_pool)) |item| {
                if (!codomain.member_cross_pool(
                    set_pool,
                    item,
                    elem_pool,
                )) return false;
            }
            return true;
        },
        .function_v => |function_value| {
            if (!domain_matches_counted_keys_cross_pool(
                domain,
                set_pool,
                function_value.len,
                function_value.domain.items(elem_pool),
                elem_pool,
            )) return false;
            for (function_value.entries(elem_pool)) |item| {
                if (!codomain.member_cross_pool(
                    set_pool,
                    item,
                    elem_pool,
                )) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn domain_matches_counted_keys_cross_pool(
    domain: Value,
    domain_pool: *const ValuePool,
    key_count: u32,
    keys: ?[]const Value,
    key_pool: *const ValuePool,
) bool {
    const cardinality = finite_cardinality(domain_pool, domain) orelse
        return false;
    if (cardinality != key_count) return false;
    if (keys) |function_keys| {
        assert(function_keys.len == key_count);
        for (function_keys) |key| {
            if (!domain.member_cross_pool(
                domain_pool,
                key,
                key_pool,
            )) return false;
        }
        return true;
    }
    var index: u32 = 0;
    while (index < key_count) : (index += 1) {
        if (!domain.member(
            domain_pool,
            .{ .int_v = @as(i64, @intCast(index)) + 1 },
        )) return false;
    }
    return true;
}

fn sequence_set_member_cross_pool(
    set_pool: *const ValuePool,
    element_set: Value,
    elem: Value,
    elem_pool: *const ValuePool,
) bool {
    switch (elem) {
        .tuple_v => |tuple_value| {
            for (tuple_value.items(elem_pool)) |item| {
                if (!element_set.member_cross_pool(
                    set_pool,
                    item,
                    elem_pool,
                )) return false;
            }
            return true;
        },
        .function_v => |function_value| {
            var index: u32 = 0;
            while (index < function_value.len) : (index += 1) {
                const item = function_value.apply(
                    elem_pool,
                    .{ .int_v = @as(i64, @intCast(index)) + 1 },
                ) orelse return false;
                if (!element_set.member_cross_pool(
                    set_pool,
                    item,
                    elem_pool,
                )) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn power_set_member_cross_pool(
    set_pool: *const ValuePool,
    base: Value,
    elem: Value,
    elem_pool: *const ValuePool,
) bool {
    if (elem != .set_v) return false;
    for (elem.set_v.items(elem_pool)) |item| {
        if (!base.member_cross_pool(
            set_pool,
            item,
            elem_pool,
        )) return false;
    }
    return true;
}

fn union_member_cross_pool(
    set_pool: *const ValuePool,
    set: Value,
    elem: Value,
    elem_pool: *const ValuePool,
) bool {
    if (set != .set_v) return false;
    for (set.set_v.items(set_pool)) |nested| {
        if (nested.member_cross_pool(
            set_pool,
            elem,
            elem_pool,
        )) return true;
    }
    return false;
}

fn is_symbolic_finite_set(value_v: Value) bool {
    return switch (value_v) {
        .cup_v, .cap_v, .diff_v, .union_v => true,
        else => false,
    };
}

fn finite_set_extensional_equal(
    left: Value,
    right: Value,
    pool: *const ValuePool,
) ?bool {
    const left_subset = finite_set_subset(left, right, pool) orelse return null;
    if (!left_subset) return false;
    return finite_set_subset(right, left, pool);
}

fn concrete_finite_set_equal(
    concrete: Set,
    symbolic: Value,
    pool: *const ValuePool,
) ?bool {
    const cardinality = finite_cardinality(pool, symbolic) orelse return null;
    if (cardinality != concrete.len) return false;
    for (concrete.items(pool)) |item| {
        if (!symbolic.member(pool, item)) return false;
    }
    return true;
}

fn concrete_finite_set_equal_cross_pool(
    concrete: Set,
    concrete_pool: *const ValuePool,
    symbolic: Value,
    symbolic_pool: *const ValuePool,
) ?bool {
    const cardinality = finite_cardinality(symbolic_pool, symbolic) orelse
        return null;
    if (cardinality != concrete.len) return false;
    for (concrete.items(concrete_pool)) |item| {
        if (!symbolic.member_cross_pool(
            symbolic_pool,
            item,
            concrete_pool,
        )) return false;
    }
    return true;
}

fn finite_set_subset(
    left: Value,
    right: Value,
    pool: *const ValuePool,
) ?bool {
    return finite_set_support_subset(left, left, right, pool);
}

fn finite_set_support_subset(
    container: Value,
    support: Value,
    right: Value,
    pool: *const ValuePool,
) ?bool {
    return switch (support) {
        .set_v => |set| blk: {
            for (set.items(pool)) |item| {
                if (container.member(pool, item) and !right.member(pool, item)) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .range_v => |range| blk: {
            if (range.hi < range.lo) break :blk true;
            var item = range.lo;
            while (true) {
                const value_v = Value{ .int_v = item };
                if (container.member(pool, value_v) and
                    !right.member(pool, value_v))
                {
                    break :blk false;
                }
                if (item == range.hi) break;
                item += 1;
            }
            break :blk true;
        },
        .cup_v => |set| blk: {
            const left_subset = finite_set_support_subset(
                container,
                set.left(pool),
                right,
                pool,
            ) orelse break :blk null;
            if (!left_subset) break :blk false;
            break :blk finite_set_support_subset(
                container,
                set.right(pool),
                right,
                pool,
            );
        },
        .cap_v, .diff_v => |set| finite_set_support_subset(
            container,
            set.left(pool),
            right,
            pool,
        ),
        .union_v => |set| blk: {
            const sets = set.set(pool);
            if (sets != .set_v) break :blk null;
            for (sets.set_v.items(pool)) |nested| {
                if (!nested.is_set_like()) break :blk null;
                const nested_subset = finite_set_support_subset(
                    container,
                    nested,
                    right,
                    pool,
                ) orelse break :blk null;
                if (!nested_subset) break :blk false;
            }
            break :blk true;
        },
        else => null,
    };
}

fn power_set_member(pool: *const ValuePool, base: Value, elem: Value) bool {
    assert(base.is_set_like());
    if (elem != .set_v) return false;
    for (elem.set_v.items(pool)) |item| {
        if (!base.member(pool, item)) return false;
    }
    return true;
}

fn sequence_set_member(pool: *const ValuePool, element_set: Value, elem: Value) bool {
    assert(element_set.is_set_like());
    switch (elem) {
        .tuple_v => |tuple| {
            for (tuple.items(pool)) |item| {
                if (!element_set.member(pool, item)) return false;
            }
            return true;
        },
        .function_v => |function| {
            assert(function.domain.len == function.len);
            var i: u32 = 0;
            while (i < function.len) : (i += 1) {
                const item = function.apply(
                    pool,
                    Value{ .int_v = @as(i64, @intCast(i)) + 1 },
                ) orelse return false;
                if (!element_set.member(pool, item)) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn function_equals_tuple(function: Function, tuple: Tuple, pool: *const ValuePool) bool {
    if (function.len != tuple.len or function.domain.len != function.len) return false;
    const tuple_items = tuple.items(pool);
    var i: u32 = 0;
    while (i < function.len) : (i += 1) {
        const function_item = function.apply(
            pool,
            Value{ .int_v = @as(i64, @intCast(i)) + 1 },
        ) orelse return false;
        if (!function_item.eql(tuple_items[i], pool)) return false;
    }
    return true;
}

fn function_equals_tuple_cross_pool(
    function: Function,
    function_pool: *const ValuePool,
    tuple: Tuple,
    tuple_pool: *const ValuePool,
) bool {
    if (function.len != tuple.len or function.domain.len != function.len) return false;
    const tuple_items = tuple.items(tuple_pool);
    var i: u32 = 0;
    while (i < function.len) : (i += 1) {
        const function_item = function.apply(
            function_pool,
            Value{ .int_v = @as(i64, @intCast(i)) + 1 },
        ) orelse return false;
        if (!Value.eql_cross_pool(
            function_item,
            function_pool,
            tuple_items[i],
            tuple_pool,
        )) return false;
    }
    return true;
}

fn range_cardinality(range: Range) ?u64 {
    if (range.hi < range.lo) return 0;
    const count = @as(i128, range.hi) - @as(i128, range.lo) + 1;
    if (count > std.math.maxInt(u64)) return null;
    return @intCast(count);
}

fn range_equals_set(r: Range, s: Set, pool: *const ValuePool) bool {
    const items = s.items(pool);
    const cardinality = range_cardinality(r) orelse return false;
    if (items.len != cardinality) return false;
    for (items, 0..) |it, i| {
        const expected = r.lo + @as(i64, @intCast(i));
        if (it.as_int() != expected) return false;
    }
    return true;
}

fn range_equals_set_cross_pool(r: Range, s: Set, pool: *const ValuePool) bool {
    const cardinality = range_cardinality(r) orelse return false;
    if (s.len != cardinality) return false;
    for (s.items(pool), 0..) |it, i| {
        const expected = r.lo + @as(i64, @intCast(i));
        if (it.as_int() != expected) return false;
    }
    return true;
}

fn function_set_member(pool: *const ValuePool, fs: FunctionSet, elem: Value) bool {
    const domain = fs.domain(pool);
    const codomain = fs.codomain(pool);
    if (elem == .tuple_v) {
        const t = elem.tuple_v;
        if (!domain_matches_tuple_domain(domain, t, pool)) return false;
        for (t.items(pool)) |v| {
            if (!codomain.member(pool, v)) return false;
        }
        return true;
    }
    if (elem != .function_v) return false;
    const f = elem.function_v;
    if (!domain_matches_function_domain(domain, f, pool)) return false;
    const keys = f.domain.items(pool);
    for (keys) |k| {
        const v = f.apply(pool, k) orelse return false;
        if (!codomain.member(pool, v)) return false;
    }
    return true;
}

fn domain_matches_tuple_domain(domain: Value, t: Tuple, pool: *const ValuePool) bool {
    switch (domain) {
        .set_v => |s| {
            const keys = s.items(pool);
            if (keys.len != t.len) return false;
            for (keys, 0..) |k, i| {
                if (k.as_int() != @as(i64, @intCast(i + 1))) return false;
            }
            return true;
        },
        .range_v => |r| return r.lo == 1 and r.hi == @as(i64, @intCast(t.len)),
        else => return false,
    }
}

fn domain_matches_function_domain(domain: Value, f: Function, pool: *const ValuePool) bool {
    switch (domain) {
        .set_v => return f.domain.eql(domain.set_v, pool),
        .range_v => |r| {
            const keys = f.domain.items(pool);
            const cardinality = range_cardinality(r) orelse return false;
            if (keys.len != cardinality) return false;
            for (keys, 0..) |k, i| {
                const expected = r.lo + @as(i64, @intCast(i));
                if (k.as_int() != expected) return false;
            }
            return true;
        },
        .tuple_set_v => {
            const keys = f.domain.items(pool);
            const cardinality = finite_cardinality(pool, domain) orelse return false;
            if (keys.len != cardinality) return false;
            for (keys) |k| {
                if (!domain.member(pool, k)) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn finite_cardinality(pool: *const ValuePool, set: Value) ?u64 {
    switch (set) {
        .set_v => |s| return s.len,
        .range_v => |r| return range_cardinality(r),
        .tuple_set_v => |ts| {
            var total: u64 = 1;
            for (ts.sets(pool)) |component| {
                const c = finite_cardinality(pool, component) orelse return null;
                total = std.math.mul(u64, total, c) catch return null;
            }
            return total;
        },
        .record_set_v => |record_set| {
            var total: u64 = 1;
            var field_index: u32 = 0;
            while (field_index < record_set.len) : (field_index += 1) {
                const count = finite_cardinality(
                    pool,
                    record_set.field_domain(pool, field_index),
                ) orelse return null;
                total = std.math.mul(u64, total, count) catch return null;
            }
            return total;
        },
        .function_set_v => |function_set| {
            const domain_count = finite_cardinality(
                pool,
                function_set.domain(pool),
            ) orelse return null;
            const codomain_count = finite_cardinality(
                pool,
                function_set.codomain(pool),
            ) orelse return null;
            return finite_power(codomain_count, domain_count);
        },
        .power_set_v => |power_set| {
            const base_count = finite_cardinality(
                pool,
                power_set.set(pool),
            ) orelse return null;
            return finite_power(2, base_count);
        },
        else => return null,
    }
}

fn finite_power(base: u64, exponent: u64) ?u64 {
    var result: u64 = 1;
    var factor = base;
    var remaining = exponent;
    while (remaining > 0) : (remaining >>= 1) {
        if (remaining & 1 != 0) {
            result = std.math.mul(u64, result, factor) catch return null;
        }
        if (remaining > 1) {
            factor = std.math.mul(u64, factor, factor) catch return null;
        }
    }
    return result;
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
        if (dense_contains_probe(self.items(pool), v)) |found| {
            return found;
        }
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
        const src_items = self.items(source);
        const dest = try target.alloc_values(@intCast(src_items.len));
        assert(dest.len == src_items.len);
        try clone_values_assume_capacity(src_items, source, target, dest);
        const offset: u32 = @intCast((@intFromPtr(dest.ptr) - @intFromPtr(target.values.ptr)) / @sizeOf(Value));
        assert(offset + dest.len <= target.value_cap);
        return Set{ .offset = offset, .len = @intCast(src_items.len) };
    }
};

fn dense_contains_probe(items: []const Value, value: Value) ?bool {
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
    if (!same_repr(items[index_u], value)) return null;
    return true;
}

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
        if (self.len != other.len) return false;
        const other_keys = other.domain.items(pool);
        const other_entries = other.entries(pool);
        for (self.domain.items(pool), self.entries(pool)) |left_key, left_entry| {
            var found = false;
            for (other_keys, other_entries) |right_key, right_entry| {
                if (!left_key.eql(right_key, pool)) continue;
                found = true;
                if (!left_entry.eql(right_entry, pool)) return false;
                break;
            }
            if (!found) return false;
        }
        return true;
    }

    pub fn clone(self: Function, source: *const ValuePool, target: *ValuePool) error{ OutOfMemory, NotImplemented }!Function {
        assert(self.offset + self.len <= source.value_count);
        const dom = try self.domain.clone(source, target);
        const vals = self.entries(source);
        const dest = try target.alloc_values(@intCast(vals.len));
        assert(dest.len == vals.len);
        try clone_values_assume_capacity(vals, source, target, dest);
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
        const src_items = self.items(source);
        const dest = try target.alloc_values(@intCast(src_items.len));
        assert(dest.len == src_items.len);
        try clone_values_assume_capacity(src_items, source, target, dest);
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
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            const name = a[i * 2].string_v.slice(pool);
            const other_value = other.lookup(pool, name) orelse return false;
            if (!a[i * 2 + 1].eql(other_value, pool)) return false;
        }
        return true;
    }

    pub fn clone(self: Record, source: *const ValuePool, target: *ValuePool) error{ OutOfMemory, NotImplemented }!Record {
        assert(self.offset + self.len * 2 <= source.value_count);
        const fs = self.fields(source);
        const dest = try target.alloc_values(@intCast(fs.len));
        assert(dest.len == fs.len);
        for (fs, 0..) |v, i| {
            dest[i] = try v.clone_assume_capacity(source, target);
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
        if (source == target) return self;
        return try target.push_string(self.slice(source));
    }
};

fn clone_slice_value_count(values: []const Value, source: *const ValuePool) u64 {
    var count: u64 = values.len;
    for (values) |v| count += v.clone_value_count(source);
    return count;
}

fn values_are_pool_independent(values: []const Value) bool {
    if (values.len == 0) return true;
    switch (values[0]) {
        .bool_v, .int_v, .model_v, .range_v => {},
        else => return false,
    }
    for (values[1..]) |value_v| switch (value_v) {
        .bool_v, .int_v, .model_v, .range_v => {},
        else => return false,
    };
    return true;
}

fn clone_values_assume_capacity(
    source_values: []const Value,
    source: *const ValuePool,
    target: *ValuePool,
    target_values: []Value,
) error{ OutOfMemory, NotImplemented }!void {
    assert(source_values.len == target_values.len);
    if (values_are_pool_independent(source_values)) {
        @memcpy(target_values, source_values);
        return;
    }
    for (source_values, target_values) |source_value, *target_value| {
        target_value.* = try source_value.clone_assume_capacity(source, target);
    }
}

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
    /// Whether this pool is allowed to grow its backing arrays.
    growable: bool = true,
    string_intern_slots: []String = &.{},
    string_intern_log: []u32 = &.{},
    string_intern_count: u32 = 0,

    pub fn init(arena: *Arena, value_cap: u32, string_cap: u32) !ValuePool {
        assert(value_cap > 0);
        assert(string_cap > 0);
        const values = try arena.alloc(Value, value_cap);
        const strings = try arena.alloc(u8, string_cap);
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

    pub fn enable_string_interning(
        self: *ValuePool,
        slot_count: u32,
    ) !void {
        assert(self.string_intern_slots.len == 0);
        assert(slot_count >= 2);
        assert(std.math.isPowerOfTwo(slot_count));
        self.string_intern_slots = try self.arena.alloc(String, slot_count);
        self.string_intern_log = try self.arena.alloc(u32, slot_count);
        @memset(self.string_intern_slots, .{
            .offset = std.math.maxInt(u32),
            .len = 0,
        });
    }

    fn grow_values(self: *ValuePool) !void {
        assert(self.value_count <= self.value_cap);
        const new_cap_u64 = @as(u64, self.value_cap) * 2;
        if (new_cap_u64 > std.math.maxInt(u32)) return error.OutOfMemory;
        const new_cap: u32 = @intCast(new_cap_u64);
        const new_values = try self.arena.alloc(Value, new_cap);
        @memcpy(new_values[0..self.value_count], self.values[0..self.value_count]);
        self.values = new_values;
        self.value_cap = new_cap;
    }

    fn grow_strings(self: *ValuePool) !void {
        assert(self.string_count <= self.string_cap);
        const new_cap_u64 = @as(u64, self.string_cap) * 2;
        if (new_cap_u64 > std.math.maxInt(u32)) return error.OutOfMemory;
        const new_cap: u32 = @intCast(new_cap_u64);
        const new_strings = try self.arena.alloc(u8, new_cap);
        @memcpy(new_strings[0..self.string_count], self.strings[0..self.string_count]);
        self.strings = new_strings;
        self.string_cap = new_cap;
    }

    pub fn ensure_value_capacity(self: *ValuePool, additional: u64) !void {
        assert(self.value_count <= self.value_cap);
        const needed = @as(u64, self.value_count) + additional;
        while (needed > self.value_cap) {
            if (self.growable) {
                try self.grow_values();
            } else {
                return error.OutOfMemory;
            }
        }
    }

    pub fn push_value(self: *ValuePool, v: Value) !u32 {
        if (self.value_count >= self.value_cap) {
            if (self.growable) {
                try self.grow_values();
            } else {
                return error.OutOfMemory;
            }
        }
        const idx = self.value_count;
        self.values[idx] = v;
        self.value_count += 1;
        return idx;
    }

    pub fn push_values(self: *ValuePool, vs: []const Value) !u32 {
        assert(self.value_count <= self.value_cap);
        if (vs.len > std.math.maxInt(u32)) return error.OutOfMemory;
        const needed = @as(u64, self.value_count) + @as(u64, @intCast(vs.len));
        if (needed > std.math.maxInt(u32)) return error.OutOfMemory;
        while (needed > self.value_cap) {
            if (self.growable) {
                try self.grow_values();
            } else {
                return error.OutOfMemory;
            }
        }
        const start = self.value_count;
        @memcpy(self.values[start..][0..vs.len], vs);
        self.value_count = @intCast(needed);
        return start;
    }

    pub fn alloc_values(self: *ValuePool, count: u32) ![]Value {
        assert(self.value_count <= self.value_cap);
        const needed = @as(u64, self.value_count) + @as(u64, count);
        if (needed > std.math.maxInt(u32)) return error.OutOfMemory;
        while (needed > self.value_cap) {
            if (self.growable) {
                try self.grow_values();
            } else {
                return error.OutOfMemory;
            }
        }
        const start = self.value_count;
        self.value_count = @intCast(needed);
        return self.values[start..][0..count];
    }

    pub fn push_string(self: *ValuePool, s: []const u8) !String {
        if (self.string_intern_slots.len > 0) {
            const mask = self.string_intern_slots.len - 1;
            var slot_index: usize = @intCast(
                std.hash.Wyhash.hash(0, s) & mask,
            );
            var probes: usize = 0;
            while (probes < self.string_intern_slots.len) : (probes += 1) {
                const slot = &self.string_intern_slots[slot_index];
                if (slot.offset == std.math.maxInt(u32)) {
                    const interned = try self.push_string_uninterned(s);
                    slot.* = interned;
                    assert(self.string_intern_count <
                        self.string_intern_log.len);
                    self.string_intern_log[self.string_intern_count] =
                        @intCast(slot_index);
                    self.string_intern_count += 1;
                    return interned;
                }
                if (std.mem.eql(u8, slot.slice(self), s)) return slot.*;
                slot_index = (slot_index + 1) & mask;
            }
            return error.OutOfMemory;
        }
        return self.push_string_uninterned(s);
    }

    pub fn alloc_scratch_bytes(self: *ValuePool, count: u32) ![]u8 {
        assert(self.string_count <= self.string_cap);
        const needed = @as(u64, self.string_count) + count;
        if (needed > std.math.maxInt(u32)) return error.OutOfMemory;
        while (needed > self.string_cap) {
            if (self.growable) {
                try self.grow_strings();
            } else {
                return error.OutOfMemory;
            }
        }
        const start = self.string_count;
        self.string_count = @intCast(needed);
        return self.strings[start..][0..count];
    }

    fn push_string_uninterned(self: *ValuePool, s: []const u8) !String {
        assert(self.string_count <= self.string_cap);
        if (s.len > std.math.maxInt(u32)) return error.OutOfMemory;
        const needed = @as(u64, self.string_count) + @as(u64, @intCast(s.len));
        if (needed > std.math.maxInt(u32)) return error.OutOfMemory;
        while (needed > self.string_cap) {
            if (self.growable) {
                try self.grow_strings();
            } else {
                return error.OutOfMemory;
            }
        }
        const start = self.string_count;
        @memcpy(self.strings[start..][0..s.len], s);
        self.string_count = @intCast(needed);
        return String{ .offset = start, .len = @intCast(s.len) };
    }

    pub fn snapshot(self: ValuePool) Snapshot {
        assert(self.value_count <= self.value_cap);
        assert(self.string_count <= self.string_cap);
        return .{
            .value_count = self.value_count,
            .string_count = self.string_count,
            .string_intern_count = self.string_intern_count,
        };
    }

    pub fn restore(self: *ValuePool, snap: Snapshot) void {
        assert(snap.value_count <= self.value_cap);
        assert(snap.string_count <= self.string_cap);
        assert(snap.string_intern_count <= self.string_intern_count);
        while (self.string_intern_count >
            snap.string_intern_count)
        {
            self.string_intern_count -= 1;
            const slot_index =
                self.string_intern_log[self.string_intern_count];
            assert(slot_index < self.string_intern_slots.len);
            self.string_intern_slots[slot_index] = .{
                .offset = std.math.maxInt(u32),
                .len = 0,
            };
        }
        self.value_count = snap.value_count;
        self.string_count = snap.string_count;
    }

    pub const Snapshot = struct {
        value_count: u32,
        string_count: u32,
        string_intern_count: u32,
    };
};

test "value pool string interning reuses canonical bytes" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 16, 64);
    try pool.enable_string_interning(16);

    const first = try pool.push_string("status");
    const second = try pool.push_string("status");
    try std.testing.expectEqual(first.offset, second.offset);
    try std.testing.expectEqual(@as(u32, 6), pool.string_count);
}

test "set contains dense probe falls back for sparse and unsorted sets" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 16, 64);

    const items = [_]Value{
        .{ .int_v = 5 },
        .{ .int_v = 1 },
    };
    const offset = try pool.push_values(&items);
    const set_value = Set{ .offset = offset, .len = items.len };

    try std.testing.expect(set_value.contains(&pool, .{ .int_v = 1 }));
    try std.testing.expect(set_value.contains(&pool, .{ .int_v = 5 }));
    try std.testing.expect(!set_value.contains(&pool, .{ .int_v = 4 }));
}

test "symbolic finite set equality is extensional" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 32, 64);

    const singleton_offset = try pool.push_values(&.{.{ .int_v = 1 }});
    const pair_offset = try pool.push_values(&.{
        .{ .int_v = 1 },
        .{ .int_v = 2 },
    });
    const singleton = Value{ .set_v = .{
        .offset = singleton_offset,
        .len = 1,
    } };
    const pair = Value{ .set_v = .{
        .offset = pair_offset,
        .len = 2,
    } };
    const singleton_value_offset = try pool.push_value(singleton);
    const pair_value_offset = try pool.push_value(pair);
    const left = Value{ .cup_v = .{
        .left_offset = singleton_value_offset,
        .right_offset = pair_value_offset,
    } };
    const right = Value{ .cup_v = .{
        .left_offset = pair_value_offset,
        .right_offset = singleton_value_offset,
    } };

    try std.testing.expect(left.eql(right, &pool));
    try std.testing.expect(left.eql(pair, &pool));
}

test "range cardinality handles empty and full-width bounds" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 32, 64);

    const empty_offset = try pool.push_values(&.{});
    const empty = Value{ .set_v = .{
        .offset = empty_offset,
        .len = 0,
    } };
    const empty_range = Value{ .range_v = .{ .lo = 2, .hi = 0 } };
    try std.testing.expect(empty_range.eql(empty, &pool));
    try std.testing.expect(empty.eql(empty_range, &pool));
    try std.testing.expect(Value.eql_cross_pool(
        empty_range,
        &pool,
        empty,
        &pool,
    ));

    const codomain_offset = try pool.push_values(&.{.{ .bool_v = true }});
    const codomain = Value{ .set_v = .{
        .offset = codomain_offset,
        .len = 1,
    } };
    const function_set = Value{ .function_set_v = .{
        .domain_offset = try pool.push_value(empty_range),
        .codomain_offset = try pool.push_value(codomain),
    } };
    const empty_function = Value{ .function_v = .{
        .domain = empty.set_v,
        .offset = empty_offset,
        .len = 0,
    } };
    try std.testing.expect(function_set.member(&pool, empty_function));

    const full_width = Value{ .range_v = .{
        .lo = std.math.minInt(i64),
        .hi = std.math.maxInt(i64),
    } };
    try std.testing.expect(!full_width.eql(empty, &pool));
    try std.testing.expectEqual(
        @as(?u64, null),
        finite_cardinality(&pool, full_width),
    );
}

test "concrete set equals finite symbolic record set" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 128, 128);

    const type_name = try pool.push_string("type");
    const pid_name = try pool.push_string("pid");
    const termination_type = Value{
        .string_v = try pool.push_string("TerminationMessageType"),
    };
    const type_domain_offset = try pool.push_values(&.{termination_type});
    const type_domain = Value{ .set_v = .{
        .offset = type_domain_offset,
        .len = 1,
    } };
    const pid_values = [_]Value{
        .{ .model_v = 1 },
        .{ .model_v = 2 },
        .{ .model_v = 3 },
    };
    const pid_domain_offset = try pool.push_values(&pid_values);
    const pid_domain = Value{ .set_v = .{
        .offset = pid_domain_offset,
        .len = pid_values.len,
    } };
    const record_set_fields = [_]Value{
        .{ .string_v = type_name },
        type_domain,
        .{ .string_v = pid_name },
        pid_domain,
    };
    const record_set_offset = try pool.push_values(&record_set_fields);
    const symbolic = Value{ .record_set_v = .{
        .offset = record_set_offset,
        .len = 2,
    } };

    var records: [pid_values.len]Value = undefined;
    for (pid_values, 0..) |pid, index| {
        const fields = [_]Value{
            .{ .string_v = type_name },
            termination_type,
            .{ .string_v = pid_name },
            pid,
        };
        records[index] = .{ .record_v = .{
            .offset = try pool.push_values(&fields),
            .len = 2,
        } };
    }
    const concrete_offset = try pool.push_values(&records);
    const concrete = Value{ .set_v = .{
        .offset = concrete_offset,
        .len = records.len,
    } };

    try std.testing.expect(concrete.eql(symbolic, &pool));
    try std.testing.expect(symbolic.eql(concrete, &pool));

    const incomplete = Value{ .set_v = .{
        .offset = concrete_offset,
        .len = records.len - 1,
    } };
    try std.testing.expect(!incomplete.eql(symbolic, &pool));

    var clone_arena = try Arena.init(1024 * 1024);
    defer clone_arena.deinit();
    var clone_pool = try ValuePool.init(&clone_arena, 128, 128);
    const cloned_concrete = try concrete.clone(&pool, &clone_pool);
    const cloned_incomplete = try incomplete.clone(&pool, &clone_pool);

    try std.testing.expect(Value.eql_cross_pool(
        cloned_concrete,
        &clone_pool,
        symbolic,
        &pool,
    ));
    try std.testing.expect(Value.eql_cross_pool(
        symbolic,
        &pool,
        cloned_concrete,
        &clone_pool,
    ));
    try std.testing.expect(!Value.eql_cross_pool(
        cloned_incomplete,
        &clone_pool,
        symbolic,
        &pool,
    ));
}

test "symbolic membership reads an element from another pool" {
    var set_arena = try Arena.init(1024 * 1024);
    defer set_arena.deinit();
    var element_arena = try Arena.init(1024 * 1024);
    defer element_arena.deinit();
    var set_pool = try ValuePool.init(&set_arena, 128, 128);
    var element_pool = try ValuePool.init(&element_arena, 128, 128);

    const domain_offset = try set_pool.push_values(&.{
        .{ .int_v = 1 },
        .{ .int_v = 2 },
    });
    const domain = Value{ .set_v = .{
        .offset = domain_offset,
        .len = 2,
    } };
    const red = Value{ .string_v = try set_pool.push_string("red") };
    const blue = Value{ .string_v = try set_pool.push_string("blue") };
    const codomain_offset = try set_pool.push_values(&.{ red, blue });
    const codomain = Value{ .set_v = .{
        .offset = codomain_offset,
        .len = 2,
    } };
    const function_set = Value{ .function_set_v = .{
        .domain_offset = try set_pool.push_value(domain),
        .codomain_offset = try set_pool.push_value(codomain),
    } };

    const function_domain_offset = try element_pool.push_values(&.{
        .{ .int_v = 1 },
        .{ .int_v = 2 },
    });
    const function_entries_offset = try element_pool.push_values(&.{
        .{ .string_v = try element_pool.push_string("red") },
        .{ .string_v = try element_pool.push_string("blue") },
    });
    const function = Value{ .function_v = .{
        .domain = .{ .offset = function_domain_offset, .len = 2 },
        .offset = function_entries_offset,
        .len = 2,
    } };
    try std.testing.expect(function_set.member_cross_pool(
        &set_pool,
        function,
        &element_pool,
    ));

    element_pool.values[function_entries_offset + 1] = .{
        .string_v = try element_pool.push_string("green"),
    };
    try std.testing.expect(!function_set.member_cross_pool(
        &set_pool,
        function,
        &element_pool,
    ));
}

test "record equality ignores field order" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 32, 64);

    const a_name = try pool.push_string("a");
    const b_name = try pool.push_string("b");
    const left_items = [_]Value{
        .{ .string_v = a_name },
        .{ .int_v = 1 },
        .{ .string_v = b_name },
        .{ .int_v = 2 },
    };
    const right_items = [_]Value{
        .{ .string_v = b_name },
        .{ .int_v = 2 },
        .{ .string_v = a_name },
        .{ .int_v = 1 },
    };
    const left_offset = try pool.push_values(&left_items);
    const right_offset = try pool.push_values(&right_items);
    const left = Value{ .record_v = .{ .offset = left_offset, .len = 2 } };
    const right = Value{ .record_v = .{ .offset = right_offset, .len = 2 } };

    try std.testing.expect(left.eql(right, &pool));

    var clone_arena = try Arena.init(1024 * 1024);
    defer clone_arena.deinit();
    var clone_pool = try ValuePool.init(&clone_arena, 32, 64);
    const cloned_right = try right.clone(&pool, &clone_pool);
    try std.testing.expect(Value.eql_cross_pool(left, &pool, cloned_right, &clone_pool));
    try std.testing.expect(!Value.eql_ordered_cross_pool(
        left,
        &pool,
        cloned_right,
        &clone_pool,
    ));
    const cloned_left = try left.clone(&pool, &clone_pool);
    try std.testing.expect(Value.eql_ordered_cross_pool(
        left,
        &pool,
        cloned_left,
        &clone_pool,
    ));
}

test "deep cross-pool clone reserves capacity before recursive writes" {
    var source_arena = try Arena.init(1024 * 1024);
    defer source_arena.deinit();
    var target_arena = try Arena.init(1024 * 1024);
    defer target_arena.deinit();

    var source = try ValuePool.init(&source_arena, 16, 64);
    var target = try ValuePool.init(&target_arena, 1, 64);

    const inner_items = [_]Value{ .{ .int_v = 1 }, .{ .int_v = 2 } };
    const inner_offset = try source.push_values(&inner_items);
    const inner = Value{ .set_v = .{ .offset = inner_offset, .len = inner_items.len } };
    const outer_items = [_]Value{ inner, inner, inner };
    const outer_offset = try source.push_values(&outer_items);
    const outer = Value{ .set_v = .{ .offset = outer_offset, .len = outer_items.len } };

    const cloned = try outer.clone(&source, &target);
    try std.testing.expect(cloned.eql(outer, &target));
    try std.testing.expect(target.value_cap >= target.value_count);
}
