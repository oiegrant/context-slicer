const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_adapter = b.addSystemCommand(&.{
        "mvn", "package", "-DskipTests", "-q",
        "--file", "../context-adapter-java/pom.xml",
    });
    const build_agent = b.addSystemCommand(&.{
        "mvn", "package", "-DskipTests", "-q",
        "--file", "../context-agent-java/pom.xml",
    });

    const exe = b.addExecutable(.{
        .name = "context-slicer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Module that embeds the JAR bytes; its root lives at the repo root so
    // @embedFile paths can reach sibling directories (context-adapter-java/, etc.)
    const embedded_jars_module = b.createModule(.{
        .root_source_file = b.path("../embedded_jars.zig"),
    });
    exe.root_module.addImport("embedded_jars", embedded_jars_module);

    exe.step.dependOn(&build_adapter.step);
    exe.step.dependOn(&build_agent.step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run context-slicer");
    run_step.dependOn(&run_cmd.step);

    // Single test binary rooted at main.zig so all subsystems can cross-import.
    // main.zig imports every module transitively, pulling in their test blocks.
    const test_step = b.step("test", "Run all unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("embedded_jars", embedded_jars_module);
    const run_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_tests.step);
}
