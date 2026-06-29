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
const StateBuffer = action.StateBuffer;
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
const generated_runtime = @import("generated_runtime.zig");

const WorkerContext = struct {
    eval_arena: Arena,
    eval_pool: ValuePool,
    evaluator: Evaluator,
    candidate_arena: Arena,
    candidate_store: StateStore,
    candidate_evaluator: Evaluator,
    candidate_pool_base: ValuePool.Snapshot,
    eval_pool_base: ValuePool.Snapshot,
    out_states: StateBuffer,
    compose_states: StateBuffer,
    prepared_fingerprints: []fingerprint.Fingerprint,
    prepared_invariants: []bool,
    prepared_edge_masks: []u64,
    prepared_generated: u64,
    composition_generated: u64,
    source_snapshot: StateStore,

    fn deinit(self: *WorkerContext) void {
        self.eval_arena.deinit();
        self.candidate_arena.deinit();
    }
};

const ParallelState = struct {
    checker: *Checker,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    condition: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    active: u32 = 0,
    current_level: u32 = 0,
    done: bool = false,
    failure: ?Error = null,
};

fn parallel_lock(parallel: *ParallelState) void {
    assert(std.c.pthread_mutex_lock(&parallel.mutex) == .SUCCESS);
}

fn parallel_unlock(parallel: *ParallelState) void {
    assert(std.c.pthread_mutex_unlock(&parallel.mutex) == .SUCCESS);
}

fn parallel_wait(parallel: *ParallelState) void {
    assert(std.c.pthread_cond_wait(
        &parallel.condition,
        &parallel.mutex,
    ) == .SUCCESS);
}

fn parallel_broadcast(parallel: *ParallelState) void {
    assert(std.c.pthread_cond_broadcast(&parallel.condition) == .SUCCESS);
}

fn parallel_worker(
    parallel: *ParallelState,
    worker: *WorkerContext,
) void {
    const checker = parallel.checker;
    while (true) {
        parallel_lock(parallel);
        if (parallel.done or parallel.failure != null) {
            parallel_unlock(parallel);
            return;
        }

        const next_idx = checker.queue.peek() orelse {
            if (parallel.active == 0) {
                parallel.done = true;
                parallel_broadcast(parallel);
                parallel_unlock(parallel);
                return;
            }
            parallel_wait(parallel);
            parallel_unlock(parallel);
            continue;
        };
        const next_level = checker.state_store.get(next_idx).level;
        if (checker.graph_enabled and
            next_level > parallel.current_level)
        {
            if (parallel.active != 0) {
                parallel_wait(parallel);
                parallel_unlock(parallel);
                continue;
            }
            parallel.current_level = next_level;
        }
        const state_idx = checker.queue.dequeue().?;
        assert(state_idx == next_idx);
        assert(state_idx < checker.state_store.count);
        worker.source_snapshot = checker.state_store;
        parallel.active += 1;
        parallel_unlock(parallel);

        worker.candidate_store.reset(worker.candidate_pool_base);
        worker.eval_pool.restore(worker.eval_pool_base);
        worker.out_states.clear();
        worker.prepared_generated = 0;
        worker.composition_generated = 0;
        var executor = ActionExecutor{
            .evaluator = worker.evaluator,
            .source_state_store = &worker.source_snapshot,
            .candidate_store = &worker.candidate_store,
            .eval_pool = &worker.eval_pool,
            .compose_states = &worker.compose_states,
            .composition_generated = &worker.composition_generated,
            .fairness_markers = checker.fairness_markers,
            .edge_action_masks = worker.prepared_edge_masks,
        };
        const generation_error: ?Error = blk: {
            executor.execute_next(
                checker.next_spec.?,
                state_idx,
                &worker.out_states,
            ) catch |err| break :blk err;
            worker.prepared_generated = worker.out_states.items.len;
            checker.prepare_generated(
                state_idx,
                &worker.out_states,
                &worker.candidate_store,
                &worker.candidate_evaluator,
                &worker.eval_pool,
                worker.prepared_fingerprints,
                worker.prepared_invariants,
                worker.prepared_edge_masks,
            ) catch |err| break :blk err;
            break :blk null;
        };

        parallel_lock(parallel);
        if (generation_error) |err| {
            parallel.failure = err;
        } else if (checker.check_deadlock and
            worker.prepared_generated == 0)
        {
            if (checker.diagnostics) {
                std.debug.print(
                    "Deadlock generated={d} distinct={d}\n",
                    .{ checker.generated, checker.distinct },
                );
                checker.print_trace(state_idx);
            }
            parallel.failure = Error.Deadlock;
        } else if (parallel.failure == null) {
            checker.generated += worker.composition_generated;
            if (checker.graph_enabled) {
                checker.succ_offsets[state_idx] = checker.succ_count;
            }
            checker.check_enabled_invariants(
                state_idx,
                worker.out_states.items.len > 0,
            ) catch |err| {
                parallel.failure = err;
            };
            if (parallel.failure == null) {
                checker.process_prepared_generated(
                    state_idx,
                    &worker.out_states,
                    &worker.candidate_store,
                    &worker.evaluator,
                    &worker.eval_pool,
                    worker.prepared_fingerprints,
                    worker.prepared_invariants,
                    worker.prepared_edge_masks,
                ) catch |err| {
                    parallel.failure = err;
                };
            }
        }
        assert(parallel.active > 0);
        parallel.active -= 1;
        if (parallel.failure != null or
            (checker.queue.is_empty() and parallel.active == 0))
        {
            parallel.done = true;
        }
        parallel_broadcast(parallel);
        parallel_unlock(parallel);
    }
}

pub const FairnessCondition = struct {
    kind: enum { weak, strong },
    action: *ast.Expr,
    vars: *ast.Expr,
    full_vars: bool = false,
    bindings: []const FairnessBinding = &.{},
};

pub const FairnessBinding = action.FairnessBinding;

const SymmetryHashCache = struct {
    const Entry = struct {
        value: Value = .{ .bool_v = false },
        permutation_ptr: usize = 0,
        hash: fingerprint.Fingerprint = 0,
        occupied: bool = false,
    };

    entries: []Entry,
    enabled: bool,

    fn init(arena: *Arena, enabled: bool) !SymmetryHashCache {
        const entries = try arena.alloc(
            Entry,
            if (enabled) 32_768 else 1,
        );
        @memset(entries, .{});
        return .{ .entries = entries, .enabled = enabled };
    }

    fn hash_value(
        self: *SymmetryHashCache,
        pool: *const ValuePool,
        value_v: Value,
        permutation: ?[]const u32,
    ) fingerprint.Fingerprint {
        const permutation_ptr = if (permutation) |mapping|
            @intFromPtr(mapping.ptr)
        else
            0;
        const identity = value_identity(value_v);
        const slot: usize = @intCast(
            (identity ^ (permutation_ptr *% 0x9e3779b97f4a7c15)) &
                (self.entries.len - 1),
        );
        const entry = &self.entries[slot];
        if (entry.occupied and
            entry.permutation_ptr == permutation_ptr and
            std.meta.eql(entry.value, value_v))
        {
            return entry.hash;
        }
        const hash = fingerprint.hash_value_permuted(
            pool,
            value_v,
            permutation,
        );
        entry.* = .{
            .value = value_v,
            .permutation_ptr = permutation_ptr,
            .hash = hash,
            .occupied = true,
        };
        return hash;
    }
};

fn value_identity(value_v: Value) u64 {
    const tag: u64 = @intFromEnum(value_v);
    return switch (value_v) {
        .bool_v => |value_b| tag ^ @as(u64, @intFromBool(value_b)),
        .int_v => |value_i| tag ^ @as(u64, @bitCast(value_i)),
        .model_v => |model| tag ^ model,
        .string_v => |string| tag ^
            (@as(u64, string.offset) << 32) ^ string.len,
        .set_v => |set| tag ^
            (@as(u64, set.offset) << 32) ^ set.len,
        .function_v => |function| tag ^
            (@as(u64, function.domain.offset) << 32) ^
            function.domain.len ^
            (@as(u64, function.offset) *% 0x9e3779b97f4a7c15) ^
            function.len,
        .tuple_v => |tuple| tag ^
            (@as(u64, tuple.offset) << 32) ^ tuple.len,
        .record_v => |record| tag ^
            (@as(u64, record.offset) << 32) ^ record.len,
        .lambda_v => |lambda| tag ^ @intFromPtr(lambda),
        .generated_operator_v => |operator| tag ^
            operator.function_address ^
            (@as(u64, operator.arity) << 48) ^
            (@as(u64, operator.captured_offset) << 16) ^
            operator.captured_len,
        .function_set_v => |set| tag ^
            (@as(u64, set.domain_offset) << 32) ^
            set.codomain_offset,
        .record_set_v => |set| tag ^
            (@as(u64, set.offset) << 32) ^ set.len,
        .tuple_set_v => |set| tag ^
            (@as(u64, set.offset) << 32) ^ set.len,
        .union_v, .power_set_v => |set| tag ^ set.set_offset,
        .cup_v, .cap_v, .diff_v => |set| tag ^
            (@as(u64, set.left_offset) << 32) ^
            set.right_offset,
        .range_v => |range| tag ^
            @as(u64, @bitCast(range.lo)) ^
            (@as(u64, @bitCast(range.hi)) *%
                0x9e3779b97f4a7c15),
        .seq_set_v => |set| tag ^ set.element_set_offset,
    };
}

fn starts_with(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and std.mem.eql(u8, haystack[0..needle.len], needle);
}

fn symmetry_fingerprint(
    default_pool: *const ValuePool,
    canonical_pool: *const ValuePool,
    symmetry_hash_cache: *SymmetryHashCache,
    state_v: *const StateStore.State,
    permutations: []const []const u32,
) fingerprint.Fingerprint {
    const values = state_v.values;
    if (permutations.len == 0) {
        var hash = fingerprint.hash_init();
        for (values, 0..) |value_v, variable_index| {
            hash = fingerprint.hash_value(
                state_v.value_pool(
                    @intCast(variable_index),
                    default_pool,
                ),
                value_v,
                hash,
            );
        }
        return hash;
    }
    assert(values.len <= 64);

    var best_permutation: ?[]const u32 = null;
    var best_hashes: [64]fingerprint.Fingerprint = undefined;
    var best_hash_valid: [64]bool = @splat(false);

    for (permutations) |candidate_permutation| {
        for (values, 0..) |value_v, variable_index| {
            const value_pool = state_v.value_pool(
                @intCast(variable_index),
                default_pool,
            );
            if (!best_hash_valid[variable_index]) {
                best_hashes[variable_index] =
                    if (value_pool == canonical_pool and
                    symmetry_hash_cache.enabled)
                        symmetry_hash_cache.hash_value(
                            value_pool,
                            value_v,
                            best_permutation,
                        )
                    else
                        fingerprint.hash_value_permuted(
                            value_pool,
                            value_v,
                            best_permutation,
                        );
                best_hash_valid[variable_index] = true;
            }
            const candidate_hash = if (value_pool == canonical_pool and
                symmetry_hash_cache.enabled)
                symmetry_hash_cache.hash_value(
                    value_pool,
                    value_v,
                    candidate_permutation,
                )
            else
                fingerprint.hash_value_permuted(
                    value_pool,
                    value_v,
                    candidate_permutation,
                );
            if (candidate_hash > best_hashes[variable_index]) break;
            if (candidate_hash < best_hashes[variable_index]) {
                best_permutation = candidate_permutation;
                @memset(&best_hash_valid, false);
                best_hashes[variable_index] = candidate_hash;
                best_hash_valid[variable_index] = true;
                break;
            }
        }
    }

    var hash = fingerprint.hash_init();
    for (values, 0..) |value_v, variable_index| {
        const value_pool = state_v.value_pool(
            @intCast(variable_index),
            default_pool,
        );
        hash = fingerprint.hash_combine(
            hash,
            if (value_pool == canonical_pool and
                symmetry_hash_cache.enabled)
                symmetry_hash_cache.hash_value(
                    value_pool,
                    value_v,
                    best_permutation,
                )
            else
                fingerprint.hash_value_permuted(
                    value_pool,
                    value_v,
                    best_permutation,
                ),
        );
    }
    return hash;
}

const CanonicalValueEntry = struct {
    hash: fingerprint.Fingerprint = 0,
    value: Value = .{ .bool_v = false },
    variable_index: u16 = 0,
    occupied: bool = false,
};

fn canonical_value_capacity(max_states: u32) u32 {
    const target = @min(
        @as(u64, max_states) * 2,
        2_097_152,
    );
    var capacity: u32 = 1024;
    while (capacity < target) capacity *= 2;
    assert(std.math.isPowerOfTwo(capacity));
    return capacity;
}

pub const Checker = struct {
    arena: *Arena,
    state_store: StateStore,
    candidate_arena: *Arena,
    candidate_store: StateStore,
    candidate_evaluator: Evaluator,
    candidate_pool_base: ValuePool.Snapshot,
    queue: StateQueue,
    fp_set: FpSet,
    symmetry_hash_cache: SymmetryHashCache,
    canonical_value_entries: []CanonicalValueEntry,
    evaluator: Evaluator,
    init_spec: ?action.CompiledInit,
    next_spec: ?action.CompiledNext,
    invariants: []const *ast.Expr,
    invariant_names: []const []const u8,
    constraints: []const *ast.Expr,
    constraint_names: []const []const u8,
    action_constraints: []const *ast.Expr,
    action_constraint_names: []const []const u8,
    properties: []const *ast.Expr,
    safety_properties: []const *ast.Expr,
    eval_arena: *Arena,
    eval_pool: ValuePool,
    eval_pool_base: ValuePool.Snapshot,
    check_deadlock: bool,
    diagnostics: bool,
    worker_count: u16,
    max_states: u32,
    max_successors: u32,
    generated: u64,
    distinct: u64,
    // Transition graph for liveness/property checking.
    succ_offsets: []u32,
    succ_counts: []u32,
    succ_edges: []u32,
    edge_action_masks: []u64,
    succ_count: u32,
    succ_cap: u32,
    graph_enabled: bool,
    canonical_states: []bool,
    initial_states: []bool,
    // We record total allocated max_states for successor arrays because the
    // graph is built on at most max_states distinct states.  Some consumers
    // assume `idx < distinct`; callers must keep successor indices within this
    // bound, but we assert it defensively.
    max_states_limit: u32,
    // Fairness conditions extracted from the specification formula.
    fairness: []const FairnessCondition,
    fairness_markers: []const action.FairnessMarker,
    symmetry_permutations: []const []const u32,

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
        worker_count: u16,
    ) !Checker {
        return init_internal(
            arena,
            module,
            cfg,
            max_states,
            eval_value_cap,
            eval_string_cap,
            state_value_cap,
            state_string_cap,
            eval_arena_bytes,
            override_ctx,
            worker_count,
            @min(max_states, 65_536),
            &.{},
            &.{},
        );
    }

    pub fn init_generated(
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
        worker_count: u16,
        generated: []const generated_runtime.Operator,
        generated_expressions: []const generated_runtime.Expression,
    ) !Checker {
        return init_internal(
            arena,
            module,
            cfg,
            max_states,
            eval_value_cap,
            eval_string_cap,
            state_value_cap,
            state_string_cap,
            eval_arena_bytes,
            override_ctx,
            worker_count,
            @min(max_states, 65_536),
            generated,
            generated_expressions,
        );
    }

    pub fn init_generated_with_successor_limit(
        arena: *Arena,
        module: ast.Module,
        cfg: Config,
        max_states: u32,
        max_successors: u32,
        eval_value_cap: u32,
        eval_string_cap: u32,
        state_value_cap: u32,
        state_string_cap: u32,
        eval_arena_bytes: u64,
        override_ctx: overrides.OverrideContext,
        worker_count: u16,
        generated: []const generated_runtime.Operator,
        generated_expressions: []const generated_runtime.Expression,
    ) !Checker {
        return init_internal(
            arena,
            module,
            cfg,
            max_states,
            eval_value_cap,
            eval_string_cap,
            state_value_cap,
            state_string_cap,
            eval_arena_bytes,
            override_ctx,
            worker_count,
            max_successors,
            generated,
            generated_expressions,
        );
    }

    fn init_internal(
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
        worker_count: u16,
        max_successors: u32,
        generated: []const generated_runtime.Operator,
        generated_expressions: []const generated_runtime.Expression,
    ) !Checker {
        assert(worker_count > 0);
        assert(max_successors > 0);
        assert(max_successors <= max_states);
        var state_store = try StateStore.init(
            arena,
            module.variables,
            max_states,
            state_value_cap,
            state_string_cap,
        );
        // Canonical values are referenced by stable u32 offsets throughout
        // stored states. Growing this pool would relocate every backing value
        // and temporarily duplicate multiple gigabytes on exhaustive models.
        state_store.values_pool.growable = false;
        try state_store.values_pool.enable_string_interning(131_072);
        const queue = try StateQueue.init(arena, max_states);
        const fp_set = try FpSet.init(arena, max_states * 2);
        const symmetry_hash_cache = try SymmetryHashCache.init(
            arena,
            worker_count == 1,
        );
        const canonical_value_entries: []CanonicalValueEntry = if (!cfg.check_deadlock)
            try arena.alloc(
                CanonicalValueEntry,
                canonical_value_capacity(max_states),
            )
        else
            &[_]CanonicalValueEntry{};
        @memset(canonical_value_entries, .{});
        var evaluator = try Evaluator.init_generated(
            module,
            arena,
            override_ctx,
            generated,
            generated_expressions,
        );
        evaluator.set_treat_unknown_as_model(true);
        const aliases = try evaluate_aliases(arena, cfg);
        evaluator.set_aliases(aliases);
        const constants = try evaluate_constants(arena, cfg, &evaluator, &state_store.values_pool);
        evaluator.set_constants(constants);
        evaluator.set_treat_unknown_as_model(false);
        const compiler = ActionCompiler.init(arena, evaluator);

        const eval_arena = try arena.alloc_object(Arena);
        eval_arena.* = try Arena.init(eval_arena_bytes);
        var eval_pool = try ValuePool.init(eval_arena, eval_value_cap, eval_string_cap);
        evaluator.set_definition_memo_pool(&eval_pool);
        for (module.assumptions, 0..) |assumption, assumption_index| {
            const result = evaluator.eval_expr(
                assumption,
                Context.empty(),
                null,
                &eval_pool,
                &state_store.values_pool,
            ) catch |err| {
                std.debug.print("ASSUME[{d}] evaluation failed: {any}", .{ assumption_index, err });
                if (evaluator.err_ctx.context) |context| {
                    std.debug.print(" -- context: {s} {s}", .{
                        context,
                        evaluator.err_ctx.detail orelse "",
                    });
                }
                std.debug.print("\n", .{});
                return err;
            };
            if (result != .bool_v) {
                return evaluator.fail(Error.TypeError, "ASSUME", @tagName(result));
            }
            if (!result.bool_v) {
                std.debug.print("ASSUME[{d}] evaluated to FALSE\n", .{assumption_index});
                return Error.AssumptionViolated;
            }
        }
        evaluator.freeze_definition_memo();
        const symmetry_permutations = try evaluate_symmetry(
            arena,
            cfg,
            &evaluator,
            &eval_pool,
            &state_store.values_pool,
        );
        const eval_pool_base = eval_pool.snapshot();

        const candidate_arena = try arena.alloc_object(Arena);
        candidate_arena.* = try Arena.init(@max(eval_arena_bytes / 4, 16 * 1024 * 1024));
        var candidate_store = try StateStore.init(
            candidate_arena,
            module.variables,
            max_successors,
            @min(state_value_cap, 1_048_576),
            @min(state_string_cap, 65_536),
        );
        var candidate_evaluator = try evaluator.fork(candidate_arena);
        candidate_evaluator.set_constants(try clone_constants(
            arena,
            constants,
            &state_store.values_pool,
            &candidate_store.values_pool,
        ));
        const candidate_pool_base = candidate_store.values_pool.snapshot();

        const spec_name_v: ?[]const u8 = cfg.spec_name orelse find_spec_name(module);
        const init_name_v: ?[]const u8 = blk: {
            if (cfg.init_name) |n| break :blk n;
            if (spec_name_v) |sn| {
                if (extract_spec_names(module, sn)) |snames| break :blk snames.init else |_| {}
            }
            break :blk find_init_name(module) orelse
                find_def_fallback(module, &.{ "Init", "Initial", "InitialState" });
        };
        const next_name_v: ?[]const u8 = blk: {
            if (cfg.next_name) |n| break :blk n;
            if (spec_name_v) |sn| {
                if (extract_spec_names(module, sn)) |snames| break :blk snames.next else |_| {}
            }
            break :blk find_next_name(module) orelse find_def_fallback(module, &.{ "Next", "Step" });
        };

        if ((init_name_v == null) != (next_name_v == null)) return Error.ConfigError;
        const compiled_init: ?action.CompiledInit = if (init_name_v) |name| blk: {
            const resolved_name = evaluator.resolve_alias(name);
            const init_def = evaluator.find_definition(resolved_name) orelse {
                std.debug.print("undefined init def: {s}\n", .{resolved_name});
                return Error.UndefinedSymbol;
            };
            break :blk try compiler.compile_init(init_def.body);
        } else null;
        const compiled_next: ?action.CompiledNext = if (next_name_v) |name| blk: {
            const resolved_name = evaluator.resolve_alias(name);
            const next_def = evaluator.find_definition(resolved_name) orelse {
                std.debug.print("undefined next def: {s}\n", .{resolved_name});
                return Error.UndefinedSymbol;
            };
            break :blk try compiler.compile_next(next_def.body);
        } else null;

        var invariant_exprs = std.ArrayList(*ast.Expr).empty;
        defer invariant_exprs.deinit(std.heap.page_allocator);
        for (cfg.invariants) |inv_name| {
            const def = evaluator.find_definition(inv_name) orelse {
                std.debug.print("undefined invariant: {s}\n", .{inv_name});
                print_definition_tail(module);
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

        var action_constraint_exprs = std.ArrayList(*ast.Expr).empty;
        defer action_constraint_exprs.deinit(std.heap.page_allocator);
        for (cfg.action_constraints) |cname| {
            const def = evaluator.find_definition(cname) orelse {
                std.debug.print("undefined action constraint: {s}\n", .{cname});
                return Error.UndefinedSymbol;
            };
            try action_constraint_exprs.append(std.heap.page_allocator, def.body);
        }
        const action_constraints: []const *ast.Expr =
            if (action_constraint_exprs.items.len == 0)
                &[_]*ast.Expr{}
            else blk: {
                const result = try arena.alloc(
                    *ast.Expr,
                    action_constraint_exprs.items.len,
                );
                @memcpy(result, action_constraint_exprs.items);
                break :blk result;
            };

        var property_exprs = std.ArrayList(*ast.Expr).empty;
        defer property_exprs.deinit(std.heap.page_allocator);
        var safety_property_exprs = std.ArrayList(*ast.Expr).empty;
        defer safety_property_exprs.deinit(std.heap.page_allocator);
        for (cfg.properties) |pname| {
            const def = evaluator.find_definition(pname) orelse {
                std.debug.print("undefined property: {s}\n", .{pname});
                print_definition_tail(module);
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

        const graph_enabled = properties.len > 0;
        const graph_states: u32 = if (graph_enabled) max_states else 0;
        const succ_cap: u32 = if (graph_enabled)
            std.math.mul(u32, max_states, 32) catch
                return Error.OutOfMemory
        else
            0;
        const succ_offsets = try arena.alloc(u32, graph_states + 1);
        @memset(succ_offsets, 0);
        const succ_counts = try arena.alloc(u32, graph_states);
        @memset(succ_counts, 0);
        const succ_edges = try arena.alloc(u32, succ_cap);
        const edge_action_masks = try arena.alloc(u64, succ_cap);
        const canonical_states = try arena.alloc(bool, graph_states);
        @memset(canonical_states, false);
        const initial_states = try arena.alloc(bool, graph_states);
        @memset(initial_states, false);

        const fairness = if (graph_enabled)
            if (spec_name_v) |sn|
                try extract_fairness(
                    arena,
                    &evaluator,
                    &eval_pool,
                    &state_store.values_pool,
                    module,
                    sn,
                )
            else
                &[_]FairnessCondition{}
        else
            &[_]FairnessCondition{};
        const fairness_markers = try build_fairness_markers(arena, fairness);
        return Checker{
            .arena = arena,
            .state_store = state_store,
            .candidate_arena = candidate_arena,
            .candidate_store = candidate_store,
            .candidate_evaluator = candidate_evaluator,
            .candidate_pool_base = candidate_pool_base,
            .queue = queue,
            .fp_set = fp_set,
            .symmetry_hash_cache = symmetry_hash_cache,
            .canonical_value_entries = canonical_value_entries,
            .evaluator = evaluator,
            .init_spec = compiled_init,
            .next_spec = compiled_next,
            .invariants = invariants,
            .invariant_names = invariant_names,
            .constraints = constraints,
            .constraint_names = cfg.constraints,
            .action_constraints = action_constraints,
            .action_constraint_names = cfg.action_constraints,
            .properties = properties,
            .safety_properties = safety_properties,
            .eval_arena = eval_arena,
            .eval_pool = eval_pool,
            .eval_pool_base = eval_pool_base,
            .check_deadlock = cfg.check_deadlock,
            .diagnostics = true,
            .worker_count = worker_count,
            .max_states = max_states,
            .max_successors = max_successors,
            .generated = 0,
            .distinct = 0,
            .succ_offsets = succ_offsets,
            .succ_counts = succ_counts,
            .succ_edges = succ_edges,
            .edge_action_masks = edge_action_masks,
            .succ_count = 0,
            .succ_cap = succ_cap,
            .graph_enabled = graph_enabled,
            .canonical_states = canonical_states,
            .initial_states = initial_states,
            .max_states_limit = max_states,
            .fairness = fairness,
            .fairness_markers = fairness_markers,
            .symmetry_permutations = symmetry_permutations,
        };
    }

    pub fn deinit(self: *Checker) void {
        self.eval_arena.deinit();
        self.candidate_arena.deinit();
    }

    pub fn set_diagnostics(self: *Checker, enabled: bool) void {
        self.diagnostics = enabled;
    }

    pub fn check(self: *Checker) !Result {
        if (self.init_spec == null) {
            assert(self.next_spec == null);
            return Result{
                .generated = 0,
                .distinct = 0,
                .error_state = null,
            };
        }
        assert(self.next_spec != null);

        var out_states = try StateBuffer.init(self.arena, self.max_successors);
        var compose_states = try StateBuffer.init(self.arena, self.max_successors);
        const edge_masks = try self.arena.alloc(u64, self.max_successors);
        var composition_generated: u64 = 0;

        var executor = ActionExecutor{
            .evaluator = self.evaluator,
            .source_state_store = &self.state_store,
            .candidate_store = &self.candidate_store,
            .eval_pool = &self.eval_pool,
            .compose_states = &compose_states,
            .composition_generated = &composition_generated,
            .fairness_markers = self.fairness_markers,
            .edge_action_masks = edge_masks,
        };

        self.candidate_store.reset(self.candidate_pool_base);
        self.eval_pool.restore(self.eval_pool_base);
        try executor.execute_init(self.init_spec.?, &out_states);
        try self.process_generated(
            null,
            &out_states,
            &self.candidate_store,
            &self.candidate_evaluator,
            edge_masks,
        );
        self.eval_pool.restore(self.eval_pool_base);

        if (self.worker_count == 1) {
            while (self.queue.dequeue()) |idx| {
                assert(idx < self.state_store.count);
                assert(idx < self.max_states_limit);
                out_states.clear();
                if (self.graph_enabled) {
                    self.succ_offsets[idx] = self.succ_count;
                }
                self.candidate_store.reset(self.candidate_pool_base);
                self.eval_pool.restore(self.eval_pool_base);
                composition_generated = 0;
                executor.execute_next(self.next_spec.?, idx, &out_states) catch |err| {
                    std.debug.print("Error executing Next from state {d}: {any}\n", .{
                        idx,
                        err,
                    });
                    return err;
                };
                self.generated += composition_generated;
                if (self.check_deadlock and out_states.items.len == 0) {
                    if (self.diagnostics) {
                        std.debug.print(
                            "Deadlock generated={d} distinct={d}\n",
                            .{ self.generated, self.distinct },
                        );
                        self.print_trace(idx);
                    }
                    return Error.Deadlock;
                }
                try self.check_enabled_invariants(idx, out_states.items.len > 0);
                try self.process_generated(
                    idx,
                    &out_states,
                    &self.candidate_store,
                    &self.candidate_evaluator,
                    edge_masks,
                );
                self.eval_pool.restore(self.eval_pool_base);
            }
        } else {
            try self.check_parallel();
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

    fn check_parallel(self: *Checker) !void {
        assert(self.worker_count > 1);
        const workers = try self.arena.alloc(WorkerContext, self.worker_count);
        var initialized: u16 = 0;
        errdefer {
            for (workers[0..initialized]) |*worker| worker.deinit();
        }
        for (workers) |*worker| {
            try self.init_worker(worker);
            initialized += 1;
        }
        defer for (workers) |*worker| worker.deinit();
        // Worker cleanup now belongs to the normal defer. The errdefer above
        // is only for a partially initialized array.
        initialized = 0;

        // Workers read canonical values without synchronization. Prevent pool
        // relocation while they are active; capacity exhaustion is explicit.
        self.state_store.values_pool.growable = false;
        defer self.state_store.values_pool.growable = true;

        var parallel = ParallelState{ .checker = self };
        defer {
            assert(std.c.pthread_cond_destroy(&parallel.condition) == .SUCCESS);
            assert(std.c.pthread_mutex_destroy(&parallel.mutex) == .SUCCESS);
        }
        if (self.queue.peek()) |idx| {
            parallel.current_level = self.state_store.get(idx).level;
        }
        const threads = try self.arena.alloc(std.Thread, self.worker_count);
        var spawned: u16 = 0;
        errdefer for (threads[0..spawned]) |thread| thread.join();
        for (workers, 0..) |*worker, i| {
            threads[i] = try std.Thread.spawn(.{}, parallel_worker, .{
                &parallel,
                worker,
            });
            spawned += 1;
        }
        assert(spawned == self.worker_count);
        for (threads) |thread| thread.join();
        // The spawn-failure errdefer owns only live, unjoined handles. Clear
        // its range before propagating a model-checking error.
        spawned = 0;
        if (parallel.failure) |err| return err;
    }

    fn init_worker(self: *Checker, worker: *WorkerContext) !void {
        worker.eval_arena = try Arena.init(16 * 1024 * 1024);
        errdefer worker.eval_arena.deinit();
        worker.evaluator = try self.evaluator.fork(&worker.eval_arena);
        worker.evaluator.set_constants(self.evaluator.constants);
        worker.eval_pool = try ValuePool.init(
            &worker.eval_arena,
            1_048_576,
            65_536,
        );
        worker.eval_pool_base = worker.eval_pool.snapshot();

        worker.candidate_arena = try Arena.init(16 * 1024 * 1024);
        errdefer worker.candidate_arena.deinit();
        worker.candidate_store = try StateStore.init(
            &worker.candidate_arena,
            self.state_store.variable_names,
            self.max_successors,
            1_048_576,
            65_536,
        );
        worker.candidate_evaluator = try worker.evaluator.fork(
            &worker.candidate_arena,
        );
        worker.candidate_evaluator.set_constants(try clone_constants(
            self.arena,
            self.evaluator.constants,
            &self.state_store.values_pool,
            &worker.candidate_store.values_pool,
        ));
        worker.candidate_pool_base = worker.candidate_store.values_pool.snapshot();
        worker.out_states = try StateBuffer.init(
            &worker.candidate_arena,
            self.max_successors,
        );
        worker.compose_states = try StateBuffer.init(
            &worker.candidate_arena,
            self.max_successors,
        );
        worker.prepared_fingerprints = try worker.candidate_arena.alloc(
            fingerprint.Fingerprint,
            self.max_successors,
        );
        worker.prepared_invariants = try worker.candidate_arena.alloc(
            bool,
            self.max_successors,
        );
        worker.prepared_edge_masks = try worker.candidate_arena.alloc(
            u64,
            self.max_successors,
        );
        worker.prepared_generated = 0;
        worker.composition_generated = 0;
        worker.source_snapshot = self.state_store;
    }

    fn prepare_generated(
        self: *Checker,
        parent_idx: u32,
        out_states: *StateBuffer,
        candidate_store: *StateStore,
        candidate_evaluator: *Evaluator,
        eval_pool: *ValuePool,
        prepared_fingerprints: []fingerprint.Fingerprint,
        prepared_invariants: []bool,
        prepared_edge_masks: []u64,
    ) !void {
        assert(self.worker_count > 1);
        assert(!self.symmetry_hash_cache.enabled);
        assert(out_states.items.len <= prepared_fingerprints.len);
        assert(out_states.items.len <= prepared_invariants.len);
        assert(out_states.items.len <= prepared_edge_masks.len);
        var kept_count: u32 = 0;
        var action_parent = try self.clone_parent_for_action_constraints(
            parent_idx,
            candidate_store,
        );
        for (out_states.items) |candidate_index| {
            assert(candidate_index < candidate_store.count);
            const candidate = candidate_store.get(candidate_index);
            candidate.pred = parent_idx;
            candidate.level = self.state_store.get(parent_idx).level + 1;
            const snapshot = eval_pool.snapshot();
            defer eval_pool.restore(snapshot);
            if (!try self.check_candidate_constraints(
                candidate,
                candidate_store,
                candidate_evaluator,
                eval_pool,
            )) continue;
            if (action_parent) |*parent| {
                if (!try self.check_candidate_action_constraints(
                    parent,
                    candidate,
                    candidate_store,
                    candidate_evaluator,
                    eval_pool,
                )) continue;
            }
            const candidate_fingerprint = symmetry_fingerprint(
                &candidate_store.values_pool,
                &self.state_store.values_pool,
                &self.symmetry_hash_cache,
                candidate,
                self.symmetry_permutations,
            );
            out_states.items[kept_count] = candidate_index;
            prepared_fingerprints[kept_count] = candidate_fingerprint;
            prepared_invariants[kept_count] = true;
            prepared_edge_masks[kept_count] = prepared_edge_masks[
                @intCast(candidate_index)
            ];
            kept_count += 1;
        }
        out_states.shrink(kept_count);
    }

    fn process_prepared_generated(
        self: *Checker,
        parent_idx: u32,
        out_states: *StateBuffer,
        candidate_store: *StateStore,
        evaluator: *Evaluator,
        eval_pool: *ValuePool,
        prepared_fingerprints: []const fingerprint.Fingerprint,
        prepared_invariants: []const bool,
        prepared_edge_masks: []u64,
    ) !void {
        assert(out_states.items.len <= prepared_fingerprints.len);
        assert(out_states.items.len <= prepared_invariants.len);
        assert(out_states.items.len <= prepared_edge_masks.len);
        var kept_count: u32 = 0;
        for (out_states.items, 0..) |*candidate_index, prepared_index| {
            const candidate = candidate_store.get(candidate_index.*);
            const state_fingerprint = prepared_fingerprints[prepared_index];
            const canonical = self.fp_set.find(state_fingerprint);
            const is_new = canonical == null;
            const state_idx = if (canonical) |existing| existing else blk: {
                const permanent_idx = try self.clone_candidate_state(
                    candidate,
                    candidate_store,
                    parent_idx,
                );
                assert(self.fp_set.put_with_index(
                    state_fingerprint,
                    permanent_idx,
                ) == null);
                break :blk permanent_idx;
            };
            if (is_new) {
                self.distinct += 1;
                assert(self.distinct <= self.max_states_limit);
                if (self.graph_enabled) {
                    self.canonical_states[state_idx] = true;
                }
            }
            if (is_new) {
                const invariant_snapshot = eval_pool.snapshot();
                const invariants_hold = try self.check_invariants_with(
                    evaluator,
                    eval_pool,
                    self.state_store.get(state_idx),
                );
                eval_pool.restore(invariant_snapshot);
                if (!invariants_hold) {
                    std.debug.print(
                        "InvariantViolated generated={d} distinct={d}\n",
                        .{ self.generated, self.distinct },
                    );
                    self.print_trace(state_idx);
                    return Error.InvariantViolated;
                }
            }
            if (is_new and !self.queue.enqueue(state_idx)) {
                return Error.StateSpaceExhausted;
            }
            if (deduplicate_successor(
                out_states.items[0..kept_count],
                prepared_edge_masks[0..kept_count],
                state_idx,
                prepared_edge_masks[prepared_index],
            )) continue;
            self.generated += 1;
            candidate_index.* = state_idx;
            out_states.items[kept_count] = state_idx;
            prepared_edge_masks[kept_count] = prepared_edge_masks[prepared_index];
            kept_count += 1;
        }
        out_states.shrink(kept_count);
        try self.record_successors(parent_idx, out_states, prepared_edge_masks);
    }

    fn process_generated(
        self: *Checker,
        parent_idx: ?u32,
        out_states: *StateBuffer,
        candidate_store: *StateStore,
        candidate_evaluator: *Evaluator,
        edge_masks: []u64,
    ) !void {
        // First pass: check constraints/invariants, canonicalize duplicates,
        // and enqueue newly discovered states. After this loop, out_states
        // contains canonical indices for graph edges.
        var kept_count: u32 = 0;
        var action_parent = if (parent_idx) |pidx|
            try self.clone_parent_for_action_constraints(
                pidx,
                candidate_store,
            )
        else
            null;
        for (out_states.items) |*idx| {
            assert(idx.* < candidate_store.count);
            const candidate_index = idx.*;
            const candidate = candidate_store.get(idx.*);
            if (parent_idx) |pidx| {
                candidate.pred = pidx;
                candidate.level = self.state_store.get(pidx).level + 1;
            }
            const snap = self.eval_pool.snapshot();
            const constraints_hold = try self.check_candidate_constraints(
                candidate,
                candidate_store,
                candidate_evaluator,
                &self.eval_pool,
            );
            if (!constraints_hold) {
                self.eval_pool.restore(snap);
                idx.* = std.math.maxInt(u32);
                continue;
            }
            const action_constraints_hold =
                if (action_parent) |*parent|
                    try self.check_candidate_action_constraints(
                        parent,
                        candidate,
                        candidate_store,
                        candidate_evaluator,
                        &self.eval_pool,
                    )
                else
                    true;
            if (!action_constraints_hold) {
                self.eval_pool.restore(snap);
                idx.* = std.math.maxInt(u32);
                continue;
            }
            const fp = symmetry_fingerprint(
                &candidate_store.values_pool,
                &self.state_store.values_pool,
                &self.symmetry_hash_cache,
                candidate,
                self.symmetry_permutations,
            );
            const canonical = self.fp_set.find(fp);
            const is_new = canonical == null;
            const state_idx = if (canonical) |existing| existing else blk: {
                const permanent_idx = try self.clone_candidate_state(
                    candidate,
                    candidate_store,
                    parent_idx,
                );
                assert(self.fp_set.put_with_index(fp, permanent_idx) == null);
                break :blk permanent_idx;
            };
            if (is_new) {
                self.distinct += 1;
                assert(self.distinct <= self.max_states_limit);
                if (self.graph_enabled) {
                    self.canonical_states[state_idx] = true;
                }
            }
            if (parent_idx == null) {
                if (self.graph_enabled) {
                    assert(self.canonical_states[state_idx]);
                    self.initial_states[state_idx] = true;
                }
            }
            const invariants_hold = if (is_new)
                try self.check_invariants(self.state_store.get(state_idx))
            else
                true;
            self.eval_pool.restore(snap);
            if (!invariants_hold) {
                std.debug.print("InvariantViolated generated={d} distinct={d}\n", .{ self.generated, self.distinct });
                self.print_trace(state_idx);
                return Error.InvariantViolated;
            }
            if (is_new) {
                if (!self.queue.enqueue(state_idx)) {
                    return Error.StateSpaceExhausted;
                }
            }
            if (deduplicate_successor(
                out_states.items[0..kept_count],
                edge_masks[0..kept_count],
                state_idx,
                edge_masks[@intCast(candidate_index)],
            )) continue;
            self.generated += 1;
            idx.* = state_idx;
            out_states.items[kept_count] = state_idx;
            edge_masks[kept_count] = edge_masks[@intCast(candidate_index)];
            kept_count += 1;
        }
        out_states.shrink(kept_count);
        try self.record_successors(parent_idx, out_states, edge_masks);
    }

    fn record_successors(
        self: *Checker,
        parent_idx: ?u32,
        out_states: *StateBuffer,
        edge_masks: []const u64,
    ) !void {
        if (parent_idx) |pidx| {
            const count: u32 = @intCast(out_states.items.len);
            assert(edge_masks.len >= count);
            if (self.graph_enabled) {
                if (self.succ_count + count > self.succ_cap) {
                    return Error.OutOfMemory;
                }
                self.succ_offsets[pidx] = self.succ_count;
                self.succ_counts[pidx] = count;
                for (out_states.items, 0..) |idx, i| {
                    assert(idx < self.state_store.count);
                    self.succ_edges[self.succ_count + i] = idx;
                    self.edge_action_masks[self.succ_count + i] = edge_masks[i];
                }
                self.succ_count += count;
            }
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

    fn deduplicate_successor(
        states: []const u32,
        edge_masks: []u64,
        state_idx: u32,
        edge_mask: u64,
    ) bool {
        assert(edge_masks.len >= states.len);
        for (states, 0..) |existing, index| {
            if (existing != state_idx) continue;
            edge_masks[index] |= edge_mask;
            return true;
        }
        return false;
    }

    fn clone_candidate_state(
        self: *Checker,
        candidate: *StateStore.State,
        candidate_store: *StateStore,
        parent_idx: ?u32,
    ) !u32 {
        const state_idx = try self.state_store.alloc_state();
        const state = self.state_store.get(state_idx);
        state.level = candidate.level;
        state.pred = candidate.pred;
        state.changed_mask = candidate.changed_mask;
        state.borrowed_mask = 0;
        state.borrowed_pool = null;
        for (candidate.values, state.values, 0..) |source, *target, variable_index| {
            const changed = parent_idx == null or
                (candidate.changed_mask &
                    (@as(u64, 1) << @intCast(variable_index))) != 0;
            if (changed) {
                target.* = try self.intern_canonical_value(
                    source,
                    &candidate_store.values_pool,
                    @intCast(variable_index),
                );
                assert(Value.eql_cross_pool(
                    source,
                    &candidate_store.values_pool,
                    target.*,
                    &self.state_store.values_pool,
                ));
            } else {
                target.* = self.state_store.get(parent_idx.?).values[variable_index];
            }
        }
        return state_idx;
    }

    fn intern_canonical_value(
        self: *Checker,
        source: Value,
        source_pool: *const ValuePool,
        variable_index: u16,
    ) !Value {
        if (self.canonical_value_entries.len == 0) {
            return source.clone(
                source_pool,
                &self.state_store.values_pool,
            );
        }
        switch (source) {
            .bool_v, .int_v, .model_v, .range_v => return source,
            .string_v => {
                return source.clone(
                    source_pool,
                    &self.state_store.values_pool,
                );
            },
            else => {},
        }
        assert(self.canonical_value_entries.len > 0);
        assert(std.math.isPowerOfTwo(self.canonical_value_entries.len));
        const hash = fingerprint.hash_value(
            source_pool,
            source,
            fingerprint.hash_init(),
        );
        const mixed_hash = fingerprint.hash_combine(hash, variable_index);
        const mask = self.canonical_value_entries.len - 1;
        var slot: usize = @intCast(mixed_hash & mask);
        var probes: usize = 0;
        while (probes < self.canonical_value_entries.len) : (probes += 1) {
            const entry = &self.canonical_value_entries[slot];
            if (!entry.occupied) {
                const canonical = try source.clone(
                    source_pool,
                    &self.state_store.values_pool,
                );
                entry.* = .{
                    .hash = hash,
                    .value = canonical,
                    .variable_index = variable_index,
                    .occupied = true,
                };
                return canonical;
            }
            if (entry.hash == hash and
                entry.variable_index == variable_index and
                Value.eql_cross_pool(
                    source,
                    source_pool,
                    entry.value,
                    &self.state_store.values_pool,
                ))
            {
                return entry.value;
            }
            slot = (slot + 1) & mask;
        }
        return source.clone(
            source_pool,
            &self.state_store.values_pool,
        );
    }

    fn check_candidate_constraints(
        self: *Checker,
        candidate: *StateStore.State,
        candidate_store: *StateStore,
        candidate_evaluator: *Evaluator,
        eval_pool: *ValuePool,
    ) !bool {
        assert(self.constraint_names.len == self.constraints.len);
        for (self.constraint_names) |constraint_name| {
            const value = candidate_evaluator.eval_named_zero(
                constraint_name,
                Context.empty(),
                candidate,
                eval_pool,
                &candidate_store.values_pool,
            ) catch |err| {
                std.debug.print("Error evaluating candidate constraint {s}: {any}\n", .{
                    constraint_name,
                    err,
                });
                return err;
            };
            if (!value.is_truthy()) return false;
        }
        return true;
    }

    fn check_candidate_invariants(
        self: *Checker,
        candidate: *StateStore.State,
        candidate_store: *StateStore,
        candidate_evaluator: *Evaluator,
        eval_pool: *ValuePool,
    ) !bool {
        assert(self.invariant_names.len == self.invariants.len);
        for (self.invariant_names) |invariant_name| {
            const value = candidate_evaluator.eval_named_zero(
                invariant_name,
                Context.empty(),
                candidate,
                eval_pool,
                &candidate_store.values_pool,
            ) catch |err| {
                std.debug.print("Error evaluating candidate invariant {s}: {any}\n", .{
                    invariant_name,
                    err,
                });
                return err;
            };
            if (!value.is_truthy()) return false;
        }
        return true;
    }

    fn clone_parent_for_action_constraints(
        self: *Checker,
        parent_idx: u32,
        candidate_store: *StateStore,
    ) !?StateStore.State {
        if (self.action_constraints.len == 0) return null;
        const source = self.state_store.get(parent_idx);
        const values = try candidate_store.values_pool.alloc_values(
            @intCast(source.values.len),
        );
        for (source.values, values) |value, *target| {
            target.* = try value.clone(
                &self.state_store.values_pool,
                &candidate_store.values_pool,
            );
        }
        return StateStore.State{
            .level = source.level,
            .pred = source.pred,
            .changed_mask = 0,
            .borrowed_mask = 0,
            .borrowed_pool = null,
            .values = values,
        };
    }

    fn check_candidate_action_constraints(
        self: *Checker,
        parent: *StateStore.State,
        candidate: *StateStore.State,
        candidate_store: *StateStore,
        candidate_evaluator: *Evaluator,
        eval_pool: *ValuePool,
    ) !bool {
        assert(self.action_constraints.len > 0);
        assert(self.action_constraint_names.len ==
            self.action_constraints.len);
        candidate_evaluator.set_next_state(candidate);
        defer candidate_evaluator.set_next_state(null);
        for (self.action_constraint_names) |constraint_name| {
            const value = try candidate_evaluator.eval_named_zero(
                constraint_name,
                Context.empty(),
                parent,
                eval_pool,
                &candidate_store.values_pool,
            );
            if (!value.is_truthy()) return false;
        }
        return true;
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
                const vars_child = try self.evaluator.eval_expr(ba.vars, Context.empty(), child, &self.eval_pool, &self.state_store.values_pool);
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
        // Finalize graph bounds. Successor ranges use explicit per-state
        // counts because raw state ids can have gaps from deduped allocations.
        const n = self.state_store.count;
        if (n > 0) {
            assert(n + 1 <= self.succ_offsets.len);
            self.succ_offsets[n] = self.succ_count;
        }

        const scc_data = try self.build_scc_data();
        defer scc_data.deinit();

        var cache = PropertyCache.init(self.arena);
        for (self.properties) |prop| {
            const results = try self.eval_temporal_property_all(prop, &scc_data, &cache);
            var initial_count: u32 = 0;
            for (0..n) |i| {
                if (!self.initial_states[i]) continue;
                initial_count += 1;
                if (!results[i]) {
                    std.debug.print("PropertyViolated: property at initial state={d}\n", .{i});
                    return Error.PropertyViolated;
                }
            }
            assert(initial_count > 0);
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
        pred_offsets: []u32,
        pred_edges: []u32,
        fair_sccs: []bool,
        fair_region: []bool,
        allocator: std.mem.Allocator,

        fn deinit(self: SccData) void {
            self.allocator.free(self.scc_ids);
            self.allocator.free(self.scc_succ_offsets);
            self.allocator.free(self.scc_succ_edges);
            self.allocator.free(self.scc_states_offsets);
            self.allocator.free(self.scc_states_edges);
            self.allocator.free(self.pred_offsets);
            self.allocator.free(self.pred_edges);
            self.allocator.free(self.fair_sccs);
            self.allocator.free(self.fair_region);
        }
    };

    fn scc_edge_key(from: u32, to: u32) u64 {
        return (@as(u64, from) << 32) | @as(u64, to);
    }

    fn scc_edge_key_from(key: u64) u32 {
        return @intCast(key >> 32);
    }

    fn scc_edge_key_to(key: u64) u32 {
        return @intCast(key & 0xffff_ffff);
    }

    fn build_scc_data(self: *Checker) !SccData {
        const n = self.state_store.count;
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
        var scc_edge_keys = try allocator.alloc(u64, self.succ_count);
        defer allocator.free(scc_edge_keys);
        var scc_edge_count: u32 = 0;
        for (0..n) |i| {
            const idx: u32 = @intCast(i);
            const from = scc_ids[idx];
            for (self.successors(idx)) |succ| {
                if (succ == idx) continue; // skip stuttering self-loops for liveness
                const to = scc_ids[succ];
                if (from == to) continue;
                assert(scc_edge_count < scc_edge_keys.len);
                scc_edge_keys[scc_edge_count] = scc_edge_key(from, to);
                scc_edge_count += 1;
            }
        }
        const scc_edges = scc_edge_keys[0..scc_edge_count];
        std.mem.sort(u64, scc_edges, {}, std.sort.asc(u64));
        var unique_edge_count: u32 = 0;
        var previous_key: ?u64 = null;
        for (scc_edges) |key| {
            if (previous_key != null and previous_key.? == key) continue;
            const from = scc_edge_key_from(key);
            assert(from < scc_count);
            scc_succ_counts[from] += 1;
            unique_edge_count += 1;
            previous_key = key;
        }

        var scc_succ_offsets = try allocator.alloc(u32, scc_count + 1);
        var total_edges: u32 = 0;
        for (0..scc_count) |i| {
            scc_succ_offsets[i] = total_edges;
            total_edges += scc_succ_counts[i];
        }
        assert(total_edges == unique_edge_count);
        scc_succ_offsets[scc_count] = total_edges;

        var scc_succ_edges = try allocator.alloc(u32, total_edges);
        @memcpy(fill, scc_succ_offsets[0..scc_count]);
        previous_key = null;
        for (scc_edges) |key| {
            if (previous_key != null and previous_key.? == key) continue;
            const from = scc_edge_key_from(key);
            const to = scc_edge_key_to(key);
            assert(from < scc_count);
            assert(to < scc_count);
            scc_succ_edges[fill[from]] = to;
            fill[from] += 1;
            previous_key = key;
        }
        for (0..scc_count) |i| {
            assert(fill[i] == scc_succ_offsets[i + 1]);
        }

        const fair_sccs = try self.compute_fair_sccs(scc_ids, scc_count, scc_states_offsets, scc_states_edges, allocator);
        const fair_region = try self.compute_fair_region(scc_ids, scc_count, scc_succ_offsets, scc_succ_edges, fair_sccs, n, allocator);
        const reverse = try self.build_reverse_graph(allocator, n);

        return SccData{
            .scc_ids = scc_ids,
            .scc_count = scc_count,
            .scc_succ_offsets = scc_succ_offsets,
            .scc_succ_edges = scc_succ_edges,
            .scc_states_offsets = scc_states_offsets,
            .scc_states_edges = scc_states_edges,
            .pred_offsets = reverse.offsets,
            .pred_edges = reverse.edges,
            .fair_sccs = fair_sccs,
            .fair_region = fair_region,
            .allocator = allocator,
        };
    }

    const ReverseGraph = struct {
        offsets: []u32,
        edges: []u32,
    };

    fn build_reverse_graph(
        self: *Checker,
        allocator: std.mem.Allocator,
        state_count: u32,
    ) Error!ReverseGraph {
        const counts = try allocator.alloc(u32, state_count);
        defer allocator.free(counts);
        @memset(counts, 0);
        var edge_count: u32 = 0;
        for (0..state_count) |state_index_usize| {
            const state_index: u32 = @intCast(state_index_usize);
            for (self.successors(state_index)) |successor| {
                assert(successor < state_count);
                counts[successor] += 1;
                edge_count += 1;
            }
        }

        const offsets = try allocator.alloc(u32, state_count + 1);
        errdefer allocator.free(offsets);
        var offset: u32 = 0;
        for (counts, 0..) |count, i| {
            offsets[i] = offset;
            offset += count;
        }
        assert(offset == edge_count);
        offsets[state_count] = edge_count;

        const edges = try allocator.alloc(u32, edge_count);
        errdefer allocator.free(edges);
        const fill = try allocator.alloc(u32, state_count);
        defer allocator.free(fill);
        @memcpy(fill, offsets[0..state_count]);
        for (0..state_count) |state_index_usize| {
            const state_index: u32 = @intCast(state_index_usize);
            for (self.successors(state_index)) |successor| {
                edges[fill[successor]] = state_index;
                fill[successor] += 1;
            }
        }
        return .{ .offsets = offsets, .edges = edges };
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
        const n = self.state_store.count;
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
                const state_index: u32 = @intCast(s);
                const begin = self.succ_offsets[state_index];
                const end = begin + self.succ_counts[state_index];
                for (begin..end) |edge_index_usize| {
                    const edge_index: u32 = @intCast(edge_index_usize);
                    const succ = self.succ_edges[edge_index];
                    const mask = self.edge_action_masks[edge_index];
                    if ((mask & (@as(u64, 1) << @intCast(fi))) != 0) {
                        enabled[fi][s] = true;
                        const from_scc = scc_ids[state_index];
                        const to_scc = scc_ids[succ];
                        if (from_scc == to_scc) {
                            has_angle[fi * scc_count + from_scc] = true;
                        }
                    }
                }
            }
            _ = fc;
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

    fn eval_action(self: *Checker, action_expr: *ast.Expr, context: Context, parent: *StateStore.State, child: *StateStore.State) Error!bool {
        const snap = self.eval_pool.snapshot();
        defer self.eval_pool.restore(snap);
        const context_snap = self.evaluator.context_snapshot();
        defer self.evaluator.restore_context_pool(context_snap);
        self.evaluator.set_next_state(child);
        defer self.evaluator.set_next_state(null);
        const v = try self.evaluator.eval_expr(action_expr, context, parent, &self.eval_pool, &self.state_store.values_pool);
        return v.is_truthy();
    }

    fn eval_vars_equal(self: *Checker, vars_expr: *ast.Expr, context: Context, a: *StateStore.State, b: *StateStore.State) Error!bool {
        const snap = self.eval_pool.snapshot();
        defer self.eval_pool.restore(snap);
        const context_snap = self.evaluator.context_snapshot();
        defer self.evaluator.restore_context_pool(context_snap);
        const va = try self.evaluator.eval_expr(vars_expr, context, a, &self.eval_pool, &self.state_store.values_pool);
        const vb = try self.evaluator.eval_expr(vars_expr, context, b, &self.eval_pool, &self.state_store.values_pool);
        return va.eql(vb, &self.eval_pool);
    }

    fn eval_temporal_property_all(
        self: *Checker,
        prop: *ast.Expr,
        scc_data: *const SccData,
        cache: *PropertyCache,
    ) Error![]bool {
        if (cache.get(prop)) |cached| return cached;

        const n = self.state_store.count;
        const results = try std.heap.page_allocator.alloc(bool, n);
        errdefer std.heap.page_allocator.free(results);

        const snap = self.eval_pool.snapshot();
        defer self.eval_pool.restore(snap);

        switch (prop.*) {
            .ident => |name| {
                if (self.evaluator.find_definition(name)) |def| {
                    const resolved = try self.eval_temporal_property_all(def.body, scc_data, cache);
                    @memcpy(results, resolved);
                } else {
                    for (0..n) |i| {
                        results[i] = try self.eval_temporal_state_expr(
                            prop,
                            @intCast(i),
                        );
                    }
                }
            },
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
                            results[i] = try self.eval_temporal_state_expr(
                                prop,
                                @intCast(i),
                            );
                        }
                    },
                }
            },
            .unary => |u| {
                switch (u.op) {
                    .not => {
                        const operand = try self.eval_temporal_property_all(
                            u.operand,
                            scc_data,
                            cache,
                        );
                        for (0..n) |i| {
                            results[i] = !operand[i];
                        }
                    },
                    .enabled => {
                        for (0..n) |i| {
                            results[i] = try self.eval_enabled_action(
                                u.operand,
                                @intCast(i),
                            );
                        }
                    },
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
                            results[i] = try self.eval_temporal_state_expr(
                                prop,
                                @intCast(i),
                            );
                        }
                    },
                }
            },
            .box_action => |ba| {
                for (0..n) |i| {
                    const state_idx: u32 = @intCast(i);
                    if (!self.canonical_states[state_idx]) {
                        results[i] = true;
                        continue;
                    }
                    const parent = self.state_store.get(state_idx);
                    var holds = true;
                    for (self.successors(state_idx)) |succ| {
                        const child = self.state_store.get(succ);
                        if (try self.eval_action(ba.action, Context.empty(), parent, child)) continue;
                        if (!try self.eval_vars_equal(ba.vars, Context.empty(), parent, child)) {
                            holds = false;
                            break;
                        }
                    }
                    results[i] = holds;
                }
            },
            else => {
                for (0..n) |i| {
                    results[i] = try self.eval_temporal_state_expr(
                        prop,
                        @intCast(i),
                    );
                }
            },
        }

        try cache.put(std.heap.page_allocator, prop, results);
        return results;
    }

    fn eval_enabled_action(
        self: *Checker,
        action_expr: *ast.Expr,
        state_index: u32,
    ) Error!bool {
        const parent = self.state_store.get(state_index);
        for (self.successors(state_index)) |successor| {
            const child = self.state_store.get(successor);
            if (try self.eval_action(
                action_expr,
                Context.empty(),
                parent,
                child,
            )) return true;
        }
        return false;
    }

    fn eval_temporal_state_expr(
        self: *Checker,
        prop: *ast.Expr,
        state_index: u32,
    ) Error!bool {
        const snap = self.eval_pool.snapshot();
        defer self.eval_pool.restore(snap);
        if (contains_enabled(prop)) {
            self.evaluator.set_enabled_result(
                self.successors(state_index).len > 0,
            );
            defer self.evaluator.set_enabled_result(null);
        }
        const st = self.state_store.get(state_index);
        const value = try self.evaluator.eval_expr(
            prop,
            Context.empty(),
            st,
            &self.eval_pool,
            &self.state_store.values_pool,
        );
        return value.is_truthy();
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
        const n = self.state_store.count;
        assert(n > 0);
        assert(n == operand.len);
        assert(n == scc_data.scc_ids.len);
        assert(n == scc_data.fair_region.len);
        const results = try std.heap.page_allocator.alloc(bool, n);
        errdefer std.heap.page_allocator.free(results);
        @memset(results, true);
        const work = try std.heap.page_allocator.alloc(u32, n);
        defer std.heap.page_allocator.free(work);
        var work_len: u32 = 0;
        for (operand, 0..) |holds, state_index_usize| {
            const state_index: u32 = @intCast(state_index_usize);
            if (!scc_data.fair_region[state_index] or holds) continue;
            results[state_index] = false;
            work[work_len] = state_index;
            work_len += 1;
        }
        while (work_len > 0) {
            work_len -= 1;
            const state_index = work[work_len];
            const begin = scc_data.pred_offsets[state_index];
            const end = scc_data.pred_offsets[state_index + 1];
            for (scc_data.pred_edges[begin..end]) |predecessor| {
                if (!scc_data.fair_region[predecessor]) continue;
                if (!results[predecessor]) continue;
                results[predecessor] = false;
                work[work_len] = predecessor;
                work_len += 1;
            }
        }
        return results;
    }

    fn eval_diamond_all(self: *Checker, operand: []const bool, scc_data: *const SccData) Error![]bool {
        const n = self.state_store.count;
        assert(n > 0);
        assert(n == operand.len);
        assert(n == scc_data.scc_ids.len);
        assert(n == scc_data.fair_region.len);
        const results = try std.heap.page_allocator.alloc(bool, n);
        errdefer std.heap.page_allocator.free(results);

        // <>P is false exactly when there is a fair infinite behavior that
        // avoids P forever. Such a behavior exists from a state iff a fair SCC
        // containing no P is reachable through states that also do not satisfy P.
        var bad = try std.heap.page_allocator.alloc(bool, n);
        defer std.heap.page_allocator.free(bad);
        @memset(bad, false);
        var work = try std.heap.page_allocator.alloc(u32, n);
        defer std.heap.page_allocator.free(work);
        var work_len: u32 = 0;

        for (0..scc_data.scc_count) |scc_index| {
            const scc: u32 = @intCast(scc_index);
            if (!scc_data.fair_sccs[scc]) continue;
            var has_operand = false;
            const begin = scc_data.scc_states_offsets[scc];
            const end = scc_data.scc_states_offsets[scc + 1];
            for (scc_data.scc_states_edges[begin..end]) |state_idx| {
                if (operand[state_idx]) {
                    has_operand = true;
                    break;
                }
            }
            if (has_operand) continue;
            for (scc_data.scc_states_edges[begin..end]) |state_idx| {
                if (bad[state_idx]) continue;
                assert(!operand[state_idx]);
                bad[state_idx] = true;
                work[work_len] = state_idx;
                work_len += 1;
            }
        }

        while (work_len > 0) {
            work_len -= 1;
            const cur = work[work_len];
            const begin = scc_data.pred_offsets[cur];
            const end = scc_data.pred_offsets[cur + 1];
            for (scc_data.pred_edges[begin..end]) |pred| {
                if (bad[pred] or operand[pred]) continue;
                bad[pred] = true;
                work[work_len] = pred;
                work_len += 1;
            }
        }

        for (0..n) |i| {
            results[i] = !bad[i];
        }
        return results;
    }

    fn compute_sccs(self: *Checker) ![]u32 {
        const n = self.state_store.count;
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
        assert(idx < self.state_store.count);
        const begin = self.succ_offsets[idx];
        const end = begin + self.succ_counts[idx];
        assert(begin <= end);
        assert(end <= self.succ_edges.len);
        assert(end <= self.succ_count);
        const slice = self.succ_edges[begin..end];
        for (slice) |s| assert(s < self.state_store.count);
        return slice;
    }

    fn check_constraints(self: *Checker, st: *StateStore.State) !bool {
        assert(self.constraint_names.len == self.constraints.len);
        for (self.constraint_names) |constraint_name| {
            const v = self.evaluator.eval_named_zero(
                constraint_name,
                Context.empty(),
                st,
                &self.eval_pool,
                &self.state_store.values_pool,
            ) catch |err| {
                std.debug.print("Error evaluating constraint {s}: {any}\n", .{
                    constraint_name,
                    err,
                });
                return err;
            };
            if (!v.is_truthy()) return false;
        }
        return true;
    }

    fn check_invariants(self: *Checker, st: *StateStore.State) !bool {
        return self.check_invariants_with(
            &self.evaluator,
            &self.eval_pool,
            st,
        );
    }

    fn check_invariants_with(
        self: *Checker,
        evaluator: *Evaluator,
        eval_pool: *ValuePool,
        st: *StateStore.State,
    ) !bool {
        assert(self.invariant_names.len == self.invariants.len);
        for (self.invariants, 0..) |inv, i| {
            if (contains_enabled(inv)) continue;
            const v = evaluator.eval_named_zero(
                self.invariant_names[i],
                Context.empty(),
                st,
                eval_pool,
                &self.state_store.values_pool,
            ) catch |err| {
                if (i < self.invariant_names.len) {
                    std.debug.print("Error evaluating invariant {s}: {any}\n", .{ self.invariant_names[i], err });
                }
                return err;
            };
            if (!v.is_truthy()) {
                std.debug.print("Invariant false: {s}\n", .{self.invariant_names[i]});
                try self.print_first_false_conjunct(inv, st);
                return false;
            }
        }
        return true;
    }

    fn check_enabled_invariants(self: *Checker, state_idx: u32, enabled: bool) !void {
        assert(state_idx < self.state_store.count);
        self.evaluator.set_enabled_result(enabled);
        defer self.evaluator.set_enabled_result(null);
        const st = self.state_store.get(state_idx);
        for (self.invariants, 0..) |inv, i| {
            if (!contains_enabled(inv)) continue;
            const value = self.evaluator.eval_expr(
                inv,
                Context.empty(),
                st,
                &self.eval_pool,
                &self.state_store.values_pool,
            ) catch |err| {
                std.debug.print("Error evaluating ENABLED invariant {s}: {any}\n", .{
                    self.invariant_names[i],
                    err,
                });
                return err;
            };
            if (!value.is_truthy()) {
                std.debug.print("Invariant false: {s}\n", .{self.invariant_names[i]});
                try self.print_first_false_conjunct(inv, st);
                std.debug.print("InvariantViolated generated={d} distinct={d}\n", .{
                    self.generated,
                    self.distinct,
                });
                self.print_trace(state_idx);
                return Error.InvariantViolated;
            }
        }
    }

    fn print_first_false_conjunct(self: *Checker, expr: *ast.Expr, st: *StateStore.State) !void {
        var index: u32 = 0;
        _ = try self.print_first_false_conjunct_inner(expr, st, &index);
    }

    fn print_first_false_conjunct_inner(self: *Checker, expr: *ast.Expr, st: *StateStore.State, index: *u32) !bool {
        if (expr.* == .ident) {
            const name = self.evaluator.resolve_alias(expr.ident);
            if (self.evaluator.find_definition(name)) |def| {
                return try self.print_first_false_conjunct_inner(def.body, st, index);
            }
            if (self.evaluator.find_subexpression(name)) |body| {
                return try self.print_first_false_conjunct_inner(body, st, index);
            }
        }
        if (expr.* == .binary and expr.*.binary.op == .and_op) {
            if (try self.print_first_false_conjunct_inner(expr.*.binary.left, st, index)) return true;
            return try self.print_first_false_conjunct_inner(expr.*.binary.right, st, index);
        }
        const current = index.*;
        index.* += 1;
        const snap = self.eval_pool.snapshot();
        defer self.eval_pool.restore(snap);
        const v = try self.evaluator.eval_expr(expr, Context.empty(), st, &self.eval_pool, &self.state_store.values_pool);
        if (!v.is_truthy()) {
            std.debug.print("First false conjunct #{d}: {s}\n", .{ current, @tagName(expr.*) });
            return true;
        }
        return false;
    }

    fn print_trace(self: *Checker, state_idx: u32) void {
        assert(state_idx < self.state_store.count);
        var idx = state_idx;
        var remaining: u32 = self.state_store.get(idx).level + 1;
        while (remaining > 0) : (remaining -= 1) {
            const st = self.state_store.get(idx);
            std.debug.print("State {d} (level {d}):\n", .{ idx, st.level });
            for (self.state_store.variable_names, st.values) |name, value| {
                std.debug.print("  {s} = ", .{name});
                self.print_value(value, 0);
                std.debug.print("\n", .{});
            }
            if (st.level == 0) break;
            assert(st.pred < self.state_store.count);
            idx = st.pred;
        }
    }

    fn print_value(self: *Checker, value: Value, depth: u8) void {
        if (depth >= 16) {
            std.debug.print("...", .{});
            return;
        }
        const pool = &self.state_store.values_pool;
        switch (value) {
            .bool_v => |v| std.debug.print("{s}", .{if (v) "TRUE" else "FALSE"}),
            .int_v => |v| std.debug.print("{d}", .{v}),
            .string_v => |v| std.debug.print("\"{s}\"", .{v.slice(pool)}),
            .model_v => |v| std.debug.print("{s}", .{self.evaluator.models.get_name(v)}),
            .range_v => |v| std.debug.print("{d}..{d}", .{ v.lo, v.hi }),
            .seq_set_v => std.debug.print("<Seq>", .{}),
            .power_set_v => std.debug.print("<SUBSET>", .{}),
            .set_v => |set| {
                std.debug.print("{{", .{});
                for (set.items(pool), 0..) |item, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    self.print_value(item, depth + 1);
                }
                std.debug.print("}}", .{});
            },
            .tuple_v => |tuple| {
                std.debug.print("<<", .{});
                for (tuple.items(pool), 0..) |item, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    self.print_value(item, depth + 1);
                }
                std.debug.print(">>", .{});
            },
            .record_v => |record| {
                std.debug.print("[", .{});
                const fields = record.fields(pool);
                var i: u32 = 0;
                while (i < record.len) : (i += 1) {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s} |-> ", .{fields[i * 2].string_v.slice(pool)});
                    self.print_value(fields[i * 2 + 1], depth + 1);
                }
                std.debug.print("]", .{});
            },
            .function_v => |function| {
                std.debug.print("[", .{});
                const keys = function.domain.items(pool);
                const entries = function.entries(pool);
                for (keys, entries, 0..) |key, entry, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    self.print_value(key, depth + 1);
                    std.debug.print(" |-> ", .{});
                    self.print_value(entry, depth + 1);
                }
                std.debug.print("]", .{});
            },
            else => std.debug.print("<{s}>", .{@tagName(value)}),
        }
    }
};

fn print_definition_tail(module: ast.Module) void {
    const head_len = @min(module.definitions.len, 20);
    std.debug.print("first parsed definitions:", .{});
    for (module.definitions[0..head_len]) |def| {
        std.debug.print(" {s}", .{def.name});
    }
    std.debug.print("\n", .{});
    const start = module.definitions.len -| 12;
    std.debug.print("last parsed definitions:", .{});
    for (module.definitions[start..]) |def| {
        std.debug.print(" {s}", .{def.name});
    }
    std.debug.print("\n", .{});
}

fn contains_enabled(expr: *ast.Expr) bool {
    return switch (expr.*) {
        .unary => |u| u.op == .enabled or contains_enabled(u.operand),
        .binary => |b| contains_enabled(b.left) or contains_enabled(b.right),
        .quantifier => |q| contains_enabled(q.body),
        .if_then_else => |ite| contains_enabled(ite.cond) or
            contains_enabled(ite.then_branch) or
            contains_enabled(ite.else_branch),
        .apply => |ap| blk: {
            if (contains_enabled(ap.func)) break :blk true;
            for (ap.args) |arg| {
                if (contains_enabled(arg)) break :blk true;
            }
            break :blk false;
        },
        .let_in => |let| blk: {
            for (let.defs) |def| {
                if (contains_enabled(def.body)) break :blk true;
            }
            break :blk contains_enabled(let.body);
        },
        .case_expr => |case| blk: {
            for (case.arms) |arm| {
                if (contains_enabled(arm.cond) or contains_enabled(arm.value)) break :blk true;
            }
            break :blk if (case.otherwise) |other| contains_enabled(other) else false;
        },
        else => false,
    };
}

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

fn collect_fairness(
    arena: *Arena,
    evaluator: *Evaluator,
    eval_pool: *ValuePool,
    state_pool: *ValuePool,
    expr: *ast.Expr,
    bindings: []const FairnessBinding,
    list: *std.ArrayList(FairnessCondition),
) !void {
    switch (expr.*) {
        .binary => |b| {
            if (b.op == .and_op) {
                try collect_fairness(
                    arena,
                    evaluator,
                    eval_pool,
                    state_pool,
                    b.left,
                    bindings,
                    list,
                );
                try collect_fairness(
                    arena,
                    evaluator,
                    eval_pool,
                    state_pool,
                    b.right,
                    bindings,
                    list,
                );
            }
        },
        .unary => |u| {
            try collect_fairness(
                arena,
                evaluator,
                eval_pool,
                state_pool,
                u.operand,
                bindings,
                list,
            );
        },
        .quantifier => |quantifier| {
            if (quantifier.kind != .forall or quantifier.vars.len != 1) return;
            const variable = quantifier.vars[0];
            const domain_values = try finite_fairness_domain(
                evaluator,
                eval_pool,
                state_pool,
                variable.domain,
                bindings,
            );
            defer std.heap.page_allocator.free(domain_values);
            for (domain_values) |value| {
                var expanded = std.ArrayList(FairnessBinding).empty;
                defer expanded.deinit(std.heap.page_allocator);
                try expanded.appendSlice(std.heap.page_allocator, bindings);
                try expanded.append(std.heap.page_allocator, .{
                    .name = variable.name,
                    .value = value,
                });
                try collect_fairness(
                    arena,
                    evaluator,
                    eval_pool,
                    state_pool,
                    quantifier.body,
                    expanded.items,
                    list,
                );
            }
        },
        .box_action => |ba| {
            try collect_fairness(
                arena,
                evaluator,
                eval_pool,
                state_pool,
                ba.action,
                bindings,
                list,
            );
        },
        .apply => |ap| {
            if (ap.func.* == .ident and ap.args.len == 1) {
                const name = ap.func.*.ident;
                if (starts_with(name, "WF_")) {
                    const vars_name = name[3..];
                    const full_vars = std.mem.eql(u8, vars_name, "vars");
                    const saved_bindings = try arena.alloc(
                        FairnessBinding,
                        bindings.len,
                    );
                    @memcpy(saved_bindings, bindings);
                    try list.append(std.heap.page_allocator, FairnessCondition{
                        .kind = .weak,
                        .action = ap.args[0],
                        .vars = try expr_ident(arena, vars_name),
                        .full_vars = full_vars,
                        .bindings = saved_bindings,
                    });
                } else if (starts_with(name, "SF_")) {
                    const vars_name = name[3..];
                    const full_vars = std.mem.eql(u8, vars_name, "vars");
                    const saved_bindings = try arena.alloc(
                        FairnessBinding,
                        bindings.len,
                    );
                    @memcpy(saved_bindings, bindings);
                    try list.append(std.heap.page_allocator, FairnessCondition{
                        .kind = .strong,
                        .action = ap.args[0],
                        .vars = try expr_ident(arena, vars_name),
                        .full_vars = full_vars,
                        .bindings = saved_bindings,
                    });
                }
            }
        },
        else => {},
    }
}

fn finite_fairness_domain(
    evaluator: *Evaluator,
    eval_pool: *ValuePool,
    state_pool: *ValuePool,
    domain: *ast.Expr,
    bindings: []const FairnessBinding,
) ![]Value {
    const snap = eval_pool.snapshot();
    defer eval_pool.restore(snap);
    const context_snap = evaluator.*.context_snapshot();
    defer evaluator.*.restore_context_pool(context_snap);

    var context = Context.empty();
    for (bindings) |binding| {
        context = try evaluator.*.extend_context(
            context,
            binding.name,
            binding.value,
        );
    }

    const domain_value = try evaluator.*.eval_expr(
        domain,
        context,
        null,
        eval_pool,
        state_pool,
    );
    var values = std.ArrayList(Value).empty;
    errdefer values.deinit(std.heap.page_allocator);
    switch (domain_value) {
        .range_v => |range| {
            if (range.hi < range.lo) {
                return try values.toOwnedSlice(std.heap.page_allocator);
            }
            var item = range.lo;
            while (item <= range.hi) : (item += 1) {
                try values.append(std.heap.page_allocator, .{ .int_v = item });
                if (item == std.math.maxInt(i64)) break;
            }
        },
        .set_v => |set| {
            for (set.items(eval_pool)) |item| {
                switch (item) {
                    .bool_v, .int_v, .model_v => try values.append(
                        std.heap.page_allocator,
                        item,
                    ),
                    else => return try values.toOwnedSlice(
                        std.heap.page_allocator,
                    ),
                }
            }
        },
        else => {},
    }
    return try values.toOwnedSlice(std.heap.page_allocator);
}

fn extract_fairness(
    arena: *Arena,
    evaluator: *Evaluator,
    eval_pool: *ValuePool,
    state_pool: *ValuePool,
    module: ast.Module,
    spec_name: []const u8,
) ![]const FairnessCondition {
    var list = std.ArrayList(FairnessCondition).empty;
    defer list.deinit(std.heap.page_allocator);
    const body = resolve_definition(module, spec_name) orelse return &[_]FairnessCondition{};
    try collect_fairness(
        arena,
        evaluator,
        eval_pool,
        state_pool,
        body,
        &.{},
        &list,
    );
    const result = try arena.alloc(FairnessCondition, list.items.len);
    @memcpy(result, list.items);
    return result;
}

fn build_fairness_markers(
    arena: *Arena,
    fairness: []const FairnessCondition,
) ![]const action.FairnessMarker {
    assert(fairness.len <= 64);
    if (fairness.len == 0) return &[_]action.FairnessMarker{};
    const markers = try arena.alloc(action.FairnessMarker, fairness.len);
    for (fairness, 0..) |condition, index| {
        markers[index] = .{
            .action = condition.action,
            .bindings = condition.bindings,
            .bit_index = @intCast(index),
        };
    }
    return markers;
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

fn evaluate_symmetry(
    arena: *Arena,
    cfg: Config,
    evaluator: *Evaluator,
    eval_pool: *ValuePool,
    state_pool: *ValuePool,
) ![]const []const u32 {
    const symmetry_name = cfg.symmetry_name orelse return &.{};
    const definition = evaluator.find_definition(symmetry_name) orelse
        return evaluator.fail(
            Error.UndefinedSymbol,
            "symmetry",
            symmetry_name,
        );
    const raw = try evaluator.eval_expr(
        definition.body,
        Context.empty(),
        null,
        eval_pool,
        state_pool,
    );
    const materialized = try evaluator.materialize_set(
        raw,
        Context.empty(),
        null,
        eval_pool,
        state_pool,
    );
    if (materialized != .set_v) {
        return evaluator.fail(
            Error.TypeError,
            "symmetry",
            @tagName(materialized),
        );
    }

    const model_count: usize = evaluator.models.count;
    if (model_count == 0) return &.{};
    var mappings = std.ArrayList([]u32).empty;
    defer {
        for (mappings.items) |mapping| {
            std.heap.page_allocator.free(mapping);
        }
        mappings.deinit(std.heap.page_allocator);
    }

    for (materialized.set_v.items(eval_pool)) |permutation_value| {
        if (permutation_value != .function_v) {
            return evaluator.fail(
                Error.TypeError,
                "symmetry permutation",
                @tagName(permutation_value),
            );
        }
        const mapping = try identity_mapping(model_count);
        errdefer std.heap.page_allocator.free(mapping);
        const function = permutation_value.function_v;
        for (
            function.domain.items(eval_pool),
            function.entries(eval_pool),
        ) |from, to| {
            if (from != .model_v or to != .model_v) {
                return evaluator.fail(
                    Error.TypeError,
                    "symmetry permutation",
                    "domain and range must contain model values",
                );
            }
            assert(from.model_v < mapping.len);
            assert(to.model_v < mapping.len);
            mapping[from.model_v] = to.model_v;
        }
        if (!mapping_is_identity(mapping) and
            !mapping_exists(mappings.items, mapping))
        {
            try mappings.append(std.heap.page_allocator, mapping);
        } else {
            std.heap.page_allocator.free(mapping);
        }
    }

    try mappings.ensureTotalCapacity(std.heap.page_allocator, 4096);
    const generator_count = mappings.items.len;
    var cursor: usize = 0;
    while (cursor < mappings.items.len) : (cursor += 1) {
        for (mappings.items[0..generator_count]) |generator| {
            if (mappings.items.len >= 4096) {
                return evaluator.fail(
                    Error.OutOfMemory,
                    "symmetry subgroup",
                    "more than 4096 permutations",
                );
            }
            const composed = try compose_mapping(
                generator,
                mappings.items[cursor],
            );
            errdefer std.heap.page_allocator.free(composed);
            if (!mapping_is_identity(composed) and
                !mapping_exists(mappings.items, composed))
            {
                try mappings.append(std.heap.page_allocator, composed);
            } else {
                std.heap.page_allocator.free(composed);
            }
        }
    }

    const result = try arena.alloc([]const u32, mappings.items.len);
    for (mappings.items, result) |mapping, *copy| {
        const destination = try arena.alloc(u32, mapping.len);
        @memcpy(destination, mapping);
        copy.* = destination;
    }
    return result;
}

fn identity_mapping(model_count: usize) ![]u32 {
    const mapping = try std.heap.page_allocator.alloc(u32, model_count);
    for (mapping, 0..) |*entry, i| entry.* = @intCast(i);
    return mapping;
}

fn compose_mapping(left: []const u32, right: []const u32) ![]u32 {
    assert(left.len == right.len);
    const result = try std.heap.page_allocator.alloc(u32, left.len);
    for (result, 0..) |*entry, i| {
        assert(right[i] < left.len);
        entry.* = left[right[i]];
    }
    return result;
}

fn mapping_is_identity(mapping: []const u32) bool {
    for (mapping, 0..) |entry, i| {
        if (entry != i) return false;
    }
    return true;
}

fn mapping_exists(mappings: []const []u32, candidate: []const u32) bool {
    for (mappings) |mapping| {
        if (std.mem.eql(u32, mapping, candidate)) return true;
    }
    return false;
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

fn clone_constants(
    arena: *Arena,
    constants: []const Constant,
    source: *const ValuePool,
    target: *ValuePool,
) ![]const Constant {
    if (constants.len == 0) return &.{};
    const result = try arena.alloc(Constant, constants.len);
    for (constants, result) |constant, *copy| {
        copy.* = .{
            .name = constant.name,
            .value = try constant.value.clone(source, target),
        };
    }
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
    if (std.mem.eql(u8, trimmed, "TRUE") or
        std.mem.eql(u8, trimmed, "FALSE"))
    {
        return false;
    }
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
