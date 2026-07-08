//! C-callable entry points for the Arrow C Data Interface.
//!
//! This is the root of the `zarr_c` shared library, kept separate from the
//! `zarr` module so the core stays free of a libc dependency. It exposes a
//! small, fixed surface used to verify Zarr's C Data Interface against another
//! Arrow implementation: one function exports a known sample record batch, and
//! one imports a batch and checks it equals that sample. Both take the
//! addresses of caller-allocated `ArrowSchema` and `ArrowArray` structs as
//! integers, which is how cffi and ctypes pass them.
//!
//! The sample batch covers several layout families in one round trip:
//!
//! - `id`: `int32`, `[1, 2, 3]`, non-null (fixed-width primitive).
//! - `flag`: `boolean`, `[true, null, false]` (bit-packed values plus validity).
//! - `name`: `utf8`, `["a", null, "ccc"]` (32-bit-offset variable length).
//! - `bio`: `large_utf8`, `["x", "yy", "zzz"]` (64-bit-offset variable length).
//! - `tags`: `list<int32>`, `[[1, 2], [], [3, 4, 5]]` (nested offsets and child).
//!
//! Timestamp and struct columns are left out on purpose: a batch builder always
//! stamps a primitive column with its storage type, so a `timestamp` logical
//! type cannot ride through it, and a struct `DataType` carries no field names,
//! so a struct column's inner fields would export unnamed.

const std = @import("std");
const zarr = @import("zarr");

const ArrowSchema = zarr.c_data.ArrowSchema;
const ArrowArray = zarr.c_data.ArrowArray;
const SampleBatch = zarr.RecordBatch(&[_]type{
    zarr.PrimitiveArray(i32),
    zarr.BooleanArray,
    zarr.Utf8Array,
    zarr.LargeUtf8Array,
    zarr.ListArray(zarr.PrimitiveArray(i32)),
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
    fields[4] = try zarr.Field.init(allocator, "tags", list_type, false);
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
        try builder.append();
    }
    var columns = try builder.finish();
    errdefer columns.deinit();
    return SampleBatch.init(allocator, schema, columns);
}

fn batchMatchesSample(batch: SampleBatch) bool {
    if (batch.numRows() != row_count) return false;
    const ids = batch.column(0);
    const flags = batch.column(1);
    const names = batch.column(2);
    const bios = batch.column(3);
    const tags = batch.column(4);
    for (0..row_count) |i| {
        if (ids.get(i) != @as(?i32, expected_ids[i])) return false;
        if (!optBoolEq(flags.get(i), expected_flags[i])) return false;
        if (!optBytesEq(names.get(i), expected_names[i])) return false;
        if (!optBytesEq(bios.get(i), expected_bios[i])) return false;
        if (tags.valueLength(i) != expected_tags[i].len) return false;
        const base = tags.valueOffset(i);
        for (expected_tags[i], 0..) |element, j| {
            if (tags.values.get(base + j) != @as(?i32, element)) return false;
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

test "sample batch round-trips through the C API entry points" {
    // Export fills the structs, then verify imports and compares them to the
    // sample, releasing them. This exercises the entry points in-process
    // without needing an external Arrow implementation.
    var schema: ArrowSchema = undefined;
    var array: ArrowArray = undefined;
    try std.testing.expectEqual(@as(c_int, 0), zarr_export_sample_batch(@intFromPtr(&schema), @intFromPtr(&array)));
    try std.testing.expectEqual(@as(c_int, 0), zarr_verify_sample_batch(@intFromPtr(&schema), @intFromPtr(&array)));
}
