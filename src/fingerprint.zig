const std = @import("std");
const assert = std.debug.assert;
const Value = @import("value.zig").Value;
const ValuePool = @import("value.zig").ValuePool;

pub const Fingerprint = u64;

pub fn hash_init() Fingerprint {
    return 0xcbf29ce484222325;
}

pub fn hash_byte(fp: Fingerprint, b: u8) Fingerprint {
    return (fp ^ b) *% 0x100000001b3;
}

pub fn hash_bytes(fp: Fingerprint, bytes: []const u8) Fingerprint {
    var h = fp;
    for (bytes) |b| {
        h = hash_byte(h, b);
    }
    return h;
}

pub fn hash_combine(a: Fingerprint, b: Fingerprint) Fingerprint {
    return a ^ (b +% 0x9e3779b97f4a7c15 +% (a << 6) +% (a >> 2));
}

const UnorderedHash = struct {
    xor: Fingerprint,
    sum: Fingerprint,
    sum_square: Fingerprint,
    product: Fingerprint,
    count: u64,
};

fn unordered_hash_init() UnorderedHash {
    return .{
        .xor = 0,
        .sum = 0,
        .sum_square = 0,
        .product = 1,
        .count = 0,
    };
}

fn unordered_hash_mix(value: Fingerprint) Fingerprint {
    var mixed = value +% 0x9e3779b97f4a7c15;
    mixed = (mixed ^ (mixed >> 30)) *% 0xbf58476d1ce4e5b9;
    mixed = (mixed ^ (mixed >> 27)) *% 0x94d049bb133111eb;
    return mixed ^ (mixed >> 31);
}

fn unordered_hash_add(hash: *UnorderedHash, value: Fingerprint) void {
    const mixed = unordered_hash_mix(value);
    hash.xor ^= std.math.rotl(Fingerprint, mixed, @as(u6, @truncate(mixed)));
    hash.sum +%= mixed;
    hash.sum_square +%= mixed *% mixed;
    hash.product *%= mixed | 1;
    hash.count += 1;
}

fn unordered_hash_finish(hash: UnorderedHash) Fingerprint {
    var result = hash_init();
    result = hash_combine(result, hash.xor);
    result = hash_combine(result, hash.sum);
    result = hash_combine(result, hash.sum_square);
    result = hash_combine(result, hash.product);
    result = hash_combine(result, hash.count);
    return result;
}

const BoundedHashState = struct {
    remaining_nodes: u32,
    valid: bool = true,
};

fn hash_value_inner(
    pool: *const ValuePool,
    v: Value,
    permutation: ?[]const u32,
) Fingerprint {
    var unused: BoundedHashState = undefined;
    return hash_value_inner_impl(false, pool, v, permutation, &unused);
}

inline fn hash_value_inner_impl(
    comptime bounded: bool,
    pool: *const ValuePool,
    v: Value,
    permutation: ?[]const u32,
    bounded_state: *BoundedHashState,
) Fingerprint {
    if (bounded) {
        if (!bounded_state.valid) return 0;
        if (bounded_state.remaining_nodes == 0) {
            bounded_state.valid = false;
            return 0;
        }
        bounded_state.remaining_nodes -= 1;
    }
    return switch (v) {
        .bool_v => |value| blk: {
            var hash = hash_byte(hash_init(), @backingInt(v));
            hash = hash_byte(hash, if (value) 1 else 0);
            break :blk hash;
        },
        .int_v => |value| blk: {
            var hash = hash_byte(hash_init(), @backingInt(v));
            const bytes: [@sizeOf(i64)]u8 = @bitCast(value);
            hash = hash_bytes(hash, &bytes);
            break :blk hash;
        },
        .model_v => |value| blk: {
            var hash = hash_byte(hash_init(), @backingInt(v));
            const permuted = if (permutation) |mapping|
                if (value < mapping.len) mapping[value] else value
            else
                value;
            const bytes: [@sizeOf(u32)]u8 = @bitCast(permuted);
            hash = hash_bytes(hash, &bytes);
            break :blk hash;
        },
        .string_v => |value| blk: {
            if (bounded and value.len > 128) {
                bounded_state.valid = false;
                break :blk 0;
            }
            var hash = hash_byte(hash_init(), @backingInt(v));
            hash = hash_bytes(hash, value.slice(pool));
            break :blk hash;
        },
        .range_v => |value| blk: {
            var hash = hash_byte(hash_init(), @backingInt(v));
            hash = hash_byte(hash, 0x17);
            const lo_bytes: [@sizeOf(i64)]u8 = @bitCast(value.lo);
            const hi_bytes: [@sizeOf(i64)]u8 = @bitCast(value.hi);
            hash = hash_bytes(hash, &lo_bytes);
            hash = hash_bytes(hash, &hi_bytes);
            break :blk hash;
        },
        else => hash_value_inner_aggregate_impl(
            bounded,
            pool,
            v,
            permutation,
            bounded_state,
        ),
    };
}

fn hash_value_inner_aggregate_impl(
    comptime bounded: bool,
    pool: *const ValuePool,
    v: Value,
    permutation: ?[]const u32,
    bounded_state: *BoundedHashState,
) Fingerprint {
    var h = hash_init();
    const sequence_layout = if (v == .function_v)
        sequence_function_layout(pool, v.function_v)
    else
        SequenceLayout.not_sequence;
    const tag = if (sequence_layout != .not_sequence)
        value_tag_tuple
    else if (v == .set_delta_v)
        value_tag_set
    else
        @backingInt(v);
    h = hash_byte(h, tag);
    switch (v) {
        .bool_v, .int_v, .model_v, .string_v, .range_v => unreachable,
        .set_v => |s| {
            var unordered = unordered_hash_init();
            for (s.items(pool)) |it| {
                unordered_hash_add(
                    &unordered,
                    hash_value_inner_impl(
                        bounded,
                        pool,
                        it,
                        permutation,
                        bounded_state,
                    ),
                );
            }
            h = hash_combine(h, unordered_hash_finish(unordered));
        },
        .set_delta_v => {
            var unordered = unordered_hash_init();
            hash_set_delta_elements_impl(
                bounded,
                pool,
                v,
                permutation,
                bounded_state,
                &unordered,
            );
            h = hash_combine(h, unordered_hash_finish(unordered));
        },
        .tuple_v => |t| {
            const items = t.items(pool);
            for (items, 0..) |it, item_index| {
                h +%= state_component_from_value_hash(
                    hash_value_inner_impl(
                        bounded,
                        pool,
                        it,
                        permutation,
                        bounded_state,
                    ),
                    @intCast(item_index),
                );
            }
        },
        .function_v => |f| {
            if (sequence_layout != .not_sequence) {
                const entries = f.entries(pool);
                if (sequence_layout == .ordered) {
                    for (entries, 0..) |item, item_index| {
                        h +%= state_component_from_value_hash(
                            hash_value_inner_impl(
                                bounded,
                                pool,
                                item,
                                permutation,
                                bounded_state,
                            ),
                            @intCast(item_index),
                        );
                    }
                    return h;
                }
                if (f.len <= 64) {
                    var entry_indices: [64]u8 = undefined;
                    for (f.domain.items(pool), 0..) |key, entry_index| {
                        const sequence_index: usize = @intCast(
                            (key.as_int() orelse unreachable) - 1,
                        );
                        entry_indices[sequence_index] = @intCast(entry_index);
                    }
                    for (entry_indices[0..f.len], 0..) |entry_index, item_index| {
                        const item = entries[entry_index];
                        h +%= state_component_from_value_hash(
                            hash_value_inner_impl(
                                bounded,
                                pool,
                                item,
                                permutation,
                                bounded_state,
                            ),
                            @intCast(item_index),
                        );
                    }
                    return h;
                }
                var sequence_index: u32 = 0;
                while (sequence_index < f.len) : (sequence_index += 1) {
                    const item = f.apply(pool, .{
                        .int_v = @as(i64, @intCast(sequence_index)) + 1,
                    }) orelse unreachable;
                    h +%= state_component_from_value_hash(
                        hash_value_inner_impl(
                            bounded,
                            pool,
                            item,
                            permutation,
                            bounded_state,
                        ),
                        sequence_index,
                    );
                }
                return h;
            }
            const keys = f.domain.items(pool);
            const vals = f.entries(pool);
            var unordered = unordered_hash_init();
            for (keys, vals) |k, val| {
                var entry_hash = hash_value_inner_impl(
                    bounded,
                    pool,
                    k,
                    permutation,
                    bounded_state,
                );
                entry_hash = hash_byte(entry_hash, 0xcd);
                entry_hash = hash_value_inner_impl(
                    bounded,
                    pool,
                    val,
                    permutation,
                    bounded_state,
                ) ^ entry_hash;
                unordered_hash_add(&unordered, entry_hash);
            }
            h = hash_combine(h, unordered_hash_finish(unordered));
        },
        .record_v => |r| {
            const fs = r.fields(pool);
            var i: u32 = 0;
            var unordered = unordered_hash_init();
            while (i < r.len) : (i += 1) {
                var field_hash = hash_value_inner_impl(
                    bounded,
                    pool,
                    fs[i * 2],
                    permutation,
                    bounded_state,
                );
                field_hash = hash_byte(field_hash, 0xef);
                field_hash = hash_combine(
                    field_hash,
                    hash_value_inner_impl(
                        bounded,
                        pool,
                        fs[i * 2 + 1],
                        permutation,
                        bounded_state,
                    ),
                );
                unordered_hash_add(&unordered, field_hash);
            }
            h = hash_combine(h, unordered_hash_finish(unordered));
        },
        .lambda_v => if (bounded) {
            bounded_state.valid = false;
        } else {
            @panic("lambda values cannot be fingerprinted");
        },
        .generated_operator_v => if (bounded) {
            bounded_state.valid = false;
        } else {
            @panic("generated operator values cannot be fingerprinted");
        },
        .function_set_v => |fs| {
            h = hash_byte(h, 0x10);
            h = hash_combine(h, hash_value_inner_impl(
                bounded,
                pool,
                fs.domain(pool),
                permutation,
                bounded_state,
            ));
            h = hash_combine(h, hash_value_inner_impl(
                bounded,
                pool,
                fs.codomain(pool),
                permutation,
                bounded_state,
            ));
        },
        .record_set_v => |rs| {
            h = hash_byte(h, 0x11);
            var unordered = unordered_hash_init();
            var i: u32 = 0;
            while (i < rs.len) : (i += 1) {
                var field_hash = hash_value_inner_impl(
                    bounded,
                    pool,
                    Value{ .string_v = rs.field_name(pool, i) },
                    permutation,
                    bounded_state,
                );
                field_hash = hash_byte(field_hash, 0xee);
                field_hash = hash_combine(
                    field_hash,
                    hash_value_inner_impl(
                        bounded,
                        pool,
                        rs.field_domain(pool, i),
                        permutation,
                        bounded_state,
                    ),
                );
                unordered_hash_add(&unordered, field_hash);
            }
            h = hash_combine(h, unordered_hash_finish(unordered));
        },
        .tuple_set_v => |ts| {
            h = hash_byte(h, 0x12);
            const ss = ts.sets(pool);
            for (ss) |s| {
                h = hash_combine(h, hash_value_inner_impl(
                    bounded,
                    pool,
                    s,
                    permutation,
                    bounded_state,
                ));
            }
        },
        .union_v => |u| {
            h = hash_byte(h, 0x13);
            h = hash_combine(h, hash_value_inner_impl(
                bounded,
                pool,
                u.set(pool),
                permutation,
                bounded_state,
            ));
        },
        .cup_v => |bs| {
            h = hash_byte(h, 0x14);
            h = hash_combine(h, hash_value_inner_impl(
                bounded,
                pool,
                bs.left(pool),
                permutation,
                bounded_state,
            ));
            h = hash_combine(h, hash_value_inner_impl(
                bounded,
                pool,
                bs.right(pool),
                permutation,
                bounded_state,
            ));
        },
        .cap_v => |bs| {
            h = hash_byte(h, 0x15);
            h = hash_combine(h, hash_value_inner_impl(
                bounded,
                pool,
                bs.left(pool),
                permutation,
                bounded_state,
            ));
            h = hash_combine(h, hash_value_inner_impl(
                bounded,
                pool,
                bs.right(pool),
                permutation,
                bounded_state,
            ));
        },
        .diff_v => |bs| {
            h = hash_byte(h, 0x16);
            h = hash_combine(h, hash_value_inner_impl(
                bounded,
                pool,
                bs.left(pool),
                permutation,
                bounded_state,
            ));
            h = hash_combine(h, hash_value_inner_impl(
                bounded,
                pool,
                bs.right(pool),
                permutation,
                bounded_state,
            ));
        },
        .seq_set_v => |ss| {
            h = hash_byte(h, 0x18);
            h = hash_combine(h, hash_value_inner_impl(
                bounded,
                pool,
                ss.element_set(pool),
                permutation,
                bounded_state,
            ));
        },
        .power_set_v => |ps| {
            h = hash_byte(h, 0x19);
            h = hash_combine(h, hash_value_inner_impl(
                bounded,
                pool,
                ps.set(pool),
                permutation,
                bounded_state,
            ));
        },
    }
    return h;
}

pub fn hash_value_unseeded_bounded(
    pool: *const ValuePool,
    value: Value,
    remaining_nodes: *u32,
) ?Fingerprint {
    var bounded_state = BoundedHashState{
        .remaining_nodes = remaining_nodes.*,
    };
    const hash = hash_value_inner_impl(
        true,
        pool,
        value,
        null,
        &bounded_state,
    );
    remaining_nodes.* = bounded_state.remaining_nodes;
    return if (bounded_state.valid) hash else null;
}

const value_tag_tuple: u8 = @backingInt(@import("value.zig").ValueTag.tuple_v);
const value_tag_set: u8 = @backingInt(@import("value.zig").ValueTag.set_v);

fn hash_set_delta_elements_impl(
    comptime bounded: bool,
    pool: *const ValuePool,
    set_value: Value,
    permutation: ?[]const u32,
    bounded_state: *BoundedHashState,
    unordered: *UnorderedHash,
) void {
    switch (set_value) {
        .set_v => |set| {
            for (set.items(pool)) |item| {
                unordered_hash_add(
                    unordered,
                    hash_value_inner_impl(
                        bounded,
                        pool,
                        item,
                        permutation,
                        bounded_state,
                    ),
                );
            }
        },
        .set_delta_v => |delta| {
            hash_set_delta_elements_impl(
                bounded,
                pool,
                delta.base(pool),
                permutation,
                bounded_state,
                unordered,
            );
            hash_set_delta_elements_impl(
                bounded,
                pool,
                .{ .set_v = delta.additions(pool) },
                permutation,
                bounded_state,
                unordered,
            );
        },
        else => unreachable,
    }
}

const SequenceLayout = enum {
    not_sequence,
    ordered,
    unordered,
};

fn sequence_function_layout(
    pool: *const ValuePool,
    function: @import("value.zig").Function,
) SequenceLayout {
    if (function.domain.len != function.len) return .not_sequence;
    var ordered = true;
    var seen: u64 = 0;
    for (function.domain.items(pool), 0..) |key, storage_index| {
        const raw_index = key.as_int() orelse return .not_sequence;
        if (raw_index < 1 or
            raw_index > @as(i64, @intCast(function.len)))
        {
            return .not_sequence;
        }
        if (raw_index != @as(i64, @intCast(storage_index + 1))) {
            ordered = false;
        }
        if (function.len <= 64) {
            const bit: u6 = @intCast(raw_index - 1);
            const mask = @as(u64, 1) << bit;
            if (seen & mask != 0) return .not_sequence;
            seen |= mask;
        }
    }
    return if (ordered) .ordered else .unordered;
}

/// Operator values are executable closures, not mathematical values with a
/// stable fingerprint. Callers using fingerprints as optional cache keys must
/// reject them even when they are nested inside another value.
pub fn value_is_hashable_bounded(
    pool: *const ValuePool,
    value: Value,
    remaining_nodes: *u32,
) bool {
    return hash_value_unseeded_bounded(
        pool,
        value,
        remaining_nodes,
    ) != null;
}

pub fn hash_value(pool: *const ValuePool, v: Value, fp: Fingerprint) Fingerprint {
    return hash_combine(fp, hash_value_inner(pool, v, null));
}

pub fn hash_value_unseeded(
    pool: *const ValuePool,
    value: Value,
) Fingerprint {
    return hash_value_inner(pool, value, null);
}

pub fn state_component_from_value_hash(
    value_hash: Fingerprint,
    variable_index: u32,
) Fingerprint {
    const indexed = hash_combine(
        value_hash,
        @as(Fingerprint, variable_index) *% 0x9e3779b97f4a7c15,
    );
    return unordered_hash_mix(indexed);
}

pub fn hash_state_indexed(
    default_pool: *const ValuePool,
    state: anytype,
) Fingerprint {
    var hash = hash_init();
    for (state.values, 0..) |value, variable_index| {
        hash +%= state_component_from_value_hash(
            hash_value_unseeded(
                state.value_pool(@intCast(variable_index), default_pool),
                value,
            ),
            @intCast(variable_index),
        );
    }
    return hash;
}

pub fn replace_state_value(
    state_hash: Fingerprint,
    variable_index: u32,
    old_pool: *const ValuePool,
    old_value: Value,
    new_pool: *const ValuePool,
    new_value: Value,
) Fingerprint {
    return replace_state_value_hashes(
        state_hash,
        variable_index,
        hash_value_unseeded(old_pool, old_value),
        hash_value_unseeded(new_pool, new_value),
    );
}

pub fn replace_state_value_hashes(
    state_hash: Fingerprint,
    variable_index: u32,
    old_value_hash: Fingerprint,
    new_value_hash: Fingerprint,
) Fingerprint {
    return state_hash -%
        state_component_from_value_hash(old_value_hash, variable_index) +%
        state_component_from_value_hash(new_value_hash, variable_index);
}

pub fn hash_value_permuted(
    pool: *const ValuePool,
    v: Value,
    permutation: ?[]const u32,
) Fingerprint {
    return hash_value_inner(pool, v, permutation);
}

pub fn hash_state_tuple_projection(
    default_pool: *const ValuePool,
    state: anytype,
    variable_indices: []const u16,
    permutation: ?[]const u32,
) Fingerprint {
    assert(default_pool.value_count <= default_pool.value_cap);
    var hash = hash_byte(hash_init(), value_tag_tuple);
    for (variable_indices, 0..) |variable_index, item_index| {
        assert(variable_index < state.values.len);
        hash +%= state_component_from_value_hash(
            hash_value_inner(
                state.value_pool(variable_index, default_pool),
                state.values[variable_index],
                permutation,
            ),
            @intCast(item_index),
        );
    }
    return hash;
}

pub fn hash_state(pool: *const ValuePool, values: []const Value) Fingerprint {
    assert(pool.value_count <= pool.value_cap);
    var h = hash_init();
    for (values) |v| {
        h = hash_value(pool, v, h);
    }
    return h;
}

pub fn hash_state_permuted(
    pool: *const ValuePool,
    values: []const Value,
    permutation: []const u32,
) Fingerprint {
    var h = hash_init();
    for (values) |v| {
        h = hash_combine(h, hash_value_inner(pool, v, permutation));
    }
    return h;
}

test "bounded value hashing matches the canonical fingerprint in one pass" {
    const Arena = @import("arena.zig").Arena;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 64, 64);
    const tuple_offset = try pool.push_values(&.{
        .{ .int_v = 1 },
        .{ .int_v = 2 },
    });
    const set_offset = try pool.push_values(&.{
        .{ .tuple_v = .{ .offset = tuple_offset, .len = 2 } },
        .{ .bool_v = true },
    });
    const aggregate = Value{ .set_v = .{
        .offset = set_offset,
        .len = 2,
    } };

    var sufficient_nodes: u32 = 8;
    try std.testing.expectEqual(
        hash_value_unseeded(&pool, aggregate),
        hash_value_unseeded_bounded(
            &pool,
            aggregate,
            &sufficient_nodes,
        ).?,
    );
    try std.testing.expectEqual(@as(u32, 3), sufficient_nodes);

    var insufficient_nodes: u32 = 4;
    try std.testing.expectEqual(
        @as(?Fingerprint, null),
        hash_value_unseeded_bounded(
            &pool,
            aggregate,
            &insufficient_nodes,
        ),
    );
}

test "canonical set delta hashes as its concrete finite set" {
    const Arena = @import("arena.zig").Arena;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 128, 128);

    const base_items = [_]Value{
        .{ .int_v = 1 },
        .{ .int_v = 2 },
        .{ .int_v = 3 },
        .{ .int_v = 4 },
    };
    const base_items_offset = try pool.push_values(&base_items);
    const base_offset = try pool.push_value(.{ .set_v = .{
        .offset = base_items_offset,
        .len = base_items.len,
    } });
    const addition_items = [_]Value{
        .{ .int_v = 5 },
        .{ .int_v = 6 },
    };
    const additions_offset = try pool.push_values(&addition_items);
    const delta = Value{ .set_delta_v = .{
        .base_offset = base_offset,
        .additions_offset = additions_offset,
        .additions_len = addition_items.len,
        .depth = 1,
    } };
    const concrete_items = base_items ++ addition_items;
    const concrete_offset = try pool.push_values(&concrete_items);
    const concrete = Value{ .set_v = .{
        .offset = concrete_offset,
        .len = concrete_items.len,
    } };

    try std.testing.expectEqual(
        hash_value_unseeded(&pool, concrete),
        hash_value_unseeded(&pool, delta),
    );
}

test "state tuple projection hashes values from mixed pools without cloning" {
    const Arena = @import("arena.zig").Arena;
    const MixedState = struct {
        values: []const Value,
        borrowed_pool: *const ValuePool,

        fn value_pool(
            self: *const @This(),
            variable_index: u32,
            default_pool: *const ValuePool,
        ) *const ValuePool {
            return if (variable_index == 1)
                self.borrowed_pool
            else
                default_pool;
        }
    };

    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var default_pool = try ValuePool.init(&arena, 64, 64);
    var borrowed_pool = try ValuePool.init(&arena, 64, 64);
    var materialized_pool = try ValuePool.init(&arena, 64, 64);

    const default_value = Value{
        .string_v = try default_pool.push_string("default"),
    };
    const borrowed_value = Value{
        .string_v = try borrowed_pool.push_string("borrowed"),
    };
    const values = [_]Value{ default_value, borrowed_value };
    const state = MixedState{
        .values = &values,
        .borrowed_pool = &borrowed_pool,
    };

    const materialized_values = [_]Value{
        try default_value.clone(&default_pool, &materialized_pool),
        try borrowed_value.clone(&borrowed_pool, &materialized_pool),
    };
    const tuple_offset = try materialized_pool.push_values(
        &materialized_values,
    );
    const materialized_tuple = Value{ .tuple_v = .{
        .offset = tuple_offset,
        .len = materialized_values.len,
    } };

    try std.testing.expectEqual(
        hash_value_unseeded(&materialized_pool, materialized_tuple),
        hash_state_tuple_projection(
            &default_pool,
            &state,
            &.{ 0, 1 },
            null,
        ),
    );

    const replacement_value = Value{
        .string_v = try borrowed_pool.push_string("replacement"),
    };
    const replacement_values = [_]Value{ default_value, replacement_value };
    const replacement_state = MixedState{
        .values = &replacement_values,
        .borrowed_pool = &borrowed_pool,
    };
    const incremental = replace_state_value_hashes(
        hash_state_tuple_projection(
            &default_pool,
            &state,
            &.{ 0, 1 },
            null,
        ),
        1,
        hash_value_unseeded(&borrowed_pool, borrowed_value),
        hash_value_unseeded(&borrowed_pool, replacement_value),
    );
    try std.testing.expectEqual(
        hash_state_tuple_projection(
            &default_pool,
            &replacement_state,
            &.{ 0, 1 },
            null,
        ),
        incremental,
    );
}
