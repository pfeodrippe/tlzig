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

fn hash_value_inner(
    pool: *const ValuePool,
    v: Value,
    permutation: ?[]const u32,
) Fingerprint {
    var h = hash_init();
    const sequence_layout = if (v == .function_v)
        sequence_function_layout(pool, v.function_v)
    else
        SequenceLayout.not_sequence;
    const tag = if (sequence_layout != .not_sequence)
        value_tag_tuple
    else
        @intFromEnum(v);
    h = hash_byte(h, tag);
    switch (v) {
        .bool_v => |b| {
            h = hash_byte(h, if (b) 1 else 0);
        },
        .int_v => |i| {
            const bytes: [@sizeOf(i64)]u8 = @bitCast(i);
            h = hash_bytes(h, &bytes);
        },
        .model_v => |m| {
            const permuted = if (permutation) |mapping|
                if (m < mapping.len) mapping[m] else m
            else
                m;
            const bytes: [@sizeOf(u32)]u8 = @bitCast(permuted);
            h = hash_bytes(h, &bytes);
        },
        .string_v => |s| {
            h = hash_bytes(h, s.slice(pool));
        },
        .set_v => |s| {
            var unordered = unordered_hash_init();
            for (s.items(pool)) |it| {
                unordered_hash_add(
                    &unordered,
                    hash_value_inner(pool, it, permutation),
                );
            }
            h = hash_combine(h, unordered_hash_finish(unordered));
        },
        .tuple_v => |t| {
            const items = t.items(pool);
            for (items) |it| {
                h = hash_byte(h, 0xab);
                h = hash_value_inner(pool, it, permutation) ^ h;
            }
        },
        .function_v => |f| {
            if (sequence_layout != .not_sequence) {
                const entries = f.entries(pool);
                if (sequence_layout == .ordered) {
                    for (entries) |item| {
                        h = hash_byte(h, 0xab);
                        h = hash_value_inner(pool, item, permutation) ^ h;
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
                    for (entry_indices[0..f.len]) |entry_index| {
                        const item = entries[entry_index];
                        h = hash_byte(h, 0xab);
                        h = hash_value_inner(pool, item, permutation) ^ h;
                    }
                    return h;
                }
                var sequence_index: u32 = 0;
                while (sequence_index < f.len) : (sequence_index += 1) {
                    const item = f.apply(pool, .{
                        .int_v = @as(i64, @intCast(sequence_index)) + 1,
                    }) orelse unreachable;
                    h = hash_byte(h, 0xab);
                    h = hash_value_inner(pool, item, permutation) ^ h;
                }
                return h;
            }
            const keys = f.domain.items(pool);
            const vals = f.entries(pool);
            var unordered = unordered_hash_init();
            for (keys, vals) |k, val| {
                var entry_hash = hash_value_inner(pool, k, permutation);
                entry_hash = hash_byte(entry_hash, 0xcd);
                entry_hash = hash_value_inner(pool, val, permutation) ^ entry_hash;
                unordered_hash_add(&unordered, entry_hash);
            }
            h = hash_combine(h, unordered_hash_finish(unordered));
        },
        .record_v => |r| {
            const fs = r.fields(pool);
            var i: u32 = 0;
            var unordered = unordered_hash_init();
            while (i < r.len) : (i += 1) {
                var field_hash = hash_value_inner(
                    pool,
                    fs[i * 2],
                    permutation,
                );
                field_hash = hash_byte(field_hash, 0xef);
                field_hash = hash_combine(
                    field_hash,
                    hash_value_inner(pool, fs[i * 2 + 1], permutation),
                );
                unordered_hash_add(&unordered, field_hash);
            }
            h = hash_combine(h, unordered_hash_finish(unordered));
        },
        .lambda_v => @panic("lambda values cannot be fingerprinted"),
        .generated_operator_v => @panic(
            "generated operator values cannot be fingerprinted",
        ),
        .function_set_v => |fs| {
            h = hash_byte(h, 0x10);
            h = hash_combine(h, hash_value_inner(pool, fs.domain(pool), permutation));
            h = hash_combine(h, hash_value_inner(pool, fs.codomain(pool), permutation));
        },
        .record_set_v => |rs| {
            h = hash_byte(h, 0x11);
            var unordered = unordered_hash_init();
            var i: u32 = 0;
            while (i < rs.len) : (i += 1) {
                var field_hash = hash_value_inner(
                    pool,
                    Value{ .string_v = rs.field_name(pool, i) },
                    permutation,
                );
                field_hash = hash_byte(field_hash, 0xee);
                field_hash = hash_combine(
                    field_hash,
                    hash_value_inner(pool, rs.field_domain(pool, i), permutation),
                );
                unordered_hash_add(&unordered, field_hash);
            }
            h = hash_combine(h, unordered_hash_finish(unordered));
        },
        .tuple_set_v => |ts| {
            h = hash_byte(h, 0x12);
            const ss = ts.sets(pool);
            for (ss) |s| {
                h = hash_combine(h, hash_value_inner(pool, s, permutation));
            }
        },
        .union_v => |u| {
            h = hash_byte(h, 0x13);
            h = hash_combine(h, hash_value_inner(pool, u.set(pool), permutation));
        },
        .cup_v => |bs| {
            h = hash_byte(h, 0x14);
            h = hash_combine(h, hash_value_inner(pool, bs.left(pool), permutation));
            h = hash_combine(h, hash_value_inner(pool, bs.right(pool), permutation));
        },
        .cap_v => |bs| {
            h = hash_byte(h, 0x15);
            h = hash_combine(h, hash_value_inner(pool, bs.left(pool), permutation));
            h = hash_combine(h, hash_value_inner(pool, bs.right(pool), permutation));
        },
        .diff_v => |bs| {
            h = hash_byte(h, 0x16);
            h = hash_combine(h, hash_value_inner(pool, bs.left(pool), permutation));
            h = hash_combine(h, hash_value_inner(pool, bs.right(pool), permutation));
        },
        .range_v => |r| {
            h = hash_byte(h, 0x17);
            const lo_bytes: [@sizeOf(i64)]u8 = @bitCast(r.lo);
            const hi_bytes: [@sizeOf(i64)]u8 = @bitCast(r.hi);
            h = hash_bytes(h, &lo_bytes);
            h = hash_bytes(h, &hi_bytes);
        },
        .seq_set_v => |ss| {
            h = hash_byte(h, 0x18);
            h = hash_combine(h, hash_value_inner(pool, ss.element_set(pool), permutation));
        },
        .power_set_v => |ps| {
            h = hash_byte(h, 0x19);
            h = hash_combine(h, hash_value_inner(pool, ps.set(pool), permutation));
        },
    }
    return h;
}

const value_tag_tuple: u8 = @intFromEnum(@import("value.zig").ValueTag.tuple_v);

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
