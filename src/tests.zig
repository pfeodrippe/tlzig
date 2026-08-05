const std = @import("std");
const Arena = @import("arena.zig").Arena;
const parser = @import("parser.zig");
const value = @import("value.zig");
const Value = value.Value;
const ValuePool = value.ValuePool;
const fingerprint = @import("fingerprint.zig");
const fp_set = @import("fp_set.zig");
const StateQueue = @import("queue.zig").StateQueue;
const StateStore = @import("state.zig").StateStore;

comptime {
    _ = @import("codegen.zig");
    _ = @import("config.zig");
    _ = @import("generated_runtime.zig");
    _ = @import("parser_test.zig");
}

fn make_test_arena() !Arena {
    return try Arena.init(1 * 1024 * 1024);
}

fn test_value_offset(pool: *const ValuePool, values: []const Value) u32 {
    const base = @intFromPtr(pool.values.ptr);
    const addr = @intFromPtr(values.ptr);
    std.debug.assert(addr >= base);
    const bytes = addr - base;
    std.debug.assert(bytes % @sizeOf(Value) == 0);
    return @intCast(bytes / @sizeOf(Value));
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

test "incremental state fingerprint matches full recomputation" {
    var arena = try make_test_arena();
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 16, 16);

    var old_values = [_]Value{
        .{ .int_v = 7 },
        .{ .bool_v = false },
        .{ .int_v = 11 },
    };
    var new_values = old_values;
    new_values[1] = .{ .bool_v = true };
    const old_state = StateStore.State{
        .level = 0,
        .pred = 0,
        .changed_mask = 0,
        .borrowed_pool = null,
        .values = &old_values,
    };
    const new_state = StateStore.State{
        .level = 1,
        .pred = 0,
        .changed_mask = 1 << 1,
        .borrowed_pool = null,
        .values = &new_values,
    };

    const old_hash = fingerprint.hash_state_indexed(&pool, &old_state);
    const incremental = fingerprint.replace_state_value(
        old_hash,
        1,
        &pool,
        old_values[1],
        &pool,
        new_values[1],
    );
    try std.testing.expectEqual(
        fingerprint.hash_state_indexed(&pool, &new_state),
        incremental,
    );
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

test "record equality and fingerprints ignore field order" {
    var arena = try make_test_arena();
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 32, 32);
    const a = try pool.push_string("a");
    const b = try pool.push_string("b");

    const left_fields = try pool.alloc_values(4);
    const left_offset = test_value_offset(&pool, left_fields);
    left_fields[0] = .{ .string_v = a };
    left_fields[1] = .{ .int_v = 1 };
    left_fields[2] = .{ .string_v = b };
    left_fields[3] = .{ .int_v = 2 };
    const left = Value{ .record_v = .{ .offset = left_offset, .len = 2 } };

    const right_fields = try pool.alloc_values(4);
    const right_offset = test_value_offset(&pool, right_fields);
    right_fields[0] = .{ .string_v = b };
    right_fields[1] = .{ .int_v = 2 };
    right_fields[2] = .{ .string_v = a };
    right_fields[3] = .{ .int_v = 1 };
    const right = Value{ .record_v = .{ .offset = right_offset, .len = 2 } };

    try std.testing.expect(left.eql(right, &pool));
    try std.testing.expect(Value.eql_cross_pool(left, &pool, right, &pool));
    try std.testing.expectEqual(
        fingerprint.hash_value(&pool, left, fingerprint.hash_init()),
        fingerprint.hash_value(&pool, right, fingerprint.hash_init()),
    );
}

test "function equality ignores domain storage order" {
    var arena = try make_test_arena();
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 64, 32);

    const left_keys = try pool.alloc_values(2);
    const left_keys_offset = test_value_offset(&pool, left_keys);
    left_keys[0] = .{ .int_v = 1 };
    left_keys[1] = .{ .int_v = 2 };
    const left_values = try pool.alloc_values(2);
    const left_values_offset = test_value_offset(&pool, left_values);
    left_values[0] = .{ .int_v = 10 };
    left_values[1] = .{ .int_v = 20 };
    const left = Value{ .function_v = .{
        .domain = .{ .offset = left_keys_offset, .len = 2 },
        .offset = left_values_offset,
        .len = 2,
    } };

    const right_keys = try pool.alloc_values(2);
    const right_keys_offset = test_value_offset(&pool, right_keys);
    right_keys[0] = .{ .int_v = 2 };
    right_keys[1] = .{ .int_v = 1 };
    const right_values = try pool.alloc_values(2);
    const right_values_offset = test_value_offset(&pool, right_values);
    right_values[0] = .{ .int_v = 20 };
    right_values[1] = .{ .int_v = 10 };
    const right = Value{ .function_v = .{
        .domain = .{ .offset = right_keys_offset, .len = 2 },
        .offset = right_values_offset,
        .len = 2,
    } };

    try std.testing.expect(left.eql(right, &pool));
    try std.testing.expect(Value.eql_cross_pool(left, &pool, right, &pool));
    try std.testing.expectEqual(
        fingerprint.hash_value(&pool, left, fingerprint.hash_init()),
        fingerprint.hash_value(&pool, right, fingerprint.hash_init()),
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
