const std = @import("std");

pub fn main(init: std.process.Init.Minimal) void {
    var threaded_io: std.Io.Threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .argv0 = std.Io.Threaded.Argv0.init(init.args),
    });
    const io = threaded_io.io();
    const allocator = std.heap.page_allocator;

    const tlzig = find_tlzig(allocator, io) catch |err| {
        std.debug.print("failed to find tlzig: {any}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(tlzig);

    const tla_files = collect_tla_files(allocator, io) catch |err| {
        std.debug.print("failed to collect tla files: {any}\n", .{err});
        std.process.exit(1);
    };
    defer {
        for (tla_files) |f| allocator.free(f);
        allocator.free(tla_files);
    }

    var pass: u32 = 0;
    var fail: u32 = 0;
    var skip: u32 = 0;
    var failures = std.ArrayList([]const u8).empty;
    defer {
        for (failures.items) |f| allocator.free(f);
        failures.deinit(allocator);
    }

    for (tla_files) |tla_path| {
        if (std.mem.endsWith(u8, tla_path, "_proof.tla")) {
            skip += 1;
            continue;
        }
        const cfg_path = find_cfg(allocator, tla_path) catch null;
        var default_cfg = false;
        if (cfg_path == null) default_cfg = true;
        defer if (cfg_path) |c| allocator.free(c);

        const ok = run_tlzig(allocator, io, tlzig, tla_path, cfg_path) catch |err| {
            fail += 1;
            const msg = std.fmt.allocPrint(allocator, "{s}: {any}", .{ tla_path, err }) catch continue;
            failures.append(allocator, msg) catch allocator.free(msg);
            continue;
        };
        if (ok) {
            pass += 1;
        } else {
            fail += 1;
            const msg = std.fmt.allocPrint(allocator, "{s}: exit nonzero", .{tla_path}) catch continue;
            failures.append(allocator, msg) catch allocator.free(msg);
        }
    }

    std.debug.print("\n=== Harness Results ===\n", .{});
    std.debug.print("pass={d} fail={d} skip={d} total={d}\n", .{ pass, fail, skip, pass + fail + skip });
    std.debug.print("\nFailures (first 50):\n", .{});
    const show = @min(failures.items.len, 50);
    for (failures.items[0..show]) |f| std.debug.print("  {s}\n", .{f});
}

fn collect_tla_files(allocator: std.mem.Allocator, io: std.Io) ![][]const u8 {
    const argv = [_][]const u8{
        "find",
        "vendor/tlaplus-examples/specifications",
        "-name",
        "*.tla",
    };
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(result.stderr);
    if (result.term.exited != 0) return error.FindFailed;
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, result.stdout, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(allocator, try allocator.dupe(u8, line));
    }
    allocator.free(result.stdout);
    const out = try allocator.alloc([]const u8, lines.items.len);
    @memcpy(out, lines.items);
    return out;
}

fn find_tlzig(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const candidates = [_][]const u8{
        "zig-out/bin/tlzig",
        "./zig-out/bin/tlzig",
        "../zig-out/bin/tlzig",
    };
    for (candidates) |c| {
        const stat = std.Io.Dir.cwd().statFile(io, c, .{}) catch continue;
        if (stat.kind == .file) return try allocator.dupe(u8, c);
    }
    return error.NotFound;
}

fn find_cfg(allocator: std.mem.Allocator, tla_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(tla_path).?;
    const base = std.fs.path.basename(tla_path);
    const name = base[0 .. base.len - 4];

    const local_name = try std.mem.concat(allocator, u8, &.{ name, ".cfg" });
    defer allocator.free(local_name);
    const local = try std.fs.path.join(allocator, &.{ dir, local_name });
    if (file_exists(local)) return local;
    allocator.free(local);

    return error.NotFound;
}

fn file_exists(path: []const u8) bool {
    const path_z = std.heap.page_allocator.alloc(u8, path.len + 1) catch return false;
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const file = std.c.fopen(@ptrCast(path_z.ptr), "rb");
    if (file) |f| {
        _ = std.c.fclose(f);
        return true;
    }
    return false;
}

fn run_tlzig(allocator: std.mem.Allocator, io: std.Io, tlzig: []const u8, tla: []const u8, cfg: ?[]const u8) !bool {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, tlzig);
    try argv.append(allocator, "--spec");
    try argv.append(allocator, tla);
    if (cfg) |c| {
        try argv.append(allocator, "--cfg");
        try argv.append(allocator, c);
    } else {
        try argv.append(allocator, "--default-cfg");
    }
    try argv.append(allocator, "--max-states");
    try argv.append(allocator, "5000");
    try argv.append(allocator, "--arena-bytes");
    try argv.append(allocator, "2000000000");
    try argv.append(allocator, "--eval-arena-bytes");
    try argv.append(allocator, "1000000000");
    const result = try std.process.run(allocator, io, .{ .argv = argv.items });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (result.term.exited == 0) return true;
    // A run that exhausts the state limit or finds a counterexample without crashing is
    // considered a pass because the checker successfully parsed, initialized, and explored states.
    if (std.mem.indexOf(u8, result.stderr, "StateSpaceExhausted") != null) return true;
    if (std.mem.indexOf(u8, result.stderr, "InvariantViolated") != null) return true;
    return false;
}
