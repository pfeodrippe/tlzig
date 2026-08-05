const std = @import("std");
const tlzig = @import("tlzig");
const Arena = tlzig.Arena;
const ast = tlzig.ast;
const checker = tlzig.checker;
const config = tlzig.config;
const ModuleLoader = tlzig.ModuleLoader;
const overrides = tlzig.overrides;
const generated_runtime = tlzig.generated_runtime;
const generated_model = @import("generated_model");

comptime {
    if (!@hasDecl(generated_model, "abi_version")) {
        @compileError("generated model is stale; regenerate it with tlzig --emit-zig");
    }
    if (generated_model.abi_version !=
        generated_runtime.generated_model_abi_version)
    {
        @compileError("generated model ABI mismatch; regenerate it with tlzig --emit-zig");
    }
    if (generated_model.fallback_count != 0) {
        @compileError(
            "benchmark requires a strict generated model with fallback_count == 0",
        );
    }
}

const Spec = struct {
    label: ?[]const u8 = null,
    tla: []const u8,
    cfg: []const u8,
    default_enabled: bool = true,
    one_core_default: bool = true,
    max_states: u32 = 100_000,
    max_successors: u32 = 65_536,
    max_graph_edges: ?u32 = null,
    max_nat: i64 = 1000,
    min_int: i64 = -1000,
    max_int: i64 = 1000,
    state_values_per_state: u32 = 60,
    state_value_cap: ?u32 = null,
    scratch_growable: bool = false,
    expected_violation: bool = false,
    distinct_tolerance: u64 = 0,
    expected_distinct_tolerance: ?u64 = null,
    compare_generated: bool = true,
    compare_distinct: bool = true,
    prefer_generated: bool = false,
    java_classpath: ?[]const u8 = null,
    java_heap: ?[]const u8 = null,
};

const Options = struct {
    filter: ?[]const u8 = null,
    label_suffix: []const u8 = "",
    include_long: bool = false,
    include_one_core: bool = false,
    auto_only: bool = false,
    tlzig_only: bool = false,
    skip_prefer_generated: bool = false,
    tlc_baseline_prefer_generated: bool = false,
    write_tlzig_baseline: bool = false,
};

const specs = [_]Spec{
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/HourClock/HourClock.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/HourClock/HourClock.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/AsynchInterface.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/AsynchInterface.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/Channel.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/Channel.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/DieHard/DieHard.tla", .cfg = "vendor/tlaplus-examples/specifications/DieHard/DieHard.cfg", .expected_violation = true },
    .{ .tla = "vendor/tlaplus-examples/specifications/MissionariesAndCannibals/MissionariesAndCannibals.tla", .cfg = "vendor/tlaplus-examples/specifications/MissionariesAndCannibals/MissionariesAndCannibals.cfg", .expected_violation = true },
    .{ .tla = "vendor/tlaplus-examples/specifications/CigaretteSmokers/CigaretteSmokers.tla", .cfg = "vendor/tlaplus-examples/specifications/CigaretteSmokers/CigaretteSmokers.cfg", .max_states = 5000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/CigaretteSmokers/APCigaretteSmokers.tla", .cfg = "vendor/tlaplus-examples/specifications/CigaretteSmokers/APCigaretteSmokers.cfg", .max_states = 5000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan.tla", .cfg = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan100Beans.cfg", .default_enabled = false, .one_core_default = false, .max_states = 100_000, .max_nat = 1000, .min_int = -1000, .max_int = 1000 },
    .{ .label = "CoffeeCan1000", .tla = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan.tla", .cfg = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan1000Beans.cfg", .one_core_default = false, .max_states = 600_000, .state_values_per_state = 16, .prefer_generated = true },
    .{ .tla = "vendor/tlaplus-examples/specifications/TeachingConcurrency/Simple.tla", .cfg = "vendor/tlaplus-examples/specifications/TeachingConcurrency/Simple.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/barriers/Barrier.tla", .cfg = "vendor/tlaplus-examples/specifications/barriers/Barrier.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/locks_auxiliary_vars/Lock.tla", .cfg = "vendor/tlaplus-examples/specifications/locks_auxiliary_vars/Lock.cfg" },
    .{ .tla = "vendor/tlaplus-examples/specifications/Majority/MCMajority.tla", .cfg = "vendor/tlaplus-examples/specifications/Majority/MCMajority.cfg", .max_states = 100_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/LearnProofs/MCFindHighest.tla", .cfg = "vendor/tlaplus-examples/specifications/LearnProofs/MCFindHighest.cfg", .max_states = 100_000, .compare_generated = false },
    .{ .tla = "vendor/tlaplus-examples/specifications/transaction_commit/TwoPhase.tla", .cfg = "vendor/tlaplus-examples/specifications/transaction_commit/TwoPhase.cfg", .max_states = 100_000, .compare_generated = false },
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/Liveness/LiveHourClock.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/Liveness/LiveHourClock.cfg" },
    // Higher state count specs:
    .{ .label = "CoffeeCan3000", .tla = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan.tla", .cfg = "vendor/tlaplus-examples/specifications/CoffeeCan/CoffeeCan3000Beans.cfg", .default_enabled = false, .one_core_default = false, .max_states = 5_000_000, .max_nat = 10_000, .min_int = -10_000, .max_int = 10_000, .state_values_per_state = 16, .prefer_generated = true },
    .{ .tla = "vendor/tlaplus-examples/specifications/transaction_commit/TCommit.tla", .cfg = "vendor/tlaplus-examples/specifications/transaction_commit/TCommit.cfg", .max_states = 500_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/transaction_commit/APTCommit.tla", .cfg = "vendor/tlaplus-examples/specifications/transaction_commit/APTCommit.cfg", .max_states = 500_000 },
    // The reduced complete graph audit proves exact states and semantic edges;
    // TLC additionally counts duplicate existential/action witnesses.
    .{ .label = "PaxosCommit", .tla = "vendor/tlaplus-examples/specifications/transaction_commit/PaxosCommit.tla", .cfg = "vendor/tlaplus-examples/specifications/transaction_commit/PaxosCommit.cfg", .default_enabled = false, .one_core_default = false, .max_states = 5_000_000, .state_values_per_state = 192, .compare_generated = false, .prefer_generated = true },
    // Complete quotient-graph audit: exact states, initial state, and semantic
    // edges under the configured replica symmetry. TLC retains duplicate
    // action witnesses, so its raw generated-state counter is non-semantic.
    .{ .label = "MultiPaxosSmall", .tla = "vendor/tlaplus-examples/specifications/MultiPaxos-SMR/MultiPaxos_MC.tla", .cfg = "vendor/tlaplus-examples/specifications/MultiPaxos-SMR/MultiPaxos_MC_small.cfg", .default_enabled = false, .one_core_default = false, .max_states = 2_000_000, .state_values_per_state = 320, .compare_generated = false, .prefer_generated = true },
    // Full 37-million-state quotient graph. TLC retains 10,668 additional
    // duplicate action witnesses, so require exact distinct-state parity.
    .{ .label = "MultiPaxos", .tla = "vendor/tlaplus-examples/specifications/MultiPaxos-SMR/MultiPaxos_MC.tla", .cfg = "vendor/tlaplus-examples/specifications/MultiPaxos-SMR/MultiPaxos_MC.cfg", .default_enabled = false, .one_core_default = false, .max_states = 40_000_000, .max_successors = 4_096, .state_values_per_state = 2, .state_value_cap = 80_000_000, .compare_generated = false, .prefer_generated = true, .java_heap = "-Xmx24g" },
    .{ .tla = "vendor/tlaplus-examples/specifications/chang_roberts/MCChangRoberts.tla", .cfg = "vendor/tlaplus-examples/specifications/chang_roberts/MCChangRoberts.cfg", .max_states = 500_000, .expected_violation = true },
    .{ .tla = "vendor/tlaplus-examples/specifications/SpanningTree/SpanTree.tla", .cfg = "vendor/tlaplus-examples/specifications/SpanningTree/SpanTree.cfg", .default_enabled = false, .one_core_default = false, .max_states = 500_000, .expected_violation = true },
    .{ .tla = "vendor/tlaplus-examples/specifications/ewd840/SyncTerminationDetection.tla", .cfg = "vendor/tlaplus-examples/specifications/ewd840/SyncTerminationDetection.cfg", .max_states = 500_000, .compare_generated = false },
    .{ .tla = "vendor/tlaplus-examples/specifications/ewd998/AsyncTerminationDetection.tla", .cfg = "vendor/tlaplus-examples/specifications/ewd998/AsyncTerminationDetection.cfg", .max_states = 200_000, .compare_generated = false },
    // Complete N=2 graph audit: exact states, initial states, semantic edges,
    // and weak-fair System edges. TLC retains duplicate action witnesses.
    .{ .label = "EWD998ChanSmall", .tla = "vendor/tlaplus-examples/specifications/ewd998/EWD998Chan.tla", .cfg = "benchmark_configs/EWD998Chan_small.cfg", .default_enabled = false, .one_core_default = false, .max_states = 500_000, .state_values_per_state = 96, .compare_generated = false, .prefer_generated = true },
    .{ .label = "EWD998Chan", .tla = "vendor/tlaplus-examples/specifications/ewd998/EWD998Chan.tla", .cfg = "vendor/tlaplus-examples/specifications/ewd998/EWD998Chan.cfg", .default_enabled = false, .one_core_default = false, .max_states = 20_000_000, .state_values_per_state = 96, .compare_generated = false, .prefer_generated = true },
    // Representative larger state spaces and advanced semantics:
    .{
        .label = "Slush Medium",
        .tla = "vendor/tlaplus-examples/specifications/SlushProtocol/Slush.tla",
        .cfg = "vendor/tlaplus-examples/specifications/SlushProtocol/SlushMedium.cfg",
        .one_core_default = false,
        .max_states = 10_000_000,
        .prefer_generated = true,
    },
    // Exact 244-million-state graph. Keep the all-core pair opt-in because it
    // takes roughly twenty minutes and approaches the memory limit of a 48 GiB
    // machine. The upstream configuration has no symmetry reduction.
    .{
        .label = "Slush Large",
        .tla = "vendor/tlaplus-examples/specifications/SlushProtocol/Slush.tla",
        .cfg = "vendor/tlaplus-examples/specifications/SlushProtocol/SlushLarge.cfg",
        .default_enabled = false,
        .one_core_default = false,
        .max_states = 250_000_000,
        .state_values_per_state = 2,
        .state_value_cap = 8_000_000,
        .prefer_generated = true,
        .java_heap = "-Xmx32g",
    },
    .{ .tla = "vendor/tlaplus-examples/specifications/FiniteMonotonic/MCReplicatedLog.tla", .cfg = "vendor/tlaplus-examples/specifications/FiniteMonotonic/MCReplicatedLog.cfg", .max_states = 200_000, .compare_generated = false },
    .{ .tla = "vendor/tlaplus-examples/specifications/FiniteMonotonic/MCCRDT.tla", .cfg = "vendor/tlaplus-examples/specifications/FiniteMonotonic/MCCRDT.cfg", .max_states = 200_000, .compare_generated = false },
    .{ .label = "MCBinarySearch", .tla = "vendor/tlaplus-examples/specifications/LoopInvariance/MCBinarySearch.tla", .cfg = "vendor/tlaplus-examples/specifications/LoopInvariance/MCBinarySearch.cfg", .one_core_default = false, .max_states = 200_000, .prefer_generated = true },
    .{ .label = "GameOfLife", .tla = "vendor/tlaplus-examples/specifications/GameOfLife/GameOfLife.tla", .cfg = "vendor/tlaplus-examples/specifications/GameOfLife/GameOfLife.cfg", .one_core_default = false, .max_states = 200_000, .state_values_per_state = 80, .prefer_generated = true },
    // TLC counts duplicate existential witnesses as generated states here.
    // Strict graph audits establish exact state and transition-relation parity.
    .{ .label = "Sailfish1", .tla = "vendor/tlaplus-examples/specifications/dag-consensus/TLCSailfish1.tla", .cfg = "vendor/tlaplus-examples/specifications/dag-consensus/TLCSailfish1.cfg", .one_core_default = false, .max_states = 120_000, .state_values_per_state = 256, .compare_generated = false, .prefer_generated = true },
    // TLC retains duplicate action witnesses in its generated-state counter.
    // The N=2 strict audit matches all states, initial states, unique edges,
    // and the weak-fair System edge subset; compare exact distinct states here.
    .{ .label = "EWD998Small", .tla = "vendor/tlaplus-examples/specifications/ewd998/EWD998.tla", .cfg = "vendor/tlaplus-examples/specifications/ewd998/EWD998Small.cfg", .one_core_default = false, .max_states = 1_600_000, .state_values_per_state = 60, .compare_generated = false, .prefer_generated = true },
    // Complete constrained N=2 temporal graph. This exercises both temporal
    // properties and catches generated UNCHANGED calls that inherit enclosing
    // action parameters. TLC retains duplicate action witnesses, so compare
    // exact distinct states and outcomes.
    .{ .label = "EWD998 N2 Temporal", .tla = "vendor/tlaplus-examples/specifications/ewd998/EWD998.tla", .cfg = "benchmark_configs/EWD998N2Temporal.cfg", .one_core_default = false, .max_states = 100_000, .state_values_per_state = 96, .compare_generated = false, .prefer_generated = true },
    // Original N=4 temporal model. Keep the exhaustive pair opt-in because
    // its complete graph has 248,006,200 states and 2,083,298,801 edges.
    .{ .label = "EWD998 Original Large", .tla = "vendor/tlaplus-examples/specifications/ewd998/EWD998.tla", .cfg = "vendor/tlaplus-examples/specifications/ewd998/EWD998.cfg", .default_enabled = false, .one_core_default = false, .max_states = 250_000_000, .max_successors = 4_096, .max_graph_edges = 2_200_000_000, .state_values_per_state = 2, .state_value_cap = 180_000_000, .scratch_growable = true, .compare_generated = false, .prefer_generated = true, .java_heap = "-Xmx24g" },
    // Completing liveness check with 18 quantified WF/SF obligations.
    .{ .label = "ElevatorLivenessMedium", .tla = "vendor/tlaplus-examples/specifications/MultiCarElevator/Elevator.tla", .cfg = "vendor/tlaplus-examples/specifications/MultiCarElevator/ElevatorLivenessMedium.cfg", .one_core_default = false, .max_states = 100_000, .state_values_per_state = 256, .prefer_generated = true },
    // Two-million-state temporal graph with quantified weak fairness. This
    // guards exact exploration and the allocation-free edge-marker SCC path.
    .{ .label = "cf1s folklore", .tla = "vendor/tlaplus-examples/specifications/cf1s-folklore/cf1s_folklore.tla", .cfg = "vendor/tlaplus-examples/specifications/cf1s-folklore/cf1s_folklore.cfg", .one_core_default = false, .max_states = 3_000_000, .state_values_per_state = 160, .prefer_generated = true },
    // Exhaustive 18-million-state safety model. Keep the all-core pair opt-in
    // so the default benchmark stays within its interactive time budget.
    .{ .label = "ElevatorSafetyMedium", .tla = "vendor/tlaplus-examples/specifications/MultiCarElevator/Elevator.tla", .cfg = "vendor/tlaplus-examples/specifications/MultiCarElevator/ElevatorSafetyMedium.cfg", .default_enabled = false, .one_core_default = false, .max_states = 20_000_000, .state_values_per_state = 16, .state_value_cap = 402_653_184, .compare_generated = false, .prefer_generated = true },
    // Exact 59-million-state safety model. Initial states are streamed in
    // bounded batches; the lower successor cap avoids reserving scratch for
    // the complete 390,625-state initial relation at once.
    .{ .label = "ElevatorSafetyLarge", .tla = "vendor/tlaplus-examples/specifications/MultiCarElevator/Elevator.tla", .cfg = "vendor/tlaplus-examples/specifications/MultiCarElevator/ElevatorSafetyLarge.cfg", .default_enabled = false, .one_core_default = false, .max_states = 65_000_000, .max_successors = 4_096, .state_values_per_state = 2, .state_value_cap = 130_000_000, .compare_generated = false, .prefer_generated = true, .java_heap = "-Xmx24g" },
    // TLC spends about seven minutes eagerly enumerating the outer power set;
    // keep the exact paired row available without extending the default gate.
    .{ .label = "SpanTreeTest5Nodes", .tla = "vendor/tlaplus-examples/specifications/SpanningTree/SpanTreeTest.tla", .cfg = "vendor/tlaplus-examples/specifications/SpanningTree/SpanTreeTest5Nodes.cfg", .default_enabled = false, .one_core_default = false, .max_states = 500_000, .state_values_per_state = 60, .prefer_generated = true },
    // INSTANCE translation over a 501,552-state, 9.7-million-transition graph.
    .{ .label = "APbcastFolklore", .tla = "vendor/tlaplus-examples/specifications/bcastFolklore/APbcastFolklore.tla", .cfg = "vendor/tlaplus-examples/specifications/bcastFolklore/APbcastFolklore.cfg", .one_core_default = false, .max_states = 1_000_000, .state_values_per_state = 160, .prefer_generated = true },
    // Direct bounded power-set enumeration over a 1,072,452-state,
    // 29,223,200-generated-transition graph.
    .{ .label = "Bosco", .tla = "vendor/tlaplus-examples/specifications/bosco/bosco.tla", .cfg = "vendor/tlaplus-examples/specifications/bosco/bosco.cfg", .one_core_default = false, .max_states = 1_200_000, .state_values_per_state = 16, .prefer_generated = true },
    // The upstream N=3 configuration violates TypeOK because messages to a
    // failed process can age beyond maxAge. This reduced model reaches the
    // same age-43 counterexample quickly and exercises direct SUBSET actions.
    .{ .label = "EnvironmentControllerN2Safety", .tla = "vendor/tlaplus-examples/specifications/detector_chan96/EnvironmentController.tla", .cfg = "benchmark_configs/EnvironmentControllerN2Safety.cfg", .one_core_default = false, .max_states = 200_000, .state_values_per_state = 160, .expected_violation = true, .expected_distinct_tolerance = 30_000, .compare_generated = false, .prefer_generated = true },
    // Exact no-symmetry safety graph with two invariants and more than 56
    // million generated transitions. It stays in the default performance gate.
    .{ .label = "MCKVSSafetySmall", .tla = "vendor/tlaplus-examples/specifications/KeyValueStore/MCKVS.tla", .cfg = "vendor/tlaplus-examples/specifications/KeyValueStore/MCKVSSafetySmall.cfg", .one_core_default = false, .max_states = 4_000_000, .state_values_per_state = 16, .prefer_generated = true, .java_heap = "-Xmx8g" },
    // Exact 17-million-state symmetry-reduced safety graph. Keep the pair
    // opt-in so the default gate remains within its interactive time budget.
    .{ .label = "MCKVSSafetyMedium", .tla = "vendor/tlaplus-examples/specifications/KeyValueStore/MCKVS.tla", .cfg = "vendor/tlaplus-examples/specifications/KeyValueStore/MCKVSSafetyMedium.cfg", .default_enabled = false, .one_core_default = false, .max_states = 18_000_000, .state_values_per_state = 16, .prefer_generated = true, .java_heap = "-Xmx12g" },
    // Snapshot-isolation safety and temporal termination over the complete
    // concrete graph. TLC documents symmetry reduction as unsafe for liveness.
    .{ .label = "MCKVsnap", .tla = "vendor/tlaplus-examples/specifications/KeyValueStore/MCKVsnap.tla", .cfg = "benchmark_configs/MCKVsnap_no_sym.cfg", .one_core_default = false, .max_states = 250_000, .state_values_per_state = 160, .prefer_generated = true },
    // Exhaustive recursive operators, nested functions, and multi-bound
    // function literals. Keep it opt-in because the paired run takes tens of
    // seconds even with all cores.
    .{ .label = "BTree", .tla = "vendor/tlaplus-examples/specifications/btree/btree.tla", .cfg = "vendor/tlaplus-examples/specifications/btree/btree.cfg", .default_enabled = false, .one_core_default = false, .max_states = 500_000, .state_values_per_state = 60, .prefer_generated = true },
    // VIEW hides hash-allocation order. Exact generated and distinct counts
    // guard deferred primed arguments across generated action-call frames.
    .{ .label = "NanoMedium", .tla = "vendor/tlaplus-examples/specifications/NanoBlockchain/MCNano.tla", .cfg = "vendor/tlaplus-examples/specifications/NanoBlockchain/MCNanoMedium.cfg", .default_enabled = false, .one_core_default = false, .max_states = 700_000, .state_values_per_state = 160, .prefer_generated = true },
    .{ .label = "NanoHash5Small", .tla = "vendor/tlaplus-examples/specifications/NanoBlockchain/MCNano.tla", .cfg = "benchmark_configs/MCNanoHash5Small.cfg", .one_core_default = false, .max_states = 2_000_000, .state_values_per_state = 32, .prefer_generated = true },
    // Large safety configuration; opt-in because the reachable graph exceeds
    // the default benchmark's memory and time budget.
    .{ .label = "NanoLarge", .tla = "vendor/tlaplus-examples/specifications/NanoBlockchain/MCNano.tla", .cfg = "vendor/tlaplus-examples/specifications/NanoBlockchain/MCNanoLarge.cfg", .default_enabled = false, .one_core_default = false, .max_states = 130_000_000, .max_successors = 4_096, .state_values_per_state = 2, .state_value_cap = 260_000_000, .prefer_generated = true, .java_heap = "-Xmx24g" },
    // TLC's four temporal branches take about nineteen minutes on the full
    // graph. Keep this exact liveness comparison opt-in.
    .{ .label = "bcastFolklore", .tla = "vendor/tlaplus-examples/specifications/bcastFolklore/bcastFolklore.tla", .cfg = "vendor/tlaplus-examples/specifications/bcastFolklore/bcastFolklore.cfg", .default_enabled = false, .one_core_default = false, .max_states = 1_000_000, .state_values_per_state = 160, .prefer_generated = true },
    .{ .tla = "vendor/tlaplus-examples/specifications/ewd687a/MCEWD687a.tla", .cfg = "vendor/tlaplus-examples/specifications/ewd687a/MCEWD687a.cfg", .default_enabled = false, .one_core_default = false, .max_states = 200_000, .compare_generated = false },
    .{ .tla = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AdvancedExamples/MCInnerSerial.tla", .cfg = "vendor/tlaplus-examples/specifications/SpecifyingSystems/AdvancedExamples/MCInnerSerial.cfg", .default_enabled = false, .one_core_default = false, .max_states = 200_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/YoYo/MCYoYoNoPruning.tla", .cfg = "vendor/tlaplus-examples/specifications/YoYo/MCYoYoNoPruning.cfg", .default_enabled = false, .one_core_default = false, .max_states = 200_000 },
    .{ .tla = "vendor/tlaplus-examples/specifications/YoYo/MCYoYoPruning.tla", .cfg = "vendor/tlaplus-examples/specifications/YoYo/MCYoYoPruning.cfg", .default_enabled = false, .one_core_default = false, .max_states = 200_000 },
    .{
        .label = "MultiShardTxn ClientCentric",
        .tla = "vendor/MDBTLA/MultiShardTxn/ClientCentricTests.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/ClientCentricTests.cfg",
        .max_states = 2_000,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn MCM/snapshot-invariant",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.cfg",
        .max_states = 100_000,
        .expected_violation = true,
        .distinct_tolerance = 16,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn MCM/rc-local-invariant",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn_rc_local.cfg",
        .max_states = 20_000,
        .expected_violation = true,
        .distinct_tolerance = 16,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn Storage",
        .tla = "vendor/MDBTLA/MultiShardTxn/Storage.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/Storage.cfg",
        .max_states = 100_000,
        .expected_violation = true,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn Storage exhaustive",
        .tla = "vendor/MDBTLA/MultiShardTxn/Storage.tla",
        .cfg = "benchmark_configs/MDBTLA/MultiShardTxn/Storage_exhaustive.cfg",
        .default_enabled = false,
        .one_core_default = false,
        .max_states = 1_200_000,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn RC/no-prepare-block",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block.cfg",
        .max_states = 20_000,
        .state_values_per_state = 120,
        .expected_violation = true,
        .distinct_tolerance = 32,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn RC/no-prepare-block-or-ww",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block_or_ww.cfg",
        .max_states = 20_000,
        .state_values_per_state = 120,
        .expected_violation = true,
        .distinct_tolerance = 32,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn RC/snapshot",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_snapshot.cfg",
        .max_states = 100_000,
        .state_values_per_state = 300,
        .expected_violation = true,
        .distinct_tolerance = 32,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn RC/with-prepare-block",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_with_prepare_block.cfg",
        .max_states = 20_000,
        .state_values_per_state = 120,
        .expected_violation = true,
        .distinct_tolerance = 32,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn RC/no-prepare-block exhaustive",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "benchmark_configs/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block_exhaustive.cfg",
        .default_enabled = false,
        .one_core_default = false,
        .max_states = 18_000_000,
        .state_values_per_state = 120,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn RC/no-prepare-block-or-ww exhaustive",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "benchmark_configs/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block_or_ww_exhaustive.cfg",
        .default_enabled = false,
        .one_core_default = false,
        .max_states = 20_000_000,
        .state_values_per_state = 120,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn RC/snapshot exhaustive",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "benchmark_configs/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_snapshot_exhaustive.cfg",
        .default_enabled = false,
        .one_core_default = false,
        .max_states = 68_000_000,
        .state_values_per_state = 300,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "MultiShardTxn RC/with-prepare-block exhaustive",
        .tla = "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
        .cfg = "benchmark_configs/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_with_prepare_block_exhaustive.cfg",
        .default_enabled = false,
        .one_core_default = false,
        .max_states = 17_000_000,
        .state_values_per_state = 120,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "SingleLog MCMDBProps",
        .tla = "vendor/MDBTLA/SingleLog/MCMDBProps.tla",
        .cfg = "vendor/MDBTLA/SingleLog/MCMDBProps.cfg",
        .default_enabled = false,
        .one_core_default = false,
        .max_states = 500_000,
        .state_values_per_state = 180,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "SingleLog MDBLinearizability",
        .tla = "vendor/MDBTLA/SingleLog/MDBLinearizability.tla",
        .cfg = "vendor/MDBTLA/SingleLog/MDBLinearizability.cfg",
        .one_core_default = false,
        .max_states = 5_000_000,
        .state_values_per_state = 180,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "SingleShardTxn ShardTxn",
        .tla = "vendor/MDBTLA/SingleShardTxn/ShardTxn.tla",
        .cfg = "benchmark_configs/MDBTLA/SingleShardTxn/ShardTxn_no_sym.cfg",
        .default_enabled = false,
        .one_core_default = false,
        .max_states = 12_000_000,
        .state_values_per_state = 220,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "SingleShardTxn ShardTxn/small",
        .tla = "vendor/MDBTLA/SingleShardTxn/ShardTxn.tla",
        .cfg = "benchmark_configs/MDBTLA/SingleShardTxn/ShardTxn_small_no_sym.cfg",
        .one_core_default = false,
        .max_states = 500_000,
        .state_values_per_state = 220,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "SingleShardTxn ShardTxn/small safety",
        .tla = "vendor/MDBTLA/SingleShardTxn/ShardTxn.tla",
        .cfg = "benchmark_configs/MDBTLA/SingleShardTxn/ShardTxn_small_safety.cfg",
        .one_core_default = false,
        .max_states = 500_000,
        .state_values_per_state = 220,
        .compare_generated = false,
        .prefer_generated = true,
        .java_classpath = "vendor/MDBTLA/MultiShardTxn/lib/tla2tools-v1.8.jar:" ++
            "vendor/MDBTLA/MultiShardTxn/lib/CommunityModules.jar",
    },
    .{
        .label = "SingleShardTxn ShardTxn/small safety no-sym",
        .tla = "vendor/MDBTLA/SingleShardTxn/ShardTxn.tla",
        .cfg = "benchmark_configs/MDBTLA/SingleShardTxn/ShardTxn_small_safety_no_sym.cfg",
        .default_enabled = false,
        .one_core_default = false,
        .max_states = 500_000,
        .state_values_per_state = 220,
        .compare_generated = false,
        .prefer_generated = true,
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
    const options = parse_options(init) catch {
        std.debug.print(
            "usage: benchmark [--include-long] [--include-one-core] [--auto-only] [--tlzig-only] [--skip-prefer-generated] [--tlc-baseline-prefer-generated] [--write-tlzig-baseline] [--filter TEXT|TEXT]\n",
            .{},
        );
        std.process.exit(2);
    };

    std.Io.Dir.cwd().createDirPath(io, "benchmark_results") catch |err| {
        std.debug.print("failed to create benchmark_results: {any}\n", .{err});
        std.process.exit(1);
    };

    const java_classpath =
        "vendor/tlaplus/tlatools/org.lamport.tlatools/dist/tla2tools.jar:" ++
        "vendor/tlaplus/tlatools/org.lamport.tlatools/lib/CommunityModules.jar";

    std.debug.print("{s:32} {s:>10} {s:>10} {s:>10} {s:>10} {s:>18} {s:>18}\n", .{
        "SPEC", "TLC-1", "TLC-auto", "tlzig-1", "tlzig-auto", "TLC states", "tlzig states",
    });
    std.debug.print("-----------------------------------------------------------------------------------------------------------\n", .{});

    var failures: u32 = 0;
    for (specs) |spec| {
        const explicit_match = filter_matches(spec, options.filter);
        const exact_label_match = filter_label_matches(spec, options.filter);
        if (options.filter != null and !explicit_match) continue;
        if (!options.include_long and !spec.default_enabled and
            (options.filter == null or !exact_label_match))
        {
            continue;
        }
        if (options.tlc_baseline_prefer_generated and spec.prefer_generated) {
            run_tlc_baseline(
                allocator,
                io,
                java_classpath,
                spec,
            ) catch |err| {
                failures += 1;
                std.debug.print("{s:40} ERROR {any}\n", .{ spec.tla, err });
            };
            continue;
        }
        if (options.skip_prefer_generated and spec.prefer_generated) {
            continue;
        }
        run_comparison(
            allocator,
            io,
            java_classpath,
            spec,
            !options.auto_only and
                (options.include_one_core or spec.one_core_default),
            options.label_suffix,
            options.tlzig_only,
            options.write_tlzig_baseline,
        ) catch |err| {
            failures += 1;
            std.debug.print("{s:40} ERROR {any}\n", .{ spec.tla, err });
        };
    }
    if (failures > 0) {
        std.debug.print("benchmark failures={d}\n", .{failures});
        std.process.exit(1);
    }
}

fn parse_options(init: std.process.Init.Minimal) !Options {
    var args = std.process.Args.Iterator.init(init.args);
    std.debug.assert(args.skip());
    var options = Options{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--include-long")) {
            options.include_long = true;
        } else if (std.mem.eql(u8, arg, "--include-one-core")) {
            options.include_one_core = true;
        } else if (std.mem.eql(u8, arg, "--auto-only")) {
            options.auto_only = true;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            options.filter = args.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--label-suffix")) {
            options.label_suffix = args.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--tlzig-only")) {
            options.tlzig_only = true;
        } else if (std.mem.eql(u8, arg, "--skip-prefer-generated")) {
            options.skip_prefer_generated = true;
        } else if (std.mem.eql(u8, arg, "--tlc-baseline-prefer-generated")) {
            options.tlc_baseline_prefer_generated = true;
        } else if (std.mem.eql(u8, arg, "--write-tlzig-baseline")) {
            options.write_tlzig_baseline = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.InvalidArgs;
        } else if (options.filter == null) {
            options.filter = arg;
        } else {
            return error.InvalidArgs;
        }
    }
    return options;
}

fn filter_matches(spec: Spec, optional_filter: ?[]const u8) bool {
    const needle = optional_filter orelse return false;
    if (filter_is_known_label(needle)) {
        return filter_label_matches(spec, optional_filter);
    }
    return std.mem.indexOf(u8, spec.tla, needle) != null or
        std.mem.indexOf(u8, spec.cfg, needle) != null;
}

fn filter_is_known_label(needle: []const u8) bool {
    for (specs) |spec| {
        const label = spec.label orelse continue;
        if (std.mem.eql(u8, label, needle)) return true;
    }
    return false;
}

fn filter_label_matches(spec: Spec, optional_filter: ?[]const u8) bool {
    const needle = optional_filter orelse return false;
    const label = spec.label orelse return false;
    return std.mem.eql(u8, label, needle);
}

fn run_comparison(
    allocator: std.mem.Allocator,
    io: std.Io,
    java_cp: []const u8,
    spec: Spec,
    run_one_core: bool,
    label_suffix: []const u8,
    tlzig_only: bool,
    write_baseline: bool,
) !void {
    const cpu_count = tlzig.platform.auto_worker_count();
    const tlzig_one: ?RunResult = if (run_one_core)
        try run_tlzig_internal(
            allocator,
            io,
            spec,
            1,
            true,
        )
    else
        null;
    defer if (tlzig_one) |result| result.deinit(allocator);
    const tlzig_auto = try run_tlzig_internal(
        allocator,
        io,
        spec,
        cpu_count,
        true,
    );
    defer tlzig_auto.deinit(allocator);
    const spec_java_cp = spec.java_classpath orelse java_cp;
    const tlc_one: ?RunResult = if (run_one_core and !tlzig_only)
        try run_tlc(allocator, io, spec_java_cp, spec, "1")
    else
        null;
    defer if (tlc_one) |result| result.deinit(allocator);
    const tlc_auto: ?RunResult = if (!tlzig_only)
        try run_tlc(allocator, io, spec_java_cp, spec, "auto")
    else
        null;
    defer if (tlc_auto) |result| result.deinit(allocator);

    const basename = spec.label orelse std.fs.path.basename(spec.tla);
    const display_name = if (label_suffix.len == 0)
        basename
    else
        try std.mem.concat(allocator, u8, &.{ basename, label_suffix });
    defer if (label_suffix.len != 0) allocator.free(display_name);
    if (tlzig_only and run_one_core) {
        std.debug.print("{s:32} {s:>10} {s:>10} {d:>10.3} {d:>10.3} {s:>18} {d:>9}/{d:<8}\n", .{
            display_name,
            "-",
            "-",
            seconds(tlzig_one.?.elapsed_ms),
            seconds(tlzig_auto.elapsed_ms),
            "-",
            tlzig_auto.generated,
            tlzig_auto.distinct,
        });
    } else if (tlzig_only) {
        std.debug.print("{s:32} {s:>10} {s:>10} {s:>10} {d:>10.3} {s:>18} {d:>9}/{d:<8}\n", .{
            display_name,
            "-",
            "-",
            "-",
            seconds(tlzig_auto.elapsed_ms),
            "-",
            tlzig_auto.generated,
            tlzig_auto.distinct,
        });
    } else if (run_one_core) {
        std.debug.print("{s:32} {d:>10.3} {d:>10.3} {d:>10.3} {d:>10.3} {d:>9}/{d:<8} {d:>9}/{d:<8}\n", .{
            display_name,
            seconds(tlc_one.?.elapsed_ms),
            seconds(tlc_auto.?.elapsed_ms),
            seconds(tlzig_one.?.elapsed_ms),
            seconds(tlzig_auto.elapsed_ms),
            tlc_one.?.generated,
            tlc_one.?.distinct,
            tlzig_one.?.generated,
            tlzig_one.?.distinct,
        });
    } else {
        std.debug.print("{s:32} {s:>10} {d:>10.3} {s:>10} {d:>10.3} {d:>9}/{d:<8} {d:>9}/{d:<8}\n", .{
            display_name,
            "-",
            seconds(tlc_auto.?.elapsed_ms),
            "-",
            seconds(tlzig_auto.elapsed_ms),
            tlc_auto.?.generated,
            tlc_auto.?.distinct,
            tlzig_auto.generated,
            tlzig_auto.distinct,
        });
    }

    if (tlzig_only) {
        if (write_baseline) {
            if (generated_model.generated_count > 0) {
                std.debug.print(
                    "--write-tlzig-baseline requires the interpreted benchmark binary\n",
                    .{},
                );
                return error.InvalidArgs;
            }
            try write_tlzig_baseline(allocator, spec, tlzig_auto);
            return;
        }
        compare_tlzig_baseline(
            allocator,
            spec,
            tlzig_auto,
        ) catch |err| switch (err) {
            error.MissingBaseline => {
                std.debug.print(
                    "  AOT baseline unavailable; tlzig-only result was not cross-checked\n",
                    .{},
                );
            },
            else => return err,
        };
        return;
    }

    const one_core_mismatch = if (run_one_core)
        tlc_one.?.outcome != tlzig_one.?.outcome or
            tlc_one.?.outcome != tlc_auto.?.outcome
    else
        false;
    const expected_distinct_mismatch = if (spec.expected_distinct_tolerance) |tolerance|
        !distinct_within_tolerance(
            tlc_auto.?.distinct,
            tlzig_auto.distinct,
            tolerance,
        ) or (run_one_core and !distinct_within_tolerance(
            tlc_one.?.distinct,
            tlzig_one.?.distinct,
            tolerance,
        ))
    else
        false;
    const mismatch = one_core_mismatch or
        tlc_auto.?.outcome != tlzig_auto.outcome or
        (if (spec.expected_violation)
            expected_distinct_mismatch
        else
            (spec.compare_generated and
                ((run_one_core and
                    (tlc_one.?.generated != tlc_auto.?.generated or
                        tlc_one.?.generated != tlzig_one.?.generated)) or
                    tlc_auto.?.generated != tlzig_auto.generated)) or
                (spec.compare_distinct and
                    ((run_one_core and
                        (tlc_one.?.distinct != tlc_auto.?.distinct or
                            tlc_one.?.distinct != tlzig_one.?.distinct)) or
                        tlc_auto.?.distinct != tlzig_auto.distinct)));
    if (mismatch) {
        if (run_one_core) {
            std.debug.print(
                "  STATE MISMATCH: TLC-1={d}/{d}/{s} TLC-auto={d}/{d}/{s} " ++
                    "tlzig-1={d}/{d}/{s} tlzig-auto={d}/{d}/{s}\n",
                .{
                    tlc_one.?.generated,
                    tlc_one.?.distinct,
                    @tagName(tlc_one.?.outcome),
                    tlc_auto.?.generated,
                    tlc_auto.?.distinct,
                    @tagName(tlc_auto.?.outcome),
                    tlzig_one.?.generated,
                    tlzig_one.?.distinct,
                    @tagName(tlzig_one.?.outcome),
                    tlzig_auto.generated,
                    tlzig_auto.distinct,
                    @tagName(tlzig_auto.outcome),
                },
            );
        } else {
            std.debug.print(
                "  STATE MISMATCH: TLC-auto={d}/{d}/{s} tlzig-auto={d}/{d}/{s}\n",
                .{
                    tlc_auto.?.generated,
                    tlc_auto.?.distinct,
                    @tagName(tlc_auto.?.outcome),
                    tlzig_auto.generated,
                    tlzig_auto.distinct,
                    @tagName(tlzig_auto.outcome),
                },
            );
        }
        return error.StateMismatch;
    }

    if (generated_model.generated_count == 0) {
        try write_tlzig_baseline(allocator, spec, tlzig_auto);
    }
}

fn run_tlc_baseline(
    allocator: std.mem.Allocator,
    io: std.Io,
    java_cp: []const u8,
    spec: Spec,
) !void {
    const spec_java_cp = spec.java_classpath orelse java_cp;
    const result = try run_tlc(allocator, io, spec_java_cp, spec, "auto");
    defer result.deinit(allocator);
    const display_name = spec.label orelse std.fs.path.basename(spec.tla);
    std.debug.print(
        "{s:32} {s:>10} {d:>10.3} {s:>10} {s:>10} {d:>9}/{d:<8} {s:>18}\n",
        .{
            display_name,
            "-",
            seconds(result.elapsed_ms),
            "-",
            "-",
            result.generated,
            result.distinct,
            "-",
        },
    );
    try write_tlzig_baseline(allocator, spec, result);
}

fn distinct_within_tolerance(
    expected: u64,
    actual: u64,
    tolerance: u64,
) bool {
    const delta = if (expected >= actual)
        expected - actual
    else
        actual - expected;
    return delta <= tolerance;
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

const BaselineResult = struct {
    generated: u64,
    distinct: u64,
    outcome: Outcome,
};

fn compare_tlzig_baseline(
    allocator: std.mem.Allocator,
    spec: Spec,
    actual: RunResult,
) !void {
    const baseline = try read_tlzig_baseline(allocator, spec);
    const mismatch = baseline.outcome != actual.outcome or
        (!spec.expected_violation and
            spec.compare_generated and
            baseline.generated != actual.generated) or
        (if (spec.expected_distinct_tolerance) |tolerance|
            !distinct_within_tolerance(
                baseline.distinct,
                actual.distinct,
                tolerance,
            )
        else
            !spec.expected_violation and
                spec.compare_distinct and
                !distinct_within_tolerance(
                    baseline.distinct,
                    actual.distinct,
                    spec.distinct_tolerance,
                ));
    if (!mismatch) return;

    std.debug.print(
        "  AOT MISMATCH: tlzig-baseline={d}/{d}/{s} tlzig-aot={d}/{d}/{s}\n",
        .{
            baseline.generated,
            baseline.distinct,
            @tagName(baseline.outcome),
            actual.generated,
            actual.distinct,
            @tagName(actual.outcome),
        },
    );
    return error.StateMismatch;
}

fn write_tlzig_baseline(
    allocator: std.mem.Allocator,
    spec: Spec,
    result: RunResult,
) !void {
    const path = try tlzig_baseline_path(allocator, spec);
    defer allocator.free(path);
    const contents = try std.fmt.allocPrint(
        allocator,
        "{d} {d} {s}\n",
        .{ result.generated, result.distinct, @tagName(result.outcome) },
    );
    defer allocator.free(contents);
    try write_file(path, contents);
}

fn read_tlzig_baseline(
    allocator: std.mem.Allocator,
    spec: Spec,
) !BaselineResult {
    const path = try tlzig_baseline_path(allocator, spec);
    defer allocator.free(path);
    var arena = try Arena.init(4096);
    defer arena.deinit();
    const contents = read_file(&arena, path) catch |err| {
        std.debug.print(
            "missing tlzig baseline for AOT benchmark {s}: {any}\n",
            .{ spec.label orelse spec.tla, err },
        );
        return error.MissingBaseline;
    };
    var tokens = std.mem.tokenizeAny(u8, contents, " \t\r\n");
    const generated_text = tokens.next() orelse return error.InvalidBaseline;
    const distinct_text = tokens.next() orelse return error.InvalidBaseline;
    const outcome_text = tokens.next() orelse return error.InvalidBaseline;
    const generated = try std.fmt.parseInt(u64, generated_text, 10);
    const distinct = try std.fmt.parseInt(u64, distinct_text, 10);
    const outcome = parse_outcome_tag(outcome_text) orelse return error.InvalidBaseline;
    return .{
        .generated = generated,
        .distinct = distinct,
        .outcome = outcome,
    };
}

fn parse_outcome_tag(tag: []const u8) ?Outcome {
    if (std.mem.eql(u8, tag, "completed")) return .completed;
    if (std.mem.eql(u8, tag, "violation")) return .violation;
    if (std.mem.eql(u8, tag, "deadlock")) return .deadlock;
    return null;
}

fn tlzig_baseline_path(
    allocator: std.mem.Allocator,
    spec: Spec,
) ![]const u8 {
    var hasher = std.hash.Wyhash.init(0x4245_4e43_484d_4152);
    benchmark_hash_bytes(&hasher, spec.tla);
    benchmark_hash_bytes(&hasher, spec.cfg);
    if (spec.label) |label| benchmark_hash_bytes(&hasher, label);
    return try std.fmt.allocPrint(
        allocator,
        "benchmark_results/tlzig_auto_{x}.txt",
        .{hasher.final()},
    );
}

fn benchmark_hash_bytes(
    hasher: *std.hash.Wyhash,
    bytes: []const u8,
) void {
    const len: u64 = bytes.len;
    hasher.update(std.mem.asBytes(&len));
    hasher.update(bytes);
}

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
    use_generated: bool,
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
    var module = loader.load(spec.tla) catch |err| {
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
    module.config_replacements = try config.build_codegen_replacements(
        &arena,
        module,
        cfg,
    );

    const override_ctx = overrides.OverrideContext{
        .max_seq_len = 5,
        .max_nat = spec.max_nat,
        .min_int = spec.min_int,
        .max_int = spec.max_int,
    };

    const eval_value_cap: u32 = 1_048_576;
    const eval_string_cap: u32 = 65_536;
    const state_value_cap = spec.state_value_cap orelse cap_u32(@min(
        @max(
            @as(u64, spec.max_states) * spec.state_values_per_state,
            1_000_000,
        ),
        192_000_000,
    ));
    std.debug.assert(state_value_cap >= 1_000_000);
    const state_string_cap = cap_u32(@min(
        @max(@as(u64, spec.max_states) * 4, 500_000),
        8_000_000,
    ));

    const generated_model_matches =
        use_generated and generated_matches(module, cfg);
    const generated: []const generated_runtime.Operator =
        if (generated_model_matches)
            &generated_model.operators
        else
            &.{};
    const generated_expressions: []const generated_runtime.Expression =
        if (generated_model_matches)
            &generated_model.expressions
        else
            &.{};
    var ch = checker.Checker.init_generated_with_resource_limits(
        &arena,
        module,
        cfg,
        spec.max_states,
        @min(spec.max_states, spec.max_successors),
        spec.max_graph_edges,
        eval_value_cap,
        eval_string_cap,
        state_value_cap,
        state_string_cap,
        16 * 1024 * 1024,
        override_ctx,
        worker_count,
        generated,
        generated_expressions,
    ) catch |err| {
        std.debug.print("failed to initialize checker for {s}: {any}\n", .{ spec.tla, err });
        return error.CheckFailed;
    };
    defer ch.deinit();
    ch.set_scratch_growable(spec.scratch_growable);
    ch.set_diagnostics(std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null);

    const result = ch.check() catch |err| {
        const elapsed = elapsed_ms(io, start);
        const distinct = ch.distinct;
        if (err == error.InvariantViolated or
            err == error.PropertyViolated or
            err == error.Deadlock)
        {
            const output = try std.fmt.allocPrint(
                allocator,
                "generated={d} distinct={d} error={any}",
                .{ ch.successor_attempts, distinct, err },
            );
            return RunResult{
                .elapsed_ms = elapsed,
                .generated = ch.successor_attempts,
                .distinct = distinct,
                .outcome = if (err == error.Deadlock)
                    .deadlock
                else
                    .violation,
                .output = output,
            };
        }
        std.debug.print(
            "checking failed for {s}: {any} -- generated={d} distinct={d} queued={d}",
            .{
                spec.tla,
                err,
                ch.successor_attempts,
                distinct,
                ch.queue.len(),
            },
        );
        if (ch.evaluator.err_ctx.context) |context| {
            std.debug.print(
                " -- context: {s} {s}",
                .{ context, ch.evaluator.err_ctx.detail orelse "" },
            );
        }
        std.debug.print("\n", .{});
        if (std.c.getenv("TLZIG_BENCH_DIAGNOSTICS") != null) {
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
        }
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

fn generated_matches(module: ast.Module, cfg: config.Config) bool {
    if (generated_model.generated_count == 0 or
        !std.mem.eql(u8, generated_model.module_name, module.name))
    {
        return false;
    }
    if (generated_model.config_replacements_hash !=
        config.codegen_replacements_hash(module.config_replacements))
    {
        return false;
    }
    if (!generated_root_covered(cfg.spec_name)) return false;
    if (!generated_root_covered(cfg.init_name)) return false;
    if (!generated_root_covered(cfg.next_name)) return false;
    if (!generated_root_covered(cfg.symmetry_name)) return false;
    if (!generated_root_covered(cfg.view_name)) return false;
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

fn run_tlc(
    allocator: std.mem.Allocator,
    io: std.Io,
    java_cp: []const u8,
    spec: Spec,
    workers: []const u8,
) !RunResult {
    const classpath = try std.mem.concat(allocator, u8, &.{ java_cp, ":specs/modules" });
    defer allocator.free(classpath);
    const metadir_nonce: u64 = @bitCast(
        std.Io.Clock.Timestamp.now(io, .real).raw.toMicroseconds(),
    );
    const metadir_hash = std.hash.Wyhash.hash(metadir_nonce, spec.cfg);
    const metadir = try std.fmt.allocPrint(
        allocator,
        "benchmark_results/tlc_meta-{x}-{s}",
        .{ metadir_hash, workers },
    );
    defer allocator.free(metadir);
    const stdout_path = try std.fmt.allocPrint(
        allocator,
        "benchmark_results/tlc_output-{x}-{s}.log",
        .{ metadir_hash, workers },
    );
    defer allocator.free(stdout_path);
    const stderr_path = try std.fmt.allocPrint(
        allocator,
        "benchmark_results/tlc_output-{x}-{s}.err",
        .{ metadir_hash, workers },
    );
    defer allocator.free(stderr_path);
    defer std.Io.Dir.cwd().deleteTree(io, metadir) catch |err| {
        std.debug.print("failed to remove TLC metadata {s}: {any}\n", .{
            metadir,
            err,
        });
    };
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "java");
    if (std.mem.eql(u8, workers, "1")) {
        try argv.appendSlice(allocator, &.{
            "-XX:ActiveProcessorCount=1",
            "-XX:+UseSerialGC",
        });
    } else {
        try argv.append(allocator, "-XX:+UseParallelGC");
    }
    if (spec.java_heap) |java_heap| {
        try argv.append(allocator, java_heap);
    }
    try argv.appendSlice(allocator, &.{
        "-cp",
        classpath,
        "-Dtlc2.tool.impl.Tool.cdot=true",
        "tlc2.TLC",
        "-metadir",
        metadir,
        "-workers",
        workers,
        "-cleanup",
        "-lncheck",
        "final",
        "-config",
        spec.cfg,
        spec.tla,
    });

    const start = std.Io.Clock.Timestamp.now(io, .real);
    std.debug.print("  TLC output: {s}\n", .{stdout_path});
    const term = term: {
        const cwd = std.Io.Dir.cwd();
        var stdout_file = try cwd.createFile(io, stdout_path, .{});
        defer stdout_file.close(io);
        var stderr_file = try cwd.createFile(io, stderr_path, .{});
        defer stderr_file.close(io);
        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .{ .file = stdout_file },
            .stderr = .{ .file = stderr_file },
        });
        defer child.kill(io);
        break :term try child.wait(io);
    };
    const elapsed = elapsed_ms(io, start);
    const stdout = try std.Io.Dir.cwd().readFileAlloc(
        io,
        stdout_path,
        allocator,
        .limited(64 * 1024 * 1024),
    );
    errdefer allocator.free(stdout);
    const stderr = try std.Io.Dir.cwd().readFileAlloc(
        io,
        stderr_path,
        allocator,
        .limited(64 * 1024 * 1024),
    );
    defer allocator.free(stderr);
    const result: std.process.RunResult = .{
        .term = term,
        .stdout = stdout,
        .stderr = stderr,
    };

    const generated = parse_before_keyword(result.stdout, " states generated") orelse {
        print_tlc_failure(spec, workers, result);
        return error.TlcFailed;
    };
    const distinct = parse_before_keyword(result.stdout, " distinct states found") orelse {
        print_tlc_failure(spec, workers, result);
        return error.TlcFailed;
    };
    const outcome = parse_tlc_outcome(result.stdout, result.term) orelse {
        print_tlc_failure(spec, workers, result);
        return error.TlcFailed;
    };
    return RunResult{
        .elapsed_ms = elapsed,
        .generated = generated,
        .distinct = distinct,
        .outcome = outcome,
        .output = result.stdout,
    };
}

fn print_tlc_failure(
    spec: Spec,
    workers: []const u8,
    result: std.process.RunResult,
) void {
    std.debug.print(
        "TLC failed for {s} workers={s} term={any}\nstdout:\n{s}\nstderr:\n{s}\n",
        .{ spec.tla, workers, result.term, result.stdout, result.stderr },
    );
}

fn parse_tlc_outcome(
    output: []const u8,
    term: std.process.Child.Term,
) ?Outcome {
    if (std.mem.indexOf(u8, output, "Deadlock reached") != null) {
        return .deadlock;
    }
    if (term.success()) return .completed;
    const violation_markers = [_][]const u8{
        " is violated.",
        " is violated by the initial state",
        " was violated.",
        " were violated.",
        "The first argument of Assert evaluated to FALSE",
    };
    for (violation_markers) |marker| {
        if (std.mem.indexOf(u8, output, marker) != null) return .violation;
    }
    return null;
}

test "TLC outcome classification rejects non-semantic process failures" {
    try std.testing.expectEqual(
        Outcome.completed,
        parse_tlc_outcome("Model checking completed.", .{ .exited = 0 }).?,
    );
    try std.testing.expectEqual(
        Outcome.deadlock,
        parse_tlc_outcome("Error: Deadlock reached.", .{ .exited = 12 }).?,
    );
    try std.testing.expectEqual(
        Outcome.violation,
        parse_tlc_outcome(
            "Error: Temporal property Live was violated.",
            .{ .exited = 13 },
        ).?,
    );
    try std.testing.expectEqual(
        Outcome.violation,
        parse_tlc_outcome(
            "Error: Invariant TypeOK is violated.",
            .{ .exited = 12 },
        ).?,
    );
    try std.testing.expectEqual(
        @as(?Outcome, null),
        parse_tlc_outcome(
            "TLC threw an unexpected exception. OutOfMemoryError",
            .{ .exited = 255 },
        ),
    );
    try std.testing.expectEqual(
        @as(?Outcome, null),
        parse_tlc_outcome("", .{ .signal = .KILL }),
    );
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
