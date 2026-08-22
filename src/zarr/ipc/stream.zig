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
//! returning each batch's columns as `ArrayData`. The reader collects
//! dictionary batches into a map and attaches the values to the
//! dictionary-encoded columns that reference them. The writer emits each
//! dictionary once, before the first batch that uses it; dictionary deltas
//! are not implemented yet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flatbuffers = @import("flatbuffers.zig");
const Builder = flatbuffers.Builder;
const message = @import("message.zig");
const ipc_schema = @import("schema.zig");
const batch = @import("batch.zig");
const Buffer = @import("../buffer.zig").Buffer;
const Schema = @import("../schema.zig").Schema;
const Field = @import("../schema.zig").Field;
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

/// The location of one encapsulated message inside a buffer being written:
/// its offset, its prefix-plus-metadata length, and its body length. The
/// file writer records these as footer blocks.
pub const MessageBlock = struct { offset: i64, metadata_length: i32, body_length: i64 };

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
    /// Dictionary values already written, by id; owned by this writer and
    /// kept to check that later batches reuse them unchanged.
    emitted: batch.Dictionaries,

    /// Starts a stream by writing the schema message. Release with `deinit`.
    pub fn init(allocator: Allocator, schema: Schema) Allocator.Error!StreamWriter {
        var self = StreamWriter{
            .allocator = allocator,
            .buf = .empty,
            .emitted = batch.Dictionaries.init(allocator),
        };
        errdefer self.deinit();
        const msg = try encodeSchemaMessage(allocator, schema);
        defer allocator.free(msg);
        try self.buf.appendSlice(allocator, msg);
        return self;
    }

    pub fn deinit(self: *StreamWriter) void {
        self.buf.deinit(self.allocator);
        var it = self.emitted.valueIterator();
        while (it.next()) |values| values.deinit();
        self.emitted.deinit();
        self.* = undefined;
    }

    /// Appends one record batch message, preceded by a dictionary batch
    /// message for every dictionary the batch uses that has not been emitted
    /// yet. A later batch must reuse an emitted dictionary unchanged, since
    /// deltas are not implemented; a changed dictionary returns
    /// `error.UnsupportedType`. `data` is the struct-typed columns of a
    /// batch and must match the schema the stream was started with; the
    /// caller keeps ownership.
    pub fn writeBatch(self: *StreamWriter, data: ArrayData) (Allocator.Error || error{UnsupportedType})!void {
        for (data.children) |column| {
            try emitDictionaries(self.allocator, &self.buf, &self.emitted, column);
        }
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
    /// Dictionary values by id, collected from dictionary batch messages;
    /// owned by this reader and cloned into the arrays that use them.
    dictionaries: batch.Dictionaries,

    /// Reads the schema message that starts the stream. Release with `deinit`.
    pub fn init(allocator: Allocator, bytes: []const u8) DecodeError!StreamReader {
        const envelope = try message.decode(bytes);
        if (envelope.metadata.len == 0) return error.UnexpectedMessage;
        const msg = try flatbuffers.getRoot(envelope.metadata);
        if (try msg.readScalar(u8, message_slot_header_tag, 0) != header_schema) {
            return error.UnexpectedMessage;
        }
        const header = (try msg.readTable(message_slot_header)) orelse return error.MalformedSchema;

        var schema = try ipc_schema.readSchema(allocator, header);
        errdefer schema.deinit(allocator);
        const column_type = try columnTypeOf(allocator, schema);
        return .{
            .allocator = allocator,
            .bytes = bytes,
            .pos = 8 + envelope.metadata.len,
            .schema = schema,
            .column_type = column_type,
            .dictionaries = batch.Dictionaries.init(allocator),
        };
    }

    pub fn deinit(self: *StreamReader) void {
        self.schema.deinit(self.allocator);
        self.column_type.deinit(self.allocator);
        var it = self.dictionaries.valueIterator();
        while (it.next()) |values| values.deinit();
        self.dictionaries.deinit();
        self.* = undefined;
    }

    /// Decodes the next record batch's columns, or returns null at the
    /// end-of-stream marker or the end of the input. The caller owns the
    /// returned data and must release it with `deinit`.
    pub fn next(self: *StreamReader) DecodeError!?ArrayData {
        while (true) {
            if (self.pos >= self.bytes.len) return null;
            const envelope = try message.decode(self.bytes[self.pos..]);
            if (envelope.metadata.len == 0) {
                // The end-of-stream marker; stay on it so further calls also
                // return null.
                return null;
            }

            const msg = try flatbuffers.getRoot(envelope.metadata);
            const body_length = try msg.readScalar(i64, message_slot_body_length, 0);
            if (body_length < 0) return error.Truncated;
            const body_len: usize = @intCast(body_length);
            if (envelope.body.len < body_len) return error.Truncated;
            const advance = 8 + envelope.metadata.len + body_len;

            switch (try msg.readScalar(u8, message_slot_header_tag, 0)) {
                header_dictionary_batch => {
                    const header = (try msg.readTable(message_slot_header)) orelse return error.MalformedBatch;
                    try ingestDictionaryBatch(self.allocator, &self.dictionaries, self.schema, header, envelope.body[0..body_len]);
                    self.pos += advance;
                },
                header_record_batch => {
                    const header = (try msg.readTable(message_slot_header)) orelse return error.MalformedBatch;
                    const data = try batch.readRecordBatch(self.allocator, header, self.column_type, envelope.body[0..body_len], &self.dictionaries);
                    self.pos += advance;
                    return data;
                },
                header_schema => return error.UnexpectedMessage,
                else => return error.UnsupportedMessage,
            }
        }
    }
};

/// Walks an array, appending a dictionary batch message for every
/// dictionary node whose id has not been emitted, inner dictionaries first so
/// a reader can resolve nested encodings in order. An id seen again must
/// carry the same values; deltas are not implemented.
fn emitDictionaries(
    allocator: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    emitted: *batch.Dictionaries,
    data: ArrayData,
) (Allocator.Error || error{UnsupportedType})!void {
    return emitDictionariesRecorded(allocator, buf, emitted, data, null);
}

/// Like `emitDictionaries`, but records each emitted message's location into
/// `blocks`; the file writer turns those into footer dictionary blocks.
pub fn emitDictionariesRecorded(
    allocator: Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    emitted: *batch.Dictionaries,
    data: ArrayData,
    blocks: ?*std.ArrayListUnmanaged(MessageBlock),
) (Allocator.Error || error{UnsupportedType})!void {
    if (data.data_type == .dictionary) {
        const values = data.dictionary.?;
        // The values may contain dictionary-encoded children of their own.
        try emitDictionariesRecorded(allocator, buf, emitted, values.*, blocks);

        const id = data.data_type.dictionary.id;
        if (emitted.getPtr(id)) |seen| {
            if (!seen.dataEquals(values.*)) return error.UnsupportedType;
            return;
        }
        const encoded = try encodeDictionaryMessage(allocator, id, values.*);
        defer allocator.free(encoded.bytes);
        if (blocks) |list| {
            try list.append(allocator, .{
                .offset = @intCast(buf.items.len),
                .metadata_length = @intCast(encoded.bytes.len - encoded.body_length),
                .body_length = @intCast(encoded.body_length),
            });
        }
        try buf.appendSlice(allocator, encoded.bytes);
        var kept = try values.clone(allocator);
        errdefer kept.deinit();
        try emitted.put(id, kept);
        return;
    }
    for (data.children) |child| {
        try emitDictionariesRecorded(allocator, buf, emitted, child, blocks);
    }
}

const EncodedMessage = struct { bytes: []u8, body_length: u64 };

/// Encodes one dictionary batch message: the values as a single-column
/// record batch inside a `DictionaryBatch` header. The values are borrowed.
fn encodeDictionaryMessage(allocator: Allocator, id: i64, values: ArrayData) Allocator.Error!EncodedMessage {
    var children = [1]ArrayData{values};
    var root_buffers = [1]?Buffer{null};
    // A borrowed root over the values; writeRecordBatch and encodeBody only
    // read it, and its empty struct type is never released.
    const root = ArrayData{
        .allocator = allocator,
        .data_type = .{ .@"struct" = &.{} },
        .length = values.length,
        .null_count = 0,
        .buffers = root_buffers[0..],
        .children = children[0..],
    };

    var b = Builder.init(allocator);
    defer b.deinit();
    const batch_off = try batch.writeRecordBatch(&b, root);
    const body_length = batch.bodyLength(root);
    // DictionaryBatch slots (Message.fbs): 0 id, 1 data, 2 isDelta.
    b.startTable();
    try b.addScalar(i64, 0, id, 0);
    try b.addOffset(1, batch_off);
    const dict_off = try b.endTable();
    const metadata = try b.finish(try writeMessage(&b, header_dictionary_batch, dict_off, @intCast(body_length)));

    const body = try batch.encodeBody(allocator, root);
    defer allocator.free(body);
    return .{ .bytes = try message.encode(allocator, metadata, body), .body_length = body_length };
}

/// The value type of the dictionary with the given id, found anywhere in the
/// schema, or null when no field references it. Borrowed from the schema.
pub fn dictionaryValueType(schema: Schema, id: i64) ?DataType {
    for (schema.fields) |f| {
        if (findDictionaryValue(f.data_type, id)) |value| return value;
    }
    return null;
}

fn findDictionaryValue(data_type: DataType, id: i64) ?DataType {
    return switch (data_type) {
        .dictionary => |d| if (d.id == id) d.value.* else findDictionaryValue(d.value.*, id),
        .list => |child| findDictionaryValue(child.data_type, id),
        .fixed_size_list => |fsl| findDictionaryValue(fsl.child.data_type, id),
        .@"struct" => |fields| for (fields) |f| {
            if (findDictionaryValue(f.data_type, id)) |value| break value;
        } else null,
        else => null,
    };
}

/// Decodes one `DictionaryBatch` header and stores its values in `map`,
/// replacing any previous values for the same id. Deltas are not implemented.
/// Used by the stream reader for inline messages and by the file reader for
/// footer dictionary blocks.
pub fn ingestDictionaryBatch(
    allocator: Allocator,
    map: *batch.Dictionaries,
    schema: Schema,
    dict_table: flatbuffers.Table,
    body: []const u8,
) DecodeError!void {
    // DictionaryBatch slots (Message.fbs): 0 id, 1 data, 2 isDelta.
    const id = try dict_table.readScalar(i64, 0, 0);
    if (try dict_table.readScalar(bool, 2, false)) return error.UnsupportedMessage;
    const data_table = (try dict_table.readTable(1)) orelse return error.MalformedBatch;
    const value_type = dictionaryValueType(schema, id) orelse return error.MalformedBatch;

    // The dictionary travels as a record batch with one column of the value
    // type. Earlier dictionaries are passed along, so a dictionary whose
    // values are themselves dictionary-encoded resolves against them.
    var value_field = try Field.init(allocator, "", value_type, true);
    defer value_field.deinit(allocator);
    var wrapper = try DataType.initStructFields(allocator, &.{value_field});
    defer wrapper.deinit(allocator);

    var decoded = try batch.readRecordBatch(allocator, data_table, wrapper, body, map);
    defer decoded.deinit();
    if (decoded.children.len != 1) return error.MalformedBatch;
    var values = try decoded.children[0].clone(allocator);
    errdefer values.deinit();

    const slot = try map.getOrPut(id);
    if (slot.found_existing) slot.value_ptr.deinit();
    slot.value_ptr.* = values;
}

/// Decodes one encapsulated record batch message at the start of `bytes` into
/// the struct-typed columns it holds. `column_type` is the struct type over
/// the schema's column types, as `columnTypeOf` builds. Used by the stream
/// reader for the next message and by the file reader for random access. The
/// caller owns the returned data.
pub fn decodeBatchMessage(allocator: Allocator, bytes: []const u8, column_type: DataType, dictionaries: ?*const batch.Dictionaries) DecodeError!ArrayData {
    const envelope = try message.decode(bytes);
    if (envelope.metadata.len == 0) return error.UnexpectedMessage;
    const msg = try flatbuffers.getRoot(envelope.metadata);

    const body_length = try msg.readScalar(i64, message_slot_body_length, 0);
    if (body_length < 0) return error.Truncated;
    const body_len: usize = @intCast(body_length);
    if (envelope.body.len < body_len) return error.Truncated;

    switch (try msg.readScalar(u8, message_slot_header_tag, 0)) {
        header_record_batch => {},
        header_schema => return error.UnexpectedMessage,
        else => return error.UnsupportedMessage,
    }
    const header = (try msg.readTable(message_slot_header)) orelse return error.MalformedBatch;
    return batch.readRecordBatch(allocator, header, column_type, envelope.body[0..body_len], dictionaries);
}

/// The struct type over a schema's fields, which is the shape of a batch's
/// columns in erased form. The struct carries the schema's field names and
/// nullability. The caller owns the returned type.
pub fn columnTypeOf(allocator: Allocator, schema: Schema) Allocator.Error!DataType {
    return DataType.initStructFields(allocator, schema.fields);
}

const testing = std.testing;
const PrimitiveArray = @import("../primitive_array.zig").PrimitiveArray;
const Utf8Array = @import("../varbinary_array.zig").VarBinaryArray(true, i32);
const StructArray = @import("../struct_array.zig").StructArray;

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
    try testing.expect(reader.schema.field(2).data_type.list.data_type.equals(.int64));

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

test "reader returns errors on corrupt stream bytes instead of crashing" {
    const allocator = testing.allocator;
    const copy = try allocator.dupe(u8, &pyarrow_stream);
    defer allocator.free(copy);
    for (0..copy.len) |i| {
        const original = copy[i];
        defer copy[i] = original;
        copy[i] = 0xff;
        var reader = StreamReader.init(allocator, copy) catch continue;
        defer reader.deinit();
        while (reader.next() catch null) |decoded| {
            var data = decoded;
            data.deinit();
        }
    }
}

// A pyarrow 21 stream with a dictionary-encoded column:
// category: dictionary<int8 -> utf8> and n: int32 not null. One dictionary
// batch delivers ["red", "green", "blue"], then two record batches hold
// indices {[0, 1, null, 0], n [1, 2, 3, 4]} and {[2, 2], n [5, 6]}.
const pyarrow_dictionary_stream = [_]u8{
    0xff, 0xff, 0xff, 0xff, 0xd8, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x00,
    0x0c, 0x00, 0x06, 0x00, 0x05, 0x00, 0x08, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x01, 0x04, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x74, 0xff, 0xff, 0xff, 0x04, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x54, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x10, 0x00, 0x14, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x07, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    0x10, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x6e, 0x00, 0x00, 0x00, 0xa8, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
    0x20, 0x00, 0x00, 0x00, 0x10, 0x00, 0x18, 0x00, 0x08, 0x00, 0x06, 0x00, 0x07, 0x00, 0x0c, 0x00,
    0x10, 0x00, 0x14, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x05, 0x14, 0x00, 0x00, 0x00,
    0x48, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x63, 0x61, 0x74, 0x65, 0x67, 0x6f, 0x72, 0x79, 0x00, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x08, 0x00, 0x00, 0x00, 0x04, 0x00, 0x08, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x0c, 0x00, 0x08, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x00, 0x00, 0x00, 0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0xa8, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0c, 0x00, 0x14, 0x00, 0x06, 0x00, 0x05, 0x00, 0x08, 0x00, 0x0c, 0x00, 0x0c, 0x00, 0x00, 0x00,
    0x00, 0x02, 0x04, 0x00, 0x14, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x04, 0x00, 0x08, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x0a, 0x00, 0x18, 0x00, 0x0c, 0x00, 0x04, 0x00, 0x08, 0x00, 0x0a, 0x00, 0x00, 0x00,
    0x4c, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00,
    0x72, 0x65, 0x64, 0x67, 0x72, 0x65, 0x65, 0x6e, 0x62, 0x6c, 0x75, 0x65, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0xb8, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0c, 0x00, 0x16, 0x00, 0x06, 0x00, 0x05, 0x00, 0x08, 0x00, 0x0c, 0x00, 0x0c, 0x00, 0x00, 0x00,
    0x00, 0x03, 0x04, 0x00, 0x18, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x0a, 0x00, 0x18, 0x00, 0x0c, 0x00, 0x04, 0x00, 0x08, 0x00, 0x0a, 0x00, 0x00, 0x00,
    0x5c, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0xb8, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0c, 0x00, 0x16, 0x00, 0x06, 0x00, 0x05, 0x00, 0x08, 0x00, 0x0c, 0x00, 0x0c, 0x00, 0x00, 0x00,
    0x00, 0x03, 0x04, 0x00, 0x18, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x0a, 0x00, 0x18, 0x00, 0x0c, 0x00, 0x04, 0x00, 0x08, 0x00, 0x0a, 0x00, 0x00, 0x00,
    0x5c, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
};

test "reader decodes a dictionary-encoded stream written by pyarrow" {
    const allocator = testing.allocator;

    var reader = try StreamReader.init(allocator, &pyarrow_dictionary_stream);
    defer reader.deinit();

    const category = reader.schema.field(0);
    try testing.expect(category.data_type == .dictionary);
    try testing.expectEqual(@as(i64, 0), category.data_type.dictionary.id);
    try testing.expect(category.data_type.dictionary.index.equals(.int8));
    try testing.expect(category.data_type.dictionary.value.equals(.utf8));

    var first = (try reader.next()) orelse return error.MissingBatch;
    defer first.deinit();
    try testing.expectEqual(@as(usize, 4), first.length);
    const cat1 = first.child(0);
    try testing.expect(!cat1.isValid(2));
    const indices1 = cat1.values(i8);
    try testing.expectEqual(@as(i8, 0), indices1[0]);
    try testing.expectEqual(@as(i8, 1), indices1[1]);
    try testing.expectEqual(@as(i8, 0), indices1[3]);
    const dict = cat1.dictionary.?;
    try testing.expectEqual(@as(usize, 3), dict.length);
    try testing.expectEqualStrings("red", dict.valueBytes(0));
    try testing.expectEqualStrings("green", dict.valueBytes(1));
    try testing.expectEqualStrings("blue", dict.valueBytes(2));
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4 }, first.child(1).values(i32));

    var second = (try reader.next()) orelse return error.MissingBatch;
    defer second.deinit();
    try testing.expectEqual(@as(i8, 2), second.child(0).values(i8)[0]);
    try testing.expectEqualStrings("blue", second.child(0).dictionary.?.valueBytes(2));
    try testing.expectEqualSlices(i32, &.{ 5, 6 }, second.child(1).values(i32));

    try testing.expectEqual(@as(?ArrayData, null), try reader.next());
}

/// A hand-built dictionary column: indices into ["red", "green", "blue"].
fn buildDictionaryColumn(allocator: Allocator, indices_bytes: []const i8, validity_byte: ?u8) !ArrayData {
    var offsets = try Buffer.alloc(allocator, 4 * @sizeOf(i32));
    const off = offsets.items(i32);
    off[0] = 0;
    off[1] = 3;
    off[2] = 8;
    off[3] = 12;
    const values = try Buffer.dupe(allocator, "redgreenblue");
    const dict_buffers = try allocator.alloc(?Buffer, 3);
    dict_buffers[0] = null;
    dict_buffers[1] = offsets;
    dict_buffers[2] = values;
    const dict_values = try ArrayData.init(allocator, .utf8, 3, 0, dict_buffers, try allocator.alloc(ArrayData, 0));

    var indices = try Buffer.alloc(allocator, indices_bytes.len);
    @memcpy(indices.items(i8)[0..indices_bytes.len], indices_bytes);
    const buffers = try allocator.alloc(?Buffer, 2);
    if (validity_byte) |byte| {
        var validity = try Buffer.allocZeroed(allocator, 1);
        validity.data[0] = byte;
        buffers[0] = validity;
    } else {
        buffers[0] = null;
    }
    buffers[1] = indices;
    var null_count: usize = 0;
    if (validity_byte) |byte| null_count = indices_bytes.len - @popCount(byte & ((@as(u8, 1) << @intCast(indices_bytes.len)) - 1));

    const dict_type = try zarr_datatype.DataType.initDictionary(allocator, 0, .int8, .utf8, false);
    return ArrayData.initDictionary(allocator, dict_type, indices_bytes.len, null_count, buffers, dict_values);
}

const zarr_datatype = @import("../datatype.zig");

fn buildDictionaryBatchData(allocator: Allocator, indices_bytes: []const i8, validity_byte: ?u8) !ArrayData {
    const column = try buildDictionaryColumn(allocator, indices_bytes, validity_byte);
    const root_buffers = try allocator.alloc(?Buffer, 1);
    root_buffers[0] = null;
    const children = try allocator.alloc(ArrayData, 1);
    children[0] = column;
    var struct_type = try DataType.initStruct(allocator, &.{.utf8});
    // The column is dictionary-encoded; the root type must match it.
    struct_type.deinit(allocator);
    var dict_type = try zarr_datatype.DataType.initDictionary(allocator, 0, .int8, .utf8, false);
    defer dict_type.deinit(allocator);
    const root_type = try DataType.initStruct(allocator, &.{dict_type});
    return ArrayData.init(allocator, root_type, indices_bytes.len, 0, root_buffers, children);
}

test "dictionary-encoded batches round-trip through the stream" {
    const allocator = testing.allocator;

    var dict_type = try zarr_datatype.DataType.initDictionary(allocator, 0, .int8, .utf8, false);
    defer dict_type.deinit(allocator);
    var category = try Field.init(allocator, "category", dict_type, true);
    defer category.deinit(allocator);
    var schema = try Schema.init(allocator, &.{category});
    defer schema.deinit(allocator);

    var batch1 = try buildDictionaryBatchData(allocator, &.{ 0, 1, 2, 0 }, 0b1011);
    defer batch1.deinit();
    var batch2 = try buildDictionaryBatchData(allocator, &.{ 2, 2 }, null);
    defer batch2.deinit();

    var writer = try StreamWriter.init(allocator, schema);
    defer writer.deinit();
    try writer.writeBatch(batch1);
    try writer.writeBatch(batch2); // the same dictionary: emitted only once
    const bytes = try writer.finish();
    defer allocator.free(bytes);

    var reader = try StreamReader.init(allocator, bytes);
    defer reader.deinit();
    try testing.expect(schema.equals(reader.schema));

    var first = (try reader.next()) orelse return error.MissingBatch;
    defer first.deinit();
    try first.validateFull();
    const cat = first.child(0);
    try testing.expectEqualSlices(i8, &.{ 0, 1, 2, 0 }, cat.values(i8));
    try testing.expect(!cat.isValid(2));
    try testing.expectEqualStrings("red", cat.dictionary.?.valueBytes(0));
    try testing.expectEqualStrings("blue", cat.dictionary.?.valueBytes(2));

    var second = (try reader.next()) orelse return error.MissingBatch;
    defer second.deinit();
    try testing.expectEqualSlices(i8, &.{ 2, 2 }, second.child(0).values(i8));
    try testing.expectEqualStrings("green", second.child(0).dictionary.?.valueBytes(1));

    try testing.expectEqual(@as(?ArrayData, null), try reader.next());
}

test "a changed dictionary in a later batch is refused" {
    const allocator = testing.allocator;

    var dict_type = try zarr_datatype.DataType.initDictionary(allocator, 0, .int8, .utf8, false);
    defer dict_type.deinit(allocator);
    var category = try Field.init(allocator, "category", dict_type, true);
    defer category.deinit(allocator);
    var schema = try Schema.init(allocator, &.{category});
    defer schema.deinit(allocator);

    var batch1 = try buildDictionaryBatchData(allocator, &.{0}, null);
    defer batch1.deinit();
    var batch2 = try buildDictionaryBatchData(allocator, &.{0}, null);
    defer batch2.deinit();
    // Change one dictionary byte: "red" becomes "rad".
    @constCast(batch2.child(0).dictionary.?.buffers[2].?.data)[1] = 'a';

    var writer = try StreamWriter.init(allocator, schema);
    defer writer.deinit();
    try writer.writeBatch(batch1);
    try testing.expectError(error.UnsupportedType, writer.writeBatch(batch2));
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
