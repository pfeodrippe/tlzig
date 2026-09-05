const std = @import("std");
const assert = std.debug.assert;
const Arena = @import("arena.zig").Arena;
const value_module = @import("value.zig");
const Value = value_module.Value;
const ValueTag = value_module.ValueTag;
const ValuePool = value_module.ValuePool;

pub fn canonical_value_capacity(
    arena_bytes: u64,
    max_states: u32,
    values_per_state: u32,
) u32 {
    assert(arena_bytes > 0);
    assert(max_states > 0);
    assert(values_per_state > 0);

    const requested = @as(u64, max_states) * values_per_state;
    const arena_budget = arena_bytes / 2 / @sizeOf(Value);
    const capacity = @min(
        @max(requested, 1_000_000),
        arena_budget,
        std.math.maxInt(u32),
    );
    return @intCast(capacity);
}

pub const StateStore = struct {
    arena: *Arena,
    variable_names: []const []const u8,
    states: []State,
    state_values: StateValueArrays,
    count: u32,
    cap: u32,
    values_pool: ValuePool,

    pub const Storage = enum(u8) {
        full,
        compact,
    };

    const StateValueArrays = union(Storage) {
        full: []Value,
        compact: []CompactValue,
    };

    /// Canonical state roots stay inline so reading a state does not chase a
    /// random descriptor in the canonical pool. Nested aggregate contents are
    /// still addressed by stable u32 pool offsets.
    pub const CompactValue = extern struct {
        word_0: u32,
        word_1: u32,
        tag_payload: u32,

        const tag_bits = 5;
        const tag_shift = 32 - tag_bits;
        const payload_mask = (@as(u32, 1) << tag_shift) - 1;
        const payload_sign_bit = @as(u32, 1) << (tag_shift - 1);
        const indirect_tag = (@as(u32, 1) << tag_bits) - 1;

        pub fn init(value_v: Value) ?CompactValue {
            var result = CompactValue{
                .word_0 = 0,
                .word_1 = 0,
                .tag_payload = @as(u32, @backingInt(value_v.tag())) << tag_shift,
            };
            switch (value_v) {
                .bool_v => |payload| result.word_0 = @intFromBool(payload),
                .int_v => |payload| result.set_u64(@bitCast(payload)),
                .set_v => |payload| result.set_offset_length(
                    payload.offset,
                    payload.len,
                ),
                .function_v => |payload| {
                    assert(payload.domain.len == payload.len);
                    if (payload.len > payload_mask) return null;
                    result.word_0 = payload.domain.offset;
                    result.word_1 = payload.offset;
                    result.set_payload(payload.len);
                },
                .tuple_v => |payload| result.set_offset_length(
                    payload.offset,
                    payload.len,
                ),
                .record_v => |payload| result.set_offset_length(
                    payload.offset,
                    payload.len,
                ),
                .string_v => |payload| result.set_offset_length(
                    payload.offset,
                    payload.len,
                ),
                .model_v => |payload| result.word_0 = payload,
                .lambda_v => |payload| result.set_u64(@intFromPtr(payload)),
                .generated_operator_v => return null,
                .function_set_v => |payload| {
                    result.word_0 = payload.domain_offset;
                    result.word_1 = payload.codomain_offset;
                },
                .record_set_v => |payload| result.set_offset_length(
                    payload.offset,
                    payload.len,
                ),
                .tuple_set_v => |payload| result.set_offset_length(
                    payload.offset,
                    payload.len,
                ),
                .union_v => |payload| result.word_0 = payload.set_offset,
                .cup_v, .cap_v, .diff_v => |payload| {
                    result.word_0 = payload.left_offset;
                    result.word_1 = payload.right_offset;
                },
                .range_v => |payload| {
                    const delta = std.math.sub(i64, payload.hi, payload.lo) catch
                        return null;
                    const delta_min = -(@as(i64, 1) << (tag_shift - 1));
                    const delta_max = (@as(i64, 1) << (tag_shift - 1)) - 1;
                    if (delta < delta_min or delta > delta_max) return null;
                    result.set_u64(@bitCast(payload.lo));
                    const delta_i32: i32 = @intCast(delta);
                    result.set_payload(@as(u32, @bitCast(delta_i32)) & payload_mask);
                },
                .seq_set_v => |payload| {
                    result.word_0 = payload.element_set_offset;
                },
                .power_set_v => |payload| result.word_0 = payload.set_offset,
                .set_delta_v => |payload| {
                    if (payload.depth > payload_mask >> 16) return null;
                    result.word_0 = payload.base_offset;
                    result.word_1 = payload.additions_offset;
                    result.set_payload(@as(u32, payload.additions_len) |
                        (@as(u32, payload.depth) << 16));
                },
            }
            return result;
        }

        pub fn init_indirect(handle: u32) CompactValue {
            return .{
                .word_0 = handle,
                .word_1 = 0,
                .tag_payload = indirect_tag << tag_shift,
            };
        }

        pub fn value(self: CompactValue, pool: *const ValuePool) Value {
            const encoded_tag = self.storage_tag();
            if (encoded_tag == indirect_tag) {
                assert(self.word_0 < pool.value_count);
                return pool.values[self.word_0];
            }
            const tag: ValueTag = @fromBackingInt(@intCast(encoded_tag));
            return switch (tag) {
                .bool_v => .{ .bool_v = self.word_0 != 0 },
                .int_v => .{ .int_v = @bitCast(self.get_u64()) },
                .set_v => .{ .set_v = self.offset_length() },
                .function_v => .{ .function_v = .{
                    .domain = .{ .offset = self.word_0, .len = self.small_payload() },
                    .offset = self.word_1,
                    .len = self.small_payload(),
                } },
                .tuple_v => .{ .tuple_v = .{
                    .offset = self.word_0,
                    .len = self.word_1,
                } },
                .record_v => .{ .record_v = .{
                    .offset = self.word_0,
                    .len = self.word_1,
                } },
                .string_v => .{ .string_v = .{
                    .offset = self.word_0,
                    .len = self.word_1,
                } },
                .model_v => .{ .model_v = self.word_0 },
                .lambda_v => .{ .lambda_v = @ptrFromInt(self.get_u64()) },
                .generated_operator_v => unreachable,
                .function_set_v => .{ .function_set_v = .{
                    .domain_offset = self.word_0,
                    .codomain_offset = self.word_1,
                } },
                .record_set_v => .{ .record_set_v = .{
                    .offset = self.word_0,
                    .len = self.word_1,
                } },
                .tuple_set_v => .{ .tuple_set_v = .{
                    .offset = self.word_0,
                    .len = self.word_1,
                } },
                .union_v => .{ .union_v = .{ .set_offset = self.word_0 } },
                .cup_v => .{ .cup_v = self.binary_set() },
                .cap_v => .{ .cap_v = self.binary_set() },
                .diff_v => .{ .diff_v = self.binary_set() },
                .range_v => blk: {
                    const lo: i64 = @bitCast(self.get_u64());
                    const raw_delta = self.small_payload();
                    const signed_delta = if (raw_delta & payload_sign_bit != 0)
                        raw_delta | ~payload_mask
                    else
                        raw_delta;
                    const delta: i32 = @bitCast(signed_delta);
                    break :blk .{ .range_v = .{
                        .lo = lo,
                        .hi = lo + @as(i64, delta),
                    } };
                },
                .seq_set_v => .{ .seq_set_v = .{
                    .element_set_offset = self.word_0,
                } },
                .power_set_v => .{ .power_set_v = .{
                    .set_offset = self.word_0,
                } },
                .set_delta_v => .{ .set_delta_v = .{
                    .base_offset = self.word_0,
                    .additions_offset = self.word_1,
                    .additions_len = @truncate(self.small_payload()),
                    .depth = @truncate(self.small_payload() >> 16),
                } },
            };
        }

        fn set_u64(self: *CompactValue, payload_v: u64) void {
            self.word_0 = @truncate(payload_v);
            self.word_1 = @truncate(payload_v >> 32);
        }

        fn get_u64(self: CompactValue) u64 {
            return @as(u64, self.word_0) | (@as(u64, self.word_1) << 32);
        }

        fn storage_tag(self: CompactValue) u32 {
            return self.tag_payload >> tag_shift;
        }

        fn small_payload(self: CompactValue) u32 {
            return self.tag_payload & payload_mask;
        }

        fn set_payload(self: *CompactValue, payload_v: u32) void {
            assert(payload_v <= payload_mask);
            self.tag_payload = (self.tag_payload & ~payload_mask) | payload_v;
        }

        fn set_offset_length(
            self: *CompactValue,
            offset: u32,
            length: u32,
        ) void {
            self.word_0 = offset;
            self.word_1 = length;
        }

        fn offset_length(self: CompactValue) value_module.Set {
            return .{ .offset = self.word_0, .len = self.word_1 };
        }

        fn binary_set(self: CompactValue) value_module.BinarySet {
            return .{
                .left_offset = self.word_0,
                .right_offset = self.word_1,
            };
        }
    };

    pub const StateValues = extern struct {
        pointer: *anyopaque,
        length: u8,
        storage: Storage,
        reserved: [6]u8 = @splat(0),

        pub fn init_full(values: []Value) StateValues {
            assert(values.len <= 64);
            return .{
                .pointer = @ptrCast(values.ptr),
                .length = @intCast(values.len),
                .storage = .full,
            };
        }

        pub fn init_compact(compact_values: []CompactValue) StateValues {
            assert(compact_values.len <= 64);
            return .{
                .pointer = @ptrCast(compact_values.ptr),
                .length = @intCast(compact_values.len),
                .storage = .compact,
            };
        }

        pub fn len(self: StateValues) u8 {
            assert(self.length <= 64);
            return self.length;
        }

        pub fn value(
            self: StateValues,
            pool: *const ValuePool,
            index: u32,
        ) Value {
            assert(index < self.length);
            return switch (self.storage) {
                .full => self.full_const()[index],
                .compact => self.compact_const()[index].value(pool),
            };
        }

        pub fn set_value(self: *StateValues, index: u32, value_v: Value) void {
            assert(self.storage == .full);
            assert(index < self.length);
            self.full()[index] = value_v;
        }

        pub fn set_compact(
            self: *StateValues,
            index: u32,
            compact_value_v: CompactValue,
        ) void {
            assert(self.storage == .compact);
            assert(index < self.length);
            self.compact()[index] = compact_value_v;
        }

        pub fn compact_value(self: StateValues, index: u32) CompactValue {
            assert(self.storage == .compact);
            assert(index < self.length);
            return self.compact_const()[index];
        }

        pub fn full(self: StateValues) []Value {
            assert(self.storage == .full);
            const pointer: [*]Value = @ptrCast(@alignCast(self.pointer));
            return pointer[0..self.length];
        }

        pub fn full_const(self: StateValues) []const Value {
            assert(self.storage == .full);
            const pointer: [*]const Value = @ptrCast(@alignCast(self.pointer));
            return pointer[0..self.length];
        }

        pub fn compact(self: StateValues) []CompactValue {
            assert(self.storage == .compact);
            const pointer: [*]CompactValue = @ptrCast(@alignCast(self.pointer));
            return pointer[0..self.length];
        }

        pub fn compact_const(self: StateValues) []const CompactValue {
            assert(self.storage == .compact);
            const pointer: [*]const CompactValue = @ptrCast(
                @alignCast(self.pointer),
            );
            return pointer[0..self.length];
        }
    };

    pub const State = struct {
        level: u32,
        pred: u32,
        changed_mask: u64,
        borrowed_pool: ?*const ValuePool,
        values: StateValues,

        pub fn value(
            self: *const State,
            variable_index: u32,
            default_pool: *const ValuePool,
        ) Value {
            return self.values.value(default_pool, variable_index);
        }

        pub fn set_value(
            self: *State,
            variable_index: u32,
            value_v: Value,
        ) void {
            self.values.set_value(variable_index, value_v);
        }

        pub fn set_compact(
            self: *State,
            variable_index: u32,
            compact_value_v: CompactValue,
        ) void {
            self.values.set_compact(variable_index, compact_value_v);
        }

        pub fn compact_value(
            self: *const State,
            variable_index: u32,
        ) CompactValue {
            return self.values.compact_value(variable_index);
        }

        pub fn value_pool(
            self: *const State,
            variable_index: u32,
            default_pool: *const ValuePool,
        ) *const ValuePool {
            assert(variable_index < self.values.len());
            if (self.values.storage == .compact) {
                assert(self.borrowed_pool == null);
                return default_pool;
            }
            const variable_bit = @as(u64, 1) << @intCast(variable_index);
            if (self.borrowed_pool != null and
                self.changed_mask & variable_bit == 0)
            {
                return self.borrowed_pool.?;
            }
            return default_pool;
        }
    };

    pub fn init(arena: *Arena, variable_names: []const []const u8, max_states: u32, value_cap: u32, string_cap: u32) !StateStore {
        return init_with_storage(
            arena,
            variable_names,
            max_states,
            value_cap,
            string_cap,
            .full,
        );
    }

    pub fn init_compact(arena: *Arena, variable_names: []const []const u8, max_states: u32, value_cap: u32, string_cap: u32) !StateStore {
        return init_with_storage(
            arena,
            variable_names,
            max_states,
            value_cap,
            string_cap,
            .compact,
        );
    }

    fn init_with_storage(
        arena: *Arena,
        variable_names: []const []const u8,
        max_states: u32,
        value_cap: u32,
        string_cap: u32,
        storage: Storage,
    ) !StateStore {
        const states = try arena.alloc(State, max_states);
        assert(variable_names.len <= 64);
        const values_count = std.math.mul(
            u64,
            max_states,
            variable_names.len,
        ) catch return error.OutOfMemory;
        if (values_count > std.math.maxInt(u32)) return error.OutOfMemory;
        const state_values: StateValueArrays = switch (storage) {
            .full => .{ .full = try arena.alloc(Value, values_count) },
            .compact => .{
                .compact = try arena.alloc(CompactValue, values_count),
            },
        };
        const values_pool = try ValuePool.init(arena, value_cap, string_cap);
        return StateStore{
            .arena = arena,
            .variable_names = variable_names,
            .states = states,
            .state_values = state_values,
            .count = 0,
            .cap = max_states,
            .values_pool = values_pool,
        };
    }

    pub fn alloc_state(self: *StateStore) !u32 {
        assert(self.count <= self.cap);
        if (self.count >= self.cap) {
            return error.StateSpaceExhausted;
        }
        const idx = self.count;
        const variable_count: u32 = @intCast(self.variable_names.len);
        const values_start = std.math.mul(u32, idx, variable_count) catch
            return error.OutOfMemory;
        const values: StateValues = switch (self.state_values) {
            .full => |state_values| blk: {
                assert(values_start + variable_count <= state_values.len);
                break :blk StateValues.init_full(
                    state_values[values_start..][0..variable_count],
                );
            },
            .compact => |state_handles| blk: {
                assert(values_start + variable_count <= state_handles.len);
                break :blk StateValues.init_compact(
                    state_handles[values_start..][0..variable_count],
                );
            },
        };
        self.states[idx] = .{
            .level = 0,
            .pred = 0,
            .changed_mask = 0,
            .borrowed_pool = null,
            .values = values,
        };
        self.count += 1;
        return idx;
    }

    pub fn reset(self: *StateStore, pool_snapshot: ValuePool.Snapshot) void {
        assert(pool_snapshot.value_count <= self.values_pool.value_count);
        assert(pool_snapshot.string_count <= self.values_pool.string_count);
        self.count = 0;
        self.values_pool.restore(pool_snapshot);
    }

    pub fn get(self: *StateStore, idx: u32) *State {
        std.debug.assert(idx < self.count);
        return &self.states[idx];
    }

    pub fn lookup_variable(self: StateStore, name: []const u8) ?u32 {
        for (self.variable_names, 0..) |vn, i| {
            if (std.mem.eql(u8, vn, name)) return @intCast(i);
        }
        return null;
    }

    pub fn set(self: *StateStore, idx: u32, var_idx: u32, v: Value) void {
        std.debug.assert(idx < self.count);
        std.debug.assert(var_idx < self.variable_names.len);
        self.states[idx].set_value(var_idx, v);
    }

    pub fn set_compact(
        self: *StateStore,
        idx: u32,
        var_idx: u32,
        compact_value: CompactValue,
    ) void {
        std.debug.assert(idx < self.count);
        std.debug.assert(var_idx < self.variable_names.len);
        self.states[idx].set_compact(var_idx, compact_value);
    }

    pub fn get_value(self: StateStore, idx: u32, var_idx: u32) Value {
        std.debug.assert(idx < self.count);
        std.debug.assert(var_idx < self.variable_names.len);
        return self.states[idx].value(var_idx, &self.values_pool);
    }

    pub fn clone_state_values(self: *StateStore, source_idx: u32, target_idx: u32) !void {
        const source = self.get(source_idx);
        const target = self.get(target_idx);
        assert(source.values.storage == target.values.storage);
        switch (source.values.storage) {
            .full => for (source.values.full_const(), 0..) |v, i| {
                target.set_value(
                    @intCast(i),
                    try v.clone(&self.values_pool, &self.values_pool),
                );
            },
            .compact => @memcpy(
                target.values.compact(),
                source.values.compact_const(),
            ),
        }
    }
};

test "state metadata remains cache compact" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(StateStore.State));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(StateStore.StateValues));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(StateStore.CompactValue));
}

test "compact state values round-trip inline canonical values" {
    var arena = try Arena.init(4 * 1024 * 1024);
    defer arena.deinit();

    const variable_names = [_][]const u8{ "x", "y" };
    var store = try StateStore.init_compact(
        &arena,
        &variable_names,
        4,
        64,
        64,
    );
    const state_index = try store.alloc_state();
    store.set_compact(
        state_index,
        0,
        StateStore.CompactValue.init(.{ .int_v = 41 }).?,
    );
    store.set_compact(
        state_index,
        1,
        StateStore.CompactValue.init(.{ .bool_v = true }).?,
    );

    try std.testing.expectEqual(
        Value{ .int_v = 41 },
        store.get_value(state_index, 0),
    );
    try std.testing.expectEqual(
        Value{ .bool_v = true },
        store.get_value(state_index, 1),
    );
}

test "canonical value capacity follows the arena budget" {
    const gib: u64 = 1024 * 1024 * 1024;
    const capacity = canonical_value_capacity(24 * gib, 18_000_000, 160);

    try std.testing.expect(capacity > 192_000_000);
    try std.testing.expectEqual(@as(u32, 536_870_912), capacity);
}

test "canonical value capacity remains bounded for smaller arenas" {
    const gib: u64 = 1024 * 1024 * 1024;
    try std.testing.expectEqual(
        @as(u32, 22_369_621),
        canonical_value_capacity(gib, 18_000_000, 160),
    );
}
