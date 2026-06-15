const std = @import("std");
const Arena = @import("arena.zig").Arena;
const value = @import("value.zig");
const Value = value.Value;
const ValuePool = value.ValuePool;

pub const StateStore = struct {
    arena: *Arena,
    variable_names: []const []const u8,
    states: []State,
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
        const values_pool = try ValuePool.init(arena, value_cap, string_cap);
        return StateStore{
            .arena = arena,
            .variable_names = variable_names,
            .states = states,
            .count = 0,
            .cap = max_states,
            .values_pool = values_pool,
        };
    }

    pub fn alloc_state(self: *StateStore) !u32 {
        if (self.count >= self.cap) return error.StateSpaceExhausted;
        const idx = self.count;
        self.states[idx] = .{
            .level = 0,
            .pred = 0,
            .values = try self.arena.alloc(Value, @intCast(self.variable_names.len)),
        };
        self.count += 1;
        return idx;
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
