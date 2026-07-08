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

    // C Data Interface shared library, built on demand via `zig build c-api`.
    // Kept out of the default build so the core stays free of a libc link.
    const c_api_module = b.createModule(.{
        .root_source_file = b.path("src/zarr_c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api_module.addImport("zarr", zarr_module);
    const c_api_lib = b.addLibrary(.{
        .name = "zarr_c",
        .linkage = .dynamic,
        .root_module = c_api_module,
    });
    const c_api_step = b.step("c-api", "Build the C Data Interface shared library");
    c_api_step.dependOn(&b.addInstallArtifact(c_api_lib, .{}).step);

    // In-process round-trip test of the C entry points, runnable without an
    // external Arrow implementation.
    const c_api_tests = b.addTest(.{ .root_module = c_api_module });
    const run_c_api_tests = b.addRunArtifact(c_api_tests);
    const c_api_test_step = b.step("test-c-api", "Run C Data Interface library tests");
    c_api_test_step.dependOn(&run_c_api_tests.step);

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
