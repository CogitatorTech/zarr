//! Arrow IPC record batch serialization.
//!
//! Encodes the columns of a record batch, in their type-erased `ArrayData`
//! form, into the FlatBuffers `RecordBatch` table defined by the Arrow
//! format's Message.fbs, plus the message body holding the raw buffer bytes.
//!
//! The spec flattens a batch depth-first: for each column in order, one
//! `FieldNode` (length and null count) and one `Buffer` (offset and length in
//! the body) per canonical buffer slot, then the same for its children,
//! recursively. The batch root itself is not a node; its columns are the
//! top-level fields. An absent validity buffer is written as a zero-length
//! `Buffer` entry, matching other implementations. Buffers are laid out in
//! traversal order, each padded to an 8-byte boundary.
//!
//! A record batch in erased form is a struct array over the columns, which is
//! what `RecordBatch.toData` produces. The struct root's own validity, if it
//! has one, is not serialized: record batch rows are never null.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flatbuffers = @import("flatbuffers.zig");
const Builder = flatbuffers.Builder;
const Table = flatbuffers.Table;
const Offset = flatbuffers.Offset;
const Buffer = @import("../buffer.zig").Buffer;
const DataType = @import("../datatype.zig").DataType;
const ArrayData = @import("../array_data.zig").ArrayData;

/// Errors from decoding an encoded record batch.
pub const DecodeError = error{
    /// The batch declares body compression, which Zarr does not implement.
    UnsupportedCompression,
    /// The metadata does not describe a well-formed batch for the given type:
    /// node or buffer counts disagree with the type, a count is negative, or
    /// a buffer runs past the end of the body.
    MalformedBatch,
} || ArrayData.Error || flatbuffers.ReadError || Allocator.Error;

// `RecordBatch` table slots in Message.fbs: 0 length, 1 nodes, 2 buffers,
// 3 compression, 4 variadic buffer counts.
const batch_slot_length = 0;
const batch_slot_nodes = 1;
const batch_slot_buffers = 2;
const batch_slot_compression = 3;

/// Byte size of the `FieldNode` and `Buffer` structs: two i64 fields each.
const struct_size = 16;

/// `length` rounded up to the next 8-byte boundary.
fn padded(length: u64) u64 {
    return (length + 7) & ~@as(u64, 7);
}

const FieldNode = struct { length: i64, null_count: i64 };
const BufferRef = struct { offset: i64, length: i64 };

/// Writes `data`, the struct-typed columns of a record batch, as a FlatBuffers
/// `RecordBatch` table into `b` and returns its offset. The buffer offsets it
/// records match the body layout `encodeBody` produces.
pub fn writeRecordBatch(b: *Builder, data: ArrayData) Allocator.Error!Offset {
    std.debug.assert(data.data_type == .@"struct");

    var nodes: std.ArrayListUnmanaged(FieldNode) = .empty;
    defer nodes.deinit(b.allocator);
    var buffers: std.ArrayListUnmanaged(BufferRef) = .empty;
    defer buffers.deinit(b.allocator);
    var pos: u64 = 0;
    for (data.children) |column| {
        try collectColumn(b.allocator, column, &nodes, &buffers, &pos);
    }

    try b.startVector(struct_size, nodes.items.len, 8);
    var i = nodes.items.len;
    while (i > 0) {
        i -= 1;
        var bytes: [struct_size]u8 = undefined;
        std.mem.writeInt(i64, bytes[0..8], nodes.items[i].length, .little);
        std.mem.writeInt(i64, bytes[8..16], nodes.items[i].null_count, .little);
        try b.pushStructBytes(&bytes);
    }
    const nodes_off = try b.endVector(nodes.items.len);

    try b.startVector(struct_size, buffers.items.len, 8);
    i = buffers.items.len;
    while (i > 0) {
        i -= 1;
        var bytes: [struct_size]u8 = undefined;
        std.mem.writeInt(i64, bytes[0..8], buffers.items[i].offset, .little);
        std.mem.writeInt(i64, bytes[8..16], buffers.items[i].length, .little);
        try b.pushStructBytes(&bytes);
    }
    const buffers_off = try b.endVector(buffers.items.len);

    b.startTable();
    try b.addScalar(i64, batch_slot_length, @intCast(data.length), 0);
    try b.addOffset(batch_slot_nodes, nodes_off);
    try b.addOffset(batch_slot_buffers, buffers_off);
    return b.endTable();
}

/// Appends the node and buffer entries for one array and its descendants,
/// depth-first, advancing `pos` past each buffer's padded length. An absent
/// buffer becomes a zero-length entry at the current position.
fn collectColumn(
    allocator: Allocator,
    data: ArrayData,
    nodes: *std.ArrayListUnmanaged(FieldNode),
    buffers: *std.ArrayListUnmanaged(BufferRef),
    pos: *u64,
) Allocator.Error!void {
    try nodes.append(allocator, .{
        .length = @intCast(data.length),
        .null_count = @intCast(data.null_count),
    });
    for (data.buffers) |maybe| {
        const length: u64 = if (maybe) |buf| buf.data.len else 0;
        try buffers.append(allocator, .{
            .offset = @intCast(pos.*),
            .length = @intCast(length),
        });
        pos.* += padded(length);
    }
    for (data.children) |child| {
        try collectColumn(allocator, child, nodes, buffers, pos);
    }
}

/// Total byte length of the body for `data`: every buffer in traversal order,
/// each padded to an 8-byte boundary.
pub fn bodyLength(data: ArrayData) u64 {
    std.debug.assert(data.data_type == .@"struct");
    var total: u64 = 0;
    for (data.children) |column| addBufferLengths(column, &total);
    return total;
}

fn addBufferLengths(data: ArrayData, total: *u64) void {
    for (data.buffers) |maybe| {
        if (maybe) |buf| total.* += padded(buf.data.len);
    }
    for (data.children) |child| addBufferLengths(child, total);
}

/// Encodes the message body for `data`: the raw bytes of every buffer in
/// traversal order, zero-padded to 8-byte boundaries. The caller owns the
/// returned bytes.
pub fn encodeBody(allocator: Allocator, data: ArrayData) Allocator.Error![]u8 {
    std.debug.assert(data.data_type == .@"struct");
    const body = try allocator.alloc(u8, @intCast(bodyLength(data)));
    @memset(body, 0);
    var pos: u64 = 0;
    for (data.children) |column| copyBuffers(column, body, &pos);
    return body;
}

fn copyBuffers(data: ArrayData, body: []u8, pos: *u64) void {
    for (data.buffers) |maybe| {
        if (maybe) |buf| {
            @memcpy(body[@intCast(pos.*)..][0..buf.data.len], buf.data);
            pos.* += padded(buf.data.len);
        }
    }
    for (data.children) |child| copyBuffers(child, body, pos);
}

/// Number of `FieldNode` entries one column of `data_type` contributes.
fn countNodes(data_type: DataType) usize {
    var n: usize = 1;
    switch (data_type) {
        .list => |child| n += countNodes(child.data_type),
        .@"struct" => |fields| for (fields) |field| {
            n += countNodes(field.data_type);
        },
        else => {},
    }
    return n;
}

/// Number of `Buffer` entries one column of `data_type` contributes.
fn countBuffers(data_type: DataType) usize {
    var n = ArrayData.bufferCount(data_type);
    switch (data_type) {
        .list => |child| n += countBuffers(child.data_type),
        .@"struct" => |fields| for (fields) |field| {
            n += countBuffers(field.data_type);
        },
        else => {},
    }
    return n;
}

/// Reads the struct-typed columns of a record batch from a FlatBuffers
/// `RecordBatch` table and its message body. `data_type` must be the struct
/// type describing the columns, as built from the batch's schema; it is
/// borrowed and cloned into the result. Buffer bytes are copied out of `body`
/// into owned, aligned buffers, so `body` may be freed afterwards. The caller
/// owns the returned data and must release it with `deinit`.
pub fn readRecordBatch(allocator: Allocator, table: Table, data_type: DataType, body: []const u8) DecodeError!ArrayData {
    std.debug.assert(data_type == .@"struct");
    if (try table.readTable(batch_slot_compression) != null) return error.UnsupportedCompression;

    const length = try table.readScalar(i64, batch_slot_length, 0);
    if (length < 0) return error.MalformedBatch;

    const column_fields = data_type.@"struct";
    var expected_nodes: usize = 0;
    var expected_buffers: usize = 0;
    for (column_fields) |column_field| {
        expected_nodes += countNodes(column_field.data_type);
        expected_buffers += countBuffers(column_field.data_type);
    }
    if (try table.vectorLen(batch_slot_nodes) != expected_nodes) return error.MalformedBatch;
    if (try table.vectorLen(batch_slot_buffers) != expected_buffers) return error.MalformedBatch;

    // Constructed inside a block so its errdefers end with the block: once
    // `result` owns everything, the failure path below must free through
    // `result.deinit` alone.
    var result = blk: {
        var node_i: usize = 0;
        var buffer_i: usize = 0;
        const children = try allocator.alloc(ArrayData, column_fields.len);
        var finished: usize = 0;
        errdefer {
            for (children[0..finished]) |*child| child.deinit();
            allocator.free(children);
        }
        for (column_fields, 0..) |column_field, i| {
            children[i] = try readColumn(allocator, table, column_field.data_type, body, &node_i, &buffer_i);
            finished += 1;
        }

        // The root is the batch's struct array; its validity slot is empty
        // and its rows are never null.
        const root_buffers = try allocator.alloc(?Buffer, 1);
        errdefer allocator.free(root_buffers);
        root_buffers[0] = null;
        const root_type = try data_type.clone(allocator);
        // The layout is correct by construction, so init cannot fail: the
        // buffer and child counts match the type, the children were built
        // from the same type, and the root null count is zero.
        break :blk ArrayData.init(allocator, root_type, @intCast(length), 0, root_buffers, children) catch unreachable;
    };
    // The metadata and body were only checked structurally so far. Offsets,
    // null counts, and buffer sizes come from untrusted bytes, so validate
    // the decoded arrays in full before handing them out.
    result.validateFull() catch |err| {
        result.deinit();
        return err;
    };
    return result;
}

/// Reads one column: its `FieldNode`, its buffers, and its children,
/// depth-first, advancing the node and buffer cursors.
fn readColumn(
    allocator: Allocator,
    table: Table,
    data_type: DataType,
    body: []const u8,
    node_i: *usize,
    buffer_i: *usize,
) DecodeError!ArrayData {
    const node_pos = try table.vectorStructPos(batch_slot_nodes, node_i.*, struct_size);
    node_i.* += 1;
    const length = try table.scalarAt(i64, node_pos);
    const null_count = try table.scalarAt(i64, node_pos + 8);
    if (length < 0 or null_count < 0 or null_count > length) return error.MalformedBatch;

    const buffer_count = ArrayData.bufferCount(data_type);
    const buffers = try allocator.alloc(?Buffer, buffer_count);
    for (buffers) |*slot| slot.* = null;
    errdefer {
        for (buffers) |*maybe| {
            if (maybe.*) |*buf| buf.deinit();
        }
        allocator.free(buffers);
    }
    for (0..buffer_count) |slot| {
        const segment = try bodySegment(table, body, buffer_i);
        // A zero-length validity entry means the column has no validity
        // buffer; other zero-length buffers are real, such as the value
        // buffer of an empty array.
        if (slot == 0 and segment.len == 0) continue;
        buffers[slot] = try Buffer.dupe(allocator, segment);
    }

    const child_count = ArrayData.childCount(data_type);
    const children = try allocator.alloc(ArrayData, child_count);
    var finished: usize = 0;
    errdefer {
        for (children[0..finished]) |*child| child.deinit();
        allocator.free(children);
    }
    switch (data_type) {
        .list => |child_field| {
            children[0] = try readColumn(allocator, table, child_field.data_type, body, node_i, buffer_i);
            finished += 1;
        },
        .@"struct" => |child_fields| for (child_fields, 0..) |child_field, i| {
            children[i] = try readColumn(allocator, table, child_field.data_type, body, node_i, buffer_i);
            finished += 1;
        },
        else => {},
    }

    const owned_type = try data_type.clone(allocator);
    // The layout is correct by construction, as in readRecordBatch, and the
    // null count was validated against the length above.
    return ArrayData.init(allocator, owned_type, @intCast(length), @intCast(null_count), buffers, children) catch unreachable;
}

/// Reads the next `Buffer` entry and returns its bytes within `body`, checking
/// that the entry lies inside the body.
fn bodySegment(table: Table, body: []const u8, buffer_i: *usize) DecodeError![]const u8 {
    const pos = try table.vectorStructPos(batch_slot_buffers, buffer_i.*, struct_size);
    buffer_i.* += 1;
    const offset = try table.scalarAt(i64, pos);
    const length = try table.scalarAt(i64, pos + 8);
    if (offset < 0 or length < 0) return error.MalformedBatch;
    const start: u64 = @intCast(offset);
    const len: u64 = @intCast(length);
    if (start + len > body.len) return error.MalformedBatch;
    return body[@intCast(start)..][0..@intCast(len)];
}

const testing = std.testing;
const PrimitiveArray = @import("../primitive_array.zig").PrimitiveArray;
const Utf8Array = @import("../varbinary_array.zig").VarBinaryArray(true, i32);
const ListArray = @import("../list_array.zig").ListArray;
const StructArray = @import("../struct_array.zig").StructArray;

const PersonColumns = StructArray(&.{ PrimitiveArray(i32), Utf8Array });

/// Columns (id: int32, name: utf8) with rows {1, "a"}, {null, null},
/// {3, "ccc"}, in erased form.
fn buildPersonData(allocator: Allocator) !ArrayData {
    var builder = PersonColumns.Builder.init(allocator);
    defer builder.deinit();
    try builder.children[0].append(1);
    try builder.children[1].append("a");
    try builder.append();
    try builder.children[0].appendNull();
    try builder.children[1].appendNull();
    try builder.append();
    try builder.children[0].append(3);
    try builder.children[1].append("ccc");
    try builder.append();
    var columns = try builder.finish();
    defer columns.deinit();
    return columns.toData(allocator);
}

test "record batch columns round-trip through metadata and body" {
    const allocator = testing.allocator;
    var data = try buildPersonData(allocator);
    defer data.deinit();

    var b = Builder.init(allocator);
    defer b.deinit();
    const root = try writeRecordBatch(&b, data);
    const metadata = try b.finish(root);
    const body = try encodeBody(allocator, data);
    defer allocator.free(body);

    try testing.expectEqual(bodyLength(data), @as(u64, body.len));

    var struct_type = try DataType.initStruct(allocator, &.{ .int32, .utf8 });
    defer struct_type.deinit(allocator);
    var back = try readRecordBatch(allocator, try flatbuffers.getRoot(metadata), struct_type, body);
    defer back.deinit();

    try testing.expectEqual(@as(usize, 3), back.length);
    const ids = back.child(0);
    try testing.expectEqual(@as(usize, 1), ids.null_count);
    try testing.expect(ids.isValid(0));
    try testing.expect(!ids.isValid(1));
    try testing.expectEqual(@as(i32, 1), ids.values(i32)[0]);
    try testing.expectEqual(@as(i32, 3), ids.values(i32)[2]);
    const names = back.child(1);
    try testing.expectEqualStrings("a", names.valueBytes(0));
    try testing.expect(!names.isValid(1));
    try testing.expectEqualStrings("ccc", names.valueBytes(2));
}

test "list column round-trips" {
    const allocator = testing.allocator;
    const TagsColumns = StructArray(&.{ListArray(PrimitiveArray(i64))});

    // tags: [10, 20], [], null.
    var builder = TagsColumns.Builder.init(allocator);
    defer builder.deinit();
    try builder.children[0].values.append(10);
    try builder.children[0].values.append(20);
    try builder.children[0].appendList();
    try builder.append();
    try builder.children[0].appendList();
    try builder.append();
    try builder.children[0].appendNull();
    try builder.append();
    var columns = try builder.finish();
    defer columns.deinit();
    var data = try columns.toData(allocator);
    defer data.deinit();

    var b = Builder.init(allocator);
    defer b.deinit();
    const root = try writeRecordBatch(&b, data);
    const metadata = try b.finish(root);
    const body = try encodeBody(allocator, data);
    defer allocator.free(body);

    var list_type = try DataType.initList(allocator, .int64);
    var struct_type = try DataType.initStruct(allocator, &.{list_type});
    list_type.deinit(allocator);
    defer struct_type.deinit(allocator);
    var back = try readRecordBatch(allocator, try flatbuffers.getRoot(metadata), struct_type, body);
    defer back.deinit();

    const tags = back.child(0);
    try testing.expectEqual(@as(usize, 3), tags.length);
    try testing.expect(tags.isValid(0));
    try testing.expect(tags.isValid(1));
    try testing.expect(!tags.isValid(2));
    try testing.expectEqualSlices(i32, &.{ 0, 2, 2, 2 }, tags.offsets(i32));
    const items = tags.child(0);
    try testing.expectEqual(@as(i64, 10), items.values(i64)[0]);
    try testing.expectEqual(@as(i64, 20), items.values(i64)[1]);
}

test "zero-row batch round-trips" {
    const allocator = testing.allocator;
    var builder = PersonColumns.Builder.init(allocator);
    defer builder.deinit();
    var columns = try builder.finish();
    defer columns.deinit();
    var data = try columns.toData(allocator);
    defer data.deinit();

    var b = Builder.init(allocator);
    defer b.deinit();
    const root = try writeRecordBatch(&b, data);
    const metadata = try b.finish(root);
    const body = try encodeBody(allocator, data);
    defer allocator.free(body);

    var struct_type = try DataType.initStruct(allocator, &.{ .int32, .utf8 });
    defer struct_type.deinit(allocator);
    var back = try readRecordBatch(allocator, try flatbuffers.getRoot(metadata), struct_type, body);
    defer back.deinit();

    try testing.expectEqual(@as(usize, 0), back.length);
    try testing.expectEqual(@as(usize, 0), back.child(0).length);
}

// The output of `pyarrow.record_batch(...).serialize()` for the columns
// (id: int32 [1, 2, null], name: utf8 ["a", null, "ccc"],
// tags: list<int64> [[1, 2], [], null]), generated with pyarrow 21. It is an
// encapsulated IPC message: a 4-byte continuation marker, a 4-byte metadata
// length, the `Message` table, and the 96-byte body.
const pyarrow_batch_message = [_]u8{
    0xff, 0xff, 0xff, 0xff, 0x28, 0x01, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0c, 0x00, 0x16, 0x00, 0x06, 0x00, 0x05, 0x00, 0x08, 0x00, 0x0c, 0x00, 0x0c, 0x00, 0x00, 0x00,
    0x00, 0x03, 0x04, 0x00, 0x18, 0x00, 0x00, 0x00, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x0a, 0x00, 0x18, 0x00, 0x0c, 0x00, 0x04, 0x00, 0x08, 0x00, 0x0a, 0x00, 0x00, 0x00,
    0xac, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x61, 0x63, 0x63, 0x63, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

test "readRecordBatch reads a batch serialized by pyarrow" {
    const allocator = testing.allocator;
    const metadata_len = std.mem.readInt(u32, pyarrow_batch_message[4..8], .little);
    const metadata = pyarrow_batch_message[8 .. 8 + metadata_len];
    const body = pyarrow_batch_message[8 + metadata_len ..];

    // Message table slots (Message.fbs): 0 version, 1 header tag, 2 header,
    // 3 body length. Header tag 3 is RecordBatch.
    const message = try flatbuffers.getRoot(metadata);
    try testing.expectEqual(@as(u8, 3), try message.readScalar(u8, 1, 0));
    try testing.expectEqual(@as(i64, @intCast(body.len)), try message.readScalar(i64, 3, 0));
    const batch_table = (try message.readTable(2)).?;

    var list_type = try DataType.initList(allocator, .int64);
    var struct_type = try DataType.initStruct(allocator, &.{ .int32, .utf8, list_type });
    list_type.deinit(allocator);
    defer struct_type.deinit(allocator);

    var back = try readRecordBatch(allocator, batch_table, struct_type, body);
    defer back.deinit();

    try testing.expectEqual(@as(usize, 3), back.length);

    const ids = back.child(0);
    try testing.expectEqual(@as(i32, 1), ids.values(i32)[0]);
    try testing.expectEqual(@as(i32, 2), ids.values(i32)[1]);
    try testing.expect(!ids.isValid(2));

    const names = back.child(1);
    try testing.expectEqualStrings("a", names.valueBytes(0));
    try testing.expect(!names.isValid(1));
    try testing.expectEqualStrings("ccc", names.valueBytes(2));

    const tags = back.child(2);
    try testing.expectEqual(@as(usize, 1), tags.null_count);
    try testing.expectEqualSlices(i32, &.{ 0, 2, 2, 2 }, tags.offsets(i32));
    try testing.expect(!tags.isValid(2));
    const items = tags.child(0);
    try testing.expectEqual(@as(usize, 2), items.length);
    try testing.expectEqual(@as(i64, 1), items.values(i64)[0]);
    try testing.expectEqual(@as(i64, 2), items.values(i64)[1]);
}

test "readRecordBatch rejects a compressed body" {
    const allocator = testing.allocator;
    var b = Builder.init(allocator);
    defer b.deinit();

    // An empty BodyCompression table means LZ4 frame compression, the codec
    // enum's zero default.
    b.startTable();
    const compression = try b.endTable();
    b.startTable();
    try b.addOffset(batch_slot_compression, compression);
    const root = try b.endTable();
    const buf = try b.finish(root);

    var struct_type = try DataType.initStruct(allocator, &.{});
    defer struct_type.deinit(allocator);
    try testing.expectError(
        error.UnsupportedCompression,
        readRecordBatch(allocator, try flatbuffers.getRoot(buf), struct_type, &.{}),
    );
}

test "readRecordBatch rejects a body too short for its buffers" {
    const allocator = testing.allocator;
    var data = try buildPersonData(allocator);
    defer data.deinit();

    var b = Builder.init(allocator);
    defer b.deinit();
    const root = try writeRecordBatch(&b, data);
    const metadata = try b.finish(root);

    var struct_type = try DataType.initStruct(allocator, &.{ .int32, .utf8 });
    defer struct_type.deinit(allocator);
    try testing.expectError(
        error.MalformedBatch,
        readRecordBatch(allocator, try flatbuffers.getRoot(metadata), struct_type, &.{}),
    );
}

test "readRecordBatch rejects metadata that disagrees with the type" {
    const allocator = testing.allocator;
    var data = try buildPersonData(allocator);
    defer data.deinit();

    var b = Builder.init(allocator);
    defer b.deinit();
    const root = try writeRecordBatch(&b, data);
    const metadata = try b.finish(root);
    const body = try encodeBody(allocator, data);
    defer allocator.free(body);

    // One declared column cannot match a two-column batch.
    var struct_type = try DataType.initStruct(allocator, &.{.int32});
    defer struct_type.deinit(allocator);
    try testing.expectError(
        error.MalformedBatch,
        readRecordBatch(allocator, try flatbuffers.getRoot(metadata), struct_type, body),
    );
}

test "readRecordBatch rejects a batch with corrupt offsets" {
    const allocator = testing.allocator;
    // A utf8 column with decreasing offsets, wrapped as a batch by hand. The
    // writer does not validate, so the reader must.
    var offsets = try Buffer.alloc(allocator, 3 * @sizeOf(i32));
    const off = offsets.items(i32);
    off[0] = 0;
    off[1] = 5;
    off[2] = 3;
    const values = try Buffer.dupe(allocator, "abcdefgh");
    const column_buffers = try allocator.alloc(?Buffer, 3);
    column_buffers[0] = null;
    column_buffers[1] = offsets;
    column_buffers[2] = values;
    const column = try ArrayData.init(allocator, .utf8, 2, 0, column_buffers, try allocator.alloc(ArrayData, 0));

    const struct_type = try DataType.initStruct(allocator, &.{.utf8});
    const root_buffers = try allocator.alloc(?Buffer, 1);
    root_buffers[0] = null;
    const root_children = try allocator.alloc(ArrayData, 1);
    root_children[0] = column;
    var data = try ArrayData.init(allocator, struct_type, 2, 0, root_buffers, root_children);
    defer data.deinit();

    var b = Builder.init(allocator);
    defer b.deinit();
    const root = try writeRecordBatch(&b, data);
    const metadata = try b.finish(root);
    const body = try encodeBody(allocator, data);
    defer allocator.free(body);

    var expected_type = try DataType.initStruct(allocator, &.{.utf8});
    defer expected_type.deinit(allocator);
    try testing.expectError(
        error.InvalidOffset,
        readRecordBatch(allocator, try flatbuffers.getRoot(metadata), expected_type, body),
    );
}

test "record batch serialization leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var data = try buildPersonData(allocator);
            defer data.deinit();
            var b = Builder.init(allocator);
            defer b.deinit();
            const root = try writeRecordBatch(&b, data);
            const metadata = try b.finish(root);
            const body = try encodeBody(allocator, data);
            defer allocator.free(body);
            var struct_type = try DataType.initStruct(allocator, &.{ .int32, .utf8 });
            defer struct_type.deinit(allocator);
            var back = try readRecordBatch(allocator, try flatbuffers.getRoot(metadata), struct_type, body);
            back.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}
