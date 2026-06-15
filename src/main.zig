const std = @import("std");
const Arena = @import("arena.zig").Arena;
const parser = @import("parser.zig");
const config = @import("config.zig");
const checker = @import("checker.zig");

pub fn main(init: std.process.Init.Minimal) void {
    var it = std.process.Args.Iterator.init(init.args);
    defer it.deinit();
    _ = it.next(); // skip argv[0]

    var spec_path: ?[]const u8 = null;
    var cfg_path: ?[]const u8 = null;
    var max_states: u32 = 1_000_000;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--spec")) {
            spec_path = it.next();
        } else if (std.mem.eql(u8, arg, "--cfg")) {
            cfg_path = it.next();
        } else if (std.mem.eql(u8, arg, "--max-states")) {
            if (it.next()) |v| {
                max_states = std.fmt.parseInt(u32, v, 10) catch 1_000_000;
            }
        }
    }

    const spec_path_v = spec_path orelse {
        std.debug.print("usage: tlzig --spec FILE.tla --cfg FILE.cfg [--max-states N]\n", .{});
        std.process.exit(1);
    };
    const cfg_path_v = cfg_path orelse {
        std.debug.print("usage: tlzig --spec FILE.tla --cfg FILE.cfg [--max-states N]\n", .{});
        std.process.exit(1);
    };

    var arena = Arena.init(256 * 1024 * 1024) catch {
        std.debug.print("failed to allocate arena\n", .{});
        std.process.exit(1);
    };
    defer arena.deinit();

    const spec_source = read_file(&arena, spec_path_v) catch {
        std.debug.print("failed to read spec: {s}\n", .{spec_path_v});
        std.process.exit(1);
    };
    const cfg_source = read_file(&arena, cfg_path_v) catch {
        std.debug.print("failed to read cfg: {s}\n", .{cfg_path_v});
        std.process.exit(1);
    };

    var p = parser.Parser.init(&arena, spec_source);
    const module = p.parse_module() catch {
        std.debug.print("failed to parse spec\n", .{});
        std.process.exit(1);
    };
    const cfg = config.parse(&arena, cfg_source) catch {
        std.debug.print("failed to parse config\n", .{});
        std.process.exit(1);
    };

    var ch = checker.Checker.init(
        &arena,
        module,
        cfg,
        max_states,
        1_000_000,
        100_000,
        1_000_000,
        100_000,
    ) catch |err| {
        std.debug.print("failed to initialize checker: {any}\n", .{err});
        std.process.exit(1);
    };

    const result = ch.check() catch |err| {
        std.debug.print("checking failed: {any}\n", .{err});
        std.process.exit(1);
    };

    std.debug.print("generated={d} distinct={d}\n", .{ result.generated, result.distinct });
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
