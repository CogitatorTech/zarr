//! Arrow IPC schema serialization.
//!
//! Encodes a `Schema` into the FlatBuffers `Schema` table defined by the Arrow
//! format's Schema.fbs, and decodes it back. This is the metadata layer of the
//! IPC format: a higher layer wraps the encoded table in a `Message` and the
//! encapsulated message envelope, which `ipc/message.zig` handles.
//!
//! Field ids and union member numbers mirror Schema.fbs, which is the
//! authority for this module. Spec types that Zarr does not implement yet,
//! such as decimal and union, decode to `error.UnsupportedType`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flatbuffers = @import("flatbuffers.zig");
const Builder = flatbuffers.Builder;
const Table = flatbuffers.Table;
const Offset = flatbuffers.Offset;
const schema_mod = @import("../schema.zig");
const Schema = schema_mod.Schema;
const Field = schema_mod.Field;
const datatype = @import("../datatype.zig");
const DataType = datatype.DataType;

/// Errors from decoding an encoded schema.
pub const DecodeError = error{
    /// The schema uses a spec type or parameter Zarr does not implement.
    UnsupportedType,
    /// The schema declares big-endian data, which Zarr does not handle.
    UnsupportedEndianness,
    /// The buffer does not describe a well-formed schema.
    MalformedSchema,
} || flatbuffers.ReadError || Allocator.Error;

// Members of the `Type` union in Schema.fbs, in declaration order.
// FlatBuffers numbers union members from 1; 0 means absent. Members Zarr does
// not implement (Decimal 7, Time 9, Interval 11, Union 14, FixedSizeBinary 15,
// FixedSizeList 16, Map 17, Duration 18, and the members past LargeList) have
// no constant here and decode to `error.UnsupportedType`.
const type_null: u8 = 1;
const type_int: u8 = 2;
const type_floating_point: u8 = 3;
const type_binary: u8 = 4;
const type_utf8: u8 = 5;
const type_bool: u8 = 6;
const type_date: u8 = 8;
const type_timestamp: u8 = 10;
const type_list: u8 = 12;
const type_struct: u8 = 13;
const type_large_binary: u8 = 19;
const type_large_utf8: u8 = 20;

// `Field` table slots in Schema.fbs: 0 name, 1 nullable, 2 type tag, 3 type,
// 4 dictionary, 5 children, 6 custom metadata.
const field_slot_name = 0;
const field_slot_nullable = 1;
const field_slot_type_tag = 2;
const field_slot_type = 3;
const field_slot_children = 5;

// `Schema` table slots in Schema.fbs: 0 endianness, 1 fields,
// 2 custom metadata, 3 features.
const schema_slot_endianness = 0;
const schema_slot_fields = 1;

/// Writes `schema` as a FlatBuffers `Schema` table into `b` and returns its
/// offset. Used by the message layer to embed a schema in a `Message`.
pub fn writeSchema(b: *Builder, schema: Schema) Allocator.Error!Offset {
    const n = schema.fields.len;
    const offsets = try b.allocator.alloc(Offset, n);
    defer b.allocator.free(offsets);
    for (schema.fields, 0..) |f, i| {
        offsets[i] = try writeField(b, f.name, f.data_type, f.nullable);
    }

    try b.startVector(4, n, 4);
    var i = n;
    while (i > 0) {
        i -= 1;
        try b.pushOffsetElement(offsets[i]);
    }
    const fields_off = try b.endVector(n);

    b.startTable();
    // Endianness is omitted: the default is little, the only order Zarr writes.
    try b.addOffset(schema_slot_fields, fields_off);
    return b.endTable();
}

/// Writes one `Field` table and returns its offset. Child names and
/// nullability come from the child fields nested types carry, so struct
/// field names and list element names round-trip.
fn writeField(b: *Builder, name: []const u8, data_type: DataType, nullable: bool) Allocator.Error!Offset {
    var children_off: Offset = 0;
    switch (data_type) {
        .list => |child| {
            const item = try writeField(b, child.name, child.data_type, child.nullable);
            try b.startVector(4, 1, 4);
            try b.pushOffsetElement(item);
            children_off = try b.endVector(1);
        },
        .@"struct" => |fields| {
            const offsets = try b.allocator.alloc(Offset, fields.len);
            defer b.allocator.free(offsets);
            for (fields, 0..) |field, i| {
                offsets[i] = try writeField(b, field.name, field.data_type, field.nullable);
            }
            try b.startVector(4, fields.len, 4);
            var i = fields.len;
            while (i > 0) {
                i -= 1;
                try b.pushOffsetElement(offsets[i]);
            }
            children_off = try b.endVector(fields.len);
        },
        else => {},
    }

    const ty = try writeType(b, data_type);
    const name_off = try b.createString(name);

    b.startTable();
    try b.addOffset(field_slot_name, name_off);
    try b.addScalar(bool, field_slot_nullable, nullable, false);
    try b.addScalar(u8, field_slot_type_tag, ty.tag, 0);
    try b.addOffset(field_slot_type, ty.offset);
    try b.addOffset(field_slot_children, children_off);
    return b.endTable();
}

const TypeOffset = struct { tag: u8, offset: Offset };

/// Writes the `Type` union member table for `data_type` and returns its union
/// tag and offset.
fn writeType(b: *Builder, data_type: DataType) Allocator.Error!TypeOffset {
    return switch (data_type) {
        .null => writeEmptyType(b, type_null),
        .boolean => writeEmptyType(b, type_bool),
        .int8 => writeIntType(b, 8, true),
        .int16 => writeIntType(b, 16, true),
        .int32 => writeIntType(b, 32, true),
        .int64 => writeIntType(b, 64, true),
        .uint8 => writeIntType(b, 8, false),
        .uint16 => writeIntType(b, 16, false),
        .uint32 => writeIntType(b, 32, false),
        .uint64 => writeIntType(b, 64, false),
        // FloatingPoint.precision: HALF 0, SINGLE 1, DOUBLE 2.
        .float16 => writeScalarType(b, type_floating_point, 0, 0),
        .float32 => writeScalarType(b, type_floating_point, 1, 0),
        .float64 => writeScalarType(b, type_floating_point, 2, 0),
        .binary => writeEmptyType(b, type_binary),
        .utf8 => writeEmptyType(b, type_utf8),
        .large_binary => writeEmptyType(b, type_large_binary),
        .large_utf8 => writeEmptyType(b, type_large_utf8),
        // Date.unit: DAY 0, MILLISECOND 1 (the schema default).
        .date32 => writeScalarType(b, type_date, 0, 1),
        .date64 => writeScalarType(b, type_date, 1, 1),
        // Timestamp.unit: SECOND 0 through NANOSECOND 3, matching the
        // declaration order of `TimeUnit`. The timezone is omitted, since
        // Zarr's timestamp carries none.
        .timestamp => |unit| writeScalarType(b, type_timestamp, @intFromEnum(unit), 0),
        .list => writeEmptyType(b, type_list),
        .@"struct" => writeEmptyType(b, type_struct),
    };
}

/// Writes a `Type` member with no fields, such as `Utf8` or `List`.
fn writeEmptyType(b: *Builder, tag: u8) Allocator.Error!TypeOffset {
    b.startTable();
    return .{ .tag = tag, .offset = try b.endTable() };
}

/// Writes a `Type` member whose only used field is one i16 enum at slot 0,
/// such as `FloatingPoint`, `Date`, or `Timestamp`.
fn writeScalarType(b: *Builder, tag: u8, value: i16, default: i16) Allocator.Error!TypeOffset {
    b.startTable();
    try b.addScalar(i16, 0, value, default);
    return .{ .tag = tag, .offset = try b.endTable() };
}

/// Writes an `Int` type table: bit width at slot 0, signedness at slot 1.
fn writeIntType(b: *Builder, bits: i32, signed: bool) Allocator.Error!TypeOffset {
    b.startTable();
    try b.addScalar(i32, 0, bits, 0);
    try b.addScalar(bool, 1, signed, false);
    return .{ .tag = type_int, .offset = try b.endTable() };
}

/// Encodes `schema` as a standalone FlatBuffers buffer with the `Schema`
/// table as the root. The caller owns the returned bytes.
pub fn encode(allocator: Allocator, schema: Schema) Allocator.Error![]u8 {
    var b = Builder.init(allocator);
    defer b.deinit();
    const root = try writeSchema(&b, schema);
    const bytes = try b.finish(root);
    return allocator.dupe(u8, bytes);
}

/// Reads a `Schema` from a FlatBuffers `Schema` table. The caller owns the
/// returned schema and must release it with `deinit`. Used by the message
/// layer, which locates the table inside a `Message`. The table is assumed to
/// be well-formed FlatBuffers; only Arrow-level problems are reported as
/// errors.
pub fn readSchema(allocator: Allocator, table: Table) DecodeError!Schema {
    // Endianness: Little 0 (the default), Big 1.
    if (try table.readScalar(i16, schema_slot_endianness, 0) != 0) {
        return error.UnsupportedEndianness;
    }

    const n = try table.vectorLen(schema_slot_fields);
    const fields = try allocator.alloc(Field, n);
    var finished: usize = 0;
    errdefer {
        for (fields[0..finished]) |*f| f.deinit(allocator);
        allocator.free(fields);
    }
    for (0..n) |i| {
        fields[i] = try readField(allocator, try table.vectorTable(schema_slot_fields, i), 0);
        finished += 1;
    }
    return .{ .fields = fields };
}

/// Reads one `Field` table into an owned `Field`, recursing through `readType`
/// into child fields. A field with no name gets an empty one, since
/// `Field.name` is not optional. `depth` bounds the recursion; see
/// `max_type_nesting`.
fn readField(allocator: Allocator, table: Table, depth: usize) DecodeError!Field {
    if (depth > max_type_nesting) return error.MalformedSchema;
    var data_type = try readType(allocator, table, depth);
    errdefer data_type.deinit(allocator);
    // All fallible reads happen before the name is duped, so nothing leaks
    // when one of them fails.
    const nullable = try table.readScalar(bool, field_slot_nullable, false);
    const raw_name = (try table.readString(field_slot_name)) orelse "";
    const name = try allocator.dupe(u8, raw_name);
    return .{ .name = name, .data_type = data_type, .nullable = nullable };
}

/// Nesting bound for `readField`. A hostile buffer can point a field's child
/// at the field itself, which would recurse forever; real schemas stay far
/// below this depth.
const max_type_nesting = 64;

/// Reads the `Type` union of a `Field` table, recursing into the field's
/// children for list and struct. The nested type's `Type` members carry no
/// child information themselves; children live on the enclosing field and
/// are read as full fields, keeping their names and nullability.
fn readType(allocator: Allocator, field_table: Table, depth: usize) DecodeError!DataType {
    switch (try field_table.readScalar(u8, field_slot_type_tag, 0)) {
        type_null => return .null,
        type_bool => return .boolean,
        type_binary => return .binary,
        type_utf8 => return .utf8,
        type_large_binary => return .large_binary,
        type_large_utf8 => return .large_utf8,
        type_int => {
            const t = (try field_table.readTable(field_slot_type)) orelse return error.MalformedSchema;
            const bits = try t.readScalar(i32, 0, 0);
            if (try t.readScalar(bool, 1, false)) {
                return switch (bits) {
                    8 => .int8,
                    16 => .int16,
                    32 => .int32,
                    64 => .int64,
                    else => error.UnsupportedType,
                };
            }
            return switch (bits) {
                8 => .uint8,
                16 => .uint16,
                32 => .uint32,
                64 => .uint64,
                else => error.UnsupportedType,
            };
        },
        type_floating_point => {
            const t = (try field_table.readTable(field_slot_type)) orelse return error.MalformedSchema;
            return switch (try t.readScalar(i16, 0, 0)) {
                0 => .float16,
                1 => .float32,
                2 => .float64,
                else => error.UnsupportedType,
            };
        },
        type_date => {
            const t = (try field_table.readTable(field_slot_type)) orelse return error.MalformedSchema;
            return switch (try t.readScalar(i16, 0, 1)) {
                0 => .date32,
                1 => .date64,
                else => error.UnsupportedType,
            };
        },
        type_timestamp => {
            const t = (try field_table.readTable(field_slot_type)) orelse return error.MalformedSchema;
            // Zarr's timestamp has no timezone, so a zoned timestamp cannot be
            // represented; dropping the zone would change the data's meaning.
            if (try t.readString(1)) |tz| {
                if (tz.len != 0) return error.UnsupportedType;
            }
            const unit = try t.readScalar(i16, 0, 0);
            if (unit < 0 or unit > 3) return error.UnsupportedType;
            return .{ .timestamp = @enumFromInt(unit) };
        },
        type_list => {
            if (try field_table.vectorLen(field_slot_children) != 1) return error.MalformedSchema;
            const child = try allocator.create(Field);
            errdefer allocator.destroy(child);
            child.* = try readField(allocator, try field_table.vectorTable(field_slot_children, 0), depth + 1);
            return .{ .list = child };
        },
        type_struct => {
            const n = try field_table.vectorLen(field_slot_children);
            const fields = try allocator.alloc(Field, n);
            var finished: usize = 0;
            errdefer {
                for (fields[0..finished]) |*f| f.deinit(allocator);
                allocator.free(fields);
            }
            for (0..n) |i| {
                fields[i] = try readField(allocator, try field_table.vectorTable(field_slot_children, i), depth + 1);
                finished += 1;
            }
            return .{ .@"struct" = fields };
        },
        else => return error.UnsupportedType,
    }
}

/// Decodes a standalone buffer produced by `encode`. The caller owns the
/// returned schema and must release it with `deinit`.
pub fn decode(allocator: Allocator, buf: []const u8) DecodeError!Schema {
    return readSchema(allocator, try flatbuffers.getRoot(buf));
}

const testing = std.testing;

test "flat schema round-trips through encode and decode" {
    var id = try Field.init(testing.allocator, "id", .int32, false);
    defer id.deinit(testing.allocator);
    var name = try Field.init(testing.allocator, "name", .utf8, true);
    defer name.deinit(testing.allocator);

    var schema = try Schema.init(testing.allocator, &.{ id, name });
    defer schema.deinit(testing.allocator);

    const bytes = try encode(testing.allocator, schema);
    defer testing.allocator.free(bytes);

    var back = try decode(testing.allocator, bytes);
    defer back.deinit(testing.allocator);

    try testing.expect(schema.equals(back));
}

test "every flat type round-trips" {
    const flat_types = [_]DataType{
        .null,                          .boolean,
        .int8,                          .int16,
        .int32,                         .int64,
        .uint8,                         .uint16,
        .uint32,                        .uint64,
        .float16,                       .float32,
        .float64,                       .binary,
        .utf8,                          .large_binary,
        .large_utf8,                    .date32,
        .date64,                        .{ .timestamp = .second },
        .{ .timestamp = .millisecond }, .{ .timestamp = .microsecond },
        .{ .timestamp = .nanosecond },
    };

    var fields: [flat_types.len]Field = undefined;
    var built: usize = 0;
    defer for (fields[0..built]) |*f| f.deinit(testing.allocator);
    for (flat_types, 0..) |ty, i| {
        fields[i] = try Field.init(testing.allocator, "f", ty, true);
        built += 1;
    }

    var schema = try Schema.init(testing.allocator, &fields);
    defer schema.deinit(testing.allocator);

    const bytes = try encode(testing.allocator, schema);
    defer testing.allocator.free(bytes);

    var back = try decode(testing.allocator, bytes);
    defer back.deinit(testing.allocator);

    try testing.expect(schema.equals(back));
}

test "nested list and struct types round-trip" {
    var list_type = try DataType.initList(testing.allocator, .int64);
    defer list_type.deinit(testing.allocator);
    var inner_struct = try DataType.initStruct(testing.allocator, &.{ .boolean, .utf8 });
    defer inner_struct.deinit(testing.allocator);
    var list_of_struct = try DataType.initList(testing.allocator, inner_struct);
    defer list_of_struct.deinit(testing.allocator);

    var tags = try Field.init(testing.allocator, "tags", list_type, true);
    defer tags.deinit(testing.allocator);
    var rows = try Field.init(testing.allocator, "rows", list_of_struct, false);
    defer rows.deinit(testing.allocator);

    var schema = try Schema.init(testing.allocator, &.{ tags, rows });
    defer schema.deinit(testing.allocator);

    const bytes = try encode(testing.allocator, schema);
    defer testing.allocator.free(bytes);

    var back = try decode(testing.allocator, bytes);
    defer back.deinit(testing.allocator);

    try testing.expect(schema.equals(back));
}

test "named struct fields and list child fields round-trip" {
    const allocator = testing.allocator;

    var x = try Field.init(allocator, "x", .float64, false);
    defer x.deinit(allocator);
    var label = try Field.init(allocator, "label", .utf8, true);
    defer label.deinit(allocator);
    var point_type = try DataType.initStructFields(allocator, &.{ x, label });
    defer point_type.deinit(allocator);

    var element = try Field.init(allocator, "element", .int64, false);
    defer element.deinit(allocator);
    var readings_type = try DataType.initListField(allocator, element);
    defer readings_type.deinit(allocator);

    var point = try Field.init(allocator, "point", point_type, true);
    defer point.deinit(allocator);
    var readings = try Field.init(allocator, "readings", readings_type, false);
    defer readings.deinit(allocator);
    var schema = try Schema.init(allocator, &.{ point, readings });
    defer schema.deinit(allocator);

    const bytes = try encode(allocator, schema);
    defer allocator.free(bytes);
    var back = try decode(allocator, bytes);
    defer back.deinit(allocator);

    try testing.expect(schema.equals(back));
    const point_back = back.field(0).data_type.@"struct";
    try testing.expectEqualStrings("x", point_back[0].name);
    try testing.expect(!point_back[0].nullable);
    try testing.expectEqualStrings("label", point_back[1].name);
    const element_back = back.field(1).data_type.list;
    try testing.expectEqualStrings("element", element_back.name);
    try testing.expect(!element_back.nullable);
}

test "empty schema round-trips" {
    var schema = try Schema.init(testing.allocator, &.{});
    defer schema.deinit(testing.allocator);

    const bytes = try encode(testing.allocator, schema);
    defer testing.allocator.free(bytes);

    var back = try decode(testing.allocator, bytes);
    defer back.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), back.fieldCount());
}

// The output of `pyarrow.schema([...]).serialize()` for the schema
// (id: int32 not null, name: utf8, ts: timestamp[us], tags: list<item: int64>),
// generated with pyarrow 21. It is an encapsulated IPC message: a 4-byte
// continuation marker, a 4-byte metadata length, and a `Message` table whose
// header is the `Schema` table.
const pyarrow_schema_message = [_]u8{
    0xff, 0xff, 0xff, 0xff, 0x50, 0x01, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x00,
    0x0c, 0x00, 0x06, 0x00, 0x05, 0x00, 0x08, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x01, 0x04, 0x00,
    0x0c, 0x00, 0x00, 0x00, 0x08, 0x00, 0x08, 0x00, 0x00, 0x00, 0x04, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0xe8, 0x00, 0x00, 0x00, 0xa8, 0x00, 0x00, 0x00,
    0x64, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x74, 0xff, 0xff, 0xff, 0x00, 0x00, 0x01, 0x0c,
    0x14, 0x00, 0x00, 0x00, 0x1c, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x14, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x74, 0x61, 0x67, 0x73, 0x00, 0x00, 0x00, 0x00,
    0x68, 0xff, 0xff, 0xff, 0xa0, 0xff, 0xff, 0xff, 0x00, 0x00, 0x01, 0x02, 0x10, 0x00, 0x00, 0x00,
    0x18, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x69, 0x74, 0x65, 0x6d, 0x00, 0x00, 0x00, 0x00, 0x58, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
    0x40, 0x00, 0x00, 0x00, 0xd0, 0xff, 0xff, 0xff, 0x00, 0x00, 0x01, 0x0a, 0x10, 0x00, 0x00, 0x00,
    0x1c, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x74, 0x73, 0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x08, 0x00, 0x06, 0x00, 0x06, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x10, 0x00, 0x14, 0x00, 0x08, 0x00, 0x06, 0x00, 0x07, 0x00, 0x0c, 0x00,
    0x00, 0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x05, 0x10, 0x00, 0x00, 0x00,
    0x1c, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x6e, 0x61, 0x6d, 0x65, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x14, 0x00, 0x08, 0x00, 0x00, 0x00, 0x07, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x10, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x10, 0x00, 0x00, 0x00, 0x1c, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x69, 0x64, 0x00, 0x00,
    0x08, 0x00, 0x0c, 0x00, 0x08, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

test "decode reads a schema serialized by pyarrow" {
    const metadata_len = std.mem.readInt(u32, pyarrow_schema_message[4..8], .little);
    const metadata = pyarrow_schema_message[8 .. 8 + metadata_len];

    // Message table slots (Message.fbs): 0 version, 1 header tag, 2 header,
    // 3 body length, 4 custom metadata. Header tag 1 is Schema.
    const message = try flatbuffers.getRoot(metadata);
    try testing.expectEqual(@as(u8, 1), try message.readScalar(u8, 1, 0));
    const schema_table = (try message.readTable(2)).?;

    var schema = try readSchema(testing.allocator, schema_table);
    defer schema.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), schema.fieldCount());

    try testing.expectEqualStrings("id", schema.field(0).name);
    try testing.expect(schema.field(0).data_type.equals(.int32));
    try testing.expect(!schema.field(0).nullable);

    try testing.expectEqualStrings("name", schema.field(1).name);
    try testing.expect(schema.field(1).data_type.equals(.utf8));
    try testing.expect(schema.field(1).nullable);

    try testing.expectEqualStrings("ts", schema.field(2).name);
    try testing.expect(schema.field(2).data_type.equals(.{ .timestamp = .microsecond }));

    try testing.expectEqualStrings("tags", schema.field(3).name);
    try testing.expect(schema.field(3).data_type == .list);
    try testing.expect(schema.field(3).data_type.list.data_type.equals(.int64));
}

test "decode rejects a big-endian schema" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.startVector(4, 0, 4);
    const fields_off = try b.endVector(0);
    b.startTable();
    try b.addScalar(i16, 0, 1, 0); // Endianness.Big
    try b.addOffset(1, fields_off);
    const root = try b.endTable();
    const buf = try b.finish(root);

    try testing.expectError(error.UnsupportedEndianness, decode(testing.allocator, buf));
}

test "decode rejects a timestamp with a timezone" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    const tz = try b.createString("UTC");
    b.startTable();
    try b.addScalar(i16, 0, 2, 0); // TimeUnit.MICROSECOND
    try b.addOffset(1, tz);
    const ts_type = try b.endTable();

    const field_name = try b.createString("ts");
    b.startTable();
    try b.addOffset(0, field_name);
    try b.addScalar(bool, 1, true, false);
    try b.addScalar(u8, 2, 10, 0); // Type.Timestamp
    try b.addOffset(3, ts_type);
    const field_off = try b.endTable();

    try b.startVector(4, 1, 4);
    try b.pushOffsetElement(field_off);
    const fields_off = try b.endVector(1);

    b.startTable();
    try b.addOffset(1, fields_off);
    const root = try b.endTable();
    const buf = try b.finish(root);

    try testing.expectError(error.UnsupportedType, decode(testing.allocator, buf));
}

test "decode rejects a type Zarr does not implement" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    // A Decimal type table: precision 10, scale 2.
    b.startTable();
    try b.addScalar(i32, 0, 10, 0);
    try b.addScalar(i32, 1, 2, 0);
    const decimal_type = try b.endTable();

    const field_name = try b.createString("price");
    b.startTable();
    try b.addOffset(0, field_name);
    try b.addScalar(u8, 2, 7, 0); // Type.Decimal
    try b.addOffset(3, decimal_type);
    const field_off = try b.endTable();

    try b.startVector(4, 1, 4);
    try b.pushOffsetElement(field_off);
    const fields_off = try b.endVector(1);

    b.startTable();
    try b.addOffset(1, fields_off);
    const root = try b.endTable();
    const buf = try b.finish(root);

    try testing.expectError(error.UnsupportedType, decode(testing.allocator, buf));
}

test "decode returns errors on corrupt metadata instead of crashing" {
    const allocator = testing.allocator;
    const metadata_len = std.mem.readInt(u32, pyarrow_schema_message[4..8], .little);
    const metadata = pyarrow_schema_message[8 .. 8 + metadata_len];

    // Every truncation must decode cleanly or return an error, never read
    // out of bounds.
    for (0..metadata.len) |len| {
        var schema = decode(allocator, metadata[0..len]) catch continue;
        schema.deinit(allocator);
    }

    // Likewise for every single-byte corruption.
    const copy = try allocator.dupe(u8, metadata);
    defer allocator.free(copy);
    for (0..copy.len) |i| {
        const original = copy[i];
        defer copy[i] = original;
        copy[i] = 0xff;
        var schema = decode(allocator, copy) catch continue;
        schema.deinit(allocator);
    }
}

test "encode and decode leak nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var list_type = try DataType.initList(allocator, .int32);
            defer list_type.deinit(allocator);
            var f = try Field.init(allocator, "tags", list_type, true);
            defer f.deinit(allocator);
            var schema = try Schema.init(allocator, &.{f});
            defer schema.deinit(allocator);

            const bytes = try encode(allocator, schema);
            defer allocator.free(bytes);
            var back = try decode(allocator, bytes);
            back.deinit(allocator);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}
