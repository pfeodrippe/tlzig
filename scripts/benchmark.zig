const std = @import("std");
const tlzig = @import("tlzig");
const Arena = tlzig.Arena;
const checker = tlzig.checker;
const config = tlzig.config;
const ModuleLoader = tlzig.ModuleLoader;
const overrides = tlzig.overrides;

const Spec = struct {
    label: ?[]const u8 = null,
    tla: []const u8,
    cfg: []const u8,
    max_states: u32 = 100_000,
    max_nat: i64 = 1000,
    min_int: i64 = -1000,
    max_int: i64 = 1000,
    expected_violation: bool = false,
    compare_generated: bool = true,
    compare_distinct: bool = true,
    java_classpath: ?[]const u8 = null,
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
    // Representative larger state spaces and advanced semantics:
    .{ .tla = "vendor/tlaplus-examples/specifications/FiniteMonotonic/MCReplicatedLog.tla", .cfg = "vendor/tlaplus-examples/specifications/FiniteMonotonic/MCReplicatedLog.cfg", .max_states = 200_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/FiniteMonotonic/MCCRDT.tla", .cfg = "vendor/tlaplus-examples/specifications/FiniteMonotonic/MCCRDT.cfg", .max_states = 200_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/LoopInvariance/MCBinarySearch.tla", .cfg = "vendor/tlaplus-examples/specifications/LoopInvariance/MCBinarySearch.cfg", .max_states = 200_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/ewd687a/MCEWD687a.tla", .cfg = "vendor/tlaplus-examples/specifications/ewd687a/MCEWD687a.cfg", .max_states = 200_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AdvancedExamples/MCInnerSerial.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AdvancedExamples/MCInnerSerial.cfg", .max_states = 200_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/YoYo/MCYoYoNoPruning.tla", .cfg = "vendor/tlaplus-examples/specifications/YoYo/MCYoYoNoPruning.cfg", .max_states = 200_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/YoYo/MCYoYoPruning.tla", .cfg = "vendor/tlaplus-examples/specifications/YoYo/MCYoYoPruning.cfg", .max_states = 200_000 },
    .{
        .label = "MultiShardTxn ClientCentric",
        .tla = "vendor/MDBTLA/MultiShardTxn/ClientCentricTests.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/ClientCentricTests.cfg",
        .max_states = 2_000,
        .compare_generated = false,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn MCM/snapshot-invariant",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.cfg",
        .max_states = 100_000,
        .expected_violation = true,
        .compare_generated = false,
        .compare_distinct = false,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn MCM/rc-local-invariant",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn_rc_local.cfg",
        .max_states = 20_000,
        .compare_generated = false,
        .compare_distinct = false,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn Storage",
        .tla = "vendor/MDBTLA/MultiShardTxn/Storage.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/Storage.cfg",
        .max_states = 100_000,
        .compare_generated = false,
        .compare_distinct = false,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn RC/no-prepare-block",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block.cfg",
        .max_states = 20_000,
        .compare_generated = false,
        .compare_distinct = false,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn RC/no-prepare-block-or-ww",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block_or_ww.cfg",
        .max_states = 20_000,
        .compare_generated = false,
        .compare_distinct = false,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn RC/snapshot",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_snapshot.cfg",
        .max_states = 100_000,
        .compare_generated = false,
        .compare_distinct = false,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn RC/with-prepare-block",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_with_prepare_block.cfg",
        .max_states = 20_000,
        .compare_generated = false,
        .compare_distinct = false,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
};

pub fn main(init: std.process.Init.Minimal) void {
    var threaded_io: std.Io.Threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .argv0 = std.Io.Threaded.Argv0.init(init.args),
    });
    const io = threaded_io.io();
    const allocator = std.heap.page_allocator;
    var args = std.process.Args.Iterator.init(init.args);
    std.debug.assert(args.skip());
    const filter = args.next();

    std.Io.Dir.cwd().createDirPath(io, "benchmark_results") catch |err| {
        std.debug.print("failed to create benchmark_results: {any}\n", .{err});
        std.process.exit(1);
    };

    const java_classpath =
        "/tmp/tla2tools.jar:" ++
        "vendor/tlaplus/tlatools/org.lamport.tlatools/lib/CommunityModules.jar";

    std.debug.print("{s:32} {s:>10} {s:>10} {s:>10} {s:>10} {s:>18}\n", .{
        "SPEC", "TLC-1", "TLC-auto", "tlzig-1", "tlzig-auto", "generated/distinct",
    });
    std.debug.print("----------------------------------------------------------------------------------------\n", .{});

    var failures: u32 = 0;
    for (specs) |spec| {
        if (filter) |needle| {
            if (std.mem.indexOf(u8, spec.tla, needle) == null and
                std.mem.indexOf(u8, spec.cfg, needle) == null and
                (spec.label == null or
                    std.mem.indexOf(u8, spec.label.?, needle) == null))
            {
                continue;
            }
        }
        run_comparison(allocator, io, java_classpath, spec) catch |err| {
            failures += 1;
            std.debug.print("{s:40} ERROR {any}\n", .{ spec.tla, err });
        };
    }
    if (failures > 0) {
        std.debug.print("benchmark failures={d}\n", .{failures});
        std.process.exit(1);
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
    const spec_java_cp = spec.java_classpath orelse java_cp;
    const tlc_one = try run_tlc(allocator, io, spec_java_cp, spec, "1");
    defer tlc_one.deinit(allocator);
    const tlc_auto = try run_tlc(allocator, io, spec_java_cp, spec, "auto");
    defer tlc_auto.deinit(allocator);

    const basename = spec.label orelse std.fs.path.basename(spec.tla);
    std.debug.print("{s:32} {d:>10.3} {d:>10.3} {d:>10.3} {d:>10.3} {d:>9}/{d:<8}\n", .{
        basename,
        seconds(tlc_one.elapsed_ms),
        seconds(tlc_auto.elapsed_ms),
        seconds(tlzig_one.elapsed_ms),
        seconds(tlzig_auto.elapsed_ms),
        tlc_one.generated,
        tlc_one.distinct,
    });

    const mismatch = tlc_one.outcome != tlzig_one.outcome or
        tlc_auto.outcome != tlzig_auto.outcome or
        tlc_one.outcome != tlc_auto.outcome or
        (if (spec.expected_violation)
            spec.compare_distinct and tlc_one.distinct != tlzig_one.distinct
        else
            (spec.compare_generated and
                (tlc_one.generated != tlc_auto.generated or
                    tlc_one.generated != tlzig_one.generated or
                    tlc_one.generated != tlzig_auto.generated)) or
                (spec.compare_distinct and
                    (tlc_one.distinct != tlc_auto.distinct or
                        tlc_one.distinct != tlzig_one.distinct or
                        tlc_one.distinct != tlzig_auto.distinct)));
    if (mismatch) {
        std.debug.print(
            "  STATE MISMATCH: TLC-1={d}/{d} TLC-auto={d}/{d} " ++
                "tlzig-1={d}/{d} tlzig-auto={d}/{d}\n",
            .{
                tlc_one.generated,
                tlc_one.distinct,
                tlc_auto.generated,
                tlc_auto.distinct,
                tlzig_one.generated,
                tlzig_one.distinct,
                tlzig_auto.generated,
                tlzig_auto.distinct,
            },
        );
        return error.StateMismatch;
    }
}

const RunResult = struct {
    elapsed_ms: u64,
    generated: u64,
    distinct: u64,
    outcome: Outcome,
    output: []const u8,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

const Outcome = enum {
    completed,
    violation,
    deadlock,
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

    var arena = Arena.init(16 * 1024 * 1024) catch |err| {
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

    const eval_value_cap: u32 = 262_144;
    const eval_string_cap: u32 = 65_536;
    const variables_len: u64 = @intCast(module.variables.len);
    const state_values_per_state = @max(variables_len * 12, 64);
    const state_strings_per_state = @max(variables_len * 16, 64);
    const state_value_cap = cap_u32(@min(
        @max(@as(u64, spec.max_states) * state_values_per_state, 1_000_000),
        64_000_000,
    ));
    const state_string_cap = cap_u32(@min(
        @max(@as(u64, spec.max_states) * state_strings_per_state, 500_000),
        64_000_000,
    ));

    var ch = checker.Checker.init(
        &arena,
        module,
        cfg,
        spec.max_states,
        eval_value_cap,
        eval_string_cap,
        state_value_cap,
        state_string_cap,
        16 * 1024 * 1024,
        override_ctx,
        worker_count,
    ) catch |err| {
        std.debug.print("failed to initialize checker for {s}: {any}\n", .{ spec.tla, err });
        return error.CheckFailed;
    };
    defer ch.deinit();
    ch.set_diagnostics(false);

    const result = ch.check() catch |err| {
        const elapsed = elapsed_ms(io, start);
        const distinct = ch.distinct;
        const output = try std.fmt.allocPrint(allocator, "generated={d} distinct={d} error={any}", .{ ch.generated, distinct, err });
        if (err == error.InvariantViolated or
            err == error.PropertyViolated or
            err == error.Deadlock)
        {
            return RunResult{
                .elapsed_ms = elapsed,
                .generated = ch.generated,
                .distinct = distinct,
                .outcome = if (err == error.Deadlock)
                    .deadlock
                else
                    .violation,
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
        .generated = result.generated,
        .distinct = result.distinct,
        .outcome = .completed,
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
    const argv_auto = [_][]const u8{
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
    const argv_single = [_][]const u8{
        "java",
        "-XX:ActiveProcessorCount=1",
        "-XX:+UseSerialGC",
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
    const argv: []const []const u8 = if (std.mem.eql(u8, workers, "1"))
        &argv_single
    else
        &argv_auto;

    const start = std.Io.Clock.Timestamp.now(io, .real);
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stderr);
    const elapsed = elapsed_ms(io, start);

    const generated = parse_before_keyword(result.stdout, " states generated") orelse {
        allocator.free(result.stdout);
        return error.TlcFailed;
    };
    const distinct = parse_before_keyword(result.stdout, " distinct states found") orelse {
        allocator.free(result.stdout);
        return error.TlcFailed;
    };
    return RunResult{
        .elapsed_ms = elapsed,
        .generated = generated,
        .distinct = distinct,
        .outcome = parse_tlc_outcome(result.stdout, result.term),
        .output = result.stdout,
    };
}

fn parse_tlc_outcome(
    output: []const u8,
    term: std.process.Child.Term,
) Outcome {
    if (std.mem.indexOf(u8, output, "Deadlock reached") != null) {
        return .deadlock;
    }
    return switch (term) {
        .exited => |code| if (code == 0) .completed else .violation,
        else => .violation,
    };
}

fn parse_before_keyword(output: []const u8, keyword: []const u8) ?u64 {
    var pos: usize = 0;
    var last: ?u64 = null;
    while (true) {
        const idx = std.mem.indexOfPos(u8, output, pos, keyword) orelse
            return last;
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
            if (std.fmt.parseInt(u64, buf[0..len], 10)) |n| {
                last = n;
            } else |_| {}
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
