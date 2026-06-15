const std = @import("std");
const Arena = @import("arena.zig").Arena;
const config = @import("config.zig");
const checker = @import("checker.zig");
const ModuleLoader = @import("module_loader.zig").ModuleLoader;
const overrides = @import("overrides.zig");

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
    var arena_bytes: u64 = 512 * 1024 * 1024;
    var eval_arena_bytes: u64 = 256 * 1024 * 1024;

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
                arena_bytes = std.fmt.parseInt(u64, v, 10) catch 512 * 1024 * 1024;
            }
        } else if (std.mem.eql(u8, arg, "--eval-arena-bytes")) {
            if (it.next()) |v| {
                eval_arena_bytes = std.fmt.parseInt(u64, v, 10) catch 256 * 1024 * 1024;
            }
        }
    }

    const spec_path_v = spec_path orelse {
        std.debug.print("usage: tlzig --spec FILE.tla --cfg FILE.cfg [--max-states N] [--arena-bytes B] [--eval-arena-bytes B]\n", .{});
        std.process.exit(1);
    };
    if (cfg_path == null and !default_cfg) {
        std.debug.print("usage: tlzig --spec FILE.tla (--cfg FILE.cfg | --default-cfg) [--max-states N] ...\n", .{});
        std.process.exit(1);
    }

    overrides.set_max_seq_len(max_seq_len);
    overrides.set_nat_bound(max_nat);
    overrides.set_int_bounds(min_int, max_int);

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

    const eval_value_cap = cap_u32(@min(@max(@as(u64, max_states) * 256, 500_000), 8_000_000));
    const eval_string_cap = cap_u32(@min(@max(@as(u64, max_states) * 64, 500_000), 4_000_000));
    const state_value_cap = cap_u32(@min(@max(@as(u64, max_states) * 256, 500_000), 8_000_000));
    const state_string_cap = cap_u32(@min(@max(@as(u64, max_states) * 32, 200_000), 2_000_000));

    var ch = checker.Checker.init(
        &arena,
        module,
        cfg,
        max_states,
        eval_value_cap,
        eval_string_cap,
        state_value_cap,
        state_string_cap,
        eval_arena_bytes,
    ) catch |err| {
        std.debug.print("failed to initialize checker: {any}\n", .{err});
        std.process.exit(1);
    };

    const result = ch.check() catch |err| {
        std.debug.print("checking failed: {any}\n", .{err});
        if (err == error.TypeError) std.debug.dumpCurrentStackTrace(.{});
        std.process.exit(1);
    };

    _ = std.c.printf("generated=%llu distinct=%llu\n", result.generated, result.distinct);
}

fn cap_u32(v: u64) u32 {
    const max = std.math.maxInt(u32);
    return if (v > max) max else @intCast(v);
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
