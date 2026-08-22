//! C-callable entry points for the Arrow C Data Interface.
//!
//! This is the root of the `zarr_c` shared library, kept separate from the
//! `zarr` module so the core stays free of a libc dependency. It exposes a
//! small, fixed surface used to verify Zarr against another Arrow
//! implementation, built around one known sample record batch. For the C Data
//! Interface, one function exports the sample and one imports a batch and
//! checks it equals the sample. For the IPC stream format, one function
//! encodes the sample as a stream and one decodes a stream and checks it
//! holds exactly the sample. Addresses and buffers are passed as integers,
//! which is how cffi and ctypes pass them.
//!
//! The sample batch covers several layout families in one round trip:
//!
//! - `id`: `int32`, `[1, 2, 3]`, non-null (fixed-width primitive).
//! - `flag`: `boolean`, `[true, null, false]` (bit-packed values plus validity).
//! - `name`: `utf8`, `["a", null, "ccc"]` (32-bit-offset variable length).
//! - `bio`: `large_utf8`, `["x", "yy", "zzz"]` (64-bit-offset variable length).
//! - `tags`: `list<int32>`, `[[1, 2], [], [3, 4, 5]]` (nested offsets and child).
//! - `point`: `struct<x: float64 not null, label: utf8>`,
//!   `[{1.5, "a"}, null, {-2.25, null}]` (named fields, a struct-level null,
//!   and a child-level null under a valid row).
//!
//! A timestamp column is left out on purpose: a batch builder always stamps a
//! primitive column with its storage type, so a `timestamp` logical type
//! cannot ride through it.

const std = @import("std");
const zarr = @import("zarr");

const ArrowSchema = zarr.c_data.ArrowSchema;
const ArrowArray = zarr.c_data.ArrowArray;
const PointColumn = zarr.StructArray(&.{ zarr.PrimitiveArray(f64), zarr.Utf8Array });
const SampleBatch = zarr.RecordBatch(&[_]type{
    zarr.PrimitiveArray(i32),
    zarr.BooleanArray,
    zarr.Utf8Array,
    zarr.LargeUtf8Array,
    zarr.ListArray(zarr.PrimitiveArray(i32)),
    PointColumn,
});

/// The allocator backing every export. It is captured in the exported release
/// callbacks, so the consumer's release frees through it. libc is linked for
/// this library, so `c_allocator` is available.
const allocator = std.heap.c_allocator;

const row_count = 3;
const expected_ids = [row_count]i32{ 1, 2, 3 };
const expected_flags = [row_count]?bool{ true, null, false };
const expected_names = [row_count]?[]const u8{ "a", null, "ccc" };
const expected_bios = [row_count][]const u8{ "x", "yy", "zzz" };
const expected_tags = [row_count][]const i32{ &.{ 1, 2 }, &.{}, &.{ 3, 4, 5 } };
const Point = struct { x: f64, label: ?[]const u8 };
const expected_points = [row_count]?Point{ .{ .x = 1.5, .label = "a" }, null, .{ .x = -2.25, .label = null } };

/// Fill the caller-allocated `ArrowSchema` and `ArrowArray` at the given
/// addresses with the sample record batch. Returns 0 on success, 1 on failure.
export fn zarr_export_sample_batch(schema_addr: usize, array_addr: usize) c_int {
    const out_schema: *ArrowSchema = @ptrFromInt(schema_addr);
    const out_array: *ArrowArray = @ptrFromInt(array_addr);
    exportSample(out_schema, out_array) catch return 1;
    return 0;
}

/// Import the `ArrowSchema` and `ArrowArray` at the given addresses, release
/// them, and check the batch equals the sample. Returns 0 on a match, 1 on a
/// mismatch, and 2 when the import itself fails.
export fn zarr_verify_sample_batch(schema_addr: usize, array_addr: usize) c_int {
    const in_schema: *ArrowSchema = @ptrFromInt(schema_addr);
    const in_array: *ArrowArray = @ptrFromInt(array_addr);

    var batch = zarr.c_data.importRecordBatch(SampleBatch, allocator, in_schema, in_array) catch {
        releaseBoth(in_schema, in_array);
        return 2;
    };
    defer batch.deinit();
    // The import copied the data, so hand the foreign structs back now.
    releaseBoth(in_schema, in_array);

    return if (batchMatchesSample(batch)) 0 else 1;
}

/// Encode the sample record batch as an Arrow IPC stream into the caller's
/// buffer. Returns the number of bytes written, or -1 when encoding fails or
/// the buffer is too small.
export fn zarr_encode_sample_stream(out_addr: usize, capacity: usize) isize {
    const out: [*]u8 = @ptrFromInt(out_addr);
    const bytes = encodeSampleStream() catch return -1;
    defer allocator.free(bytes);
    if (bytes.len > capacity) return -1;
    @memcpy(out[0..bytes.len], bytes);
    return @intCast(bytes.len);
}

fn encodeSampleStream() ![]u8 {
    var schema = try buildSchema();
    defer schema.deinit(allocator);
    var batch = try buildBatch(schema);
    defer batch.deinit();
    var data = try batch.toData(allocator);
    defer data.deinit();

    var writer = try zarr.ipc_stream.StreamWriter.init(allocator, schema);
    defer writer.deinit();
    try writer.writeBatch(data);
    return writer.finish();
}

/// Decode an Arrow IPC stream and check it holds exactly the sample: the
/// sample schema, one batch with the sample values, and nothing after it.
/// Returns 0 on a match, 1 on a mismatch, and 2 when decoding fails.
export fn zarr_verify_sample_stream(bytes_addr: usize, len: usize) c_int {
    const bytes = @as([*]const u8, @ptrFromInt(bytes_addr))[0..len];
    const matches = verifySampleStream(bytes) catch return 2;
    return if (matches) 0 else 1;
}

fn verifySampleStream(bytes: []const u8) !bool {
    var expected_schema = try buildSchema();
    defer expected_schema.deinit(allocator);

    var reader = try zarr.ipc_stream.StreamReader.init(allocator, bytes);
    defer reader.deinit();
    if (!expected_schema.equals(reader.schema)) return false;

    var data = (try reader.next()) orelse return false;
    defer data.deinit();
    var batch = try SampleBatch.fromData(allocator, reader.schema, data);
    defer batch.deinit();

    var extra = try reader.next();
    if (extra) |*d| {
        d.deinit();
        return false;
    }
    return batchMatchesSample(batch);
}

/// Encode the sample record batch as an Arrow IPC file into the caller's
/// buffer. Returns the number of bytes written, or -1 when encoding fails or
/// the buffer is too small.
export fn zarr_encode_sample_file(out_addr: usize, capacity: usize) isize {
    const out: [*]u8 = @ptrFromInt(out_addr);
    const bytes = encodeSampleFile() catch return -1;
    defer allocator.free(bytes);
    if (bytes.len > capacity) return -1;
    @memcpy(out[0..bytes.len], bytes);
    return @intCast(bytes.len);
}

fn encodeSampleFile() ![]u8 {
    var schema = try buildSchema();
    defer schema.deinit(allocator);
    var batch = try buildBatch(schema);
    defer batch.deinit();
    var data = try batch.toData(allocator);
    defer data.deinit();

    var writer = try zarr.ipc_file.FileWriter.init(allocator, schema);
    defer writer.deinit();
    try writer.writeBatch(data);
    return writer.finish();
}

/// Open an Arrow IPC file and check it holds exactly the sample: the sample
/// schema and one batch with the sample values. Returns 0 on a match, 1 on a
/// mismatch, and 2 when decoding fails.
export fn zarr_verify_sample_file(bytes_addr: usize, len: usize) c_int {
    const bytes = @as([*]const u8, @ptrFromInt(bytes_addr))[0..len];
    const matches = verifySampleFile(bytes) catch return 2;
    return if (matches) 0 else 1;
}

fn verifySampleFile(bytes: []const u8) !bool {
    var expected_schema = try buildSchema();
    defer expected_schema.deinit(allocator);

    var reader = try zarr.ipc_file.FileReader.init(allocator, bytes);
    defer reader.deinit();
    if (!expected_schema.equals(reader.schema)) return false;
    if (reader.batchCount() != 1) return false;

    var data = try reader.readBatch(0);
    defer data.deinit();
    var batch = try SampleBatch.fromData(allocator, reader.schema, data);
    defer batch.deinit();
    return batchMatchesSample(batch);
}

/// Import the `ArrowSchema` and `ArrowArray` at the given addresses, release
/// them, and check the batch equals rows 1 and 2 of the sample, which is what
/// slicing the sample batch as `[1:3]` produces. Verifies that a producer's
/// non-zero offset is honored on import. Returns 0 on a match, 1 on a
/// mismatch, and 2 when the import itself fails.
export fn zarr_verify_sample_batch_slice(schema_addr: usize, array_addr: usize) c_int {
    const in_schema: *ArrowSchema = @ptrFromInt(schema_addr);
    const in_array: *ArrowArray = @ptrFromInt(array_addr);

    var batch = zarr.c_data.importRecordBatch(SampleBatch, allocator, in_schema, in_array) catch {
        releaseBoth(in_schema, in_array);
        return 2;
    };
    defer batch.deinit();
    releaseBoth(in_schema, in_array);

    return if (batchMatchesSampleRows(batch, 1, 2)) 0 else 1;
}

fn releaseBoth(schema: *ArrowSchema, array: *ArrowArray) void {
    if (array.release) |release| release(array);
    if (schema.release) |release| release(schema);
}

fn exportSample(out_schema: *ArrowSchema, out_array: *ArrowArray) !void {
    var schema = try buildSchema();
    defer schema.deinit(allocator);
    var batch = try buildBatch(schema);
    defer batch.deinit();
    try zarr.c_data.exportRecordBatch(allocator, batch, out_schema, out_array);
}

fn buildSchema() !zarr.Schema {
    var list_type = try zarr.DataType.initList(allocator, .int32);
    defer list_type.deinit(allocator);

    var x = try zarr.Field.init(allocator, "x", .float64, false);
    defer x.deinit(allocator);
    var label = try zarr.Field.init(allocator, "label", .utf8, true);
    defer label.deinit(allocator);
    var point_type = try zarr.DataType.initStructFields(allocator, &.{ x, label });
    defer point_type.deinit(allocator);

    var fields: [6]zarr.Field = undefined;
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
    fields[4] = try zarr.Field.init(allocator, "tags", list_type, false);
    built += 1;
    fields[5] = try zarr.Field.init(allocator, "point", point_type, true);
    built += 1;

    return zarr.Schema.init(allocator, fields[0..]);
}

fn buildBatch(schema: zarr.Schema) !SampleBatch {
    var builder = SampleBatch.Columns.Builder.init(allocator);
    defer builder.deinit();
    for (0..row_count) |i| {
        try builder.children[0].append(expected_ids[i]);
        if (expected_flags[i]) |v| try builder.children[1].append(v) else try builder.children[1].appendNull();
        if (expected_names[i]) |v| try builder.children[2].append(v) else try builder.children[2].appendNull();
        try builder.children[3].append(expected_bios[i]);
        for (expected_tags[i]) |element| try builder.children[4].values.append(element);
        try builder.children[4].appendList();
        if (expected_points[i]) |p| {
            try builder.children[5].children[0].append(p.x);
            if (p.label) |v| try builder.children[5].children[1].append(v) else try builder.children[5].children[1].appendNull();
            try builder.children[5].append();
        } else {
            try builder.children[5].appendNull();
        }
        try builder.append();
    }
    var columns = try builder.finish();
    errdefer columns.deinit();
    return SampleBatch.init(allocator, schema, columns);
}

fn batchMatchesSample(batch: SampleBatch) bool {
    return batchMatchesSampleRows(batch, 0, row_count);
}

/// Whether `batch` holds exactly rows `[start, start + count)` of the sample.
fn batchMatchesSampleRows(batch: SampleBatch, start: usize, count: usize) bool {
    if (batch.numRows() != count) return false;
    const ids = batch.column(0);
    const flags = batch.column(1);
    const names = batch.column(2);
    const bios = batch.column(3);
    const tags = batch.column(4);
    const points = batch.column(5);
    for (0..count) |j| {
        const i = start + j;
        if (ids.get(j) != @as(?i32, expected_ids[i])) return false;
        if (!optBoolEq(flags.get(j), expected_flags[i])) return false;
        if (!optBytesEq(names.get(j), expected_names[i])) return false;
        if (!optBytesEq(bios.get(j), expected_bios[i])) return false;
        if (tags.valueLength(j) != expected_tags[i].len) return false;
        const base = tags.valueOffset(j);
        for (expected_tags[i], 0..) |element, k| {
            if (tags.values.get(base + k) != @as(?i32, element)) return false;
        }
        if (expected_points[i]) |p| {
            if (!points.isValid(j)) return false;
            if (points.field(0).get(j) != @as(?f64, p.x)) return false;
            if (!optBytesEq(points.field(1).get(j), p.label)) return false;
        } else if (points.isValid(j)) {
            return false;
        }
    }
    return true;
}

fn optBoolEq(a: ?bool, b: ?bool) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

fn optBytesEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

test "sample stream round-trips through the C API entry points" {
    // Encode fills the buffer with an IPC stream, then verify decodes it and
    // compares it to the sample, in-process.
    var buf: [4096]u8 = undefined;
    const written = zarr_encode_sample_stream(@intFromPtr(&buf), buf.len);
    try std.testing.expect(written > 0);
    try std.testing.expectEqual(@as(c_int, 0), zarr_verify_sample_stream(@intFromPtr(&buf), @intCast(written)));
}

test "sample file round-trips through the C API entry points" {
    var buf: [4096]u8 = undefined;
    const written = zarr_encode_sample_file(@intFromPtr(&buf), buf.len);
    try std.testing.expect(written > 0);
    try std.testing.expectEqual(@as(c_int, 0), zarr_verify_sample_file(@intFromPtr(&buf), @intCast(written)));
}

test "a sliced sample batch verifies through the C API entry points" {
    // Export fills the structs, then a foreign-style slice is simulated by
    // moving the root offset, exactly as a producer that hands over rows
    // [1, 3) would.
    var schema: ArrowSchema = undefined;
    var array: ArrowArray = undefined;
    try std.testing.expectEqual(@as(c_int, 0), zarr_export_sample_batch(@intFromPtr(&schema), @intFromPtr(&array)));
    array.offset = 1;
    array.length = 2;
    array.null_count = -1;
    try std.testing.expectEqual(@as(c_int, 0), zarr_verify_sample_batch_slice(@intFromPtr(&schema), @intFromPtr(&array)));
}

test "sample batch round-trips through the C API entry points" {
    // Export fills the structs, then verify imports and compares them to the
    // sample, releasing them. This exercises the entry points in-process
    // without needing an external Arrow implementation.
    var schema: ArrowSchema = undefined;
    var array: ArrowArray = undefined;
    try std.testing.expectEqual(@as(c_int, 0), zarr_export_sample_batch(@intFromPtr(&schema), @intFromPtr(&array)));
    try std.testing.expectEqual(@as(c_int, 0), zarr_verify_sample_batch(@intFromPtr(&schema), @intFromPtr(&array)));
}
