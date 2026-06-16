const std = @import("std");
const assert = std.debug.assert;
const Arena = @import("arena.zig").Arena;
const ast = @import("ast.zig");
const eval = @import("eval.zig");
const Context = eval.Context;
const Evaluator = eval.Evaluator;
const action = @import("action.zig");
const ActionCompiler = action.ActionCompiler;
const ActionExecutor = action.ActionExecutor;
const StateStore = @import("state.zig").StateStore;
const StateQueue = @import("queue.zig").StateQueue;
const FpSet = @import("fp_set.zig").FpSet;
const fingerprint = @import("fingerprint.zig");
const ValuePool = @import("value.zig").ValuePool;
const Value = @import("value.zig").Value;
const Error = @import("err.zig").Error;
const Config = @import("config.zig").Config;
const ConstantAssignment = @import("config.zig").ConstantAssignment;
const Constant = eval.Constant;
const parser = @import("parser.zig");
const overrides = @import("overrides.zig");

pub const FairnessCondition = struct {
    kind: enum { weak, strong },
    action: *ast.Expr,
    vars: *ast.Expr,
};

fn starts_with(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and std.mem.eql(u8, haystack[0..needle.len], needle);
}

pub const Checker = struct {
    arena: *Arena,
    state_store: StateStore,
    queue: StateQueue,
    fp_set: FpSet,
    evaluator: Evaluator,
    init_spec: action.CompiledInit,
    next_spec: action.CompiledNext,
    invariants: []const *ast.Expr,
    invariant_names: []const []const u8,
    constraints: []const *ast.Expr,
    properties: []const *ast.Expr,
    safety_properties: []const *ast.Expr,
    eval_arena: *Arena,
    eval_pool: ValuePool,
    max_states: u32,
    generated: u64,
    distinct: u64,
    // Transition graph for liveness/property checking.
    succ_offsets: []u32,
    succ_edges: []u32,
    succ_count: u32,
    succ_cap: u32,
    // We record total allocated max_states for successor arrays because the
    // graph is built on at most max_states distinct states.  Some consumers
    // assume `idx < distinct`; callers must keep successor indices within this
    // bound, but we assert it defensively.
    max_states_limit: u32,
    // Fairness conditions extracted from the specification formula.
    fairness: []const FairnessCondition,

    pub fn init(
        arena: *Arena,
        module: ast.Module,
        cfg: Config,
        max_states: u32,
        eval_value_cap: u32,
        eval_string_cap: u32,
        state_value_cap: u32,
        state_string_cap: u32,
        eval_arena_bytes: u64,
        override_ctx: overrides.OverrideContext,
    ) !Checker {
        var state_store = try StateStore.init(
            arena,
            module.variables,
            max_states,
            state_value_cap,
            state_string_cap,
        );
        const queue = try StateQueue.init(arena, max_states);
        const fp_set = try FpSet.init(arena, max_states * 2);
        var evaluator = try Evaluator.init(module, arena, override_ctx);
        evaluator.set_treat_unknown_as_model(true);
        const aliases = try evaluate_aliases(arena, cfg);
        evaluator.set_aliases(aliases);
        const constants = try evaluate_constants(arena, cfg, &evaluator, &state_store.values_pool);
        evaluator.set_constants(constants);
        evaluator.set_treat_unknown_as_model(false);
        const compiler = ActionCompiler.init(arena, evaluator);

        const spec_name_v: ?[]const u8 = cfg.spec_name orelse find_spec_name(module);
        const init_name_v: []const u8 = blk: {
            if (cfg.init_name) |n| break :blk n;
            if (spec_name_v) |sn| {
                if (extract_spec_names(module, sn)) |snames| break :blk snames.init else |_| {}
            }
            break :blk find_init_name(module) orelse find_def_fallback(module, &.{ "Init", "Initial", "InitialState" }) orelse {
                return Error.ConfigError;
            };
        };
        const next_name_v: []const u8 = blk: {
            if (cfg.next_name) |n| break :blk n;
            if (spec_name_v) |sn| {
                if (extract_spec_names(module, sn)) |snames| break :blk snames.next else |_| {}
            }
            break :blk find_next_name(module) orelse find_def_fallback(module, &.{ "Next", "Step" }) orelse {
                return Error.ConfigError;
            };
        };

        const init_def = evaluator.find_definition(init_name_v) orelse {
            std.debug.print("undefined init def: {s}\n", .{init_name_v});
            return Error.UndefinedSymbol;
        };
        const next_def = evaluator.find_definition(next_name_v) orelse {
            std.debug.print("undefined next def: {s}\n", .{next_name_v});
            return Error.UndefinedSymbol;
        };

        const compiled_init = try compiler.compile_init(init_def.body);
        const compiled_next = try compiler.compile_next(next_def.body);

        var invariant_exprs = std.ArrayList(*ast.Expr).empty;
        defer invariant_exprs.deinit(std.heap.page_allocator);
        for (cfg.invariants) |inv_name| {
            const def = evaluator.find_definition(inv_name) orelse {
                std.debug.print("undefined invariant: {s}\n", .{inv_name});
                return Error.UndefinedSymbol;
            };
            try invariant_exprs.append(std.heap.page_allocator, def.body);
        }

        const invariant_names: []const []const u8 = cfg.invariants;

        const invariants: []const *ast.Expr = if (invariant_exprs.items.len == 0) &[_]*ast.Expr{} else blk: {
            const result = try arena.alloc(*ast.Expr, invariant_exprs.items.len);
            for (invariant_exprs.items, 0..) |inv, i| {
                result[i] = inv;
            }
            break :blk result;
        };

        var constraint_exprs = std.ArrayList(*ast.Expr).empty;
        defer constraint_exprs.deinit(std.heap.page_allocator);
        for (cfg.constraints) |cname| {
            const def = evaluator.find_definition(cname) orelse {
                std.debug.print("undefined constraint: {s}\n", .{cname});
                return Error.UndefinedSymbol;
            };
            try constraint_exprs.append(std.heap.page_allocator, def.body);
        }
        const constraints: []const *ast.Expr = if (constraint_exprs.items.len == 0) &[_]*ast.Expr{} else blk: {
            const result = try arena.alloc(*ast.Expr, constraint_exprs.items.len);
            for (constraint_exprs.items, 0..) |c, i| {
                result[i] = c;
            }
            break :blk result;
        };

        var property_exprs = std.ArrayList(*ast.Expr).empty;
        defer property_exprs.deinit(std.heap.page_allocator);
        var safety_property_exprs = std.ArrayList(*ast.Expr).empty;
        defer safety_property_exprs.deinit(std.heap.page_allocator);
        for (cfg.properties) |pname| {
            const def = evaluator.find_definition(pname) orelse {
                std.debug.print("undefined property: {s}\n", .{pname});
                return Error.UndefinedSymbol;
            };
            if (classify_temporal(def.body) == .safety) {
                try safety_property_exprs.append(std.heap.page_allocator, def.body);
            } else {
                try property_exprs.append(std.heap.page_allocator, def.body);
            }
        }
        const properties: []const *ast.Expr = if (property_exprs.items.len == 0) &[_]*ast.Expr{} else blk: {
            const result = try arena.alloc(*ast.Expr, property_exprs.items.len);
            for (property_exprs.items, 0..) |p, i| {
                result[i] = p;
            }
            break :blk result;
        };
        const safety_properties: []const *ast.Expr = if (safety_property_exprs.items.len == 0) &[_]*ast.Expr{} else blk: {
            const result = try arena.alloc(*ast.Expr, safety_property_exprs.items.len);
            for (safety_property_exprs.items, 0..) |p, i| {
                result[i] = p;
            }
            break :blk result;
        };

        const eval_arena = try arena.alloc_object(Arena);
        eval_arena.* = try Arena.init(eval_arena_bytes);
        const eval_pool = try ValuePool.init(eval_arena, eval_value_cap, eval_string_cap);

        const succ_cap: u32 = max_states * 32;
        const succ_offsets = try arena.alloc(u32, max_states + 1);
        @memset(succ_offsets, 0);
        const succ_edges = try arena.alloc(u32, succ_cap);

        const fairness = if (spec_name_v) |sn| try extract_fairness(arena, module, sn) else &[_]FairnessCondition{};

        return Checker{
            .arena = arena,
            .state_store = state_store,
            .queue = queue,
            .fp_set = fp_set,
            .evaluator = evaluator,
            .init_spec = compiled_init,
            .next_spec = compiled_next,
            .invariants = invariants,
            .invariant_names = invariant_names,
            .constraints = constraints,
            .properties = properties,
            .safety_properties = safety_properties,
            .eval_arena = eval_arena,
            .eval_pool = eval_pool,
            .max_states = max_states,
            .generated = 0,
            .distinct = 0,
            .succ_offsets = succ_offsets,
            .succ_edges = succ_edges,
            .succ_count = 0,
            .succ_cap = succ_cap,
            .max_states_limit = max_states,
            .fairness = fairness,
        };
    }

    pub fn deinit(self: *Checker) void {
        self.eval_arena.deinit();
    }

    pub fn check(self: *Checker) !Result {
        var out_states = std.ArrayList(u32).empty;
        defer out_states.deinit(std.heap.page_allocator);

        var executor = ActionExecutor{
            .evaluator = self.evaluator,
            .state_store = &self.state_store,
            .eval_pool = &self.eval_pool,
        };

        try executor.execute_init(self.init_spec, &out_states);
        try self.process_generated(null, &out_states);

        while (self.queue.dequeue()) |idx| {
            assert(idx < self.state_store.count);
            assert(idx < self.max_states_limit);
            out_states.clearRetainingCapacity();
            self.succ_offsets[idx] = self.succ_count;
            self.eval_pool.restore(self.eval_pool.snapshot());
            try executor.execute_next(self.next_spec, idx, &out_states);
            self.eval_pool.restore(self.eval_pool.snapshot());
            try self.process_generated(idx, &out_states);
        }

        // After exhaustive safety checking, verify temporal PROPERTIES.
        if (self.properties.len > 0) {
            try self.check_properties();
        }

        return Result{
            .generated = self.generated,
            .distinct = self.distinct,
            .error_state = null,
        };
    }

    fn process_generated(self: *Checker, parent_idx: ?u32, out_states: *std.ArrayList(u32)) !void {
        // First pass: check constraints/invariants, canonicalize duplicates,
        // and enqueue newly discovered states. After this loop, out_states
        // contains canonical indices for graph edges.
        var kept_count: u32 = 0;
        for (out_states.items) |*idx| {
            assert(idx.* < self.state_store.count);
            self.generated += 1;
            const st = self.state_store.get(idx.*);
            const snap = self.eval_pool.snapshot();
            const constraints_hold = try self.check_constraints(st);
            if (!constraints_hold) {
                self.eval_pool.restore(snap);
                idx.* = std.math.maxInt(u32);
                continue;
            }
            // Canonicalize before checking invariants so that the violating
            // state is counted in `distinct`, matching TLC's reporting.
            const fp = fingerprint.hash_state(&self.state_store.values_pool, st.values);
            const canonical = self.fp_set.put_with_index(fp, idx.*);
            const is_new = canonical == null;
            const state_idx = canonical orelse idx.*;
            if (is_new) {
                self.distinct += 1;
                assert(self.distinct <= self.max_states_limit);
            }
            const invariants_hold = try self.check_invariants(self.state_store.get(state_idx));
            self.eval_pool.restore(snap);
            if (!invariants_hold) {
                std.debug.print("InvariantViolated generated={d} distinct={d}\n", .{ self.generated, self.distinct });
                return Error.InvariantViolated;
            }
            if (is_new) {
                if (!self.queue.enqueue(state_idx)) {
                    return Error.StateSpaceExhausted;
                }
            }
            idx.* = state_idx;
            out_states.items[kept_count] = state_idx;
            kept_count += 1;
        }
        out_states.shrinkRetainingCapacity(kept_count);

        if (parent_idx) |pidx| {
            const count: u32 = @intCast(out_states.items.len);
            if (self.succ_count + count > self.succ_cap) return Error.OutOfMemory;
            for (out_states.items, 0..) |idx, i| {
                assert(idx < self.state_store.count);
                self.succ_edges[self.succ_count + i] = idx;
            }
            self.succ_count += count;
            if (self.safety_properties.len > 0) {
                const parent = self.state_store.get(pidx);
                for (out_states.items) |idx| {
                    const child = self.state_store.get(idx);
                    if (!try self.check_safety_properties(parent, child)) {
                        std.debug.print("PropertyViolated on transition {d}->{d}\n", .{ pidx, idx });
                        return Error.PropertyViolated;
                    }
                }
            }
        }
    }

    fn check_safety_properties(self: *Checker, parent: *StateStore.State, child: *StateStore.State) !bool {
        const snap = self.eval_pool.snapshot();
        defer self.eval_pool.restore(snap);
        self.evaluator.set_next_state(child);
        defer self.evaluator.set_next_state(null);
        for (self.safety_properties) |prop| {
            if (!try self.eval_safety_property(prop, parent, child)) return false;
        }
        return true;
    }

    fn eval_safety_property(
        self: *Checker,
        prop: *ast.Expr,
        parent: *StateStore.State,
        child: *StateStore.State,
    ) !bool {
        switch (prop.*) {
            .unary => |u| {
                if (u.op == .temporal_box) {
                    return try self.eval_safety_property(u.operand, parent, child);
                }
            },
            .box_action => |ba| {
                // [][A]_v means that every step is either an A step or a
                // stuttering step on v.  We evaluate A with the parent state as
                // s0 and the child state as the next state (set by
                // check_safety_properties), then evaluate v on both states.
                const action_holds = try self.evaluator.eval_expr(ba.action, Context.empty(), parent, &self.eval_pool, &self.state_store.values_pool);
                if (action_holds.is_truthy()) return true;
                self.evaluator.set_next_state(parent);
                const vars_parent = try self.evaluator.eval_expr(ba.vars, Context.empty(), parent, &self.eval_pool, &self.state_store.values_pool);
                self.evaluator.set_next_state(child);
                const vars_child = try self.evaluator.eval_expr(ba.vars, Context.empty(), parent, &self.eval_pool, &self.state_store.values_pool);
                return vars_parent.eql(vars_child, &self.eval_pool);
            },
            else => {},
        }
        const v = try self.evaluator.eval_expr(prop, Context.empty(), parent, &self.eval_pool, &self.state_store.values_pool);
        return v.is_truthy();
    }

    fn unwrap_safety_action(expr: *ast.Expr) !*ast.Expr {
        var e = expr;
        while (true) {
            switch (e.*) {
                .unary => |u| {
                    if (u.op == .temporal_box) {
                        e = u.operand;
                        continue;
                    }
                },
                .box_action => return e,
                else => return e,
            }
            return e;
        }
    }

    const TemporalKind = enum { safety, liveness, unsupported };

    fn classify_temporal(expr: *ast.Expr) TemporalKind {
        switch (expr.*) {
            .unary => |u| {
                if (u.op == .temporal_box) return .safety;
            },
            .box_action => return .safety,
            else => {},
        }
        return .liveness;
    }

    fn check_properties(self: *Checker) !void {
        // Finalize successor offsets: ensure monotonic non-decreasing ranges.
        // We also filter out any stale maxInt(u32) entries that may have been
        // left in succ_edges when successors were canonicalized to a duplicate.
        const n = self.distinct;
        if (n > 0) {
            var last: u32 = 0;
            for (0..n) |i| {
                const idx: u32 = @intCast(i);
                if (self.succ_offsets[idx] >= last) {
                    last = self.succ_offsets[idx];
                } else {
                    self.succ_offsets[idx] = last;
                }
            }
            assert(n + 1 < self.succ_offsets.len);
            self.succ_offsets[n] = self.succ_count;

            // Compact: keep only edges whose target is a valid distinct state.
            var write: u32 = 0;
            for (0..self.succ_count) |e| {
                const t = self.succ_edges[e];
                if (t == std.math.maxInt(u32) or t >= n) {
                    // Drop invalid edges and adjust offsets of all nodes that
                    // point past this edge. We do a linear scan; n and edges
                    // are bounded by max_states so this is O(n + edges).
                    for (0..n + 1) |off| {
                        if (self.succ_offsets[off] > write) self.succ_offsets[off] -= 1;
                    }
                    continue;
                }
                self.succ_edges[write] = t;
                write += 1;
            }
            self.succ_count = write;
            self.succ_offsets[n] = write;
        }

        const scc_data = try self.build_scc_data();
        defer scc_data.deinit();

        var cache = PropertyCache.init(self.arena);
        for (self.properties) |prop| {
            const results = try self.eval_temporal_property_all(prop, &scc_data, &cache);
            for (0..n) |i| {
                if (!results[i]) {
                    std.debug.print("PropertyViolated: property at state={d}\n", .{i});
                    return Error.PropertyViolated;
                }
            }
        }
    }

    const PropertyCache = struct {
        keys: std.ArrayList(*ast.Expr),
        values: std.ArrayList([]bool),

        fn init(arena: *Arena) PropertyCache {
            _ = arena;
            return PropertyCache{
                .keys = std.ArrayList(*ast.Expr).empty,
                .values = std.ArrayList([]bool).empty,
            };
        }

        fn get(self: PropertyCache, prop: *ast.Expr) ?[]bool {
            for (self.keys.items, 0..) |k, i| {
                if (k == prop) return self.values.items[i];
            }
            return null;
        }

        fn put(self: *PropertyCache, allocator: std.mem.Allocator, prop: *ast.Expr, results: []bool) !void {
            try self.keys.append(allocator, prop);
            try self.values.append(allocator, results);
        }
    };

    const SccData = struct {
        scc_ids: []u32,
        scc_count: u32,
        scc_succ_offsets: []u32,
        scc_succ_edges: []u32,
        scc_states_offsets: []u32,
        scc_states_edges: []u32,
        fair_sccs: []bool,
        fair_region: []bool,
        allocator: std.mem.Allocator,

        fn deinit(self: SccData) void {
            self.allocator.free(self.scc_ids);
            self.allocator.free(self.scc_succ_offsets);
            self.allocator.free(self.scc_succ_edges);
            self.allocator.free(self.scc_states_offsets);
            self.allocator.free(self.scc_states_edges);
            self.allocator.free(self.fair_sccs);
            self.allocator.free(self.fair_region);
        }
    };

    fn build_scc_data(self: *Checker) !SccData {
        const n = self.distinct;
        const scc_ids = try self.compute_sccs();
        var scc_count: u32 = 0;
        for (scc_ids) |id| {
            if (id + 1 > scc_count) scc_count = id + 1;
        }

        const allocator = std.heap.page_allocator;

        var scc_states_counts = try allocator.alloc(u32, scc_count);
        defer allocator.free(scc_states_counts);
        @memset(scc_states_counts, 0);
        for (scc_ids) |id| {
            scc_states_counts[id] += 1;
        }

        var scc_states_offsets = try allocator.alloc(u32, scc_count + 1);
        var total_states: u32 = 0;
        for (0..scc_count) |i| {
            scc_states_offsets[i] = total_states;
            total_states += scc_states_counts[i];
        }
        scc_states_offsets[scc_count] = total_states;

        var scc_states_edges = try allocator.alloc(u32, total_states);
        var fill = try allocator.alloc(u32, scc_count);
        defer allocator.free(fill);
        @memcpy(fill, scc_states_offsets[0..scc_count]);
        for (0..n) |i| {
            const idx: u32 = @intCast(i);
            const id = scc_ids[idx];
            scc_states_edges[fill[id]] = idx;
            fill[id] += 1;
        }

        var scc_succ_counts = try allocator.alloc(u32, scc_count);
        defer allocator.free(scc_succ_counts);
        @memset(scc_succ_counts, 0);
        var edge_seen = try allocator.alloc(bool, scc_count * scc_count);
        defer allocator.free(edge_seen);
        @memset(edge_seen, false);
        for (0..n) |i| {
            const idx: u32 = @intCast(i);
            const from = scc_ids[idx];
            for (self.successors(idx)) |succ| {
                if (succ == idx) continue; // skip stuttering self-loops for liveness
                const to = scc_ids[succ];
                if (from == to) continue;
                const key = from * scc_count + to;
                if (!edge_seen[key]) {
                    edge_seen[key] = true;
                    scc_succ_counts[from] += 1;
                }
            }
        }

        var scc_succ_offsets = try allocator.alloc(u32, scc_count + 1);
        var total_edges: u32 = 0;
        for (0..scc_count) |i| {
            scc_succ_offsets[i] = total_edges;
            total_edges += scc_succ_counts[i];
        }
        scc_succ_offsets[scc_count] = total_edges;

        var scc_succ_edges = try allocator.alloc(u32, total_edges);
        @memcpy(fill, scc_succ_offsets[0..scc_count]);
        @memset(edge_seen, false);
        for (0..n) |i| {
            const idx: u32 = @intCast(i);
            const from = scc_ids[idx];
            for (self.successors(idx)) |succ| {
                if (succ == idx) continue; // skip stuttering self-loops for liveness
                const to = scc_ids[succ];
                if (from == to) continue;
                const key = from * scc_count + to;
                if (!edge_seen[key]) {
                    edge_seen[key] = true;
                    scc_succ_edges[fill[from]] = to;
                    fill[from] += 1;
                }
            }
        }

        const fair_sccs = try self.compute_fair_sccs(scc_ids, scc_count, scc_states_offsets, scc_states_edges, allocator);
        const fair_region = try self.compute_fair_region(scc_ids, scc_count, scc_succ_offsets, scc_succ_edges, fair_sccs, n, allocator);

        return SccData{
            .scc_ids = scc_ids,
            .scc_count = scc_count,
            .scc_succ_offsets = scc_succ_offsets,
            .scc_succ_edges = scc_succ_edges,
            .scc_states_offsets = scc_states_offsets,
            .scc_states_edges = scc_states_edges,
            .fair_sccs = fair_sccs,
            .fair_region = fair_region,
            .allocator = allocator,
        };
    }

    fn compute_fair_region(
        self: *Checker,
        scc_ids: []u32,
        scc_count: u32,
        scc_succ_offsets: []u32,
        scc_succ_edges: []u32,
        fair_sccs: []bool,
        n: u64,
        allocator: std.mem.Allocator,
    ) Error![]bool {
        _ = self;
        const fair_region = try allocator.alloc(bool, n);
        @memset(fair_region, false);
        var scc_can_reach_fair = try allocator.alloc(bool, scc_count);
        defer allocator.free(scc_can_reach_fair);
        @memset(scc_can_reach_fair, false);
        var stack = try allocator.alloc(u32, scc_count);
        defer allocator.free(stack);
        var stack_len: u32 = 0;
        for (fair_sccs, 0..) |fair, id| {
            if (fair) {
                scc_can_reach_fair[id] = true;
                stack[stack_len] = @intCast(id);
                stack_len += 1;
            }
        }
        while (stack_len > 0) {
            stack_len -= 1;
            const cur = stack[stack_len];
            for (0..scc_count) |pred_id| {
                const pred: u32 = @intCast(pred_id);
                if (scc_can_reach_fair[pred]) continue;
                const begin = scc_succ_offsets[pred];
                const end = scc_succ_offsets[pred + 1];
                for (scc_succ_edges[begin..end]) |succ| {
                    if (succ == cur) {
                        scc_can_reach_fair[pred] = true;
                        assert(stack_len < scc_count);
                        stack[stack_len] = pred;
                        stack_len += 1;
                        break;
                    }
                }
            }
        }
        for (scc_ids, 0..) |scc_id, i| {
            if (scc_can_reach_fair[scc_id]) fair_region[i] = true;
        }
        return fair_region;
    }

    fn compute_fair_sccs(
        self: *Checker,
        scc_ids: []u32,
        scc_count: u32,
        scc_states_offsets: []u32,
        scc_states_edges: []u32,
        allocator: std.mem.Allocator,
    ) Error![]bool {
        const n = self.distinct;
        const fair_sccs = try allocator.alloc(bool, scc_count);
        @memset(fair_sccs, true);
        if (self.fairness.len == 0) return fair_sccs;
        @memset(fair_sccs, false);

        var enabled = try allocator.alloc([]bool, self.fairness.len);
        defer allocator.free(enabled);
        var has_angle = try allocator.alloc(bool, self.fairness.len * scc_count);
        defer allocator.free(has_angle);
        @memset(has_angle, false);

        for (self.fairness, 0..) |fc, fi| {
            enabled[fi] = try allocator.alloc(bool, n);
            @memset(enabled[fi], false);
            for (0..n) |s| {
                const state = self.state_store.get(@intCast(s));
                for (self.successors(@intCast(s))) |succ| {
                    const child = self.state_store.get(succ);
                    if (try self.eval_action(fc.action, state, child)) {
                        enabled[fi][s] = true;
                        if (!(try self.eval_vars_equal(fc.vars, state, child))) {
                            const from_scc = scc_ids[s];
                            const to_scc = scc_ids[succ];
                            if (from_scc == to_scc) {
                                has_angle[fi * scc_count + from_scc] = true;
                            }
                        }
                    }
                }
            }
        }
        defer for (enabled) |e| allocator.free(e);

        for (0..scc_count) |id| {
            const scc_id: u32 = @intCast(id);
            var fair = true;
            for (self.fairness, 0..) |fc, fi| {
                var all_enabled = true;
                var any_enabled = false;
                const begin = scc_states_offsets[scc_id];
                const end = scc_states_offsets[scc_id + 1];
                for (scc_states_edges[begin..end]) |state_idx| {
                    if (enabled[fi][state_idx]) {
                        any_enabled = true;
                    } else {
                        all_enabled = false;
                    }
                }
                const angle = has_angle[fi * scc_count + scc_id];
                const cond_fair = switch (fc.kind) {
                    .weak => !all_enabled or angle,
                    .strong => !any_enabled or angle,
                };
                if (!cond_fair) {
                    fair = false;
                    break;
                }
            }
            fair_sccs[scc_id] = fair;
        }
        return fair_sccs;
    }

    fn eval_action(self: *Checker, action_expr: *ast.Expr, parent: *StateStore.State, child: *StateStore.State) Error!bool {
        const snap = self.eval_pool.snapshot();
        defer self.eval_pool.restore(snap);
        self.evaluator.set_next_state(child);
        defer self.evaluator.set_next_state(null);
        const v = try self.evaluator.eval_expr(action_expr, Context.empty(), parent, &self.eval_pool, &self.state_store.values_pool);
        return v.is_truthy();
    }

    fn eval_vars_equal(self: *Checker, vars_expr: *ast.Expr, a: *StateStore.State, b: *StateStore.State) Error!bool {
        const snap = self.eval_pool.snapshot();
        defer self.eval_pool.restore(snap);
        const va = try self.evaluator.eval_expr(vars_expr, Context.empty(), a, &self.eval_pool, &self.state_store.values_pool);
        const vb = try self.evaluator.eval_expr(vars_expr, Context.empty(), b, &self.eval_pool, &self.state_store.values_pool);
        return va.eql(vb, &self.eval_pool);
    }

    fn eval_temporal_property_all(
        self: *Checker,
        prop: *ast.Expr,
        scc_data: *const SccData,
        cache: *PropertyCache,
    ) Error![]bool {
        if (cache.get(prop)) |cached| return cached;

        const n = self.distinct;
        const results = try std.heap.page_allocator.alloc(bool, n);
        errdefer std.heap.page_allocator.free(results);

        const snap = self.eval_pool.snapshot();
        defer self.eval_pool.restore(snap);

        switch (prop.*) {
            .if_then_else => |ite| {
                const cond_results = try self.eval_temporal_property_all(ite.cond, scc_data, cache);
                const then_results = try self.eval_temporal_property_all(ite.then_branch, scc_data, cache);
                const else_results = try self.eval_temporal_property_all(ite.else_branch, scc_data, cache);
                for (0..n) |i| {
                    results[i] = if (cond_results[i]) then_results[i] else else_results[i];
                }
            },
            .binary => |b| {
                switch (b.op) {
                    .and_op => {
                        const left = try self.eval_temporal_property_all(b.left, scc_data, cache);
                        const right = try self.eval_temporal_property_all(b.right, scc_data, cache);
                        for (0..n) |i| {
                            results[i] = left[i] and right[i];
                        }
                    },
                    .or_op => {
                        const left = try self.eval_temporal_property_all(b.left, scc_data, cache);
                        const right = try self.eval_temporal_property_all(b.right, scc_data, cache);
                        for (0..n) |i| {
                            results[i] = left[i] or right[i];
                        }
                    },
                    .implies => {
                        const left = try self.eval_temporal_property_all(b.left, scc_data, cache);
                        const right = try self.eval_temporal_property_all(b.right, scc_data, cache);
                        for (0..n) |i| {
                            results[i] = !left[i] or right[i];
                        }
                    },
                    .leads_to => {
                        // P ~> Q  ==  [](P => <>Q)
                        const p = try self.eval_temporal_property_all(b.left, scc_data, cache);
                        const q = try self.eval_temporal_property_all(b.right, scc_data, cache);
                        const diamond_q = try self.eval_diamond_all(q, scc_data);
                        defer std.heap.page_allocator.free(diamond_q);
                        for (0..n) |i| {
                            results[i] = !p[i] or diamond_q[i];
                        }
                        const box_results = try self.eval_box_all(results, scc_data);
                        defer std.heap.page_allocator.free(box_results);
                        @memcpy(results, box_results);
                    },
                    else => {
                        for (0..n) |i| {
                            const st = self.state_store.get(@intCast(i));
                            const v = try self.evaluator.eval_expr(prop, Context.empty(), st, &self.eval_pool, &self.state_store.values_pool);
                            results[i] = v.is_truthy();
                        }
                    },
                }
            },
            .unary => |u| {
                switch (u.op) {
                    .temporal_box => {
                        const operand = try self.eval_temporal_property_all(u.operand, scc_data, cache);
                        const box_results = try self.eval_box_all(operand, scc_data);
                        defer std.heap.page_allocator.free(box_results);
                        @memcpy(results, box_results);
                    },
                    .temporal_diamond => {
                        const operand = try self.eval_temporal_property_all(u.operand, scc_data, cache);
                        const diamond_results = try self.eval_diamond_all(operand, scc_data);
                        defer std.heap.page_allocator.free(diamond_results);
                        @memcpy(results, diamond_results);
                    },
                    else => {
                        for (0..n) |i| {
                            const st = self.state_store.get(@intCast(i));
                            const v = try self.evaluator.eval_expr(prop, Context.empty(), st, &self.eval_pool, &self.state_store.values_pool);
                            results[i] = v.is_truthy();
                        }
                    },
                }
            },
            else => {
                for (0..n) |i| {
                    const st = self.state_store.get(@intCast(i));
                    const v = try self.evaluator.eval_expr(prop, Context.empty(), st, &self.eval_pool, &self.state_store.values_pool);
                    results[i] = v.is_truthy();
                }
            },
        }

        try cache.put(std.heap.page_allocator, prop, results);
        return results;
    }

    // The "fair game graph" used for evaluating temporal properties under
    // fairness contains every original edge whose target can participate in a
    // fair behavior.  States outside the fair region cannot be extended to an
    // infinite fair path, so every LTL formula is vacuously true there.
    fn is_fair_game_edge(self: *Checker, scc_data: *const SccData, succ: u32) bool {
        _ = self;
        return scc_data.fair_region[succ];
    }

    fn eval_box_all(self: *Checker, operand: []const bool, scc_data: *const SccData) Error![]bool {
        const n = self.distinct;
        assert(n > 0);
        assert(n == operand.len);
        assert(n == scc_data.scc_ids.len);
        assert(n == scc_data.fair_region.len);
        const results = try std.heap.page_allocator.alloc(bool, n);
        errdefer std.heap.page_allocator.free(results);
        var visited = try std.heap.page_allocator.alloc(bool, n);
        defer std.heap.page_allocator.free(visited);
        var stack = try std.heap.page_allocator.alloc(u32, n);
        defer std.heap.page_allocator.free(stack);
        for (0..n) |start| {
            const start_idx: u32 = @intCast(start);
            if (!scc_data.fair_region[start_idx]) {
                results[start] = true;
                continue;
            }
            @memset(visited, false);
            var stack_len: u32 = 0;
            stack[stack_len] = start_idx;
            stack_len += 1;
            visited[start_idx] = true;
            var holds = true;
            while (stack_len > 0) {
                stack_len -= 1;
                const cur = stack[stack_len];
                if (!operand[cur]) {
                    holds = false;
                    break;
                }
                for (self.successors(cur)) |succ| {
                    if (!self.is_fair_game_edge(scc_data, succ)) continue;
                    if (!visited[succ]) {
                        visited[succ] = true;
                        stack[stack_len] = succ;
                        stack_len += 1;
                    }
                }
            }
            results[start] = holds;
        }
        return results;
    }

    fn eval_diamond_all(self: *Checker, operand: []const bool, scc_data: *const SccData) Error![]bool {
        const n = self.distinct;
        assert(n > 0);
        assert(n == operand.len);
        assert(n == scc_data.scc_ids.len);
        assert(n == scc_data.fair_region.len);
        const results = try std.heap.page_allocator.alloc(bool, n);
        errdefer std.heap.page_allocator.free(results);

        // Compute the fair-game attractor to `operand`.  A state is good iff
        // every fair-game path from it reaches a state satisfying `operand`.
        var good = try std.heap.page_allocator.alloc(bool, n);
        defer std.heap.page_allocator.free(good);
        @memset(good, false);
        var pending = try std.heap.page_allocator.alloc(u32, n);
        defer std.heap.page_allocator.free(pending);
        @memset(pending, 0);

        var work = try std.heap.page_allocator.alloc(u32, n);
        defer std.heap.page_allocator.free(work);
        var work_len: u32 = 0;

        for (0..n) |s| {
            const idx: u32 = @intCast(s);
            if (!scc_data.fair_region[idx]) continue;
            var count: u32 = 0;
            for (self.successors(idx)) |succ| {
                if (self.is_fair_game_edge(scc_data, succ)) count += 1;
            }
            pending[idx] = count;
            if (operand[idx]) {
                good[idx] = true;
                work[work_len] = idx;
                work_len += 1;
            }
        }

        while (work_len > 0) {
            work_len -= 1;
            const cur = work[work_len];
            for (0..n) |s| {
                const pred: u32 = @intCast(s);
                if (!scc_data.fair_region[pred]) continue;
                if (good[pred]) continue;
                var has_edge = false;
                for (self.successors(pred)) |succ| {
                    if (succ == cur and self.is_fair_game_edge(scc_data, succ)) {
                        has_edge = true;
                        break;
                    }
                }
                if (!has_edge) continue;
                assert(pending[pred] > 0);
                pending[pred] -= 1;
                if (pending[pred] == 0) {
                    good[pred] = true;
                    work[work_len] = pred;
                    work_len += 1;
                }
            }
        }

        for (0..n) |i| {
            results[i] = !scc_data.fair_region[i] or good[i];
        }
        return results;
    }

    fn compute_sccs(self: *Checker) ![]u32 {
        const n = self.distinct;
        assert(n > 0);
        assert(n <= self.max_states_limit);
        const allocator = std.heap.page_allocator;

        const indices = try allocator.alloc(u32, n);
        defer allocator.free(indices);
        @memset(indices, 0);
        const lowlinks = try allocator.alloc(u32, n);
        defer allocator.free(lowlinks);
        @memset(lowlinks, 0);
        const on_stack = try allocator.alloc(bool, n);
        defer allocator.free(on_stack);
        @memset(on_stack, false);
        const node_stack = try allocator.alloc(u32, n);
        defer allocator.free(node_stack);
        var node_stack_len: u32 = 0;
        var scc_ids = try allocator.alloc(u32, n);
        errdefer allocator.free(scc_ids);
        var index: u32 = 0;
        var scc_count: u32 = 0;

        // Iterative Tarjan SCC. We track visited edges with a per-node edge
        // index array to avoid recursion and to stay within a bounded arena.
        var edge_indices = try allocator.alloc(u32, n);
        defer allocator.free(edge_indices);
        @memset(edge_indices, 0);

        var v_stack = try allocator.alloc(u32, n);
        defer allocator.free(v_stack);
        var v_stack_len: u32 = 0;

        for (0..n) |start_i| {
            if (indices[start_i] != 0) continue;
            assert(v_stack_len == 0);
            v_stack[0] = @intCast(start_i);
            v_stack_len = 1;
            while (v_stack_len > 0) {
                const v = v_stack[v_stack_len - 1];
                if (indices[v] == 0) {
                    index += 1;
                    indices[v] = index;
                    lowlinks[v] = index;
                    on_stack[v] = true;
                    node_stack[node_stack_len] = v;
                    assert(node_stack_len < n);
                    node_stack_len += 1;
                    edge_indices[v] = 0;
                }
                const succs = self.successors(v);
                const ei = edge_indices[v];
                if (ei < succs.len) {
                    const w = succs[ei];
                    edge_indices[v] = ei + 1;
                    if (indices[w] == 0) {
                        assert(v_stack_len < n);
                        v_stack[v_stack_len] = w;
                        v_stack_len += 1;
                    } else if (on_stack[w]) {
                        if (indices[w] < lowlinks[v]) lowlinks[v] = indices[w];
                    }
                } else {
                    // all edges of v processed
                    v_stack_len -= 1;
                    if (lowlinks[v] == indices[v]) {
                        // root of an SCC
                        while (node_stack_len > 0) {
                            assert(node_stack_len <= n);
                            node_stack_len -= 1;
                            const w = node_stack[node_stack_len];
                            on_stack[w] = false;
                            scc_ids[w] = scc_count;
                            if (w == v) break;
                        }
                        assert(scc_count < n);
                        scc_count += 1;
                    }
                    if (v_stack_len > 0) {
                        const parent = v_stack[v_stack_len - 1];
                        if (lowlinks[v] < lowlinks[parent]) lowlinks[parent] = lowlinks[v];
                    }
                }
            }
        }
        return scc_ids;
    }

    fn successors(self: *Checker, idx: u32) []const u32 {
        assert(idx + 1 <= self.succ_offsets.len);
        assert(idx < self.distinct);
        const begin = self.succ_offsets[idx];
        const end = self.succ_offsets[idx + 1];
        assert(begin <= end);
        assert(end <= self.succ_edges.len);
        const slice = self.succ_edges[begin..end];
        for (slice) |s| assert(s < self.distinct);
        return slice;
    }

    fn check_constraints(self: *Checker, st: *StateStore.State) !bool {
        for (self.constraints) |c| {
            const v = try self.evaluator.eval_expr(c, Context.empty(), st, &self.eval_pool, &self.state_store.values_pool);
            if (!v.is_truthy()) return false;
        }
        return true;
    }

    fn check_invariants(self: *Checker, st: *StateStore.State) !bool {
        for (self.invariants, 0..) |inv, i| {
            const v = self.evaluator.eval_expr(inv, Context.empty(), st, &self.eval_pool, &self.state_store.values_pool) catch |err| {
                if (i < self.invariant_names.len) {
                    std.debug.print("Error evaluating invariant {s}: {any}\n", .{ self.invariant_names[i], err });
                }
                return err;
            };
            if (!v.is_truthy()) return false;
        }
        return true;
    }
};

pub const Result = struct {
    generated: u64,
    distinct: u64,
    error_state: ?u32,
};

const SpecNames = struct {
    init: []const u8,
    next: []const u8,
};

fn resolve_definition(module: ast.Module, name: []const u8) ?*ast.Expr {
    for (module.definitions) |d| {
        if (std.mem.eql(u8, d.name, name)) return d.body;
    }
    return null;
}

fn expr_ident(arena: *Arena, name: []const u8) !*ast.Expr {
    const ptr = try arena.alloc_object(ast.Expr);
    ptr.* = ast.Expr{ .ident = try arena.dup(name) };
    return ptr;
}

fn collect_fairness(arena: *Arena, expr: *ast.Expr, list: *std.ArrayList(FairnessCondition)) !void {
    switch (expr.*) {
        .binary => |b| {
            if (b.op == .and_op) {
                try collect_fairness(arena, b.left, list);
                try collect_fairness(arena, b.right, list);
            }
        },
        .unary => |u| {
            try collect_fairness(arena, u.operand, list);
        },
        .box_action => |ba| {
            try collect_fairness(arena, ba.action, list);
        },
        .apply => |ap| {
            if (ap.func.* == .ident and ap.args.len == 1) {
                const name = ap.func.*.ident;
                if (starts_with(name, "WF_")) {
                    const vars_name = name[3..];
                    try list.append(std.heap.page_allocator, FairnessCondition{
                        .kind = .weak,
                        .action = ap.args[0],
                        .vars = try expr_ident(arena, vars_name),
                    });
                } else if (starts_with(name, "SF_")) {
                    const vars_name = name[3..];
                    try list.append(std.heap.page_allocator, FairnessCondition{
                        .kind = .strong,
                        .action = ap.args[0],
                        .vars = try expr_ident(arena, vars_name),
                    });
                }
            }
        },
        else => {},
    }
}

fn extract_fairness(arena: *Arena, module: ast.Module, spec_name: []const u8) ![]const FairnessCondition {
    var list = std.ArrayList(FairnessCondition).empty;
    defer list.deinit(std.heap.page_allocator);
    const body = resolve_definition(module, spec_name) orelse return &[_]FairnessCondition{};
    try collect_fairness(arena, body, &list);
    const result = try arena.alloc(FairnessCondition, list.items.len);
    @memcpy(result, list.items);
    return result;
}

fn extract_spec_names(module: ast.Module, spec_name: []const u8) !SpecNames {
    for (module.definitions) |d| {
        if (!std.mem.eql(u8, d.name, spec_name)) continue;
        var conj: *ast.Expr = d.body;
        // Resolve aliases and ignore fairness/justice/property conjuncts.
        var steps: u32 = 0;
        while (steps < 16) : (steps += 1) {
            switch (conj.*) {
                .ident => |name| {
                    if (resolve_definition(module, name)) |b| {
                        conj = b;
                        continue;
                    }
                },
                .binary => |b| {
                    if (b.op == .and_op) {
                        var right = b.right;
                        for (0..4) |_| {
                            switch (right.*) {
                                .ident => |n| {
                                    if (resolve_definition(module, n)) |rb| {
                                        right = rb;
                                        continue;
                                    }
                                },
                                else => break,
                            }
                            break;
                        }
                        const right_name = try action_name(right);
                        if (right_name != null) {
                            return SpecNames{
                                .init = try init_name(b.left) orelse return Error.ConfigError,
                                .next = right_name.?,
                            };
                        }
                        // Right conjunct is not the action (fairness/property/print); drop it.
                        conj = b.left;
                        continue;
                    }
                },
                else => {},
            }
            break;
        }
        return Error.ConfigError;
    }
    return Error.ConfigError;
}

fn action_name(expr: *ast.Expr) error{ConfigError}!?[]const u8 {
    // [][Next]_vars
    switch (expr.*) {
        .box_action => |ba| {
            if (ba.action.* == .ident) return ba.action.ident;
            return null;
        },
        .unary => |u| return try action_name(u.operand),
        .binary => |b| {
            if (b.op == .and_op) {
                const left = try action_name(b.left);
                if (left != null) return left;
                return try action_name(b.right);
            }
        },
        else => {},
    }
    return null;
}

fn init_name(expr: *ast.Expr) error{ConfigError}!?[]const u8 {
    switch (expr.*) {
        .ident => |name| return name,
        else => return null,
    }
}

fn find_init_name(module: ast.Module) ?[]const u8 {
    for (module.definitions) |d| {
        if (std.mem.eql(u8, d.name, "Init")) return d.name;
    }
    return null;
}

fn find_def_fallback(module: ast.Module, candidates: []const []const u8) ?[]const u8 {
    for (candidates) |cand| {
        for (module.definitions) |d| {
            if (std.mem.eql(u8, d.name, cand)) return d.name;
        }
    }
    return null;
}

fn find_next_name(module: ast.Module) ?[]const u8 {
    for (module.definitions) |d| {
        if (std.mem.eql(u8, d.name, "Next")) return d.name;
    }
    return null;
}

fn find_spec_name(module: ast.Module) ?[]const u8 {
    for (module.definitions) |d| {
        if (std.mem.eql(u8, d.name, "Spec")) return d.name;
    }
    return null;
}

fn evaluate_constants(arena: *Arena, cfg: Config, evaluator: *Evaluator, state_pool: *ValuePool) ![]const Constant {
    var values = std.ArrayList(Constant).empty;
    defer values.deinit(std.heap.page_allocator);
    for (cfg.constants) |ca| {
        if (ca.is_substitution and is_operator_alias(ca.expr)) continue;
        const value = try evaluate_config_expr(arena, ca, evaluator, state_pool);
        try values.append(std.heap.page_allocator, Constant{
            .name = ca.name,
            .value = value,
        });
    }
    return try dup_slice(arena, Constant, values.items);
}

fn dup_slice(arena: *Arena, comptime T: type, items: []const T) ![]const T {
    if (items.len == 0) return &[_]T{};
    const result = try arena.alloc(T, items.len);
    @memcpy(result, items);
    return result;
}

fn evaluate_aliases(arena: *Arena, cfg: Config) ![]const eval.Alias {
    var aliases = std.ArrayList(eval.Alias).empty;
    defer aliases.deinit(std.heap.page_allocator);
    for (cfg.constants) |ca| {
        if (!ca.is_substitution) continue;
        const trimmed = std.mem.trim(u8, ca.expr, " \t");
        if (is_operator_alias(trimmed)) {
            try aliases.append(std.heap.page_allocator, eval.Alias{
                .from = try arena.dup(ca.name),
                .to = try arena.dup(trimmed),
            });
        }
    }
    return try dup_slice(arena, eval.Alias, aliases.items);
}

fn is_operator_alias(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return false;
    if (!std.ascii.isAlphabetic(trimmed[0])) return false;
    for (trimmed[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn evaluate_config_expr(arena: *Arena, ca: ConstantAssignment, evaluator: *Evaluator, state_pool: *ValuePool) !Value {
    const trimmed = std.mem.trim(u8, ca.expr, " \t");
    if (trimmed.len == 0) return error.SyntaxError;

    if (ca.is_substitution) {
        const expr = try parser.Parser.parse_expr_string(arena, trimmed);
        return try evaluator.eval_expr(expr, Context.empty(), null, state_pool, state_pool);
    }

    // A constant assignment of the form C = C declares C to be a model value,
    // overriding any module definition of the same name.
    if (std.mem.eql(u8, trimmed, ca.name) and evaluator.treat_unknown_as_model) {
        const id = try evaluator.models.intern(ca.name);
        return Value{ .model_v = id };
    }

    // Parse the right-hand side as a TLA+ expression so nested sets, ranges,
    // and model values are handled by the real parser/evaluator.
    const expr = try parser.Parser.parse_expr_string(arena, trimmed);
    return try evaluator.eval_expr(expr, Context.empty(), null, state_pool, state_pool);
}
