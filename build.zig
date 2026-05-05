pub fn build(b: *std.Build) void {
    // Options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module
    const mod = b.addModule("flexible_struct", .{
        .root_source_file = b.path("src/flexible_struct.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Test
    const unit_tests = b.addTest(.{ .root_module = mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Docs
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "flexible_struct",
        .root_module = mod,
    });
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&docs.step);
}

const std = @import("std");
