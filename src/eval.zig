const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Arena = @import("arena.zig").Arena;
const ast = @import("ast.zig");
const value = @import("value.zig");
const Value = value.Value;
const ValuePool = value.ValuePool;
const Function = value.Function;
const Set = value.Set;
const fingerprint = @import("fingerprint.zig");
const state = @import("state.zig");
const StateStore = state.StateStore;
const Error = @import("err.zig").Error;
const ModelTable = value.ModelTable;
const overrides = @import("overrides.zig");
const generated_runtime = @import("generated_runtime.zig");
const codegen = @import("codegen.zig");
const sequence_patterns = @import("sequence_patterns.zig");
const set_patterns = @import("set_patterns.zig");

pub const Constant = generated_runtime.NamedValue;

pub const Context = struct {
    head: ?*const ContextBinding,
    state: ?*const StateContext,
    local_floor: ?*const ContextBinding,
    len: u16,

    pub fn empty() Context {
        return .{
            .head = null,
            .state = null,
            .local_floor = null,
            .len = 0,
        };
    }

    pub fn operator_frame(self: Context) Context {
        return .{
            .head = self.head,
            .state = self.state,
            .local_floor = self.head,
            .len = 0,
        };
    }

    pub fn restore_locals(
        self: Context,
        state_context: Context,
    ) Context {
        return .{
            .head = self.head,
            .state = state_context.state,
            .local_floor = self.local_floor,
            .len = self.len,
        };
    }

    pub fn lookup(self: Context, name: []const u8) ?Value {
        const binding = self.lookup_binding_value(name) orelse return null;
        return binding.value;
    }

    pub fn lookup_value(
        self: Context,
        name: []const u8,
        eval_pool: *ValuePool,
    ) Error!?Value {
        const binding = self.lookup_binding_value(name) orelse return null;
        const source_pool = binding.value_pool orelse return binding.value;
        return try binding.value.clone(source_pool, eval_pool);
    }

    pub fn lookup_local_value(
        self: Context,
        name: []const u8,
    ) ?Value {
        var binding = self.head;
        while (binding) |current| : (binding = current.parent) {
            if (current == self.local_floor) break;
            if (!name_eql(current.name, name)) continue;
            return current.value;
        }
        return null;
    }

    pub fn has_local_binding(self: Context, name: []const u8) bool {
        var binding = self.head;
        while (binding) |current| : (binding = current.parent) {
            if (current == self.local_floor) break;
            if (name_eql(current.name, name)) return true;
        }
        return false;
    }

    pub fn lookup_values(
        self: Context,
        names: []const []const u8,
        required: []const bool,
        values: []Value,
        eval_pool: *ValuePool,
    ) Error!void {
        const found_all = try self.lookup_values_internal(
            names,
            required,
            values,
            eval_pool,
            false,
        );
        assert(found_all);
    }

    pub fn lookup_all_values(
        self: Context,
        names: []const []const u8,
        values: []Value,
        eval_pool: *ValuePool,
    ) Error!bool {
        return self.lookup_values_internal(
            names,
            &.{},
            values,
            eval_pool,
            true,
        );
    }

    pub fn lookup_required_values_if_available(
        self: Context,
        names: []const []const u8,
        required: []const bool,
        values: []Value,
        eval_pool: *ValuePool,
    ) Error!bool {
        _ = self.lookup_values_internal(
            names,
            required,
            values,
            eval_pool,
            false,
        ) catch |err| switch (err) {
            Error.UndefinedSymbol => return false,
            else => return err,
        };
        return true;
    }

    fn lookup_values_internal(
        self: Context,
        names: []const []const u8,
        required: []const bool,
        values: []Value,
        eval_pool: *ValuePool,
        require_all: bool,
    ) Error!bool {
        assert(names.len == values.len);
        assert(required.len == 0 or required.len == names.len);
        assert(names.len <= 32);
        if (self.lookup_values_stack_top(
            names,
            values,
        )) {
            return true;
        }
        var found: [32]bool = @splat(false);
        var found_count: usize = 0;
        var binding = self.head;
        while (binding) |current| : (binding = current.parent) {
            if (current == self.local_floor) break;
            var index: usize = 0;
            while (index < names.len) : (index += 1) {
                if (found[index]) continue;
                if (!name_eql(current.name, names[index])) continue;
                found[index] = true;
                found_count += 1;
                values[index] = current.value;
                if (found_count == names.len) return true;
                break;
            }
        }
        var state_iterator = self.state_assignments();
        while (state_iterator.next()) |current| {
            var index: usize = 0;
            while (index < names.len) : (index += 1) {
                if (found[index]) continue;
                if (!name_eql(current.name, names[index])) continue;
                found[index] = true;
                found_count += 1;
                if (current.value.value_pool) |source_pool| {
                    values[index] = try current.value.value.clone(
                        source_pool,
                        eval_pool,
                    );
                } else {
                    values[index] = current.value.value;
                }
                if (found_count == names.len) return true;
                break;
            }
        }
        for (names, 0..) |_, index| {
            if (found[index]) continue;
            if (require_all) return false;
            if (required.len == 0 or required[index]) {
                return Error.UndefinedSymbol;
            }
            values[index] = Value{ .bool_v = false };
        }
        return true;
    }

    fn lookup_values_stack_top(
        self: Context,
        names: []const []const u8,
        values: []Value,
    ) bool {
        if (names.len == 0) return true;
        if (names.len > self.len) return false;
        var binding = self.head;
        var index = names.len;
        while (index > 0) {
            index -= 1;
            const current = binding orelse return false;
            if (current == self.local_floor) return false;
            if (!name_eql(current.name, names[index])) return false;
            values[index] = current.value;
            binding = current.parent;
        }
        return true;
    }

    fn lookup_values_at_depths(
        self: Context,
        names: []const []const u8,
        depths: []const u8,
        values: []Value,
    ) bool {
        assert(names.len == depths.len);
        assert(names.len == values.len);
        if (names.len == 0) return true;

        var binding = self.head;
        var current_depth: usize = 0;
        var index = names.len;
        while (index > 0) {
            index -= 1;
            const target_depth = depths[index];
            if (index + 1 < names.len) {
                assert(target_depth > depths[index + 1]);
            }
            while (current_depth < target_depth) : (current_depth += 1) {
                const current = binding orelse return false;
                if (current == self.local_floor) return false;
                binding = current.parent;
            }
            const current = binding orelse return false;
            if (current == self.local_floor or
                !name_eql(current.name, names[index]))
            {
                return false;
            }
            values[index] = current.value;
        }
        return true;
    }

    pub fn lookup_value_at_depth(
        self: Context,
        name: []const u8,
        depth: u8,
    ) ?Value {
        var binding = self.head;
        var current_depth: usize = 0;
        while (current_depth < depth) : (current_depth += 1) {
            const current = binding orelse return null;
            if (current == self.local_floor) return null;
            binding = current.parent;
        }
        const current = binding orelse return null;
        if (current == self.local_floor or !name_eql(current.name, name)) {
            return null;
        }
        return current.value;
    }

    fn lookup_binding_value(self: Context, name: []const u8) ?ContextLookup {
        var binding = self.head;
        while (binding) |current| {
            if (current == self.local_floor) break;
            if (name_eql(current.name, name)) return .{
                .value = current.value,
                .value_pool = null,
            };
            binding = current.parent;
        }
        var state_iterator = self.state_assignments();
        while (state_iterator.next()) |current| {
            if (name_eql(current.name, name)) return .{
                .value = current.value.value,
                .value_pool = current.value.value_pool,
            };
        }
        return null;
    }

    pub fn lookup_state(self: Context, variable_index: u32) ?StateContextValue {
        if (variable_index >= 64) return null;
        const bit = @as(u64, 1) << @intCast(variable_index);
        const state_context = self.state orelse return null;
        if (state_context.mask & bit == 0) return null;
        assert(state_context.count == @popCount(state_context.mask));
        return .{
            .value = state_context.values[variable_index],
            .value_pool = state_context.value_pools[variable_index],
            .assignment = state_context.assignments[variable_index],
        };
    }

    pub fn collect_state_assignments(
        self: Context,
        assignments: []?StateContextValue,
    ) void {
        var iterator = self.state_assignments();
        while (iterator.next()) |current| {
            assert(current.variable_index < assignments.len);
            assignments[current.variable_index] = current.value;
        }
    }

    pub fn state_assignments(self: Context) StateAssignmentIterator {
        const state_context = self.state orelse return .{
            .names = null,
            .values = null,
            .value_pools = null,
            .assignments = null,
            .remaining = 0,
        };
        assert(state_context.count == @popCount(state_context.mask));
        return .{
            .names = &state_context.names,
            .values = &state_context.values,
            .value_pools = &state_context.value_pools,
            .assignments = &state_context.assignments,
            .remaining = state_context.mask,
        };
    }

    pub fn state_values(self: Context, count: u32) []const Value {
        assert(count <= 64);
        const state_context = self.state orelse return &.{};
        return state_context.values[0..count];
    }

    pub fn state_value_pools(
        self: Context,
        count: u32,
    ) []const ?*const ValuePool {
        assert(count <= 64);
        const state_context = self.state orelse return &.{};
        return state_context.value_pools[0..count];
    }

    pub fn state_assignment_mask(self: Context) u64 {
        const state_context = self.state orelse return 0;
        assert(state_context.count == @popCount(state_context.mask));
        return state_context.mask;
    }
};

pub const StateContextValue = struct {
    value: Value,
    value_pool: ?*const ValuePool,
    assignment: AssignmentKind,
};

const StateContext = struct {
    names: [64][]const u8 = @splat(&.{}),
    values: [64]Value = @splat(.{ .bool_v = false }),
    value_pools: [64]?*const ValuePool = @splat(null),
    assignments: [64]AssignmentKind = @splat(.unchanged),
    mask: u64 = 0,
    count: u8 = 0,
};

pub const IndexedStateContextValue = struct {
    name: []const u8,
    variable_index: u32,
    value: StateContextValue,
};

pub const StateAssignmentIterator = struct {
    names: ?*const [64][]const u8,
    values: ?*const [64]Value,
    value_pools: ?*const [64]?*const ValuePool,
    assignments: ?*const [64]AssignmentKind,
    remaining: u64,

    pub fn next(self: *StateAssignmentIterator) ?IndexedStateContextValue {
        if (self.remaining == 0) return null;
        const variable_index: u6 = @intCast(@ctz(self.remaining));
        const bit = @as(u64, 1) << variable_index;
        self.remaining &= ~bit;
        const assignment = (self.assignments orelse unreachable)[variable_index];
        assert(assignment != .local);
        return .{
            .name = (self.names orelse unreachable)[variable_index],
            .variable_index = variable_index,
            .value = .{
                .value = (self.values orelse unreachable)[variable_index],
                .value_pool = (self.value_pools orelse unreachable)[variable_index],
                .assignment = assignment,
            },
        };
    }
};

const ContextLookup = struct {
    value: Value,
    value_pool: ?*const ValuePool,
};

const ContextBinding = struct {
    parent: ?*const ContextBinding,
    name: []const u8,
    value: Value,
};

pub const AssignmentKind = enum {
    local,
    changed,
    unchanged,
};

const ContextPool = struct {
    bindings: []ContextBinding,
    count: u32,
    restore_floor: u32,
    state: StateContext,
    state_trail: [64]u6,
    state_restore_floor: u8,
    pin_depth: u16,

    fn init(arena: *Arena) !ContextPool {
        return .{
            .bindings = try arena.alloc(ContextBinding, 131_072),
            .count = 0,
            .restore_floor = 0,
            .state = .{},
            .state_trail = undefined,
            .state_restore_floor = 0,
            .pin_depth = 0,
        };
    }

    fn reset(self: *ContextPool) void {
        assert(self.count <= self.bindings.len);
        assert(self.state.count <= self.state.values.len);
        self.count = 0;
        self.restore_floor = 0;
        self.state.count = 0;
        self.state.mask = 0;
        self.state_restore_floor = 0;
        assert(self.pin_depth == 0);
    }

    fn snapshot(self: *const ContextPool) u64 {
        assert(self.count <= self.bindings.len);
        assert(self.state.count == @popCount(self.state.mask));
        return pack_counts(self.count, self.state.count);
    }

    fn restore(self: *ContextPool, mark: u64) void {
        const saved_count: u32 = @truncate(mark);
        const saved_state_count: u8 = @truncate(mark >> 32);
        const local_target = @max(saved_count, self.restore_floor);
        const state_target = @max(saved_state_count, self.state_restore_floor);
        assert(local_target <= self.count);
        assert(state_target <= self.state.count);
        self.count = local_target;
        while (self.state.count > state_target) {
            self.state.count -= 1;
            const variable_index = self.state_trail[self.state.count];
            const bit = @as(u64, 1) << variable_index;
            assert(self.state.mask & bit != 0);
            self.state.mask &= ~bit;
            if (builtin.mode == .debug or builtin.mode == .safe) {
                self.state.names[variable_index] = &.{};
                self.state.values[variable_index] = .{ .bool_v = false };
                self.state.value_pools[variable_index] = null;
                self.state.assignments[variable_index] = .unchanged;
            }
        }
        assert(self.state.count == @popCount(self.state.mask));
    }

    fn pin(self: *ContextPool) u64 {
        assert(self.pin_depth < std.math.maxInt(u16));
        const previous = pack_counts(
            self.restore_floor,
            self.state_restore_floor,
        );
        self.restore_floor = @max(self.restore_floor, self.count);
        self.state_restore_floor = @max(
            self.state_restore_floor,
            self.state.count,
        );
        self.pin_depth += 1;
        return previous;
    }

    fn unpin(self: *ContextPool, previous: u64) void {
        assert(self.pin_depth > 0);
        const previous_local: u32 = @truncate(previous);
        const previous_state: u8 = @truncate(previous >> 32);
        assert(previous_local <= self.restore_floor);
        assert(previous_state <= self.state_restore_floor);
        self.restore_floor = previous_local;
        self.state_restore_floor = previous_state;
        self.pin_depth -= 1;
    }

    fn can_reset_at_root(self: *const ContextPool) bool {
        return self.pin_depth == 0;
    }

    fn pack_counts(local: u32, state_count: u8) u64 {
        return @as(u64, state_count) << 32 | local;
    }

    inline fn extend_state(
        self: *ContextPool,
        context: Context,
        name: []const u8,
        variable_index: u32,
        value_v: Value,
        value_pool: ?*const ValuePool,
        assignment: AssignmentKind,
    ) Error!Context {
        assert(assignment != .local);
        if (variable_index >= self.state.values.len or
            self.state.count >= self.state.values.len)
        {
            if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                std.debug.print(
                    "context state trail exhausted: {d}/{d}\n",
                    .{ self.state.count, self.state.values.len },
                );
            }
            return Error.OutOfMemory;
        }
        if (self.state.mask == 0) {
            assert(context.state == null or context.state == &self.state);
        } else {
            assert(context.state == &self.state);
        }
        const variable_index_u6: u6 = @intCast(variable_index);
        const bit = @as(u64, 1) << variable_index_u6;
        if (self.state.mask & bit != 0) return Error.TypeError;
        self.state_trail[self.state.count] = variable_index_u6;
        self.state.names[variable_index] = name;
        self.state.values[variable_index] = value_v;
        self.state.value_pools[variable_index] = value_pool;
        self.state.assignments[variable_index] = assignment;
        self.state.mask |= bit;
        self.state.count += 1;
        assert(self.state.count == @popCount(self.state.mask));
        return .{
            .head = context.head,
            .state = &self.state,
            .local_floor = context.local_floor,
            .len = context.len,
        };
    }

    inline fn extend_local(
        self: *ContextPool,
        context: Context,
        name: []const u8,
        value_v: Value,
    ) Error!Context {
        assert(context.len < std.math.maxInt(u16));
        if (self.state.mask == 0) {
            assert(context.state == null or context.state == &self.state);
        } else {
            assert(context.state == &self.state);
        }
        if (self.count >= self.bindings.len) {
            if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                std.debug.print(
                    "context local bindings exhausted: {d}/{d}\n",
                    .{ self.count, self.bindings.len },
                );
            }
            return Error.OutOfMemory;
        }
        const binding = &self.bindings[self.count];
        self.count += 1;
        binding.* = .{
            .parent = context.head,
            .name = name,
            .value = value_v,
        };
        return .{
            .head = binding,
            .state = context.state,
            .local_floor = context.local_floor,
            .len = context.len + 1,
        };
    }
};

pub const Alias = struct {
    from: []const u8,
    to: []const u8,
};

pub const EvalLambda = struct {
    params: []const []const u8,
    body: *ast.Expr,
    ctx: Context,
};

const ApplicationGroup = struct {
    args: []const *ast.Expr,
};

pub const ErrorContext = struct {
    context: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    active: bool = false,
};

const MemoEntry = struct {
    name: []const u8,
    value: Value,
};

const DefinitionMemo = struct {
    pool: ?*ValuePool = null,
    frozen: bool = false,
    count: u16 = 0,
    entries: [1024]MemoEntry = undefined,

    fn reset(self: *DefinitionMemo, pool: ?*ValuePool) void {
        self.pool = pool;
        self.frozen = false;
        self.count = 0;
    }

    fn freeze(self: *DefinitionMemo) void {
        assert(self.pool != null);
        self.frozen = true;
    }

    fn get(
        self: *const DefinitionMemo,
        pool: *ValuePool,
        name: []const u8,
    ) ?Value {
        if (self.pool != pool) return null;
        for (self.entries[0..self.count]) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    fn put(
        self: *DefinitionMemo,
        pool: *ValuePool,
        name: []const u8,
        value_v: Value,
    ) Error!void {
        if (self.pool != pool or self.frozen) return;
        if (self.count >= self.entries.len) return Error.OutOfMemory;
        self.entries[self.count] = .{ .name = name, .value = value_v };
        self.count += 1;
        assert(self.count <= self.entries.len);
    }
};

const CallMemoEntry = struct {
    hash: fingerprint.Fingerprint,
    name: []const u8,
    args_offset: u32,
    args_len: u16,
    state_address: usize,
    next_state_address: usize,
    value: Value,
};

const StateCallMemo = struct {
    const entry_count = 1024;
    const slot_count = entry_count * 2;

    pool: ?*ValuePool = null,
    hash_node_budget: u32 = 16,
    fingerprint_only: bool = false,
    count: u16 = 0,
    entries: [entry_count]CallMemoEntry = undefined,
    slots: [slot_count]u16 = undefined,
    slot_generations: [slot_count]u64 = @splat(0),
    generation: u64 = 0,

    fn reset(self: *StateCallMemo, pool: ?*ValuePool) void {
        self.pool = pool;
        self.count = 0;
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(&self.slot_generations, 0);
            self.generation = 1;
        }
    }

    fn hash_call(
        self: *const StateCallMemo,
        name: []const u8,
        args: []const Value,
        args_pool: *const ValuePool,
        state_address: usize,
        next_state_address: usize,
    ) ?fingerprint.Fingerprint {
        var hash = fingerprint.hash_bytes(fingerprint.hash_init(), name);
        hash = fingerprint.hash_combine(hash, state_address);
        hash = fingerprint.hash_combine(hash, next_state_address);
        var remaining_nodes = self.hash_node_budget;
        for (args) |argument| {
            const argument_hash = fingerprint.hash_value_unseeded_bounded(
                args_pool,
                argument,
                &remaining_nodes,
            ) orelse return null;
            hash = fingerprint.hash_combine(
                hash,
                argument_hash,
            );
        }
        return hash;
    }

    fn get(
        self: *const StateCallMemo,
        name: []const u8,
        args: []const Value,
        args_pool: *const ValuePool,
        state_address: usize,
        next_state_address: usize,
    ) ?Value {
        const memo_pool = self.pool orelse return null;
        assert(self.count <= entry_count);
        if (self.count == 0) return null;
        const hash = self.hash_call(
            name,
            args,
            args_pool,
            state_address,
            next_state_address,
        ) orelse return null;
        var slot: usize = @intCast(hash & (slot_count - 1));
        var probes: usize = 0;
        while (probes < slot_count) : (probes += 1) {
            if (self.slot_generations[slot] != self.generation) return null;
            const encoded_index = self.slots[slot];
            assert(encoded_index > 0);
            assert(encoded_index <= self.count);
            const entry = self.entries[encoded_index - 1];
            if (entry.hash != hash or
                !std.mem.eql(u8, entry.name, name) or
                entry.args_len != args.len or
                entry.state_address != state_address or
                entry.next_state_address != next_state_address)
            {
                slot = (slot + 1) & (slot_count - 1);
                continue;
            }
            if (self.fingerprint_only) return entry.value;
            for (args, 0..) |argument, index| {
                if (!Value.eql_cross_pool(
                    argument,
                    args_pool,
                    memo_pool.values[entry.args_offset + index],
                    memo_pool,
                )) break;
            } else return entry.value;
            slot = (slot + 1) & (slot_count - 1);
        }
        return null;
    }

    fn put(
        self: *StateCallMemo,
        name: []const u8,
        args: []const Value,
        args_pool: *const ValuePool,
        state_address: usize,
        next_state_address: usize,
        value_v: Value,
    ) error{ OutOfMemory, NotImplemented }!void {
        const memo_pool = self.pool orelse return;
        if (self.count >= self.entries.len or
            args.len > std.math.maxInt(u16))
        {
            return error.OutOfMemory;
        }
        const hash = self.hash_call(
            name,
            args,
            args_pool,
            state_address,
            next_state_address,
        ) orelse return error.NotImplemented;
        var slot: usize = @intCast(hash & (slot_count - 1));
        var probes: usize = 0;
        while (probes < slot_count and
            self.slot_generations[slot] == self.generation) : (probes += 1)
        {
            slot = (slot + 1) & (slot_count - 1);
        }
        if (probes == slot_count) return error.OutOfMemory;
        const snapshot = memo_pool.snapshot();
        errdefer memo_pool.restore(snapshot);
        const args_offset = if (self.fingerprint_only) 0 else memo_pool.value_count;
        if (!self.fingerprint_only) {
            _ = try memo_pool.alloc_values(@intCast(args.len));
            for (args, 0..) |argument, index| {
                memo_pool.values[args_offset + index] = try argument.clone(
                    args_pool,
                    memo_pool,
                );
            }
        }
        const memo_value = try value_v.clone(args_pool, memo_pool);
        self.entries[self.count] = .{
            .hash = hash,
            .name = name,
            .args_offset = args_offset,
            .args_len = @intCast(args.len),
            .state_address = state_address,
            .next_state_address = next_state_address,
            .value = memo_value,
        };
        self.slots[slot] = self.count + 1;
        self.slot_generations[slot] = self.generation;
        self.count += 1;
    }
};

const generated_cache_entry_value_budget: u32 = 16 * 1024;
const generated_cache_entry_string_budget: u32 = 64 * 1024;
const generated_cache_total_value_budget: u32 = 64 * 1024;
const generated_cache_total_string_budget: u32 = 1024 * 1024;

const materialize_scratch_depth_max = 64;
const materialize_scratch_initial_capacity = 64;

const MaterializeScratchFrame = struct {
    values: []Value,
    secondary_values: []Value,
    names: [][]const u8,
    lengths: []u32,

    fn ensure(
        self: *MaterializeScratchFrame,
        arena: *Arena,
        count: usize,
    ) !void {
        if (count <= self.values.len) return;
        var capacity = self.values.len;
        assert(capacity > 0);
        while (capacity < count) {
            capacity = std.math.mul(usize, capacity, 2) catch
                return Error.OutOfMemory;
        }
        self.values = try arena.alloc(Value, capacity);
        self.secondary_values = try arena.alloc(Value, capacity);
        self.names = try arena.alloc([]const u8, capacity);
        self.lengths = try arena.alloc(u32, capacity);
    }

    fn ensure_secondary_preserve(
        self: *MaterializeScratchFrame,
        arena: *Arena,
        count: usize,
        preserve: usize,
    ) !void {
        assert(preserve <= self.secondary_values.len);
        if (count <= self.secondary_values.len) return;
        var capacity = self.secondary_values.len;
        assert(capacity > 0);
        while (capacity < count) {
            capacity = std.math.mul(usize, capacity, 2) catch
                return Error.OutOfMemory;
        }
        const grown = try arena.alloc(Value, capacity);
        @memcpy(grown[0..preserve], self.secondary_values[0..preserve]);
        self.secondary_values = grown;
    }
};

const MaterializeScratch = struct {
    arena: *Arena,
    frames: []MaterializeScratchFrame,
    depth: u8,

    fn init(arena: *Arena) !*MaterializeScratch {
        const scratch = try arena.alloc_object(MaterializeScratch);
        const frames = try arena.alloc(
            MaterializeScratchFrame,
            materialize_scratch_depth_max,
        );
        for (frames) |*frame| {
            frame.* = .{
                .values = try arena.alloc(
                    Value,
                    materialize_scratch_initial_capacity,
                ),
                .secondary_values = try arena.alloc(
                    Value,
                    materialize_scratch_initial_capacity,
                ),
                .names = try arena.alloc(
                    []const u8,
                    materialize_scratch_initial_capacity,
                ),
                .lengths = try arena.alloc(
                    u32,
                    materialize_scratch_initial_capacity,
                ),
            };
        }
        scratch.* = .{
            .arena = arena,
            .frames = frames,
            .depth = 0,
        };
        return scratch;
    }

    fn acquire(
        self: *MaterializeScratch,
        count: usize,
    ) Error!*MaterializeScratchFrame {
        assert(self.depth <= self.frames.len);
        if (self.depth == self.frames.len) return Error.NotImplemented;
        const frame = &self.frames[self.depth];
        self.depth += 1;
        errdefer self.depth -= 1;
        try frame.ensure(self.arena, count);
        return frame;
    }

    fn release(self: *MaterializeScratch) void {
        assert(self.depth > 0);
        assert(self.depth <= self.frames.len);
        self.depth -= 1;
    }
};

pub const Evaluator = struct {
    module: ast.Module,
    constants: []const Constant,
    constant_slots: []?Value,
    aliases: []const Alias,
    models: *ModelTable,
    override_registry: overrides.Registry,
    treat_unknown_as_model: bool,
    next_state: ?*state.StateStore.State,
    enabled_result: ?bool,
    definition_memo: *DefinitionMemo,
    state_definition_memo: *DefinitionMemo,
    state_call_memo: *StateCallMemo,
    state_definition_pool: *ValuePool,
    persistent_call_memo: *StateCallMemo,
    persistent_call_pool: *ValuePool,
    persistent_call_safe: []const bool,
    action_call_memo: *StateCallMemo,
    action_call_pool: *ValuePool,
    recursive_definitions: []?bool,
    generated_cache_pool: *ValuePool,
    generated_cache: []?Value,
    generated_cache_rollback: []?Value,
    generated_cache_frozen: bool,
    late_generated_cache_pool: *ValuePool,
    late_generated_cache: []?Value,
    generated_state_memo_required: bool,
    context_pool: *ContextPool,
    materialize_scratch: *MaterializeScratch,
    /// Error context stored via pointer so all by-value copies share state.
    err_ctx: *ErrorContext,

    pub fn init(module: ast.Module, arena: *Arena, override_ctx: overrides.OverrideContext) !Evaluator {
        return init_generated(module, arena, override_ctx, &.{}, &.{});
    }

    pub fn init_generated(
        module: ast.Module,
        arena: *Arena,
        override_ctx: overrides.OverrideContext,
        generated: []const generated_runtime.Operator,
        generated_expressions: []const generated_runtime.Expression,
    ) !Evaluator {
        const models = try arena.alloc_object(ModelTable);
        models.* = try ModelTable.init(arena, 1024);
        const err_ctx = try arena.alloc_object(ErrorContext);
        err_ctx.* = .{};
        const definition_memo = try arena.alloc_object(DefinitionMemo);
        definition_memo.* = .{};
        const state_definition_memo = try arena.alloc_object(DefinitionMemo);
        state_definition_memo.* = .{};
        const state_call_memo = try arena.alloc_object(StateCallMemo);
        state_call_memo.* = .{};
        const state_definition_pool = try arena.alloc_object(ValuePool);
        state_definition_pool.* = try ValuePool.init(arena, 4096, 4096);
        const persistent_call_memo = try arena.alloc_object(StateCallMemo);
        persistent_call_memo.* = .{
            .hash_node_budget = 4096,
            .fingerprint_only = builtin.mode == .fast or
                builtin.mode == .small,
        };
        const persistent_call_pool = try arena.alloc_object(ValuePool);
        persistent_call_pool.* = try ValuePool.init(arena, 32 * 1024, 64 * 1024);
        persistent_call_pool.growable = false;
        persistent_call_memo.reset(persistent_call_pool);
        const action_call_memo = try arena.alloc_object(StateCallMemo);
        action_call_memo.* = .{};
        const action_call_pool = try arena.alloc_object(ValuePool);
        action_call_pool.* = try ValuePool.init(arena, 64 * 1024, 64 * 1024);
        action_call_pool.growable = false;
        const persistent_call_safe = try arena.alloc(bool, module.definitions.len);
        for (module.definitions, persistent_call_safe) |definition, *safe| {
            safe.* = codegen.definition_persistent_call_cache_safe(
                module,
                definition,
            );
        }
        const recursive_definitions = try arena.alloc(?bool, module.definitions.len);
        @memset(recursive_definitions, null);
        const generated_cache_pool = try arena.alloc_object(ValuePool);
        generated_cache_pool.* = try ValuePool.init(
            arena,
            generated_cache_total_value_budget,
            generated_cache_total_string_budget,
        );
        const generated_cache = try arena.alloc(?Value, module.definitions.len);
        @memset(generated_cache, null);
        const generated_cache_rollback = try arena.alloc(
            ?Value,
            module.definitions.len,
        );
        @memset(generated_cache_rollback, null);
        const late_generated_cache_pool = try arena.alloc_object(ValuePool);
        late_generated_cache_pool.* = try ValuePool.init(
            arena,
            generated_cache_entry_value_budget,
            generated_cache_entry_string_budget,
        );
        late_generated_cache_pool.growable = false;
        const late_generated_cache = try arena.alloc(
            ?Value,
            module.definitions.len,
        );
        @memset(late_generated_cache, null);
        const context_pool = try arena.alloc_object(ContextPool);
        context_pool.* = try ContextPool.init(arena);
        const materialize_scratch = try MaterializeScratch.init(arena);
        const constant_slots = try arena.alloc(?Value, module.constants.len);
        @memset(constant_slots, null);
        var override_registry = overrides.default_registry(override_ctx);
        override_registry.generated = generated;
        override_registry.generated_expressions = generated_expressions;
        var generated_state_memo_required = false;
        for (generated) |operator| {
            if (operator.state_memo_required) {
                generated_state_memo_required = true;
                break;
            }
        }
        return Evaluator{
            .module = module,
            .constants = &[_]Constant{},
            .constant_slots = constant_slots,
            .aliases = &[_]Alias{},
            .models = models,
            .override_registry = override_registry,
            .treat_unknown_as_model = false,
            .next_state = null,
            .enabled_result = null,
            .definition_memo = definition_memo,
            .state_definition_memo = state_definition_memo,
            .state_call_memo = state_call_memo,
            .state_definition_pool = state_definition_pool,
            .persistent_call_memo = persistent_call_memo,
            .persistent_call_pool = persistent_call_pool,
            .persistent_call_safe = persistent_call_safe,
            .action_call_memo = action_call_memo,
            .action_call_pool = action_call_pool,
            .recursive_definitions = recursive_definitions,
            .generated_cache_pool = generated_cache_pool,
            .generated_cache = generated_cache,
            .generated_cache_rollback = generated_cache_rollback,
            .generated_cache_frozen = false,
            .late_generated_cache_pool = late_generated_cache_pool,
            .late_generated_cache = late_generated_cache,
            .generated_state_memo_required = generated_state_memo_required,
            .context_pool = context_pool,
            .materialize_scratch = materialize_scratch,
            .err_ctx = err_ctx,
        };
    }

    pub fn set_treat_unknown_as_model(self: *Evaluator, enable: bool) void {
        self.treat_unknown_as_model = enable;
    }

    pub fn fork(self: Evaluator, arena: *Arena) !Evaluator {
        const err_ctx = try arena.alloc_object(ErrorContext);
        err_ctx.* = .{};
        const definition_memo = try arena.alloc_object(DefinitionMemo);
        definition_memo.* = .{};
        const state_definition_memo = try arena.alloc_object(DefinitionMemo);
        state_definition_memo.* = .{};
        const state_call_memo = try arena.alloc_object(StateCallMemo);
        state_call_memo.* = .{};
        const state_definition_pool = try arena.alloc_object(ValuePool);
        state_definition_pool.* = try ValuePool.init(arena, 4096, 4096);
        const persistent_call_memo = try arena.alloc_object(StateCallMemo);
        persistent_call_memo.* = .{
            .hash_node_budget = 4096,
            .fingerprint_only = builtin.mode == .fast or
                builtin.mode == .small,
        };
        const persistent_call_pool = try arena.alloc_object(ValuePool);
        persistent_call_pool.* = try ValuePool.init(arena, 32 * 1024, 64 * 1024);
        persistent_call_pool.growable = false;
        persistent_call_memo.reset(persistent_call_pool);
        const action_call_memo = try arena.alloc_object(StateCallMemo);
        action_call_memo.* = .{};
        const action_call_pool = try arena.alloc_object(ValuePool);
        action_call_pool.* = try ValuePool.init(arena, 64 * 1024, 64 * 1024);
        action_call_pool.growable = false;
        const recursive_definitions = try arena.alloc(
            ?bool,
            self.module.definitions.len,
        );
        @memset(recursive_definitions, null);
        const generated_cache_pool = try arena.alloc_object(ValuePool);
        generated_cache_pool.* = try ValuePool.init(arena, 4096, 4096);
        const generated_cache = try arena.alloc(?Value, self.module.definitions.len);
        @memset(generated_cache, null);
        const generated_cache_rollback = try arena.alloc(
            ?Value,
            self.module.definitions.len,
        );
        @memset(generated_cache_rollback, null);
        const late_generated_cache_pool = try arena.alloc_object(ValuePool);
        late_generated_cache_pool.* = try ValuePool.init(
            arena,
            generated_cache_entry_value_budget,
            generated_cache_entry_string_budget,
        );
        late_generated_cache_pool.growable = false;
        const late_generated_cache = try arena.alloc(
            ?Value,
            self.module.definitions.len,
        );
        @memset(late_generated_cache, null);
        const context_pool = try arena.alloc_object(ContextPool);
        context_pool.* = try ContextPool.init(arena);
        const materialize_scratch = try MaterializeScratch.init(arena);
        const constant_slots = try arena.alloc(
            ?Value,
            self.module.constants.len,
        );
        @memset(constant_slots, null);
        var copy = self;
        copy.next_state = null;
        copy.enabled_result = null;
        copy.definition_memo = definition_memo;
        copy.state_definition_memo = state_definition_memo;
        copy.state_call_memo = state_call_memo;
        copy.state_definition_pool = state_definition_pool;
        copy.persistent_call_memo = persistent_call_memo;
        copy.persistent_call_pool = persistent_call_pool;
        copy.action_call_memo = action_call_memo;
        copy.action_call_pool = action_call_pool;
        copy.recursive_definitions = recursive_definitions;
        copy.generated_cache_pool = generated_cache_pool;
        copy.generated_cache = generated_cache;
        copy.generated_cache_rollback = generated_cache_rollback;
        copy.generated_cache_frozen = false;
        copy.late_generated_cache_pool = late_generated_cache_pool;
        copy.late_generated_cache = late_generated_cache;
        copy.context_pool = context_pool;
        copy.materialize_scratch = materialize_scratch;
        copy.constant_slots = constant_slots;
        copy.err_ctx = err_ctx;
        return copy;
    }

    pub fn freeze_generated_cache(
        self: *Evaluator,
        eval_pool: *ValuePool,
    ) Error!void {
        assert(!self.generated_cache_frozen);
        assert(self.generated_cache_pool != eval_pool);
        const source_pool = self.generated_cache_pool;
        for (self.generated_cache) |*cached| {
            if (cached.*) |value_v| {
                cached.* = try value_v.clone(source_pool, eval_pool);
            }
        }
        self.generated_cache_pool = eval_pool;
        self.generated_cache_frozen = true;
    }

    pub fn warm_eager_generated_cache(
        self: *Evaluator,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) void {
        assert(!self.generated_cache_frozen);
        assert(self.generated_cache_pool != eval_pool);
        assert(self.generated_cache_rollback.len == self.generated_cache.len);
        for (self.override_registry.generated) |operator| {
            if (!operator.eager_cache) continue;
            assert(operator.cacheable);
            assert(operator.arity == 0);
            const function = operator.function orelse continue;
            const cache_index = operator.cache_index orelse continue;
            assert(cache_index < self.generated_cache.len);
            if (self.generated_cache[cache_index] != null) continue;

            const eval_snapshot = eval_pool.snapshot();
            const cache_snapshot = self.generated_cache_pool.snapshot();
            @memcpy(self.generated_cache_rollback, self.generated_cache);
            const eval_growable = eval_pool.growable;
            const cache_growable = self.generated_cache_pool.growable;
            eval_pool.growable = false;
            self.generated_cache_pool.growable = false;
            const warmed = blk: {
                _ = self.call_generated(
                    function,
                    &.{},
                    Context.empty(),
                    null,
                    eval_pool,
                    state_pool,
                    false,
                ) catch break :blk false;
                break :blk true;
            };
            eval_pool.growable = eval_growable;
            self.generated_cache_pool.growable = cache_growable;
            eval_pool.restore(eval_snapshot);

            const cache_values = self.generated_cache_pool.value_count -
                cache_snapshot.value_count;
            const cache_strings = self.generated_cache_pool.string_count -
                cache_snapshot.string_count;
            const admitted = warmed and
                cache_values <= generated_cache_entry_value_budget and
                cache_strings <= generated_cache_entry_string_budget;
            if (!admitted) {
                @memcpy(self.generated_cache, self.generated_cache_rollback);
                self.generated_cache_pool.restore(cache_snapshot);
                self.err_ctx.* = .{};
            }
            if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                std.debug.print(
                    "generated cache warm {s}: admitted={} values={d} strings={d}\n",
                    .{ operator.name, admitted, cache_values, cache_strings },
                );
            }
        }
    }

    pub fn generated_cache_is_frozen(self: *const Evaluator) bool {
        return self.generated_cache_frozen;
    }

    pub fn share_generated_cache_from(
        self: *Evaluator,
        source: *const Evaluator,
    ) void {
        assert(source.generated_cache_frozen);
        assert(source.generated_cache_pool != self.generated_cache_pool);
        assert(source.generated_cache.len == self.generated_cache.len);
        assert(source.late_generated_cache.len == self.late_generated_cache.len);
        assert(source.late_generated_cache_pool != source.generated_cache_pool);
        assert(!source.late_generated_cache_pool.growable);
        self.generated_cache = source.generated_cache;
        self.generated_cache_pool = source.generated_cache_pool;
        self.generated_cache_frozen = true;
        self.late_generated_cache = source.late_generated_cache;
        self.late_generated_cache_pool = source.late_generated_cache_pool;
    }

    pub fn localize_generated_cache_from(
        self: *Evaluator,
        source: *const Evaluator,
        local_pool: *ValuePool,
    ) void {
        const entry_value_budget = generated_cache_entry_value_budget;
        const entry_string_budget: u32 = 256 * 1024;
        const total_value_budget = generated_cache_total_value_budget;
        const total_string_budget = generated_cache_total_string_budget;
        assert(source.generated_cache_frozen);
        assert(!self.generated_cache_frozen);
        assert(self.generated_cache.len == source.generated_cache.len);
        assert(local_pool != source.generated_cache_pool);

        const base = local_pool.snapshot();
        for (source.override_registry.generated) |operator| {
            if (!operator.cacheable) continue;
            const cache_index = operator.cache_index orelse continue;
            assert(cache_index < self.generated_cache.len);
            const source_value = source.generated_cache[cache_index] orelse
                continue;
            const used_values = local_pool.value_count - base.value_count;
            const used_strings = local_pool.string_count - base.string_count;
            if (used_values >= total_value_budget or
                used_strings >= total_string_budget)
            {
                break;
            }
            const value_budget = @min(
                entry_value_budget,
                total_value_budget - used_values,
            );
            const string_budget = @min(
                entry_string_budget,
                total_string_budget - used_strings,
            );
            const snapshot = local_pool.snapshot();
            const value_cap = local_pool.value_cap;
            const string_cap = local_pool.string_cap;
            const growable = local_pool.growable;
            local_pool.value_cap = @min(
                value_cap,
                snapshot.value_count + value_budget,
            );
            local_pool.string_cap = @min(
                string_cap,
                snapshot.string_count + string_budget,
            );
            local_pool.growable = false;
            const localized = source_value.clone(
                source.generated_cache_pool,
                local_pool,
            ) catch null;
            local_pool.value_cap = value_cap;
            local_pool.string_cap = string_cap;
            local_pool.growable = growable;
            if (localized) |value_v| {
                self.generated_cache[cache_index] = value_v;
            } else {
                local_pool.restore(snapshot);
            }
        }
        self.generated_cache_pool = local_pool;
        self.generated_cache_frozen = true;
        if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
            std.debug.print(
                "generated cache localized values={d} strings={d}\n",
                .{
                    local_pool.value_count - base.value_count,
                    local_pool.string_count - base.string_count,
                },
            );
        }
    }

    pub fn reset_context_pool(self: *const Evaluator) void {
        self.context_pool.reset();
    }

    pub fn context_snapshot(self: *const Evaluator) u64 {
        return self.context_pool.snapshot();
    }

    pub fn restore_context_pool(self: *const Evaluator, snapshot: u64) void {
        self.context_pool.restore(snapshot);
    }

    pub fn pin_context_pool(self: *const Evaluator) u64 {
        return self.context_pool.pin();
    }

    pub fn unpin_context_pool(self: *const Evaluator, previous: u64) void {
        self.context_pool.unpin(previous);
    }

    pub inline fn extend_context(
        self: *const Evaluator,
        context: Context,
        name: []const u8,
        value_v: Value,
    ) Error!Context {
        return self.context_pool.extend_local(
            context,
            name,
            value_v,
        );
    }

    pub inline fn extend_state_context(
        self: *const Evaluator,
        context: Context,
        name: []const u8,
        variable_index: u32,
        value_v: Value,
        assignment: AssignmentKind,
    ) Error!Context {
        return self.extend_state_context_from_pool(
            context,
            name,
            variable_index,
            value_v,
            null,
            assignment,
        );
    }

    pub inline fn extend_state_context_from_pool(
        self: *const Evaluator,
        context: Context,
        name: []const u8,
        variable_index: u32,
        value_v: Value,
        value_pool: ?*const ValuePool,
        assignment: AssignmentKind,
    ) Error!Context {
        assert(assignment != .local);
        assert(variable_index < self.module.variables.len);
        assert(name_eql(name, self.module.variables[variable_index]));
        return self.context_pool.extend_state(
            context,
            name,
            variable_index,
            value_v,
            value_pool,
            assignment,
        );
    }

    pub fn context_assignment(
        self: *const Evaluator,
        context: Context,
        name: []const u8,
    ) AssignmentKind {
        _ = self;
        var assignments = context.state_assignments();
        while (assignments.next()) |current| {
            if (name_eql(current.name, name)) return current.value.assignment;
        }
        return .local;
    }

    pub fn eval_named_zero(
        self: *const Evaluator,
        name: []const u8,
        context: Context,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        self.begin_state_evaluation(eval_pool);
        defer self.end_state_evaluation();
        const resolved = self.resolve_alias(name);
        if (self.override_registry.find_generated(resolved, 0)) |function| {
            return self.call_generated(
                function,
                &.{},
                context,
                current_state,
                eval_pool,
                state_pool,
                true,
            );
        }
        const definition = self.find_definition(resolved) orelse
            return Error.UndefinedSymbol;
        if (definition.params.len != 0) return Error.TypeError;
        return self.eval_expr(
            definition.body,
            context,
            current_state,
            eval_pool,
            state_pool,
        );
    }

    pub fn begin_state_evaluation(
        self: *const Evaluator,
        eval_pool: *ValuePool,
    ) void {
        self.state_definition_pool.restore(.{
            .value_count = 0,
            .string_count = 0,
            .string_intern_count = 0,
        });
        self.state_definition_memo.reset(self.state_definition_pool);
        self.state_call_memo.reset(self.state_definition_pool);
        _ = eval_pool;
    }

    pub fn end_state_evaluation(self: *const Evaluator) void {
        self.state_definition_memo.reset(null);
        self.state_call_memo.reset(null);
    }

    fn cached_state_call(
        self: *const Evaluator,
        name: []const u8,
        args: []const Value,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
    ) Error!?Value {
        const cached = self.state_call_memo.get(
            name,
            args,
            eval_pool,
            if (current_state) |state_v| @intFromPtr(state_v) else 0,
            if (self.next_state) |state_v| @intFromPtr(state_v) else 0,
        ) orelse return null;
        return try cached.clone(self.state_definition_pool, eval_pool);
    }

    fn memoize_state_call(
        self: *const Evaluator,
        name: []const u8,
        args: []const Value,
        current_state: ?*StateStore.State,
        result: Value,
        eval_pool: *ValuePool,
    ) Error!void {
        self.state_call_memo.put(
            name,
            args,
            eval_pool,
            if (current_state) |state_v| @intFromPtr(state_v) else 0,
            if (self.next_state) |state_v| @intFromPtr(state_v) else 0,
            result,
        ) catch |err| switch (err) {
            error.OutOfMemory, error.NotImplemented => {},
        };
    }

    fn reset_persistent_call_cache(self: *const Evaluator) void {
        self.persistent_call_pool.restore(.{
            .value_count = 0,
            .string_count = 0,
            .string_intern_count = 0,
        });
        self.persistent_call_memo.reset(self.persistent_call_pool);
        assert(self.persistent_call_memo.count == 0);
    }

    fn cached_persistent_call(
        self: *const Evaluator,
        name: []const u8,
        args: []const Value,
        eval_pool: *ValuePool,
    ) Error!?Value {
        assert(eval_pool != self.persistent_call_pool);
        const cached = self.persistent_call_memo.get(
            name,
            args,
            eval_pool,
            0,
            0,
        ) orelse return null;
        return try cached.clone(self.persistent_call_pool, eval_pool);
    }

    fn memoize_persistent_call(
        self: *const Evaluator,
        name: []const u8,
        args: []const Value,
        result: Value,
        eval_pool: *ValuePool,
    ) void {
        assert(eval_pool != self.persistent_call_pool);
        self.persistent_call_memo.put(
            name,
            args,
            eval_pool,
            0,
            0,
            result,
        ) catch |err| switch (err) {
            error.NotImplemented => return,
            error.OutOfMemory => {
                self.reset_persistent_call_cache();
                self.persistent_call_memo.put(
                    name,
                    args,
                    eval_pool,
                    0,
                    0,
                    result,
                ) catch return;
            },
        };
    }

    fn persistent_call_result_worth_caching(result: Value) bool {
        if (result.is_set_like()) return true;
        return switch (result) {
            .function_v, .record_v, .tuple_v => true,
            else => false,
        };
    }

    pub fn begin_action_evaluation(self: *const Evaluator) void {
        assert(self.action_call_memo.pool == null);
        self.action_call_pool.restore(.{
            .value_count = 0,
            .string_count = 0,
            .string_intern_count = 0,
        });
        self.action_call_memo.reset(self.action_call_pool);
        assert(self.action_call_memo.pool == self.action_call_pool);
    }

    pub fn end_action_evaluation(self: *const Evaluator) void {
        assert(self.action_call_memo.pool == self.action_call_pool);
        self.action_call_memo.reset(null);
        assert(self.action_call_memo.pool == null);
    }

    fn definition_is_recursive(
        self: *const Evaluator,
        definition: ast.Definition,
    ) bool {
        for (self.module.definitions, 0..) |candidate, index| {
            if (candidate.body != definition.body or
                !std.mem.eql(u8, candidate.name, definition.name))
            {
                continue;
            }
            if (self.recursive_definitions[index]) |recursive| {
                return recursive;
            }
            const recursive = codegen.expression_calls_identifier(
                definition.body,
                definition.name,
            );
            self.recursive_definitions[index] = recursive;
            return recursive;
        }
        return false;
    }

    pub fn find_generated_expression(
        self: *const Evaluator,
        identity: u32,
    ) ?generated_runtime.Expression {
        return self.override_registry.find_generated_expression(identity);
    }

    pub fn generated_expression_count(self: *const Evaluator) usize {
        return self.override_registry.generated_expressions.len;
    }

    pub fn generated_requires_state_memo(self: *const Evaluator) bool {
        return self.generated_state_memo_required;
    }

    pub fn eval_generated_expression(
        self: *const Evaluator,
        expression: *const generated_runtime.Expression,
        context: Context,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (expression.direct_value) |direct| return direct;
        if (expression.direct_arg_index) |index| {
            if (index >= expression.arg_names.len or
                index >= expression.arg_depths.len)
            {
                return Error.TypeError;
            }
            if (context.lookup_value_at_depth(
                expression.arg_names[index],
                expression.arg_depths[index],
            )) |direct| {
                if (!generated_runtime.requires_force(direct)) return direct;
            }
        }
        if (expression.arg_names.len > 32) return Error.NotImplemented;
        if (expression.arg_required.len != 0 and
            expression.arg_required.len != expression.arg_names.len)
        {
            return Error.TypeError;
        }
        var args: [32]Value = undefined;
        if (expression.arg_names.len > 0) {
            const found_at_depths = expression.arg_required.len == 0 and
                expression.arg_depths.len == expression.arg_names.len and
                context.lookup_values_at_depths(
                    expression.arg_names,
                    expression.arg_depths,
                    args[0..expression.arg_names.len],
                );
            const found = found_at_depths or try context.lookup_values_internal(
                expression.arg_names,
                expression.arg_required,
                args[0..expression.arg_names.len],
                eval_pool,
                false,
            );
            assert(found);
        }
        const result = self.call_generated(
            expression.function,
            args[0..expression.arg_names.len],
            context,
            current_state,
            eval_pool,
            state_pool,
            expression.uses_primed,
        ) catch |err| {
            if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                std.debug.print(
                    "generated expression {d} failed with {any}; args={any}\n",
                    .{ expression.identity, err, expression.arg_names },
                );
            }
            return err;
        };
        return result;
    }

    pub fn eval_generated_expression_if_args_available(
        self: *const Evaluator,
        expression: *const generated_runtime.Expression,
        context: Context,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        if (expression.direct_value) |direct| return direct;
        if (expression.direct_arg_index) |index| {
            if (index >= expression.arg_names.len or
                index >= expression.arg_depths.len)
            {
                return Error.TypeError;
            }
            if (context.lookup_value_at_depth(
                expression.arg_names[index],
                expression.arg_depths[index],
            )) |direct| {
                if (!generated_runtime.requires_force(direct)) return direct;
            }
        }
        if (expression.arg_names.len > 32) return Error.NotImplemented;
        if (expression.arg_required.len != 0 and
            expression.arg_required.len != expression.arg_names.len)
        {
            return Error.TypeError;
        }
        var args: [32]Value = undefined;
        if (expression.arg_names.len > 0) {
            const found_at_depths = expression.arg_required.len == 0 and
                expression.arg_depths.len == expression.arg_names.len and
                context.lookup_values_at_depths(
                    expression.arg_names,
                    expression.arg_depths,
                    args[0..expression.arg_names.len],
                );
            const found = found_at_depths or context.lookup_values_internal(
                expression.arg_names,
                expression.arg_required,
                args[0..expression.arg_names.len],
                eval_pool,
                false,
            ) catch |err| switch (err) {
                Error.UndefinedSymbol => false,
                else => return err,
            };
            if (!found) return null;
        }
        return self.call_generated(
            expression.function,
            args[0..expression.arg_names.len],
            context,
            current_state,
            eval_pool,
            state_pool,
            expression.uses_primed,
        ) catch |err| {
            if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                std.debug.print(
                    "generated expression {d} failed with {any}; args={any}\n",
                    .{ expression.identity, err, expression.arg_names },
                );
            }
            return err;
        };
    }

    pub fn eval_generated_expression_bool(
        self: *const Evaluator,
        expression: *const generated_runtime.Expression,
        context: Context,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!bool {
        if (expression.direct_value) |direct| {
            return generated_runtime.boolean(direct);
        }
        if (expression.direct_arg_index) |index| {
            if (index >= expression.arg_names.len or
                index >= expression.arg_depths.len)
            {
                return Error.TypeError;
            }
            if (context.lookup_value_at_depth(
                expression.arg_names[index],
                expression.arg_depths[index],
            )) |direct| {
                if (!generated_runtime.requires_force(direct)) {
                    return generated_runtime.boolean(direct);
                }
            }
        }
        const boolean_function = expression.boolean_function orelse {
            const result = try self.eval_generated_expression(
                expression,
                context,
                current_state,
                eval_pool,
                state_pool,
            );
            return result.is_truthy();
        };
        if (expression.arg_names.len > 32) return Error.NotImplemented;
        if (expression.arg_required.len != 0 and
            expression.arg_required.len != expression.arg_names.len)
        {
            return Error.TypeError;
        }
        var args: [32]Value = undefined;
        if (expression.arg_names.len > 0) {
            const found_at_depths = expression.arg_required.len == 0 and
                expression.arg_depths.len == expression.arg_names.len and
                context.lookup_values_at_depths(
                    expression.arg_names,
                    expression.arg_depths,
                    args[0..expression.arg_names.len],
                );
            const found = found_at_depths or try context.lookup_values_internal(
                expression.arg_names,
                expression.arg_required,
                args[0..expression.arg_names.len],
                eval_pool,
                false,
            );
            assert(found);
        }
        return self.call_generated_bool(
            boolean_function,
            args[0..expression.arg_names.len],
            context,
            current_state,
            eval_pool,
            state_pool,
            expression.uses_primed,
        ) catch |err| {
            if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                std.debug.print(
                    "generated boolean expression {d} failed with {any}; args={any}\n",
                    .{ expression.identity, err, expression.arg_names },
                );
            }
            return err;
        };
    }

    pub fn eval_generated_expression_bool_if_args_available(
        self: *const Evaluator,
        expression: *const generated_runtime.Expression,
        context: Context,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?bool {
        if (expression.direct_value) |direct| {
            return try generated_runtime.boolean(direct);
        }
        if (expression.direct_arg_index) |index| {
            if (index >= expression.arg_names.len or
                index >= expression.arg_depths.len)
            {
                return Error.TypeError;
            }
            if (context.lookup_value_at_depth(
                expression.arg_names[index],
                expression.arg_depths[index],
            )) |direct| {
                if (!generated_runtime.requires_force(direct)) {
                    return try generated_runtime.boolean(direct);
                }
            }
        }
        const boolean_function = expression.boolean_function orelse {
            const result = try self.eval_generated_expression_if_args_available(
                expression,
                context,
                current_state,
                eval_pool,
                state_pool,
            ) orelse return null;
            return result.is_truthy();
        };
        if (expression.arg_names.len > 32) return Error.NotImplemented;
        if (expression.arg_required.len != 0 and
            expression.arg_required.len != expression.arg_names.len)
        {
            return Error.TypeError;
        }
        var args: [32]Value = undefined;
        if (expression.arg_names.len > 0) {
            const found_at_depths = expression.arg_required.len == 0 and
                expression.arg_depths.len == expression.arg_names.len and
                context.lookup_values_at_depths(
                    expression.arg_names,
                    expression.arg_depths,
                    args[0..expression.arg_names.len],
                );
            const found = found_at_depths or context.lookup_values_internal(
                expression.arg_names,
                expression.arg_required,
                args[0..expression.arg_names.len],
                eval_pool,
                false,
            ) catch |err| switch (err) {
                Error.UndefinedSymbol => false,
                else => return err,
            };
            if (!found) return null;
        }
        return self.call_generated_bool(
            boolean_function,
            args[0..expression.arg_names.len],
            context,
            current_state,
            eval_pool,
            state_pool,
            expression.uses_primed,
        ) catch |err| {
            if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                std.debug.print(
                    "generated boolean expression {d} failed with {any}; args={any}\n",
                    .{ expression.identity, err, expression.arg_names },
                );
            }
            return err;
        };
    }

    pub fn make_generated_expression_operator(
        self: *const Evaluator,
        expression: *const generated_runtime.Expression,
        arity: u16,
        context: Context,
        eval_pool: *ValuePool,
    ) Error!Value {
        _ = self;
        if (arity > expression.arg_names.len) return Error.TypeError;
        if (expression.arg_required.len != 0 and
            expression.arg_required.len != expression.arg_names.len)
        {
            return Error.TypeError;
        }
        const capture_count = expression.arg_names.len - arity;
        const captures = try eval_pool.alloc_values(@intCast(capture_count));
        const required = if (expression.arg_required.len == 0)
            &.{}
        else
            expression.arg_required[0..capture_count];
        try context.lookup_values(
            expression.arg_names[0..capture_count],
            required,
            captures,
            eval_pool,
        );
        const offset: u32 = if (captures.len == 0)
            0
        else
            @intCast(
                (@intFromPtr(captures.ptr) -
                    @intFromPtr(eval_pool.values.ptr)) /
                    @sizeOf(Value),
            );
        return .{ .generated_operator_v = .{
            .function_address = @intFromPtr(expression.function),
            .arity = arity,
            .captured_offset = offset,
            .captured_len = @intCast(captures.len),
        } };
    }

    pub fn set_next_state(self: *Evaluator, st: ?*state.StateStore.State) void {
        self.next_state = st;
    }

    pub fn set_enabled_result(self: *Evaluator, enabled: ?bool) void {
        self.enabled_result = enabled;
    }

    pub fn set_definition_memo_pool(
        self: *Evaluator,
        pool: ?*ValuePool,
    ) void {
        self.definition_memo.reset(pool);
    }

    pub fn freeze_definition_memo(self: *Evaluator) void {
        self.definition_memo.freeze();
    }

    pub fn set_constants(self: *Evaluator, constants: []const Constant) void {
        self.reset_persistent_call_cache();
        self.constants = constants;
        @memset(self.constant_slots, null);
        for (self.module.constants, 0..) |name, index| {
            for (constants) |constant| {
                if (name_eql(name, constant.name)) {
                    self.constant_slots[index] = constant.value;
                    break;
                }
            }
        }
    }

    pub fn set_aliases(self: *Evaluator, aliases: []const Alias) void {
        self.reset_persistent_call_cache();
        self.aliases = aliases;
    }

    /// Record error context and return the error. Always use this in hot paths
    /// so the top-level handler can print what went wrong.
    pub fn fail(self: *const Evaluator, err: Error, context: []const u8, detail: []const u8) Error {
        self.err_ctx.context = context;
        self.err_ctx.detail = detail;
        return err;
    }

    pub fn resolve_alias(self: *const Evaluator, name: []const u8) []const u8 {
        for (self.aliases) |a| {
            if (name_eql(name, a.from)) return a.to;
        }
        return name;
    }

    fn is_module_operator(
        self: *const Evaluator,
        name: []const u8,
        module_name: []const u8,
        operator_name: []const u8,
    ) bool {
        if (std.mem.eql(u8, name, operator_name)) {
            const definition = self.find_definition(name) orelse return false;
            return definition_source_module(definition, module_name);
        }
        const bang = std.mem.lastIndexOfScalar(u8, name, '!') orelse
            return false;
        return std.mem.eql(u8, name[0..bang], module_name) and
            std.mem.eql(u8, name[bang + 1 ..], operator_name);
    }

    pub fn find_constant(self: *const Evaluator, name: []const u8) ?Value {
        for (self.constants) |c| {
            if (name_eql(c.name, name)) return c.value;
        }
        return null;
    }

    pub fn eval_expr(
        self: *const Evaluator,
        expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        assert(@intFromPtr(expr) != 0);
        assert(eval_pool.value_count <= eval_pool.value_cap);
        assert(state_pool.value_count <= state_pool.value_cap);
        const root_call = !self.err_ctx.active;
        if (root_call) {
            if (ctx.len == 0 and
                ctx.state_assignment_mask() == 0 and
                self.context_pool.can_reset_at_root())
            {
                self.context_pool.reset();
            }
            self.err_ctx.context = null;
            self.err_ctx.detail = null;
            self.err_ctx.active = true;
        }
        defer if (root_call) {
            assert(self.err_ctx.active);
            self.err_ctx.active = false;
        };
        const result = self.eval_expr_inner(expr, ctx, s0, eval_pool, state_pool);
        return result catch |err| {
            if (self.err_ctx.context == null) {
                self.err_ctx.context = "expr";
                self.err_ctx.detail = if (expr.* == .apply and
                    expr.apply.func.* == .ident)
                    expr.apply.func.ident
                else
                    @tagName(expr.*);
            }
            return err;
        };
    }

    fn eval_expr_inner(
        self: *const Evaluator,
        expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        switch (expr.*) {
            .bool_literal => |b| return Value{ .bool_v = b },
            .int_literal => |i| return Value{ .int_v = i },
            .string_literal => |s| return Value{ .string_v = try eval_pool.push_string(s) },
            .ident => |name| {
                if (try self.eval_local_identifier(
                    ctx,
                    name,
                    s0,
                    eval_pool,
                    state_pool,
                )) |v| return v;
                const aliased = self.resolve_alias(name);
                if (!std.mem.eql(u8, aliased, name)) {
                    if (try self.eval_local_identifier(
                        ctx,
                        aliased,
                        s0,
                        eval_pool,
                        state_pool,
                    )) |v| return v;
                }
                if (s0) |st| {
                    if (self.find_variable(name)) |idx| {
                        return try st.values[idx].clone(
                            st.value_pool(idx, state_pool),
                            eval_pool,
                        );
                    }
                    if (!std.mem.eql(u8, aliased, name)) {
                        if (self.find_variable(aliased)) |idx| {
                            return try st.values[idx].clone(
                                st.value_pool(idx, state_pool),
                                eval_pool,
                            );
                        }
                    }
                } else {
                    if (try ctx.lookup_value(name, eval_pool)) |v| return v;
                    if (!std.mem.eql(u8, aliased, name)) {
                        if (try ctx.lookup_value(aliased, eval_pool)) |v| return v;
                    }
                }
                if (self.find_constant(name)) |v| return try v.clone(state_pool, eval_pool);
                if (self.is_module_operator(
                    aliased,
                    "IOUtils",
                    "IOEnv",
                )) {
                    return try overrides.io_env(
                        self.override_registry.ctx,
                        eval_pool,
                    );
                }
                if (self.override_registry.find_value(aliased)) |func| {
                    return try func(self.override_registry.ctx, eval_pool);
                }
                // Check if the aliased name is a constant.
                if (!std.mem.eql(u8, aliased, name)) {
                    if (self.find_constant(aliased)) |v| return try v.clone(state_pool, eval_pool);
                }
                // Built-in constant sets.
                if (std.mem.eql(u8, aliased, "Nat")) {
                    // Nat = set of all natural numbers. Represent as a special
                    // range_v with hi = maxInt so membership checks work.
                    return Value{ .range_v = .{ .lo = 0, .hi = std.math.maxInt(i64) } };
                }
                if (std.mem.eql(u8, aliased, "Int")) {
                    return Value{ .range_v = .{
                        .lo = std.math.minInt(i64),
                        .hi = std.math.maxInt(i64),
                    } };
                }
                if (std.mem.eql(u8, aliased, "BOOLEAN")) {
                    const dest = try eval_pool.alloc_values(2);
                    dest[0] = Value{ .bool_v = false };
                    dest[1] = Value{ .bool_v = true };
                    return Value{ .set_v = try make_set(eval_pool, dest) };
                }
                if (std.mem.eql(u8, aliased, "STRING")) {
                    // STRING (set of all strings) — represented as a model value
                    // that can be checked for membership.
                    return Value{ .string_v = try eval_pool.push_string("__STRING_SET__") };
                }
                if (self.override_registry.find_generated(
                    aliased,
                    0,
                )) |func| {
                    return try self.call_generated(
                        func,
                        &.{},
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                        true,
                    );
                }
                if (self.find_definition(aliased)) |def| {
                    if (def.is_function) {
                        return try self.make_recursive_function(
                            def,
                            ctx.operator_frame(),
                            eval_pool,
                        );
                    }
                    if (def.params.len != 0) {
                        return try self.make_lambda(
                            def,
                            ctx.operator_frame(),
                            eval_pool,
                        );
                    }
                    if (s0 == null and ctx.len == 0) {
                        if (self.definition_memo.get(eval_pool, aliased)) |v| {
                            return v;
                        }
                        const v = try self.eval_expr(
                            def.body,
                            ctx,
                            s0,
                            eval_pool,
                            state_pool,
                        );
                        try self.definition_memo.put(
                            eval_pool,
                            aliased,
                            v,
                        );
                        return v;
                    }
                    if (s0 != null) {
                        if (self.state_definition_memo.get(
                            self.state_definition_pool,
                            aliased,
                        )) |value_v| {
                            return try value_v.clone(
                                self.state_definition_pool,
                                eval_pool,
                            );
                        }
                        const value_v = try self.eval_expr(
                            def.body,
                            ctx.operator_frame(),
                            s0,
                            eval_pool,
                            state_pool,
                        );
                        const memo_value = value_v.clone(
                            eval_pool,
                            self.state_definition_pool,
                        ) catch |err| switch (err) {
                            error.NotImplemented => return value_v,
                            else => return err,
                        };
                        self.state_definition_memo.put(
                            self.state_definition_pool,
                            aliased,
                            memo_value,
                        ) catch |err| {
                            if (err != Error.OutOfMemory) return err;
                        };
                        return value_v;
                    }
                    return try self.eval_expr(
                        def.body,
                        ctx.operator_frame(),
                        s0,
                        eval_pool,
                        state_pool,
                    );
                }
                if (self.find_subexpression(aliased)) |body| {
                    return try self.eval_expr(body, ctx, s0, eval_pool, state_pool);
                }
                if (self.treat_unknown_as_model) {
                    const id = try self.models.intern(name);
                    return Value{ .model_v = id };
                }
                return self.fail(Error.UndefinedSymbol, "ident", name);
            },
            .primed => |name| {
                const aliased = self.resolve_alias(name);
                if (try ctx.lookup_value(aliased, eval_pool)) |v| return v;
                if (try ctx.lookup_value(name, eval_pool)) |v| return v;
                const ns = self.next_state;
                if (ns) |nst| {
                    if (self.find_variable(aliased)) |idx| {
                        return try nst.values[idx].clone(
                            nst.value_pool(idx, state_pool),
                            eval_pool,
                        );
                    }
                    if (self.find_definition(aliased)) |def| {
                        if (def.params.len != 0) return Error.TypeError;
                        return try self.eval_expr(
                            def.body,
                            ctx.operator_frame(),
                            ns,
                            eval_pool,
                            state_pool,
                        );
                    }
                }
                if (s0) |st| {
                    if (self.find_variable(aliased)) |idx| {
                        return try st.values[idx].clone(
                            st.value_pool(idx, state_pool),
                            eval_pool,
                        );
                    }
                }
                if (self.find_definition(aliased)) |def| {
                    if (def.params.len != 0) return Error.TypeError;
                    if (ns) |next| {
                        return try self.eval_expr(
                            def.body,
                            ctx,
                            next,
                            eval_pool,
                            state_pool,
                        );
                    }
                    const current = s0 orelse
                        return self.fail(
                            Error.TypeError,
                            "primed definition without current state",
                            name,
                        );
                    return try self.eval_primed_definition(
                        def,
                        ctx,
                        current,
                        eval_pool,
                        state_pool,
                    );
                }
                return self.fail(Error.UndefinedSymbol, "primed", name);
            },
            .primed_expr => |operand| {
                const child = self.next_state orelse
                    return self.fail(Error.TypeError, "primed expression", "missing next state");
                return try self.eval_expr(
                    operand,
                    ctx,
                    child,
                    eval_pool,
                    state_pool,
                );
            },
            .binary => |b| {
                return self.eval_binary(
                    b,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                ) catch |err| {
                    if (err == Error.TypeError and
                        self.err_ctx.context == null)
                    {
                        self.err_ctx.context = "binary";
                        self.err_ctx.detail = @tagName(b.op);
                    }
                    return err;
                };
            },
            .unary => |u| {
                if (try eval_symbolic_set(self, expr, ctx, s0, eval_pool, state_pool)) |sv| return sv;
                return try self.eval_unary(u, ctx, s0, eval_pool, state_pool);
            },
            .if_then_else => |ite| {
                const c = try self.eval_expr(ite.cond, ctx, s0, eval_pool, state_pool);
                if (c.as_bool() orelse return Error.TypeError) {
                    return try self.eval_expr(ite.then_branch, ctx, s0, eval_pool, state_pool);
                }
                return try self.eval_expr(ite.else_branch, ctx, s0, eval_pool, state_pool);
            },
            .set_enum => |items| {
                if (items.len > 256) return self.fail(Error.NotImplemented, "set literal", "more than 256 elements");
                var scratch: [256]Value = undefined;
                for (items, 0..) |it, i| {
                    scratch[i] = try self.eval_expr(it, ctx, s0, eval_pool, state_pool);
                }
                const dest = try eval_pool.alloc_values(@intCast(items.len));
                @memcpy(dest, scratch[0..items.len]);
                return Value{ .set_v = try make_set(eval_pool, dest) };
            },
            .set_filter => |sf| return try self.eval_set_filter(sf, ctx, s0, eval_pool, state_pool),
            .set_map => |sm| {
                if (try eval_symbolic_set(self, expr, ctx, s0, eval_pool, state_pool)) |sv| return sv;
                return try self.eval_set_map(sm, ctx, s0, eval_pool, state_pool);
            },
            .set_binary => |sb| {
                if (try eval_symbolic_set(self, expr, ctx, s0, eval_pool, state_pool)) |sv| return sv;
                return try self.eval_set_binary(sb, ctx, s0, eval_pool, state_pool);
            },
            .set_of_functions => |sf| {
                if (try eval_symbolic_set(
                    self,
                    expr,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                )) |symbolic| return symbolic;
                return try self.eval_set_of_functions(
                    sf,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
            },
            .record_set => |rs| {
                if (try eval_symbolic_set(self, expr, ctx, s0, eval_pool, state_pool)) |sv| return sv;
                return try self.eval_record_set(rs, ctx, s0, eval_pool, state_pool);
            },
            .function_literal => |fl| return try self.eval_function_literal(fl, ctx, s0, eval_pool, state_pool),
            .apply => |ap| return try self.eval_apply(ap, ctx, s0, eval_pool, state_pool),
            .field => |f| return try self.eval_field(f, ctx, s0, eval_pool, state_pool),
            .tuple => |t| {
                if (t.len > 64) return self.fail(Error.NotImplemented, "tuple literal", "more than 64 elements");
                var scratch: [64]Value = undefined;
                for (t, 0..) |it, i| {
                    scratch[i] = try self.eval_expr(it, ctx, s0, eval_pool, state_pool);
                }
                const dest = try eval_pool.alloc_values(@intCast(t.len));
                @memcpy(dest, scratch[0..t.len]);
                return Value{ .tuple_v = make_tuple(eval_pool, dest) };
            },
            .record => |r| {
                if (r.len > 64) return self.fail(Error.NotImplemented, "record literal", "more than 64 fields");
                var scratch: [128]Value = undefined;
                for (r, 0..) |field, i| {
                    scratch[i * 2] = Value{ .string_v = try eval_pool.push_string(field.name) };
                    scratch[i * 2 + 1] = try self.eval_expr(field.value, ctx, s0, eval_pool, state_pool);
                }
                const value_count = r.len * 2;
                const dest = try eval_pool.alloc_values(@intCast(value_count));
                @memcpy(dest, scratch[0..value_count]);
                return Value{ .record_v = make_record(eval_pool, dest) };
            },
            .quantifier => |q| return try self.eval_quantifier(q, ctx, s0, eval_pool, state_pool),
            .choose => |c| return try self.eval_choose(c, ctx, s0, eval_pool, state_pool),
            .unchanged => |names| {
                const parent = s0 orelse
                    return self.fail(Error.TypeError, "UNCHANGED", "missing parent state");
                const child = self.next_state orelse
                    return self.fail(Error.TypeError, "UNCHANGED", "missing next state");
                for (names) |name| {
                    if (self.find_variable(name)) |idx| {
                        if (!Value.eql_cross_pool(
                            parent.values[idx],
                            parent.value_pool(idx, state_pool),
                            child.values[idx],
                            child.value_pool(idx, state_pool),
                        )) {
                            return Value{ .bool_v = false };
                        }
                        continue;
                    }
                    const def = self.find_definition(name) orelse
                        return self.fail(Error.UndefinedSymbol, "UNCHANGED", name);
                    if (def.params.len != 0) {
                        return self.fail(Error.TypeError, "UNCHANGED", name);
                    }
                    const parent_value = try self.eval_expr(
                        def.body,
                        ctx,
                        parent,
                        eval_pool,
                        state_pool,
                    );
                    const child_value = try self.eval_expr(
                        def.body,
                        ctx,
                        child,
                        eval_pool,
                        state_pool,
                    );
                    if (!parent_value.eql(child_value, eval_pool)) {
                        return Value{ .bool_v = false };
                    }
                }
                return Value{ .bool_v = true };
            },
            .unchanged_expr => |operand| {
                const parent = s0 orelse
                    return self.fail(Error.TypeError, "UNCHANGED", "missing parent state");
                const child = self.next_state orelse
                    return self.fail(Error.TypeError, "UNCHANGED", "missing next state");
                const parent_value = try self.eval_expr(
                    operand,
                    ctx,
                    parent,
                    eval_pool,
                    state_pool,
                );
                const child_value = try self.eval_expr(
                    operand,
                    ctx,
                    child,
                    eval_pool,
                    state_pool,
                );
                return Value{ .bool_v = parent_value.eql(child_value, eval_pool) };
            },
            .except => |e| return try self.eval_except(e, ctx, s0, eval_pool, state_pool),
            .let_in => |l| return try self.eval_let_in(l, ctx, s0, eval_pool, state_pool),
            .case_expr => |c| return try self.eval_case_expr(c, ctx, s0, eval_pool, state_pool),
            .box_action => return Value{ .bool_v = true },
            .lambda => |l| {
                const lam = try eval_pool.arena.alloc_object(value.Lambda);
                const ctx_ptr = try eval_pool.arena.alloc_object(Context);
                ctx_ptr.* = ctx;
                const params_copy = try eval_pool.arena.alloc([]const u8, l.params.len);
                for (l.params, 0..) |p, i| params_copy[i] = p;
                lam.* = value.Lambda{
                    .params = params_copy,
                    .body = @ptrCast(l.body),
                    .ctx = @ptrCast(ctx_ptr),
                };
                return Value{ .lambda_v = lam };
            },
            .at => return (try ctx.lookup_value("@", eval_pool)) orelse
                Error.SyntaxError,
        }
    }

    fn eval_binary(
        self: *const Evaluator,
        b: *ast.Binary,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const left = try self.eval_binary_operand(
            b,
            b.left,
            "left",
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        switch (b.op) {
            .and_op => {
                if (!left.is_truthy()) return Value{ .bool_v = false };
                const right = try self.eval_binary_operand(b, b.right, "right", ctx, s0, eval_pool, state_pool);
                return Value{ .bool_v = right.is_truthy() };
            },
            .or_op => {
                if (left.is_truthy()) return Value{ .bool_v = true };
                const right = try self.eval_binary_operand(b, b.right, "right", ctx, s0, eval_pool, state_pool);
                return Value{ .bool_v = right.is_truthy() };
            },
            .implies => {
                if (!left.is_truthy()) return Value{ .bool_v = true };
                const right = try self.eval_binary_operand(b, b.right, "right", ctx, s0, eval_pool, state_pool);
                return Value{ .bool_v = right.is_truthy() };
            },
            .equiv => {
                const right = try self.eval_binary_operand(b, b.right, "right", ctx, s0, eval_pool, state_pool);
                return Value{ .bool_v = left.is_truthy() == right.is_truthy() };
            },
            .in => {
                if (is_seq_application(b.right)) {
                    return Value{ .bool_v = try self.sequence_member(
                        left,
                        b.right.apply.args[0],
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    ) };
                }
                return Value{ .bool_v = try self.value_in_set_expression(
                    left,
                    b.right,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                    0,
                ) };
            },
            .notin => {
                if (is_seq_application(b.right)) {
                    return Value{ .bool_v = !try self.sequence_member(
                        left,
                        b.right.apply.args[0],
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    ) };
                }
                if (try eval_symbolic_set(self, b.right, ctx, s0, eval_pool, state_pool)) |right| {
                    assert(right.is_set_like());
                    return Value{ .bool_v = !right.member(eval_pool, left) };
                }
                const right = try self.eval_expr(b.right, ctx, s0, eval_pool, state_pool);
                if (!right.is_set_like()) return self.fail(Error.TypeError, "\\notin: rhs not a set", @tagName(right));
                return Value{ .bool_v = !right.member(eval_pool, left) };
            },
            else => {},
        }
        const right = try self.eval_binary_operand(
            b,
            b.right,
            "right",
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        return switch (b.op) {
            .eq => Value{ .bool_v = try self.equal_values(
                left,
                right,
                ctx,
                s0,
                eval_pool,
                state_pool,
            ) },
            .ne => Value{ .bool_v = !try self.equal_values(
                left,
                right,
                ctx,
                s0,
                eval_pool,
                state_pool,
            ) },
            .lt => Value{ .bool_v = (left.as_int() orelse return self.fail(Error.TypeError, "<", @tagName(left))) < (right.as_int() orelse return self.fail(Error.TypeError, "<", @tagName(right))) },
            .le => Value{ .bool_v = (left.as_int() orelse return self.fail(Error.TypeError, "<=", @tagName(left))) <= (right.as_int() orelse return self.fail(Error.TypeError, "<=", @tagName(right))) },
            .gt => Value{ .bool_v = (left.as_int() orelse return self.fail(Error.TypeError, ">", @tagName(left))) > (right.as_int() orelse return self.fail(Error.TypeError, ">", @tagName(right))) },
            .ge => Value{ .bool_v = (left.as_int() orelse return self.fail(Error.TypeError, ">=", @tagName(left))) >= (right.as_int() orelse return self.fail(Error.TypeError, ">=", @tagName(right))) },
            .subseteq => {
                if (!left.is_set_like() or !right.is_set_like()) return self.fail(Error.TypeError, "\\subseteq", @tagName(left));
                const lmat = try self.materialize_set(left, ctx, s0, eval_pool, state_pool);
                if (lmat != .set_v) return self.fail(Error.TypeError, "\\subseteq", "lhs materialize failed");
                for (lmat.set_v.items(eval_pool)) |item| {
                    if (!right.member(eval_pool, item)) return Value{ .bool_v = false };
                }
                return Value{ .bool_v = true };
            },
            .plus => {
                const lv = left.as_int() orelse return self.fail(Error.TypeError, "+", @tagName(left));
                const rv = right.as_int() orelse return self.fail(Error.TypeError, "+ right", @tagName(right));
                return Value{ .int_v = lv + rv };
            },
            .minus => Value{ .int_v = (left.as_int() orelse return self.fail(Error.TypeError, "-", @tagName(left))) - (right.as_int() orelse return self.fail(Error.TypeError, "-", @tagName(right))) },
            .times => Value{ .int_v = (left.as_int() orelse return self.fail(Error.TypeError, "*", @tagName(left))) * (right.as_int() orelse return self.fail(Error.TypeError, "*", @tagName(right))) },
            .div => {
                const denom = right.as_int() orelse return self.fail(Error.TypeError, "\\div", @tagName(right));
                if (denom == 0) return Error.DivisionByZero;
                return Value{ .int_v = @divTrunc(left.as_int() orelse return self.fail(Error.TypeError, "\\div", @tagName(left)), denom) };
            },
            .mod => {
                const denom = right.as_int() orelse return self.fail(Error.TypeError, "%", @tagName(right));
                if (denom == 0) return Error.DivisionByZero;
                return Value{ .int_v = @mod(left.as_int() orelse return self.fail(Error.TypeError, "%", @tagName(left)), denom) };
            },
            .power => {
                const base = left.as_int() orelse return self.fail(Error.TypeError, "^", @tagName(left));
                const exp = right.as_int() orelse return self.fail(Error.TypeError, "^", @tagName(right));
                if (exp < 0) return Error.DivisionByZero;
                var result: i64 = 1;
                var i: i64 = 0;
                while (i < exp) : (i += 1) result *= base;
                return Value{ .int_v = result };
            },
            .range => {
                const lo = left.as_int() orelse return self.fail(Error.TypeError, "..", @tagName(left));
                const hi = right.as_int() orelse return self.fail(Error.TypeError, "..", @tagName(right));
                return Value{ .range_v = .{ .lo = lo, .hi = hi } };
            },
            .concat => return try overrides.sequence_concat(self.override_registry.ctx, eval_pool, left, right),
            .ooverride => return try overrides.ooverride(self.override_registry.ctx, eval_pool, left, right),
            .recordto => return try overrides.recordto(self.override_registry.ctx, eval_pool, left, right),
            .leads_to => {
                // P ~> Q is a temporal operator; normal expression evaluation
                // should not encounter it.  Return true as a conservative stub
                // to avoid errors during state/action evaluation.
                return Value{ .bool_v = true };
            },
            else => {
                return self.fail(Error.NotImplemented, "binary", @tagName(b.op));
            },
        };
    }

    fn equal_values(
        self: *const Evaluator,
        left: Value,
        right: Value,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!bool {
        if (!left.is_set_like() or !right.is_set_like()) {
            return left.eql(right, eval_pool);
        }
        const left_empty = known_set_empty(left, eval_pool);
        const right_empty = known_set_empty(right, eval_pool);
        if (left_empty != null and right_empty != null and
            (left_empty.? or right_empty.?))
        {
            return left_empty.? == right_empty.?;
        }
        if (std.meta.activeTag(left) == std.meta.activeTag(right)) {
            return left.eql(right, eval_pool);
        }
        const materialized_left = try self.materialize_set(
            left,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        const materialized_right = try self.materialize_set(
            right,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        return materialized_left.eql(materialized_right, eval_pool);
    }

    fn eval_binary_operand(
        self: *const Evaluator,
        binary: *ast.Binary,
        operand: *ast.Expr,
        side: []const u8,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        return self.eval_expr(
            operand,
            ctx,
            s0,
            eval_pool,
            state_pool,
        ) catch |err| {
            if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                std.debug.print(
                    "binary operand failed: side={s} op={s} node={s}",
                    .{ side, @tagName(binary.op), @tagName(operand.*) },
                );
                if (operand.* == .ident) {
                    std.debug.print(" ident={s}", .{operand.*.ident});
                }
                std.debug.print(" error={any}\n", .{err});
            }
            if (self.err_ctx.context != null and
                std.mem.eql(u8, self.err_ctx.context.?, "expr"))
            {
                self.err_ctx.context = side;
                self.err_ctx.detail = @tagName(binary.op);
            }
            return err;
        };
    }

    fn sequence_member(
        self: *const Evaluator,
        sequence: Value,
        element_set_expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!bool {
        const element_set = if (try eval_symbolic_set(self, element_set_expr, ctx, s0, eval_pool, state_pool)) |set|
            set
        else
            try self.eval_expr(element_set_expr, ctx, s0, eval_pool, state_pool);
        if (!element_set.is_set_like()) {
            return self.fail(Error.TypeError, "Seq", "argument is not a set");
        }

        switch (sequence) {
            .tuple_v => |tuple| {
                assert(tuple.offset + tuple.len <= eval_pool.value_count);
                for (tuple.items(eval_pool)) |element| {
                    if (!element_set.member(eval_pool, element)) return false;
                }
                return true;
            },
            .function_v => |function| {
                assert(function.offset + function.len <= eval_pool.value_count);
                assert(function.domain.len == function.len);
                var i: u32 = 0;
                while (i < function.len) : (i += 1) {
                    const element = function.apply(
                        eval_pool,
                        Value{ .int_v = @as(i64, @intCast(i)) + 1 },
                    ) orelse return false;
                    if (!element_set.member(eval_pool, element)) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    fn eval_unary(
        self: *const Evaluator,
        u: *ast.Unary,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        switch (u.op) {
            .enabled => return Value{ .bool_v = self.enabled_result orelse true },
            .temporal_box, .temporal_diamond => {
                // These operators are interpreted over the completed state
                // graph. Their operands must not be evaluated as state
                // expressions here (notably ENABLED actions have no next
                // state in this path).
                return Value{ .bool_v = true };
            },
            else => {},
        }
        const operand = try self.eval_expr(u.operand, ctx, s0, eval_pool, state_pool);
        return switch (u.op) {
            .not => Value{ .bool_v = !operand.is_truthy() },
            .neg => Value{ .int_v = -(operand.as_int() orelse return self.fail(Error.TypeError, "-", @tagName(operand))) },
            .subset => blk: {
                if (!operand.is_set_like()) return self.fail(Error.TypeError, "SUBSET", "non-set operand");
                const mat = try self.materialize_set(operand, ctx, s0, eval_pool, state_pool);
                break :blk try eval_subset(eval_pool, mat);
            },
            .union_all => blk: {
                if (!operand.is_set_like()) return self.fail(Error.TypeError, "UNION", "non-set operand");
                const mat = try self.materialize_set(operand, ctx, s0, eval_pool, state_pool);
                break :blk try eval_union_all(eval_pool, mat);
            },
            .domain => {
                const domain_operand = if (operand == .generated_operator_v)
                    try self.apply_values(
                        operand,
                        &.{},
                        eval_pool,
                        state_pool,
                        s0,
                    )
                else
                    operand;
                if (domain_operand == .function_v) return Value{ .set_v = domain_operand.function_v.domain };
                if (domain_operand == .record_v) {
                    const fields = domain_operand.record_v.fields(eval_pool);
                    const names = try eval_pool.alloc_values(
                        domain_operand.record_v.len,
                    );
                    var i: u32 = 0;
                    while (i < domain_operand.record_v.len) : (i += 1) {
                        assert(fields[i * 2] == .string_v);
                        names[i] = fields[i * 2];
                    }
                    return Value{ .set_v = try make_set(eval_pool, names) };
                }
                // Tuples (sequences) have domain 1..Len.
                if (domain_operand == .tuple_v) {
                    const n = domain_operand.tuple_v.len;
                    if (n == 0) {
                        const empty = try eval_pool.alloc_values(0);
                        return Value{ .set_v = try make_set(eval_pool, empty) };
                    }
                    return Value{ .range_v = .{ .lo = 1, .hi = @intCast(n) } };
                }
                return self.fail(Error.TypeError, "DOMAIN", @tagName(domain_operand));
            },
            .enabled, .temporal_box, .temporal_diamond => unreachable,
        };
    }

    fn eval_set_filter(
        self: *const Evaluator,
        sf: *ast.SetFilter,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (sf.vars.len == 1) {
            if (try self.eval_hereditary_power_set_filter(
                sf,
                ctx,
                s0,
                eval_pool,
                state_pool,
            )) |symbolic| {
                return symbolic;
            }
            if (try eval_symbolic_integer_filter(
                self,
                sf,
                ctx,
                s0,
                eval_pool,
                state_pool,
            )) |symbolic| {
                return symbolic;
            }
            const bv = sf.vars[0];
            if (try self.eval_function_set_filter(
                sf,
                bv,
                ctx,
                s0,
                eval_pool,
                state_pool,
            )) |filtered| {
                return filtered;
            }
            if (try self.eval_sorted_sequence_filter(sf, bv, ctx, s0, eval_pool, state_pool)) |sorted| {
                return sorted;
            }
            const domain = try self.eval_set_materialized(bv.domain, ctx, s0, eval_pool, state_pool);
            const domain_set = domain.set_v;
            assert(domain_set.offset + domain_set.len <= eval_pool.value_count);
            const accepted_offset = eval_pool.value_count;
            _ = try eval_pool.alloc_values(domain_set.len);
            const scratch_snapshot = eval_pool.snapshot();
            const context_snap = self.context_snapshot();
            var accepted_count: u32 = 0;
            for (0..domain_set.len) |item_index| {
                // Keep offsets rather than slices across predicate evaluation:
                // a growable scratch pool may replace its backing allocation.
                const it = eval_pool.values[domain_set.offset + item_index];
                const new_ctx = try self.extend_context(ctx, bv.name, it);
                const pred = try self.eval_expr(sf.pred, new_ctx, s0, eval_pool, state_pool);
                if (pred.is_truthy()) {
                    assert(accepted_count < domain_set.len);
                    eval_pool.values[accepted_offset + accepted_count] = it;
                    accepted_count += 1;
                }
                eval_pool.restore(scratch_snapshot);
                self.restore_context_pool(context_snap);
            }
            assert(accepted_offset + accepted_count <= eval_pool.value_count);
            return Value{ .set_v = .{
                .offset = accepted_offset,
                .len = accepted_count,
            } };
        }
        return try self.eval_set_filter_tuples(sf, 0, ctx, s0, eval_pool, state_pool);
    }

    fn eval_hereditary_power_set_filter(
        self: *const Evaluator,
        filter: *ast.SetFilter,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        const pattern = set_patterns.hereditary_power_set_filter(filter) orelse
            return null;

        const inner_domain = try self.eval_set_materialized(
            pattern.base,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (inner_domain != .set_v) return null;
        const source = inner_domain.set_v;
        const accepted_offset = eval_pool.value_count;
        _ = try eval_pool.alloc_values(source.len);
        const scratch_snapshot = eval_pool.snapshot();
        const context_mark = self.context_snapshot();
        var accepted_count: u32 = 0;
        for (0..source.len) |i| {
            const candidate = eval_pool.values[source.offset + i];
            const predicate_ctx = try self.extend_context(
                ctx,
                pattern.element_name,
                candidate,
            );
            const accepted = try self.eval_expr(
                pattern.predicate,
                predicate_ctx,
                s0,
                eval_pool,
                state_pool,
            );
            if (accepted.is_truthy()) {
                eval_pool.values[accepted_offset + accepted_count] = candidate;
                accepted_count += 1;
            }
            eval_pool.restore(scratch_snapshot);
            self.restore_context_pool(context_mark);
        }
        const accepted = Value{ .set_v = .{
            .offset = accepted_offset,
            .len = accepted_count,
        } };
        return Value{ .power_set_v = .{
            .set_offset = try eval_pool.push_value(accepted),
        } };
    }

    fn eval_function_set_filter(
        self: *const Evaluator,
        sf: *ast.SetFilter,
        bv: ast.BoundVar,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        const function_set = switch (bv.domain.*) {
            .set_of_functions => |function_set| function_set,
            else => return null,
        };
        var domain = try self.eval_expr(
            function_set.domain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        var codomain = try self.eval_expr(
            function_set.codomain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (!domain.is_set_like() or !codomain.is_set_like()) {
            return Error.TypeError;
        }
        domain = try self.materialize_set(
            domain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        codomain = try self.materialize_set(
            codomain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (domain != .set_v or codomain != .set_v) return Error.TypeError;

        if (try self.eval_pointwise_function_set_filter(
            sf,
            bv,
            domain,
            codomain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        )) |filtered| {
            return filtered;
        }

        const domain_count = domain.set_v.len;
        const codomain_count = codomain.set_v.len;
        var candidate_count: u64 = 1;
        for (0..domain_count) |_| {
            candidate_count *= codomain_count;
            if (candidate_count > 262_144) return null;
        }
        assert(candidate_count <= 262_144);

        var accepted_bits: [4096]u64 = undefined;
        const word_count: usize = @intCast((candidate_count + 63) / 64);
        @memset(accepted_bits[0..word_count], 0);
        const scratch_snapshot = eval_pool.snapshot();
        const context_snap = self.context_snapshot();
        const codomain_values = codomain.set_v.items(eval_pool);
        var accepted_count: u32 = 0;
        var combo: u64 = 0;
        while (combo < candidate_count) : (combo += 1) {
            const entries = try eval_pool.alloc_values(domain_count);
            var tmp = combo;
            var i: u32 = 0;
            while (i < domain_count) : (i += 1) {
                const value_index: usize = @intCast(tmp % codomain_count);
                tmp /= codomain_count;
                entries[i] = codomain_values[value_index];
            }
            const candidate = Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, entries.ptr),
                .len = domain_count,
            } };
            const new_ctx = try self.extend_context(ctx, bv.name, candidate);
            const pred = try self.eval_expr(
                sf.pred,
                new_ctx,
                s0,
                eval_pool,
                state_pool,
            );
            if (pred.is_truthy()) {
                const word: usize = @intCast(combo / 64);
                const bit: u6 = @intCast(combo % 64);
                accepted_bits[word] |= @as(u64, 1) << bit;
                accepted_count += 1;
            }
            eval_pool.restore(scratch_snapshot);
            self.restore_context_pool(context_snap);
        }

        try eval_pool.ensure_value_capacity(
            accepted_count +
                @as(u64, accepted_count) * domain_count,
        );
        const accepted = try eval_pool.alloc_values(accepted_count);
        var accepted_index: u32 = 0;
        combo = 0;
        while (combo < candidate_count) : (combo += 1) {
            const word: usize = @intCast(combo / 64);
            const bit: u6 = @intCast(combo % 64);
            if (accepted_bits[word] & (@as(u64, 1) << bit) == 0) continue;

            const entries = try eval_pool.alloc_values(domain_count);
            var tmp = combo;
            var i: u32 = 0;
            while (i < domain_count) : (i += 1) {
                const value_index: usize = @intCast(tmp % codomain_count);
                tmp /= codomain_count;
                entries[i] = codomain_values[value_index];
            }
            assert(accepted_index < accepted_count);
            accepted[accepted_index] = Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, entries.ptr),
                .len = domain_count,
            } };
            accepted_index += 1;
        }
        assert(accepted_index == accepted_count);
        return Value{ .set_v = .{
            .offset = value_offset(eval_pool, accepted.ptr),
            .len = accepted_count,
        } };
    }

    fn eval_pointwise_function_set_filter(
        self: *const Evaluator,
        sf: *ast.SetFilter,
        bv: ast.BoundVar,
        domain: Value,
        codomain: Value,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        assert(domain == .set_v);
        assert(codomain == .set_v);
        const quantifier = switch (sf.pred.*) {
            .quantifier => |quantifier| quantifier,
            else => return null,
        };
        if (quantifier.kind != .forall or quantifier.vars.len != 1) {
            return null;
        }
        const key_var = quantifier.vars[0];
        if (!is_pointwise_function_predicate(
            quantifier.body,
            bv.name,
            key_var.name,
        )) return null;

        const quantified_domain = try self.eval_set_materialized(
            key_var.domain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (quantified_domain != .set_v or
            !quantified_domain.set_v.eql(domain.set_v, eval_pool))
        {
            return null;
        }

        const domain_count = domain.set_v.len;
        const codomain_count = codomain.set_v.len;
        if (domain_count > 256) return null;
        const pair_count =
            @as(u64, domain_count) * codomain_count;
        if (pair_count > 262_144) return null;

        var allowed_bits: [4096]u64 = undefined;
        const word_count: usize = @intCast((pair_count + 63) / 64);
        @memset(allowed_bits[0..word_count], 0);
        var allowed_counts: [256]u32 = @splat(0);
        const domain_values = domain.set_v.items(eval_pool);
        const codomain_values = codomain.set_v.items(eval_pool);
        const scratch_snapshot = eval_pool.snapshot();
        const context_snap = self.context_snapshot();

        for (domain_values, 0..) |key, domain_index| {
            for (codomain_values, 0..) |candidate_value, value_index| {
                const entries = try eval_pool.alloc_values(domain_count);
                @memset(entries, candidate_value);
                const candidate = Value{ .function_v = .{
                    .domain = domain.set_v,
                    .offset = value_offset(eval_pool, entries.ptr),
                    .len = domain_count,
                } };
                var predicate_ctx = try self.extend_context(
                    ctx,
                    bv.name,
                    candidate,
                );
                predicate_ctx = try self.extend_context(
                    predicate_ctx,
                    key_var.name,
                    key,
                );
                const predicate = try self.eval_expr(
                    quantifier.body,
                    predicate_ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                if (predicate.is_truthy()) {
                    const pair_index =
                        domain_index * codomain_count + value_index;
                    const word: usize = @intCast(pair_index / 64);
                    const bit: u6 = @intCast(pair_index % 64);
                    allowed_bits[word] |= @as(u64, 1) << bit;
                    allowed_counts[domain_index] += 1;
                }
                eval_pool.restore(scratch_snapshot);
                self.restore_context_pool(context_snap);
            }
            if (allowed_counts[domain_index] == 0) {
                const empty = try eval_pool.alloc_values(0);
                return Value{ .set_v = .{
                    .offset = value_offset(eval_pool, empty.ptr),
                    .len = 0,
                } };
            }
        }

        var accepted_count: u64 = 1;
        for (allowed_counts[0..domain_count]) |count| {
            accepted_count *= count;
            if (accepted_count > 262_144) return null;
        }
        try eval_pool.ensure_value_capacity(
            accepted_count +
                accepted_count * domain_count,
        );
        const accepted = try eval_pool.alloc_values(
            @intCast(accepted_count),
        );
        var combo: u64 = 0;
        while (combo < accepted_count) : (combo += 1) {
            const entries = try eval_pool.alloc_values(domain_count);
            var ordinal = combo;
            for (0..domain_count) |domain_index| {
                const allowed_ordinal =
                    ordinal % allowed_counts[domain_index];
                ordinal /= allowed_counts[domain_index];
                var seen: u32 = 0;
                var value_index: u32 = 0;
                while (value_index < codomain_count) : (value_index += 1) {
                    const pair_index =
                        domain_index * codomain_count + value_index;
                    const word: usize = @intCast(pair_index / 64);
                    const bit: u6 = @intCast(pair_index % 64);
                    if (allowed_bits[word] &
                        (@as(u64, 1) << bit) == 0) continue;
                    if (seen == allowed_ordinal) break;
                    seen += 1;
                }
                assert(value_index < codomain_count);
                entries[domain_index] = codomain_values[value_index];
            }
            accepted[combo] = Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, entries.ptr),
                .len = domain_count,
            } };
        }
        return Value{ .set_v = .{
            .offset = value_offset(eval_pool, accepted.ptr),
            .len = @intCast(accepted_count),
        } };
    }

    fn eval_set_filter_tuples(
        self: *const Evaluator,
        sf: *ast.SetFilter,
        var_idx: usize,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (var_idx >= sf.vars.len) {
            const pred = try self.eval_expr(sf.pred, ctx, s0, eval_pool, state_pool);
            return if (pred.is_truthy()) Value{ .bool_v = true } else Value{ .bool_v = false };
        }
        const bv = sf.vars[var_idx];
        const domain = try self.eval_set_materialized(bv.domain, ctx, s0, eval_pool, state_pool);
        const domain_items = domain.set_v.items(eval_pool);
        const scratch = try self.materialize_scratch.acquire(domain_items.len);
        defer self.materialize_scratch.release();
        @memcpy(scratch.values[0..domain_items.len], domain_items);
        var tuple_count: usize = 0;
        for (scratch.values[0..domain_items.len]) |it| {
            const new_ctx = try self.extend_context(ctx, bv.name, it);
            const nested = try self.eval_set_filter_tuples(sf, var_idx + 1, new_ctx, s0, eval_pool, state_pool);
            if (var_idx + 1 < sf.vars.len) {
                if (nested != .set_v) return Error.TypeError;
                const nested_items = nested.set_v.items(eval_pool);
                var required_values: u64 = 0;
                for (nested_items) |tuple| {
                    if (tuple != .tuple_v) return Error.TypeError;
                    required_values = std.math.add(
                        u64,
                        required_values,
                        @as(u64, tuple.tuple_v.len) + 1,
                    ) catch return Error.OutOfMemory;
                }
                try eval_pool.ensure_value_capacity(required_values);
                for (nested.set_v.items(eval_pool)) |t| {
                    const tuple_items = t.tuple_v.items(eval_pool);
                    const extended = try eval_pool.alloc_values(
                        @intCast(tuple_items.len + 1),
                    );
                    extended[0] = it;
                    @memcpy(extended[1..], tuple_items);
                    try scratch.ensure_secondary_preserve(
                        self.materialize_scratch.arena,
                        tuple_count + 1,
                        tuple_count,
                    );
                    scratch.secondary_values[tuple_count] = Value{
                        .tuple_v = make_tuple(eval_pool, extended),
                    };
                    tuple_count += 1;
                }
            } else if (nested.is_truthy()) {
                const single = try eval_pool.alloc_values(1);
                single[0] = it;
                try scratch.ensure_secondary_preserve(
                    self.materialize_scratch.arena,
                    tuple_count + 1,
                    tuple_count,
                );
                scratch.secondary_values[tuple_count] = Value{
                    .tuple_v = make_tuple(eval_pool, single),
                };
                tuple_count += 1;
            }
        }
        const dest = try eval_pool.alloc_values(@intCast(tuple_count));
        @memcpy(dest, scratch.secondary_values[0..tuple_count]);
        return Value{ .set_v = try make_set(eval_pool, dest) };
    }

    fn eval_sorted_sequence_filter(
        self: *const Evaluator,
        sf: *ast.SetFilter,
        bv: ast.BoundVar,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        if (!sequence_patterns.is_sorted_sequence_predicate(
            sf.pred,
            bv.name,
        )) return null;
        const symbolic_domain = (try eval_symbolic_set(self, bv.domain, ctx, s0, eval_pool, state_pool)) orelse return null;

        const shape = extract_sequence_set_shape(
            eval_pool,
            symbolic_domain,
        ) orelse return null;
        const codomain_mat = try self.materialize_set(
            shape.codomain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (codomain_mat != .set_v) return null;
        const codomain_items = codomain_mat.set_v.items(eval_pool);
        const scratch_capacity = @max(
            @max(shape.length_count, codomain_items.len),
            @as(usize, shape.max_length),
        );
        const scratch = try self.materialize_scratch.acquire(scratch_capacity);
        defer self.materialize_scratch.release();
        const lengths = scratch.lengths[0..shape.length_count];
        const function_sets = symbolic_domain.union_v.set(eval_pool).set_v.items(eval_pool);
        assert(function_sets.len == lengths.len);
        for (function_sets, 0..) |set, index| {
            assert(set == .function_set_v);
            lengths[index] = sequence_domain_size(
                eval_pool,
                set.function_set_v.domain(eval_pool),
            ) orelse return null;
        }
        const values = scratch.values[0..codomain_items.len];
        @memcpy(values, codomain_items);
        sort_values(eval_pool, values) orelse return null;

        var generated_count: u64 = 0;
        var sequence_storage_count: u64 = 0;
        for (lengths) |len| {
            const count = try sorted_sequence_count(values.len, len);
            generated_count = std.math.add(
                u64,
                generated_count,
                count,
            ) catch return Error.OutOfMemory;
            const per_sequence_storage = std.math.mul(
                u64,
                2,
                len,
            ) catch return Error.OutOfMemory;
            sequence_storage_count = std.math.add(
                u64,
                sequence_storage_count,
                std.math.mul(
                    u64,
                    count,
                    per_sequence_storage,
                ) catch return Error.OutOfMemory,
            ) catch return Error.OutOfMemory;
        }
        if (generated_count > std.math.maxInt(u32)) return Error.OutOfMemory;
        const required_values = std.math.add(
            u64,
            generated_count,
            sequence_storage_count,
        ) catch return Error.OutOfMemory;
        try eval_pool.ensure_value_capacity(required_values);

        const generated = try eval_pool.alloc_values(@intCast(generated_count));
        var generated_index: usize = 0;
        for (lengths) |len| {
            const current = scratch.secondary_values[0..len];
            try generate_sorted_sequences(
                eval_pool,
                values,
                current,
                0,
                0,
                generated,
                &generated_index,
            );
        }
        assert(generated_index == generated.len);

        // Generation is lexicographic over nondecreasing value indices, so
        // each sequence is produced exactly once. Running make_set here would
        // perform a quadratic equality scan over an already-canonical set.
        return Value{ .set_v = .{
            .offset = value_offset(eval_pool, generated.ptr),
            .len = @intCast(generated.len),
        } };
    }

    fn eval_set_map(
        self: *const Evaluator,
        sm: *ast.SetMap,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        var domains: [32]Value = undefined;
        if (sm.vars.len > domains.len) {
            return self.fail(
                Error.NotImplemented,
                "set map",
                "more than 32 bound variables",
            );
        }
        var total: u64 = 1;
        for (sm.vars, 0..) |bv, i| {
            const mat = try self.eval_set_materialized(bv.domain, ctx, s0, eval_pool, state_pool);
            assert(mat == .set_v);
            domains[i] = mat;
            total *= mat.set_v.len;
            if (total > eval_pool.value_cap) return Error.OutOfMemory;
        }
        if (total > 4096) return self.fail(Error.NotImplemented, "set map", "more than 4096 results");
        var scratch: [4096]Value = undefined;
        const results = scratch[0..@intCast(total)];
        _ = try self.eval_set_map_vars(
            sm,
            0,
            domains[0..sm.vars.len],
            ctx,
            s0,
            eval_pool,
            state_pool,
            results,
            0,
        );
        const dest = try eval_pool.alloc_values(@intCast(total));
        @memcpy(dest, results);
        return Value{ .set_v = try make_set(eval_pool, dest) };
    }

    fn eval_set_map_vars(
        self: *const Evaluator,
        sm: *ast.SetMap,
        var_idx: usize,
        domains: []const Value,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
        dest: []Value,
        start: usize,
    ) Error!void {
        if (var_idx >= sm.vars.len) {
            dest[start] = try self.eval_expr(sm.value, ctx, s0, eval_pool, state_pool);
            return;
        }
        const bv = sm.vars[var_idx];
        const item_count = domains[var_idx].set_v.len;
        const context_snap = self.context_snapshot();
        var stride: usize = 1;
        var j: usize = var_idx + 1;
        while (j < domains.len) : (j += 1) stride *= domains[j].set_v.len;
        for (0..item_count) |i| {
            const it = domains[var_idx].set_v.items(eval_pool)[i];
            const new_ctx = try self.extend_context(ctx, bv.name, it);
            try self.eval_set_map_vars(sm, var_idx + 1, domains, new_ctx, s0, eval_pool, state_pool, dest, start + i * stride);
            self.restore_context_pool(context_snap);
        }
    }

    /// Evaluate an expression and return a materialized `set_v`, expanding
    /// symbolic sets such as ranges and record sets on demand.
    pub fn eval_set_materialized(
        self: *const Evaluator,
        expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const v = try self.eval_expr(expr, ctx, s0, eval_pool, state_pool);
        if (!v.is_set_like()) return Error.TypeError;
        return self.materialize_set(v, ctx, s0, eval_pool, state_pool);
    }

    /// Materialize a set-like value into an enumerated `set_v`.  Symbolic
    /// sets are expanded on demand; already-materialized sets pass through.
    pub fn materialize_set(
        self: *const Evaluator,
        set: Value,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        switch (set) {
            .set_v => return set,
            .power_set_v => |ps| {
                const base = try self.materialize_set(ps.set(eval_pool), ctx, s0, eval_pool, state_pool);
                return try eval_subset(eval_pool, base);
            },
            .seq_set_v => |ss| {
                const bounded = try make_seq_set_value(
                    eval_pool,
                    ss.element_set(eval_pool),
                    self.override_registry.ctx.max_seq_len,
                );
                return try self.materialize_set(bounded, ctx, s0, eval_pool, state_pool);
            },
            .range_v => |r| {
                if (r.lo > r.hi) {
                    const empty = try eval_pool.alloc_values(0);
                    return Value{ .set_v = try make_set(eval_pool, empty) };
                }
                const span = std.math.sub(i64, r.hi, r.lo) catch return Error.NotImplemented;
                const len_i64 = std.math.add(i64, span, 1) catch return Error.NotImplemented;
                if (len_i64 > std.math.maxInt(u32)) return Error.NotImplemented;
                const len: u32 = @intCast(len_i64);
                const dest = try eval_pool.alloc_values(@intCast(len));
                for (0..len) |i| {
                    dest[i] = Value{ .int_v = r.lo + @as(i64, @intCast(i)) };
                }
                return Value{ .set_v = try make_set(eval_pool, dest) };
            },
            .record_set_v => |rs| {
                const scratch = try self.materialize_scratch.acquire(rs.len);
                defer self.materialize_scratch.release();
                const domains = scratch.values[0..rs.len];
                const names = scratch.names[0..rs.len];
                var i: u32 = 0;
                while (i < rs.len) : (i += 1) {
                    const d = rs.field_domain(eval_pool, i);
                    const mat = try self.materialize_set(d, ctx, s0, eval_pool, state_pool);
                    if (mat != .set_v) return Error.TypeError;
                    domains[i] = mat;
                    names[i] = rs.field_name(eval_pool, i).slice(eval_pool);
                }
                var count: u64 = 1;
                for (domains) |d| {
                    count *= d.set_v.len;
                    if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
                }
                try eval_pool.ensure_value_capacity(count + count * rs.len * 2);
                const dest = try eval_pool.alloc_values(@intCast(count));
                var combo: u64 = 0;
                while (combo < count) : (combo += 1) {
                    const fields_dest = try eval_pool.alloc_values(@intCast(rs.len * 2));
                    var tmp = combo;
                    var fi: u32 = 0;
                    while (fi < rs.len) : (fi += 1) {
                        const items = domains[fi].set_v.items(eval_pool);
                        const vi: usize = @intCast(tmp % items.len);
                        tmp /= items.len;
                        const name = try eval_pool.push_string(names[fi]);
                        fields_dest[fi * 2] = Value{ .string_v = name };
                        fields_dest[fi * 2 + 1] = items[vi];
                    }
                    dest[combo] = Value{ .record_v = make_record(eval_pool, fields_dest) };
                }
                return Value{ .set_v = try make_set(eval_pool, dest) };
            },
            .tuple_set_v => |ts| {
                const ss = ts.sets(eval_pool);
                const scratch = try self.materialize_scratch.acquire(ss.len);
                defer self.materialize_scratch.release();
                const domains = scratch.values[0..ss.len];
                for (ss, 0..) |s, index| {
                    const mat = try self.materialize_set(s, ctx, s0, eval_pool, state_pool);
                    if (mat != .set_v) return Error.TypeError;
                    domains[index] = mat;
                }
                var count: u64 = 1;
                for (domains) |d| {
                    count *= d.set_v.len;
                    if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
                }
                try eval_pool.ensure_value_capacity(count + count * domains.len);
                const dest = try eval_pool.alloc_values(@intCast(count));
                var combo: u64 = 0;
                while (combo < count) : (combo += 1) {
                    const tuple_dest = try eval_pool.alloc_values(@intCast(domains.len));
                    var tmp = combo;
                    for (domains, 0..) |d, fi| {
                        const items = d.set_v.items(eval_pool);
                        const vi: usize = @intCast(tmp % items.len);
                        tmp /= items.len;
                        tuple_dest[fi] = items[vi];
                    }
                    dest[combo] = Value{ .tuple_v = make_tuple(eval_pool, tuple_dest) };
                }
                return Value{ .set_v = try make_set(eval_pool, dest) };
            },
            .function_set_v => |fs| {
                const domain = fs.domain(eval_pool);
                const codomain = fs.codomain(eval_pool);
                const dmat = try self.materialize_set(domain, ctx, s0, eval_pool, state_pool);
                const cmat = try self.materialize_set(codomain, ctx, s0, eval_pool, state_pool);
                if (dmat != .set_v or cmat != .set_v) return Error.TypeError;
                const n = dmat.set_v.len;
                const m = cmat.set_v.len;
                if (n == 0) {
                    const empty = try eval_pool.alloc_values(0);
                    const func = Value{ .function_v = .{
                        .domain = dmat.set_v,
                        .offset = value_offset(eval_pool, empty.ptr),
                        .len = 0,
                    } };
                    const dest = try eval_pool.alloc_values(1);
                    dest[0] = func;
                    return Value{ .set_v = try make_set(eval_pool, dest) };
                }
                var count: u64 = 1;
                for (0..n) |_| {
                    count *= m;
                    if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
                }
                try eval_pool.ensure_value_capacity(count + count * n);
                const values = cmat.set_v.items(eval_pool);
                const func_values = try eval_pool.alloc_values(@intCast(count));
                var combo: u64 = 0;
                while (combo < count) : (combo += 1) {
                    const entries = try eval_pool.alloc_values(n);
                    var tmp = combo;
                    var i: u32 = 0;
                    while (i < n) : (i += 1) {
                        const vi: usize = @intCast(tmp % m);
                        tmp /= m;
                        entries[i] = values[vi];
                    }
                    func_values[combo] = Value{ .function_v = .{
                        .domain = dmat.set_v,
                        .offset = value_offset(eval_pool, entries.ptr),
                        .len = n,
                    } };
                }
                return Value{ .set_v = try make_set(eval_pool, func_values) };
            },
            .union_v => |u| {
                const inner = u.set(eval_pool);
                const mat = try self.materialize_set(inner, ctx, s0, eval_pool, state_pool);
                if (mat != .set_v) return Error.TypeError;
                const sets = mat.set_v.items(eval_pool);
                const scratch = try self.materialize_scratch.acquire(sets.len);
                defer self.materialize_scratch.release();
                const materialized = scratch.values[0..sets.len];
                var total: u64 = 0;
                for (sets, 0..) |s, index| {
                    const smat = try self.materialize_set(s, ctx, s0, eval_pool, state_pool);
                    if (smat != .set_v) return Error.TypeError;
                    materialized[index] = smat;
                    total += smat.set_v.len;
                    if (total > std.math.maxInt(u32)) return Error.OutOfMemory;
                }
                const dest = try eval_pool.alloc_values(@intCast(total));
                var pos: u32 = 0;
                const disjoint = function_sets_have_distinct_domain_sizes(eval_pool, sets);
                for (materialized) |smat| {
                    const items = smat.set_v.items(eval_pool);
                    for (items) |it| {
                        if (disjoint) {
                            dest[pos] = it;
                            pos += 1;
                            continue;
                        }
                        var found = false;
                        var j: u32 = 0;
                        while (j < pos) : (j += 1) {
                            if (dest[j].eql(it, eval_pool)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            dest[pos] = it;
                            pos += 1;
                        }
                    }
                }
                return Value{ .set_v = try make_set(eval_pool, dest[0..pos]) };
            },
            .cup_v => |bs| {
                const l = try self.materialize_set(bs.left(eval_pool), ctx, s0, eval_pool, state_pool);
                const r = try self.materialize_set(bs.right(eval_pool), ctx, s0, eval_pool, state_pool);
                if (l != .set_v or r != .set_v) return Error.TypeError;
                const a = l.set_v.items(eval_pool);
                const b = r.set_v.items(eval_pool);
                const dest = try eval_pool.alloc_values(@intCast(a.len + b.len));
                @memcpy(dest[0..a.len], a);
                var count: u32 = @intCast(a.len);
                for (b) |bv| {
                    if (!l.set_v.contains(eval_pool, bv)) {
                        dest[count] = bv;
                        count += 1;
                    }
                }
                return Value{ .set_v = try make_set(eval_pool, dest[0..count]) };
            },
            .cap_v => |bs| {
                const l = try self.materialize_set(bs.left(eval_pool), ctx, s0, eval_pool, state_pool);
                const r = try self.materialize_set(bs.right(eval_pool), ctx, s0, eval_pool, state_pool);
                if (l != .set_v or r != .set_v) return Error.TypeError;
                const a = l.set_v.items(eval_pool);
                const b = r.set_v.items(eval_pool);
                const dest = try eval_pool.alloc_values(@intCast(@min(a.len, b.len)));
                var count: u32 = 0;
                for (a) |av| {
                    if (r.set_v.contains(eval_pool, av)) {
                        dest[count] = av;
                        count += 1;
                    }
                }
                return Value{ .set_v = try make_set(eval_pool, dest[0..count]) };
            },
            .diff_v => |bs| {
                const l = try self.materialize_set(bs.left(eval_pool), ctx, s0, eval_pool, state_pool);
                const r = try self.materialize_set(bs.right(eval_pool), ctx, s0, eval_pool, state_pool);
                if (l != .set_v or r != .set_v) return Error.TypeError;
                const a = l.set_v.items(eval_pool);
                const dest = try eval_pool.alloc_values(@intCast(a.len));
                var count: u32 = 0;
                for (a) |av| {
                    if (!r.set_v.contains(eval_pool, av)) {
                        dest[count] = av;
                        count += 1;
                    }
                }
                return Value{ .set_v = try make_set(eval_pool, dest[0..count]) };
            },
            else => return Error.TypeError,
        }
    }

    fn eval_record_set(
        self: *const Evaluator,
        rs: *ast.RecordSet,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (rs.fields.len == 0) {
            const empty = try eval_pool.alloc_values(0);
            return Value{ .set_v = try make_set(eval_pool, empty) };
        }
        const scratch = try self.materialize_scratch.acquire(rs.fields.len);
        defer self.materialize_scratch.release();
        const domains = scratch.values[0..rs.fields.len];
        const names = scratch.names[0..rs.fields.len];
        for (rs.fields, 0..) |f, index| {
            const d = try self.eval_set_materialized(f.domain, ctx, s0, eval_pool, state_pool);
            domains[index] = d;
            names[index] = f.name;
        }
        var count: u64 = 1;
        for (domains) |d| {
            count = std.math.mul(
                u64,
                count,
                d.set_v.len,
            ) catch return Error.OutOfMemory;
        }
        if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
        const field_storage = std.math.mul(
            u64,
            count,
            std.math.mul(
                u64,
                rs.fields.len,
                2,
            ) catch return Error.OutOfMemory,
        ) catch return Error.OutOfMemory;
        try eval_pool.ensure_value_capacity(
            std.math.add(u64, count, field_storage) catch
                return Error.OutOfMemory,
        );
        const dest = try eval_pool.alloc_values(@intCast(count));
        var combo: u64 = 0;
        while (combo < count) : (combo += 1) {
            const fields_dest = try eval_pool.alloc_values(@intCast(rs.fields.len * 2));
            var tmp = combo;
            var i: u32 = 0;
            while (i < rs.fields.len) : (i += 1) {
                const items = domains[i].set_v.items(eval_pool);
                const vi: usize = @intCast(tmp % items.len);
                tmp /= items.len;
                fields_dest[i * 2] = Value{
                    .string_v = try eval_pool.push_string(names[i]),
                };
                fields_dest[i * 2 + 1] = items[vi];
            }
            dest[combo] = Value{ .record_v = make_record(eval_pool, fields_dest) };
        }
        return Value{ .set_v = try make_set(eval_pool, dest) };
    }

    fn value_in_set_expression(
        self: *const Evaluator,
        candidate: Value,
        expression: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
        depth: u8,
    ) Error!bool {
        if (depth == 64) return Error.NotImplemented;
        switch (expression.*) {
            .ident => |name| {
                const aliased = self.resolve_alias(name);
                const builtin_set = std.mem.eql(u8, aliased, "Nat") or
                    std.mem.eql(u8, aliased, "Int") or
                    std.mem.eql(u8, aliased, "BOOLEAN") or
                    std.mem.eql(u8, aliased, "STRING");
                if (std.mem.eql(u8, aliased, "STRING")) {
                    return candidate == .string_v;
                }
                if (!builtin_set and
                    self.find_constant(name) == null and
                    self.find_constant(aliased) == null)
                {
                    if (self.find_definition(aliased)) |definition| {
                        if (definition.params.len == 0) {
                            return self.value_in_set_expression(
                                candidate,
                                definition.body,
                                ctx,
                                s0,
                                eval_pool,
                                state_pool,
                                depth + 1,
                            );
                        }
                    }
                }
            },
            .apply => |application| {
                if (application.func.* == .ident and
                    application.args.len == 0)
                {
                    if (self.find_definition(application.func.*.ident)) |definition| {
                        if (definition.params.len == 0) {
                            return self.value_in_set_expression(
                                candidate,
                                definition.body,
                                ctx,
                                s0,
                                eval_pool,
                                state_pool,
                                depth + 1,
                            );
                        }
                    }
                }
            },
            .set_enum => |items| {
                for (items) |item_expression| {
                    const item = try self.eval_expr(
                        item_expression,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                    if (try self.equal_values(
                        candidate,
                        item,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    )) return true;
                }
                return false;
            },
            .set_binary => |binary_set| {
                const in_left = try self.value_in_set_expression(
                    candidate,
                    binary_set.left,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                    depth + 1,
                );
                return switch (binary_set.op) {
                    .union_op => in_left or try self.value_in_set_expression(
                        candidate,
                        binary_set.right,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                        depth + 1,
                    ),
                    .intersection_op => in_left and try self.value_in_set_expression(
                        candidate,
                        binary_set.right,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                        depth + 1,
                    ),
                    .difference_op => in_left and !try self.value_in_set_expression(
                        candidate,
                        binary_set.right,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                        depth + 1,
                    ),
                    .cartesian_op => blk: {
                        const materialized = try self.eval_expr(
                            expression,
                            ctx,
                            s0,
                            eval_pool,
                            state_pool,
                        );
                        if (!materialized.is_set_like()) return Error.TypeError;
                        break :blk materialized.member(eval_pool, candidate);
                    },
                };
            },
            .unary => |unary| {
                if (unary.op == .subset) {
                    if (!candidate.is_set_like()) return false;
                    const concrete = try self.materialize_set(
                        candidate,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                    if (concrete != .set_v) return Error.TypeError;
                    for (concrete.set_v.items(eval_pool)) |item| {
                        if (!try self.value_in_set_expression(
                            item,
                            unary.operand,
                            ctx,
                            s0,
                            eval_pool,
                            state_pool,
                            depth + 1,
                        )) return false;
                    }
                    return true;
                }
            },
            .record_set => |record_set| {
                if (candidate != .record_v or
                    candidate.record_v.len != record_set.fields.len)
                {
                    return false;
                }
                for (record_set.fields) |field| {
                    const field_value = candidate.record_v.lookup(
                        eval_pool,
                        field.name,
                    ) orelse return false;
                    if (!try self.value_in_set_expression(
                        field_value,
                        field.domain,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                        depth + 1,
                    )) return false;
                }
                return true;
            },
            .set_of_functions => |function_set| {
                var domain = try self.eval_expr(
                    function_set.domain,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                domain = try self.materialize_set(
                    domain,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                if (domain != .set_v) return false;
                const domain_items = domain.set_v.items(eval_pool);
                switch (candidate) {
                    .function_v => |function| {
                        if (!function.domain.eql(domain.set_v, eval_pool)) {
                            return false;
                        }
                    },
                    .tuple_v => |tuple| {
                        if (tuple.len != domain_items.len) return false;
                    },
                    .record_v => |record| {
                        if (record.len != domain_items.len) return false;
                    },
                    else => return false,
                }
                for (domain_items) |key| {
                    const entry = switch (candidate) {
                        .function_v => |function| blk: {
                            break :blk function.apply(
                                eval_pool,
                                key,
                            ) orelse return false;
                        },
                        .tuple_v => |tuple| blk: {
                            if (key != .int_v or
                                key.int_v < 1 or
                                key.int_v > tuple.len)
                            {
                                return false;
                            }
                            break :blk tuple.items(eval_pool)[
                                @intCast(key.int_v - 1)
                            ];
                        },
                        .record_v => |record| blk: {
                            if (key != .string_v) {
                                return false;
                            }
                            break :blk record.lookup(
                                eval_pool,
                                key.string_v.slice(eval_pool),
                            ) orelse return false;
                        },
                        else => return false,
                    };
                    if (!try self.value_in_set_expression(
                        entry,
                        function_set.codomain,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                        depth + 1,
                    )) return false;
                }
                return true;
            },
            else => {},
        }

        if (try eval_symbolic_set(
            self,
            expression,
            ctx,
            s0,
            eval_pool,
            state_pool,
        )) |set| {
            assert(set.is_set_like());
            return set.member(eval_pool, candidate);
        }
        const set = try self.eval_expr(
            expression,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (!set.is_set_like()) {
            return self.fail(
                Error.TypeError,
                "\\in: rhs not a set",
                @tagName(set),
            );
        }
        return set.member(eval_pool, candidate);
    }

    fn is_function_in_set(_: Evaluator, func: Function, domain: Set, codomain: Set, eval_pool: *ValuePool) Error!bool {
        if (!func.domain.eql(domain, eval_pool)) return false;
        const keys = func.domain.items(eval_pool);
        for (keys) |k| {
            const v = func.apply(eval_pool, k) orelse return false;
            if (!codomain.contains(eval_pool, v)) return false;
        }
        return true;
    }

    fn eval_set_of_functions(
        self: *const Evaluator,
        sf: *ast.SetOfFunctions,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        var domain = try self.eval_expr(sf.domain, ctx, s0, eval_pool, state_pool);
        var codomain = try self.eval_expr(sf.codomain, ctx, s0, eval_pool, state_pool);
        if (!domain.is_set_like() or !codomain.is_set_like()) return Error.TypeError;
        domain = try self.materialize_set(domain, ctx, s0, eval_pool, state_pool);
        codomain = try self.materialize_set(codomain, ctx, s0, eval_pool, state_pool);
        if (domain != .set_v or codomain != .set_v) return Error.TypeError;
        const n = domain.set_v.len;
        const m = codomain.set_v.len;
        if (n == 0) {
            const empty = try eval_pool.alloc_values(0);
            const func = Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, empty.ptr),
                .len = 0,
            } };
            const dest = try eval_pool.alloc_values(1);
            dest[0] = func;
            return Value{ .set_v = try make_set(eval_pool, dest) };
        }
        var count: u64 = 1;
        for (0..n) |_| {
            count *= m;
            if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
        }
        try eval_pool.ensure_value_capacity(count + count * n);
        const values = codomain.set_v.items(eval_pool);
        const func_values = try eval_pool.alloc_values(@intCast(count));
        var combo: u64 = 0;
        while (combo < count) : (combo += 1) {
            const entries = try eval_pool.alloc_values(n);
            var tmp = combo;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const vi: usize = @intCast(tmp % m);
                tmp /= m;
                entries[i] = values[vi];
            }
            func_values[combo] = Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, entries.ptr),
                .len = n,
            } };
        }
        return Value{ .set_v = try make_set(eval_pool, func_values) };
    }

    fn eval_set_binary(
        self: *const Evaluator,
        sb: *ast.SetBinary,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        var left = try self.eval_expr(sb.left, ctx, s0, eval_pool, state_pool);
        var right = try self.eval_expr(sb.right, ctx, s0, eval_pool, state_pool);
        if (!left.is_set_like() or !right.is_set_like()) return Error.TypeError;
        left = try self.materialize_set(left, ctx, s0, eval_pool, state_pool);
        right = try self.materialize_set(right, ctx, s0, eval_pool, state_pool);
        if (left != .set_v or right != .set_v) return Error.TypeError;
        const a = left.set_v.items(eval_pool);
        const b = right.set_v.items(eval_pool);
        return switch (sb.op) {
            .cartesian_op => {
                const product = try self.cartesian_product(eval_pool, &[_]Value{ left, right });
                return Value{ .set_v = try make_set(eval_pool, product) };
            },
            .union_op => {
                const dest = try eval_pool.alloc_values(@intCast(a.len + b.len));
                @memcpy(dest[0..a.len], a);
                var count: u32 = @intCast(a.len);
                for (b) |bv| {
                    if (!left.set_v.contains(eval_pool, bv)) {
                        dest[count] = bv;
                        count += 1;
                    }
                }
                return Value{ .set_v = try make_set(eval_pool, dest[0..count]) };
            },
            .intersection_op => {
                const dest = try eval_pool.alloc_values(@intCast(@min(a.len, b.len)));
                var count: u32 = 0;
                for (a) |av| {
                    if (right.set_v.contains(eval_pool, av)) {
                        dest[count] = av;
                        count += 1;
                    }
                }
                return Value{ .set_v = try make_set(eval_pool, dest[0..count]) };
            },
            .difference_op => {
                const dest = try eval_pool.alloc_values(@intCast(a.len));
                var count: u32 = 0;
                for (a) |av| {
                    if (!right.set_v.contains(eval_pool, av)) {
                        dest[count] = av;
                        count += 1;
                    }
                }
                return Value{ .set_v = try make_set(eval_pool, dest[0..count]) };
            },
        };
    }

    fn eval_function_literal(
        self: *const Evaluator,
        fl: *ast.FunctionLiteral,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (fl.vars.len == 0) return Error.TypeError;
        if (try self.eval_sequence_field_projection(
            fl,
            ctx,
            s0,
            eval_pool,
            state_pool,
        )) |projection| {
            return projection;
        }
        if (fl.vars.len == 1) {
            const domain = try self.eval_set_materialized(fl.vars[0].domain, ctx, s0, eval_pool, state_pool);
            const item_count = domain.set_v.len;
            if (item_count > 4096) return self.fail(Error.NotImplemented, "function literal", "domain larger than 4096");
            var scratch: [4096]Value = undefined;
            const context_snap = self.context_snapshot();
            for (0..item_count) |i| {
                const it = domain.set_v.items(eval_pool)[i];
                const new_ctx = try self.extend_context(ctx, fl.vars[0].name, it);
                scratch[i] = try self.eval_expr(fl.body, new_ctx, s0, eval_pool, state_pool);
                self.restore_context_pool(context_snap);
            }
            const dest = try eval_pool.alloc_values(item_count);
            @memcpy(dest, scratch[0..item_count]);
            return Value{ .function_v = .{
                .domain = domain.set_v,
                .offset = value_offset(eval_pool, dest.ptr),
                .len = item_count,
            } };
        }
        var domains: [32]Value = undefined;
        if (fl.vars.len > domains.len) {
            return self.fail(
                Error.NotImplemented,
                "function literal",
                "more than 32 bound variables",
            );
        }
        for (fl.vars, 0..) |v, i| {
            const d = try self.eval_set_materialized(v.domain, ctx, s0, eval_pool, state_pool);
            assert(d == .set_v);
            domains[i] = d;
        }
        const product = try self.cartesian_product(eval_pool, domains[0..fl.vars.len]);
        const product_set = try make_set(eval_pool, product);
        if (product_set.len > 4096) return self.fail(Error.NotImplemented, "function literal", "product domain larger than 4096");
        var scratch: [4096]Value = undefined;
        const context_snap = self.context_snapshot();
        for (0..product_set.len) |i| {
            const tuple = product_set.items(eval_pool)[i];
            var new_ctx = ctx;
            const items = tuple.tuple_v.items(eval_pool);
            for (fl.vars, 0..) |v, j| {
                new_ctx = try self.extend_context(new_ctx, v.name, items[j]);
            }
            scratch[i] = try self.eval_expr(fl.body, new_ctx, s0, eval_pool, state_pool);
            self.restore_context_pool(context_snap);
        }
        const dest = try eval_pool.alloc_values(product_set.len);
        @memcpy(dest, scratch[0..product_set.len]);
        return Value{ .function_v = .{
            .domain = product_set,
            .offset = value_offset(eval_pool, dest.ptr),
            .len = product_set.len,
        } };
    }

    fn eval_sequence_field_projection(
        self: *const Evaluator,
        fl: *ast.FunctionLiteral,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        if (fl.vars.len != 1 or fl.body.* != .field) return null;
        const bound_var = fl.vars[0];
        const field = fl.body.*.field;
        if (field.expr.* != .apply) return null;
        const item_access = field.expr.*.apply;
        if (item_access.func.* != .ident or
            item_access.args.len != 1 or
            item_access.args[0].* != .ident or
            !name_eql(item_access.args[0].*.ident, bound_var.name))
        {
            return null;
        }
        const source_name = item_access.func.*.ident;
        if (bound_var.domain.* != .binary or
            bound_var.domain.*.binary.op != .range)
        {
            return null;
        }
        const range = bound_var.domain.*.binary;
        if (range.left.* != .int_literal or
            range.left.*.int_literal != 1 or
            range.right.* != .apply)
        {
            return null;
        }
        const upper = range.right.*.apply;
        if (upper.func.* != .ident or
            !name_eql(upper.func.*.ident, "Len") or
            upper.args.len != 1 or
            upper.args[0].* != .ident or
            !name_eql(upper.args[0].*.ident, source_name))
        {
            return null;
        }

        const source = try self.eval_expr(
            item_access.func,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        const len: u32 = switch (source) {
            .tuple_v => |tuple| tuple.len,
            .function_v => |function| function.len,
            else => return null,
        };
        try eval_pool.ensure_value_capacity(
            @as(u64, len) * 2,
        );
        const domain_values = try eval_pool.alloc_values(len);
        const result_values = try eval_pool.alloc_values(len);
        for (0..len) |i| {
            domain_values[i] = Value{
                .int_v = @as(i64, @intCast(i)) + 1,
            };
            const item = switch (source) {
                .tuple_v => |tuple| tuple.items(eval_pool)[i],
                .function_v => |function| function.apply(
                    eval_pool,
                    domain_values[i],
                ) orelse return self.fail(
                    Error.IndexOutOfBounds,
                    "sequence field projection",
                    source_name,
                ),
                else => unreachable,
            };
            if (item != .record_v) return null;
            result_values[i] = item.record_v.lookup(
                eval_pool,
                field.name,
            ) orelse return self.fail(
                Error.UndefinedSymbol,
                "sequence field projection",
                field.name,
            );
        }
        return Value{ .function_v = .{
            .domain = .{
                .offset = value_offset(eval_pool, domain_values.ptr),
                .len = len,
            },
            .offset = value_offset(eval_pool, result_values.ptr),
            .len = len,
        } };
    }

    fn cartesian_product(self: *const Evaluator, eval_pool: *ValuePool, sets: []const Value) error{ OutOfMemory, TypeError }![]Value {
        _ = self;
        if (sets.len == 0) {
            const empty = try eval_pool.alloc_values(0);
            const one = try eval_pool.alloc_values(1);
            one[0] = Value{ .tuple_v = make_tuple(eval_pool, empty) };
            return one;
        }
        // If the first set's elements are tuples (from nested \X),
        // flatten them. Compute the effective tuple length.
        var first_elem_len: u32 = 1;
        if (sets[0].set_v.len > 0) {
            const first_items = sets[0].set_v.items(eval_pool);
            if (first_items[0] == .tuple_v) {
                first_elem_len = first_items[0].tuple_v.len;
            }
        }
        const flat_len: u32 = first_elem_len + @as(u32, @intCast(sets.len - 1));
        var count: u64 = 1;
        for (sets) |s| {
            if (s != .set_v) return error.TypeError;
            count = std.math.mul(
                u64,
                count,
                s.set_v.len,
            ) catch return error.OutOfMemory;
        }
        if (count > std.math.maxInt(u32)) return error.OutOfMemory;
        const tuple_storage = std.math.mul(
            u64,
            count,
            flat_len,
        ) catch return error.OutOfMemory;
        try eval_pool.ensure_value_capacity(
            std.math.add(u64, count, tuple_storage) catch
                return error.OutOfMemory,
        );
        const dest = try eval_pool.alloc_values(@intCast(count));
        var combo: u64 = 0;
        while (combo < count) : (combo += 1) {
            const tuple_values = try eval_pool.alloc_values(flat_len);
            var tmp = combo;
            var pos: u32 = 0;
            var i: u32 = 0;
            while (i < sets.len) : (i += 1) {
                const items = sets[i].set_v.items(eval_pool);
                const vi: usize = @intCast(tmp % items.len);
                tmp /= items.len;
                if (i == 0 and first_elem_len > 1 and items[vi] == .tuple_v) {
                    // Flatten the first element's inner tuple.
                    const inner = items[vi].tuple_v.items(eval_pool);
                    for (inner) |it| {
                        tuple_values[pos] = it;
                        pos += 1;
                    }
                } else {
                    tuple_values[pos] = items[vi];
                    pos += 1;
                }
            }
            dest[combo] = Value{ .tuple_v = make_tuple(eval_pool, tuple_values) };
        }
        return dest;
    }

    fn eval_apply(
        self: *const Evaluator,
        ap: *ast.Apply,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (ap.func.* == .primed) {
            const name = self.resolve_alias(ap.func.*.primed);
            if (self.find_definition(name)) |def| {
                if (def.params.len != ap.args.len) {
                    return self.fail(Error.TypeError, "primed apply arity", name);
                }
                var new_ctx = ctx.operator_frame();
                for (def.params, ap.args) |param, arg| {
                    const arg_value = try self.eval_expr(arg, ctx, s0, eval_pool, state_pool);
                    new_ctx = try self.extend_context(new_ctx, param, arg_value);
                }
                if (self.next_state) |next| {
                    return try self.eval_expr(
                        def.body,
                        new_ctx,
                        next,
                        eval_pool,
                        state_pool,
                    );
                }

                const current = s0 orelse
                    return self.fail(
                        Error.TypeError,
                        "primed apply without current state",
                        name,
                    );
                return try self.eval_primed_definition(
                    def,
                    new_ctx,
                    current,
                    eval_pool,
                    state_pool,
                );
            }
        }
        if (s0) |state_v| {
            var root_name: []const u8 = "";
            var groups: [8]ApplicationGroup = undefined;
            var group_count: u8 = 0;
            if (collect_application_groups(
                ap,
                &root_name,
                &groups,
                &group_count,
            ) and !ctx.has_local_binding(root_name)) {
                if (self.find_variable(root_name)) |variable_index| {
                    assert(variable_index < state_v.values.len);
                    var current = state_v.values[variable_index];
                    const current_pool = state_v.value_pool(
                        variable_index,
                        state_pool,
                    );
                    for (groups[0..group_count]) |group| {
                        if (group.args.len > 8) {
                            return self.fail(
                                Error.NotImplemented,
                                "state application",
                                "more than 8 grouped arguments",
                            );
                        }
                        var arguments: [8]Value = undefined;
                        for (group.args, 0..) |arg, i| {
                            arguments[i] = try self.eval_expr(
                                arg,
                                ctx,
                                s0,
                                eval_pool,
                                state_pool,
                            );
                        }
                        const key = if (group.args.len == 1)
                            arguments[0]
                        else blk: {
                            const tuple_values = try eval_pool.alloc_values(
                                @intCast(group.args.len),
                            );
                            @memcpy(
                                tuple_values,
                                arguments[0..group.args.len],
                            );
                            break :blk Value{ .tuple_v = make_tuple(
                                eval_pool,
                                tuple_values,
                            ) };
                        };
                        current = try apply_cross_pool(
                            self,
                            current,
                            current_pool,
                            key,
                            eval_pool,
                        );
                    }
                    return try current.clone(current_pool, eval_pool);
                }
            }
        }
        if (ap.func.* == .ident) {
            const name = self.resolve_alias(ap.func.*.ident);
            if (self.is_module_operator(name, "IOUtils", "atoi")) {
                var argument_storage: [1]Value = undefined;
                if (ap.args.len != argument_storage.len) {
                    return self.fail(Error.TypeError, "atoi", "arity");
                }
                argument_storage[0] = try self.eval_expr(
                    ap.args[0],
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                return try overrides.atoi(
                    self.override_registry.ctx,
                    eval_pool,
                    &argument_storage,
                );
            }
            if (self.is_module_operator(name, "Functions", "FoldFunction") and
                ap.args.len == 3)
            {
                return try self.eval_sequence_fold(
                    ap.args[0],
                    ap.args[1],
                    ap.args[2],
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
            }
            // For set operations that require materialized sets, materialize
            // the arguments first.
            if (std.mem.eql(u8, name, "Cardinality") and ap.args.len == 1) {
                const arg_val = try self.eval_expr(ap.args[0], ctx, s0, eval_pool, state_pool);
                const mat = try self.materialize_set(arg_val, ctx, s0, eval_pool, state_pool);
                if (mat == .set_v) return Value{ .int_v = @intCast(mat.set_v.len) };
                if (mat == .range_v) return Value{ .int_v = @max(mat.range_v.hi - mat.range_v.lo + 1, 0) };
                return self.fail(Error.TypeError, "Cardinality", @tagName(mat));
            }
            if (std.mem.eql(u8, name, "Seq") and ap.args.len == 1) {
                const element_set = try self.eval_expr(ap.args[0], ctx, s0, eval_pool, state_pool);
                if (!element_set.is_set_like()) {
                    return self.fail(Error.TypeError, "Seq", "argument is not a set");
                }
                return try make_sequence_set_value(eval_pool, element_set);
            }
            if (std.mem.eql(u8, name, "SelectSeq")) {
                return try self.eval_select_seq(ap, ctx, s0, eval_pool, state_pool);
            }
            if (self.is_module_operator(name, "Functions", "FoldFunctionOnSet") and
                ap.args.len == 4)
            {
                return try self.eval_fold_function_on_set(ap, ctx, s0, eval_pool, state_pool);
            }
            if (try self.eval_local_identifier(
                ctx,
                name,
                s0,
                eval_pool,
                state_pool,
            )) |local_function| {
                var argument_storage: [64]Value = undefined;
                const values = try self.eval_application_arguments(
                    ap.args,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                    &argument_storage,
                );
                return self.apply_values(
                    local_function,
                    values,
                    eval_pool,
                    state_pool,
                    s0,
                ) catch |err| {
                    if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                        std.debug.print(
                            "local application failed: {s} value={s} args={d}: {any}\n",
                            .{ name, @tagName(local_function), values.len, err },
                        );
                    }
                    return err;
                };
            }
            if (std.mem.eql(u8, name, "TLCGet")) {
                var argument_storage: [64]Value = undefined;
                const values = try self.eval_application_arguments(
                    ap.args,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                    &argument_storage,
                );
                const level: u32 = if (s0) |state_v|
                    state_v.level + 1
                else
                    0;
                return try overrides.tlc_get_at_level(
                    self.override_registry.ctx,
                    eval_pool,
                    values,
                    level,
                );
            }
            if (self.override_registry.find(name)) |func| {
                var argument_storage: [64]Value = undefined;
                const values = try self.eval_application_arguments(
                    ap.args,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                    &argument_storage,
                );
                return func(self.override_registry.ctx, eval_pool, values) catch |err| blk: {
                    if (err == Error.NotImplemented) {
                        var materialized_storage: [64]Value = undefined;
                        const mat_values = materialized_storage[0..values.len];
                        for (values, 0..) |v2, i| {
                            mat_values[i] = if (v2.is_set_like())
                                try self.materialize_set(v2, ctx, s0, eval_pool, state_pool)
                            else
                                v2;
                        }
                        break :blk func(self.override_registry.ctx, eval_pool, mat_values) catch |err2| {
                            if (err2 == Error.TypeError) return self.fail(Error.TypeError, "apply override", name);
                            return err2;
                        };
                    }
                    if (err == Error.TypeError) return self.fail(Error.TypeError, "apply override", name);
                    return err;
                };
            }
            if (self.override_registry.find_generated(
                name,
                ap.args.len,
            )) |func| {
                var argument_storage: [64]Value = undefined;
                const values = try self.eval_application_arguments(
                    ap.args,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                    &argument_storage,
                );
                return self.call_generated(
                    func,
                    values,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                    true,
                ) catch |err| {
                    if (err == Error.TypeError) {
                        return self.fail(
                            Error.TypeError,
                            "apply generated override",
                            name,
                        );
                    }
                    return err;
                };
            }
            if (self.find_constant(name)) |constant| {
                switch (constant) {
                    .function_v, .lambda_v => {
                        var argument_storage: [64]Value = undefined;
                        const values = try self.eval_application_arguments(
                            ap.args,
                            ctx,
                            s0,
                            eval_pool,
                            state_pool,
                            &argument_storage,
                        );
                        return try self.apply_values(
                            constant,
                            values,
                            eval_pool,
                            state_pool,
                            s0,
                        );
                    },
                    else => {
                        // A config replacement such as `Op <- FALSE` replaces
                        // the complete operator body. Its formal arguments are
                        // therefore intentionally not evaluated.
                        return try constant.clone(state_pool, eval_pool);
                    },
                }
            }
            if (self.find_definition_index(name)) |definition_index| {
                const def = self.module.definitions[definition_index];
                var argument_storage: [64]Value = undefined;
                const values = try self.eval_application_arguments(
                    ap.args,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                    &argument_storage,
                );
                const memoize_recursive = self.definition_is_recursive(def);
                const persistent_cache = def.params.len > 0 and
                    !def.is_function and
                    !memoize_recursive and
                    self.persistent_call_safe[definition_index];
                if (persistent_cache) {
                    if (try self.cached_persistent_call(
                        name,
                        values,
                        eval_pool,
                    )) |cached| return cached;
                }
                if (def.is_function) {
                    const params = if (def.function_vars.len > 0)
                        def.function_vars
                    else
                        &[_][]const u8{def.function_var};
                    if (params.len != values.len) {
                        return self.fail(
                            Error.TypeError,
                            "recursive function apply arity",
                            name,
                        );
                    }
                    if (memoize_recursive) {
                        if (try self.cached_state_call(
                            name,
                            values,
                            s0,
                            eval_pool,
                        )) |cached| return cached;
                    }
                    var function_ctx = ctx.operator_frame();
                    for (params, values) |param, argument| {
                        function_ctx = try self.extend_context(
                            function_ctx,
                            param,
                            argument,
                        );
                    }
                    const result = try self.eval_expr(
                        def.body,
                        function_ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                    if (memoize_recursive) {
                        try self.memoize_state_call(
                            name,
                            values,
                            s0,
                            result,
                            eval_pool,
                        );
                    }
                    return result;
                }
                if (def.params.len == 0) {
                    const func = try self.eval_expr(
                        def.body,
                        ctx.operator_frame(),
                        s0,
                        eval_pool,
                        state_pool,
                    );
                    return self.apply_values(
                        func,
                        values,
                        eval_pool,
                        state_pool,
                        s0,
                    ) catch |err| {
                        std.debug.print(
                            "zero-arity definition value application failed: {s} value={s} args={d}: {any}\n",
                            .{ name, @tagName(func), values.len, err },
                        );
                        return err;
                    };
                }
                if (def.params.len != ap.args.len) {
                    std.debug.print(
                        "definition apply arity: {s} expected={d} actual={d}\n",
                        .{ name, def.params.len, ap.args.len },
                    );
                    return self.fail(
                        Error.TypeError,
                        "definition apply arity",
                        name,
                    );
                }
                if (memoize_recursive) {
                    if (try self.cached_state_call(
                        name,
                        values,
                        s0,
                        eval_pool,
                    )) |cached| return cached;
                }
                var new_ctx = ctx.operator_frame();
                for (def.params, 0..) |p, i| {
                    new_ctx = try self.extend_context(new_ctx, p, values[i]);
                }
                const result = try self.eval_expr(
                    def.body,
                    new_ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                if (memoize_recursive) {
                    try self.memoize_state_call(
                        name,
                        values,
                        s0,
                        result,
                        eval_pool,
                    );
                }
                if (persistent_cache and
                    persistent_call_result_worth_caching(result))
                {
                    self.memoize_persistent_call(
                        name,
                        values,
                        result,
                        eval_pool,
                    );
                }
                return result;
            }
        }
        const func = try self.eval_expr(ap.func, ctx, s0, eval_pool, state_pool);
        var argument_storage: [64]Value = undefined;
        const values = try self.eval_application_arguments(
            ap.args,
            ctx,
            s0,
            eval_pool,
            state_pool,
            &argument_storage,
        );
        return self.apply_values(func, values, eval_pool, state_pool, s0) catch |err| {
            if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                std.debug.print(
                    "value application failed: func-expr={s} func-value={s} args={d}",
                    .{ @tagName(ap.func.*), @tagName(func), values.len },
                );
                if (ap.func.* == .ident) {
                    std.debug.print(" ident={s}", .{ap.func.ident});
                }
                std.debug.print(" error={any}\n", .{err});
            }
            return err;
        };
    }

    fn eval_application_arguments(
        self: *const Evaluator,
        arguments: []const *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
        storage: *[64]Value,
    ) Error![]const Value {
        if (arguments.len > storage.len) {
            return self.fail(
                Error.NotImplemented,
                "operator application",
                "more than 64 arguments",
            );
        }
        for (arguments, 0..) |argument, index| {
            storage[index] = try self.eval_expr(
                argument,
                ctx,
                s0,
                eval_pool,
                state_pool,
            );
        }
        return storage[0..arguments.len];
    }

    fn eval_primed_definition(
        self: *const Evaluator,
        def: ast.Definition,
        ctx: Context,
        current: *StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const next_values = try eval_pool.alloc_values(
            @intCast(self.module.variables.len),
        );
        for (next_values, current.values, 0..) |
            *next_value,
            current_value,
            variable_index,
        | {
            next_value.* = if (ctx.lookup_state(
                @intCast(variable_index),
            )) |assigned| blk: {
                const source_pool = assigned.value_pool orelse eval_pool;
                break :blk try assigned.value.clone(source_pool, eval_pool);
            } else try current_value.clone(
                current.value_pool(
                    @intCast(variable_index),
                    state_pool,
                ),
                eval_pool,
            );
        }
        var partial_next = StateStore.State{
            .level = current.level + 1,
            .pred = current.pred,
            .changed_mask = 0,
            .borrowed_pool = null,
            .values = next_values,
        };

        var constant_scratch: [256]Constant = undefined;
        if (self.constants.len > constant_scratch.len) {
            return self.fail(
                Error.NotImplemented,
                "primed definition constants",
                "more than 256 constants",
            );
        }
        for (self.constants, 0..) |constant, index| {
            constant_scratch[index] = .{
                .name = constant.name,
                .value = try constant.value.clone(
                    state_pool,
                    eval_pool,
                ),
            };
        }
        var primed_evaluator = self.*;
        primed_evaluator.constants =
            constant_scratch[0..self.constants.len];
        primed_evaluator.next_state = &partial_next;
        return primed_evaluator.eval_expr(
            def.body,
            ctx,
            &partial_next,
            eval_pool,
            eval_pool,
        );
    }

    fn call_generated(
        self: *const Evaluator,
        function: generated_runtime.OperatorFn,
        args: []const Value,
        evaluator_context: Context,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
        uses_primed: bool,
    ) Error!Value {
        assert(self.module.variables.len <= 64);
        // A syntactically unprimed expression can force an operator-valued
        // argument which closes over a primed state reference.
        const skip_partial_values = current_state != null and
            !generated_call_uses_partial_values(uses_primed, args);
        const partial_mask = if (skip_partial_values)
            0
        else
            evaluator_context.state_assignment_mask();
        const partial_value_slice = if (partial_mask == 0)
            &.{}
        else
            evaluator_context.state_values(
                @intCast(self.module.variables.len),
            );
        const partial_pool_slice = if (partial_mask == 0)
            &.{}
        else
            evaluator_context.state_value_pools(
                @intCast(self.module.variables.len),
            );
        var context = generated_runtime.CallContext{
            .eval_pool = eval_pool,
            .state_pool = state_pool,
            .state = current_state,
            .next_state = self.next_state,
            .partial_mask = partial_mask,
            .partial_values = partial_value_slice,
            .partial_value_pools = partial_pool_slice,
            .read_primed = false,
            .enabled_result = self.enabled_result,
            .constants = self.constants,
            .constant_slots = self.constant_slots,
            .generated_cache = self.generated_cache,
            .generated_cache_pool = self.generated_cache_pool,
            .generated_cache_frozen = self.generated_cache_frozen,
            .late_generated_cache = self.late_generated_cache,
            .late_generated_cache_pool = self.late_generated_cache_pool,
            .models = self.models,
            .memo_context = self,
            .cached_call = generated_cached_call,
            .put_cached_call = generated_put_cached_call,
            .cached_stable_call = generated_cached_stable_call,
            .put_cached_stable_call = generated_put_cached_stable_call,
            .native_context = self,
            .native_call = generated_native_call,
            .max_seq_len = self.override_registry.ctx.max_seq_len,
        };
        return function(&context, args);
    }

    fn call_generated_bool(
        self: *const Evaluator,
        function: generated_runtime.OperatorBoolFn,
        args: []const Value,
        evaluator_context: Context,
        current_state: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
        uses_primed: bool,
    ) Error!bool {
        assert(self.module.variables.len <= 64);
        // Keep partial assignments available to deferred operator arguments.
        const skip_partial_values = current_state != null and
            !generated_call_uses_partial_values(uses_primed, args);
        const partial_mask = if (skip_partial_values)
            0
        else
            evaluator_context.state_assignment_mask();
        const partial_value_slice = if (partial_mask == 0)
            &.{}
        else
            evaluator_context.state_values(
                @intCast(self.module.variables.len),
            );
        const partial_pool_slice = if (partial_mask == 0)
            &.{}
        else
            evaluator_context.state_value_pools(
                @intCast(self.module.variables.len),
            );
        var context = generated_runtime.CallContext{
            .eval_pool = eval_pool,
            .state_pool = state_pool,
            .state = current_state,
            .next_state = self.next_state,
            .partial_mask = partial_mask,
            .partial_values = partial_value_slice,
            .partial_value_pools = partial_pool_slice,
            .read_primed = false,
            .enabled_result = self.enabled_result,
            .constants = self.constants,
            .constant_slots = self.constant_slots,
            .generated_cache = self.generated_cache,
            .generated_cache_pool = self.generated_cache_pool,
            .generated_cache_frozen = self.generated_cache_frozen,
            .late_generated_cache = self.late_generated_cache,
            .late_generated_cache_pool = self.late_generated_cache_pool,
            .models = self.models,
            .memo_context = self,
            .cached_call = generated_cached_call,
            .put_cached_call = generated_put_cached_call,
            .cached_stable_call = generated_cached_stable_call,
            .put_cached_stable_call = generated_put_cached_stable_call,
            .native_context = self,
            .native_call = generated_native_call,
            .max_seq_len = self.override_registry.ctx.max_seq_len,
        };
        return function(&context, args);
    }

    fn eval_sequence_fold(
        self: *const Evaluator,
        operator_expr: *ast.Expr,
        accumulator_expr: *ast.Expr,
        sequence_expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const operator = try self.eval_expr(
            operator_expr,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        var accumulator = try self.eval_expr(
            accumulator_expr,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        const sequence = try self.eval_expr(
            sequence_expr,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        const len: u32 = switch (sequence) {
            .tuple_v => |tuple| tuple.len,
            .function_v => |function| function.len,
            else => return self.fail(
                Error.TypeError,
                "sequence fold",
                @tagName(sequence),
            ),
        };
        const context_snap = self.context_snapshot();
        var index: u32 = 0;
        while (index < len) : (index += 1) {
            const element = switch (sequence) {
                .tuple_v => |tuple| eval_pool.values[tuple.offset + index],
                .function_v => |function| eval_pool.values[function.offset + index],
                else => unreachable,
            };
            const args = [_]Value{ element, accumulator };
            accumulator = try self.apply_values(
                operator,
                &args,
                eval_pool,
                state_pool,
                s0,
            );
            self.restore_context_pool(context_snap);
        }
        return accumulator;
    }

    fn eval_fold_function_on_set(
        self: *const Evaluator,
        ap: *ast.Apply,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        assert(ap.args.len == 4);
        const op = try self.eval_expr(ap.args[0], ctx, s0, eval_pool, state_pool);
        var accumulator = try self.eval_expr(ap.args[1], ctx, s0, eval_pool, state_pool);
        const function = try self.eval_expr(ap.args[2], ctx, s0, eval_pool, state_pool);
        const indices = try self.eval_set_materialized(ap.args[3], ctx, s0, eval_pool, state_pool);
        if (indices != .set_v) return self.fail(Error.TypeError, "FoldFunctionOnSet", "indices");

        for (indices.set_v.items(eval_pool)) |index| {
            const mapped = try self.apply_value(function, index, eval_pool, state_pool, s0);
            const args = [_]Value{ mapped, accumulator };
            accumulator = try self.apply_values(op, &args, eval_pool, state_pool, s0);
        }
        return accumulator;
    }

    fn eval_select_seq(
        self: *const Evaluator,
        ap: *ast.Apply,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (ap.args.len != 2) return self.fail(Error.TypeError, "SelectSeq", "expected two arguments");

        const sequence = try self.eval_expr(ap.args[0], ctx, s0, eval_pool, state_pool);
        const predicate = try self.eval_expr(ap.args[1], ctx, s0, eval_pool, state_pool);
        const len: u32 = switch (sequence) {
            .tuple_v => |tuple| tuple.len,
            .function_v => |function| function.len,
            else => return self.fail(Error.TypeError, "SelectSeq", "first argument is not a sequence"),
        };
        if (len == 0) return Value{ .tuple_v = .{ .offset = 0, .len = 0 } };

        // Reserve the complete result before invoking the predicate. Predicate
        // evaluation may grow the pool, but the offset remains stable.
        const result = try eval_pool.alloc_values(len);
        const result_offset = value_offset(eval_pool, result.ptr);
        assert(result_offset + len <= eval_pool.value_count);

        var selected: u32 = 0;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const element = switch (sequence) {
                .tuple_v => |tuple| blk: {
                    assert(tuple.offset + tuple.len <= eval_pool.value_count);
                    break :blk eval_pool.values[tuple.offset + i];
                },
                .function_v => |function| function.apply(
                    eval_pool,
                    Value{ .int_v = @as(i64, @intCast(i)) + 1 },
                ) orelse return self.fail(Error.TypeError, "SelectSeq", "function domain is not 1..Len(sequence)"),
                else => unreachable,
            };
            const keep = try self.apply_value(predicate, element, eval_pool, state_pool, s0);
            if (keep != .bool_v) {
                return self.fail(Error.TypeError, "SelectSeq", "predicate did not return BOOLEAN");
            }
            if (keep.bool_v) {
                assert(selected < len);
                eval_pool.values[result_offset + selected] = element;
                selected += 1;
            }
        }
        assert(selected <= len);
        return Value{ .tuple_v = .{ .offset = result_offset, .len = selected } };
    }

    fn apply_values(self: *const Evaluator, func: Value, args: []const Value, eval_pool: *ValuePool, state_pool: *ValuePool, s0: ?*StateStore.State) Error!Value {
        if (func == .generated_operator_v) {
            const operator_value = func.generated_operator_v;
            if (args.len != operator_value.arity) {
                return self.fail(
                    Error.TypeError,
                    "apply generated operator arity",
                    "argument count mismatch",
                );
            }
            if (operator_value.captured_len + args.len > 64) {
                return Error.NotImplemented;
            }
            const generated_function: generated_runtime.OperatorFn = @ptrFromInt(
                operator_value.function_address,
            );
            var combined: [64]Value = undefined;
            const captured = eval_pool.values[operator_value.captured_offset..][0..operator_value.captured_len];
            @memcpy(combined[0..captured.len], captured);
            @memcpy(combined[captured.len..][0..args.len], args);
            return try self.call_generated(
                generated_function,
                combined[0 .. captured.len + args.len],
                Context.empty(),
                s0,
                eval_pool,
                state_pool,
                true,
            );
        }
        if (args.len == 0) return func;
        if (args.len == 1) return try self.apply_value(func, args[0], eval_pool, state_pool, s0);
        if (func == .lambda_v) {
            const lambda = func.lambda_v;
            if (lambda.params.len != args.len) return Error.TypeError;
            const body: *ast.Expr = @ptrCast(@alignCast(lambda.body));
            const lambda_ctx: *Context = @ptrCast(@alignCast(lambda.ctx));
            var new_ctx = lambda_ctx.*;
            for (lambda.params, args) |param, arg| {
                new_ctx = try self.extend_context(new_ctx, param, arg);
            }
            return try self.eval_expr(body, new_ctx, s0, eval_pool, state_pool);
        }
        const tuple_values = try eval_pool.alloc_values(@intCast(args.len));
        @memcpy(tuple_values, args);
        const arg = Value{ .tuple_v = make_tuple(eval_pool, tuple_values) };
        return try self.apply_value(func, arg, eval_pool, state_pool, s0);
    }

    fn make_recursive_function(
        self: *const Evaluator,
        def: ast.Definition,
        ctx: Context,
        eval_pool: *ValuePool,
    ) Error!Value {
        std.debug.assert(def.is_function);
        const body = def.body;
        const source_params = if (def.function_vars.len > 0)
            def.function_vars
        else
            &[_][]const u8{def.function_var};
        const params_copy = try eval_pool.arena.alloc([]const u8, source_params.len);
        @memcpy(params_copy, source_params);

        // Allocate the lambda and context first; the context binds the
        // function name to the lambda itself, allowing recursive calls.
        const lam = try eval_pool.arena.alloc_object(value.Lambda);
        const ctx_ptr = try eval_pool.arena.alloc_object(Context);
        const func_val = Value{ .lambda_v = lam };
        ctx_ptr.* = try self.extend_context(ctx, def.name, func_val);
        lam.* = value.Lambda{
            .params = params_copy,
            .body = @ptrCast(body),
            .ctx = @ptrCast(ctx_ptr),
        };
        return func_val;
    }

    fn apply_value(self: *const Evaluator, func: Value, arg: Value, eval_pool: *ValuePool, state_pool: *ValuePool, s0: ?*StateStore.State) Error!Value {
        switch (func) {
            .function_v => |f| return f.apply(eval_pool, arg) orelse {
                if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
                    std.debug.print(
                        "function lookup missed: arg={s}",
                        .{@tagName(arg)},
                    );
                    if (arg == .model_v) {
                        std.debug.print("({d})", .{arg.model_v});
                    } else if (arg == .int_v) {
                        std.debug.print("({d})", .{arg.int_v});
                    }
                    std.debug.print(" domain=[", .{});
                    for (f.domain.items(eval_pool), 0..) |item, index| {
                        if (index != 0) std.debug.print(",", .{});
                        if (item == .model_v) {
                            std.debug.print("model({d})", .{item.model_v});
                        } else if (item == .int_v) {
                            std.debug.print("int({d})", .{item.int_v});
                        } else {
                            std.debug.print("{s}", .{@tagName(item)});
                        }
                    }
                    std.debug.print("]\n", .{});
                }
                return self.fail(
                    Error.IndexOutOfBounds,
                    "apply function",
                    @tagName(arg),
                );
            },
            .tuple_v => |t| {
                const idx = (arg.as_int() orelse return Error.TypeError) - 1;
                if (idx < 0 or idx >= t.len) return self.fail(Error.IndexOutOfBounds, "apply tuple", @tagName(arg));
                return t.items(eval_pool)[@intCast(idx)];
            },
            .record_v => |r| {
                const name = arg.string_v.slice(eval_pool);
                return r.lookup(eval_pool, name) orelse Error.UndefinedSymbol;
            },
            .lambda_v => |l| {
                const body: *ast.Expr = @ptrCast(@alignCast(l.body));
                const lambda_ctx: *Context = @ptrCast(@alignCast(l.ctx));
                var new_ctx = lambda_ctx.*;
                if (l.params.len == 1) {
                    new_ctx = try self.extend_context(new_ctx, l.params[0], arg);
                } else {
                    if (arg != .tuple_v or arg.tuple_v.len != l.params.len) return Error.TypeError;
                    const items = arg.tuple_v.items(eval_pool);
                    for (l.params, 0..) |p, i| {
                        new_ctx = try self.extend_context(new_ctx, p, items[i]);
                    }
                }
                return try self.eval_expr(body, new_ctx, s0, eval_pool, state_pool);
            },
            else => return self.fail(
                Error.TypeError,
                "apply value",
                @tagName(func),
            ),
        }
    }

    fn eval_field(
        self: *const Evaluator,
        f: *ast.Field,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const rec = try self.eval_expr(f.expr, ctx, s0, eval_pool, state_pool);
        if (rec != .record_v) return Error.TypeError;
        return rec.record_v.lookup(eval_pool, f.name) orelse
            self.fail(Error.UndefinedSymbol, "record field", f.name);
    }

    fn eval_quantifier(
        self: *const Evaluator,
        q: *ast.Quantifier,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (try self.eval_state_function_quantifier(
            q,
            ctx,
            s0,
            eval_pool,
            state_pool,
        )) |result| {
            return result;
        }
        return try self.eval_quantifier_vars(q, 0, ctx, s0, eval_pool, state_pool);
    }

    fn eval_state_function_quantifier(
        self: *const Evaluator,
        q: *ast.Quantifier,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        const state_v = s0 orelse return null;
        if (q.kind != .forall or q.vars.len == 0 or q.vars.len > 8 or
            q.body.* != .binary)
        {
            return null;
        }
        const comparison = q.body.*.binary;
        switch (comparison.op) {
            .eq, .ne, .lt, .le, .gt, .ge => {},
            else => return null,
        }
        if (comparison.left.* != .apply) return null;

        var root_name: []const u8 = "";
        var groups: [8]ApplicationGroup = undefined;
        var group_count: u8 = 0;
        if (!collect_application_groups(
            comparison.left.*.apply,
            &root_name,
            &groups,
            &group_count,
        )) return null;
        if (ctx.has_local_binding(root_name)) return null;
        const variable_index = self.find_variable(root_name) orelse
            return null;
        assert(variable_index < state_v.values.len);

        var group_var_indices: [8]u8 = undefined;
        for (groups[0..group_count], 0..) |group, group_index| {
            if (group.args.len != 1 or group.args[0].* != .ident) {
                return null;
            }
            const argument_name = group.args[0].*.ident;
            var found: ?u8 = null;
            for (q.vars, 0..) |bound_var, bound_index| {
                if (name_eql(bound_var.name, argument_name)) {
                    found = @intCast(bound_index);
                    break;
                }
            }
            group_var_indices[group_index] = found orelse return null;
        }
        if (expr_mentions_bound_names(comparison.right, q.vars)) {
            return null;
        }

        var domains: [8]Value = undefined;
        for (q.vars, 0..) |bound_var, i| {
            domains[i] = try self.eval_set_materialized(
                bound_var.domain,
                ctx,
                s0,
                eval_pool,
                state_pool,
            );
            if (domains[i] != .set_v) return null;
        }
        const right = try self.eval_expr(
            comparison.right,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        var assignments: [8]Value = undefined;
        const holds = try self.eval_state_quantifier_combinations(
            domains[0..q.vars.len],
            0,
            &assignments,
            state_v.values[variable_index],
            state_v.value_pool(variable_index, state_pool),
            groups[0..group_count],
            group_var_indices[0..group_count],
            comparison.op,
            right,
            eval_pool,
            state_pool,
        );
        return Value{ .bool_v = holds };
    }

    fn eval_state_quantifier_combinations(
        self: *const Evaluator,
        domains: []const Value,
        depth: usize,
        assignments: *[8]Value,
        root: Value,
        root_pool: *const ValuePool,
        groups: []const ApplicationGroup,
        group_var_indices: []const u8,
        comparison: ast.BinaryOp,
        right: Value,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!bool {
        if (depth < domains.len) {
            for (domains[depth].set_v.items(eval_pool)) |item| {
                assignments[depth] = item;
                if (!try self.eval_state_quantifier_combinations(
                    domains,
                    depth + 1,
                    assignments,
                    root,
                    root_pool,
                    groups,
                    group_var_indices,
                    comparison,
                    right,
                    eval_pool,
                    state_pool,
                )) return false;
            }
            return true;
        }

        var current = root;
        for (groups, group_var_indices) |_, bound_index| {
            current = try apply_cross_pool(
                self,
                current,
                root_pool,
                assignments[bound_index],
                eval_pool,
            );
        }
        return compare_cross_pool_scalars(
            current,
            root_pool,
            right,
            eval_pool,
            comparison,
        ) orelse return Error.TypeError;
    }

    fn eval_quantifier_vars(
        self: *const Evaluator,
        q: *ast.Quantifier,
        idx: u32,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const saved_context_count = self.context_pool.snapshot();
        defer self.context_pool.restore(saved_context_count);
        if (idx >= q.vars.len) {
            if (self.boolean_membership_is_tautology(q.body, 0)) {
                return .{ .bool_v = true };
            }
            return try self.eval_expr(q.body, ctx, s0, eval_pool, state_pool);
        }
        const bv = q.vars[idx];
        if (bv.domain.* == .ident and std.mem.eql(
            u8,
            bv.domain.ident,
            "__tlzig_unbounded_domain",
        )) {
            if (!self.boolean_membership_is_tautology(q.body, 0)) {
                return self.fail(
                    Error.NotImplemented,
                    "unbounded quantifier",
                    bv.name,
                );
            }
            return try self.eval_quantifier_vars(
                q,
                idx + 1,
                ctx,
                s0,
                eval_pool,
                state_pool,
            );
        }
        if (try self.eval_filtered_power_set_quantifier(
            q,
            idx,
            bv,
            ctx,
            s0,
            eval_pool,
            state_pool,
        )) |result| {
            return result;
        }
        var independent = !codegen.expression_references_identifier(
            q.body,
            bv.name,
        );
        if (independent) {
            for (q.vars[idx + 1 ..]) |later| {
                if (codegen.expression_references_identifier(
                    later.domain,
                    bv.name,
                )) {
                    independent = false;
                    break;
                }
            }
        }
        if (independent) {
            const symbolic_domain = (try eval_symbolic_set(
                self,
                bv.domain,
                ctx,
                s0,
                eval_pool,
                state_pool,
            )) orelse try self.eval_expr(
                bv.domain,
                ctx,
                s0,
                eval_pool,
                state_pool,
            );
            const domain_nonempty: ?bool = switch (symbolic_domain) {
                .set_v => |set| set.len > 0,
                .range_v => |range| range.hi >= range.lo,
                else => null,
            };
            if (domain_nonempty) |nonempty| {
                if (!nonempty) {
                    return .{ .bool_v = q.kind == .forall };
                }
                return try self.eval_quantifier_vars(
                    q,
                    idx + 1,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
            }
        }
        const domain = try self.eval_set_materialized(bv.domain, ctx, s0, eval_pool, state_pool);
        assert(domain == .set_v);
        const item_offset = domain.set_v.offset;
        const item_count = domain.set_v.len;
        assert(item_offset + item_count <= eval_pool.value_count);
        const expected = q.kind == .forall;
        var item_index: u32 = 0;
        while (item_index < item_count) : (item_index += 1) {
            assert(item_offset + item_index < eval_pool.value_count);
            const it = eval_pool.values[item_offset + item_index];
            const new_ctx = try self.extend_context(ctx, bv.name, it);
            const result = try self.eval_quantifier_vars(q, idx + 1, new_ctx, s0, eval_pool, state_pool);
            if (result.is_truthy() != expected) {
                return Value{ .bool_v = !expected };
            }
        }
        return Value{ .bool_v = expected };
    }

    fn boolean_membership_is_tautology(
        self: *const Evaluator,
        expression: *const ast.Expr,
        depth: u8,
    ) bool {
        if (expression.* != .binary or expression.binary.op != .in or
            expression.binary.right.* != .ident or
            !std.mem.eql(u8, expression.binary.right.ident, "BOOLEAN"))
        {
            return false;
        }
        return self.expression_guaranteed_boolean(
            expression.binary.left,
            depth,
        );
    }

    fn expression_guaranteed_boolean(
        self: *const Evaluator,
        expression: *const ast.Expr,
        depth: u8,
    ) bool {
        if (depth >= 32) return false;
        return switch (expression.*) {
            .bool_literal => true,
            .binary => |binary| switch (binary.op) {
                .eq,
                .ne,
                .lt,
                .le,
                .gt,
                .ge,
                .in,
                .notin,
                .subseteq,
                .and_op,
                .or_op,
                .implies,
                .equiv,
                => true,
                else => false,
            },
            .unary => |unary| switch (unary.op) {
                .not, .enabled, .temporal_box, .temporal_diamond => true,
                else => false,
            },
            .quantifier => true,
            .apply => |application| blk: {
                if (application.func.* != .ident) break :blk false;
                const name = self.resolve_alias(application.func.ident);
                const definition = self.find_definition(name) orelse
                    break :blk false;
                if (definition.params.len != application.args.len) {
                    break :blk false;
                }
                break :blk self.expression_guaranteed_boolean(
                    definition.body,
                    depth + 1,
                );
            },
            else => false,
        };
    }

    fn eval_filtered_power_set_quantifier(
        self: *const Evaluator,
        q: *ast.Quantifier,
        idx: u32,
        quantified_var: ast.BoundVar,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        const domain_expr = blk: {
            if (quantified_var.domain.* == .ident) {
                const name = self.resolve_alias(quantified_var.domain.ident);
                const definition = self.find_definition(name) orelse
                    return null;
                if (definition.params.len != 0) return null;
                break :blk definition.body;
            }
            break :blk quantified_var.domain;
        };
        if (domain_expr.* != .set_filter) return null;
        const filter = domain_expr.set_filter;
        if (filter.vars.len != 1) return null;

        const symbolic_domain = try self.eval_expr(
            filter.vars[0].domain,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (symbolic_domain != .power_set_v) return null;
        const base = try self.materialize_set(
            symbolic_domain.power_set_v.set(eval_pool),
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        if (base != .set_v or base.set_v.len > 63) return null;

        const base_items = base.set_v.items(eval_pool);
        const subset_storage = try eval_pool.alloc_values(base.set_v.len);
        const iteration_snapshot = eval_pool.snapshot();
        const saved_context_count = self.context_pool.snapshot();
        const expected = q.kind == .forall;
        const subset_count = @as(u64, 1) << @intCast(base_items.len);
        var mask: u64 = 0;
        while (mask < subset_count) : (mask += 1) {
            var item_count: u32 = 0;
            for (base_items, 0..) |item, bit| {
                if ((mask & (@as(u64, 1) << @intCast(bit))) != 0) {
                    subset_storage[item_count] = item;
                    item_count += 1;
                }
            }
            const subset = Value{ .set_v = try make_set(
                eval_pool,
                subset_storage[0..item_count],
            ) };
            const filter_ctx = try self.extend_context(
                ctx,
                filter.vars[0].name,
                subset,
            );
            const accepted = try self.eval_expr(
                filter.pred,
                filter_ctx,
                s0,
                eval_pool,
                state_pool,
            );
            if (accepted.is_truthy()) {
                const quantified_ctx = try self.extend_context(
                    ctx,
                    quantified_var.name,
                    subset,
                );
                const result = try self.eval_quantifier_vars(
                    q,
                    idx + 1,
                    quantified_ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                if (result.is_truthy() != expected) {
                    eval_pool.restore(iteration_snapshot);
                    self.context_pool.restore(saved_context_count);
                    return Value{ .bool_v = !expected };
                }
            }
            eval_pool.restore(iteration_snapshot);
            self.context_pool.restore(saved_context_count);
        }
        return Value{ .bool_v = expected };
    }

    fn eval_let_in(
        self: *const Evaluator,
        l: *ast.LetIn,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        var new_ctx = ctx;
        for (l.defs) |def| {
            const v = if (def.is_function)
                try self.make_recursive_function(def, new_ctx, eval_pool)
            else
                try self.make_lambda(def, new_ctx, eval_pool);
            new_ctx = try self.extend_context(new_ctx, def.name, v);
        }
        return try self.eval_expr(l.body, new_ctx, s0, eval_pool, state_pool);
    }

    fn eval_local_identifier(
        self: *const Evaluator,
        ctx: Context,
        name: []const u8,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!?Value {
        const value_v = ctx.lookup_local_value(name) orelse
            return null;
        if (value_v != .lambda_v or value_v.lambda_v.params.len != 0) {
            return value_v;
        }
        const lambda = value_v.lambda_v;
        const body: *ast.Expr = @ptrCast(@alignCast(lambda.body));
        const lambda_ctx: *Context = @ptrCast(@alignCast(lambda.ctx));
        return try self.eval_expr(
            body,
            lambda_ctx.*,
            s0,
            eval_pool,
            state_pool,
        );
    }

    fn make_lambda(
        self: *const Evaluator,
        def: ast.Definition,
        ctx: Context,
        eval_pool: *ValuePool,
    ) Error!Value {
        const lam = try eval_pool.arena.alloc_object(value.Lambda);
        const ctx_ptr = try eval_pool.arena.alloc_object(Context);
        const params_copy = try eval_pool.arena.alloc([]const u8, def.params.len);
        for (def.params, 0..) |p, i| params_copy[i] = p;
        const function = Value{ .lambda_v = lam };
        // LET operators may be declared RECURSIVE. Self-binding every local
        // parameterized operator is semantically inert when it is not
        // recursive and avoids carrying parser-only declaration metadata.
        ctx_ptr.* = try self.extend_context(ctx, def.name, function);
        lam.* = value.Lambda{
            .params = params_copy,
            .body = @ptrCast(def.body),
            .ctx = @ptrCast(ctx_ptr),
        };
        return function;
    }

    fn eval_case_expr(
        self: *const Evaluator,
        c: *ast.CaseExpr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        for (c.arms) |arm| {
            const cond = try self.eval_expr(arm.cond, ctx, s0, eval_pool, state_pool);
            if (cond.is_truthy()) {
                return try self.eval_expr(arm.value, ctx, s0, eval_pool, state_pool);
            }
        }
        if (c.otherwise) |other| {
            return try self.eval_expr(other, ctx, s0, eval_pool, state_pool);
        }
        return Error.EmptyChoose;
    }

    fn eval_choose(
        self: *const Evaluator,
        c: *ast.Choose,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (c.domain) |domain_expr| {
            const domain = try self.eval_set_materialized(domain_expr, ctx, s0, eval_pool, state_pool);
            const domain_set = domain.set_v;
            assert(domain_set.offset + domain_set.len <= eval_pool.value_count);
            const scratch_snapshot = eval_pool.snapshot();
            const context_snap = self.context_snapshot();
            var chosen: ?Value = null;
            for (0..domain_set.len) |item_index| {
                const it = eval_pool.values[domain_set.offset + item_index];
                const new_ctx = try self.extend_context(ctx, c.var_name, it);
                const pred = try self.eval_expr(c.body, new_ctx, s0, eval_pool, state_pool);
                if (pred.is_truthy()) {
                    if (chosen == null) {
                        chosen = it;
                    } else if (self.compare_choose_values(
                        it,
                        chosen.?,
                        eval_pool,
                    )) |cmp| {
                        if (cmp < 0) chosen = it;
                    }
                }
                eval_pool.restore(scratch_snapshot);
                self.restore_context_pool(context_snap);
            }
            if (chosen) |value_v| return value_v;
            std.debug.print(
                "CHOOSE has no witness: variable={s} domain_size={d}\n",
                .{ c.var_name, domain_set.len },
            );
            return self.fail(Error.EmptyChoose, "CHOOSE", c.var_name);
        }
        // Domain-free CHOOSE: try fresh model values until the predicate holds.
        var attempt: u32 = 0;
        while (attempt < 1024) : (attempt += 1) {
            var name_buffer: [32]u8 = undefined;
            const name = std.fmt.bufPrint(
                &name_buffer,
                "__choose_{d}",
                .{attempt},
            ) catch return Error.OutOfMemory;
            const id = try self.models.intern(name);
            const candidate = Value{ .model_v = id };
            const new_ctx = try self.extend_context(ctx, c.var_name, candidate);
            const pred = try self.eval_expr(c.body, new_ctx, s0, eval_pool, state_pool);
            if (pred.is_truthy()) return candidate;
        }
        return self.fail(Error.EmptyChoose, "CHOOSE", c.var_name);
    }

    fn compare_choose_values(
        self: *const Evaluator,
        left: Value,
        right: Value,
        pool: *const ValuePool,
    ) ?i8 {
        if (left == .model_v) {
            if (right != .model_v) return -1;
            return switch (std.mem.order(
                u8,
                self.models.get_name(left.model_v),
                self.models.get_name(right.model_v),
            )) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        }
        if (right == .model_v) return 1;
        if (left == .tuple_v and right == .tuple_v) {
            const left_items = left.tuple_v.items(pool);
            const right_items = right.tuple_v.items(pool);
            if (left_items.len != right_items.len) {
                return if (left_items.len < right_items.len) -1 else 1;
            }
            for (left_items, right_items) |left_item, right_item| {
                const comparison = self.compare_choose_values(
                    left_item,
                    right_item,
                    pool,
                ) orelse return null;
                if (comparison != 0) return comparison;
            }
            return 0;
        }
        return left.compare(right, pool);
    }

    fn eval_except(
        self: *const Evaluator,
        e: *ast.Except,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (s0) |state_v| {
            if (e.func.* == .ident) {
                if (self.find_variable(e.func.*.ident)) |variable_index| {
                    assert(variable_index < state_v.values.len);
                    return try self.except_steps_cross_pool(
                        state_v.values[variable_index],
                        state_v.value_pool(variable_index, state_pool),
                        e.steps,
                        0,
                        e.value,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                }
            }
        }
        const original = try self.eval_expr(e.func, ctx, s0, eval_pool, state_pool);
        return try self.except_steps(original, e.steps, 0, e.value, ctx, s0, eval_pool, state_pool);
    }

    fn except_steps_cross_pool(
        self: *const Evaluator,
        original: Value,
        original_pool: *const ValuePool,
        steps: []const ast.AccessStep,
        idx: u32,
        value_expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        assert(idx < steps.len);
        const step = steps[idx];
        switch (step) {
            .index => |index_expr| {
                const key = try self.eval_expr(
                    index_expr,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                switch (original) {
                    .function_v => |function| {
                        const keys = function.domain.items(original_pool);
                        const entries = function.entries(original_pool);
                        var selected: ?u32 = null;
                        for (keys, 0..) |candidate, i| {
                            if (cross_pool_eql(
                                candidate,
                                original_pool,
                                key,
                                eval_pool,
                            )) {
                                selected = @intCast(i);
                                break;
                            }
                        }
                        const selected_index = selected orelse
                            return self.fail(
                                Error.IndexOutOfBounds,
                                "except cross-pool function",
                                @tagName(key),
                            );
                        const new_value = try self.except_cross_pool_child(
                            entries[selected_index],
                            original_pool,
                            steps,
                            idx,
                            value_expr,
                            ctx,
                            s0,
                            eval_pool,
                            state_pool,
                        );
                        const domain_values = try eval_pool.alloc_values(
                            function.len,
                        );
                        const result_values = try eval_pool.alloc_values(
                            function.len,
                        );
                        const domain_offset = value_offset(
                            eval_pool,
                            domain_values.ptr,
                        );
                        const result_offset = value_offset(
                            eval_pool,
                            result_values.ptr,
                        );
                        for (keys, entries, 0..) |
                            source_key,
                            source_value,
                            i,
                        | {
                            eval_pool.values[domain_offset + i] =
                                try source_key.clone(
                                    original_pool,
                                    eval_pool,
                                );
                            eval_pool.values[result_offset + i] =
                                if (i == selected_index)
                                    new_value
                                else
                                    try source_value.clone(
                                        original_pool,
                                        eval_pool,
                                    );
                        }
                        return Value{ .function_v = .{
                            .domain = .{
                                .offset = domain_offset,
                                .len = function.len,
                            },
                            .offset = result_offset,
                            .len = function.len,
                        } };
                    },
                    .tuple_v => |tuple| {
                        const selected_index_i64 =
                            (key.as_int() orelse return self.fail(
                                Error.TypeError,
                                "except cross-pool tuple",
                                @tagName(key),
                            )) - 1;
                        if (selected_index_i64 < 0 or
                            selected_index_i64 >= tuple.len)
                        {
                            return self.fail(
                                Error.IndexOutOfBounds,
                                "except cross-pool tuple",
                                @tagName(key),
                            );
                        }
                        const selected_index: u32 =
                            @intCast(selected_index_i64);
                        const items = tuple.items(original_pool);
                        const new_value = try self.except_cross_pool_child(
                            items[selected_index],
                            original_pool,
                            steps,
                            idx,
                            value_expr,
                            ctx,
                            s0,
                            eval_pool,
                            state_pool,
                        );
                        const result = try eval_pool.alloc_values(tuple.len);
                        const result_offset = value_offset(
                            eval_pool,
                            result.ptr,
                        );
                        for (items, 0..) |item, i| {
                            eval_pool.values[result_offset + i] =
                                if (i == selected_index)
                                    new_value
                                else
                                    try item.clone(original_pool, eval_pool);
                        }
                        return Value{ .tuple_v = .{
                            .offset = result_offset,
                            .len = tuple.len,
                        } };
                    },
                    .record_v => {
                        if (key != .string_v) {
                            return self.fail(
                                Error.TypeError,
                                "except cross-pool record",
                                @tagName(key),
                            );
                        }
                        return try self.except_cross_pool_record(
                            original.record_v,
                            original_pool,
                            key.string_v.slice(eval_pool),
                            steps,
                            idx,
                            value_expr,
                            ctx,
                            s0,
                            eval_pool,
                            state_pool,
                        );
                    },
                    else => return self.fail(
                        Error.TypeError,
                        "except cross-pool index",
                        @tagName(original),
                    ),
                }
            },
            .field => |field| {
                if (original != .record_v) {
                    return self.fail(
                        Error.TypeError,
                        "except cross-pool field",
                        @tagName(original),
                    );
                }
                return try self.except_cross_pool_record(
                    original.record_v,
                    original_pool,
                    field,
                    steps,
                    idx,
                    value_expr,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
            },
        }
    }

    fn except_cross_pool_child(
        self: *const Evaluator,
        old_value: Value,
        original_pool: *const ValuePool,
        steps: []const ast.AccessStep,
        idx: u32,
        value_expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (idx + 1 < steps.len) {
            return try self.except_steps_cross_pool(
                old_value,
                original_pool,
                steps,
                idx + 1,
                value_expr,
                ctx,
                s0,
                eval_pool,
                state_pool,
            );
        }
        const old_value_eval = try old_value.clone(
            original_pool,
            eval_pool,
        );
        const new_ctx = try self.extend_context(
            ctx,
            "@",
            old_value_eval,
        );
        return try self.eval_expr(
            value_expr,
            new_ctx,
            s0,
            eval_pool,
            state_pool,
        );
    }

    fn except_cross_pool_record(
        self: *const Evaluator,
        record: value.Record,
        original_pool: *const ValuePool,
        field: []const u8,
        steps: []const ast.AccessStep,
        idx: u32,
        value_expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        const fields = record.fields(original_pool);
        var selected: ?u32 = null;
        var i: u32 = 0;
        while (i < record.len) : (i += 1) {
            if (std.mem.eql(
                u8,
                fields[i * 2].string_v.slice(original_pool),
                field,
            )) {
                selected = i;
                break;
            }
        }
        const selected_index = selected orelse
            return self.fail(
                Error.UndefinedSymbol,
                "except cross-pool record",
                field,
            );
        const new_value = try self.except_cross_pool_child(
            fields[selected_index * 2 + 1],
            original_pool,
            steps,
            idx,
            value_expr,
            ctx,
            s0,
            eval_pool,
            state_pool,
        );
        const result = try eval_pool.alloc_values(record.len * 2);
        const result_offset = value_offset(eval_pool, result.ptr);
        i = 0;
        while (i < record.len) : (i += 1) {
            eval_pool.values[result_offset + i * 2] =
                try fields[i * 2].clone(
                    original_pool,
                    eval_pool,
                );
            eval_pool.values[result_offset + i * 2 + 1] =
                if (i == selected_index)
                    new_value
                else
                    try fields[i * 2 + 1].clone(
                        original_pool,
                        eval_pool,
                    );
        }
        return Value{ .record_v = .{
            .offset = result_offset,
            .len = record.len,
        } };
    }

    fn except_steps(
        self: *const Evaluator,
        original: Value,
        steps: []const ast.AccessStep,
        idx: u32,
        value_expr: *ast.Expr,
        ctx: Context,
        s0: ?*StateStore.State,
        eval_pool: *ValuePool,
        state_pool: *ValuePool,
    ) Error!Value {
        if (idx >= steps.len) {
            return try self.eval_expr(value_expr, ctx, s0, eval_pool, state_pool);
        }
        const step = steps[idx];
        switch (step) {
            .index => |idx_expr| {
                const key = try self.eval_expr(idx_expr, ctx, s0, eval_pool, state_pool);
                const old_value = try self.except_lookup_index(original, key, eval_pool);
                const new_ctx = try self.extend_context(ctx, "@", old_value);
                const new_value = try self.except_steps(old_value, steps, idx + 1, value_expr, new_ctx, s0, eval_pool, state_pool);
                return try self.except_update_index(original, key, new_value, eval_pool);
            },
            .field => |field| {
                const old_value = try self.except_lookup_field(original, field, eval_pool);
                const new_ctx = try self.extend_context(ctx, "@", old_value);
                const new_value = try self.except_steps(old_value, steps, idx + 1, value_expr, new_ctx, s0, eval_pool, state_pool);
                return try self.except_update_field(original, field, new_value, eval_pool);
            },
        }
    }

    fn except_lookup_index(self: *const Evaluator, original: Value, key: Value, eval_pool: *ValuePool) Error!Value {
        switch (original) {
            .function_v => |f| return f.apply(eval_pool, key) orelse self.fail(Error.IndexOutOfBounds, "except lookup function", @tagName(key)),
            .tuple_v => |t| {
                const i = (key.as_int() orelse
                    return self.fail(
                        Error.TypeError,
                        "except tuple index",
                        @tagName(key),
                    )) - 1;
                if (i < 0 or i >= t.len) return self.fail(Error.IndexOutOfBounds, "except lookup tuple", @tagName(key));
                return t.items(eval_pool)[@intCast(i)];
            },
            .record_v => |record| {
                if (key != .string_v) {
                    return self.fail(
                        Error.TypeError,
                        "except record index",
                        @tagName(key),
                    );
                }
                const field = key.string_v.slice(eval_pool);
                return record.lookup(eval_pool, field) orelse
                    self.fail(
                        Error.UndefinedSymbol,
                        "except record index",
                        field,
                    );
            },
            else => return self.fail(
                Error.TypeError,
                "except index lookup",
                @tagName(original),
            ),
        }
    }

    fn except_update_index(self: *const Evaluator, original: Value, key: Value, new_value: Value, eval_pool: *ValuePool) Error!Value {
        switch (original) {
            .function_v => |f| {
                const entries = f.entries(eval_pool);
                const dest = try eval_pool.alloc_values(@intCast(entries.len));
                const keys = f.domain.items(eval_pool);
                for (entries, 0..) |v, i| {
                    dest[i] = if (keys[i].eql(key, eval_pool)) new_value else v;
                }
                return Value{ .function_v = .{
                    .domain = f.domain,
                    .offset = value_offset(eval_pool, dest.ptr),
                    .len = f.len,
                } };
            },
            .tuple_v => |t| {
                const i = (key.as_int() orelse
                    return self.fail(
                        Error.TypeError,
                        "except tuple index",
                        @tagName(key),
                    )) - 1;
                if (i < 0 or i >= t.len) return self.fail(Error.IndexOutOfBounds, "except update tuple", @tagName(key));
                const items = t.items(eval_pool);
                const dest = try eval_pool.alloc_values(@intCast(items.len));
                @memcpy(dest, items);
                dest[@intCast(i)] = new_value;
                return Value{ .tuple_v = make_tuple(eval_pool, dest) };
            },
            .record_v => {
                if (key != .string_v) {
                    return self.fail(
                        Error.TypeError,
                        "except record index",
                        @tagName(key),
                    );
                }
                return try self.except_update_field(
                    original,
                    key.string_v.slice(eval_pool),
                    new_value,
                    eval_pool,
                );
            },
            else => return self.fail(
                Error.TypeError,
                "except index update",
                @tagName(original),
            ),
        }
    }

    fn except_lookup_field(self: *const Evaluator, original: Value, field: []const u8, eval_pool: *ValuePool) Error!Value {
        if (original != .record_v) {
            return self.fail(
                Error.TypeError,
                "except field lookup",
                @tagName(original),
            );
        }
        return original.record_v.lookup(eval_pool, field) orelse Error.UndefinedSymbol;
    }

    fn except_update_field(self: *const Evaluator, original: Value, field: []const u8, new_value: Value, eval_pool: *ValuePool) Error!Value {
        if (original != .record_v) {
            return self.fail(
                Error.TypeError,
                "except field update",
                @tagName(original),
            );
        }
        const fs = original.record_v.fields(eval_pool);
        const dest = try eval_pool.alloc_values(@intCast(fs.len));
        @memcpy(dest, fs);
        var i: u32 = 0;
        while (i < original.record_v.len) : (i += 1) {
            const key = fs[i * 2].string_v.slice(eval_pool);
            if (std.mem.eql(u8, key, field)) {
                dest[i * 2 + 1] = new_value;
                break;
            }
        }
        return Value{ .record_v = make_record(eval_pool, dest) };
    }

    pub fn find_variable(self: *const Evaluator, name: []const u8) ?u32 {
        for (self.module.variables, 0..) |variable, index| {
            if (name_eql(variable, name)) return @intCast(index);
        }
        return null;
    }

    fn find_definition_index(self: *const Evaluator, name: []const u8) ?usize {
        for (self.module.definitions, 0..) |definition, index| {
            if (name_eql(definition.name, name)) return index;
        }
        return null;
    }

    pub fn find_definition(self: *const Evaluator, name: []const u8) ?ast.Definition {
        const index = self.find_definition_index(name) orelse return null;
        return self.module.definitions[index];
    }

    pub fn find_subexpression(self: *const Evaluator, name: []const u8) ?*ast.Expr {
        const bang = std.mem.lastIndexOfScalar(u8, name, '!') orelse return null;
        if (bang == 0 or bang + 1 >= name.len) return null;
        const selector = std.fmt.parseInt(usize, name[bang + 1 ..], 10) catch return null;
        if (selector == 0) return null;

        const base_name = name[0..bang];
        const base = if (self.find_definition(base_name)) |def|
            def.body
        else
            self.find_subexpression(base_name) orelse return null;
        return select_subexpression(base, selector);
    }
};

inline fn generated_call_uses_partial_values(
    uses_primed: bool,
    args: []const Value,
) bool {
    return uses_primed or
        generated_runtime.arguments_contain_generated_operator(args);
}

inline fn name_eql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    if (left.ptr == right.ptr) return true;
    return std.mem.eql(u8, left, right);
}

fn known_set_empty(set: Value, pool: *const ValuePool) ?bool {
    return switch (set) {
        .set_v => |materialized| materialized.len == 0,
        .range_v => |range| range.hi < range.lo,
        .power_set_v, .seq_set_v, .function_set_v => false,
        .cup_v => |binary| blk: {
            const left = known_set_empty(binary.left(pool), pool) orelse
                break :blk null;
            const right = known_set_empty(binary.right(pool), pool) orelse
                break :blk null;
            break :blk left and right;
        },
        else => null,
    };
}

fn definition_source_module(
    definition: ast.Definition,
    module_name: []const u8,
) bool {
    const file_name = std.fs.path.basename(definition.source_path);
    if (file_name.len != module_name.len + ".tla".len) return false;
    return std.mem.eql(u8, file_name[0..module_name.len], module_name) and
        std.mem.eql(u8, file_name[module_name.len..], ".tla");
}

fn generated_native_call(
    context: *const anyopaque,
    pool: *ValuePool,
    name: []const u8,
    args: []const Value,
    current_state: ?*StateStore.State,
) Error!Value {
    const evaluator: *const Evaluator = @ptrCast(
        @alignCast(context),
    );
    if (std.mem.eql(u8, name, "TLCGet")) {
        const level: u32 = if (current_state) |state_v|
            state_v.level + 1
        else
            0;
        return overrides.tlc_get_at_level(
            evaluator.override_registry.ctx,
            pool,
            args,
            level,
        );
    }
    const function = evaluator.override_registry.find(name) orelse
        return Error.UndefinedSymbol;
    return function(evaluator.override_registry.ctx, pool, args);
}

fn generated_cached_call(
    context: *const anyopaque,
    name: []const u8,
    args: []const Value,
    eval_pool: *ValuePool,
    current_state: ?*StateStore.State,
    next_state: ?*StateStore.State,
) Error!?Value {
    const evaluator: *const Evaluator = @ptrCast(@alignCast(context));
    const cached = evaluator.state_call_memo.get(
        name,
        args,
        eval_pool,
        if (current_state) |state_v| @intFromPtr(state_v) else 0,
        if (next_state) |state_v| @intFromPtr(state_v) else 0,
    ) orelse return null;
    return try cached.clone(evaluator.state_definition_pool, eval_pool);
}

fn generated_put_cached_call(
    context: *const anyopaque,
    name: []const u8,
    args: []const Value,
    result: Value,
    eval_pool: *ValuePool,
    current_state: ?*StateStore.State,
    next_state: ?*StateStore.State,
) Error!void {
    const evaluator: *const Evaluator = @ptrCast(@alignCast(context));
    evaluator.state_call_memo.put(
        name,
        args,
        eval_pool,
        if (current_state) |state_v| @intFromPtr(state_v) else 0,
        if (next_state) |state_v| @intFromPtr(state_v) else 0,
        result,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.NotImplemented => {},
    };
}

fn generated_cached_stable_call(
    context: *const anyopaque,
    name: []const u8,
    args: []const Value,
    eval_pool: *ValuePool,
    current_state: ?*StateStore.State,
    next_state: ?*StateStore.State,
) Error!?Value {
    const evaluator: *const Evaluator = @ptrCast(@alignCast(context));
    const contains_state_path =
        generated_runtime.arguments_contain_state_path_operator(args);
    if (!contains_state_path) {
        if (try evaluator.cached_persistent_call(
            name,
            args,
            eval_pool,
        )) |cached| return cached;
    }
    if (!contains_state_path and
        evaluator.action_call_memo.pool != null)
    {
        assert(evaluator.action_call_memo.pool == evaluator.action_call_pool);
        const cached = evaluator.action_call_memo.get(
            name,
            args,
            eval_pool,
            0,
            0,
        ) orelse return null;
        return try cached.clone(evaluator.action_call_pool, eval_pool);
    }
    return generated_cached_call(
        context,
        name,
        args,
        eval_pool,
        current_state,
        next_state,
    );
}

fn generated_put_cached_stable_call(
    context: *const anyopaque,
    name: []const u8,
    args: []const Value,
    result: Value,
    eval_pool: *ValuePool,
    current_state: ?*StateStore.State,
    next_state: ?*StateStore.State,
) Error!void {
    const evaluator: *const Evaluator = @ptrCast(@alignCast(context));
    const contains_state_path =
        generated_runtime.arguments_contain_state_path_operator(args);
    if (!contains_state_path and
        Evaluator.persistent_call_result_worth_caching(result))
    {
        evaluator.memoize_persistent_call(
            name,
            args,
            result,
            eval_pool,
        );
    }
    if (!contains_state_path and
        evaluator.action_call_memo.pool != null)
    {
        assert(evaluator.action_call_memo.pool == evaluator.action_call_pool);
        evaluator.action_call_memo.put(
            name,
            args,
            eval_pool,
            0,
            0,
            result,
        ) catch |err| switch (err) {
            error.OutOfMemory, error.NotImplemented => {},
        };
        return;
    }
    return generated_put_cached_call(
        context,
        name,
        args,
        result,
        eval_pool,
        current_state,
        next_state,
    );
}

fn expr_mentions_bound_names(
    expr: *const ast.Expr,
    vars: []const ast.BoundVar,
) bool {
    return switch (expr.*) {
        .bool_literal, .int_literal, .string_literal => false,
        .ident => |name| blk: {
            for (vars) |bound_var| {
                if (name_eql(name, bound_var.name)) break :blk true;
            }
            break :blk false;
        },
        else => true,
    };
}

fn compare_cross_pool_scalars(
    left: Value,
    left_pool: *const ValuePool,
    right: Value,
    right_pool: *const ValuePool,
    comparison: ast.BinaryOp,
) ?bool {
    return switch (comparison) {
        .eq => cross_pool_eql(
            left,
            left_pool,
            right,
            right_pool,
        ),
        .ne => !cross_pool_eql(
            left,
            left_pool,
            right,
            right_pool,
        ),
        .lt, .le, .gt, .ge => blk: {
            const left_int = left.as_int() orelse break :blk null;
            const right_int = right.as_int() orelse break :blk null;
            break :blk switch (comparison) {
                .lt => left_int < right_int,
                .le => left_int <= right_int,
                .gt => left_int > right_int,
                .ge => left_int >= right_int,
                else => unreachable,
            };
        },
        else => null,
    };
}

fn is_pointwise_function_predicate(
    expr: *const ast.Expr,
    function_name: []const u8,
    key_name: []const u8,
) bool {
    return switch (expr.*) {
        .bool_literal, .int_literal, .string_literal => true,
        .ident => |name| !name_eql(name, function_name),
        .binary => |binary| is_pointwise_function_predicate(
            binary.left,
            function_name,
            key_name,
        ) and is_pointwise_function_predicate(
            binary.right,
            function_name,
            key_name,
        ),
        .unary => |unary| is_pointwise_function_predicate(
            unary.operand,
            function_name,
            key_name,
        ),
        .quantifier => |quantifier| blk: {
            for (quantifier.vars) |bound_var| {
                if (name_eql(bound_var.name, function_name) or
                    name_eql(bound_var.name, key_name) or
                    !is_pointwise_function_predicate(
                        bound_var.domain,
                        function_name,
                        key_name,
                    ))
                {
                    break :blk false;
                }
            }
            break :blk is_pointwise_function_predicate(
                quantifier.body,
                function_name,
                key_name,
            );
        },
        .if_then_else => |conditional| is_pointwise_function_predicate(
            conditional.cond,
            function_name,
            key_name,
        ) and is_pointwise_function_predicate(
            conditional.then_branch,
            function_name,
            key_name,
        ) and is_pointwise_function_predicate(
            conditional.else_branch,
            function_name,
            key_name,
        ),
        .apply => |application| blk: {
            if (application.func.* == .ident and
                name_eql(
                    application.func.*.ident,
                    function_name,
                ))
            {
                break :blk application.args.len == 1 and
                    application.args[0].* == .ident and
                    name_eql(
                        application.args[0].*.ident,
                        key_name,
                    );
            }
            if (!is_pointwise_function_predicate(
                application.func,
                function_name,
                key_name,
            )) break :blk false;
            for (application.args) |argument| {
                if (!is_pointwise_function_predicate(
                    argument,
                    function_name,
                    key_name,
                )) break :blk false;
            }
            break :blk true;
        },
        .field => |field| is_pointwise_function_predicate(
            field.expr,
            function_name,
            key_name,
        ),
        .tuple, .set_enum => |items| blk: {
            for (items) |item| {
                if (!is_pointwise_function_predicate(
                    item,
                    function_name,
                    key_name,
                )) break :blk false;
            }
            break :blk true;
        },
        .record => |fields| blk: {
            for (fields) |field| {
                if (!is_pointwise_function_predicate(
                    field.value,
                    function_name,
                    key_name,
                )) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn select_subexpression(expr: *ast.Expr, selector: usize) ?*ast.Expr {
    if (expr.* != .binary) return if (selector == 1) expr else null;
    const op = expr.binary.op;
    if (op != .and_op and op != .or_op) return if (selector == 1) expr else null;

    var remaining = selector;
    return select_list_item(expr, op, &remaining);
}

fn select_list_item(expr: *ast.Expr, op: ast.BinaryOp, remaining: *usize) ?*ast.Expr {
    if (expr.* == .binary and expr.binary.op == op) {
        if (select_list_item(expr.binary.left, op, remaining)) |selected| return selected;
        return select_list_item(expr.binary.right, op, remaining);
    }
    if (remaining.* == 1) return expr;
    remaining.* -= 1;
    return null;
}

fn function_sets_have_distinct_domain_sizes(pool: *ValuePool, sets: []const Value) bool {
    var seen: [64]bool = undefined;
    @memset(&seen, false);
    for (sets) |set| {
        if (set != .function_set_v) return false;
        const domain = set.function_set_v.domain(pool);
        const size: usize = switch (domain) {
            .set_v => |s| s.len,
            .range_v => |r| blk: {
                if (r.hi < r.lo) break :blk 0;
                break :blk @intCast(r.hi - r.lo + 1);
            },
            else => return false,
        };
        if (size >= seen.len) return false;
        if (seen[size]) return false;
        seen[size] = true;
    }
    return true;
}

fn is_seq_application(expr: *ast.Expr) bool {
    if (expr.* != .apply) return false;
    const application = expr.apply;
    return application.args.len == 1 and
        application.func.* == .ident and
        std.mem.eql(u8, application.func.ident, "Seq");
}

const SequenceSetShape = struct {
    codomain: Value,
    length_count: usize,
    max_length: u32,
};

fn extract_sequence_set_shape(
    pool: *ValuePool,
    seq_set: Value,
) ?SequenceSetShape {
    if (seq_set != .union_v) return null;
    const inner = seq_set.union_v.set(pool);
    if (inner != .set_v) return null;

    var codomain: ?Value = null;
    var max_length: u32 = 0;
    const sets = inner.set_v.items(pool);
    if (sets.len == 0) return null;
    for (sets) |set| {
        if (set != .function_set_v) return null;
        const fs = set.function_set_v;
        const len = sequence_domain_size(pool, fs.domain(pool)) orelse return null;
        max_length = @max(max_length, len);
        const fs_codomain = fs.codomain(pool);
        if (codomain) |existing| {
            if (!existing.eql(fs_codomain, pool)) return null;
        } else {
            codomain = fs_codomain;
        }
    }
    return SequenceSetShape{
        .codomain = codomain.?,
        .length_count = sets.len,
        .max_length = max_length,
    };
}

fn sequence_domain_size(pool: *ValuePool, domain: Value) ?u32 {
    return switch (domain) {
        .set_v => |s| blk: {
            const items = s.items(pool);
            for (items, 0..) |it, i| {
                if (it != .int_v or it.int_v != @as(i64, @intCast(i + 1))) return null;
            }
            break :blk s.len;
        },
        .range_v => |r| blk: {
            if (r.lo != 1 or r.hi < 0) return null;
            break :blk @intCast(@max(r.hi, 0));
        },
        else => null,
    };
}

fn sort_values(pool: *ValuePool, items: []Value) ?void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0) {
            const cmp = items[j - 1].compare(key, pool) orelse return null;
            if (cmp <= 0) break;
            items[j] = items[j - 1];
            j -= 1;
        }
        items[j] = key;
    }
}

fn sorted_sequence_count(
    value_count: usize,
    target_len: u32,
) Error!u64 {
    if (target_len == 0) return 1;
    if (value_count == 0) return 0;

    const n = @as(u128, value_count) + @as(u128, target_len) - 1;
    const k = @min(
        @as(u128, target_len),
        @as(u128, value_count - 1),
    );
    var count: u128 = 1;
    var i: u128 = 1;
    while (i <= k) : (i += 1) {
        count = std.math.mul(
            u128,
            count,
            n - k + i,
        ) catch return Error.OutOfMemory;
        count /= i;
        if (count > std.math.maxInt(u32)) return Error.OutOfMemory;
    }
    return @intCast(count);
}

fn generate_sorted_sequences(
    eval_pool: *ValuePool,
    values: []const Value,
    current: []Value,
    start: usize,
    depth: usize,
    generated: []Value,
    generated_index: *usize,
) Error!void {
    if (depth == current.len) {
        assert(generated_index.* < generated.len);
        generated[generated_index.*] = try make_sequence_function(
            eval_pool,
            current,
        );
        generated_index.* += 1;
        return;
    }
    var i = start;
    while (i < values.len) : (i += 1) {
        current[depth] = values[i];
        try generate_sorted_sequences(
            eval_pool,
            values,
            current,
            i,
            depth + 1,
            generated,
            generated_index,
        );
    }
}

fn make_sequence_function(eval_pool: *ValuePool, items: []const Value) Error!Value {
    const len: u32 = @intCast(items.len);
    const entries = try eval_pool.alloc_values(len);
    @memcpy(entries, items);
    const entries_offset = value_offset(eval_pool, entries.ptr);

    const dom = try eval_pool.alloc_values(len);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        dom[i] = Value{ .int_v = @as(i64, @intCast(i + 1)) };
    }
    return Value{ .function_v = .{
        .domain = try make_set(eval_pool, dom),
        .offset = entries_offset,
        .len = len,
    } };
}

fn eval_union_all(eval_pool: *ValuePool, operand: Value) Error!Value {
    if (operand != .set_v) return Error.TypeError;
    const sets = operand.set_v.items(eval_pool);
    var total: u32 = 0;
    for (sets) |s| {
        if (s != .set_v) return Error.TypeError;
        total += s.set_v.len;
    }
    const dest = try eval_pool.alloc_values(total);
    var pos: u32 = 0;
    for (sets) |s| {
        const items = s.set_v.items(eval_pool);
        for (items) |it| {
            var found = false;
            var j: u32 = 0;
            while (j < pos) : (j += 1) {
                if (dest[j].eql(it, eval_pool)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                dest[pos] = it;
                pos += 1;
            }
        }
    }
    return Value{ .set_v = try make_set(eval_pool, dest[0..pos]) };
}

fn eval_subset(eval_pool: *ValuePool, operand: Value) Error!Value {
    if (operand != .set_v) return Error.TypeError;
    const items = operand.set_v.items(eval_pool);
    if (items.len >= 32) {
        std.debug.print("NotImplemented: SUBSET with {d} elements (max 31)\n", .{items.len});
        return Error.NotImplemented;
    }
    const count: u32 = @as(u32, 1) << @intCast(items.len);
    const subset_items: u64 = if (items.len == 0) 0 else @as(u64, count / 2) * items.len;
    try eval_pool.ensure_value_capacity(@as(u64, count) + subset_items);
    const dest = try eval_pool.alloc_values(count);
    for (0..count) |mask| {
        const subset_len = @popCount(mask);
        const sub = try eval_pool.alloc_values(@intCast(subset_len));
        var j: u32 = 0;
        for (items, 0..) |it, k| {
            if (((mask >> @intCast(k)) & 1) == 1) {
                sub[j] = it;
                j += 1;
            }
        }
        dest[mask] = Value{ .set_v = try make_set(eval_pool, sub) };
    }
    return Value{ .set_v = try make_set(eval_pool, dest) };
}

fn make_set(eval_pool: *ValuePool, values: []Value) Error!value.Set {
    var hashes: [65_536]fingerprint.Fingerprint = undefined;
    const use_hashes = values.len <= hashes.len;
    if (!use_hashes) {
        if (values.len > std.math.maxInt(u32)) return Error.OutOfMemory;
        var table_len: usize = 1;
        while (table_len < values.len * 2) table_len *= 2;
        const snapshot = eval_pool.snapshot();
        defer eval_pool.restore(snapshot);
        const alignment_padding = @alignOf(fingerprint.Fingerprint) - 1;
        const hashes_bytes = std.math.mul(
            usize,
            values.len,
            @sizeOf(fingerprint.Fingerprint),
        ) catch return Error.OutOfMemory;
        const table_bytes = std.math.mul(
            usize,
            table_len,
            @sizeOf(u32),
        ) catch return Error.OutOfMemory;
        const scratch_len = std.math.add(
            usize,
            alignment_padding,
            std.math.add(usize, hashes_bytes, table_bytes) catch
                return Error.OutOfMemory,
        ) catch return Error.OutOfMemory;
        if (scratch_len > std.math.maxInt(u32)) return Error.OutOfMemory;
        const scratch = try eval_pool.alloc_scratch_bytes(@intCast(scratch_len));
        const hashes_address = std.mem.alignForward(
            usize,
            @intFromPtr(scratch.ptr),
            @alignOf(fingerprint.Fingerprint),
        );
        const dynamic_hashes_ptr: [*]fingerprint.Fingerprint =
            @ptrFromInt(hashes_address);
        const dynamic_hashes = dynamic_hashes_ptr[0..values.len];
        const table_address = hashes_address + hashes_bytes;
        assert(table_address % @alignOf(u32) == 0);
        const dynamic_table_ptr: [*]u32 = @ptrFromInt(table_address);
        const dynamic_table = dynamic_table_ptr[0..table_len];
        @memset(dynamic_table, 0);

        var unique_len: u32 = 0;
        for (values) |candidate| {
            const candidate_hash = fingerprint.hash_value(
                eval_pool,
                candidate,
                fingerprint.hash_init(),
            );
            var slot = @as(usize, @truncate(candidate_hash)) &
                (table_len - 1);
            var duplicate = false;
            while (dynamic_table[slot] != 0) {
                const existing_index = dynamic_table[slot] - 1;
                if (dynamic_hashes[existing_index] == candidate_hash and
                    (builtin.mode == .fast or
                        values[existing_index].eql(candidate, eval_pool)))
                {
                    duplicate = true;
                    break;
                }
                slot = (slot + 1) & (table_len - 1);
            }
            if (duplicate) continue;
            values[unique_len] = candidate;
            dynamic_hashes[unique_len] = candidate_hash;
            dynamic_table[slot] = unique_len + 1;
            unique_len += 1;
        }
        assert(unique_len <= values.len);
        return value.Set{
            .offset = value_offset(eval_pool, values.ptr),
            .len = unique_len,
        };
    }
    var table: [131_072]u32 = undefined;
    var table_len: usize = 1;
    while (table_len < values.len * 2) table_len *= 2;
    const use_table = use_hashes and values.len >= 32;
    if (use_table) @memset(table[0..table_len], 0);

    var unique_len: u32 = 0;
    for (values) |candidate| {
        const candidate_hash = if (use_hashes)
            fingerprint.hash_value(
                eval_pool,
                candidate,
                fingerprint.hash_init(),
            )
        else
            0;
        var duplicate = false;
        var insert_slot: usize = 0;
        if (use_table) {
            insert_slot = @as(usize, @truncate(candidate_hash)) &
                (table_len - 1);
            while (table[insert_slot] != 0) {
                const existing_index = table[insert_slot] - 1;
                if (hashes[existing_index] == candidate_hash) {
                    if (builtin.mode == .fast or
                        values[existing_index].eql(candidate, eval_pool))
                    {
                        duplicate = true;
                        break;
                    }
                }
                insert_slot = (insert_slot + 1) & (table_len - 1);
            }
        } else {
            for (values[0..unique_len], 0..) |existing, i| {
                if (use_hashes and hashes[i] != candidate_hash) continue;
                if (use_hashes and builtin.mode == .fast) {
                    // TLC also uses 64-bit fingerprints as its identity boundary.
                    // Debug and safe builds retain structural verification so a
                    // collision is observable during development.
                    duplicate = true;
                    break;
                }
                if (existing.eql(candidate, eval_pool)) {
                    duplicate = true;
                    break;
                }
            }
        }
        if (!duplicate) {
            values[unique_len] = candidate;
            if (use_hashes) hashes[unique_len] = candidate_hash;
            if (use_table) table[insert_slot] = unique_len + 1;
            unique_len += 1;
        }
    }
    assert(unique_len <= values.len);
    return value.Set{
        .offset = value_offset(eval_pool, values.ptr),
        .len = unique_len,
    };
}

fn make_tuple(eval_pool: *ValuePool, values: []Value) value.Tuple {
    return .{
        .offset = value_offset(eval_pool, values.ptr),
        .len = @intCast(values.len),
    };
}

fn make_record(eval_pool: *ValuePool, values: []Value) value.Record {
    return .{
        .offset = value_offset(eval_pool, values.ptr),
        .len = @intCast(values.len / 2),
    };
}

fn value_offset(eval_pool: *const ValuePool, ptr: [*]Value) u32 {
    const base = @intFromPtr(eval_pool.values.ptr);
    const addr = @intFromPtr(ptr);
    assert(addr >= base);
    const bytes = addr - base;
    assert(bytes % @sizeOf(Value) == 0);
    const offset: u32 = @intCast(bytes / @sizeOf(Value));
    assert(offset <= eval_pool.value_count);
    return offset;
}

fn collect_application_groups(
    application: *ast.Apply,
    root_name: *[]const u8,
    groups: []ApplicationGroup,
    group_count: *u8,
) bool {
    switch (application.func.*) {
        .ident => |name| root_name.* = name,
        .apply => |parent| {
            if (!collect_application_groups(
                parent,
                root_name,
                groups,
                group_count,
            )) return false;
        },
        else => return false,
    }
    if (group_count.* >= groups.len) return false;
    groups[group_count.*] = .{ .args = application.args };
    group_count.* += 1;
    return true;
}

fn apply_cross_pool(
    evaluator: *const Evaluator,
    function: Value,
    function_pool: *const ValuePool,
    key: Value,
    key_pool: *const ValuePool,
) Error!Value {
    return switch (function) {
        .function_v => |function_v| blk: {
            const keys = function_v.domain.items(function_pool);
            const entries = function_v.entries(function_pool);
            for (keys, entries) |candidate, entry| {
                if (cross_pool_eql(
                    candidate,
                    function_pool,
                    key,
                    key_pool,
                )) break :blk entry;
            }
            return evaluator.fail(
                Error.IndexOutOfBounds,
                "state function application",
                @tagName(key),
            );
        },
        .tuple_v => |tuple| blk: {
            const index = (key.as_int() orelse
                return evaluator.fail(
                    Error.TypeError,
                    "state tuple application",
                    @tagName(key),
                )) - 1;
            if (index < 0 or index >= tuple.len) {
                return evaluator.fail(
                    Error.IndexOutOfBounds,
                    "state tuple application",
                    @tagName(key),
                );
            }
            break :blk tuple.items(function_pool)[@intCast(index)];
        },
        .record_v => |record| blk: {
            if (key != .string_v) {
                return evaluator.fail(
                    Error.TypeError,
                    "state record application",
                    @tagName(key),
                );
            }
            const name = key.string_v.slice(key_pool);
            break :blk record.lookup(function_pool, name) orelse
                return evaluator.fail(
                    Error.UndefinedSymbol,
                    "state record application",
                    name,
                );
        },
        else => evaluator.fail(
            Error.TypeError,
            "state application",
            @tagName(function),
        ),
    };
}

fn cross_pool_eql(
    left: Value,
    left_pool: *const ValuePool,
    right: Value,
    right_pool: *const ValuePool,
) bool {
    return Value.eql_cross_pool(left, left_pool, right, right_pool);
}

/// Try to evaluate an expression to a symbolic set value without materializing
/// its elements.  Used for membership tests (`x \in S`).  Returns null when the
/// expression is not a recognized symbolic-set pattern.
fn eval_symbolic_set(
    self: *const Evaluator,
    expr: *ast.Expr,
    ctx: Context,
    s0: ?*StateStore.State,
    eval_pool: *ValuePool,
    state_pool: *ValuePool,
) Error!?Value {
    switch (expr.*) {
        .ident => {
            const set = try self.eval_expr(expr, ctx, s0, eval_pool, state_pool);
            return if (set.is_set_like()) set else null;
        },
        .set_enum => |items| {
            const dest = try eval_pool.alloc_values(@intCast(items.len));
            for (items, 0..) |item, index| {
                dest[index] = (try eval_symbolic_set(
                    self,
                    item,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                )) orelse try self.eval_expr(
                    item,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
            }
            return Value{ .set_v = try make_set(eval_pool, dest) };
        },
        .set_of_functions => |sf| {
            const domain = (try eval_symbolic_set(
                self,
                sf.domain,
                ctx,
                s0,
                eval_pool,
                state_pool,
            )) orelse try self.eval_expr(
                sf.domain,
                ctx,
                s0,
                eval_pool,
                state_pool,
            );
            const codomain = (try eval_symbolic_set(
                self,
                sf.codomain,
                ctx,
                s0,
                eval_pool,
                state_pool,
            )) orelse try self.eval_expr(
                sf.codomain,
                ctx,
                s0,
                eval_pool,
                state_pool,
            );
            if (!domain.is_set_like() or !codomain.is_set_like()) return null;
            return try make_function_set_value(eval_pool, domain, codomain);
        },
        .record_set => |rs| {
            const dest = try eval_pool.alloc_values(@intCast(rs.fields.len * 2));
            for (rs.fields, 0..) |f, i| {
                const domain = (try eval_symbolic_set(
                    self,
                    f.domain,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                )) orelse try self.eval_expr(
                    f.domain,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                if (!domain.is_set_like()) return null;
                const name = try eval_pool.push_string(f.name);
                dest[i * 2] = Value{ .string_v = name };
                dest[i * 2 + 1] = domain;
            }
            return Value{ .record_set_v = .{
                .offset = value_offset(eval_pool, dest.ptr),
                .len = @intCast(rs.fields.len),
            } };
        },
        .set_filter => |sf| {
            return try eval_symbolic_integer_filter(
                self,
                sf,
                ctx,
                s0,
                eval_pool,
                state_pool,
            );
        },
        .set_binary => |sb| {
            switch (sb.op) {
                .cartesian_op => {
                    const left = (try eval_symbolic_set(
                        self,
                        sb.left,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    )) orelse try self.eval_expr(
                        sb.left,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                    const right = (try eval_symbolic_set(
                        self,
                        sb.right,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    )) orelse try self.eval_expr(
                        sb.right,
                        ctx,
                        s0,
                        eval_pool,
                        state_pool,
                    );
                    if (!left.is_set_like() or !right.is_set_like()) return null;
                    // Flatten: if left is a tuple_set_v, extend it with right.
                    if (left == .tuple_set_v) {
                        const ts = left.tuple_set_v;
                        const ss = ts.sets(eval_pool);
                        const dest = try eval_pool.alloc_values(@intCast(ss.len + 1));
                        @memcpy(dest[0..ss.len], ss);
                        dest[ss.len] = right;
                        return Value{ .tuple_set_v = .{
                            .offset = value_offset(eval_pool, dest.ptr),
                            .len = @intCast(ss.len + 1),
                        } };
                    }
                    const dest = try eval_pool.alloc_values(2);
                    dest[0] = left;
                    dest[1] = right;
                    return Value{ .tuple_set_v = .{
                        .offset = value_offset(eval_pool, dest.ptr),
                        .len = 2,
                    } };
                },
                .union_op => {
                    const left = try eval_symbolic_set(self, sb.left, ctx, s0, eval_pool, state_pool);
                    const right = try eval_symbolic_set(self, sb.right, ctx, s0, eval_pool, state_pool);
                    if (left == null or right == null) return null;
                    if (left.? == .set_v and right.? == .set_v) return null;
                    return try make_binary_set_value(eval_pool, .cup_v, left.?, right.?);
                },
                .intersection_op => {
                    const left = try eval_symbolic_set(self, sb.left, ctx, s0, eval_pool, state_pool);
                    const right = try eval_symbolic_set(self, sb.right, ctx, s0, eval_pool, state_pool);
                    if (left == null or right == null) return null;
                    if (left.? == .set_v and right.? == .set_v) return null;
                    return try make_binary_set_value(eval_pool, .cap_v, left.?, right.?);
                },
                .difference_op => {
                    const left = try eval_symbolic_set(self, sb.left, ctx, s0, eval_pool, state_pool);
                    const right = try eval_symbolic_set(self, sb.right, ctx, s0, eval_pool, state_pool);
                    if (left == null or right == null) return null;
                    if (left.? == .set_v and right.? == .set_v) return null;
                    return try make_binary_set_value(eval_pool, .diff_v, left.?, right.?);
                },
            }
        },
        .unary => |u| {
            if (u.op == .subset) {
                const base = (try eval_symbolic_set(
                    self,
                    u.operand,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                )) orelse try self.eval_expr(
                    u.operand,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                );
                if (!base.is_set_like()) return null;
                return Value{ .power_set_v = .{
                    .set_offset = try eval_pool.push_value(base),
                } };
            }
            if (u.op != .union_all) return null;
            if (try eval_symbolic_set(self, u.operand, ctx, s0, eval_pool, state_pool)) |inner| {
                return try make_union_value(eval_pool, inner);
            }
            const set = try self.eval_expr(u.operand, ctx, s0, eval_pool, state_pool);
            if (!set.is_set_like()) return null;
            return try make_union_value(eval_pool, set);
        },
        .set_map => |sm| {
            // Recognize { [1..n -> S] : n \in Domain } as a sequence set.
            const maybe_seq = try eval_symbolic_seq_map(self, sm, ctx, s0, eval_pool, state_pool);
            if (maybe_seq) |sv| return sv;
            return null;
        },
        .apply => |ap| {
            if (ap.func.* != .ident) return null;
            const name = self.resolve_alias(ap.func.*.ident);
            if (std.mem.eql(u8, name, "Seq") and ap.args.len == 1) {
                const arg = try self.eval_expr(ap.args[0], ctx, s0, eval_pool, state_pool);
                if (!arg.is_set_like()) return null;
                return try make_sequence_set_value(eval_pool, arg);
            }
            if (self.find_definition(name)) |def| {
                if (def.params.len != ap.args.len) return null;
                var argument_storage: [64]Value = undefined;
                const values = try self.eval_application_arguments(
                    ap.args,
                    ctx,
                    s0,
                    eval_pool,
                    state_pool,
                    &argument_storage,
                );
                var new_ctx = ctx.operator_frame();
                for (def.params, 0..) |p, i| {
                    new_ctx = try self.extend_context(new_ctx, p, values[i]);
                }
                return try eval_symbolic_set(self, def.body, new_ctx, s0, eval_pool, state_pool);
            }
            return null;
        },
        .binary => |b2| {
            if (b2.op != .range) return null;
            const lo = try self.eval_expr(b2.left, ctx, s0, eval_pool, state_pool);
            const hi = try self.eval_expr(b2.right, ctx, s0, eval_pool, state_pool);
            if (lo != .int_v or hi != .int_v) return null;
            if (hi.int_v < lo.int_v) return Value{ .set_v = .{ .offset = 0, .len = 0 } };
            const count: u32 = @intCast(hi.int_v - lo.int_v + 1);
            const dest = try eval_pool.alloc_values(count);
            var i: i64 = lo.int_v;
            for (dest) |*slot| {
                slot.* = Value{ .int_v = i };
                i += 1;
            }
            return Value{ .set_v = .{ .offset = value_offset(eval_pool, dest.ptr), .len = count } };
        },
        else => return null,
    }
}

fn eval_symbolic_integer_filter(
    self: *const Evaluator,
    filter: *ast.SetFilter,
    ctx: Context,
    s0: ?*StateStore.State,
    eval_pool: *ValuePool,
    state_pool: *ValuePool,
) Error!?Value {
    if (filter.vars.len != 1) return null;
    const bound = filter.vars[0];
    const domain = (try eval_symbolic_set(
        self,
        bound.domain,
        ctx,
        s0,
        eval_pool,
        state_pool,
    )) orelse return null;
    if (domain != .range_v) return null;

    var range = domain.range_v;
    if (!try apply_symbolic_integer_bounds(
        self,
        filter.pred,
        bound.name,
        ctx,
        s0,
        eval_pool,
        state_pool,
        &range.lo,
        &range.hi,
    )) return null;
    return Value{ .range_v = range };
}

fn apply_symbolic_integer_bounds(
    self: *const Evaluator,
    predicate: *ast.Expr,
    variable_name: []const u8,
    ctx: Context,
    s0: ?*StateStore.State,
    eval_pool: *ValuePool,
    state_pool: *ValuePool,
    lo: *i64,
    hi: *i64,
) Error!bool {
    if (predicate.* != .binary) return false;
    const binary = predicate.binary;
    if (binary.op == .and_op) {
        return try apply_symbolic_integer_bounds(
            self,
            binary.left,
            variable_name,
            ctx,
            s0,
            eval_pool,
            state_pool,
            lo,
            hi,
        ) and try apply_symbolic_integer_bounds(
            self,
            binary.right,
            variable_name,
            ctx,
            s0,
            eval_pool,
            state_pool,
            lo,
            hi,
        );
    }

    const variable_on_left = binary.left.* == .ident and
        std.mem.eql(u8, binary.left.ident, variable_name);
    const variable_on_right = binary.right.* == .ident and
        std.mem.eql(u8, binary.right.ident, variable_name);
    if (variable_on_left == variable_on_right) return false;
    const constant_expr = if (variable_on_left) binary.right else binary.left;
    const constant = try self.eval_expr(
        constant_expr,
        ctx,
        s0,
        eval_pool,
        state_pool,
    );
    if (constant != .int_v) return false;

    const op = if (variable_on_left) binary.op else switch (binary.op) {
        .lt => ast.BinaryOp.gt,
        .le => ast.BinaryOp.ge,
        .gt => ast.BinaryOp.lt,
        .ge => ast.BinaryOp.le,
        else => binary.op,
    };
    const threshold = constant.int_v;
    switch (op) {
        .eq => {
            lo.* = @max(lo.*, threshold);
            hi.* = @min(hi.*, threshold);
        },
        .gt => lo.* = @max(lo.*, std.math.add(i64, threshold, 1) catch return false),
        .ge => lo.* = @max(lo.*, threshold),
        .lt => hi.* = @min(hi.*, std.math.sub(i64, threshold, 1) catch return false),
        .le => hi.* = @min(hi.*, threshold),
        else => return false,
    }
    return true;
}

fn make_function_set_value(eval_pool: *ValuePool, domain: Value, codomain: Value) Error!Value {
    assert(domain.is_set_like());
    assert(codomain.is_set_like());
    const dom_offset = try eval_pool.push_value(domain);
    const cod_offset = try eval_pool.push_value(codomain);
    return Value{ .function_set_v = .{ .domain_offset = dom_offset, .codomain_offset = cod_offset } };
}

fn make_sequence_set_value(eval_pool: *ValuePool, element_set: Value) Error!Value {
    assert(element_set.is_set_like());
    return Value{ .seq_set_v = .{
        .element_set_offset = try eval_pool.push_value(element_set),
    } };
}

fn make_binary_set_value(eval_pool: *ValuePool, tag: value.ValueTag, left: Value, right: Value) Error!Value {
    assert(left.is_set_like());
    assert(right.is_set_like());
    const lo = try eval_pool.push_value(left);
    const ro = try eval_pool.push_value(right);
    return switch (tag) {
        .cup_v => Value{ .cup_v = .{ .left_offset = lo, .right_offset = ro } },
        .cap_v => Value{ .cap_v = .{ .left_offset = lo, .right_offset = ro } },
        .diff_v => Value{ .diff_v = .{ .left_offset = lo, .right_offset = ro } },
        else => unreachable,
    };
}

fn make_seq_set_value(eval_pool: *ValuePool, value_set: Value, max_len: u32) Error!Value {
    assert(value_set.is_set_like());
    if (max_len == 0) {
        const empty_set = try eval_pool.push_value(Value{ .set_v = .{ .offset = 0, .len = 0 } });
        return Value{ .union_v = .{ .set_offset = @intCast(empty_set) } };
    }
    const slots = try eval_pool.alloc_values(@intCast(max_len + 1));
    var n: i64 = 0;
    for (slots) |*slot| {
        const dom = try eval_pool.alloc_values(@intCast(n));
        var i: i64 = 1;
        for (dom) |*d| {
            d.* = Value{ .int_v = i };
            i += 1;
        }
        slot.* = try make_function_set_value(
            eval_pool,
            Value{ .set_v = .{ .offset = value_offset(eval_pool, dom.ptr), .len = @intCast(n) } },
            value_set,
        );
        n += 1;
    }
    const union_set = Value{ .set_v = .{ .offset = value_offset(eval_pool, slots.ptr), .len = @intCast(slots.len) } };
    return Value{ .union_v = .{ .set_offset = try eval_pool.push_value(union_set) } };
}

fn make_union_value(eval_pool: *ValuePool, set: Value) Error!Value {
    assert(set.is_set_like());
    return Value{ .union_v = .{ .set_offset = try eval_pool.push_value(set) } };
}

fn eval_symbolic_seq_map(
    self: *const Evaluator,
    sm: *ast.SetMap,
    ctx: Context,
    s0: ?*StateStore.State,
    eval_pool: *ValuePool,
    state_pool: *ValuePool,
) Error!?Value {
    const shape = sequence_patterns.bounded_sequence_map(sm) orelse
        return null;

    const codomain = try self.eval_expr(
        @constCast(shape.element_set),
        ctx,
        s0,
        eval_pool,
        state_pool,
    );
    if (!codomain.is_set_like()) return null;

    const domain = try self.eval_expr(
        @constCast(shape.lengths),
        ctx,
        s0,
        eval_pool,
        state_pool,
    );
    if (!domain.is_set_like()) return null;

    const slots = switch (domain) {
        .set_v => |s| blk: {
            const vals = s.items(eval_pool);
            const dest = try eval_pool.alloc_values(@intCast(vals.len));
            for (vals, 0..) |v, i| {
                if (v != .int_v or v.int_v < 0) return null;
                dest[i] = try make_symbolic_function_set(eval_pool, @intCast(v.int_v), codomain);
            }
            break :blk dest;
        },
        .range_v => |r| blk: {
            if (r.lo < 0 or r.hi < r.lo) return null;
            const len: u32 = @intCast(r.hi - r.lo + 1);
            const dest = try eval_pool.alloc_values(len);
            var v: i64 = r.lo;
            for (0..len) |i| {
                if (v < 0) return null;
                dest[i] = try make_symbolic_function_set(eval_pool, @intCast(v), codomain);
                v += 1;
            }
            break :blk dest;
        },
        else => return null,
    };

    return Value{ .set_v = .{ .offset = value_offset(eval_pool, slots.ptr), .len = @intCast(slots.len) } };
}

fn make_symbolic_function_set(eval_pool: *ValuePool, n: u32, codomain: Value) error{OutOfMemory}!Value {
    const dom = try eval_pool.alloc_values(n);
    var k: i64 = 1;
    for (dom) |*d| {
        d.* = Value{ .int_v = k };
        k += 1;
    }
    const domain_set = Value{ .set_v = .{ .offset = value_offset(eval_pool, dom.ptr), .len = n } };
    return Value{ .function_set_v = .{
        .domain_offset = try eval_pool.push_value(domain_set),
        .codomain_offset = try eval_pool.push_value(codomain),
    } };
}

fn test_eager_cache_dependency(
    context: *generated_runtime.CallContext,
    args: []const Value,
) Error!Value {
    assert(args.len == 0);
    if (try generated_runtime.cached_definition(context, 0)) |cached| {
        return cached;
    }
    const offset = try context.eval_pool.push_values(&.{.{ .int_v = 1 }});
    const result = Value{ .tuple_v = .{ .offset = offset, .len = 1 } };
    return generated_runtime.put_cached_definition(context, 0, result);
}

fn test_eager_cache_root(
    context: *generated_runtime.CallContext,
    args: []const Value,
) Error!Value {
    assert(args.len == 0);
    if (try generated_runtime.cached_definition(context, 1)) |cached| {
        return cached;
    }
    _ = try test_eager_cache_dependency(context, &.{});
    const items = try context.eval_pool.alloc_values(
        generated_cache_entry_value_budget,
    );
    @memset(items, Value{ .int_v = 1 });
    const result = Value{ .tuple_v = .{
        .offset = @intCast((@intFromPtr(items.ptr) -
            @intFromPtr(context.eval_pool.values.ptr)) / @sizeOf(Value)),
        .len = @intCast(items.len),
    } };
    return generated_runtime.put_cached_definition(context, 1, result);
}

fn test_eager_cache_large_string(
    context: *generated_runtime.CallContext,
    args: []const Value,
) Error!Value {
    assert(args.len == 0);
    if (try generated_runtime.cached_definition(context, 0)) |cached| {
        return cached;
    }
    var bytes: [5000]u8 = undefined;
    @memset(&bytes, 'x');
    const result = Value{
        .string_v = try context.eval_pool.push_string(&bytes),
    };
    return generated_runtime.put_cached_definition(context, 0, result);
}

test "eager cache admits entries larger than four kibibytes" {
    const parser = @import("parser.zig");
    const source =
        \\---------------------- MODULE CacheCapacity ----------------------
        \\Root == "placeholder"
        \\==================================================================
        \\
    ;
    var arena = try Arena.init(8 * 1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    const module = try module_parser.parse_module();
    const generated = [_]generated_runtime.Operator{.{
        .name = "Root",
        .arity = 0,
        .function = test_eager_cache_large_string,
        .cacheable = true,
        .eager_cache = true,
        .cache_index = 0,
    }};
    var evaluator = try Evaluator.init_generated(
        module,
        &arena,
        overrides.OverrideContext.default(),
        &generated,
        &.{},
    );
    var eval_pool = try ValuePool.init(&arena, 64, 8192);
    var state_pool = try ValuePool.init(&arena, 64, 64);

    evaluator.warm_eager_generated_cache(&eval_pool, &state_pool);

    const cached = evaluator.generated_cache[0].?;
    try std.testing.expectEqual(@as(u32, 5000), cached.string_v.len);
    try std.testing.expectEqual(
        @as(u32, 5000),
        evaluator.generated_cache_pool.string_count,
    );
}

test "rejected eager cache admission rolls back dependency slots" {
    const parser = @import("parser.zig");
    const source =
        \\---------------------- MODULE CacheRollback ----------------------
        \\Dependency == <<1>>
        \\Root == <<1>>
        \\==================================================================
        \\
    ;
    var arena = try Arena.init(8 * 1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    const module = try module_parser.parse_module();
    const generated = [_]generated_runtime.Operator{
        .{
            .name = "Dependency",
            .arity = 0,
            .function = test_eager_cache_dependency,
            .cacheable = true,
            .cache_index = 0,
        },
        .{
            .name = "Root",
            .arity = 0,
            .function = test_eager_cache_root,
            .cacheable = true,
            .eager_cache = true,
            .cache_index = 1,
        },
    };
    var evaluator = try Evaluator.init_generated(
        module,
        &arena,
        overrides.OverrideContext.default(),
        &generated,
        &.{},
    );
    var eval_pool = try ValuePool.init(
        &arena,
        generated_cache_entry_value_budget + 2,
        64,
    );
    var state_pool = try ValuePool.init(&arena, 64, 64);
    const cache_snapshot = evaluator.generated_cache_pool.snapshot();

    evaluator.warm_eager_generated_cache(&eval_pool, &state_pool);

    try std.testing.expectEqual(cache_snapshot, evaluator.generated_cache_pool.snapshot());
    try std.testing.expectEqual(@as(?Value, null), evaluator.generated_cache[0]);
    try std.testing.expectEqual(@as(?Value, null), evaluator.generated_cache[1]);
}

test "state call memo resets with generations" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var argument_pool = try ValuePool.init(&arena, 64, 64);
    var memo_pool = try ValuePool.init(&arena, 64, 64);
    var memo = StateCallMemo{};
    const arguments = [_]Value{.{ .int_v = 7 }};
    const expected = Value{ .int_v = 11 };

    memo.reset(&memo_pool);
    try memo.put(
        "F",
        &arguments,
        &argument_pool,
        1,
        2,
        expected,
    );
    try std.testing.expectEqual(
        expected,
        memo.get("F", &arguments, &argument_pool, 1, 2).?,
    );

    const previous_generation = memo.generation;
    memo_pool.restore(.{
        .value_count = 0,
        .string_count = 0,
        .string_intern_count = 0,
    });
    memo.reset(&memo_pool);
    try std.testing.expect(memo.generation != previous_generation);
    try std.testing.expectEqual(
        @as(?Value, null),
        memo.get("F", &arguments, &argument_pool, 1, 2),
    );
}

test "state call memo bypasses nested operator arguments" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var argument_pool = try ValuePool.init(&arena, 64, 64);
    var memo_pool = try ValuePool.init(&arena, 64, 64);
    var body: u8 = 0;
    var context: u8 = 0;
    var lambda = value.Lambda{
        .params = &.{},
        .body = &body,
        .ctx = &context,
    };
    const tuple_offset = try argument_pool.push_values(&.{
        Value{ .int_v = 7 },
        Value{ .lambda_v = &lambda },
    });
    const arguments = [_]Value{.{ .tuple_v = .{
        .offset = tuple_offset,
        .len = 2,
    } }};
    var memo = StateCallMemo{};

    memo.reset(&memo_pool);
    try std.testing.expectEqual(
        @as(?Value, null),
        memo.get("F", &arguments, &argument_pool, 1, 2),
    );
    try std.testing.expectError(
        error.NotImplemented,
        memo.put(
            "F",
            &arguments,
            &argument_pool,
            1,
            2,
            Value{ .int_v = 11 },
        ),
    );
    try std.testing.expectEqual(@as(u16, 0), memo.count);
    try std.testing.expectEqual(@as(u32, 0), memo_pool.value_count);
}

test "state call memo bypasses expensive aggregate arguments" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var argument_pool = try ValuePool.init(&arena, 128, 64);
    var memo_pool = try ValuePool.init(&arena, 64, 64);
    const domain_items = try argument_pool.alloc_values(16);
    const entries = try argument_pool.alloc_values(16);
    for (domain_items, entries, 0..) |*domain_item, *entry, index| {
        domain_item.* = .{ .int_v = @intCast(index + 1) };
        entry.* = .{ .bool_v = index % 2 == 0 };
    }
    const arguments = [_]Value{.{ .function_v = .{
        .domain = .{
            .offset = value_offset(&argument_pool, domain_items.ptr),
            .len = @intCast(domain_items.len),
        },
        .offset = value_offset(&argument_pool, entries.ptr),
        .len = @intCast(entries.len),
    } }};
    var memo = StateCallMemo{};

    memo.reset(&memo_pool);
    try std.testing.expectEqual(
        @as(?Value, null),
        memo.get("F", &arguments, &argument_pool, 1, 2),
    );
    try std.testing.expectError(
        error.NotImplemented,
        memo.put(
            "F",
            &arguments,
            &argument_pool,
            1,
            2,
            Value{ .int_v = 11 },
        ),
    );
    try std.testing.expectEqual(@as(u16, 0), memo.count);
    try std.testing.expectEqual(@as(u32, 0), memo_pool.value_count);
}

test "pointwise function predicate requires access by bound key" {
    const parser = @import("parser.zig");
    const source =
        \\---------------------- MODULE Pointwise ----------------------
        \\CONSTANTS D, C
        \\Good == {f \in [D -> C] : \A x \in D : f[x] = x}
        \\Bad == {f \in [D -> C] : \A x \in D : f["other"] = x}
        \\==============================================================
        \\
    ;
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var module_parser = parser.Parser.init(&arena, source);
    const module = try module_parser.parse_module();
    try std.testing.expectEqual(@as(usize, 2), module.definitions.len);

    const good = module.definitions[0].body.set_filter;
    const good_quantifier = good.pred.quantifier;
    try std.testing.expect(is_pointwise_function_predicate(
        good_quantifier.body,
        good.vars[0].name,
        good_quantifier.vars[0].name,
    ));

    const bad = module.definitions[1].body.set_filter;
    const bad_quantifier = bad.pred.quantifier;
    try std.testing.expect(!is_pointwise_function_predicate(
        bad_quantifier.body,
        bad.vars[0].name,
        bad_quantifier.vars[0].name,
    ));
}

test "generated expression availability ignores unused captures" {
    var arena = try Arena.init(4096);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 16, 64);
    var binding = ContextBinding{
        .parent = null,
        .name = "used",
        .value = .{ .int_v = 7 },
    };
    const context = Context{
        .head = &binding,
        .state = null,
        .local_floor = null,
        .len = 1,
    };
    var values: [2]Value = undefined;

    try std.testing.expect(try context.lookup_required_values_if_available(
        &.{ "used", "unused" },
        &.{ true, false },
        &values,
        &pool,
    ));
    try std.testing.expectEqual(Value{ .int_v = 7 }, values[0]);
    try std.testing.expectEqual(Value{ .bool_v = false }, values[1]);
    try std.testing.expect(!try context.lookup_required_values_if_available(
        &.{ "used", "missing" },
        &.{ true, true },
        &values,
        &pool,
    ));

    try context.lookup_values(
        &.{ "unused", "used" },
        &.{ false, true },
        &values,
        &pool,
    );
    try std.testing.expectEqual(Value{ .bool_v = false }, values[0]);
    try std.testing.expectEqual(Value{ .int_v = 7 }, values[1]);
}

test "generated calls retain partial assignments for deferred arguments" {
    const primed_reference = try generated_runtime.state_reference(0, true);

    try std.testing.expect(generated_call_uses_partial_values(
        false,
        &.{primed_reference},
    ));
    try std.testing.expect(generated_call_uses_partial_values(true, &.{}));
    try std.testing.expect(!generated_call_uses_partial_values(
        false,
        &.{.{ .int_v = 1 }},
    ));
}

test "state bindings preserve local stack lookup and lexical shadowing" {
    var arena = try Arena.init(4096);
    defer arena.deinit();
    var contexts = try ContextPool.init(&arena);
    var pool = try ValuePool.init(&arena, 16, 64);

    var context = try contexts.extend_local(
        Context.empty(),
        "x",
        .{ .int_v = 7 },
    );
    context = try contexts.extend_local(
        context,
        "y",
        .{ .int_v = 11 },
    );
    context = try contexts.extend_state(
        context,
        "x",
        0,
        .{ .int_v = 99 },
        null,
        .changed,
    );

    var values: [2]Value = undefined;
    try std.testing.expect(try context.lookup_all_values(
        &.{ "x", "y" },
        &values,
        &pool,
    ));
    try std.testing.expectEqual(Value{ .int_v = 7 }, values[0]);
    try std.testing.expectEqual(Value{ .int_v = 11 }, values[1]);
    try std.testing.expectEqual(
        Value{ .int_v = 7 },
        (try context.lookup_value("x", &pool)).?,
    );
    const state_value = context.lookup_state(0).?;
    try std.testing.expectEqual(Value{ .int_v = 99 }, state_value.value);
    try std.testing.expectEqual(AssignmentKind.changed, state_value.assignment);
}

test "state context trail restores bounded slots" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Context));

    var arena = try Arena.init(4096);
    defer arena.deinit();
    var contexts = try ContextPool.init(&arena);
    const root = contexts.snapshot();

    const x_context = try contexts.extend_state(
        Context.empty(),
        "x",
        0,
        .{ .int_v = 7 },
        null,
        .changed,
    );
    try std.testing.expectError(Error.TypeError, contexts.extend_state(
        x_context,
        "x",
        0,
        .{ .int_v = 8 },
        null,
        .changed,
    ));
    const previous_floor = contexts.pin();
    const xy_context = try contexts.extend_state(
        x_context,
        "y",
        1,
        .{ .int_v = 11 },
        null,
        .unchanged,
    );
    try std.testing.expectEqual(@as(u8, 2), xy_context.state.?.count);
    try std.testing.expectEqual(Value{ .int_v = 7 }, xy_context.lookup_state(0).?.value);
    try std.testing.expectEqual(Value{ .int_v = 11 }, xy_context.lookup_state(1).?.value);

    contexts.restore(root);
    try std.testing.expectEqual(@as(u8, 1), x_context.state.?.count);
    try std.testing.expectEqual(Value{ .int_v = 7 }, x_context.lookup_state(0).?.value);
    try std.testing.expectEqual(@as(?StateContextValue, null), x_context.lookup_state(1));

    contexts.unpin(previous_floor);
    contexts.restore(root);
    try std.testing.expectEqual(@as(u8, 0), x_context.state.?.count);
    try std.testing.expectEqual(@as(?StateContextValue, null), x_context.lookup_state(0));
}

test "large sets deduplicate without quadratic fallback" {
    var arena = try Arena.init(8 * 1024 * 1024);
    defer arena.deinit();
    var pool = try ValuePool.init(&arena, 70_000, 64);
    const items = try pool.alloc_values(65_538);
    for (items, 0..) |*item, index| {
        item.* = .{ .int_v = @intCast(index % 65_537) };
    }

    const result = try make_set(&pool, items);
    try std.testing.expectEqual(@as(u32, 65_537), result.len);
    try std.testing.expect(result.contains(&pool, .{ .int_v = 0 }));
    try std.testing.expect(result.contains(&pool, .{ .int_v = 65_536 }));
}
