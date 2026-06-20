const std = @import("std");
const Arena = @import("arena.zig").Arena;
const parser = @import("parser.zig");
const value = @import("value.zig");
const Value = value.Value;
const ValuePool = value.ValuePool;
const fingerprint = @import("fingerprint.zig");
const fp_set = @import("fp_set.zig");
const StateQueue = @import("queue.zig").StateQueue;

comptime {
    _ = @import("codegen.zig");
    _ = @import("config.zig");
    _ = @import("generated_runtime.zig");
    _ = @import("parser_test.zig");
}

fn make_test_arena() !Arena {
    return try Arena.init(1 * 1024 * 1024);
}

test "arena alloc and reset" {
    var arena = try make_test_arena();
    defer arena.deinit();
    const slice = try arena.alloc(u8, 100);
    try std.testing.expectEqual(slice.len, 100);
}

test "value pool push int" {
    var arena = try make_test_arena();
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 100, 100);
    _ = try pool.push_value(Value{ .int_v = 42 });
    try std.testing.expectEqual(pool.value_count, 1);
}

test "fingerprint stable" {
    var arena = try make_test_arena();
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 100, 100);
    const v = Value{ .int_v = 7 };
    const fp1 = fingerprint.hash_value(&pool, v, fingerprint.hash_init());
    const fp2 = fingerprint.hash_value(&pool, v, fingerprint.hash_init());
    try std.testing.expectEqual(fp1, fp2);
}

test "equal tuple and function sequences have equal fingerprints" {
    var arena = try make_test_arena();
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 32, 32);
    const tuple_items = try pool.alloc_values(2);
    tuple_items[0] = .{ .int_v = 10 };
    tuple_items[1] = .{ .int_v = 20 };
    const tuple = Value{ .tuple_v = .{ .offset = 0, .len = 2 } };

    const keys = try pool.alloc_values(2);
    keys[0] = .{ .int_v = 1 };
    keys[1] = .{ .int_v = 2 };
    const values = try pool.alloc_values(2);
    values[0] = .{ .int_v = 10 };
    values[1] = .{ .int_v = 20 };
    const function = Value{ .function_v = .{
        .domain = .{ .offset = 2, .len = 2 },
        .offset = 4,
        .len = 2,
    } };

    try std.testing.expect(tuple.eql(function, &pool));
    try std.testing.expectEqual(
        fingerprint.hash_value(&pool, tuple, fingerprint.hash_init()),
        fingerprint.hash_value(&pool, function, fingerprint.hash_init()),
    );
}

test "fp set insert and dedup" {
    var arena = try make_test_arena();
    defer arena.deinit();
    var set = try fp_set.FpSet.init(&arena, 64);
    try std.testing.expect(set.put(123));
    try std.testing.expect(set.put(456));
    try std.testing.expect(!set.put(123));
    try std.testing.expectEqual(set.size(), 2);
}

test "queue fifo" {
    var arena = try make_test_arena();
    defer arena.deinit();
    var q = try StateQueue.init(&arena, 4);
    try std.testing.expect(q.enqueue(1));
    try std.testing.expect(q.enqueue(2));
    try std.testing.expectEqual(q.dequeue(), 1);
    try std.testing.expectEqual(q.dequeue(), 2);
    try std.testing.expect(q.is_empty());
}
