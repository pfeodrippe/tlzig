const std = @import("std");
const assert = std.debug.assert;
const Arena = @import("arena.zig").Arena;
const value = @import("value.zig");
const Value = value.Value;
const ValuePool = value.ValuePool;

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
    state_values: []Value,
    count: u32,
    cap: u32,
    values_pool: ValuePool,

    pub const State = struct {
        level: u32,
        pred: u32,
        changed_mask: u64,
        borrowed_mask: u64,
        borrowed_pool: ?*const ValuePool,
        values: []Value,

        pub fn value_pool(
            self: *const State,
            variable_index: u32,
            default_pool: *const ValuePool,
        ) *const ValuePool {
            assert(variable_index < self.values.len);
            if (self.borrowed_mask &
                (@as(u64, 1) << @intCast(variable_index)) != 0)
            {
                return self.borrowed_pool orelse unreachable;
            }
            return default_pool;
        }
    };

    pub fn init(arena: *Arena, variable_names: []const []const u8, max_states: u32, value_cap: u32, string_cap: u32) !StateStore {
        const states = try arena.alloc(State, max_states);
        assert(variable_names.len <= 64);
        const values_count = std.math.mul(
            u64,
            max_states,
            variable_names.len,
        ) catch return error.OutOfMemory;
        const state_values = try arena.alloc(Value, values_count);
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
        assert(values_start + variable_count <= self.state_values.len);
        self.states[idx] = .{
            .level = 0,
            .pred = 0,
            .changed_mask = 0,
            .borrowed_mask = 0,
            .borrowed_pool = null,
            .values = self.state_values[values_start..][0..variable_count],
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
        self.states[idx].values[var_idx] = v;
    }

    pub fn get_value(self: StateStore, idx: u32, var_idx: u32) Value {
        std.debug.assert(idx < self.count);
        std.debug.assert(var_idx < self.variable_names.len);
        return self.states[idx].values[var_idx];
    }

    pub fn clone_state_values(self: *StateStore, source_idx: u32, target_idx: u32) !void {
        const source = self.get(source_idx);
        const target = self.get(target_idx);
        for (source.values, 0..) |v, i| {
            target.values[i] = try v.clone(&self.values_pool, &self.values_pool);
        }
    }
};

test "canonical value capacity follows the arena budget" {
    const gib: u64 = 1024 * 1024 * 1024;
    const capacity = canonical_value_capacity(24 * gib, 18_000_000, 160);

    try std.testing.expect(capacity > 192_000_000);
    try std.testing.expectEqual(@as(u32, 402_653_184), capacity);
}

test "canonical value capacity remains bounded for smaller arenas" {
    const gib: u64 = 1024 * 1024 * 1024;
    try std.testing.expectEqual(
        @as(u32, 16_777_216),
        canonical_value_capacity(gib, 18_000_000, 160),
    );
}
