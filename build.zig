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

    // Fuzz-regression corpus check over the optional arrow-testing submodule,
    // run on demand via `zig build corpus-check`. The tool skips and exits
    // zero when the submodule is not initialized.
    const corpus_module = b.createModule(.{
        .root_source_file = b.path("tools/ipc_corpus_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    corpus_module.addImport("zarr", zarr_module);
    const corpus_exe = b.addExecutable(.{
        .name = "ipc-corpus-check",
        .root_module = corpus_module,
    });
    const run_corpus = b.addRunArtifact(corpus_exe);
    run_corpus.setCwd(b.path("."));
    const corpus_step = b.step("corpus-check", "Run the arrow-testing IPC fuzz corpus through the IPC readers");
    corpus_step.dependOn(&run_corpus.step);

    // Differential IPC test against nanoarrow, run on demand via
    // `zig build interop-nanoarrow`. Compiles the vendored nanoarrow sources
    // from the external/nanoarrow submodule with Zig's C compiler, so no
    // system packages are needed. The step fails to build when the submodule
    // is absent; `make interop-nanoarrow` guards for that and skips.
    const nanoarrow_module = b.createModule(.{
        .root_source_file = b.path("tools/nanoarrow_differential.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nanoarrow_module.addImport("zarr", zarr_module);
    nanoarrow_module.addIncludePath(b.path("tools/nanoarrow_include"));
    nanoarrow_module.addIncludePath(b.path("external/nanoarrow/src"));
    nanoarrow_module.addIncludePath(b.path("external/nanoarrow/thirdparty/flatcc/include"));
    nanoarrow_module.addCSourceFiles(.{
        .files = &.{
            "tools/nanoarrow_shim.c",
            "external/nanoarrow/src/nanoarrow/common/array.c",
            "external/nanoarrow/src/nanoarrow/common/array_stream.c",
            "external/nanoarrow/src/nanoarrow/common/schema.c",
            "external/nanoarrow/src/nanoarrow/common/utils.c",
            "external/nanoarrow/src/nanoarrow/ipc/codecs.c",
            "external/nanoarrow/src/nanoarrow/ipc/decoder.c",
            "external/nanoarrow/src/nanoarrow/ipc/encoder.c",
            "external/nanoarrow/src/nanoarrow/ipc/reader.c",
            "external/nanoarrow/src/nanoarrow/ipc/writer.c",
            "external/nanoarrow/thirdparty/flatcc/src/runtime/builder.c",
            "external/nanoarrow/thirdparty/flatcc/src/runtime/emitter.c",
            "external/nanoarrow/thirdparty/flatcc/src/runtime/refmap.c",
            "external/nanoarrow/thirdparty/flatcc/src/runtime/verifier.c",
        },
    });
    const nanoarrow_exe = b.addExecutable(.{
        .name = "nanoarrow-differential",
        .root_module = nanoarrow_module,
    });
    const run_nanoarrow = b.addRunArtifact(nanoarrow_exe);
    run_nanoarrow.setCwd(b.path("."));
    const nanoarrow_step = b.step("interop-nanoarrow", "Run the differential IPC test against nanoarrow");
    nanoarrow_step.dependOn(&run_nanoarrow.step);

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
