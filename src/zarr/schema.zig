//! Schema and field metadata.
//!
//! A `Field` names a column and gives its logical type and nullability. A
//! `Schema` is an ordered set of fields describing the columns of a record
//! batch or table. Both own their heap memory: a field owns its name and its
//! `DataType`, and a schema owns its fields. This mirrors the Arrow spec, where
//! a schema is a list of named, typed, nullable fields.

const std = @import("std");
const Allocator = std.mem.Allocator;
const DataType = @import("datatype.zig").DataType;

/// A named, typed, nullable column descriptor.
pub const Field = struct {
    /// Column name; owned by this field.
    name: []const u8,
    /// Logical type; owned by this field.
    data_type: DataType,
    /// Whether the column may contain nulls.
    nullable: bool,

    /// Builds a field owning a copy of `name` and a deep copy of `data_type`.
    /// The caller retains ownership of both arguments and must release the
    /// returned field with `deinit`.
    pub fn init(allocator: Allocator, name: []const u8, data_type: DataType, nullable: bool) Allocator.Error!Field {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_type = try data_type.clone(allocator);
        return .{ .name = owned_name, .data_type = owned_type, .nullable = nullable };
    }

    /// Frees the owned name and type.
    pub fn deinit(self: *Field, allocator: Allocator) void {
        allocator.free(self.name);
        self.data_type.deinit(allocator);
        self.* = undefined;
    }

    /// Deep-copies this field.
    pub fn clone(self: Field, allocator: Allocator) Allocator.Error!Field {
        return init(allocator, self.name, self.data_type, self.nullable);
    }

    /// Structural equality: name, type, and nullability all match.
    pub fn equals(self: Field, other: Field) bool {
        return self.nullable == other.nullable and
            std.mem.eql(u8, self.name, other.name) and
            self.data_type.equals(other.data_type);
    }
};

/// An ordered set of fields describing the columns of a record batch.
pub const Schema = struct {
    /// Fields in column order; owned by this schema.
    fields: []const Field,

    /// Builds a schema owning a deep copy of `fields`. The caller retains
    /// ownership of the argument and must release the returned schema with
    /// `deinit`.
    pub fn init(allocator: Allocator, fields: []const Field) Allocator.Error!Schema {
        const owned = try allocator.alloc(Field, fields.len);
        var finished: usize = 0;
        errdefer {
            for (owned[0..finished]) |*f| f.deinit(allocator);
            allocator.free(owned);
        }
        for (fields, 0..) |f, i| {
            owned[i] = try f.clone(allocator);
            finished += 1;
        }
        return .{ .fields = owned };
    }

    /// Frees every owned field and the field slice.
    pub fn deinit(self: *Schema, allocator: Allocator) void {
        for (self.fields) |*f| @constCast(f).deinit(allocator);
        allocator.free(self.fields);
        self.* = undefined;
    }

    /// Deep-copies this schema.
    pub fn clone(self: Schema, allocator: Allocator) Allocator.Error!Schema {
        return init(allocator, self.fields);
    }

    /// Number of fields.
    pub fn fieldCount(self: Schema) usize {
        return self.fields.len;
    }

    /// The field at column index `i`.
    pub fn field(self: Schema, i: usize) *const Field {
        std.debug.assert(i < self.fields.len);
        return &self.fields[i];
    }

    /// The first field named `name`, or null when none matches.
    pub fn fieldByName(self: Schema, name: []const u8) ?*const Field {
        for (self.fields) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    /// Structural equality: same fields in the same order.
    pub fn equals(self: Schema, other: Schema) bool {
        if (self.fields.len != other.fields.len) return false;
        for (self.fields, other.fields) |a, b| {
            if (!a.equals(b)) return false;
        }
        return true;
    }
};

test "field owns a copy of its name and type" {
    var name_buf = [_]u8{ 'i', 'd' };
    var f = try Field.init(std.testing.allocator, &name_buf, .int32, false);
    defer f.deinit(std.testing.allocator);

    // Mutating the source name does not affect the field.
    name_buf[0] = 'X';

    try std.testing.expectEqualStrings("id", f.name);
    try std.testing.expect(f.data_type.equals(.int32));
    try std.testing.expect(!f.nullable);
}

test "field owns a deep copy of a nested type" {
    var list_type = try DataType.initList(std.testing.allocator, .int32);
    var f = try Field.init(std.testing.allocator, "values", list_type, true);
    defer f.deinit(std.testing.allocator);

    // Freeing the source type leaves the field intact.
    list_type.deinit(std.testing.allocator);

    try std.testing.expect(f.data_type == .list);
    try std.testing.expect(f.data_type.list.equals(.int32));
    try std.testing.expect(f.nullable);
}

test "field equality compares name, type, and nullability" {
    var a = try Field.init(std.testing.allocator, "id", .int32, false);
    defer a.deinit(std.testing.allocator);
    var b = try Field.init(std.testing.allocator, "id", .int32, false);
    defer b.deinit(std.testing.allocator);
    var c = try Field.init(std.testing.allocator, "id", .int32, true);
    defer c.deinit(std.testing.allocator);
    var d = try Field.init(std.testing.allocator, "name", .int32, false);
    defer d.deinit(std.testing.allocator);

    try std.testing.expect(a.equals(b));
    try std.testing.expect(!a.equals(c));
    try std.testing.expect(!a.equals(d));
}

test "field clone produces an independent copy" {
    var original = try Field.init(std.testing.allocator, "id", .int32, false);
    var copy = try original.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);

    original.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("id", copy.name);
    try std.testing.expect(copy.data_type.equals(.int32));
}

test "schema owns deep copies of its fields" {
    var id = try Field.init(std.testing.allocator, "id", .int32, false);
    var name = try Field.init(std.testing.allocator, "name", .utf8, true);

    var schema = try Schema.init(std.testing.allocator, &.{ id, name });
    defer schema.deinit(std.testing.allocator);

    // Freeing the source fields leaves the schema intact.
    id.deinit(std.testing.allocator);
    name.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), schema.fieldCount());
    try std.testing.expectEqualStrings("id", schema.field(0).name);
    try std.testing.expectEqualStrings("name", schema.field(1).name);
    try std.testing.expect(schema.field(1).data_type.equals(.utf8));
}

test "schema looks up a field by name" {
    var id = try Field.init(std.testing.allocator, "id", .int32, false);
    defer id.deinit(std.testing.allocator);
    var name = try Field.init(std.testing.allocator, "name", .utf8, true);
    defer name.deinit(std.testing.allocator);

    var schema = try Schema.init(std.testing.allocator, &.{ id, name });
    defer schema.deinit(std.testing.allocator);

    const found = schema.fieldByName("name").?;
    try std.testing.expect(found.data_type.equals(.utf8));
    try std.testing.expect(schema.fieldByName("missing") == null);
}

test "schema clone produces an independent copy" {
    var id = try Field.init(std.testing.allocator, "id", .int32, false);
    defer id.deinit(std.testing.allocator);

    var original = try Schema.init(std.testing.allocator, &.{id});
    var copy = try original.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);

    original.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), copy.fieldCount());
    try std.testing.expectEqualStrings("id", copy.field(0).name);
}

test "empty schema has no fields" {
    var schema = try Schema.init(std.testing.allocator, &.{});
    defer schema.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), schema.fieldCount());
}

test "schema equality compares fields in order" {
    var id = try Field.init(std.testing.allocator, "id", .int32, false);
    defer id.deinit(std.testing.allocator);
    var name = try Field.init(std.testing.allocator, "name", .utf8, true);
    defer name.deinit(std.testing.allocator);

    var a = try Schema.init(std.testing.allocator, &.{ id, name });
    defer a.deinit(std.testing.allocator);
    var b = try Schema.init(std.testing.allocator, &.{ id, name });
    defer b.deinit(std.testing.allocator);
    var c = try Schema.init(std.testing.allocator, &.{ name, id });
    defer c.deinit(std.testing.allocator);

    try std.testing.expect(a.equals(b));
    try std.testing.expect(!a.equals(c));
}

test "schema construction leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var list_type = try DataType.initList(allocator, .int32);
            defer list_type.deinit(allocator);
            var f = try Field.init(allocator, "values", list_type, true);
            defer f.deinit(allocator);
            var schema = try Schema.init(allocator, &.{f});
            schema.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
