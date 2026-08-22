//! Runs the arrow-testing fuzz-regression corpus through the IPC readers.
//!
//! The corpus holds ClusterFuzz test cases that crashed other Arrow
//! implementations. The check is that every file either decodes or returns an
//! error: a crash aborts the process and fails the build step, and a leak on
//! any path fails the run at exit. Decoding is not expected to succeed; most
//! of the corpus is malformed on purpose.
//!
//! Run with `make corpus` or `zig build corpus-check` from the repository
//! root. When the arrow-testing submodule is not initialized, the check
//! skips and exits zero, so no workflow gains a hard dependency on it.

const std = @import("std");
const zarr = @import("zarr");

const corpus_dirs = [_]struct { path: []const u8, format: Format }{
    .{ .path = "external/arrow-testing/data/arrow-ipc-stream", .format = .stream },
    .{ .path = "external/arrow-testing/data/arrow-ipc-tensor-stream", .format = .stream },
    .{ .path = "external/arrow-testing/data/arrow-ipc-file", .format = .file },
};

const Format = enum { stream, file };

const max_file_size = 64 * 1024 * 1024;

const Totals = struct {
    decoded: usize = 0,
    rejected: usize = 0,
    skipped_dirs: usize = 0,
};

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    var totals: Totals = .{};
    {
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        for (corpus_dirs) |corpus| {
            try runDir(allocator, io, corpus.path, corpus.format, &totals);
        }
    }

    if (totals.skipped_dirs == corpus_dirs.len) {
        std.debug.print(
            "SKIP: arrow-testing corpus not found; run `git submodule update --init` to enable this check\n",
            .{},
        );
        return 0;
    }

    std.debug.print(
        "OK: corpus survived without a crash ({d} decoded, {d} rejected with errors)\n",
        .{ totals.decoded, totals.rejected },
    );

    if (gpa.deinit() == .leak) {
        std.debug.print("FAIL: the run leaked memory\n", .{});
        return 1;
    }
    return 0;
}

fn runDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    format: Format,
    totals: *Totals,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            totals.skipped_dirs += 1;
            return;
        },
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".md")) continue;

        const bytes = try dir.readFileAlloc(io, entry.name, allocator, .limited(max_file_size));
        defer allocator.free(bytes);

        // Name the file before decoding, so a crash identifies its input.
        std.debug.print("{s}/{s}: ", .{ path, entry.name });
        const outcome = switch (format) {
            .stream => checkStream(allocator, bytes),
            .file => checkFile(allocator, bytes),
        };
        switch (outcome) {
            .decoded => {
                totals.decoded += 1;
                std.debug.print("decoded\n", .{});
            },
            .rejected => {
                totals.rejected += 1;
                std.debug.print("rejected\n", .{});
            },
        }
    }
}

const Outcome = enum { decoded, rejected };

fn checkStream(allocator: std.mem.Allocator, bytes: []const u8) Outcome {
    var reader = zarr.ipc_stream.StreamReader.init(allocator, bytes) catch return .rejected;
    defer reader.deinit();
    while (reader.next() catch return .rejected) |decoded| {
        var data = decoded;
        data.deinit();
    }
    return .decoded;
}

fn checkFile(allocator: std.mem.Allocator, bytes: []const u8) Outcome {
    var reader = zarr.ipc_file.FileReader.init(allocator, bytes) catch return .rejected;
    defer reader.deinit();
    for (0..reader.batchCount()) |i| {
        var data = reader.readBatch(i) catch return .rejected;
        data.deinit();
    }
    return .decoded;
}
