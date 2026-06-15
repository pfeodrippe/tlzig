const std = @import("std");
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

fn hash_combine(a: Fingerprint, b: Fingerprint) Fingerprint {
    return a ^ (b +% 0x9e3779b97f4a7c15 +% (a << 6) +% (a >> 2));
}

fn hash_value_inner(pool: *const ValuePool, v: Value) Fingerprint {
    var h = hash_init();
    h = hash_byte(h, @intFromEnum(v));
    switch (v) {
        .bool_v => |b| {
            h = hash_byte(h, if (b) 1 else 0);
        },
        .int_v => |i| {
            const bytes: [@sizeOf(i64)]u8 = @bitCast(i);
            h = hash_bytes(h, &bytes);
        },
        .model_v => |m| {
            const bytes: [@sizeOf(u32)]u8 = @bitCast(m);
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
                    buf[i] = hash_value_inner(pool, it);
                }
                std.mem.sort(Fingerprint, buf[0..items.len], {}, std.sort.asc(Fingerprint));
                for (buf[0..items.len]) |it_h| {
                    h = hash_combine(h, it_h);
                }
            } else {
                for (items) |it| {
                    h = hash_combine(h, hash_value_inner(pool, it));
                }
            }
        },
        .tuple_v => |t| {
            const items = t.items(pool);
            for (items) |it| {
                h = hash_byte(h, 0xab);
                h = hash_value_inner(pool, it) ^ h;
            }
        },
        .function_v => |f| {
            const keys = f.domain.items(pool);
            const vals = f.entries(pool);
            var buf: [64]Fingerprint = undefined;
            if (keys.len <= buf.len) {
                for (keys, vals, 0..) |k, val, i| {
                    var kh = hash_value_inner(pool, k);
                    kh = hash_byte(kh, 0xcd);
                    kh = hash_value_inner(pool, val) ^ kh;
                    buf[i] = kh;
                }
                std.mem.sort(Fingerprint, buf[0..keys.len], {}, std.sort.asc(Fingerprint));
                for (buf[0..keys.len]) |entry_h| {
                    h = hash_combine(h, entry_h);
                }
            } else {
                for (keys, vals) |k, val| {
                    h = hash_byte(h, 0xcd);
                    h = hash_value_inner(pool, k) ^ h;
                    h = hash_value_inner(pool, val) ^ h;
                }
            }
        },
        .record_v => |r| {
            const fs = r.fields(pool);
            var i: u32 = 0;
            while (i < r.len) : (i += 1) {
                h = hash_byte(h, 0xef);
                h = hash_combine(h, hash_value_inner(pool, fs[i * 2]));
                h = hash_combine(h, hash_value_inner(pool, fs[i * 2 + 1]));
            }
        },
    }
    return h;
}

pub fn hash_value(pool: *const ValuePool, v: Value, fp: Fingerprint) Fingerprint {
    return hash_combine(fp, hash_value_inner(pool, v));
}

pub fn hash_state(pool: *const ValuePool, values: []const Value) Fingerprint {
    var h = hash_init();
    for (values) |v| {
        h = hash_value(pool, v, h);
    }
    return h;
}
