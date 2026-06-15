const std = @import("std");

const Spec = struct {
    tla: []const u8,
    cfg: []const u8,
    max_states: u32 = 100_000,
};

const specs = [_]Spec{
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/HourClock/HourClock.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/HourClock/HourClock.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/DieHard/DieHard.tla", .cfg = "vendor/tlaplus-examples/specifications/DieHard/DieHard.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/AsynchInterface.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/AsynchInterface.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/Channel.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/Channel.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/TeachingConcurrency/SimpleRegular.tla", .cfg = "vendor/tlaplus-examples/specifications/TeachingConcurrency/SimpleRegular.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/TeachingConcurrency/Simple.tla", .cfg = "vendor/tlaplus-examples/specifications/TeachingConcurrency/Simple.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/barriers/Barrier.tla", .cfg = "vendor/tlaplus-examples/specifications/barriers/Barrier.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/Majority/MCMajority.tla", .cfg = "vendor/tlaplus-examples/specifications/Majority/MCMajority.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/LearnProofs/MCFindHighest.tla", .cfg = "vendor/tlaplus-examples/specifications/LearnProofs/MCFindHighest.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/transaction_commit/TwoPhase.tla", .cfg = "vendor/tlaplus-examples/specifications/transaction_commit/TwoPhase.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/locks_auxiliary_vars/Lock.tla", .cfg = "vendor/tlaplus-examples/specifications/locks_auxiliary_vars/Lock.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/bcastFolklore/bcastFolklore.tla", .cfg = "vendor/tlaplus-examples/specifications/bcastFolklore/bcastFolklore.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan.tla", .cfg = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan100Beans.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/CigaretteSmokers/CigaretteSmokers.tla", .cfg = "vendor/tlaplus-examples/specifications/CigaretteSmokers/CigaretteSmokers.cfg", .max_states = 5000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/CigaretteSmokers/APCigaretteSmokers.tla", .cfg = "vendor/tlaplus-examples/specifications/CigaretteSmokers/APCigaretteSmokers.cfg", .max_states = 5000 },
};

pub fn main(init: std.process.Init.Minimal) void {
    var threaded_io: std.Io.Threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .argv0 = std.Io.Threaded.Argv0.init(init.args),
    });
    const io = threaded_io.io();
    const allocator = std.heap.page_allocator;

    std.Io.Dir.cwd().createDirPath(io, "benchmark_results") catch |err| {
        std.debug.print("failed to create benchmark_results: {any}\n", .{err});
        std.process.exit(1);
    };

    const tlzig = find_tlzig(allocator, io) catch |err| {
        std.debug.print("failed to find tlzig binary: {any}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(tlzig);

    const java_classpath = "/tmp/tla2tools.jar";

    std.debug.print("{s:40} {s:>10} {s:>10} {s:>12} {s:>12} {s:>8}\n", .{ "SPEC", "TLC(s)", "Tlzig(s)", "TLC states", "Tlzig states", "Speedup" });
    std.debug.print("---------------------------------------------------------------------------------------------\n", .{});

    for (specs) |spec| {
        run_comparison(allocator, io, tlzig, java_classpath, spec) catch |err| {
            std.debug.print("{s:40} ERROR {any}\n", .{ spec.tla, err });
        };
    }
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

fn run_comparison(allocator: std.mem.Allocator, io: std.Io, tlzig: []const u8, java_cp: []const u8, spec: Spec) !void {
    const tlzig_result = try run_tlzig(allocator, io, tlzig, spec);
    defer tlzig_result.deinit(allocator);

    const tlc_result = try run_tlc(allocator, io, java_cp, spec);
    defer tlc_result.deinit(allocator);

    const speedup = if (tlc_result.elapsed_ms > 0 and tlzig_result.elapsed_ms > 0)
        @as(f64, @floatFromInt(tlc_result.elapsed_ms)) / @as(f64, @floatFromInt(tlzig_result.elapsed_ms))
    else
        0.0;

    const basename = std.fs.path.basename(spec.tla);
    std.debug.print("{s:40} {d:>10.3} {d:>10.3} {d:>12} {d:>12} {d:>7.1}x\n", .{
        basename,
        @as(f64, @floatFromInt(tlc_result.elapsed_ms)) / 1000.0,
        @as(f64, @floatFromInt(tlzig_result.elapsed_ms)) / 1000.0,
        tlc_result.states,
        tlzig_result.states,
        speedup,
    });

    if (tlc_result.states != tlzig_result.states) {
        std.debug.print("  WARNING: state counts differ!\n", .{});
    }
}

const RunResult = struct {
    elapsed_ms: u64,
    states: u64,
    output: []const u8,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

fn elapsed_ms(io: std.Io, start: std.Io.Clock.Timestamp) u64 {
    const duration = std.Io.Clock.Timestamp.untilNow(start, io);
    return @intCast(@divTrunc(duration.raw.nanoseconds, 1_000_000));
}

fn run_tlzig(allocator: std.mem.Allocator, io: std.Io, tlzig: []const u8, spec: Spec) !RunResult {
    const max_states_str = try std.fmt.allocPrint(allocator, "{d}", .{spec.max_states});
    defer allocator.free(max_states_str);

    const argv = [_][]const u8{
        tlzig,
        "--spec",
        spec.tla,
        "--cfg",
        spec.cfg,
        "--max-states",
        max_states_str,
        "--arena-bytes",
        "4000000000",
        "--eval-arena-bytes",
        "2000000000",
    };

    const start = std.Io.Clock.Timestamp.now(io, .real);
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(result.stderr);
    const elapsed = elapsed_ms(io, start);

    const states = parse_after_keyword(result.stdout, "generated=") orelse {
        allocator.free(result.stdout);
        return error.TlzigFailed;
    };
    return RunResult{
        .elapsed_ms = elapsed,
        .states = states,
        .output = result.stdout,
    };
}

fn run_tlc(allocator: std.mem.Allocator, io: std.Io, java_cp: []const u8, spec: Spec) !RunResult {
    const classpath = try std.mem.concat(allocator, u8, &.{ java_cp, ":specs/modules" });
    defer allocator.free(classpath);
    const argv = [_][]const u8{
        "java",
        "-cp",
        classpath,
        "tlc2.TLC",
        "-metadir",
        "benchmark_results/tlc_meta",
        "-cleanup",
        "-config",
        spec.cfg,
        spec.tla,
    };

    const start = std.Io.Clock.Timestamp.now(io, .real);
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(result.stderr);
    const elapsed = elapsed_ms(io, start);

    const states = parse_before_keyword(result.stdout, " states generated") orelse {
        allocator.free(result.stdout);
        return error.TlcFailed;
    };
    return RunResult{
        .elapsed_ms = elapsed,
        .states = states,
        .output = result.stdout,
    };
}

fn parse_after_keyword(output: []const u8, keyword: []const u8) ?u64 {
    var pos: usize = 0;
    while (true) {
        const idx = std.mem.indexOfPos(u8, output, pos, keyword) orelse return null;
        const after = idx + keyword.len;
        var end: usize = after;
        while (end < output.len and std.ascii.isDigit(output[end])) end += 1;
        if (end > after) {
            const num_str = output[after..end];
            if (std.fmt.parseInt(u64, num_str, 10)) |n| return n else |_| {}
        }
        pos = after + 1;
    }
}

fn parse_before_keyword(output: []const u8, keyword: []const u8) ?u64 {
    var pos: usize = 0;
    while (true) {
        const idx = std.mem.indexOfPos(u8, output, pos, keyword) orelse return null;
        var start: usize = idx;
        while (start > 0 and std.ascii.isDigit(output[start - 1])) start -= 1;
        if (start < idx) {
            const num_str = output[start..idx];
            if (std.fmt.parseInt(u64, num_str, 10)) |n| return n else |_| {}
        }
        pos = idx + keyword.len;
    }
}
