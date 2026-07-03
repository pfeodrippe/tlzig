const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tlzig_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const generated_model_path = b.option(
        []const u8,
        "generated-model",
        "Generated Zig model emitted by tlzig --emit-zig",
    );
    const generated_model_module = b.createModule(.{
        .root_source_file = if (generated_model_path) |path|
            .{ .cwd_relative = path }
        else
            b.path("src/generated_model_stub.zig"),
        .target = target,
        .optimize = optimize,
    });
    generated_model_module.addImport("tlzig", tlzig_module);

    const exe = b.addExecutable(.{
        .name = "tlzig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("tlzig", tlzig_module);
    exe.root_module.addImport("generated_model", generated_model_module);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    b.step("run", "Run tlzig").dependOn(&run_cmd.step);

    const generate_cmd = b.addRunArtifact(exe);
    generate_cmd.step.dependOn(b.getInstallStep());
    generate_cmd.addPassthruArgs();
    b.step(
        "generate-model",
        "Generate a strict native Zig model; pass tlzig arguments after --",
    ).dependOn(&generate_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    const bench = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench.root_module.addImport("tlzig", tlzig_module);
    bench.root_module.addImport("generated_model", generated_model_module);
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    run_bench.has_side_effects = true;
    run_bench.step.dependOn(b.getInstallStep());
    const tlc_test_class = b.addSystemCommand(&.{
        "mkdir",
        "-p",
        "vendor/tlaplus/tlatools/org.lamport.tlatools/test-class",
    });
    const build_tlc = b.addSystemCommand(&.{
        "ant",
        "-f",
        "customBuild.xml",
        "compile",
        "dist",
        "-Dtest.skip=true",
        "-Dnoclean=true",
    });
    build_tlc.setCwd(
        b.path("vendor/tlaplus/tlatools/org.lamport.tlatools"),
    );
    build_tlc.step.dependOn(&tlc_test_class.step);
    run_bench.step.dependOn(&build_tlc.step);
    const benchmark_filter = b.option(
        []const u8,
        "benchmark-filter",
        "Run only benchmark specs whose path contains this substring",
    );
    const benchmark_include_long = b.option(
        bool,
        "benchmark-include-long",
        "Include opt-in long benchmark specs and generated benchmark rows",
    ) orelse false;
    const benchmark_generated_expressions = b.option(
        bool,
        "benchmark-generated-expressions",
        "Enable generated expression AOT benchmark path",
    ) orelse true;
    if (benchmark_filter) |filter| {
        run_bench.addArg(filter);
    }
    if (benchmark_include_long) {
        run_bench.addArg("--include-long");
    }
    if (benchmark_generated_expressions) {
        run_bench.addArg("--generated-expressions");
    }
    if (generated_model_path == null) {
        run_bench.addArg("--skip-prefer-generated");
    }
    const benchmark_step = b.step("benchmark", "Benchmark tlzig vs Java TLC");
    benchmark_step.dependOn(&run_bench.step);
    if (generated_model_path == null) {
        var previous_generated_benchmark: *std.Build.Step = &run_bench.step;
        const generated_benchmarks = [_]GeneratedBenchmark{
            .{
                .name = "benchmark_mdbtla_client_centric_aot",
                .model_path = "generated_models/mdbtla_client_centric.zig",
                .filter = "MultiShardTxn ClientCentric",
            },
            .{
                .name = "benchmark_mdbtla_mcm_snapshot_aot",
                .model_path = "generated_models/mdbtla_mcm_snapshot_invariant.zig",
                .filter = "MultiShardTxn MCM/snapshot-invariant",
            },
            .{
                .name = "benchmark_mdbtla_mcm_rc_local_aot",
                .model_path = "generated_models/mdbtla_mcm_rc_local_invariant.zig",
                .filter = "MultiShardTxn MCM/rc-local-invariant",
            },
            .{
                .name = "benchmark_mdbtla_storage_aot",
                .model_path = "generated_models/mdbtla_storage.zig",
                .filter = "MultiShardTxn Storage",
            },
            .{
                .name = "benchmark_mdbtla_storage_exhaustive_aot",
                .model_path = "generated_models/mdbtla_storage_exhaustive.zig",
                .filter = "MultiShardTxn Storage exhaustive",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_rc_no_prepare_aot",
                .model_path = "generated_models/mdbtla_rc_no_prepare_block.zig",
                .filter = "MultiShardTxn RC/no-prepare-block",
            },
            .{
                .name = "benchmark_mdbtla_rc_no_prepare_exhaustive_aot",
                .model_path = "generated_models/mdbtla_rc_no_prepare_block_exhaustive.zig",
                .filter = "MultiShardTxn RC/no-prepare-block exhaustive",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_rc_no_prepare_ww_aot",
                .model_path = "generated_models/mdbtla_rc_no_prepare_block_or_ww.zig",
                .filter = "MultiShardTxn RC/no-prepare-block-or-ww",
            },
            .{
                .name = "benchmark_mdbtla_rc_no_prepare_ww_exhaustive_aot",
                .model_path = "generated_models/mdbtla_rc_no_prepare_block_or_ww_exhaustive.zig",
                .filter = "MultiShardTxn RC/no-prepare-block-or-ww exhaustive",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_rc_snapshot_aot",
                .model_path = "generated_models/mdbtla_rc_snapshot.zig",
                .filter = "MultiShardTxn RC/snapshot",
            },
            .{
                .name = "benchmark_mdbtla_rc_snapshot_exhaustive_aot",
                .model_path = "generated_models/mdbtla_rc_snapshot_exhaustive.zig",
                .filter = "MultiShardTxn RC/snapshot exhaustive",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_rc_with_prepare_aot",
                .model_path = "generated_models/mdbtla_rc_with_prepare_block.zig",
                .filter = "MultiShardTxn RC/with-prepare-block",
            },
            .{
                .name = "benchmark_mdbtla_rc_with_prepare_exhaustive_aot",
                .model_path = "generated_models/mdbtla_rc_with_prepare_block_exhaustive.zig",
                .filter = "MultiShardTxn RC/with-prepare-block exhaustive",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_single_shard_txn_full_aot",
                .model_path = "generated_models/mdbtla_single_shard_txn_full.zig",
                .filter = "SingleShardTxn ShardTxn",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_single_shard_txn_small_aot",
                .model_path = "generated_models/mdbtla_single_shard_txn_small.zig",
                .filter = "SingleShardTxn ShardTxn/small",
            },
            .{
                .name = "benchmark_mdbtla_single_shard_txn_small_no_sym_aot",
                .model_path = "generated_models/mdbtla_single_shard_txn_small_no_sym.zig",
                .filter = "SingleShardTxn ShardTxn/small no-sym",
            },
            .{
                .name = "benchmark_mdbtla_single_shard_txn_small_safety_aot",
                .model_path = "generated_models/mdbtla_single_shard_txn_small_safety.zig",
                .filter = "SingleShardTxn ShardTxn/small safety",
            },
            .{
                .name = "benchmark_mdbtla_single_shard_txn_small_safety_no_sym_aot",
                .model_path = "generated_models/mdbtla_single_shard_txn_small_safety_no_sym.zig",
                .filter = "SingleShardTxn ShardTxn/small safety no-sym",
            },
            .{
                .name = "benchmark_mdbtla_singlelog_mcmdbprops_aot",
                .model_path = "generated_models/mdbtla_singlelog_mcmdbprops.zig",
                .filter = "SingleLog MCMDBProps",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_singlelog_mdblinearizability_aot",
                .model_path = "generated_models/mdbtla_singlelog_mdblinearizability.zig",
                .filter = "SingleLog MDBLinearizability",
            },
        };
        for (generated_benchmarks) |generated_benchmark| {
            if (!generatedBenchmarkMatches(
                benchmark_filter,
                benchmark_include_long,
                generated_benchmark.default_enabled,
                generated_benchmark.filter,
                generated_benchmark.model_path,
            )) {
                continue;
            }
            const run_generated_benchmark = addGeneratedBenchmark(
                b,
                target,
                optimize,
                tlzig_module,
                generated_benchmark.name,
                generated_benchmark.model_path,
                generated_benchmark.filter,
                benchmark_generated_expressions,
            );
            run_generated_benchmark.step.dependOn(
                previous_generated_benchmark,
            );
            run_generated_benchmark.step.dependOn(&build_tlc.step);
            benchmark_step.dependOn(&run_generated_benchmark.step);
            previous_generated_benchmark = &run_generated_benchmark.step;
        }
    }

    const harness = b.addExecutable(.{
        .name = "harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/harness.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(harness);

    const run_harness = b.addRunArtifact(harness);
    run_harness.step.dependOn(b.getInstallStep());
    b.step("harness", "Run spec harness").dependOn(&run_harness.step);
}

const GeneratedBenchmark = struct {
    name: []const u8,
    model_path: []const u8,
    filter: []const u8,
    default_enabled: bool = true,
};

fn addGeneratedBenchmark(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tlzig_module: *std.Build.Module,
    name: []const u8,
    generated_model_path: []const u8,
    filter: []const u8,
    generated_expressions: bool,
) *std.Build.Step.Run {
    const generated_model_module = b.createModule(.{
        .root_source_file = b.path(generated_model_path),
        .target = target,
        .optimize = optimize,
    });
    generated_model_module.addImport("tlzig", tlzig_module);

    const bench = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench.root_module.addImport("tlzig", tlzig_module);
    bench.root_module.addImport("generated_model", generated_model_module);
    const run_bench = b.addRunArtifact(bench);
    run_bench.has_side_effects = true;
    run_bench.addArg(filter);
    run_bench.addArgs(&.{ "--label-suffix", " [AOT]", "--auto-only" });
    if (generated_expressions) {
        run_bench.addArg("--generated-expressions");
    }
    return run_bench;
}

fn generatedBenchmarkMatches(
    optional_filter: ?[]const u8,
    include_long: bool,
    default_enabled: bool,
    label: []const u8,
    generated_model_path: []const u8,
) bool {
    const filter = optional_filter orelse return include_long or default_enabled;
    const exact_label_match = std.mem.eql(u8, label, filter);
    if (!include_long and !default_enabled and !exact_label_match) return false;
    const label_contains_filter =
        std.mem.indexOf(u8, label, filter) != null and
        !detailedLabelPrefixMatch(label, filter);
    return exact_label_match or
        label_contains_filter or
        std.mem.indexOf(u8, generated_model_path, filter) != null;
}

fn detailedLabelPrefixMatch(label: []const u8, filter: []const u8) bool {
    if (filter.len == 0 or label.len <= filter.len) return false;
    if (!std.mem.startsWith(u8, label, filter)) return false;
    if (label[filter.len] != ' ') return false;
    return std.mem.indexOfScalar(u8, filter, '/') != null;
}
