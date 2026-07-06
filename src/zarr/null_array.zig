//! Null arrays.
//!
//! A null array is the degenerate Arrow layout: every element is null, so it
//! carries no buffers at all, not even a validity bitmap. Only its length is
//! stored, and the null count always equals the length. It exists so a column
//! of an all-null field can participate in schemas, struct arrays, and record
//! batches like any other array.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const DataType = @import("datatype.zig").DataType;
const ArrayData = @import("array_data.zig").ArrayData;

/// An array whose every element is null.
pub const NullArray = struct {
    const Self = @This();

    /// Number of elements, all null.
    length: usize,
    /// Number of null elements, always equal to `length`.
    null_count: usize,

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    /// Whether element `i` is valid. A null array has no valid elements.
    pub fn isValid(self: Self, i: usize) bool {
        std.debug.assert(i < self.length);
        return false;
    }

    /// The Arrow logical type of this array.
    pub fn dataType(self: Self) DataType {
        _ = self;
        return .null;
    }

    /// Convert into the type-erased `ArrayData` layout. A null array owns no
    /// buffers, so this only records the length and null count. The caller
    /// keeps ownership of this array and must release the returned data
    /// separately.
    pub fn toData(self: Self, allocator: Allocator) Allocator.Error!ArrayData {
        const buffers = try allocator.alloc(?Buffer, 0);
        errdefer allocator.free(buffers);
        const children = try allocator.alloc(ArrayData, 0);
        errdefer allocator.free(children);
        return ArrayData.init(allocator, .null, self.length, self.null_count, buffers, children) catch unreachable;
    }

    /// Rebuild a null array from the type-erased `ArrayData` layout. The data's
    /// logical type must be `null`. The `allocator` is accepted for a uniform
    /// `fromData` signature across array types but is not used, since a null
    /// array owns no buffers. The caller keeps ownership of `data`.
    pub fn fromData(allocator: Allocator, data: ArrayData) error{TypeMismatch}!Self {
        _ = allocator;
        if (data.data_type != .null) return error.TypeMismatch;
        return .{ .length = data.length, .null_count = data.null_count };
    }

    /// Incrementally builds a `NullArray`.
    pub const Builder = struct {
        length: usize,

        pub fn init(allocator: Allocator) Builder {
            _ = allocator;
            return .{ .length = 0 };
        }

        pub fn deinit(self: *Builder) void {
            self.* = undefined;
        }

        /// Append a null slot. A null array holds nothing but nulls.
        pub fn appendNull(self: *Builder) Allocator.Error!void {
            self.length += 1;
        }

        /// Number of elements appended so far.
        pub fn len(self: Builder) usize {
            return self.length;
        }

        /// Consume the builder and produce the array. The builder is reset to
        /// empty and may be reused or deinitialized.
        pub fn finish(self: *Builder) Allocator.Error!Self {
            const length = self.length;
            self.length = 0;
            return .{ .length = length, .null_count = length };
        }
    };
};

test "null builder produces an all-null array" {
    var builder = NullArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.appendNull();
    try builder.appendNull();
    try builder.appendNull();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 3), array.length);
    try std.testing.expectEqual(@as(usize, 3), array.null_count);
    try std.testing.expect(!array.isValid(0));
    try std.testing.expect(!array.isValid(2));
}

test "empty null builder produces a zero-length array" {
    var builder = NullArray.Builder.init(std.testing.allocator);
    defer builder.deinit();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 0), array.length);
    try std.testing.expectEqual(@as(usize, 0), array.null_count);
}

test "null array reports its Arrow data type" {
    var builder = NullArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.appendNull();
    var array = try builder.finish();
    defer array.deinit();
    try std.testing.expectEqual(DataType.null, array.dataType());
}

test "null array converts to type-erased array data" {
    const allocator = std.testing.allocator;
    var builder = NullArray.Builder.init(allocator);
    defer builder.deinit();
    try builder.appendNull();
    try builder.appendNull();
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    try std.testing.expect(data.data_type.equals(.null));
    try std.testing.expectEqual(@as(usize, 2), data.length);
    try std.testing.expectEqual(@as(usize, 2), data.null_count);
    try std.testing.expectEqual(@as(usize, 0), data.buffers.len);
}

test "null array round-trips through type-erased array data" {
    const allocator = std.testing.allocator;
    var builder = NullArray.Builder.init(allocator);
    defer builder.deinit();
    try builder.appendNull();
    try builder.appendNull();
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    var rebuilt = try NullArray.fromData(allocator, data);
    defer rebuilt.deinit();

    try std.testing.expectEqual(@as(usize, 2), rebuilt.length);
    try std.testing.expectEqual(@as(usize, 2), rebuilt.null_count);
}

test "null fromData rejects a non-null type" {
    const allocator = std.testing.allocator;
    const values = try Buffer.alloc(allocator, @sizeOf(i32));
    const buffers = try allocator.alloc(?Buffer, 2);
    buffers[0] = null;
    buffers[1] = values;
    const children = try allocator.alloc(ArrayData, 0);
    var data = try ArrayData.init(allocator, .int32, 1, 0, buffers, children);
    defer data.deinit();

    try std.testing.expectError(error.TypeMismatch, NullArray.fromData(allocator, data));
}

test "null builder len reports the appended count" {
    var builder = NullArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try std.testing.expectEqual(@as(usize, 0), builder.len());
    try builder.appendNull();
    try builder.appendNull();
    try std.testing.expectEqual(@as(usize, 2), builder.len());
}
