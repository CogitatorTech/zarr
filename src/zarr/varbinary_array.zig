//! Variable-length binary and UTF-8 arrays and their builder.
//!
//! The variable-length layout stores three buffers: an optional validity
//! bitmap, an i32 offsets buffer of `length + 1` entries, and a values buffer
//! holding the concatenated element bytes. Element `i` occupies
//! `values[offsets[i]..offsets[i + 1]]`. Offsets are monotonically
//! non-decreasing and `offsets[0]` is zero. The UTF-8 variant validates that
//! each appended element is well-formed UTF-8.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const Bitmap = @import("bitmap.zig").Bitmap;
const DataType = @import("datatype.zig").DataType;
const ArrayData = @import("array_data.zig").ArrayData;

/// Error returned when a UTF-8 array is given bytes that are not valid UTF-8.
pub const Utf8Error = error{InvalidUtf8};

/// A variable-length array over byte-string elements. When `is_utf8` is true,
/// appended elements are validated as well-formed UTF-8. `OffsetInt` is the
/// offset width: `i32` for the standard layout, or `i64` for the large layout.
pub fn VarBinaryArray(comptime is_utf8: bool, comptime OffsetInt: type) type {
    if (OffsetInt != i32 and OffsetInt != i64) {
        @compileError("VarBinaryArray offsets must be i32 or i64, not " ++ @typeName(OffsetInt));
    }
    return struct {
        const Self = @This();

        /// Error set for `Builder.append`.
        pub const AppendError = if (is_utf8) (Allocator.Error || Utf8Error) else Allocator.Error;

        /// Concatenated element bytes.
        values: Buffer,
        /// `OffsetInt` offsets, `length + 1` entries; element `i` spans
        /// `offsets[i]..offsets[i + 1]`.
        offsets: Buffer,
        /// Validity bitmap, present only when the array contains nulls.
        validity: ?Bitmap,
        /// Number of elements.
        length: usize,
        /// Number of null elements.
        null_count: usize,

        pub fn deinit(self: *Self) void {
            self.values.deinit();
            self.offsets.deinit();
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
            if (OffsetInt == i64) return if (is_utf8) .large_utf8 else .large_binary;
            return if (is_utf8) .utf8 else .binary;
        }

        /// Convert into the type-erased `ArrayData` layout, copying the
        /// buffers. The caller keeps ownership of this array and must release
        /// the returned data separately.
        pub fn toData(self: Self, allocator: Allocator) Allocator.Error!ArrayData {
            const buffers = try allocator.alloc(?Buffer, 3);
            errdefer allocator.free(buffers);
            buffers[0] = null;
            buffers[1] = null;
            buffers[2] = null;
            errdefer for (buffers) |*b| if (b.*) |*buf| buf.deinit();
            if (self.validity) |v| buffers[0] = try Buffer.dupe(allocator, v.buffer.data);
            buffers[1] = try Buffer.dupe(allocator, self.offsets.data);
            buffers[2] = try Buffer.dupe(allocator, self.values.data);
            const children = try allocator.alloc(ArrayData, 0);
            errdefer allocator.free(children);
            return ArrayData.init(allocator, self.dataType(), self.length, self.null_count, buffers, children) catch unreachable;
        }

        /// Error set for `fromData`.
        pub const FromDataError = error{TypeMismatch} || Allocator.Error;

        /// Rebuild a variable-length array from the type-erased `ArrayData`
        /// layout, copying the buffers. The data's logical type must match this
        /// specialization's offset width and binary/utf8 flavor. The caller
        /// keeps ownership of `data` and must release the returned array separately.
        pub fn fromData(allocator: Allocator, data: ArrayData) FromDataError!Self {
            const expected: DataType = if (OffsetInt == i64)
                (if (is_utf8) .large_utf8 else .large_binary)
            else
                (if (is_utf8) .utf8 else .binary);
            if (!data.data_type.equals(expected)) return error.TypeMismatch;

            var offsets = try Buffer.dupe(allocator, data.buffers[1].?.data);
            errdefer offsets.deinit();
            var values = try Buffer.dupe(allocator, data.buffers[2].?.data);
            errdefer values.deinit();

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

        /// The element bytes at `i`, or null when it is not valid.
        pub fn get(self: Self, i: usize) ?[]const u8 {
            if (!self.isValid(i)) return null;
            const offs = self.offsets.items(OffsetInt);
            const start: usize = @intCast(offs[i]);
            const end: usize = @intCast(offs[i + 1]);
            return self.values.data[start..end];
        }

        /// Incrementally builds a `VarBinaryArray`.
        pub const Builder = struct {
            allocator: Allocator,
            values: std.ArrayList(u8),
            /// End offset after each appended element.
            offsets: std.ArrayList(OffsetInt),
            validity: std.ArrayList(bool),
            null_count: usize,

            pub fn init(allocator: Allocator) Builder {
                return .{
                    .allocator = allocator,
                    .values = .empty,
                    .offsets = .empty,
                    .validity = .empty,
                    .null_count = 0,
                };
            }

            pub fn deinit(self: *Builder) void {
                self.values.deinit(self.allocator);
                self.offsets.deinit(self.allocator);
                self.validity.deinit(self.allocator);
                self.* = undefined;
            }

            /// Append a valid element. For the UTF-8 variant, returns
            /// `error.InvalidUtf8` when `bytes` is not well-formed UTF-8.
            pub fn append(self: *Builder, bytes: []const u8) AppendError!void {
                if (is_utf8 and !std.unicode.utf8ValidateSlice(bytes)) {
                    return error.InvalidUtf8;
                }
                try self.values.appendSlice(self.allocator, bytes);
                try self.offsets.append(self.allocator, @intCast(self.values.items.len));
                try self.validity.append(self.allocator, true);
            }

            /// Append a null slot. The element spans zero bytes.
            pub fn appendNull(self: *Builder) Allocator.Error!void {
                try self.offsets.append(self.allocator, @intCast(self.values.items.len));
                try self.validity.append(self.allocator, false);
                self.null_count += 1;
            }

            /// Number of elements appended so far.
            pub fn len(self: Builder) usize {
                return self.offsets.items.len;
            }

            /// Consume the builder and produce the array. The builder is reset
            /// to empty and may be reused or deinitialized.
            pub fn finish(self: *Builder) Allocator.Error!Self {
                const length = self.offsets.items.len;

                var values = try Buffer.dupe(self.allocator, self.values.items);
                errdefer values.deinit();

                const offsets = try Buffer.alloc(self.allocator, (length + 1) * @sizeOf(OffsetInt));
                errdefer self.allocator.free(offsets.data);
                const offs = offsets.items(OffsetInt);
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

                const null_count = self.null_count;
                self.values.clearRetainingCapacity();
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

const BinaryArray = VarBinaryArray(false, i32);
const Utf8Array = VarBinaryArray(true, i32);
const LargeBinaryArray = VarBinaryArray(false, i64);
const LargeUtf8Array = VarBinaryArray(true, i64);

test "binary builder produces an all-valid array" {
    var builder = BinaryArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append("foo");
    try builder.append("bar");

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 2), array.length);
    try std.testing.expectEqual(@as(usize, 0), array.null_count);
    try std.testing.expect(array.validity == null);
    try std.testing.expectEqualStrings("foo", array.get(0).?);
    try std.testing.expectEqualStrings("bar", array.get(1).?);
}

test "binary builder tracks nulls with a validity bitmap" {
    var builder = BinaryArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append("a");
    try builder.appendNull();
    try builder.append("bcd");

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 3), array.length);
    try std.testing.expectEqual(@as(usize, 1), array.null_count);
    try std.testing.expect(array.validity != null);
    try std.testing.expectEqualStrings("a", array.get(0).?);
    try std.testing.expect(array.get(1) == null);
    try std.testing.expectEqualStrings("bcd", array.get(2).?);
}

test "binary builder distinguishes empty string from null" {
    var builder = BinaryArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append("");
    try builder.appendNull();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 2), array.length);
    try std.testing.expectEqual(@as(usize, 1), array.null_count);
    try std.testing.expect(array.isValid(0));
    try std.testing.expectEqualStrings("", array.get(0).?);
    try std.testing.expect(array.get(1) == null);
}

test "empty binary builder produces a zero-length array" {
    var builder = BinaryArray.Builder.init(std.testing.allocator);
    defer builder.deinit();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 0), array.length);
    try std.testing.expectEqual(@as(usize, 0), array.null_count);
    try std.testing.expect(array.validity == null);
    // Offsets always carry the leading zero, even when empty.
    try std.testing.expectEqual(@as(usize, 1), array.offsets.items(i32).len);
    try std.testing.expectEqual(@as(i32, 0), array.offsets.items(i32)[0]);
}

test "binary offsets are monotonic with a leading zero" {
    var builder = BinaryArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append("ab");
    try builder.appendNull();
    try builder.append("cde");

    var array = try builder.finish();
    defer array.deinit();

    const offs = array.offsets.items(i32);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 0, 2, 2, 5 }, offs);
}

test "binary all-null array" {
    var builder = BinaryArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.appendNull();
    try builder.appendNull();

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 2), array.length);
    try std.testing.expectEqual(@as(usize, 2), array.null_count);
    try std.testing.expect(array.get(0) == null);
    try std.testing.expect(array.get(1) == null);
}

test "utf8 builder accepts valid UTF-8" {
    var builder = Utf8Array.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append("héllo");
    try builder.append("世界");

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 2), array.length);
    try std.testing.expectEqualStrings("héllo", array.get(0).?);
    try std.testing.expectEqualStrings("世界", array.get(1).?);
}

test "binary and utf8 arrays report their Arrow data types" {
    var bbuilder = BinaryArray.Builder.init(std.testing.allocator);
    defer bbuilder.deinit();
    try bbuilder.append("x");
    var barray = try bbuilder.finish();
    defer barray.deinit();
    try std.testing.expectEqual(DataType.binary, barray.dataType());

    var ubuilder = Utf8Array.Builder.init(std.testing.allocator);
    defer ubuilder.deinit();
    try ubuilder.append("x");
    var uarray = try ubuilder.finish();
    defer uarray.deinit();
    try std.testing.expectEqual(DataType.utf8, uarray.dataType());
}

test "binary builder len reports the appended count" {
    var builder = BinaryArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try std.testing.expectEqual(@as(usize, 0), builder.len());
    try builder.append("x");
    try builder.appendNull();
    try std.testing.expectEqual(@as(usize, 2), builder.len());
}

test "utf8 builder rejects invalid UTF-8" {
    var builder = Utf8Array.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try std.testing.expectError(error.InvalidUtf8, builder.append(&[_]u8{ 0xFF, 0xFE }));
}

test "large binary builder uses 64-bit offsets" {
    var builder = LargeBinaryArray.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append("ab");
    try builder.appendNull();
    try builder.append("cde");

    var array = try builder.finish();
    defer array.deinit();

    try std.testing.expectEqual(@as(usize, 3), array.length);
    try std.testing.expectEqual(@as(usize, 1), array.null_count);
    try std.testing.expectEqualStrings("ab", array.get(0).?);
    try std.testing.expect(array.get(1) == null);
    try std.testing.expectEqualStrings("cde", array.get(2).?);
    const offs = array.offsets.items(i64);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 0, 2, 2, 5 }, offs);
}

test "large binary and large utf8 arrays report their Arrow data types" {
    var bbuilder = LargeBinaryArray.Builder.init(std.testing.allocator);
    defer bbuilder.deinit();
    try bbuilder.append("x");
    var barray = try bbuilder.finish();
    defer barray.deinit();
    try std.testing.expectEqual(DataType.large_binary, barray.dataType());

    var ubuilder = LargeUtf8Array.Builder.init(std.testing.allocator);
    defer ubuilder.deinit();
    try ubuilder.append("y");
    var uarray = try ubuilder.finish();
    defer uarray.deinit();
    try std.testing.expectEqual(DataType.large_utf8, uarray.dataType());
}

test "binary array converts to type-erased array data" {
    const allocator = std.testing.allocator;
    var builder = BinaryArray.Builder.init(allocator);
    defer builder.deinit();
    try builder.append("ab");
    try builder.appendNull();
    try builder.append("cde");
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    try std.testing.expect(data.data_type.equals(.binary));
    try std.testing.expectEqual(@as(usize, 3), data.length);
    try std.testing.expectEqual(@as(usize, 3), data.buffers.len);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 0, 2, 2, 5 }, data.buffers[1].?.items(i32));
    try std.testing.expectEqualStrings("abcde", data.buffers[2].?.data);
}

test "large utf8 converts to type-erased array data with 64-bit offsets" {
    const allocator = std.testing.allocator;
    var builder = LargeUtf8Array.Builder.init(allocator);
    defer builder.deinit();
    try builder.append("hi");
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    try std.testing.expect(data.data_type.equals(.large_utf8));
    try std.testing.expectEqualSlices(i64, &[_]i64{ 0, 2 }, data.buffers[1].?.items(i64));
}

test "varbinary toData leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = BinaryArray.Builder.init(allocator);
            defer builder.deinit();
            try builder.append("ab");
            try builder.appendNull();
            var array = try builder.finish();
            defer array.deinit();
            var data = try array.toData(allocator);
            data.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "binary array round-trips through type-erased array data" {
    const allocator = std.testing.allocator;
    var builder = BinaryArray.Builder.init(allocator);
    defer builder.deinit();
    try builder.append("ab");
    try builder.appendNull();
    try builder.append("cde");
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    var rebuilt = try BinaryArray.fromData(allocator, data);
    defer rebuilt.deinit();

    try std.testing.expectEqual(@as(usize, 3), rebuilt.length);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.null_count);
    try std.testing.expectEqualStrings("ab", rebuilt.get(0).?);
    try std.testing.expect(rebuilt.get(1) == null);
    try std.testing.expectEqualStrings("cde", rebuilt.get(2).?);
}

test "large utf8 round-trips through type-erased array data" {
    const allocator = std.testing.allocator;
    var builder = LargeUtf8Array.Builder.init(allocator);
    defer builder.deinit();
    try builder.append("世界");
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    var rebuilt = try LargeUtf8Array.fromData(allocator, data);
    defer rebuilt.deinit();

    try std.testing.expectEqual(DataType.large_utf8, rebuilt.dataType());
    try std.testing.expectEqualStrings("世界", rebuilt.get(0).?);
}

test "varbinary fromData rejects a mismatched offset width" {
    const allocator = std.testing.allocator;
    // Build i32-offset utf8 data, then try to read it as a 64-bit layout.
    var builder = Utf8Array.Builder.init(allocator);
    defer builder.deinit();
    try builder.append("x");
    var array = try builder.finish();
    defer array.deinit();

    var data = try array.toData(allocator);
    defer data.deinit();

    try std.testing.expectError(error.TypeMismatch, LargeUtf8Array.fromData(allocator, data));
}

test "varbinary fromData leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var builder = BinaryArray.Builder.init(allocator);
            defer builder.deinit();
            try builder.append("ab");
            try builder.appendNull();
            var array = try builder.finish();
            defer array.deinit();
            var data = try array.toData(allocator);
            defer data.deinit();
            var rebuilt = try BinaryArray.fromData(allocator, data);
            rebuilt.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "large utf8 builder validates UTF-8" {
    var builder = LargeUtf8Array.Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append("世界");
    var array = try builder.finish();
    defer array.deinit();
    try std.testing.expectEqualStrings("世界", array.get(0).?);
    try std.testing.expectError(error.InvalidUtf8, builder.append(&[_]u8{0xFF}));
}
