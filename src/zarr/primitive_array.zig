//! Fixed-width primitive arrays and their builder.
//!
//! A primitive array is the simplest Arrow array layout: a single values
//! buffer of fixed-width elements, plus an optional validity bitmap. Element
//! `i` is null when a validity bitmap is present and its bit `i` is clear.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const Bitmap = @import("bitmap.zig").Bitmap;

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

            /// Consume the builder and produce the array. The builder is reset
            /// to empty and may be reused or deinitialized.
            pub fn finish(self: *Builder) Allocator.Error!Self {
                const length = self.values.items.len;
                const values = try Buffer.dupe(self.allocator, std.mem.sliceAsBytes(self.values.items));

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

test "empty builder produces a zero-length array" {
    var builder = PrimitiveArray(u8).Builder.init(std.testing.allocator);
    defer builder.deinit();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 0), array.length);
    try std.testing.expectEqual(@as(usize, 0), array.null_count);
    try std.testing.expect(array.validity == null);
}
