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
    const benchmark_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    benchmark_tests.root_module.addImport("tlzig", tlzig_module);
    benchmark_tests.root_module.addImport(
        "generated_model",
        generated_model_module,
    );
    const run_benchmark_tests = b.addRunArtifact(benchmark_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_benchmark_tests.step);

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
    const benchmark_tlzig_only = b.option(
        bool,
        "benchmark-tlzig-only",
        "Run tlzig benchmark columns without starting Java TLC",
    ) orelse false;
    if (!benchmark_tlzig_only) {
        run_bench.step.dependOn(&build_tlc.step);
    }
    if (benchmark_filter) |filter| {
        run_bench.addArg(filter);
    }
    if (benchmark_include_long) {
        run_bench.addArg("--include-long");
    }
    if (benchmark_tlzig_only) {
        run_bench.addArgs(&.{
            "--tlzig-only",
            "--write-tlzig-baseline",
        });
    }
    if (generated_model_path == null and !benchmark_tlzig_only) {
        run_bench.addArg("--tlc-baseline-prefer-generated");
    }
    const benchmark_step = b.step("benchmark", "Benchmark tlzig vs Java TLC");
    benchmark_step.dependOn(&run_bench.step);
    if (generated_model_path == null) {
        var previous_generated_benchmark: *std.Build.Step = &run_bench.step;
        const generated_benchmarks = [_]GeneratedBenchmark{
            .{
                .name = "benchmark_slush_medium_aot",
                .model_path = "generated_models/slush_medium.zig",
                .tla = "vendor/tlaplus-examples/specifications/SlushProtocol/Slush.tla",
                .cfg = "vendor/tlaplus-examples/specifications/SlushProtocol/SlushMedium.cfg",
                .filter = "Slush Medium",
            },
            .{
                .name = "benchmark_slush_large_aot",
                .model_path = "generated_models/slush_large.zig",
                .tla = "vendor/tlaplus-examples/specifications/SlushProtocol/Slush.tla",
                .cfg = "vendor/tlaplus-examples/specifications/SlushProtocol/SlushLarge.cfg",
                .filter = "Slush Large",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mc_binary_search_aot",
                .model_path = "generated_models/mc_binary_search.zig",
                .tla = "vendor/tlaplus-examples/specifications/LoopInvariance/MCBinarySearch.tla",
                .cfg = "vendor/tlaplus-examples/specifications/LoopInvariance/MCBinarySearch.cfg",
                .filter = "MCBinarySearch",
            },
            .{
                .name = "benchmark_paxos_commit_aot",
                .model_path = "generated_models/paxos_commit.zig",
                .tla = "vendor/tlaplus-examples/specifications/transaction_commit/PaxosCommit.tla",
                .cfg = "vendor/tlaplus-examples/specifications/transaction_commit/PaxosCommit.cfg",
                .filter = "PaxosCommit",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_multi_paxos_small_aot",
                .model_path = "generated_models/multi_paxos_small.zig",
                .tla = "vendor/tlaplus-examples/specifications/MultiPaxos-SMR/MultiPaxos_MC.tla",
                .cfg = "vendor/tlaplus-examples/specifications/MultiPaxos-SMR/MultiPaxos_MC_small.cfg",
                .filter = "MultiPaxosSmall",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_multi_paxos_aot",
                .model_path = "generated_models/multi_paxos.zig",
                .tla = "vendor/tlaplus-examples/specifications/MultiPaxos-SMR/MultiPaxos_MC.tla",
                .cfg = "vendor/tlaplus-examples/specifications/MultiPaxos-SMR/MultiPaxos_MC.cfg",
                .filter = "MultiPaxos",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_game_of_life_aot",
                .model_path = "generated_models/game_of_life.zig",
                .tla = "vendor/tlaplus-examples/specifications/GameOfLife/GameOfLife.tla",
                .cfg = "vendor/tlaplus-examples/specifications/GameOfLife/GameOfLife.cfg",
                .filter = "GameOfLife",
            },
            .{
                .name = "benchmark_sailfish1_aot",
                .model_path = "generated_models/sailfish1.zig",
                .tla = "vendor/tlaplus-examples/specifications/dag-consensus/TLCSailfish1.tla",
                .cfg = "vendor/tlaplus-examples/specifications/dag-consensus/TLCSailfish1.cfg",
                .filter = "Sailfish1",
            },
            .{
                .name = "benchmark_ewd998_small_aot",
                .model_path = "generated_models/ewd998_small.zig",
                .tla = "vendor/tlaplus-examples/specifications/ewd998/EWD998.tla",
                .cfg = "vendor/tlaplus-examples/specifications/ewd998/EWD998Small.cfg",
                .filter = "EWD998Small",
            },
            .{
                .name = "benchmark_ewd998_n2_temporal_aot",
                .model_path = "generated_models/ewd998_n2_temporal.zig",
                .tla = "vendor/tlaplus-examples/specifications/ewd998/EWD998.tla",
                .cfg = "benchmark_configs/EWD998N2Temporal.cfg",
                .filter = "EWD998 N2 Temporal",
            },
            .{
                .name = "benchmark_ewd998_original_large_aot",
                .model_path = "generated_models/ewd998.zig",
                .tla = "vendor/tlaplus-examples/specifications/ewd998/EWD998.tla",
                .cfg = "vendor/tlaplus-examples/specifications/ewd998/EWD998.cfg",
                .filter = "EWD998 Original Large",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_ewd998_chan_small_aot",
                .model_path = "generated_models/ewd998_chan_small.zig",
                .tla = "vendor/tlaplus-examples/specifications/ewd998/EWD998Chan.tla",
                .cfg = "benchmark_configs/EWD998Chan_small.cfg",
                .filter = "EWD998ChanSmall",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_ewd998_chan_aot",
                .model_path = "generated_models/ewd998_chan.zig",
                .tla = "vendor/tlaplus-examples/specifications/ewd998/EWD998Chan.tla",
                .cfg = "vendor/tlaplus-examples/specifications/ewd998/EWD998Chan.cfg",
                .filter = "EWD998Chan",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_elevator_liveness_medium_aot",
                .model_path = "generated_models/elevator_liveness_medium.zig",
                .tla = "vendor/tlaplus-examples/specifications/MultiCarElevator/Elevator.tla",
                .cfg = "vendor/tlaplus-examples/specifications/MultiCarElevator/ElevatorLivenessMedium.cfg",
                .filter = "ElevatorLivenessMedium",
            },
            .{
                .name = "benchmark_cf1s_folklore_aot",
                .model_path = "generated_models/cf1s_folklore.zig",
                .tla = "vendor/tlaplus-examples/specifications/cf1s-folklore/cf1s_folklore.tla",
                .cfg = "vendor/tlaplus-examples/specifications/cf1s-folklore/cf1s_folklore.cfg",
                .filter = "cf1s folklore",
            },
            .{
                .name = "benchmark_elevator_safety_medium_aot",
                .model_path = "generated_models/elevator_safety_medium.zig",
                .tla = "vendor/tlaplus-examples/specifications/MultiCarElevator/Elevator.tla",
                .cfg = "vendor/tlaplus-examples/specifications/MultiCarElevator/ElevatorSafetyMedium.cfg",
                .filter = "ElevatorSafetyMedium",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_elevator_safety_large_aot",
                .model_path = "generated_models/elevator_safety_large.zig",
                .tla = "vendor/tlaplus-examples/specifications/MultiCarElevator/Elevator.tla",
                .cfg = "vendor/tlaplus-examples/specifications/MultiCarElevator/ElevatorSafetyLarge.cfg",
                .filter = "ElevatorSafetyLarge",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_spantree_test5_aot",
                .model_path = "generated_models/spantree_test5.zig",
                .tla = "vendor/tlaplus-examples/specifications/SpanningTree/SpanTreeTest.tla",
                .cfg = "vendor/tlaplus-examples/specifications/SpanningTree/SpanTreeTest5Nodes.cfg",
                .filter = "SpanTreeTest5Nodes",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_ap_bcast_folklore_aot",
                .model_path = "generated_models/ap_bcast_folklore.zig",
                .tla = "vendor/tlaplus-examples/specifications/bcastFolklore/APbcastFolklore.tla",
                .cfg = "vendor/tlaplus-examples/specifications/bcastFolklore/APbcastFolklore.cfg",
                .filter = "APbcastFolklore",
            },
            .{
                .name = "benchmark_bosco_aot",
                .model_path = "generated_models/bosco.zig",
                .tla = "vendor/tlaplus-examples/specifications/bosco/bosco.tla",
                .cfg = "vendor/tlaplus-examples/specifications/bosco/bosco.cfg",
                .filter = "Bosco",
            },
            .{
                .name = "benchmark_environment_controller_n2_safety_aot",
                .model_path = "generated_models/environment_controller_n2_safety.zig",
                .tla = "vendor/tlaplus-examples/specifications/detector_chan96/EnvironmentController.tla",
                .cfg = "benchmark_configs/EnvironmentControllerN2Safety.cfg",
                .filter = "EnvironmentControllerN2Safety",
            },
            .{
                .name = "benchmark_mc_kvs_safety_small_aot",
                .model_path = "generated_models/mc_kvs_safety_small.zig",
                .tla = "vendor/tlaplus-examples/specifications/KeyValueStore/MCKVS.tla",
                .cfg = "vendor/tlaplus-examples/specifications/KeyValueStore/MCKVSSafetySmall.cfg",
                .filter = "MCKVSSafetySmall",
            },
            .{
                .name = "benchmark_mc_kvs_safety_medium_aot",
                .model_path = "generated_models/mc_kvs_safety_medium.zig",
                .tla = "vendor/tlaplus-examples/specifications/KeyValueStore/MCKVS.tla",
                .cfg = "vendor/tlaplus-examples/specifications/KeyValueStore/MCKVSSafetyMedium.cfg",
                .filter = "MCKVSSafetyMedium",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mc_kvsnap_aot",
                .model_path = "generated_models/mc_kvsnap.zig",
                .tla = "vendor/tlaplus-examples/specifications/KeyValueStore/MCKVsnap.tla",
                .cfg = "benchmark_configs/MCKVsnap_no_sym.cfg",
                .filter = "MCKVsnap",
            },
            .{
                .name = "benchmark_btree_aot",
                .model_path = "generated_models/btree.zig",
                .tla = "vendor/tlaplus-examples/specifications/btree/btree.tla",
                .cfg = "vendor/tlaplus-examples/specifications/btree/btree.cfg",
                .filter = "BTree",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_nano_medium_aot",
                .model_path = "generated_models/nano_medium.zig",
                .tla = "vendor/tlaplus-examples/specifications/NanoBlockchain/MCNano.tla",
                .cfg = "vendor/tlaplus-examples/specifications/NanoBlockchain/MCNanoMedium.cfg",
                .filter = "NanoMedium",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_nano_hash5_small_aot",
                .model_path = "generated_models/nano_hash5_small.zig",
                .tla = "vendor/tlaplus-examples/specifications/NanoBlockchain/MCNano.tla",
                .cfg = "benchmark_configs/MCNanoHash5Small.cfg",
                .filter = "NanoHash5Small",
            },
            .{
                .name = "benchmark_nano_large_aot",
                .model_path = "generated_models/nano_large.zig",
                .tla = "vendor/tlaplus-examples/specifications/NanoBlockchain/MCNano.tla",
                .cfg = "vendor/tlaplus-examples/specifications/NanoBlockchain/MCNanoLarge.cfg",
                .filter = "NanoLarge",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_bcast_folklore_aot",
                .model_path = "generated_models/bcast_folklore.zig",
                .tla = "vendor/tlaplus-examples/specifications/bcastFolklore/bcastFolklore.tla",
                .cfg = "vendor/tlaplus-examples/specifications/bcastFolklore/bcastFolklore.cfg",
                .filter = "bcastFolklore",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_coffee_can_1000_aot",
                .model_path = "generated_models/coffee_can_1000.zig",
                .tla = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan.tla",
                .cfg = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan1000Beans.cfg",
                .filter = "CoffeeCan1000",
            },
            .{
                .name = "benchmark_coffee_can_3000_aot",
                .model_path = "generated_models/coffee_can_3000.zig",
                .tla = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan.tla",
                .cfg = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan3000Beans.cfg",
                .filter = "CoffeeCan3000",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_client_centric_aot",
                .model_path = "generated_models/mdbtla_client_centric.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/ClientCentricTests.tla",
                .cfg = "vendor/MDBTLA/MultiShardTxn/ClientCentricTests.cfg",
                .filter = "MultiShardTxn ClientCentric",
            },
            .{
                .name = "benchmark_mdbtla_mcm_snapshot_aot",
                .model_path = "generated_models/mdbtla_mcm_snapshot_invariant.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
                .cfg = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.cfg",
                .filter = "MultiShardTxn MCM/snapshot-invariant",
            },
            .{
                .name = "benchmark_mdbtla_mcm_rc_local_aot",
                .model_path = "generated_models/mdbtla_mcm_rc_local_invariant.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
                .cfg = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn_rc_local.cfg",
                .filter = "MultiShardTxn MCM/rc-local-invariant",
            },
            .{
                .name = "benchmark_mdbtla_storage_aot",
                .model_path = "generated_models/mdbtla_storage.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/Storage.tla",
                .cfg = "vendor/MDBTLA/MultiShardTxn/Storage.cfg",
                .filter = "MultiShardTxn Storage",
            },
            .{
                .name = "benchmark_mdbtla_storage_exhaustive_aot",
                .model_path = "generated_models/mdbtla_storage_exhaustive.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/Storage.tla",
                .cfg = "benchmark_configs/MDBTLA/MultiShardTxn/Storage_exhaustive.cfg",
                .filter = "MultiShardTxn Storage exhaustive",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_rc_no_prepare_aot",
                .model_path = "generated_models/mdbtla_rc_no_prepare_block.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
                .cfg = "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block.cfg",
                .filter = "MultiShardTxn RC/no-prepare-block",
            },
            .{
                .name = "benchmark_mdbtla_rc_no_prepare_exhaustive_aot",
                .model_path = "generated_models/mdbtla_rc_no_prepare_block_exhaustive.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
                .cfg = "benchmark_configs/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block_exhaustive.cfg",
                .filter = "MultiShardTxn RC/no-prepare-block exhaustive",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_rc_no_prepare_ww_aot",
                .model_path = "generated_models/mdbtla_rc_no_prepare_block_or_ww.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
                .cfg = "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block_or_ww.cfg",
                .filter = "MultiShardTxn RC/no-prepare-block-or-ww",
            },
            .{
                .name = "benchmark_mdbtla_rc_no_prepare_ww_exhaustive_aot",
                .model_path = "generated_models/mdbtla_rc_no_prepare_block_or_ww_exhaustive.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
                .cfg = "benchmark_configs/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block_or_ww_exhaustive.cfg",
                .filter = "MultiShardTxn RC/no-prepare-block-or-ww exhaustive",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_rc_snapshot_aot",
                .model_path = "generated_models/mdbtla_rc_snapshot.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
                .cfg = "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_snapshot.cfg",
                .filter = "MultiShardTxn RC/snapshot",
            },
            .{
                .name = "benchmark_mdbtla_rc_snapshot_exhaustive_aot",
                .model_path = "generated_models/mdbtla_rc_snapshot_exhaustive.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
                .cfg = "benchmark_configs/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_snapshot_exhaustive.cfg",
                .filter = "MultiShardTxn RC/snapshot exhaustive",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_rc_with_prepare_aot",
                .model_path = "generated_models/mdbtla_rc_with_prepare_block.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
                .cfg = "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_with_prepare_block.cfg",
                .filter = "MultiShardTxn RC/with-prepare-block",
            },
            .{
                .name = "benchmark_mdbtla_rc_with_prepare_exhaustive_aot",
                .model_path = "generated_models/mdbtla_rc_with_prepare_block_exhaustive.zig",
                .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
                .cfg = "benchmark_configs/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_with_prepare_block_exhaustive.cfg",
                .filter = "MultiShardTxn RC/with-prepare-block exhaustive",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_single_shard_txn_full_aot",
                .model_path = "generated_models/mdbtla_single_shard_txn_full.zig",
                .tla = "vendor/MDBTLA/SingleShardTxn/ShardTxn.tla",
                .cfg = "benchmark_configs/MDBTLA/SingleShardTxn/ShardTxn_no_sym.cfg",
                .filter = "SingleShardTxn ShardTxn",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_single_shard_txn_small_no_sym_aot",
                .model_path = "generated_models/mdbtla_single_shard_txn_small_no_sym.zig",
                .tla = "vendor/MDBTLA/SingleShardTxn/ShardTxn.tla",
                .cfg = "benchmark_configs/MDBTLA/SingleShardTxn/ShardTxn_small_no_sym.cfg",
                .filter = "SingleShardTxn ShardTxn/small",
            },
            .{
                .name = "benchmark_mdbtla_single_shard_txn_small_safety_aot",
                .model_path = "generated_models/mdbtla_single_shard_txn_small_safety.zig",
                .tla = "vendor/MDBTLA/SingleShardTxn/ShardTxn.tla",
                .cfg = "benchmark_configs/MDBTLA/SingleShardTxn/ShardTxn_small_safety.cfg",
                .filter = "SingleShardTxn ShardTxn/small safety",
            },
            .{
                .name = "benchmark_mdbtla_single_shard_txn_small_safety_no_sym_aot",
                .model_path = "generated_models/mdbtla_single_shard_txn_small_safety_no_sym.zig",
                .tla = "vendor/MDBTLA/SingleShardTxn/ShardTxn.tla",
                .cfg = "benchmark_configs/MDBTLA/SingleShardTxn/ShardTxn_small_safety_no_sym.cfg",
                .filter = "SingleShardTxn ShardTxn/small safety no-sym",
            },
            .{
                .name = "benchmark_mdbtla_singlelog_mcmdbprops_aot",
                .model_path = "generated_models/mdbtla_singlelog_mcmdbprops.zig",
                .tla = "vendor/MDBTLA/SingleLog/MCMDBProps.tla",
                .cfg = "vendor/MDBTLA/SingleLog/MCMDBProps.cfg",
                .filter = "SingleLog MCMDBProps",
                .default_enabled = false,
            },
            .{
                .name = "benchmark_mdbtla_singlelog_mdblinearizability_aot",
                .model_path = "generated_models/mdbtla_singlelog_mdblinearizability.zig",
                .tla = "vendor/MDBTLA/SingleLog/MDBLinearizability.tla",
                .cfg = "vendor/MDBTLA/SingleLog/MDBLinearizability.cfg",
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
                exe,
                generated_benchmark.name,
                generated_benchmark.model_path,
                generated_benchmark.tla,
                generated_benchmark.cfg,
                generated_benchmark.filter,
            );
            run_generated_benchmark.step.dependOn(
                previous_generated_benchmark,
            );
            if (!benchmark_tlzig_only) {
                run_generated_benchmark.step.dependOn(&build_tlc.step);
            }
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
    tla: []const u8,
    cfg: []const u8,
    filter: []const u8,
    default_enabled: bool = true,
};

fn addGeneratedBenchmark(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tlzig_module: *std.Build.Module,
    emitter: *std.Build.Step.Compile,
    name: []const u8,
    generated_model_path: []const u8,
    generated_benchmark_tla: []const u8,
    generated_benchmark_cfg: []const u8,
    filter: []const u8,
) *std.Build.Step.Run {
    const regenerate = b.addRunArtifact(emitter);
    regenerate.has_side_effects = true;
    regenerate.addArgs(&.{
        "--spec",
        generated_benchmark_tla,
        "--cfg",
        generated_benchmark_cfg,
        "--emit-zig",
        generated_model_path,
    });
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
    bench.step.dependOn(&regenerate.step);
    bench.root_module.addImport("tlzig", tlzig_module);
    bench.root_module.addImport("generated_model", generated_model_module);
    const run_bench = b.addRunArtifact(bench);
    run_bench.has_side_effects = true;
    run_bench.addArg(filter);
    run_bench.addArgs(&.{
        "--label-suffix",
        " [AOT]",
        "--auto-only",
        "--tlzig-only",
    });
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
