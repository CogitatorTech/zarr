//! Arrow IPC file format.
//!
//! A file is the streaming format wrapped for random access: the magic
//! "ARROW1" plus two padding bytes, the stream's messages including the
//! end-of-stream marker, then a FlatBuffers `Footer` table (from the Arrow
//! format's File.fbs), the footer's byte length as an int32, and the magic
//! again. The footer repeats the schema and lists each record batch message
//! as a `Block` (offset, metadata length including the 8-byte envelope
//! prefix, and body length), so a reader can seek straight to any batch.
//!
//! `FileWriter` builds a file in memory, and `FileReader` opens one and reads
//! batches by index. Dictionary batches are not implemented; a footer that
//! lists any is reported as `error.UnsupportedMessage`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flatbuffers = @import("flatbuffers.zig");
const Builder = flatbuffers.Builder;
const ipc_schema = @import("schema.zig");
const batch = @import("batch.zig");
const stream = @import("stream.zig");
const Schema = @import("../schema.zig").Schema;
const DataType = @import("../datatype.zig").DataType;
const ArrayData = @import("../array_data.zig").ArrayData;

/// The 6-byte magic that opens and closes an Arrow file.
pub const magic = "ARROW1";

/// Errors from reading a file.
pub const DecodeError = error{
    /// The bytes are not an Arrow file: wrong magic, or a footer that is
    /// missing, truncated, or inconsistent.
    InvalidFile,
} || stream.DecodeError;

// `Footer` table slots in File.fbs: 0 version, 1 schema, 2 dictionaries,
// 3 record batches, 4 custom metadata.
const footer_slot_version = 0;
const footer_slot_schema = 1;
const footer_slot_dictionaries = 2;
const footer_slot_record_batches = 3;

/// Byte size of the `Block` struct: an i64 offset, an i32 metadata length
/// padded to 8, and an i64 body length.
const block_size = 24;

/// Builds an Arrow IPC file in memory: the opening magic and schema message,
/// the batches written through `writeBatch`, and the end-of-stream marker,
/// footer, and closing magic on `finish`.
pub const FileWriter = struct {
    allocator: Allocator,
    buf: std.ArrayListUnmanaged(u8),
    /// One entry per batch message: offset, metadata length, and body length,
    /// written into the footer's record batch blocks.
    blocks: std.ArrayListUnmanaged(Block),
    /// The file's schema, cloned at `init` and written again in the footer.
    schema: Schema,

    const Block = struct { offset: i64, metadata_length: i32, body_length: i64 };

    /// Starts a file by writing the magic and the schema message. Release
    /// with `deinit`.
    pub fn init(allocator: Allocator, schema: Schema) Allocator.Error!FileWriter {
        var self = FileWriter{
            .allocator = allocator,
            .buf = .empty,
            .blocks = .empty,
            .schema = try schema.clone(allocator),
        };
        errdefer self.deinit();
        // The opening magic, padded to the 8-byte alignment of the first
        // message.
        try self.buf.appendSlice(allocator, magic ++ "\x00\x00");
        const msg = try stream.encodeSchemaMessage(allocator, self.schema);
        defer allocator.free(msg);
        try self.buf.appendSlice(allocator, msg);
        return self;
    }

    pub fn deinit(self: *FileWriter) void {
        self.buf.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        self.schema.deinit(self.allocator);
        self.* = undefined;
    }

    /// Appends one record batch message and records its footer block. `data`
    /// is the struct-typed columns of a batch, as produced by
    /// `RecordBatch.toData`, and must match the schema the file was started
    /// with; the caller keeps ownership.
    pub fn writeBatch(self: *FileWriter, data: ArrayData) Allocator.Error!void {
        const msg = try stream.encodeBatchMessage(self.allocator, data);
        defer self.allocator.free(msg);
        const body_length = batch.bodyLength(data);
        try self.blocks.append(self.allocator, .{
            .offset = @intCast(self.buf.items.len),
            .metadata_length = @intCast(msg.len - body_length),
            .body_length = @intCast(body_length),
        });
        errdefer _ = self.blocks.pop();
        try self.buf.appendSlice(self.allocator, msg);
    }

    /// Appends the end-of-stream marker, the footer, its length, and the
    /// closing magic, and returns the finished file, owned by the caller.
    /// After `finish`, only `deinit` may be called.
    pub fn finish(self: *FileWriter) Allocator.Error![]u8 {
        try self.buf.appendSlice(self.allocator, &stream.end_of_stream);

        var b = Builder.init(self.allocator);
        defer b.deinit();
        const schema_off = try ipc_schema.writeSchema(&b, self.schema);
        try b.startVector(block_size, self.blocks.items.len, 8);
        var i = self.blocks.items.len;
        while (i > 0) {
            i -= 1;
            var bytes = [_]u8{0} ** block_size;
            std.mem.writeInt(i64, bytes[0..8], self.blocks.items[i].offset, .little);
            std.mem.writeInt(i32, bytes[8..12], self.blocks.items[i].metadata_length, .little);
            // Bytes 12 to 16 are the struct's alignment padding.
            std.mem.writeInt(i64, bytes[16..24], self.blocks.items[i].body_length, .little);
            try b.pushStructBytes(&bytes);
        }
        const batches_off = try b.endVector(self.blocks.items.len);

        b.startTable();
        try b.addScalar(i16, footer_slot_version, metadata_version_v5, 0);
        try b.addOffset(footer_slot_schema, schema_off);
        try b.addOffset(footer_slot_record_batches, batches_off);
        const footer = try b.finish(try b.endTable());

        try self.buf.appendSlice(self.allocator, footer);
        var footer_len: [4]u8 = undefined;
        std.mem.writeInt(u32, &footer_len, @intCast(footer.len), .little);
        try self.buf.appendSlice(self.allocator, &footer_len);
        try self.buf.appendSlice(self.allocator, magic);
        return self.buf.toOwnedSlice(self.allocator);
    }
};

/// `MetadataVersion.V5`, matching what the stream layer writes on messages.
const metadata_version_v5: i16 = 4;

/// Opens an Arrow IPC file for random access. Borrows `bytes`; the decoded
/// batches own their memory.
pub const FileReader = struct {
    allocator: Allocator,
    bytes: []const u8,
    /// The file's schema, owned by this reader.
    schema: Schema,
    /// The struct type over the schema's columns, used to decode each batch;
    /// owned by this reader.
    column_type: DataType,
    /// The footer table, viewing into `bytes`.
    footer: flatbuffers.Table,
    /// Number of record batch blocks in the footer.
    count: usize,

    /// Checks the magic at both ends and decodes the footer and schema.
    /// Release with `deinit`.
    pub fn init(allocator: Allocator, bytes: []const u8) DecodeError!FileReader {
        // The smallest possible file: opening magic plus padding, an empty
        // footer, the footer length, and the closing magic.
        if (bytes.len < 8 + 4 + magic.len) return error.InvalidFile;
        if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidFile;
        if (!std.mem.eql(u8, bytes[bytes.len - magic.len ..], magic)) return error.InvalidFile;

        const length_pos = bytes.len - magic.len - 4;
        const footer_length = std.mem.readInt(i32, bytes[length_pos..][0..4], .little);
        if (footer_length <= 0) return error.InvalidFile;
        const footer_len: usize = @intCast(footer_length);
        // The footer must fit between the 8-byte opening and its own length.
        if (footer_len > length_pos - 8) return error.InvalidFile;
        const footer = flatbuffers.getRoot(bytes[length_pos - footer_len .. length_pos]);

        if (footer.vectorLen(footer_slot_dictionaries) != 0) return error.UnsupportedMessage;
        const schema_table = footer.readTable(footer_slot_schema) orelse return error.InvalidFile;
        var schema = try ipc_schema.readSchema(allocator, schema_table);
        errdefer schema.deinit(allocator);
        const column_type = try stream.columnTypeOf(allocator, schema);
        return .{
            .allocator = allocator,
            .bytes = bytes,
            .schema = schema,
            .column_type = column_type,
            .footer = footer,
            .count = footer.vectorLen(footer_slot_record_batches),
        };
    }

    pub fn deinit(self: *FileReader) void {
        self.schema.deinit(self.allocator);
        self.column_type.deinit(self.allocator);
        self.* = undefined;
    }

    /// Number of record batches in the file.
    pub fn batchCount(self: FileReader) usize {
        return self.count;
    }

    /// Decodes the columns of batch `i`, using the footer's block to seek to
    /// its message. The caller owns the returned data and must release it
    /// with `deinit`.
    pub fn readBatch(self: FileReader, i: usize) DecodeError!ArrayData {
        std.debug.assert(i < self.count);
        const pos = self.footer.vectorStructPos(footer_slot_record_batches, i, block_size);
        const offset = self.footer.scalarAt(i64, pos);
        const metadata_length = self.footer.scalarAt(i32, pos + 8);
        const body_length = self.footer.scalarAt(i64, pos + 16);
        if (offset < 0 or metadata_length < 0 or body_length < 0) return error.InvalidFile;

        const start: u64 = @intCast(offset);
        const total: u64 = @as(u64, @intCast(metadata_length)) + @as(u64, @intCast(body_length));
        if (start + total > self.bytes.len) return error.InvalidFile;
        const msg = self.bytes[@intCast(start)..][0..@intCast(total)];
        return stream.decodeBatchMessage(self.allocator, msg, self.column_type);
    }
};

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

test "file round-trips a schema and two batches with random access" {
    const allocator = testing.allocator;
    var schema = try buildPersonSchema(allocator);
    defer schema.deinit(allocator);
    var batch1 = try buildPersonData(allocator, &.{ 1, null, 3 }, &.{ "a", null, "ccc" });
    defer batch1.deinit();
    var batch2 = try buildPersonData(allocator, &.{7}, &.{"x"});
    defer batch2.deinit();

    var writer = try FileWriter.init(allocator, schema);
    defer writer.deinit();
    try writer.writeBatch(batch1);
    try writer.writeBatch(batch2);
    const bytes = try writer.finish();
    defer allocator.free(bytes);

    var reader = try FileReader.init(allocator, bytes);
    defer reader.deinit();

    try testing.expect(schema.equals(reader.schema));
    try testing.expectEqual(@as(usize, 2), reader.batchCount());

    // Out of order, to prove access is random rather than sequential.
    var second = try reader.readBatch(1);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), second.length);
    try testing.expectEqual(@as(i32, 7), second.child(0).values(i32)[0]);
    try testing.expectEqualStrings("x", second.child(1).valueBytes(0));

    var first = try reader.readBatch(0);
    defer first.deinit();
    try testing.expectEqual(@as(usize, 3), first.length);
    try testing.expectEqual(@as(i32, 1), first.child(0).values(i32)[0]);
    try testing.expect(!first.child(0).isValid(1));
    try testing.expectEqualStrings("ccc", first.child(1).valueBytes(2));
}

test "file with no batches round-trips" {
    const allocator = testing.allocator;
    var schema = try buildPersonSchema(allocator);
    defer schema.deinit(allocator);

    var writer = try FileWriter.init(allocator, schema);
    defer writer.deinit();
    const bytes = try writer.finish();
    defer allocator.free(bytes);

    var reader = try FileReader.init(allocator, bytes);
    defer reader.deinit();
    try testing.expect(schema.equals(reader.schema));
    try testing.expectEqual(@as(usize, 0), reader.batchCount());
}

test "reader rejects bytes that are not an Arrow file" {
    try testing.expectError(error.InvalidFile, FileReader.init(testing.allocator, "not an arrow file at all"));
    try testing.expectError(error.InvalidFile, FileReader.init(testing.allocator, ""));
}

test "reader rejects a file with a truncated footer" {
    const allocator = testing.allocator;
    var schema = try buildPersonSchema(allocator);
    defer schema.deinit(allocator);
    var writer = try FileWriter.init(allocator, schema);
    defer writer.deinit();
    const bytes = try writer.finish();
    defer allocator.free(bytes);

    // Chopping the tail removes the closing magic.
    try testing.expectError(error.InvalidFile, FileReader.init(allocator, bytes[0 .. bytes.len - 4]));
}

// The bytes of a pyarrow IPC file, generated with pyarrow 21 via
// `pyarrow.ipc.new_file`. Schema: (id: int32 not null, name: utf8). Two
// batches: {[1, 2, 3], ["a", null, "ccc"]} and {[7], ["x"]}.
const pyarrow_file = [_]u8{
    0x41, 0x52, 0x52, 0x4f, 0x57, 0x31, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xb8, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x0c, 0x00, 0x06, 0x00, 0x05, 0x00, 0x08, 0x00,
    0x0a, 0x00, 0x00, 0x00, 0x00, 0x01, 0x04, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x08, 0x00, 0x08, 0x00,
    0x00, 0x00, 0x04, 0x00, 0x08, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x54, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x10, 0x00, 0x14, 0x00, 0x08, 0x00, 0x06, 0x00,
    0x07, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x05,
    0x10, 0x00, 0x00, 0x00, 0x1c, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x6e, 0x61, 0x6d, 0x65, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x04, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x10, 0x00, 0x14, 0x00, 0x08, 0x00, 0x00, 0x00, 0x07, 0x00, 0x0c, 0x00,
    0x00, 0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x10, 0x00, 0x00, 0x00,
    0x1c, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x69, 0x64, 0x00, 0x00, 0x08, 0x00, 0x0c, 0x00, 0x08, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x20, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xc8, 0x00, 0x00, 0x00,
    0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x16, 0x00, 0x06, 0x00, 0x05, 0x00,
    0x08, 0x00, 0x0c, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x03, 0x04, 0x00, 0x18, 0x00, 0x00, 0x00,
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x18, 0x00, 0x0c, 0x00,
    0x04, 0x00, 0x08, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x6c, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x61, 0x63, 0x63, 0x63, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xc8, 0x00, 0x00, 0x00,
    0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x16, 0x00, 0x06, 0x00, 0x05, 0x00,
    0x08, 0x00, 0x0c, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x03, 0x04, 0x00, 0x18, 0x00, 0x00, 0x00,
    0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x18, 0x00, 0x0c, 0x00,
    0x04, 0x00, 0x08, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x6c, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x78, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x14, 0x00,
    0x06, 0x00, 0x08, 0x00, 0x0c, 0x00, 0x10, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00,
    0x4c, 0x00, 0x00, 0x00, 0x3c, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0xc8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xd0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc8, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xd0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x08, 0x00, 0x00, 0x00, 0x04, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x54, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x14, 0x00, 0x08, 0x00, 0x06, 0x00, 0x07, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x10, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x05, 0x10, 0x00, 0x00, 0x00, 0x1c, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x6e, 0x61, 0x6d, 0x65,
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x00, 0x00, 0x10, 0x00, 0x14, 0x00,
    0x08, 0x00, 0x00, 0x00, 0x07, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x02, 0x10, 0x00, 0x00, 0x00, 0x1c, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x69, 0x64, 0x00, 0x00, 0x08, 0x00, 0x0c, 0x00,
    0x08, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x20, 0x00, 0x00, 0x00,
    0xf8, 0x00, 0x00, 0x00, 0x41, 0x52, 0x52, 0x4f, 0x57, 0x31,
};

test "reader opens a file written by pyarrow" {
    const allocator = testing.allocator;

    var reader = try FileReader.init(allocator, &pyarrow_file);
    defer reader.deinit();

    try testing.expectEqual(@as(usize, 2), reader.schema.fieldCount());
    try testing.expectEqualStrings("id", reader.schema.field(0).name);
    try testing.expect(!reader.schema.field(0).nullable);
    try testing.expect(reader.schema.field(1).data_type.equals(.utf8));
    try testing.expectEqual(@as(usize, 2), reader.batchCount());

    var second = try reader.readBatch(1);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), second.length);
    try testing.expectEqual(@as(i32, 7), second.child(0).values(i32)[0]);
    try testing.expectEqualStrings("x", second.child(1).valueBytes(0));

    var first = try reader.readBatch(0);
    defer first.deinit();
    try testing.expectEqual(@as(usize, 3), first.length);
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, first.child(0).values(i32));
    try testing.expect(!first.child(1).isValid(1));
    try testing.expectEqualStrings("ccc", first.child(1).valueBytes(2));
}

test "file serialization leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var schema = try buildPersonSchema(allocator);
            defer schema.deinit(allocator);
            var data = try buildPersonData(allocator, &.{ 1, null }, &.{ "a", null });
            defer data.deinit();

            var writer = try FileWriter.init(allocator, schema);
            defer writer.deinit();
            try writer.writeBatch(data);
            const bytes = try writer.finish();
            defer allocator.free(bytes);

            var reader = try FileReader.init(allocator, bytes);
            defer reader.deinit();
            var back = try reader.readBatch(0);
            back.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}
