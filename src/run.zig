const std = @import("std");
const Arena = @import("arena.zig").Arena;
const ast = @import("ast.zig");
const checker = @import("checker.zig");
const config = @import("config.zig");
const generated_runtime = @import("generated_runtime.zig");
const ModuleLoader = @import("module_loader.zig").ModuleLoader;
const overrides = @import("overrides.zig");
const platform = @import("platform.zig");
const parser = @import("parser.zig");
const state = @import("state.zig");

const assert = std.debug.assert;

pub const SpecInput = union(enum) {
    path: []const u8,
    source: Source,

    pub const Source = struct {
        /// Virtual or real path used for source locations and relative imports.
        path: []const u8,
        bytes: []const u8,
    };
};

pub const ConfigInput = union(enum) {
    path: []const u8,
    source: []const u8,
    module_default,
};

pub const Input = struct {
    spec: SpecInput,
    config: ConfigInput,
};

pub const NativeModel = struct {
    abi_version: u32 = generated_runtime.generated_model_abi_version,
    module_name: []const u8 = "",
    config_replacements_hash: u64 = 0,
    root_names: []const []const u8 = &.{},
    operators: []const generated_runtime.Operator = &.{},
    expressions: []const generated_runtime.Expression = &.{},
    fallback_count: u32 = 0,

    pub fn from(comptime model: anytype) NativeModel {
        return .{
            .abi_version = model.abi_version,
            .module_name = model.module_name,
            .config_replacements_hash = model.config_replacements_hash,
            .root_names = &model.root_names,
            .operators = &model.operators,
            .expressions = &model.expressions,
            .fallback_count = model.fallback_count,
        };
    }

    fn enabled(self: NativeModel) bool {
        return self.operators.len > 0 or self.expressions.len > 0;
    }
};

pub const Options = struct {
    max_states: u32 = 100_000,
    max_successors: u32 = 65_536,
    max_graph_edges: ?u32 = null,
    state_values_per_state: u32 = 60,
    state_value_cap: ?u32 = null,
    eval_value_cap: u32 = 1_048_576,
    eval_string_cap: u32 = 65_536,
    arena_bytes: u64 = 16 * 1024 * 1024,
    eval_arena_bytes: u64 = 16 * 1024 * 1024,
    worker_count: u16 = 1,
    scratch_growable: bool = false,
    diagnostics: bool = false,
    debug: checker.DebugOptions = .{},
    progress_interval_states: u64 = 0,
    search_paths: []const []const u8 = &.{},
    override_context: overrides.OverrideContext = overrides.OverrideContext.default(),
    native_model: NativeModel = .{},

    pub fn all_cores() u16 {
        return platform.auto_worker_count();
    }
};

/// A self-contained, one-shot model-checking run.
///
/// The returned pointer has a stable address because Checker stores pointers
/// into the owned arena. Call `destroy` after `check` or `simulate`, including
/// when either operation returns an error.
pub const Run = struct {
    allocator: std.mem.Allocator,
    arena: Arena,
    model_checker: checker.Checker,

    pub fn create(
        allocator: std.mem.Allocator,
        input: Input,
        options: Options,
    ) !*Run {
        try validate_options(options);
        const self = try allocator.create(Run);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.arena = try Arena.init(options.arena_bytes);
        errdefer self.arena.deinit();

        const spec_path = switch (input.spec) {
            .path => |path| path,
            .source => |source| source.path,
        };
        const spec_dir = std.fs.path.dirname(spec_path) orelse ".";
        const search_paths = try self.arena.alloc(
            []const u8,
            options.search_paths.len + 1,
        );
        search_paths[0] = spec_dir;
        @memcpy(search_paths[1..], options.search_paths);

        const loader = ModuleLoader.init(&self.arena, search_paths);
        var module = switch (input.spec) {
            .path => |path| try loader.load(path),
            .source => |source| try loader.load_source(
                source.path,
                source.bytes,
            ),
        };
        if (options.diagnostics) {
            std.debug.print("library run module {s} definitions:", .{module.name});
            for (module.definitions) |definition| {
                std.debug.print(" {s}", .{definition.name});
            }
            std.debug.print("\n", .{});
        }
        const cfg = try load_config(&self.arena, module, input.config);
        module.config_replacements = try config.build_codegen_replacements(
            &self.arena,
            module,
            cfg,
        );
        try validate_native_model(module, cfg, options.native_model);

        const effective_values_per_state = if (options.scratch_growable)
            @max(options.state_values_per_state, 160)
        else
            options.state_values_per_state;
        const state_value_cap = options.state_value_cap orelse
            state.canonical_value_capacity(
                options.arena_bytes,
                options.max_states,
                effective_values_per_state,
            );
        const state_string_cap = cap_u32(@min(
            @max(@as(u64, options.max_states) * 4, 500_000),
            8_000_000,
        ));

        self.model_checker = try checker.Checker.init_generated_with_resource_limits_and_debug(
            &self.arena,
            module,
            cfg,
            options.max_states,
            options.max_successors,
            options.max_graph_edges,
            options.eval_value_cap,
            options.eval_string_cap,
            state_value_cap,
            state_string_cap,
            options.eval_arena_bytes,
            options.override_context,
            options.worker_count,
            options.native_model.operators,
            options.native_model.expressions,
            options.debug,
        );
        self.model_checker.set_scratch_growable(options.scratch_growable);
        self.model_checker.set_diagnostics(options.diagnostics);
        self.model_checker.set_progress_interval(
            options.progress_interval_states,
        );
        return self;
    }

    pub fn create_from_paths(
        allocator: std.mem.Allocator,
        spec_path: []const u8,
        config_path: []const u8,
        options: Options,
    ) !*Run {
        return create(allocator, .{
            .spec = .{ .path = spec_path },
            .config = .{ .path = config_path },
        }, options);
    }

    pub fn check(self: *Run) !checker.Result {
        return self.model_checker.check();
    }

    pub fn simulate(
        self: *Run,
        options: checker.SimulationOptions,
    ) !checker.Result {
        return self.model_checker.simulate(options);
    }

    pub fn destroy(self: *Run) void {
        const allocator = self.allocator;
        self.model_checker.deinit();
        self.arena.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }
};

fn validate_options(options: Options) !void {
    if (options.max_states == 0 or
        options.max_successors == 0 or
        options.max_successors > options.max_states or
        options.state_values_per_state == 0 or
        options.eval_value_cap == 0 or
        options.eval_string_cap == 0 or
        options.arena_bytes == 0 or
        options.eval_arena_bytes == 0 or
        options.worker_count == 0)
    {
        return error.InvalidRunOptions;
    }
    if (options.max_graph_edges == 0) return error.InvalidRunOptions;
    if (options.state_value_cap == 0) return error.InvalidRunOptions;
}

fn load_config(
    arena: *Arena,
    module: ast.Module,
    input: ConfigInput,
) !config.Config {
    return switch (input) {
        .module_default => config.Config.from_module(arena, module),
        .source => |source| config.parse(arena, try arena.dup(source)),
        .path => |path| config.parse(arena, try read_file(arena, path)),
    };
}

fn validate_native_model(
    module: ast.Module,
    cfg: config.Config,
    native_model: NativeModel,
) !void {
    if (native_model.abi_version != generated_runtime.generated_model_abi_version) {
        return error.GeneratedModelAbiMismatch;
    }
    if (native_model.fallback_count != 0) {
        return error.GeneratedModelContainsFallbacks;
    }
    if (!native_model.enabled()) return;
    if (!std.mem.eql(u8, native_model.module_name, module.name)) {
        return error.GeneratedModelModuleMismatch;
    }
    if (native_model.config_replacements_hash !=
        config.codegen_replacements_hash(module.config_replacements))
    {
        return error.GeneratedModelConfigMismatch;
    }
    if (!root_covered(native_model, cfg.spec_name) or
        !root_covered(native_model, cfg.init_name) or
        !root_covered(native_model, cfg.next_name) or
        !root_covered(native_model, cfg.symmetry_name) or
        !root_covered(native_model, cfg.view_name))
    {
        return error.GeneratedModelConfigMismatch;
    }
    for (cfg.invariants) |name| {
        if (!root_covered(native_model, name)) {
            return error.GeneratedModelConfigMismatch;
        }
    }
    for (cfg.properties) |name| {
        if (!root_covered(native_model, name)) {
            return error.GeneratedModelConfigMismatch;
        }
    }
    for (cfg.constraints) |name| {
        if (!root_covered(native_model, name)) {
            return error.GeneratedModelConfigMismatch;
        }
    }
    for (cfg.action_constraints) |name| {
        if (!root_covered(native_model, name)) {
            return error.GeneratedModelConfigMismatch;
        }
    }
}

fn root_covered(native_model: NativeModel, optional_name: ?[]const u8) bool {
    const name = optional_name orelse return true;
    for (native_model.root_names) |root| {
        if (std.mem.eql(u8, root, name)) return true;
    }
    return false;
}

fn read_file(arena: *Arena, path: []const u8) ![]const u8 {
    const path_z = try std.heap.page_allocator.alloc(u8, path.len + 1);
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const file = std.c.fopen(@ptrCast(path_z.ptr), "rb") orelse
        return error.IoError;
    defer _ = std.c.fclose(file);

    var temporary = std.ArrayList(u8).empty;
    defer temporary.deinit(std.heap.page_allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = std.c.fread(&buffer, 1, buffer.len, file);
        if (count == 0) break;
        try temporary.appendSlice(
            std.heap.page_allocator,
            buffer[0..count],
        );
    }
    return arena.dup(temporary.items);
}

fn cap_u32(value: u64) u32 {
    assert(value <= std.math.maxInt(u32));
    return @intCast(value);
}

const passing_spec =
    \\---------------------- MODULE ContainedPassing ----------------------
    \\EXTENDS Naturals
    \\VARIABLE x
    \\Init == x = 0
    \\Next == x' = 1
    \\==============================================================
    \\
;

const passing_config =
    \\INIT Init
    \\NEXT Next
    \\CHECK_DEADLOCK FALSE
;

const toggle_spec =
    \\---------------------- MODULE ContainedToggle ----------------------
    \\VARIABLE b
    \\Init == b = FALSE
    \\Next == b' = ~b
    \\==============================================================
    \\
;

const toggle_config =
    \\INIT Init
    \\NEXT Next
    \\CHECK_DEADLOCK FALSE
;

test "contained runs are independent when executed sequentially" {
    const first = try Run.create(std.testing.allocator, .{
        .spec = .{ .source = .{
            .path = "ContainedPassing.tla",
            .bytes = passing_spec,
        } },
        .config = .{ .source = passing_config },
    }, test_options());
    defer first.destroy();
    const first_result = try first.check();
    try std.testing.expectEqual(@as(u64, 2), first_result.distinct);

    const second = try Run.create(std.testing.allocator, .{
        .spec = .{ .source = .{
            .path = "ContainedToggle.tla",
            .bytes = toggle_spec,
        } },
        .config = .{ .source = toggle_config },
    }, test_options());
    defer second.destroy();
    const second_result = try second.check();
    try std.testing.expectEqual(@as(u64, 2), second_result.distinct);
}

test "contained runs are independent when executed concurrently" {
    var passing = ThreadTestContext{
        .spec_path = "ContainedPassing.tla",
        .spec = passing_spec,
        .config = .{ .source = passing_config },
        .expected_distinct = 2,
    };
    var toggle = ThreadTestContext{
        .spec_path = "ContainedToggle.tla",
        .spec = toggle_spec,
        .config = .{ .source = toggle_config },
        .expected_distinct = 2,
    };
    const passing_thread = try std.Thread.spawn(.{}, ThreadTestContext.run, .{&passing});
    const toggle_thread = try std.Thread.spawn(.{}, ThreadTestContext.run, .{&toggle});
    passing_thread.join();
    toggle_thread.join();
    if (passing.failure) |failure| return failure;
    if (toggle.failure) |failure| return failure;
}

const ThreadTestContext = struct {
    spec_path: []const u8,
    spec: []const u8,
    config: ConfigInput,
    expected_distinct: u64,
    failure: ?anyerror = null,

    fn run(self: *ThreadTestContext) void {
        self.run_fallible() catch |err| {
            self.failure = err;
        };
    }

    fn run_fallible(self: *ThreadTestContext) !void {
        const model_run = try Run.create(std.testing.allocator, .{
            .spec = .{ .source = .{
                .path = self.spec_path,
                .bytes = self.spec,
            } },
            .config = self.config,
        }, test_options());
        defer model_run.destroy();
        const result = try model_run.check();
        try std.testing.expectEqual(self.expected_distinct, result.distinct);
    }
};

fn test_options() Options {
    return .{
        .max_states = 16,
        .max_successors = 16,
        .eval_value_cap = 4096,
        .eval_string_cap = 1024,
        .arena_bytes = 1024 * 1024,
        .eval_arena_bytes = 1024 * 1024,
    };
}

test "contained source fixture exposes all definitions" {
    var arena = try Arena.init(1024 * 1024);
    defer arena.deinit();
    var specification_parser = parser.Parser.init(&arena, passing_spec);
    const module = try specification_parser.parse_module();
    try std.testing.expect(find_definition(module, "Init"));
    try std.testing.expect(find_definition(module, "Next"));
}

fn find_definition(module: ast.Module, name: []const u8) bool {
    for (module.definitions) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return true;
    }
    return false;
}
