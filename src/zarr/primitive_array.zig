//! Fixed-width primitive arrays and their builder.
//!
//! A primitive array is the simplest Arrow array layout: a single values
//! buffer of fixed-width elements, plus an optional validity bitmap. Element
//! `i` is null when a validity bitmap is present and its bit `i` is clear.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const Bitmap = @import("bitmap.zig").Bitmap;
const DataType = @import("datatype.zig").DataType;
const ArrayData = @import("array_data.zig").ArrayData;

/// A fixed-width primitive array over element type `T`.
pub fn PrimitiveArray(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Values buffer holding `length` elements of type `T`.
        values: Buffer,
        /// Validity bitmap, present only when the array contains nulls.
        validity: ?Bitmap,
        /// Number of elements.
        length: usize,
        /// Number of null elements.
        null_count: usize,
        /// Arrow logical type. Defaults to the type derived from `T`, but a
        /// fixed-width temporal type such as `date32` or `timestamp` can be set
        /// through `Builder.initWithType`.
        logical_type: DataType,

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
            return self.logical_type;
        }

        /// Convert into the type-erased `ArrayData` layout, copying the buffers.
        /// The caller keeps ownership of this array and must release the
        /// returned data separately. A finished array is always a valid layout,
        /// so `init` validation cannot fail here.
        pub fn toData(self: Self, allocator: Allocator) Allocator.Error!ArrayData {
            const buffers = try allocator.alloc(?Buffer, 2);
            errdefer allocator.free(buffers);
            buffers[0] = null;
            buffers[1] = null;
            errdefer for (buffers) |*b| if (b.*) |*buf| buf.deinit();
            if (self.validity) |v| buffers[0] = try Buffer.dupe(allocator, v.buffer.data);
            buffers[1] = try Buffer.dupe(allocator, self.values.data);
            const children = try allocator.alloc(ArrayData, 0);
            errdefer allocator.free(children);
            return ArrayData.init(allocator, self.logical_type, self.length, self.null_count, buffers, children) catch unreachable;
        }

        /// Error set for `fromData`.
        pub const FromDataError = error{TypeMismatch} || Allocator.Error;

        /// Rebuild a typed array from the type-erased `ArrayData` layout,
        /// copying the buffers. The data's logical type must be fixed-width and
        /// match the storage width of `T`, and that logical type carries over to
        /// the rebuilt array so a `date32` or `timestamp` layout keeps its type.
        /// The caller keeps ownership of `data` and must release the returned
        /// array separately.
        pub fn fromData(allocator: Allocator, data: ArrayData) FromDataError!Self {
            if (!data.data_type.isFixedWidth() or data.data_type.bitWidth().? != @bitSizeOf(T)) {
                return error.TypeMismatch;
            }
            var values = try Buffer.dupe(allocator, data.buffers[1].?.data);
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
                .logical_type = data.data_type,
            };
        }

        /// The element at `i`, or null when it is not valid.
        pub fn get(self: Self, i: usize) ?T {
            if (!self.isValid(i)) return null;
            return self.values.items(T)[i];
        }

        /// Incrementally builds a `PrimitiveArray(T)`.
        pub const Builder = struct {
            allocator: Allocator,
            values: std.ArrayList(T),
            validity: std.ArrayList(bool),
            null_count: usize,
            logical_type: DataType,

            pub fn init(allocator: Allocator) Builder {
                return .{
                    .allocator = allocator,
                    .values = .empty,
                    .validity = .empty,
                    .null_count = 0,
                    .logical_type = DataType.fromZigType(T),
                };
            }

            /// Initialize a builder that stamps `logical_type` on the finished
            /// array instead of the type derived from `T`. The logical type
            /// must be fixed-width and match the storage width of `T`, as with
            /// `date32` over `i32` or `timestamp` over `i64`.
            pub fn initWithType(allocator: Allocator, logical_type: DataType) Builder {
                std.debug.assert(logical_type.isFixedWidth());
                std.debug.assert(logical_type.bitWidth().? == @bitSizeOf(T));
                return .{
                    .allocator = allocator,
                    .values = .empty,
                    .validity = .empty,
                    .null_count = 0,
                    .logical_type = logical_type,
                };
            }

            pub fn deinit(self: *Builder) void {
                self.values.deinit(self.allocator);
                self.validity.deinit(self.allocator);
                self.* = undefined;
            }

            /// Append a valid value.
            pub fn append(self: *Builder, value: T) Allocator.Error!void {
                try self.values.append(self.allocator, value);
                try self.validity.append(self.allocator, true);
            }

            /// Append a null slot.
            pub fn appendNull(self: *Builder) Allocator.Error!void {
                try self.values.append(self.allocator, undefined);
                try self.validity.append(self.allocator, false);
                self.null_count += 1;
            }

            /// Number of elements appended so far.
            pub fn len(self: Builder) usize {
                return self.values.items.len;
            }

            /// Consume the builder and produce the array. The builder is reset
            /// to empty and may be reused or deinitialized.
            pub fn finish(self: *Builder) Allocator.Error!Self {
                const length = self.values.items.len;
                var values = try Buffer.dupe(self.allocator, std.mem.sliceAsBytes(self.values.items));
                errdefer values.deinit();

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
                    .logical_type = self.logical_type,
                };
            }
        };
    };
}

test "builder produces an all-valid array" {
    var builder = PrimitiveArray(i32).Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(10);
    try builder.append(20);
    try builder.append(30);

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 3), array.length);
    try std.testing.expectEqual(@as(usize, 0), array.null_count);
    try std.testing.expect(array.validity == null);
    try std.testing.expectEqual(@as(?i32, 10), array.get(0));
    try std.testing.expectEqual(@as(?i32, 30), array.get(2));
    try std.testing.expect(array.isValid(1));
}

test "builder tracks nulls with a validity bitmap" {
    var builder = PrimitiveArray(f64).Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(1.5);
    try builder.appendNull();
    try builder.append(3.5);

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 3), array.length);
    try std.testing.expectEqual(@as(usize, 1), array.null_count);
    try std.testing.expect(array.validity != null);
    try std.testing.expectEqual(@as(?f64, 1.5), array.get(0));
    try std.testing.expectEqual(@as(?f64, null), array.get(1));
    try std.testing.expectEqual(@as(?f64, 3.5), array.get(2));
    try std.testing.expect(!array.isValid(1));
}

test "builder finish leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = PrimitiveArray(i32).Builder.init(allocator);
            defer builder.deinit();
            try builder.append(1);
            try builder.appendNull();
            try builder.append(3);
            var array = try builder.finish();
            array.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "array reports its Arrow data type" {
    var builder = PrimitiveArray(i32).Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(7);
    var array = try builder.finish();
    defer array.deinit();
    try std.testing.expectEqual(DataType.int32, array.dataType());

    var fbuilder = PrimitiveArray(f64).Builder.init(std.testing.allocator);
    defer fbuilder.deinit();
    try fbuilder.append(1.5);
    var farray = try fbuilder.finish();
    defer farray.deinit();
    try std.testing.expectEqual(DataType.float64, farray.dataType());
}

test "builder len reports the appended count" {
    var builder = PrimitiveArray(i32).Builder.init(std.testing.allocator);
    defer builder.deinit();
    try std.testing.expectEqual(@as(usize, 0), builder.len());
    try builder.append(1);
    try builder.appendNull();
    try std.testing.expectEqual(@as(usize, 2), builder.len());
}

test "primitive array converts to type-erased array data" {
    const allocator = std.testing.allocator;
    var builder = PrimitiveArray(i32).Builder.init(allocator);
    defer builder.deinit();
    try builder.append(1);
    try builder.appendNull();
    try builder.append(3);
    var array = try builder.finish();
    defer array.deinit();
    var data = try array.toData(allocator);
    defer data.deinit();

    try std.testing.expect(data.data_type.equals(.int32));
    try std.testing.expectEqual(@as(usize, 3), data.length);
    try std.testing.expectEqual(@as(usize, 1), data.null_count);
    try std.testing.expectEqual(@as(usize, 2), data.buffers.len);
    try std.testing.expect(data.validity() != null);
    try std.testing.expectEqual(@as(i32, 3), data.buffers[1].?.items(i32)[2]);
}

test "primitive array round-trips through type-erased array data" {
    const allocator = std.testing.allocator;
    var builder = PrimitiveArray(i32).Builder.init(allocator);
    defer builder.deinit();
    try builder.append(1);
    try builder.appendNull();
    try builder.append(3);
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    var rebuilt = try PrimitiveArray(i32).fromData(allocator, data);
    defer rebuilt.deinit();

    try std.testing.expectEqual(@as(usize, 3), rebuilt.length);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.null_count);
    try std.testing.expectEqual(@as(?i32, 1), rebuilt.get(0));
    try std.testing.expectEqual(@as(?i32, null), rebuilt.get(1));
    try std.testing.expectEqual(@as(?i32, 3), rebuilt.get(2));
    try std.testing.expectEqual(DataType.int32, rebuilt.dataType());
}

test "fromData preserves a temporal logical type" {
    const allocator = std.testing.allocator;
    var builder = PrimitiveArray(i64).Builder.initWithType(allocator, .{ .timestamp = .{ .unit = .microsecond } });
    defer builder.deinit();
    try builder.append(1_700_000_000_000_000);
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    var rebuilt = try PrimitiveArray(i64).fromData(allocator, data);
    defer rebuilt.deinit();

    try std.testing.expectEqual(DataType{ .timestamp = .{ .unit = .microsecond } }, rebuilt.dataType());
    try std.testing.expectEqual(@as(?i64, 1_700_000_000_000_000), rebuilt.get(0));
}

test "fromData rejects a width mismatch" {
    const allocator = std.testing.allocator;
    var builder = PrimitiveArray(i32).Builder.init(allocator);
    defer builder.deinit();
    try builder.append(1);
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    try std.testing.expectError(error.TypeMismatch, PrimitiveArray(i64).fromData(allocator, data));
}

test "fromData leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = PrimitiveArray(i32).Builder.init(allocator);
            defer builder.deinit();
            try builder.append(1);
            try builder.appendNull();
            var array = try builder.finish();
            defer array.deinit();
            var data = try array.toData(allocator);
            defer data.deinit();
            var rebuilt = try PrimitiveArray(i32).fromData(allocator, data);
            rebuilt.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "empty builder produces a zero-length array" {
    var builder = PrimitiveArray(u8).Builder.init(std.testing.allocator);
    defer builder.deinit();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 0), array.length);
    try std.testing.expectEqual(@as(usize, 0), array.null_count);
    try std.testing.expect(array.validity == null);
}

test "date32 array carries a temporal logical type over i32 storage" {
    var builder = PrimitiveArray(i32).Builder.initWithType(std.testing.allocator, .date32);
    defer builder.deinit();
    try builder.append(19_000); // days since the epoch
    try builder.appendNull();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(DataType.date32, array.dataType());
    try std.testing.expectEqual(@as(?i32, 19_000), array.get(0));
    try std.testing.expectEqual(@as(?i32, null), array.get(1));
}

test "timestamp array carries its time unit over i64 storage" {
    var builder = PrimitiveArray(i64).Builder.initWithType(std.testing.allocator, .{ .timestamp = .{ .unit = .microsecond } });
    defer builder.deinit();
    try builder.append(1_700_000_000_000_000);

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(DataType{ .timestamp = .{ .unit = .microsecond } }, array.dataType());
    try std.testing.expectEqual(@as(?i64, 1_700_000_000_000_000), array.get(0));
}

test "primitive array without an explicit type still derives it from T" {
    var builder = PrimitiveArray(i32).Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(1);
    var array = try builder.finish();
    defer array.deinit();
    try std.testing.expectEqual(DataType.int32, array.dataType());
}
