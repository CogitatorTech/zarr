//! Differential IPC test against nanoarrow.
//!
//! nanoarrow is the Arrow project's minimal C implementation, vendored as the
//! external/nanoarrow submodule and compiled by the `interop-nanoarrow` build
//! step together with the C bridge in nanoarrow_shim.c.
//!
//! Two checks run:
//!
//! 1. Acceptance agreement: a sample batch written by Zarr must round-trip
//!    through nanoarrow's IPC reader and writer, and Zarr must read the
//!    nanoarrow-written stream back to the same schema and values. A failure
//!    here fails the run.
//! 2. Rejection agreement over the arrow-testing fuzz corpus: both libraries
//!    read each input, and the verdicts are compared. Disagreements are
//!    reported as findings, not failures, since the two libraries support
//!    different feature sets; a crash or a leak still fails the run.
//!
//! Run with `make interop-nanoarrow` from the repository root.

const std = @import("std");
const zarr = @import("zarr");

extern fn zarr_na_try_read_stream(data: [*]const u8, len: i64) c_int;
extern fn zarr_na_roundtrip_stream(data: [*]const u8, len: i64, out: *[*]u8, out_len: *i64) c_int;
extern fn zarr_na_free(ptr: [*]u8) void;

const corpus_dirs = [_][]const u8{
    "external/arrow-testing/data/arrow-ipc-stream",
    "external/arrow-testing/data/arrow-ipc-tensor-stream",
};

const max_file_size = 64 * 1024 * 1024;

const SampleColumns = zarr.StructArray(&.{
    zarr.PrimitiveArray(i32),
    zarr.BooleanArray,
    zarr.Utf8Array,
    zarr.LargeUtf8Array,
    zarr.ListArray(zarr.PrimitiveArray(i64)),
});

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    var failed = false;
    {
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        acceptanceCheck(allocator) catch |err| {
            std.debug.print("FAIL: acceptance check: {t}\n", .{err});
            failed = true;
        };
        try corpusAgreement(allocator, io);
    }

    if (gpa.deinit() == .leak) {
        std.debug.print("FAIL: the run leaked memory\n", .{});
        return 1;
    }
    return if (failed) 1 else 0;
}

/// Writes the sample batch as a stream, has nanoarrow read and rewrite it,
/// and reads the nanoarrow-written bytes back, expecting the same schema and
/// values.
fn acceptanceCheck(allocator: std.mem.Allocator) !void {
    var schema = try buildSampleSchema(allocator);
    defer schema.deinit(allocator);
    var data = try buildSampleData(allocator);
    defer data.deinit();

    var writer = try zarr.ipc_stream.StreamWriter.init(allocator, schema);
    defer writer.deinit();
    try writer.writeBatch(data);
    const zarr_bytes = try writer.finish();
    defer allocator.free(zarr_bytes);

    var na_out: [*]u8 = undefined;
    var na_len: i64 = 0;
    if (zarr_na_roundtrip_stream(zarr_bytes.ptr, @intCast(zarr_bytes.len), &na_out, &na_len) != 0) {
        return error.NanoarrowRejectedZarrStream;
    }
    defer zarr_na_free(na_out);
    const na_bytes = na_out[0..@intCast(na_len)];

    var reader = try zarr.ipc_stream.StreamReader.init(allocator, na_bytes);
    defer reader.deinit();
    if (!schema.equals(reader.schema)) return error.SchemaMismatch;

    var back = (try reader.next()) orelse return error.MissingBatch;
    defer back.deinit();
    try verifySampleData(back);
    if (try reader.next() != null) return error.ExtraBatch;

    std.debug.print(
        "PASS: Zarr stream -> nanoarrow read and rewrite -> Zarr read ({d} bytes out, {d} bytes back)\n",
        .{ zarr_bytes.len, na_bytes.len },
    );
}

fn buildSampleSchema(allocator: std.mem.Allocator) !zarr.Schema {
    var list_type = try zarr.DataType.initList(allocator, .int64);
    defer list_type.deinit(allocator);

    var fields: [5]zarr.Field = undefined;
    var built: usize = 0;
    defer for (fields[0..built]) |*f| f.deinit(allocator);
    fields[0] = try zarr.Field.init(allocator, "id", .int32, false);
    built += 1;
    fields[1] = try zarr.Field.init(allocator, "flag", .boolean, true);
    built += 1;
    fields[2] = try zarr.Field.init(allocator, "name", .utf8, true);
    built += 1;
    fields[3] = try zarr.Field.init(allocator, "bio", .large_utf8, false);
    built += 1;
    fields[4] = try zarr.Field.init(allocator, "tags", list_type, true);
    built += 1;
    return zarr.Schema.init(allocator, fields[0..]);
}

/// Rows: {1, true, "a", "x", [10, 20]}, {2, null, null, "yy", []},
/// {3, false, "ccc", "zzz", null}.
fn buildSampleData(allocator: std.mem.Allocator) !zarr.ArrayData {
    var builder = SampleColumns.Builder.init(allocator);
    defer builder.deinit();

    try builder.children[0].append(1);
    try builder.children[1].append(true);
    try builder.children[2].append("a");
    try builder.children[3].append("x");
    try builder.children[4].values.append(10);
    try builder.children[4].values.append(20);
    try builder.children[4].appendList();
    try builder.append();

    try builder.children[0].append(2);
    try builder.children[1].appendNull();
    try builder.children[2].appendNull();
    try builder.children[3].append("yy");
    try builder.children[4].appendList();
    try builder.append();

    try builder.children[0].append(3);
    try builder.children[1].append(false);
    try builder.children[2].append("ccc");
    try builder.children[3].append("zzz");
    try builder.children[4].appendNull();
    try builder.append();

    var columns = try builder.finish();
    defer columns.deinit();
    return columns.toData(allocator);
}

fn verifySampleData(data: zarr.ArrayData) !void {
    if (data.length != 3) return error.ValueMismatch;

    const ids = data.child(0);
    if (!std.mem.eql(i32, ids.values(i32), &.{ 1, 2, 3 })) return error.ValueMismatch;

    const flags = data.child(1);
    if (!flags.isValid(0) or flags.isValid(1) or !flags.isValid(2)) return error.ValueMismatch;
    const flag_bits = flags.buffers[1].?.data[0];
    if (flag_bits & 1 == 0 or flag_bits & 4 != 0) return error.ValueMismatch;

    const names = data.child(2);
    if (!std.mem.eql(u8, names.valueBytes(0), "a")) return error.ValueMismatch;
    if (names.isValid(1)) return error.ValueMismatch;
    if (!std.mem.eql(u8, names.valueBytes(2), "ccc")) return error.ValueMismatch;

    const bios = data.child(3);
    if (!std.mem.eql(u8, bios.valueBytes(0), "x")) return error.ValueMismatch;
    if (!std.mem.eql(u8, bios.valueBytes(1), "yy")) return error.ValueMismatch;
    if (!std.mem.eql(u8, bios.valueBytes(2), "zzz")) return error.ValueMismatch;

    const tags = data.child(4);
    if (!std.mem.eql(i32, tags.offsets(i32), &.{ 0, 2, 2, 2 })) return error.ValueMismatch;
    if (tags.isValid(2)) return error.ValueMismatch;
    if (!std.mem.eql(i64, tags.child(0).values(i64), &.{ 10, 20 })) return error.ValueMismatch;
}

/// Reads every corpus stream with both libraries and reports verdict
/// disagreements. These are findings to look at, not failures: the two
/// libraries support different type and message subsets.
fn corpusAgreement(allocator: std.mem.Allocator, io: std.Io) !void {
    var agree: usize = 0;
    var disagree: usize = 0;
    var found_any_dir = false;

    for (corpus_dirs) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        found_any_dir = true;

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, ".md")) continue;

            const bytes = try dir.readFileAlloc(io, entry.name, allocator, .limited(max_file_size));
            defer allocator.free(bytes);

            const zarr_accepts = zarrReadsStream(allocator, bytes);
            const na_accepts = zarr_na_try_read_stream(bytes.ptr, @intCast(bytes.len)) == 0;
            if (zarr_accepts == na_accepts) {
                agree += 1;
            } else {
                disagree += 1;
                std.debug.print("DISAGREE: {s}/{s}: zarr {s}, nanoarrow {s}\n", .{
                    path,
                    entry.name,
                    verdict(zarr_accepts),
                    verdict(na_accepts),
                });
            }
        }
    }

    if (!found_any_dir) {
        std.debug.print("SKIP: arrow-testing corpus not found; rejection agreement not checked\n", .{});
        return;
    }
    std.debug.print("OK: corpus verdicts agreed on {d} of {d} inputs\n", .{ agree, agree + disagree });
}

fn verdict(accepts: bool) []const u8 {
    return if (accepts) "accepts" else "rejects";
}

fn zarrReadsStream(allocator: std.mem.Allocator, bytes: []const u8) bool {
    var reader = zarr.ipc_stream.StreamReader.init(allocator, bytes) catch return false;
    defer reader.deinit();
    while (reader.next() catch return false) |decoded| {
        var data = decoded;
        data.deinit();
    }
    return true;
}
