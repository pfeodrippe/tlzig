const std = @import("std");
const assert = std.debug.assert;
const Arena = @import("arena.zig").Arena;
const value = @import("value.zig");
const Value = value.Value;
const ValuePool = value.ValuePool;

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
        values: []Value,
    };

    pub fn init(arena: *Arena, variable_names: []const []const u8, max_states: u32, value_cap: u32, string_cap: u32) !StateStore {
        const states = try arena.alloc(State, max_states);
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
