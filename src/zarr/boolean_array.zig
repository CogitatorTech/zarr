//! Boolean arrays and their builder.
//!
//! A boolean array stores its values in a bit-packed buffer, one bit per
//! element, LSB-numbered: element `i` lives at byte `i / 8`, bit `i % 8`. A set
//! bit means true. An optional validity bitmap marks null elements. This
//! matches the Arrow boolean layout, where both the values and the validity are
//! bitmaps rather than byte-per-element buffers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bitmap = @import("bitmap.zig").Bitmap;
const Buffer = @import("buffer.zig").Buffer;
const DataType = @import("datatype.zig").DataType;
const ArrayData = @import("array_data.zig").ArrayData;

/// A boolean array with a bit-packed values buffer.
pub const BooleanArray = struct {
    const Self = @This();

    /// Bit-packed values; bit `i` set means element `i` is true.
    values: Bitmap,
    /// Validity bitmap, present only when the array contains nulls.
    validity: ?Bitmap,
    /// Number of elements.
    length: usize,
    /// Number of null elements.
    null_count: usize,

    pub fn deinit(self: *Self) void {
        self.values.deinit();
        if (self.validity) |*v| v.deinit();
        self.* = undefined;
    }

    /// Whether element `i` is valid (non-null).
    pub fn isValid(self: Self, i: usize) bool {
        std.debug.assert(i < self.length);
        if (self.validity) |v| return v.isSet(i);
        return true;
    }

    /// The Arrow logical type of this array.
    pub fn dataType(self: Self) DataType {
        _ = self;
        return .boolean;
    }

    /// Convert into the type-erased `ArrayData` layout, copying the buffers.
    /// The caller keeps ownership of this array and must release the returned
    /// data separately.
    pub fn toData(self: Self, allocator: Allocator) Allocator.Error!ArrayData {
        const buffers = try allocator.alloc(?Buffer, 2);
        errdefer allocator.free(buffers);
        buffers[0] = null;
        buffers[1] = null;
        errdefer for (buffers) |*b| if (b.*) |*buf| buf.deinit();
        if (self.validity) |v| buffers[0] = try Buffer.dupe(allocator, v.buffer.data);
        buffers[1] = try Buffer.dupe(allocator, self.values.buffer.data);
        const children = try allocator.alloc(ArrayData, 0);
        errdefer allocator.free(children);
        return ArrayData.init(allocator, .boolean, self.length, self.null_count, buffers, children) catch unreachable;
    }

    /// Error set for `fromData`.
    pub const FromDataError = error{TypeMismatch} || Allocator.Error;

    /// Rebuild a boolean array from the type-erased `ArrayData` layout, copying
    /// the buffers. The data's logical type must be `boolean`. The caller keeps
    /// ownership of `data` and must release the returned array separately.
    pub fn fromData(allocator: Allocator, data: ArrayData) FromDataError!Self {
        if (data.data_type != .boolean) return error.TypeMismatch;
        var values = Bitmap.fromOwnedBuffer(try Buffer.dupe(allocator, data.buffers[1].?.data), data.length);
        errdefer values.deinit();

        var validity: ?Bitmap = null;
        if (data.validity()) |v| {
            validity = Bitmap.fromOwnedBuffer(try Buffer.dupe(allocator, v.data), data.length);
        }

        return .{
            .values = values,
            .validity = validity,
            .length = data.length,
            .null_count = data.null_count,
        };
    }

    /// The element at `i`, or null when it is not valid.
    pub fn get(self: Self, i: usize) ?bool {
        if (!self.isValid(i)) return null;
        return self.values.isSet(i);
    }

    /// Incrementally builds a `BooleanArray`.
    pub const Builder = struct {
        allocator: Allocator,
        values: std.ArrayList(bool),
        validity: std.ArrayList(bool),
        null_count: usize,

        pub fn init(allocator: Allocator) Builder {
            return .{
                .allocator = allocator,
                .values = .empty,
                .validity = .empty,
                .null_count = 0,
            };
        }

        pub fn deinit(self: *Builder) void {
            self.values.deinit(self.allocator);
            self.validity.deinit(self.allocator);
            self.* = undefined;
        }

        /// Append a valid value.
        pub fn append(self: *Builder, value: bool) Allocator.Error!void {
            try self.values.append(self.allocator, value);
            try self.validity.append(self.allocator, true);
        }

        /// Append a null slot. The stored value bit is false.
        pub fn appendNull(self: *Builder) Allocator.Error!void {
            try self.values.append(self.allocator, false);
            try self.validity.append(self.allocator, false);
            self.null_count += 1;
        }

        /// Number of elements appended so far.
        pub fn len(self: Builder) usize {
            return self.values.items.len;
        }

        /// Consume the builder and produce the array. The builder is reset to
        /// empty and may be reused or deinitialized.
        pub fn finish(self: *Builder) Allocator.Error!Self {
            const length = self.values.items.len;

            var values = try Bitmap.init(self.allocator, length);
            errdefer values.deinit();
            for (self.values.items, 0..) |v, i| {
                if (v) values.set(i);
            }

            var validity: ?Bitmap = null;
            if (self.null_count != 0) {
                var bm = try Bitmap.init(self.allocator, length);
                for (self.validity.items, 0..) |valid, i| {
                    if (valid) bm.set(i);
                }
                validity = bm;
            }

            const null_count = self.null_count;
            self.values.clearRetainingCapacity();
            self.validity.clearRetainingCapacity();
            self.null_count = 0;

            return .{
                .values = values,
                .validity = validity,
                .length = length,
                .null_count = null_count,
            };
        }
    };
};

test "boolean builder produces an all-valid array" {
    var builder = BooleanArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(true);
    try builder.append(false);
    try builder.append(true);

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 3), array.length);
    try std.testing.expectEqual(@as(usize, 0), array.null_count);
    try std.testing.expect(array.validity == null);
    try std.testing.expectEqual(@as(?bool, true), array.get(0));
    try std.testing.expectEqual(@as(?bool, false), array.get(1));
    try std.testing.expectEqual(@as(?bool, true), array.get(2));
    try std.testing.expect(array.isValid(1));
}

test "boolean builder tracks nulls with a validity bitmap" {
    var builder = BooleanArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(true);
    try builder.appendNull();
    try builder.append(false);

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 3), array.length);
    try std.testing.expectEqual(@as(usize, 1), array.null_count);
    try std.testing.expect(array.validity != null);
    try std.testing.expectEqual(@as(?bool, true), array.get(0));
    try std.testing.expectEqual(@as(?bool, null), array.get(1));
    try std.testing.expectEqual(@as(?bool, false), array.get(2));
    try std.testing.expect(!array.isValid(1));
}

test "boolean builder distinguishes false from null" {
    var builder = BooleanArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(false);
    try builder.appendNull();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 2), array.length);
    try std.testing.expectEqual(@as(usize, 1), array.null_count);
    try std.testing.expect(array.isValid(0));
    try std.testing.expectEqual(@as(?bool, false), array.get(0));
    try std.testing.expectEqual(@as(?bool, null), array.get(1));
}

test "empty boolean builder produces a zero-length array" {
    var builder = BooleanArray.Builder.init(std.testing.allocator);
    defer builder.deinit();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 0), array.length);
    try std.testing.expectEqual(@as(usize, 0), array.null_count);
    try std.testing.expect(array.validity == null);
}

test "boolean values pack across a byte boundary" {
    var builder = BooleanArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    // 10 elements, alternating, so bit 8 and bit 9 land in the second byte.
    var i: usize = 0;
    while (i < 10) : (i += 1) try builder.append(i % 2 == 0);

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 10), array.length);
    i = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expectEqual(@as(?bool, i % 2 == 0), array.get(i));
    }
}

test "boolean all-null array" {
    var builder = BooleanArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.appendNull();
    try builder.appendNull();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 2), array.length);
    try std.testing.expectEqual(@as(usize, 2), array.null_count);
    try std.testing.expectEqual(@as(?bool, null), array.get(0));
    try std.testing.expectEqual(@as(?bool, null), array.get(1));
}

test "boolean array reports its Arrow data type" {
    var builder = BooleanArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(true);
    var array = try builder.finish();
    defer array.deinit();
    try std.testing.expectEqual(DataType.boolean, array.dataType());
}

test "boolean builder len reports the appended count" {
    var builder = BooleanArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try std.testing.expectEqual(@as(usize, 0), builder.len());
    try builder.append(true);
    try builder.appendNull();
    try std.testing.expectEqual(@as(usize, 2), builder.len());
}

test "boolean array converts to type-erased array data" {
    const allocator = std.testing.allocator;
    var builder = BooleanArray.Builder.init(allocator);
    defer builder.deinit();
    try builder.append(true);
    try builder.appendNull();
    try builder.append(false);
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    try std.testing.expect(data.data_type.equals(.boolean));
    try std.testing.expectEqual(@as(usize, 3), data.length);
    try std.testing.expectEqual(@as(usize, 1), data.null_count);
    try std.testing.expectEqual(@as(usize, 2), data.buffers.len);
    try std.testing.expect(data.validity() != null);
}

test "boolean toData leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = BooleanArray.Builder.init(allocator);
            defer builder.deinit();
            try builder.append(true);
            try builder.appendNull();
            var array = try builder.finish();
            defer array.deinit();
            var data = try array.toData(allocator);
            data.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "boolean array round-trips through type-erased array data" {
    const allocator = std.testing.allocator;
    var builder = BooleanArray.Builder.init(allocator);
    defer builder.deinit();
    try builder.append(true);
    try builder.appendNull();
    try builder.append(false);
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    var rebuilt = try BooleanArray.fromData(allocator, data);
    defer rebuilt.deinit();

    try std.testing.expectEqual(@as(usize, 3), rebuilt.length);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.null_count);
    try std.testing.expectEqual(@as(?bool, true), rebuilt.get(0));
    try std.testing.expectEqual(@as(?bool, null), rebuilt.get(1));
    try std.testing.expectEqual(@as(?bool, false), rebuilt.get(2));
}

test "boolean fromData rejects a non-boolean type" {
    const allocator = std.testing.allocator;
    const values = try Buffer.alloc(allocator, @sizeOf(i32));
    const buffers = try allocator.alloc(?Buffer, 2);
    buffers[0] = null;
    buffers[1] = values;
    const children = try allocator.alloc(ArrayData, 0);
    var data = try ArrayData.init(allocator, .int32, 1, 0, buffers, children);
    defer data.deinit();

    try std.testing.expectError(error.TypeMismatch, BooleanArray.fromData(allocator, data));
}

test "boolean fromData leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = BooleanArray.Builder.init(allocator);
            defer builder.deinit();
            try builder.append(true);
            try builder.appendNull();
            var array = try builder.finish();
            defer array.deinit();
            var data = try array.toData(allocator);
            defer data.deinit();
            var rebuilt = try BooleanArray.fromData(allocator, data);
            rebuilt.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "boolean builder finish leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = BooleanArray.Builder.init(allocator);
            defer builder.deinit();
            try builder.append(true);
            try builder.appendNull();
            try builder.append(false);
            var array = try builder.finish();
            array.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
