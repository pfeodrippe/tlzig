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
    count: u64,
};

fn unordered_hash_init() UnorderedHash {
    return .{
        .xor = 0,
        .sum = 0,
        .count = 0,
    };
}

fn unordered_hash_add(hash: *UnorderedHash, value: Fingerprint) void {
    hash.xor ^= value;
    hash.sum +%= value;
    hash.count += 1;
}

fn unordered_hash_finish(hash: UnorderedHash) Fingerprint {
    var result = hash_init();
    result = hash_combine(result, hash.xor);
    result = hash_combine(result, hash.sum);
    result = hash_combine(result, hash.count);
    return result;
}

fn hash_value_inner(
    pool: *const ValuePool,
    v: Value,
    permutation: ?[]const u32,
) Fingerprint {
    var h = hash_init();
    const function_is_tuple = v == .function_v and is_sequence_function(pool, v.function_v);
    const tag = if (function_is_tuple) value_tag_tuple else @intFromEnum(v);
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
            const items = s.items(pool);
            var buf: [64]Fingerprint = undefined;
            if (items.len <= buf.len) {
                for (items, 0..) |it, i| {
                    buf[i] = hash_value_inner(pool, it, permutation);
                }
                std.mem.sort(Fingerprint, buf[0..items.len], {}, std.sort.asc(Fingerprint));
                for (buf[0..items.len]) |it_h| {
                    h = hash_combine(h, it_h);
                }
            } else {
                var unordered = unordered_hash_init();
                for (items) |it| {
                    unordered_hash_add(
                        &unordered,
                        hash_value_inner(pool, it, permutation),
                    );
                }
                h = hash_combine(h, unordered_hash_finish(unordered));
            }
        },
        .tuple_v => |t| {
            const items = t.items(pool);
            for (items) |it| {
                h = hash_byte(h, 0xab);
                h = hash_value_inner(pool, it, permutation) ^ h;
            }
        },
        .function_v => |f| {
            if (function_is_tuple) {
                var i: u32 = 0;
                while (i < f.len) : (i += 1) {
                    const item = f.apply(
                        pool,
                        Value{ .int_v = @as(i64, @intCast(i)) + 1 },
                    ) orelse unreachable;
                    h = hash_byte(h, 0xab);
                    h = hash_value_inner(pool, item, permutation) ^ h;
                }
                return h;
            }
            const keys = f.domain.items(pool);
            const vals = f.entries(pool);
            var buf: [64]Fingerprint = undefined;
            if (keys.len <= buf.len) {
                for (keys, vals, 0..) |k, val, i| {
                    var kh = hash_value_inner(pool, k, permutation);
                    kh = hash_byte(kh, 0xcd);
                    kh = hash_value_inner(pool, val, permutation) ^ kh;
                    buf[i] = kh;
                }
                std.mem.sort(Fingerprint, buf[0..keys.len], {}, std.sort.asc(Fingerprint));
                for (buf[0..keys.len]) |entry_h| {
                    h = hash_combine(h, entry_h);
                }
            } else {
                var unordered = unordered_hash_init();
                for (keys, vals) |k, val| {
                    var entry_hash = hash_value_inner(pool, k, permutation);
                    entry_hash = hash_byte(entry_hash, 0xcd);
                    entry_hash =
                        hash_value_inner(pool, val, permutation) ^ entry_hash;
                    unordered_hash_add(&unordered, entry_hash);
                }
                h = hash_combine(h, unordered_hash_finish(unordered));
            }
        },
        .record_v => |r| {
            const fs = r.fields(pool);
            var buf: [64]Fingerprint = undefined;
            if (r.len <= buf.len) {
                var i: u32 = 0;
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
                    buf[i] = field_hash;
                }
                std.mem.sort(
                    Fingerprint,
                    buf[0..r.len],
                    {},
                    std.sort.asc(Fingerprint),
                );
                for (buf[0..r.len]) |field_hash| {
                    h = hash_combine(h, field_hash);
                }
                return h;
            }
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
            var buf: [64]Fingerprint = undefined;
            if (rs.len <= buf.len) {
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
                    buf[i] = field_hash;
                }
                std.mem.sort(
                    Fingerprint,
                    buf[0..rs.len],
                    {},
                    std.sort.asc(Fingerprint),
                );
                for (buf[0..rs.len]) |field_hash| {
                    h = hash_combine(h, field_hash);
                }
            } else {
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
            }
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

fn is_sequence_function(pool: *const ValuePool, function: @import("value.zig").Function) bool {
    if (function.domain.len != function.len) return false;
    var i: u32 = 0;
    while (i < function.len) : (i += 1) {
        if (function.apply(
            pool,
            Value{ .int_v = @as(i64, @intCast(i)) + 1 },
        ) == null) return false;
    }
    return true;
}

pub fn hash_value(pool: *const ValuePool, v: Value, fp: Fingerprint) Fingerprint {
    return hash_combine(fp, hash_value_inner(pool, v, null));
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
