//! Record batches.
//!
//! A record batch is a schema paired with a set of equal-length columns, one
//! per schema field. It is the unit of columnar data exchanged over IPC and the
//! C Data Interface. Structurally it matches a struct array, so the columns are
//! held in a `StructArray` over the same child types, and the batch adds the
//! field names, types, and nullability that a `Schema` carries.
//!
//! `RecordBatch` is generic over its column array types, which must line up
//! with the schema fields in order. Instantiate the matching column container
//! through the exposed `Columns` type so the built columns share the batch's
//! type exactly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const DataType = @import("datatype.zig").DataType;
const Schema = @import("schema.zig").Schema;
const StructArray = @import("struct_array.zig").StructArray;
const ArrayData = @import("array_data.zig").ArrayData;

/// A schema paired with equal-length columns over the given array types.
pub fn RecordBatch(comptime column_types: []const type) type {
    return struct {
        const Self = @This();

        /// The column container type. Build columns through `Columns.Builder`
        /// so they share this batch's exact type.
        pub const Columns = StructArray(column_types);

        /// Error set for `init`.
        pub const InitError = Allocator.Error || error{SchemaMismatch};

        /// Allocator that owns the cloned schema. Held so `deinit` can free the
        /// schema, which does not store its own allocator.
        allocator: Allocator,
        /// Schema describing the columns; owned by this batch.
        schema: Schema,
        /// Columns, one per schema field, each of length `numRows`; owned by
        /// this batch.
        columns: Columns,

        /// Builds a record batch from a schema and columns. The batch stores a
        /// clone of `schema`, so the caller keeps ownership of its schema. On
        /// success the batch takes ownership of `columns`, and the caller must
        /// not release them; on any error the caller still owns `columns`.
        /// Returns `error.SchemaMismatch` when the schema field count or any
        /// field type disagrees with the columns.
        pub fn init(allocator: Allocator, schema: Schema, columns: Columns) InitError!Self {
            if (schema.fieldCount() != column_types.len) return error.SchemaMismatch;
            inline for (0..column_types.len) |i| {
                var col_type = try DataType.ofArray(columns.field(i).*, allocator);
                defer col_type.deinit(allocator);
                // Layout comparison: a column array cannot carry field names,
                // so the schema is the naming authority.
                if (!col_type.equalsLayout(schema.field(i).data_type)) return error.SchemaMismatch;
            }
            // Validation passed; take ownership of the columns and a clone of
            // the schema. Cloning is the last fallible step, so a failure here
            // still leaves the caller owning `columns`.
            const owned_schema = try schema.clone(allocator);
            return .{ .allocator = allocator, .schema = owned_schema, .columns = columns };
        }

        pub fn deinit(self: *Self) void {
            self.schema.deinit(self.allocator);
            self.columns.deinit();
            self.* = undefined;
        }

        /// Error set for `fromData`.
        pub const FromDataError = Columns.FromDataError || InitError;

        /// Convert the batch's columns into the type-erased `ArrayData` layout,
        /// which for a batch is a struct array over the column types. The schema
        /// is not part of this layout, matching the C Data Interface, where a
        /// batch's array and schema cross the boundary separately. The caller
        /// keeps ownership of this batch and must release the returned data.
        pub fn toData(self: *const Self, allocator: Allocator) Allocator.Error!ArrayData {
            return self.columns.toData(allocator);
        }

        /// Rebuild a batch from a schema and the type-erased columns produced by
        /// `toData`. The columns are rebuilt from `data`, then validated against
        /// `schema` exactly as `init` does, so a schema that disagrees with the
        /// data returns `error.SchemaMismatch`. The caller keeps ownership of
        /// `schema` and `data`.
        pub fn fromData(allocator: Allocator, schema: Schema, data: ArrayData) FromDataError!Self {
            var columns = try Columns.fromData(allocator, data);
            errdefer columns.deinit();
            return init(allocator, schema, columns);
        }

        /// Number of rows, shared by every column.
        pub fn numRows(self: Self) usize {
            return self.columns.length;
        }

        /// Number of columns.
        pub fn numColumns(self: Self) usize {
            _ = self;
            return column_types.len;
        }

        /// The column array for field `i`.
        pub fn column(self: *const Self, comptime i: usize) *const column_types[i] {
            return self.columns.field(i);
        }
    };
}

const PrimitiveArray = @import("primitive_array.zig").PrimitiveArray;
const Utf8Array = @import("varbinary_array.zig").VarBinaryArray(true, i32);

const person_columns = [_]type{ PrimitiveArray(i32), Utf8Array };
const PersonBatch = RecordBatch(&person_columns);

fn buildPersonSchema(allocator: Allocator) !Schema {
    const Field = @import("schema.zig").Field;
    var id = try Field.init(allocator, "id", .int32, false);
    defer id.deinit(allocator);
    var name = try Field.init(allocator, "name", .utf8, true);
    defer name.deinit(allocator);
    return Schema.init(allocator, &.{ id, name });
}

fn buildPersonColumns(allocator: Allocator) !PersonBatch.Columns {
    var builder = PersonBatch.Columns.Builder.init(allocator);
    defer builder.deinit();
    // {1, "a"}, {2, "bb"}
    try builder.children[0].append(1);
    try builder.children[1].append("a");
    try builder.append();
    try builder.children[0].append(2);
    try builder.children[1].append("bb");
    try builder.append();
    return builder.finish();
}

test "record batch pairs a schema with matching columns" {
    const allocator = std.testing.allocator;
    var schema = try buildPersonSchema(allocator);
    defer schema.deinit(allocator);
    const columns = try buildPersonColumns(allocator);

    var batch = try PersonBatch.init(allocator, schema, columns);
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 2), batch.numRows());
    try std.testing.expectEqual(@as(usize, 2), batch.numColumns());
    try std.testing.expectEqual(@as(?i32, 1), batch.column(0).get(0));
    try std.testing.expectEqualStrings("bb", batch.column(1).get(1).?);
    try std.testing.expectEqualStrings("id", batch.schema.field(0).name);
    try std.testing.expect(batch.schema.field(1).data_type.equals(.utf8));
}

test "record batch clones its schema, leaving the caller's intact" {
    const allocator = std.testing.allocator;
    var schema = try buildPersonSchema(allocator);
    const columns = try buildPersonColumns(allocator);

    var batch = try PersonBatch.init(allocator, schema, columns);
    defer batch.deinit();

    // Freeing the caller's schema does not affect the batch.
    schema.deinit(allocator);

    try std.testing.expectEqualStrings("id", batch.schema.field(0).name);
    try std.testing.expectEqual(@as(usize, 2), batch.numColumns());
}

test "record batch rejects a schema whose field count differs" {
    const allocator = std.testing.allocator;
    const Field = @import("schema.zig").Field;
    var id = try Field.init(allocator, "id", .int32, false);
    defer id.deinit(allocator);
    var one_field = try Schema.init(allocator, &.{id});
    defer one_field.deinit(allocator);

    var columns = try buildPersonColumns(allocator);
    defer columns.deinit();

    try std.testing.expectError(error.SchemaMismatch, PersonBatch.init(allocator, one_field, columns));
}

test "record batch rejects a schema whose field type differs" {
    const allocator = std.testing.allocator;
    const Field = @import("schema.zig").Field;
    var id = try Field.init(allocator, "id", .int64, false); // column is i32
    defer id.deinit(allocator);
    var name = try Field.init(allocator, "name", .utf8, true);
    defer name.deinit(allocator);
    var wrong = try Schema.init(allocator, &.{ id, name });
    defer wrong.deinit(allocator);

    var columns = try buildPersonColumns(allocator);
    defer columns.deinit();

    try std.testing.expectError(error.SchemaMismatch, PersonBatch.init(allocator, wrong, columns));
}

test "record batch accepts a schema with named struct fields" {
    const allocator = std.testing.allocator;
    const Field = @import("schema.zig").Field;
    const StructColumn = @import("struct_array.zig").StructArray(&.{ PrimitiveArray(f64), Utf8Array });
    const point_columns = [_]type{StructColumn};
    const PointBatch = RecordBatch(&point_columns);

    // The schema names the struct's fields; the column array cannot carry
    // names, so validation compares layout, not names.
    var x = try Field.init(allocator, "x", .float64, false);
    defer x.deinit(allocator);
    var label = try Field.init(allocator, "label", .utf8, true);
    defer label.deinit(allocator);
    var point_type = try DataType.initStructFields(allocator, &.{ x, label });
    defer point_type.deinit(allocator);
    var point = try Field.init(allocator, "point", point_type, true);
    defer point.deinit(allocator);
    var schema = try Schema.init(allocator, &.{point});
    defer schema.deinit(allocator);

    var builder = PointBatch.Columns.Builder.init(allocator);
    defer builder.deinit();
    try builder.children[0].children[0].append(1.5);
    try builder.children[0].children[1].append("a");
    try builder.children[0].append();
    try builder.append();
    try builder.children[0].appendNull();
    try builder.append();
    const columns = try builder.finish();

    var batch = try PointBatch.init(allocator, schema, columns);
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 2), batch.numRows());
    try std.testing.expectEqualStrings("x", batch.schema.field(0).data_type.@"struct"[0].name);
}

test "record batch validates nested column types" {
    const allocator = std.testing.allocator;
    const Field = @import("schema.zig").Field;
    const Int32List = @import("list_array.zig").ListArray(PrimitiveArray(i32));
    const list_columns = [_]type{Int32List};
    const ListBatch = RecordBatch(&list_columns);

    var list_type = try DataType.initList(allocator, .int32);
    var f = try Field.init(allocator, "values", list_type, true);
    list_type.deinit(allocator);
    defer f.deinit(allocator);
    var schema = try Schema.init(allocator, &.{f});
    defer schema.deinit(allocator);

    var builder = ListBatch.Columns.Builder.init(allocator);
    defer builder.deinit();
    try builder.children[0].values.append(1);
    try builder.children[0].appendList();
    try builder.append();
    const columns = try builder.finish();

    var batch = try ListBatch.init(allocator, schema, columns);
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 1), batch.numRows());
    try std.testing.expectEqual(@as(usize, 1), batch.column(0).valueLength(0));
}

test "record batch round-trips through type-erased array data" {
    const allocator = std.testing.allocator;
    var schema = try buildPersonSchema(allocator);
    defer schema.deinit(allocator);
    const columns = try buildPersonColumns(allocator);

    var batch = try PersonBatch.init(allocator, schema, columns);
    defer batch.deinit();

    var data = try batch.toData(allocator);
    defer data.deinit();

    // The erased form of a batch is its columns as a struct array.
    try std.testing.expect(data.data_type == .@"struct");
    try std.testing.expectEqual(@as(usize, 2), data.children.len);

    var rebuilt = try PersonBatch.fromData(allocator, schema, data);
    defer rebuilt.deinit();

    try std.testing.expectEqual(@as(usize, 2), rebuilt.numRows());
    try std.testing.expectEqual(@as(usize, 2), rebuilt.numColumns());
    try std.testing.expectEqual(@as(?i32, 1), rebuilt.column(0).get(0));
    try std.testing.expectEqualStrings("bb", rebuilt.column(1).get(1).?);
    try std.testing.expectEqualStrings("id", rebuilt.schema.field(0).name);
}

test "record batch fromData rejects a schema that disagrees with the data" {
    const allocator = std.testing.allocator;
    const Field = @import("schema.zig").Field;
    var schema = try buildPersonSchema(allocator);
    defer schema.deinit(allocator);
    const columns = try buildPersonColumns(allocator);
    var batch = try PersonBatch.init(allocator, schema, columns);
    defer batch.deinit();

    var data = try batch.toData(allocator);
    defer data.deinit();

    // A one-field schema cannot describe two columns.
    var id = try Field.init(allocator, "id", .int32, false);
    defer id.deinit(allocator);
    var one_field = try Schema.init(allocator, &.{id});
    defer one_field.deinit(allocator);

    try std.testing.expectError(error.SchemaMismatch, PersonBatch.fromData(allocator, one_field, data));
}

test "record batch fromData leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var schema = try buildPersonSchema(allocator);
            defer schema.deinit(allocator);
            // Guard the columns only until the batch takes ownership of them; a
            // normal break leaves them with the batch, an error frees them.
            var batch = blk: {
                var columns = try buildPersonColumns(allocator);
                errdefer columns.deinit();
                break :blk try PersonBatch.init(allocator, schema, columns);
            };
            defer batch.deinit();
            var data = try batch.toData(allocator);
            defer data.deinit();
            var rebuilt = try PersonBatch.fromData(allocator, schema, data);
            rebuilt.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "record batch init leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var schema = try buildPersonSchema(allocator);
            defer schema.deinit(allocator);
            var columns = try buildPersonColumns(allocator);
            // The caller owns columns unless init succeeds.
            errdefer columns.deinit();
            var batch = try PersonBatch.init(allocator, schema, columns);
            batch.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
