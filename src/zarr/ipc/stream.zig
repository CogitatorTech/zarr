//! Arrow IPC streaming format.
//!
//! A stream is a schema message, any number of record batch messages, and an
//! end-of-stream marker. Each message is a FlatBuffers `Message` table (from
//! the Arrow format's Message.fbs) wrapped in the encapsulated envelope that
//! `ipc/message.zig` handles, followed by the message body. This module sits
//! above the other IPC modules: it composes the envelope, the schema table
//! from `ipc/schema.zig`, and the record batch table from `ipc/batch.zig`.
//!
//! `StreamWriter` builds a stream in memory, and `StreamReader` walks one,
//! returning each batch's columns as `ArrayData`. Dictionary batches are not
//! implemented and are reported as `error.UnsupportedMessage`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flatbuffers = @import("flatbuffers.zig");
const Builder = flatbuffers.Builder;
const message = @import("message.zig");
const ipc_schema = @import("schema.zig");
const batch = @import("batch.zig");
const Schema = @import("../schema.zig").Schema;
const DataType = @import("../datatype.zig").DataType;
const ArrayData = @import("../array_data.zig").ArrayData;

/// Errors from reading a stream.
pub const DecodeError = error{
    /// The stream structure is wrong: it does not start with a schema
    /// message, or a schema message appears again mid-stream.
    UnexpectedMessage,
    /// The stream contains a valid message kind Zarr does not implement,
    /// such as a dictionary batch.
    UnsupportedMessage,
} || message.DecodeError || ipc_schema.DecodeError || batch.DecodeError;

// `Message` table slots in Message.fbs: 0 version, 1 header tag, 2 header,
// 3 body length, 4 custom metadata.
const message_slot_version = 0;
const message_slot_header_tag = 1;
const message_slot_header = 2;
const message_slot_body_length = 3;

// `MessageHeader` union members: Schema 1, DictionaryBatch 2, RecordBatch 3.
const header_schema: u8 = 1;
const header_dictionary_batch: u8 = 2;
const header_record_batch: u8 = 3;

/// `MetadataVersion.V5`, the current format version, written on every message.
const metadata_version_v5: i16 = 4;

/// The 8-byte end-of-stream marker: the continuation marker followed by a
/// zero metadata length.
pub const end_of_stream = [8]u8{ 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 };

/// Encodes `schema` as one encapsulated schema message. The caller owns the
/// returned bytes.
pub fn encodeSchemaMessage(allocator: Allocator, schema: Schema) Allocator.Error![]u8 {
    var b = Builder.init(allocator);
    defer b.deinit();
    const schema_off = try ipc_schema.writeSchema(&b, schema);
    const metadata = try b.finish(try writeMessage(&b, header_schema, schema_off, 0));
    return message.encode(allocator, metadata, &.{});
}

/// Encodes `data`, the struct-typed columns of a record batch, as one
/// encapsulated record batch message with its body. The caller owns the
/// returned bytes.
pub fn encodeBatchMessage(allocator: Allocator, data: ArrayData) Allocator.Error![]u8 {
    var b = Builder.init(allocator);
    defer b.deinit();
    const batch_off = try batch.writeRecordBatch(&b, data);
    const body_length = batch.bodyLength(data);
    const metadata = try b.finish(try writeMessage(&b, header_record_batch, batch_off, @intCast(body_length)));
    const body = try batch.encodeBody(allocator, data);
    defer allocator.free(body);
    return message.encode(allocator, metadata, body);
}

/// Writes the `Message` table wrapping one header and returns its offset.
fn writeMessage(b: *Builder, header_tag: u8, header: flatbuffers.Offset, body_length: i64) Allocator.Error!flatbuffers.Offset {
    b.startTable();
    try b.addScalar(i16, message_slot_version, metadata_version_v5, 0);
    try b.addScalar(u8, message_slot_header_tag, header_tag, 0);
    try b.addOffset(message_slot_header, header);
    try b.addScalar(i64, message_slot_body_length, body_length, 0);
    return b.endTable();
}

/// Builds an Arrow IPC stream in memory: a schema message, the batches
/// written through `writeBatch`, and the end-of-stream marker on `finish`.
pub const StreamWriter = struct {
    allocator: Allocator,
    buf: std.ArrayListUnmanaged(u8),

    /// Starts a stream by writing the schema message. Release with `deinit`.
    pub fn init(allocator: Allocator, schema: Schema) Allocator.Error!StreamWriter {
        var self = StreamWriter{ .allocator = allocator, .buf = .empty };
        errdefer self.buf.deinit(allocator);
        const msg = try encodeSchemaMessage(allocator, schema);
        defer allocator.free(msg);
        try self.buf.appendSlice(allocator, msg);
        return self;
    }

    pub fn deinit(self: *StreamWriter) void {
        self.buf.deinit(self.allocator);
        self.* = undefined;
    }

    /// Appends one record batch message. `data` is the struct-typed columns
    /// of a batch, as produced by `RecordBatch.toData`, and must match the
    /// schema the stream was started with; the caller keeps ownership.
    pub fn writeBatch(self: *StreamWriter, data: ArrayData) Allocator.Error!void {
        const msg = try encodeBatchMessage(self.allocator, data);
        defer self.allocator.free(msg);
        try self.buf.appendSlice(self.allocator, msg);
    }

    /// Appends the end-of-stream marker and returns the finished stream,
    /// owned by the caller. After `finish`, only `deinit` may be called.
    pub fn finish(self: *StreamWriter) Allocator.Error![]u8 {
        try self.buf.appendSlice(self.allocator, &end_of_stream);
        return self.buf.toOwnedSlice(self.allocator);
    }
};

/// Walks an Arrow IPC stream, decoding the schema up front and one batch per
/// `next` call. Borrows `bytes`; the decoded batches own their memory.
pub const StreamReader = struct {
    allocator: Allocator,
    bytes: []const u8,
    /// Byte position of the next unread message.
    pos: usize,
    /// The stream's schema, owned by this reader.
    schema: Schema,
    /// The struct type over the schema's columns, used to decode each batch;
    /// owned by this reader.
    column_type: DataType,

    /// Reads the schema message that starts the stream. Release with `deinit`.
    pub fn init(allocator: Allocator, bytes: []const u8) DecodeError!StreamReader {
        const envelope = try message.decode(bytes);
        if (envelope.metadata.len == 0) return error.UnexpectedMessage;
        const msg = flatbuffers.getRoot(envelope.metadata);
        if (msg.readScalar(u8, message_slot_header_tag, 0) != header_schema) {
            return error.UnexpectedMessage;
        }
        const header = msg.readTable(message_slot_header) orelse return error.MalformedSchema;

        var schema = try ipc_schema.readSchema(allocator, header);
        errdefer schema.deinit(allocator);
        const column_type = try columnTypeOf(allocator, schema);
        return .{
            .allocator = allocator,
            .bytes = bytes,
            .pos = 8 + envelope.metadata.len,
            .schema = schema,
            .column_type = column_type,
        };
    }

    pub fn deinit(self: *StreamReader) void {
        self.schema.deinit(self.allocator);
        self.column_type.deinit(self.allocator);
        self.* = undefined;
    }

    /// Decodes the next record batch's columns, or returns null at the
    /// end-of-stream marker or the end of the input. The caller owns the
    /// returned data and must release it with `deinit`.
    pub fn next(self: *StreamReader) DecodeError!?ArrayData {
        if (self.pos >= self.bytes.len) return null;
        const envelope = try message.decode(self.bytes[self.pos..]);
        if (envelope.metadata.len == 0) {
            // The end-of-stream marker; stay on it so further calls also
            // return null.
            return null;
        }

        const msg = flatbuffers.getRoot(envelope.metadata);
        const body_length = msg.readScalar(i64, message_slot_body_length, 0);
        if (body_length < 0) return error.Truncated;
        const body_len: usize = @intCast(body_length);
        if (envelope.body.len < body_len) return error.Truncated;

        const data = try decodeBatchMessage(self.allocator, self.bytes[self.pos..], self.column_type);
        self.pos += 8 + envelope.metadata.len + body_len;
        return data;
    }
};

/// Decodes one encapsulated record batch message at the start of `bytes` into
/// the struct-typed columns it holds. `column_type` is the struct type over
/// the schema's column types, as `columnTypeOf` builds. Used by the stream
/// reader for the next message and by the file reader for random access. The
/// caller owns the returned data.
pub fn decodeBatchMessage(allocator: Allocator, bytes: []const u8, column_type: DataType) DecodeError!ArrayData {
    const envelope = try message.decode(bytes);
    if (envelope.metadata.len == 0) return error.UnexpectedMessage;
    const msg = flatbuffers.getRoot(envelope.metadata);

    const body_length = msg.readScalar(i64, message_slot_body_length, 0);
    if (body_length < 0) return error.Truncated;
    const body_len: usize = @intCast(body_length);
    if (envelope.body.len < body_len) return error.Truncated;

    switch (msg.readScalar(u8, message_slot_header_tag, 0)) {
        header_record_batch => {},
        header_schema => return error.UnexpectedMessage,
        else => return error.UnsupportedMessage,
    }
    const header = msg.readTable(message_slot_header) orelse return error.MalformedBatch;
    return batch.readRecordBatch(allocator, header, column_type, envelope.body[0..body_len]);
}

/// The struct type over a schema's column types, which is the shape of a
/// batch's columns in erased form. The caller owns the returned type.
pub fn columnTypeOf(allocator: Allocator, schema: Schema) Allocator.Error!DataType {
    const child_types = try allocator.alloc(DataType, schema.fields.len);
    defer allocator.free(child_types);
    for (schema.fields, 0..) |f, i| child_types[i] = f.data_type;
    return DataType.initStruct(allocator, child_types);
}

const testing = std.testing;
const PrimitiveArray = @import("../primitive_array.zig").PrimitiveArray;
const Utf8Array = @import("../varbinary_array.zig").VarBinaryArray(true, i32);
const StructArray = @import("../struct_array.zig").StructArray;
const Field = @import("../schema.zig").Field;

const PersonColumns = StructArray(&.{ PrimitiveArray(i32), Utf8Array });

fn buildPersonSchema(allocator: Allocator) !Schema {
    var id = try Field.init(allocator, "id", .int32, false);
    defer id.deinit(allocator);
    var name = try Field.init(allocator, "name", .utf8, true);
    defer name.deinit(allocator);
    return Schema.init(allocator, &.{ id, name });
}

/// Columns (id, name) with the given rows, in erased form.
fn buildPersonData(allocator: Allocator, ids: []const ?i32, names: []const ?[]const u8) !ArrayData {
    var builder = PersonColumns.Builder.init(allocator);
    defer builder.deinit();
    for (ids, names) |maybe_id, maybe_name| {
        if (maybe_id) |v| try builder.children[0].append(v) else try builder.children[0].appendNull();
        if (maybe_name) |v| try builder.children[1].append(v) else try builder.children[1].appendNull();
        try builder.append();
    }
    var columns = try builder.finish();
    defer columns.deinit();
    return columns.toData(allocator);
}

test "stream round-trips a schema and two batches" {
    const allocator = testing.allocator;
    var schema = try buildPersonSchema(allocator);
    defer schema.deinit(allocator);
    var batch1 = try buildPersonData(allocator, &.{ 1, null, 3 }, &.{ "a", null, "ccc" });
    defer batch1.deinit();
    var batch2 = try buildPersonData(allocator, &.{7}, &.{"x"});
    defer batch2.deinit();

    var writer = try StreamWriter.init(allocator, schema);
    defer writer.deinit();
    try writer.writeBatch(batch1);
    try writer.writeBatch(batch2);
    const bytes = try writer.finish();
    defer allocator.free(bytes);

    var reader = try StreamReader.init(allocator, bytes);
    defer reader.deinit();

    try testing.expect(schema.equals(reader.schema));

    var first = (try reader.next()).?;
    defer first.deinit();
    try testing.expectEqual(@as(usize, 3), first.length);
    try testing.expectEqual(@as(i32, 1), first.child(0).values(i32)[0]);
    try testing.expect(!first.child(0).isValid(1));
    try testing.expectEqualStrings("ccc", first.child(1).valueBytes(2));

    var second = (try reader.next()).?;
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), second.length);
    try testing.expectEqual(@as(i32, 7), second.child(0).values(i32)[0]);
    try testing.expectEqualStrings("x", second.child(1).valueBytes(0));

    try testing.expectEqual(@as(?ArrayData, null), try reader.next());
    // A reader at the end stays at the end.
    try testing.expectEqual(@as(?ArrayData, null), try reader.next());
}

test "schema-only stream has no batches" {
    const allocator = testing.allocator;
    var schema = try buildPersonSchema(allocator);
    defer schema.deinit(allocator);

    var writer = try StreamWriter.init(allocator, schema);
    defer writer.deinit();
    const bytes = try writer.finish();
    defer allocator.free(bytes);

    var reader = try StreamReader.init(allocator, bytes);
    defer reader.deinit();
    try testing.expect(schema.equals(reader.schema));
    try testing.expectEqual(@as(?ArrayData, null), try reader.next());
}

test "reader rejects a stream that does not start with a schema" {
    const allocator = testing.allocator;
    var data = try buildPersonData(allocator, &.{1}, &.{"a"});
    defer data.deinit();
    const msg = try encodeBatchMessage(allocator, data);
    defer allocator.free(msg);

    try testing.expectError(error.UnexpectedMessage, StreamReader.init(allocator, msg));
}

test "reader rejects a truncated stream" {
    const allocator = testing.allocator;
    var schema = try buildPersonSchema(allocator);
    defer schema.deinit(allocator);
    var data = try buildPersonData(allocator, &.{ 1, 2, 3 }, &.{ "a", "bb", "ccc" });
    defer data.deinit();

    var writer = try StreamWriter.init(allocator, schema);
    defer writer.deinit();
    try writer.writeBatch(data);
    const bytes = try writer.finish();
    defer allocator.free(bytes);

    // Cut off the end-of-stream marker and part of the batch body.
    var reader = try StreamReader.init(allocator, bytes[0 .. bytes.len - 16]);
    defer reader.deinit();
    try testing.expectError(error.Truncated, reader.next());
}

// The bytes of a pyarrow IPC stream, generated with pyarrow 21 via
// `pyarrow.ipc.new_stream`. Schema: (id: int32 not null, name: utf8,
// tags: list<int64>). Two batches:
// {[1, 2, 3], ["a", null, "ccc"], [[1, 2], [], null]} and
// {[7], ["x"], [[9]]}, then the end-of-stream marker.
const pyarrow_stream = [_]u8{
    0xff, 0xff, 0xff, 0xff, 0x18, 0x01, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x00,
    0x0c, 0x00, 0x06, 0x00, 0x05, 0x00, 0x08, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x01, 0x04, 0x00,
    0x0c, 0x00, 0x00, 0x00, 0x08, 0x00, 0x08, 0x00, 0x00, 0x00, 0x04, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0xb4, 0x00, 0x00, 0x00, 0x74, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0xa4, 0xff, 0xff, 0xff, 0x00, 0x00, 0x01, 0x0c, 0x14, 0x00, 0x00, 0x00,
    0x1c, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x74, 0x61, 0x67, 0x73, 0x00, 0x00, 0x00, 0x00, 0x98, 0xff, 0xff, 0xff,
    0xd0, 0xff, 0xff, 0xff, 0x00, 0x00, 0x01, 0x02, 0x10, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x69, 0x74, 0x65, 0x6d,
    0x00, 0x00, 0x00, 0x00, 0x88, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01, 0x40, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x14, 0x00, 0x08, 0x00, 0x06, 0x00, 0x07, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x10, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x05, 0x10, 0x00, 0x00, 0x00, 0x1c, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x6e, 0x61, 0x6d, 0x65,
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x00, 0x00, 0x10, 0x00, 0x14, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x07, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x02, 0x10, 0x00, 0x00, 0x00, 0x1c, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x69, 0x64, 0x00, 0x00, 0x08, 0x00, 0x0c, 0x00,
    0x08, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x20, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0x28, 0x01, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0c, 0x00, 0x16, 0x00, 0x06, 0x00, 0x05, 0x00, 0x08, 0x00, 0x0c, 0x00, 0x0c, 0x00, 0x00, 0x00,
    0x00, 0x03, 0x04, 0x00, 0x18, 0x00, 0x00, 0x00, 0x58, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x0a, 0x00, 0x18, 0x00, 0x0c, 0x00, 0x04, 0x00, 0x08, 0x00, 0x0a, 0x00, 0x00, 0x00,
    0xac, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x61, 0x63, 0x63, 0x63, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x28, 0x01, 0x00, 0x00,
    0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x16, 0x00, 0x06, 0x00, 0x05, 0x00,
    0x08, 0x00, 0x0c, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x03, 0x04, 0x00, 0x18, 0x00, 0x00, 0x00,
    0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x18, 0x00, 0x0c, 0x00,
    0x04, 0x00, 0x08, 0x00, 0x0a, 0x00, 0x00, 0x00, 0xac, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x78, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
};

test "reader walks a stream written by pyarrow" {
    const allocator = testing.allocator;

    var reader = try StreamReader.init(allocator, &pyarrow_stream);
    defer reader.deinit();

    try testing.expectEqual(@as(usize, 3), reader.schema.fieldCount());
    try testing.expectEqualStrings("id", reader.schema.field(0).name);
    try testing.expect(!reader.schema.field(0).nullable);
    try testing.expect(reader.schema.field(1).data_type.equals(.utf8));
    try testing.expect(reader.schema.field(2).data_type == .list);
    try testing.expect(reader.schema.field(2).data_type.list.equals(.int64));

    var first = (try reader.next()).?;
    defer first.deinit();
    try testing.expectEqual(@as(usize, 3), first.length);
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, first.child(0).values(i32));
    try testing.expect(!first.child(1).isValid(1));
    try testing.expectEqualStrings("ccc", first.child(1).valueBytes(2));
    const tags = first.child(2);
    try testing.expectEqualSlices(i32, &.{ 0, 2, 2, 2 }, tags.offsets(i32));
    try testing.expect(!tags.isValid(2));
    try testing.expectEqual(@as(i64, 2), tags.child(0).values(i64)[1]);

    var second = (try reader.next()).?;
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), second.length);
    try testing.expectEqual(@as(i32, 7), second.child(0).values(i32)[0]);
    try testing.expectEqualStrings("x", second.child(1).valueBytes(0));
    try testing.expectEqual(@as(i64, 9), second.child(2).child(0).values(i64)[0]);

    try testing.expectEqual(@as(?ArrayData, null), try reader.next());
}

test "stream serialization leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var schema = try buildPersonSchema(allocator);
            defer schema.deinit(allocator);
            var data = try buildPersonData(allocator, &.{ 1, null }, &.{ "a", null });
            defer data.deinit();

            var writer = try StreamWriter.init(allocator, schema);
            defer writer.deinit();
            try writer.writeBatch(data);
            const bytes = try writer.finish();
            defer allocator.free(bytes);

            var reader = try StreamReader.init(allocator, bytes);
            defer reader.deinit();
            var back = (try reader.next()).?;
            back.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}
