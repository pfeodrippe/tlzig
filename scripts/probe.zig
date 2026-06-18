const std = @import("std");
const tlzig = @import("tlzig");
const Arena = tlzig.Arena;
const checker = tlzig.checker;
const config = tlzig.config;
const ModuleLoader = tlzig.ModuleLoader;
const overrides = tlzig.overrides;

const max_states = 5000;

pub fn main(init: std.process.Init.Minimal) void {
    var threaded_io: std.Io.Threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .argv0 = std.Io.Threaded.Argv0.init(init.args),
    });
    const io = threaded_io.io();
    const allocator = std.heap.page_allocator;

    const args = init.args;
    if (args.len < 2) {
        std.debug.print("Usage: probe <directory>\n", .{});
        std.process.exit(1);
    }

    const dir_path = args[1];
    const dir = std.Io.Dir.cwd().openDirPath(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("failed to open dir: {any}\n", .{err});
        std.process.exit(1);
    };

    var configs = std.ArrayList([]const u8).empty;
    defer configs.deinit(std.heap.page_allocator);
    collect_configs(io, dir, "", &configs) catch |err| {
        std.debug.print("failed to collect configs: {any}\n", .{err});
        std.process.exit(1);
    };

    var pass: u32 = 0;
    var fail: u32 = 0;
    var skip: u32 = 0;

    std.debug.print("Probing {d} configs with max_states={d}\n\n", .{ configs.items.len, max_states });

    for (configs.items) |cfg_path| {
        const tla_path = find_tla(io, cfg_path) catch null;
        if (tla_path == null) {
            skip += 1;
            std.debug.print("SKIP  {s} (no .tla)\n", .{cfg_path});
            continue;
        }
        const result = run_tlzig(allocator, io, tla_path.?, cfg_path) catch |err| {
            fail += 1;
            std.debug.print("FAIL  {s}: {any}\n", .{ cfg_path, err });
            continue;
        };
        pass += 1;
        std.debug.print("PASS  {s}: {s}\n", .{ cfg_path, result });
    }

    std.debug.print("\nPASS={d} FAIL={d} SKIP={d} TOTAL={d}\n", .{ pass, fail, skip, configs.items.len });
}

fn collect_configs(io: std.Io, dir: std.Io.Dir, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
    var it = dir.iterate();
    var entry = it.next(io) catch return;
    while (entry) |e| : (entry = it.next(io) catch return) {
        const name = e.name.slice(io);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (e.kind == .directory) {
            const sub = dir.openDirPath(io, name, .{ .iterate = true }) catch continue;
            const new_prefix = std.mem.concat(std.heap.page_allocator, u8, &.{ prefix, name, "/" }) catch continue;
            defer std.heap.page_allocator.free(new_prefix);
            collect_configs(io, sub, new_prefix, out) catch continue;
        } else if (std.mem.endsWith(u8, name, ".cfg")) {
            const full = std.mem.concat(std.heap.page_allocator, u8, &.{ prefix, name }) catch continue;
            try out.append(std.heap.page_allocator, full);
        }
    }
}

fn find_tla(io: std.Io, cfg_path: []const u8) !?[]const u8 {
    const dir_part = std.fs.path.dirname(cfg_path) orelse "";
    const base = std.fs.path.basename(cfg_path);
    const stem = base[0 .. base.len - ".cfg".len];
    const candidate = std.mem.concat(std.heap.page_allocator, u8, &.{ dir_part, "/", stem, ".tla" }) catch return null;
    defer std.heap.page_allocator.free(candidate);
    _ = std.Io.Dir.cwd().openFilePath(io, candidate, .{}) catch return null;
    return std.mem.concat(std.heap.page_allocator, u8, &.{ dir_part, "/", stem, ".tla" });
}

fn run_tlzig(allocator: std.mem.Allocator, io: std.Io, tla: []const u8, cfg: []const u8) ![]const u8 {
    var arena = try Arena.init(256 * 1024 * 1024);
    defer arena.deinit();

    const spec_dir = std.fs.path.dirname(tla) orelse ".";
    const search_paths = [_][]const u8{
        spec_dir,
        "specs/modules",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-community-modules/modules",
        "vendor/tlaplus-examples/specifications",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = try loader.load(tla);
    const cfg_source = try read_file(&arena, cfg);
    const parsed_cfg = try config.parse(&arena, cfg_source);

    const override_ctx = overrides.OverrideContext{
        .max_seq_len = 5,
        .max_nat = 1000,
        .min_int = -1000,
        .max_int = 1000,
    };

    var ch = try checker.Checker.init(
        &arena,
        module,
        parsed_cfg,
        max_states,
        2_000_000,
        1_000_000,
        2_000_000,
        500_000,
        256 * 1024 * 1024,
        override_ctx,
        1,
    );
    defer ch.deinit();

    const result = ch.check() catch |err| {
        return err;
    };
    return try std.fmt.allocPrint(allocator, "generated={d} distinct={d}", .{ result.generated, result.distinct });
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
