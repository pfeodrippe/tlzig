const std = @import("std");
const tlzig = @import("tlzig");
const Arena = tlzig.Arena;
const checker = tlzig.checker;
const config = tlzig.config;
const ModuleLoader = tlzig.ModuleLoader;
const overrides = tlzig.overrides;

const Spec = struct {
    tla: []const u8,
    cfg: []const u8,
    max_states: u32 = 100_000,
    max_nat: i64 = 1000,
    min_int: i64 = -1000,
    max_int: i64 = 1000,
    expected_violation: bool = false,
};

const specs = [_]Spec{
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/HourClock/HourClock.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/HourClock/HourClock.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/AsynchInterface.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/AsynchInterface.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/Channel.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/Channel.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/DieHard/DieHard.tla", .cfg = "vendor/tlaplus-examples/specifications/DieHard/DieHard.cfg", .expected_violation = true },
    .{ .tla = "vendor/tlaplus-examples/specifications/MissionariesAndCannibals/MissionariesAndCannibals.tla", .cfg = "vendor/tlaplus-examples/specifications/MissionariesAndCannibals/MissionariesAndCannibals.cfg", .expected_violation = true },
    .{ .tla = "vendor/tlaplus-examples/specifications/CigaretteSmokers/CigaretteSmokers.tla", .cfg = "vendor/tlaplus-examples/specifications/CigaretteSmokers/CigaretteSmokers.cfg", .max_states = 5000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/CigaretteSmokers/APCigaretteSmokers.tla", .cfg = "vendor/tlaplus-examples/specifications/CigaretteSmokers/APCigaretteSmokers.cfg", .max_states = 5000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan.tla", .cfg = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan100Beans.cfg", .max_states = 100_000, .max_nat = 1000, .min_int = -1000, .max_int = 1000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/TeachingConcurrency/Simple.tla", .cfg = "vendor/tlaplus-examples/specifications/TeachingConcurrency/Simple.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/barriers/Barrier.tla", .cfg = "vendor/tlaplus-examples/specifications/barriers/Barrier.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/locks_auxiliary_vars/Lock.tla", .cfg = "vendor/tlaplus-examples/specifications/locks_auxiliary_vars/Lock.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/Majority/MCMajority.tla", .cfg = "vendor/tlaplus-examples/specifications/Majority/MCMajority.cfg", .max_states = 100_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/LearnProofs/MCFindHighest.tla", .cfg = "vendor/tlaplus-examples/specifications/LearnProofs/MCFindHighest.cfg", .max_states = 100_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/transaction_commit/TwoPhase.tla", .cfg = "vendor/tlaplus-examples/specifications/transaction_commit/TwoPhase.cfg", .max_states = 100_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/Liveness/LiveHourClock.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/Liveness/LiveHourClock.cfg" },
    // Higher state count specs:
    // .{ .tla = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan.tla", .cfg = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan3000Beans.cfg", .max_states = 50_000_000, .max_nat = 10000, .min_int = -10000, .max_int = 10000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/transaction_commit/TCommit.tla", .cfg = "vendor/tlaplus-examples/specifications/transaction_commit/TCommit.cfg", .max_states = 500_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/transaction_commit/APTCommit.tla", .cfg = "vendor/tlaplus-examples/specifications/transaction_commit/APTCommit.cfg", .max_states = 500_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/chang_roberts/MCChangRoberts.tla", .cfg = "vendor/tlaplus-examples/specifications/chang_roberts/MCChangRoberts.cfg", .max_states = 500_000, .expected_violation = true },
    .{ .tla = "vendor/tlaplus-examples/specifications/SpanningTree/SpanTree.tla", .cfg = "vendor/tlaplus-examples/specifications/SpanningTree/SpanTree.cfg", .max_states = 500_000, .expected_violation = true },
    .{ .tla = "vendor/tlaplus-examples/specifications/ewd840/SyncTerminationDetection.tla", .cfg = "vendor/tlaplus-examples/specifications/ewd840/SyncTerminationDetection.cfg", .max_states = 500_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/ewd998/AsyncTerminationDetection.tla", .cfg = "vendor/tlaplus-examples/specifications/ewd998/AsyncTerminationDetection.cfg", .max_states = 200_000 },
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

    const java_classpath = "/tmp/tla2tools.jar";

    std.debug.print("{s:32} {s:>10} {s:>10} {s:>10} {s:>10} {s:>12}\n", .{
        "SPEC", "TLC-1", "TLC-auto", "tlzig-1", "tlzig-auto", "states",
    });
    std.debug.print("----------------------------------------------------------------------------------------\n", .{});

    for (specs) |spec| {
        run_comparison(allocator, io, java_classpath, spec) catch |err| {
            std.debug.print("{s:40} ERROR {any}\n", .{ spec.tla, err });
        };
    }
}

fn run_comparison(allocator: std.mem.Allocator, io: std.Io, java_cp: []const u8, spec: Spec) !void {
    const cpu_count: u16 = @intCast(@min(
        std.Thread.getCpuCount() catch 1,
        std.math.maxInt(u16),
    ));
    const tlzig_one = try run_tlzig_internal(allocator, io, spec, 1);
    defer tlzig_one.deinit(allocator);
    const tlzig_auto = try run_tlzig_internal(allocator, io, spec, cpu_count);
    defer tlzig_auto.deinit(allocator);
    const tlc_one = try run_tlc(allocator, io, java_cp, spec, "1");
    defer tlc_one.deinit(allocator);
    const tlc_auto = try run_tlc(allocator, io, java_cp, spec, "auto");
    defer tlc_auto.deinit(allocator);

    const basename = std.fs.path.basename(spec.tla);
    std.debug.print("{s:32} {d:>10.3} {d:>10.3} {d:>10.3} {d:>10.3} {d:>12}\n", .{
        basename,
        seconds(tlc_one.elapsed_ms),
        seconds(tlc_auto.elapsed_ms),
        seconds(tlzig_one.elapsed_ms),
        seconds(tlzig_auto.elapsed_ms),
        tlc_one.states,
    });

    const mismatch = if (spec.expected_violation)
        tlc_one.states != tlzig_one.states
    else
        tlc_one.states != tlc_auto.states or
            tlc_one.states != tlzig_one.states or
            tlc_one.states != tlzig_auto.states;
    if (mismatch) {
        std.debug.print(
            "  STATE MISMATCH: TLC-1={d} TLC-auto={d} tlzig-1={d} tlzig-auto={d}\n",
            .{ tlc_one.states, tlc_auto.states, tlzig_one.states, tlzig_auto.states },
        );
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

fn seconds(ms: u64) f64 {
    return @as(f64, @floatFromInt(ms)) / 1000.0;
}

fn run_tlzig_internal(
    allocator: std.mem.Allocator,
    io: std.Io,
    spec: Spec,
    worker_count: u16,
) !RunResult {
    const start = std.Io.Clock.Timestamp.now(io, .real);

    var arena = Arena.init(512 * 1024 * 1024) catch |err| {
        std.debug.print("failed to allocate arena for {s}: {any}\n", .{ spec.tla, err });
        return error.OutOfMemory;
    };
    defer arena.deinit();

    const spec_dir = std.fs.path.dirname(spec.tla) orelse ".";
    const search_paths = [_][]const u8{
        spec_dir,
        "specs/modules",
        "vendor/tlaplus-standard-modules/tla2sany/StandardModules",
        "vendor/tlaplus-community-modules/modules",
        "vendor/tlaplus-examples/specifications",
    };
    const loader = ModuleLoader.init(&arena, &search_paths);
    const module = loader.load(spec.tla) catch |err| {
        std.debug.print("failed to load spec {s}: {any}\n", .{ spec.tla, err });
        return error.LoadFailed;
    };
    const cfg_source = read_file(&arena, spec.cfg) catch |err| {
        std.debug.print("failed to read cfg {s}: {any}\n", .{ spec.cfg, err });
        return error.LoadFailed;
    };
    const cfg = config.parse(&arena, cfg_source) catch |err| {
        std.debug.print("failed to parse cfg {s}: {any}\n", .{ spec.cfg, err });
        return error.LoadFailed;
    };

    const override_ctx = overrides.OverrideContext{
        .max_seq_len = 5,
        .max_nat = spec.max_nat,
        .min_int = spec.min_int,
        .max_int = spec.max_int,
    };

    const eval_value_cap = cap_u32(@min(@max(@as(u64, spec.max_states) * 256, 500_000), 8_000_000));
    const eval_string_cap = cap_u32(@min(@max(@as(u64, spec.max_states) * 64, 500_000), 4_000_000));
    const state_value_cap = cap_u32(@min(@max(@as(u64, spec.max_states) * 256, 500_000), 8_000_000));
    const state_string_cap = cap_u32(@min(@max(@as(u64, spec.max_states) * 32, 200_000), 2_000_000));

    var ch = checker.Checker.init(
        &arena,
        module,
        cfg,
        spec.max_states,
        eval_value_cap,
        eval_string_cap,
        state_value_cap,
        state_string_cap,
        256 * 1024 * 1024,
        override_ctx,
        worker_count,
    ) catch |err| {
        std.debug.print("failed to initialize checker for {s}: {any}\n", .{ spec.tla, err });
        return error.CheckFailed;
    };
    defer ch.deinit();

    const result = ch.check() catch |err| {
        const elapsed = elapsed_ms(io, start);
        const distinct = ch.distinct;
        const output = try std.fmt.allocPrint(allocator, "generated={d} distinct={d} error={any}", .{ ch.generated, distinct, err });
        if (err == error.InvariantViolated or err == error.PropertyViolated) {
            return RunResult{
                .elapsed_ms = elapsed,
                .states = distinct,
                .output = output,
            };
        }
        std.debug.print("checking failed for {s}: {any}\n", .{ spec.tla, err });
        return error.CheckFailed;
    };

    const elapsed = elapsed_ms(io, start);

    const output = try std.fmt.allocPrint(allocator, "generated={d} distinct={d}", .{ result.generated, result.distinct });
    return RunResult{
        .elapsed_ms = elapsed,
        .states = result.distinct,
        .output = output,
    };
}

fn run_tlc(
    allocator: std.mem.Allocator,
    io: std.Io,
    java_cp: []const u8,
    spec: Spec,
    workers: []const u8,
) !RunResult {
    const classpath = try std.mem.concat(allocator, u8, &.{ java_cp, ":specs/modules" });
    defer allocator.free(classpath);
    const argv = [_][]const u8{
        "java",
        "-cp",
        classpath,
        "tlc2.TLC",
        "-metadir",
        "benchmark_results/tlc_meta",
        "-workers",
        workers,
        "-cleanup",
        "-config",
        spec.cfg,
        spec.tla,
    };

    const start = std.Io.Clock.Timestamp.now(io, .real);
    const result = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(result.stderr);
    const elapsed = elapsed_ms(io, start);

    const states = parse_before_keyword(result.stdout, " distinct states found") orelse {
        allocator.free(result.stdout);
        return error.TlcFailed;
    };
    return RunResult{
        .elapsed_ms = elapsed,
        .states = states,
        .output = result.stdout,
    };
}

fn parse_before_keyword(output: []const u8, keyword: []const u8) ?u64 {
    var pos: usize = 0;
    while (true) {
        const idx = std.mem.indexOfPos(u8, output, pos, keyword) orelse return null;
        var start: usize = idx;
        while (start > 0 and (std.ascii.isDigit(output[start - 1]) or output[start - 1] == ',')) start -= 1;
        if (start < idx) {
            const num_str = output[start..idx];
            var buf: [64]u8 = undefined;
            if (num_str.len > buf.len) {
                pos = idx + keyword.len;
                continue;
            }
            var len: usize = 0;
            for (num_str) |c| {
                if (c == ',') continue;
                buf[len] = c;
                len += 1;
            }
            if (std.fmt.parseInt(u64, buf[0..len], 10)) |n| return n else |_| {}
        }
        pos = idx + keyword.len;
    }
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
