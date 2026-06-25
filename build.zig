const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zarr_module = b.addModule("zarr", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zarr",
        .linkage = .static,
        .root_module = zarr_module,
    });
    b.installArtifact(lib);

    // Generate API documentation from the library root module (src/lib.zig).
    const docs_step = b.step("docs", "Generate API documentation");
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "api",
    });
    docs_step.dependOn(&install_docs.step);

    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_tests.step);
}
