//! Variable-length list arrays and their builder.
//!
//! A list array is the first nested layout: each element is itself a sequence
//! of child elements. It stores an optional validity bitmap, an i32 offsets
//! buffer of `length + 1` entries, and a child array holding the concatenated
//! elements of every list. Element `i` spans `child[offsets[i]..offsets[i + 1]]`.
//! Offsets are monotonically non-decreasing and `offsets[0]` is zero.
//!
//! `ListArray` is generic over its child array type. The child type must expose
//! a `Builder` with `init`, `deinit`, `len`, and `finish`, which every array
//! builder in this library provides.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const Bitmap = @import("bitmap.zig").Bitmap;
const datatype = @import("datatype.zig");
const DataType = datatype.DataType;
const ArrayData = @import("array_data.zig").ArrayData;

/// A variable-length list over child array type `Child`.
pub fn ListArray(comptime Child: type) type {
    return struct {
        const Self = @This();

        /// Concatenated child elements of every list.
        values: Child,
        /// i32 offsets, `length + 1` entries; list `i` spans
        /// `values[offsets[i]..offsets[i + 1]]`.
        offsets: Buffer,
        /// Validity bitmap, present only when the array contains nulls.
        validity: ?Bitmap,
        /// Number of lists.
        length: usize,
        /// Number of null lists.
        null_count: usize,

        pub fn deinit(self: *Self) void {
            self.values.deinit();
            self.offsets.deinit();
            if (self.validity) |*v| v.deinit();
            self.* = undefined;
        }

        /// Whether list `i` is valid (non-null).
        pub fn isValid(self: Self, i: usize) bool {
            std.debug.assert(i < self.length);
            if (self.validity) |v| return v.isSet(i);
            return true;
        }

        /// The Arrow logical type of this array: a list of the child type. The
        /// caller owns the returned type and must release it with `deinit`.
        pub fn dataType(self: Self, allocator: Allocator) Allocator.Error!DataType {
            var child = try DataType.ofArray(self.values, allocator);
            defer child.deinit(allocator);
            return DataType.initList(allocator, child);
        }

        /// Convert into the type-erased `ArrayData` layout, copying the
        /// buffers and recursively converting the child array. The caller keeps
        /// ownership of this array and must release the returned data
        /// separately.
        pub fn toData(self: Self, allocator: Allocator) Allocator.Error!ArrayData {
            var dt = try self.dataType(allocator);
            errdefer dt.deinit(allocator);
            const buffers = try allocator.alloc(?Buffer, 2);
            errdefer allocator.free(buffers);
            buffers[0] = null;
            buffers[1] = null;
            errdefer for (buffers) |*b| if (b.*) |*buf| buf.deinit();
            if (self.validity) |v| buffers[0] = try Buffer.dupe(allocator, v.buffer.data);
            buffers[1] = try Buffer.dupe(allocator, self.offsets.data);
            const children = try allocator.alloc(ArrayData, 1);
            errdefer allocator.free(children);
            children[0] = try self.values.toData(allocator);
            errdefer children[0].deinit();
            return ArrayData.init(allocator, dt, self.length, self.null_count, buffers, children) catch unreachable;
        }

        /// Error set for `fromData`.
        pub const FromDataError = error{TypeMismatch} || Allocator.Error;

        /// Rebuild a list array from the type-erased `ArrayData` layout, copying
        /// the offsets and validity and recursively rebuilding the child array.
        /// The data's logical type must be a list. The caller keeps ownership of
        /// `data` and must release the returned array separately.
        pub fn fromData(allocator: Allocator, data: ArrayData) FromDataError!Self {
            if (data.data_type != .list) return error.TypeMismatch;

            var values = try Child.fromData(allocator, data.child(0));
            errdefer values.deinit();
            var offsets = try Buffer.dupe(allocator, data.buffers[1].?.data);
            errdefer offsets.deinit();

            var validity: ?Bitmap = null;
            if (data.validity()) |v| {
                validity = Bitmap.fromOwnedBuffer(try Buffer.dupe(allocator, v.data), data.length);
            }

            return .{
                .values = values,
                .offsets = offsets,
                .validity = validity,
                .length = data.length,
                .null_count = data.null_count,
            };
        }

        /// Index into the child array where list `i` begins.
        pub fn valueOffset(self: Self, i: usize) usize {
            std.debug.assert(i < self.length);
            return @intCast(self.offsets.items(i32)[i]);
        }

        /// Number of child elements in list `i`. A null list has length zero.
        pub fn valueLength(self: Self, i: usize) usize {
            std.debug.assert(i < self.length);
            const offs = self.offsets.items(i32);
            return @intCast(offs[i + 1] - offs[i]);
        }

        /// Incrementally builds a `ListArray`. Append child elements through
        /// `values`, then close each list with `appendList` or `appendNull`.
        pub const Builder = struct {
            allocator: Allocator,
            /// Builder for the child array.
            values: Child.Builder,
            /// End offset after each closed list.
            offsets: std.ArrayList(i32),
            validity: std.ArrayList(bool),
            null_count: usize,

            pub fn init(allocator: Allocator) Builder {
                return .{
                    .allocator = allocator,
                    .values = Child.Builder.init(allocator),
                    .offsets = .empty,
                    .validity = .empty,
                    .null_count = 0,
                };
            }

            pub fn deinit(self: *Builder) void {
                self.values.deinit();
                self.offsets.deinit(self.allocator);
                self.validity.deinit(self.allocator);
                self.* = undefined;
            }

            /// Close a valid list holding every child element appended since the
            /// previous list boundary.
            pub fn appendList(self: *Builder) Allocator.Error!void {
                try self.offsets.append(self.allocator, @intCast(self.values.len()));
                try self.validity.append(self.allocator, true);
            }

            /// Number of lists closed so far.
            pub fn len(self: Builder) usize {
                return self.offsets.items.len;
            }

            /// Close a null list. It spans zero child elements.
            pub fn appendNull(self: *Builder) Allocator.Error!void {
                try self.offsets.append(self.allocator, @intCast(self.values.len()));
                try self.validity.append(self.allocator, false);
                self.null_count += 1;
            }

            /// Consume the builder and produce the array. The builder is reset
            /// to empty and may be reused or deinitialized.
            pub fn finish(self: *Builder) Allocator.Error!Self {
                const length = self.offsets.items.len;

                const offsets = try Buffer.alloc(self.allocator, (length + 1) * @sizeOf(i32));
                errdefer self.allocator.free(offsets.data);
                const offs = offsets.items(i32);
                offs[0] = 0;
                for (self.offsets.items, 0..) |end, i| offs[i + 1] = end;

                var validity: ?Bitmap = null;
                if (self.null_count != 0) {
                    var bm = try Bitmap.init(self.allocator, length);
                    for (self.validity.items, 0..) |valid, i| {
                        if (valid) bm.set(i);
                    }
                    validity = bm;
                }
                errdefer if (validity) |*v| v.deinit();

                var values = try self.values.finish();
                errdefer values.deinit();

                const null_count = self.null_count;
                self.offsets.clearRetainingCapacity();
                self.validity.clearRetainingCapacity();
                self.null_count = 0;

                return .{
                    .values = values,
                    .offsets = offsets,
                    .validity = validity,
                    .length = length,
                    .null_count = null_count,
                };
            }
        };
    };
}

const std_testing = std.testing;
const PrimitiveArray = @import("primitive_array.zig").PrimitiveArray;
const Utf8Array = @import("varbinary_array.zig").VarBinaryArray(true, i32);

const Int32List = ListArray(PrimitiveArray(i32));
const StringList = ListArray(Utf8Array);

test "list builder produces an all-valid array" {
    var builder = Int32List.Builder.init(std.testing.allocator);
    defer builder.deinit();
    // [[1, 2, 3], [4, 5]]
    try builder.values.append(1);
    try builder.values.append(2);
    try builder.values.append(3);
    try builder.appendList();
    try builder.values.append(4);
    try builder.values.append(5);
    try builder.appendList();

    var array = try builder.finish();
    defer array.deinit();

    try std_testing.expectEqual(@as(usize, 2), array.length);
    try std_testing.expectEqual(@as(usize, 0), array.null_count);
    try std_testing.expect(array.validity == null);
    try std_testing.expectEqual(@as(usize, 3), array.valueLength(0));
    try std_testing.expectEqual(@as(usize, 2), array.valueLength(1));
    try std_testing.expectEqual(@as(usize, 0), array.valueOffset(0));
    try std_testing.expectEqual(@as(usize, 3), array.valueOffset(1));
    try std_testing.expectEqual(@as(?i32, 1), array.values.get(0));
    try std_testing.expectEqual(@as(?i32, 5), array.values.get(4));
}

test "list builder tracks nulls with a validity bitmap" {
    var builder = Int32List.Builder.init(std.testing.allocator);
    defer builder.deinit();
    // [[1], null, [2, 3]]
    try builder.values.append(1);
    try builder.appendList();
    try builder.appendNull();
    try builder.values.append(2);
    try builder.values.append(3);
    try builder.appendList();

    var array = try builder.finish();
    defer array.deinit();

    try std_testing.expectEqual(@as(usize, 3), array.length);
    try std_testing.expectEqual(@as(usize, 1), array.null_count);
    try std_testing.expect(array.validity != null);
    try std_testing.expect(array.isValid(0));
    try std_testing.expect(!array.isValid(1));
    try std_testing.expectEqual(@as(usize, 0), array.valueLength(1));
    try std_testing.expectEqual(@as(usize, 2), array.valueLength(2));
    try std_testing.expectEqual(@as(?i32, 3), array.values.get(array.valueOffset(2) + 1));
}

test "list builder distinguishes an empty list from a null" {
    var builder = Int32List.Builder.init(std.testing.allocator);
    defer builder.deinit();
    // [[], null]
    try builder.appendList();
    try builder.appendNull();

    var array = try builder.finish();
    defer array.deinit();

    try std_testing.expectEqual(@as(usize, 2), array.length);
    try std_testing.expectEqual(@as(usize, 1), array.null_count);
    try std_testing.expect(array.isValid(0));
    try std_testing.expectEqual(@as(usize, 0), array.valueLength(0));
    try std_testing.expect(!array.isValid(1));
}

test "empty list builder produces a zero-length array" {
    var builder = Int32List.Builder.init(std.testing.allocator);
    defer builder.deinit();

    var array = try builder.finish();
    defer array.deinit();

    try std_testing.expectEqual(@as(usize, 0), array.length);
    try std_testing.expectEqual(@as(usize, 0), array.null_count);
    try std_testing.expect(array.validity == null);
    // Offsets always carry the leading zero, even when empty.
    try std_testing.expectEqual(@as(usize, 1), array.offsets.items(i32).len);
    try std_testing.expectEqual(@as(i32, 0), array.offsets.items(i32)[0]);
}

test "list offsets are monotonic with a leading zero" {
    var builder = Int32List.Builder.init(std.testing.allocator);
    defer builder.deinit();
    // [[1, 2], null, [3, 4, 5]]
    try builder.values.append(1);
    try builder.values.append(2);
    try builder.appendList();
    try builder.appendNull();
    try builder.values.append(3);
    try builder.values.append(4);
    try builder.values.append(5);
    try builder.appendList();

    var array = try builder.finish();
    defer array.deinit();

    const offs = array.offsets.items(i32);
    try std_testing.expectEqualSlices(i32, &[_]i32{ 0, 2, 2, 5 }, offs);
}

test "list of strings uses a variable-length child" {
    var builder = StringList.Builder.init(std.testing.allocator);
    defer builder.deinit();
    // [["a", "bb"], ["ccc"]]
    try builder.values.append("a");
    try builder.values.append("bb");
    try builder.appendList();
    try builder.values.append("ccc");
    try builder.appendList();

    var array = try builder.finish();
    defer array.deinit();

    try std_testing.expectEqual(@as(usize, 2), array.length);
    try std_testing.expectEqual(@as(usize, 2), array.valueLength(0));
    try std_testing.expectEqual(@as(usize, 1), array.valueLength(1));
    try std_testing.expectEqualStrings("a", array.values.get(0).?);
    try std_testing.expectEqualStrings("bb", array.values.get(1).?);
    try std_testing.expectEqualStrings("ccc", array.values.get(array.valueOffset(1)).?);
}

test "list array reports a list data type over its child" {
    var builder = Int32List.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.values.append(1);
    try builder.appendList();

    var array = try builder.finish();
    defer array.deinit();

    var ty = try array.dataType(std.testing.allocator);
    defer ty.deinit(std.testing.allocator);
    try std_testing.expect(ty == .list);
    try std_testing.expect(ty.list.equals(.int32));
}

test "nested list array reports a nested list data type" {
    const Int32ListList = ListArray(Int32List);
    var builder = Int32ListList.Builder.init(std.testing.allocator);
    defer builder.deinit();
    // [[[1]]]
    try builder.values.values.append(1);
    try builder.values.appendList();
    try builder.appendList();

    var array = try builder.finish();
    defer array.deinit();

    var ty = try array.dataType(std.testing.allocator);
    defer ty.deinit(std.testing.allocator);
    try std_testing.expect(ty == .list);
    try std_testing.expect(ty.list.* == .list);
    try std_testing.expect(ty.list.list.equals(.int32));
}

test "list dataType leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = ListArray(Int32List).Builder.init(allocator);
            defer builder.deinit();
            try builder.values.values.append(1);
            try builder.values.appendList();
            try builder.appendList();
            var array = try builder.finish();
            defer array.deinit();
            var ty = try array.dataType(allocator);
            ty.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "list array converts to type-erased array data with a child" {
    const allocator = std.testing.allocator;
    var builder = Int32List.Builder.init(allocator);
    defer builder.deinit();
    // [[1, 2], [3]]
    try builder.values.append(1);
    try builder.values.append(2);
    try builder.appendList();
    try builder.values.append(3);
    try builder.appendList();
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    try std_testing.expect(data.data_type == .list);
    try std_testing.expect(data.data_type.list.equals(.int32));
    try std_testing.expectEqual(@as(usize, 2), data.length);
    try std_testing.expectEqual(@as(usize, 2), data.buffers.len);
    try std_testing.expectEqual(@as(usize, 1), data.children.len);
    try std_testing.expect(data.children[0].data_type.equals(.int32));
    try std_testing.expectEqualSlices(i32, &[_]i32{ 0, 2, 3 }, data.buffers[1].?.items(i32));
}

test "list toData leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = Int32List.Builder.init(allocator);
            defer builder.deinit();
            try builder.values.append(1);
            try builder.appendList();
            try builder.appendNull();
            var array = try builder.finish();
            defer array.deinit();
            var data = try array.toData(allocator);
            data.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "list array round-trips through type-erased array data" {
    const allocator = std.testing.allocator;
    var builder = Int32List.Builder.init(allocator);
    defer builder.deinit();
    // [[1, 2], null, [3]]
    try builder.values.append(1);
    try builder.values.append(2);
    try builder.appendList();
    try builder.appendNull();
    try builder.values.append(3);
    try builder.appendList();
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    var rebuilt = try Int32List.fromData(allocator, data);
    defer rebuilt.deinit();

    try std_testing.expectEqual(@as(usize, 3), rebuilt.length);
    try std_testing.expectEqual(@as(usize, 1), rebuilt.null_count);
    try std_testing.expect(rebuilt.isValid(0));
    try std_testing.expect(!rebuilt.isValid(1));
    try std_testing.expectEqual(@as(usize, 2), rebuilt.valueLength(0));
    try std_testing.expectEqual(@as(usize, 1), rebuilt.valueLength(2));
    try std_testing.expectEqual(@as(?i32, 1), rebuilt.values.get(0));
    try std_testing.expectEqual(@as(?i32, 3), rebuilt.values.get(rebuilt.valueOffset(2)));
}

test "nested list array round-trips through type-erased array data" {
    const allocator = std.testing.allocator;
    const Int32ListList = ListArray(Int32List);
    var builder = Int32ListList.Builder.init(allocator);
    defer builder.deinit();
    // [[[1, 2]]]
    try builder.values.values.append(1);
    try builder.values.values.append(2);
    try builder.values.appendList();
    try builder.appendList();
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    var rebuilt = try Int32ListList.fromData(allocator, data);
    defer rebuilt.deinit();

    try std_testing.expectEqual(@as(usize, 1), rebuilt.length);
    try std_testing.expectEqual(@as(usize, 1), rebuilt.valueLength(0));
    try std_testing.expectEqual(@as(?i32, 2), rebuilt.values.values.get(1));
}

test "list fromData rejects a non-list type" {
    const allocator = std.testing.allocator;
    var builder = PrimitiveArray(i32).Builder.init(allocator);
    defer builder.deinit();
    try builder.append(1);
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    try std_testing.expectError(error.TypeMismatch, Int32List.fromData(allocator, data));
}

test "list fromData leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = Int32List.Builder.init(allocator);
            defer builder.deinit();
            try builder.values.append(1);
            try builder.appendList();
            try builder.appendNull();
            var array = try builder.finish();
            defer array.deinit();
            var data = try array.toData(allocator);
            defer data.deinit();
            var rebuilt = try Int32List.fromData(allocator, data);
            rebuilt.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "list builder finish leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = Int32List.Builder.init(allocator);
            defer builder.deinit();
            try builder.values.append(1);
            try builder.values.append(2);
            try builder.appendList();
            try builder.appendNull();
            try builder.values.append(3);
            try builder.appendList();
            var array = try builder.finish();
            array.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
