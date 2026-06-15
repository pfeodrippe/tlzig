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

pub fn hash_value(pool: *const ValuePool, v: Value, fp: Fingerprint) Fingerprint {
    var h = hash_byte(fp, @intFromEnum(v));
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
            for (items) |it| {
                h = hash_value(pool, it, h);
            }
        },
        .tuple_v => |t| {
            const items = t.items(pool);
            for (items) |it| {
                h = hash_value(pool, it, h);
            }
        },
        .function_v => |f| {
            const keys = f.domain.items(pool);
            const vals = f.entries(pool);
            for (keys, vals) |k, val| {
                h = hash_value(pool, k, h);
                h = hash_value(pool, val, h);
            }
        },
        .record_v => |r| {
            const fs = r.fields(pool);
            var i: u32 = 0;
            while (i < r.len) : (i += 1) {
                h = hash_value(pool, fs[i * 2], h);
                h = hash_value(pool, fs[i * 2 + 1], h);
            }
        },
    }
    return h;
}

pub fn hash_state(pool: *const ValuePool, values: []const Value) Fingerprint {
    var h = hash_init();
    for (values) |v| {
        h = hash_value(pool, v, h);
    }
    return h;
}
