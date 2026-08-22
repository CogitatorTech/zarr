//! Struct arrays and their builder.
//!
//! A struct array is the first multi-child layout: each element is a row drawn
//! from several child arrays, one per field. It stores an optional struct-level
//! validity bitmap and `N` child arrays, each of the same length as the struct.
//! There is no offsets or values buffer of its own; every field is a full array,
//! and row `i` is the tuple of element `i` taken from each child.
//!
//! `StructArray` is generic over its list of child array types. Each child type
//! must expose a `Builder` with `init`, `deinit`, `appendNull`, and `finish`,
//! which every array builder in this library provides.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bitmap = @import("bitmap.zig").Bitmap;
const Buffer = @import("buffer.zig").Buffer;
const datatype = @import("datatype.zig");
const DataType = datatype.DataType;
const ArrayData = @import("array_data.zig").ArrayData;

/// A struct array over the given ordered list of child array types.
pub fn StructArray(comptime child_types: []const type) type {
    const Children = std.meta.Tuple(child_types);

    const ChildBuilderTypes = blk: {
        var arr: [child_types.len]type = undefined;
        for (child_types, 0..) |T, i| arr[i] = T.Builder;
        break :blk arr;
    };
    const ChildBuilders = std.meta.Tuple(&ChildBuilderTypes);

    return struct {
        const Self = @This();

        /// Child arrays, one per field, each of length `length`.
        children: Children,
        /// Struct-level validity bitmap, present only when the struct has nulls.
        validity: ?Bitmap,
        /// Number of rows.
        length: usize,
        /// Number of null rows.
        null_count: usize,

        pub fn deinit(self: *Self) void {
            inline for (0..child_types.len) |i| self.children[i].deinit();
            if (self.validity) |*v| v.deinit();
            self.* = undefined;
        }

        /// Whether row `i` is valid (non-null).
        pub fn isValid(self: Self, i: usize) bool {
            std.debug.assert(i < self.length);
            if (self.validity) |v| return v.isSet(i);
            return true;
        }

        /// The child array for field `i`.
        pub fn field(self: *const Self, comptime i: usize) *const child_types[i] {
            return &self.children[i];
        }

        /// The Arrow logical type of this array: a struct over its field types.
        /// The caller owns the returned type and must release it with `deinit`.
        pub fn dataType(self: *const Self, allocator: Allocator) Allocator.Error!DataType {
            var children: [child_types.len]DataType = undefined;
            var finished: usize = 0;
            defer for (children[0..finished]) |*c| c.deinit(allocator);
            inline for (0..child_types.len) |i| {
                children[i] = try DataType.ofArray(self.children[i], allocator);
                finished += 1;
            }
            return DataType.initStruct(allocator, &children);
        }

        /// Convert into the type-erased `ArrayData` layout, copying the
        /// validity buffer and recursively converting each child. The caller
        /// keeps ownership of this array and must release the returned data
        /// separately.
        pub fn toData(self: *const Self, allocator: Allocator) Allocator.Error!ArrayData {
            var dt = try self.dataType(allocator);
            errdefer dt.deinit(allocator);
            const buffers = try allocator.alloc(?Buffer, 1);
            errdefer allocator.free(buffers);
            buffers[0] = null;
            errdefer if (buffers[0]) |*b| b.deinit();
            if (self.validity) |v| buffers[0] = try Buffer.dupe(allocator, v.buffer.data);
            const children = try allocator.alloc(ArrayData, child_types.len);
            errdefer allocator.free(children);
            var converted: usize = 0;
            errdefer for (children[0..converted]) |*c| c.deinit();
            inline for (0..child_types.len) |i| {
                children[i] = try self.children[i].toData(allocator);
                converted += 1;
            }
            return ArrayData.init(allocator, dt, self.length, self.null_count, buffers, children) catch unreachable;
        }

        /// Error set for `fromData`.
        pub const FromDataError = error{TypeMismatch} || Allocator.Error;

        /// Rebuild a struct array from the type-erased `ArrayData` layout,
        /// copying the validity and recursively rebuilding each child. The
        /// data's logical type must be a struct with one field per child type.
        /// The caller keeps ownership of `data` and must release the returned
        /// array separately.
        pub fn fromData(allocator: Allocator, data: ArrayData) FromDataError!Self {
            if (data.data_type != .@"struct") return error.TypeMismatch;
            if (data.data_type.@"struct".len != child_types.len) return error.TypeMismatch;

            var validity: ?Bitmap = null;
            if (data.validity()) |v| {
                validity = Bitmap.fromOwnedBuffer(try Buffer.dupe(allocator, v.data), data.length);
            }
            errdefer if (validity) |*b| b.deinit();

            var children: Children = undefined;
            var converted: usize = 0;
            errdefer inline for (0..child_types.len) |i| {
                if (i < converted) children[i].deinit();
            };
            inline for (0..child_types.len) |i| {
                children[i] = try child_types[i].fromData(allocator, data.child(i));
                converted += 1;
            }

            return .{
                .children = children,
                .validity = validity,
                .length = data.length,
                .null_count = data.null_count,
            };
        }

        /// Incrementally builds a `StructArray`. Append field values through the
        /// per-field builders in `children`, then close each row with `append`
        /// or `appendNull`.
        pub const Builder = struct {
            allocator: Allocator,
            /// Per-field builders, one per child array type.
            children: ChildBuilders,
            validity: std.ArrayList(bool),
            null_count: usize,

            pub fn init(allocator: Allocator) Builder {
                var self: Builder = .{
                    .allocator = allocator,
                    .children = undefined,
                    .validity = .empty,
                    .null_count = 0,
                };
                inline for (0..child_types.len) |i| {
                    self.children[i] = child_types[i].Builder.init(allocator);
                }
                return self;
            }

            pub fn deinit(self: *Builder) void {
                inline for (0..child_types.len) |i| self.children[i].deinit();
                self.validity.deinit(self.allocator);
                self.* = undefined;
            }

            /// Close a valid row. The caller must have appended one element to
            /// each field builder since the previous row.
            pub fn append(self: *Builder) Allocator.Error!void {
                try self.validity.append(self.allocator, true);
            }

            /// Close a null row, appending a null to every field builder so the
            /// children stay the same length as the struct.
            pub fn appendNull(self: *Builder) Allocator.Error!void {
                inline for (0..child_types.len) |i| try self.children[i].appendNull();
                try self.validity.append(self.allocator, false);
                self.null_count += 1;
            }

            /// Consume the builder and produce the array. The builder is reset
            /// to empty and may be reused or deinitialized.
            pub fn finish(self: *Builder) Allocator.Error!Self {
                const length = self.validity.items.len;

                var validity: ?Bitmap = null;
                if (self.null_count != 0) {
                    var bm = try Bitmap.init(self.allocator, length);
                    for (self.validity.items, 0..) |valid, i| {
                        if (valid) bm.set(i);
                    }
                    validity = bm;
                }
                errdefer if (validity) |*v| v.deinit();

                var children: Children = undefined;
                var finished: usize = 0;
                errdefer inline for (0..child_types.len) |i| {
                    if (i < finished) children[i].deinit();
                };
                inline for (0..child_types.len) |i| {
                    children[i] = try self.children[i].finish();
                    finished += 1;
                }

                inline for (0..child_types.len) |i| {
                    std.debug.assert(children[i].length == length);
                }

                const null_count = self.null_count;
                self.validity.clearRetainingCapacity();
                self.null_count = 0;

                return .{
                    .children = children,
                    .validity = validity,
                    .length = length,
                    .null_count = null_count,
                };
            }
        };
    };
}

const PrimitiveArray = @import("primitive_array.zig").PrimitiveArray;
const Utf8Array = @import("varbinary_array.zig").VarBinaryArray(true, i32);

const PersonStruct = StructArray(&[_]type{ PrimitiveArray(i32), Utf8Array });

test "struct builder produces an all-valid array" {
    var builder = PersonStruct.Builder.init(std.testing.allocator);
    defer builder.deinit();
    // {1, "a"}, {2, "bb"}
    try builder.children[0].append(1);
    try builder.children[1].append("a");
    try builder.append();
    try builder.children[0].append(2);
    try builder.children[1].append("bb");
    try builder.append();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 2), array.length);
    try std.testing.expectEqual(@as(usize, 0), array.null_count);
    try std.testing.expect(array.validity == null);
    try std.testing.expectEqual(@as(?i32, 1), array.field(0).get(0));
    try std.testing.expectEqual(@as(?i32, 2), array.field(0).get(1));
    try std.testing.expectEqualStrings("a", array.field(1).get(0).?);
    try std.testing.expectEqualStrings("bb", array.field(1).get(1).?);
}

test "struct builder tracks nulls with a validity bitmap" {
    var builder = PersonStruct.Builder.init(std.testing.allocator);
    defer builder.deinit();
    // {1, "a"}, null
    try builder.children[0].append(1);
    try builder.children[1].append("a");
    try builder.append();
    try builder.appendNull();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 2), array.length);
    try std.testing.expectEqual(@as(usize, 1), array.null_count);
    try std.testing.expect(array.validity != null);
    try std.testing.expect(array.isValid(0));
    try std.testing.expect(!array.isValid(1));
    // Children are padded so their length matches the struct.
    try std.testing.expectEqual(@as(usize, 2), array.field(0).length);
    try std.testing.expectEqual(@as(usize, 2), array.field(1).length);
    try std.testing.expectEqual(@as(?i32, null), array.field(0).get(1));
    try std.testing.expect(array.field(1).get(1) == null);
}

test "struct fields may be null while the row is valid" {
    var builder = PersonStruct.Builder.init(std.testing.allocator);
    defer builder.deinit();
    // {1, null}: valid row, null name field
    try builder.children[0].append(1);
    try builder.children[1].appendNull();
    try builder.append();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 1), array.length);
    try std.testing.expectEqual(@as(usize, 0), array.null_count);
    try std.testing.expect(array.isValid(0));
    try std.testing.expectEqual(@as(?i32, 1), array.field(0).get(0));
    try std.testing.expect(array.field(1).get(0) == null);
}

test "empty struct builder produces a zero-length array" {
    var builder = PersonStruct.Builder.init(std.testing.allocator);
    defer builder.deinit();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 0), array.length);
    try std.testing.expectEqual(@as(usize, 0), array.null_count);
    try std.testing.expect(array.validity == null);
    try std.testing.expectEqual(@as(usize, 0), array.field(0).length);
    try std.testing.expectEqual(@as(usize, 0), array.field(1).length);
}

test "struct children all share the struct length" {
    var builder = PersonStruct.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.children[0].append(1);
    try builder.children[1].append("a");
    try builder.append();
    try builder.appendNull();
    try builder.children[0].append(3);
    try builder.children[1].append("ccc");
    try builder.append();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 3), array.length);
    try std.testing.expectEqual(array.length, array.field(0).length);
    try std.testing.expectEqual(array.length, array.field(1).length);
}

test "struct array reports a struct data type over its fields" {
    var builder = PersonStruct.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.children[0].append(1);
    try builder.children[1].append("a");
    try builder.append();

    var array = try builder.finish();
    defer array.deinit();

    var ty = try array.dataType(std.testing.allocator);
    defer ty.deinit(std.testing.allocator);
    try std.testing.expect(ty == .@"struct");
    try std.testing.expectEqual(@as(usize, 2), ty.@"struct".len);
    try std.testing.expect(ty.@"struct"[0].data_type.equals(.int32));
    try std.testing.expect(ty.@"struct"[1].data_type.equals(.utf8));
}

test "struct array reports nested list fields in its data type" {
    const Int32List = @import("list_array.zig").ListArray(PrimitiveArray(i32));
    const NestedStruct = StructArray(&[_]type{ PrimitiveArray(i32), Int32List });
    var builder = NestedStruct.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.children[0].append(1);
    try builder.children[1].values.append(2);
    try builder.children[1].appendList();
    try builder.append();

    var array = try builder.finish();
    defer array.deinit();

    var ty = try array.dataType(std.testing.allocator);
    defer ty.deinit(std.testing.allocator);
    try std.testing.expect(ty.@"struct"[0].data_type.equals(.int32));
    try std.testing.expect(ty.@"struct"[1].data_type == .list);
    try std.testing.expect(ty.@"struct"[1].data_type.list.data_type.equals(.int32));
}

test "struct dataType leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = PersonStruct.Builder.init(allocator);
            defer builder.deinit();
            try builder.children[0].append(1);
            try builder.children[1].append("a");
            try builder.append();
            var array = try builder.finish();
            defer array.deinit();
            var ty = try array.dataType(allocator);
            ty.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "struct array converts to type-erased array data with children" {
    const allocator = std.testing.allocator;
    var builder = PersonStruct.Builder.init(allocator);
    defer builder.deinit();
    try builder.children[0].append(1);
    try builder.children[1].append("a");
    try builder.append();
    try builder.appendNull();

    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    try std.testing.expect(data.data_type == .@"struct");
    try std.testing.expectEqual(@as(usize, 2), data.data_type.@"struct".len);
    try std.testing.expectEqual(@as(usize, 2), data.length);
    try std.testing.expectEqual(@as(usize, 1), data.null_count);
    try std.testing.expectEqual(@as(usize, 1), data.buffers.len);
    try std.testing.expectEqual(@as(usize, 2), data.children.len);
    try std.testing.expect(data.children[0].data_type.equals(.int32));
    try std.testing.expect(data.children[1].data_type.equals(.utf8));
    try std.testing.expect(data.validity() != null);
}

test "struct toData leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = PersonStruct.Builder.init(allocator);
            defer builder.deinit();
            try builder.children[0].append(1);
            try builder.children[1].append("a");
            try builder.append();
            var array = try builder.finish();
            defer array.deinit();
            var data = try array.toData(allocator);
            data.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "struct array round-trips through type-erased array data" {
    const allocator = std.testing.allocator;
    var builder = PersonStruct.Builder.init(allocator);
    defer builder.deinit();
    // {1, "a"}, null
    try builder.children[0].append(1);
    try builder.children[1].append("a");
    try builder.append();
    try builder.appendNull();
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    var rebuilt = try PersonStruct.fromData(allocator, data);
    defer rebuilt.deinit();

    try std.testing.expectEqual(@as(usize, 2), rebuilt.length);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.null_count);
    try std.testing.expect(rebuilt.isValid(0));
    try std.testing.expect(!rebuilt.isValid(1));
    try std.testing.expectEqual(@as(?i32, 1), rebuilt.field(0).get(0));
    try std.testing.expectEqualStrings("a", rebuilt.field(1).get(0).?);
}

test "struct fromData rebuilds a nested list field" {
    const allocator = std.testing.allocator;
    const Int32List = @import("list_array.zig").ListArray(PrimitiveArray(i32));
    const NestedStruct = StructArray(&[_]type{ PrimitiveArray(i32), Int32List });
    var builder = NestedStruct.Builder.init(allocator);
    defer builder.deinit();
    // {1, [2, 3]}
    try builder.children[0].append(1);
    try builder.children[1].values.append(2);
    try builder.children[1].values.append(3);
    try builder.children[1].appendList();
    try builder.append();
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    var rebuilt = try NestedStruct.fromData(allocator, data);
    defer rebuilt.deinit();

    try std.testing.expectEqual(@as(?i32, 1), rebuilt.field(0).get(0));
    try std.testing.expectEqual(@as(usize, 2), rebuilt.field(1).valueLength(0));
    try std.testing.expectEqual(@as(?i32, 3), rebuilt.field(1).values.get(1));
}

test "struct fromData rejects a non-struct type" {
    const allocator = std.testing.allocator;
    var builder = PrimitiveArray(i32).Builder.init(allocator);
    defer builder.deinit();
    try builder.append(1);
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    try std.testing.expectError(error.TypeMismatch, PersonStruct.fromData(allocator, data));
}

test "struct fromData leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = PersonStruct.Builder.init(allocator);
            defer builder.deinit();
            try builder.children[0].append(1);
            try builder.children[1].append("a");
            try builder.append();
            try builder.appendNull();
            var array = try builder.finish();
            defer array.deinit();
            var data = try array.toData(allocator);
            defer data.deinit();
            var rebuilt = try PersonStruct.fromData(allocator, data);
            rebuilt.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "struct builder finish leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = PersonStruct.Builder.init(allocator);
            defer builder.deinit();
            try builder.children[0].append(1);
            try builder.children[1].append("a");
            try builder.append();
            try builder.appendNull();
            var array = try builder.finish();
            array.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
