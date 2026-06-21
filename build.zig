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
    if (b.option(
        []const u8,
        "benchmark-filter",
        "Run only benchmark specs whose path contains this substring",
    )) |filter| {
        run_bench.addArg(filter);
    }
    b.step("benchmark", "Benchmark tlzig vs Java TLC").dependOn(&run_bench.step);

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
