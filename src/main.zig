const std = @import("std");
const tlzig = @import("tlzig");
const Arena = tlzig.Arena;
const config = tlzig.config;
const checker = tlzig.checker;
const codegen = tlzig.codegen;
const generated_model = @import("generated_model");
const ModuleLoader = tlzig.ModuleLoader;
const overrides = tlzig.overrides;

comptime {
    if (generated_model.fallback_count != 0) {
        @compileError(
            "generated model contains interpreter fallbacks; " ++
                "strict tlzig executables require fallback_count == 0",
        );
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    var it = std.process.Args.Iterator.init(init.args);
    defer it.deinit();
    _ = it.next(); // skip argv[0]

    var spec_path: ?[]const u8 = null;
    var cfg_path: ?[]const u8 = null;
    var default_cfg = false;
    var max_states: u32 = 100_000;
    var max_seq_len: u32 = 5;
    var max_nat: i64 = 10;
    var min_int: i64 = -10;
    var max_int: i64 = 10;
    var arena_bytes: u64 = 16 * 1024 * 1024;
    var eval_arena_bytes: u64 = 16 * 1024 * 1024;
    var worker_count: u16 = 1;
    var unlimited_memory = false;
    var emit_zig_path: ?[]const u8 = null;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--spec")) {
            spec_path = it.next();
        } else if (std.mem.eql(u8, arg, "--cfg")) {
            cfg_path = it.next();
        } else if (std.mem.eql(u8, arg, "--default-cfg")) {
            default_cfg = true;
        } else if (std.mem.eql(u8, arg, "--max-states")) {
            if (it.next()) |v| {
                max_states = std.fmt.parseInt(u32, v, 10) catch 1_000_000;
            }
        } else if (std.mem.eql(u8, arg, "--max-seq-len")) {
            if (it.next()) |v| {
                max_seq_len = std.fmt.parseInt(u32, v, 10) catch 5;
            }
        } else if (std.mem.eql(u8, arg, "--max-nat")) {
            if (it.next()) |v| {
                max_nat = std.fmt.parseInt(i64, v, 10) catch 10;
            }
        } else if (std.mem.eql(u8, arg, "--min-int")) {
            if (it.next()) |v| {
                min_int = std.fmt.parseInt(i64, v, 10) catch -10;
            }
        } else if (std.mem.eql(u8, arg, "--max-int")) {
            if (it.next()) |v| {
                max_int = std.fmt.parseInt(i64, v, 10) catch 10;
            }
        } else if (std.mem.eql(u8, arg, "--arena-bytes")) {
            if (it.next()) |v| {
                arena_bytes = std.fmt.parseInt(u64, v, 10) catch 16 * 1024 * 1024;
            }
        } else if (std.mem.eql(u8, arg, "--eval-arena-bytes")) {
            if (it.next()) |v| {
                eval_arena_bytes = std.fmt.parseInt(u64, v, 10) catch 16 * 1024 * 1024;
            }
        } else if (std.mem.eql(u8, arg, "--workers")) {
            if (it.next()) |v| {
                if (std.mem.eql(u8, v, "auto")) {
                    worker_count = @intCast(@min(
                        std.Thread.getCpuCount() catch 1,
                        std.math.maxInt(u16),
                    ));
                } else {
                    worker_count = std.fmt.parseInt(u16, v, 10) catch 1;
                }
                if (worker_count == 0) worker_count = 1;
            }
        } else if (std.mem.eql(u8, arg, "--unlimited-memory")) {
            unlimited_memory = true;
        } else if (std.mem.eql(u8, arg, "--emit-zig")) {
            emit_zig_path = it.next();
        }
    }

    const spec_path_v = spec_path orelse {
        std.debug.print("usage: tlzig --spec FILE.tla [--emit-zig FILE.zig | --cfg FILE.cfg] [--max-states N]\n", .{});
        std.process.exit(1);
    };
    if (cfg_path == null and !default_cfg and emit_zig_path == null) {
        std.debug.print("usage: tlzig --spec FILE.tla (--cfg FILE.cfg | --default-cfg) [--max-states N] ...\n", .{});
        std.process.exit(1);
    }

    const override_ctx = overrides.OverrideContext{
        .max_seq_len = max_seq_len,
        .max_nat = max_nat,
        .min_int = min_int,
        .max_int = max_int,
    };

    if (unlimited_memory) {
        std.debug.print("WARNING: --unlimited-memory is set; arenas and value pools will grow without bound. OOM errors will only occur on system memory exhaustion.\n", .{});
    }

    var arena = Arena.init(arena_bytes) catch {
        std.debug.print("failed to allocate arena\n", .{});
        std.process.exit(1);
    };
    defer arena.deinit();

    const spec_dir = std.fs.path.dirname(spec_path_v) orelse ".";
    const search_paths = [_][]const u8{
        spec_dir,
        "specs/modules",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-community-modules/modules",
        "vendor/tlaplus-examples/specifications",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = loader.load(spec_path_v) catch |err| {
        std.debug.print("failed to load spec: {any}\n", .{err});
        std.process.exit(1);
    };
    if (generated_model.generated_count > 0 and
        !std.mem.eql(u8, generated_model.module_name, module.name))
    {
        std.debug.print(
            "generated model is for module {s}, not {s}\n",
            .{ generated_model.module_name, module.name },
        );
        std.process.exit(1);
    }
    if (emit_zig_path) |output_path| {
        var roots = std.ArrayList([]const u8).empty;
        defer roots.deinit(std.heap.page_allocator);
        if (default_cfg) {
            const cfg = config.Config.from_module(&arena, module);
            append_config_roots(&roots, cfg) catch {
                std.debug.print("failed to allocate config roots\n", .{});
                std.process.exit(1);
            };
        } else if (cfg_path) |cfg_path_v| {
            const cfg_source = read_file(&arena, cfg_path_v) catch {
                std.debug.print("failed to read cfg: {s}\n", .{cfg_path_v});
                std.process.exit(1);
            };
            const cfg = config.parse(&arena, cfg_source) catch {
                std.debug.print("failed to parse config\n", .{});
                std.process.exit(1);
            };
            append_config_roots(&roots, cfg) catch {
                std.debug.print("failed to allocate config roots\n", .{});
                std.process.exit(1);
            };
        }
        const generated = codegen.emit_module_with_roots(
            std.heap.page_allocator,
            module,
            roots.items,
        ) catch |err| {
            std.debug.print("failed to generate Zig: {any}\n", .{err});
            std.process.exit(1);
        };
        defer generated.deinit(std.heap.page_allocator);
        if (generated.fallback_count > 0) {
            std.debug.print(
                "strict Zig generation rejected {d} unsupported definitions:\n",
                .{generated.fallback_count},
            );
            for (generated.unsupported) |name| {
                std.debug.print("  {s}\n", .{name});
            }
            std.process.exit(1);
        }
        const formatted = format_zig(
            std.heap.page_allocator,
            generated.source,
        ) catch |err| {
            std.debug.print(
                "generated Zig failed formatting: {any}\n",
                .{err},
            );
            std.process.exit(1);
        };
        defer std.heap.page_allocator.free(formatted);
        write_file(output_path, formatted) catch {
            std.debug.print(
                "failed to write generated Zig: {s}\n",
                .{output_path},
            );
            std.process.exit(1);
        };
        std.debug.print(
            "generated Zig operators={d} native={d} fallbacks={d} path={s}\n",
            .{
                generated.generated_count,
                generated.native_count,
                generated.fallback_count,
                output_path,
            },
        );
        return;
    }

    const cfg: config.Config = if (default_cfg) config.Config.from_module(&arena, module) else blk: {
        const cfg_path_v = cfg_path.?;
        const cfg_source = read_file(&arena, cfg_path_v) catch {
            std.debug.print("failed to read cfg: {s}\n", .{cfg_path_v});
            std.process.exit(1);
        };
        break :blk config.parse(&arena, cfg_source) catch {
            std.debug.print("failed to parse config\n", .{});
            std.process.exit(1);
        };
    };
    if (generated_model.generated_count > 0 and
        !generated_config_covers(cfg))
    {
        std.debug.print(
            "generated model does not cover every configured root\n",
            .{},
        );
        std.process.exit(1);
    }

    const eval_value_cap: u32 = 262_144;
    const eval_string_cap: u32 = 65_536;
    const variables_len: u64 = @intCast(module.variables.len);
    const state_values_per_state = @max(variables_len * 12, 64);
    const state_strings_per_state = @max(variables_len * 16, 64);
    const state_value_cap = cap_u32(@min(
        @max(@as(u64, max_states) * state_values_per_state, 1_000_000),
        64_000_000,
    ));
    const state_string_cap = cap_u32(@min(
        @max(@as(u64, max_states) * state_strings_per_state, 500_000),
        64_000_000,
    ));

    var ch = checker.Checker.init_generated(
        &arena,
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
        &generated_model.operators,
    ) catch |err| {
        std.debug.print("failed to initialize checker: {any}\n", .{err});
        std.process.exit(1);
    };
    defer ch.deinit();

    const result = ch.check() catch |err| {
        std.debug.print("checking failed: {any}", .{err});
        if (ch.evaluator.err_ctx.context) |ctx| {
            std.debug.print(" -- context: {s} {s}", .{ ctx, ch.evaluator.err_ctx.detail orelse "" });
        }
        if (err == error.OutOfMemory) {
            std.debug.print(
                " -- state-pool values={d}/{d} strings={d}/{d}",
                .{
                    ch.state_store.values_pool.value_count,
                    ch.state_store.values_pool.value_cap,
                    ch.state_store.values_pool.string_count,
                    ch.state_store.values_pool.string_cap,
                },
            );
        }
        std.debug.print(" -- generated={d} distinct={d}\n", .{ ch.generated, ch.distinct });
        std.process.exit(1);
    };

    _ = std.c.printf("generated=%llu distinct=%llu\n", result.generated, result.distinct);
}

fn format_zig(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]u8 {
    const source_z = try allocator.allocSentinel(u8, source.len, 0);
    defer allocator.free(source_z);
    @memcpy(source_z, source);
    var tree = try std.zig.Ast.parse(allocator, source_z, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidGeneratedZig;
    return tree.renderAlloc(allocator);
}

fn cap_u32(v: u64) u32 {
    const max = std.math.maxInt(u32);
    return if (v > max) max else @intCast(v);
}

fn append_config_roots(
    roots: *std.ArrayList([]const u8),
    cfg: config.Config,
) !void {
    if (cfg.spec_name) |name| {
        try roots.append(std.heap.page_allocator, name);
    }
    if (cfg.init_name) |name| {
        try roots.append(std.heap.page_allocator, name);
    }
    if (cfg.next_name) |name| {
        try roots.append(std.heap.page_allocator, name);
    }
    if (cfg.symmetry_name) |name| {
        try roots.append(std.heap.page_allocator, name);
    }
    try roots.appendSlice(std.heap.page_allocator, cfg.invariants);
    try roots.appendSlice(std.heap.page_allocator, cfg.properties);
    try roots.appendSlice(std.heap.page_allocator, cfg.constraints);
    try roots.appendSlice(std.heap.page_allocator, cfg.action_constraints);
}

fn generated_config_covers(cfg: config.Config) bool {
    if (!generated_root_covered(cfg.spec_name)) return false;
    if (!generated_root_covered(cfg.init_name)) return false;
    if (!generated_root_covered(cfg.next_name)) return false;
    if (!generated_root_covered(cfg.symmetry_name)) return false;
    for (cfg.invariants) |name| {
        if (!generated_root_covered(name)) return false;
    }
    for (cfg.properties) |name| {
        if (!generated_root_covered(name)) return false;
    }
    for (cfg.constraints) |name| {
        if (!generated_root_covered(name)) return false;
    }
    for (cfg.action_constraints) |name| {
        if (!generated_root_covered(name)) return false;
    }
    return true;
}

fn generated_root_covered(optional_name: ?[]const u8) bool {
    const name = optional_name orelse return true;
    for (generated_model.root_names) |root| {
        if (std.mem.eql(u8, root, name)) return true;
    }
    return false;
}

fn read_file(arena: *Arena, path: []const u8) ![]u8 {
    const path_z = try arena.alloc(u8, path.len + 1);
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const file = std.c.fopen(@ptrCast(path_z.ptr), "rb") orelse return error.IoError;
    defer _ = std.c.fclose(file);

    var temp = std.ArrayList(u8).empty;
    defer temp.deinit(std.heap.page_allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, file);
        if (n == 0) break;
        try temp.appendSlice(std.heap.page_allocator, buf[0..n]);
    }
    const result = try arena.alloc(u8, temp.items.len);
    @memcpy(result, temp.items);
    return result;
}

fn write_file(path: []const u8, bytes: []const u8) !void {
    const path_z = try std.heap.page_allocator.alloc(u8, path.len + 1);
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const file = std.c.fopen(@ptrCast(path_z.ptr), "wb") orelse
        return error.IoError;
    defer _ = std.c.fclose(file);
    const written = std.c.fwrite(bytes.ptr, 1, bytes.len, file);
    if (written != bytes.len) return error.IoError;
}
