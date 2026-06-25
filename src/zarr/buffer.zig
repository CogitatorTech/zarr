//! Owned, aligned memory buffers, the lowest layer of the Arrow memory model.
//!
//! Every Arrow array is ultimately a small set of buffers (validity bitmap, offsets, and values).
//! The Arrow spec recommends 64-byte alignment so buffers line up with cache lines and SIMD register widths.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Arrow-recommended buffer alignment.
pub const buffer_alignment: std.mem.Alignment = .@"64";

/// An allocator-owned, 64-byte-aligned, contiguous block of bytes.
pub const Buffer = struct {
    data: []align(buffer_alignment.toByteUnits()) u8,
    allocator: Allocator,

    /// Allocate an uninitialized buffer of `size` bytes.
    pub fn alloc(allocator: Allocator, size: usize) Allocator.Error!Buffer {
        const data = try allocator.alignedAlloc(u8, buffer_alignment, size);
        return .{ .data = data, .allocator = allocator };
    }

    /// Allocate a zero-initialized buffer of `size` bytes.
    pub fn allocZeroed(allocator: Allocator, size: usize) Allocator.Error!Buffer {
        const buf = try alloc(allocator, size);
        @memset(buf.data, 0);
        return buf;
    }

    /// Allocate a buffer holding a copy of `bytes`.
    pub fn dupe(allocator: Allocator, bytes: []const u8) Allocator.Error!Buffer {
        const buf = try alloc(allocator, bytes.len);
        @memcpy(buf.data, bytes);
        return buf;
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    pub fn len(self: Buffer) usize {
        return self.data.len;
    }

    /// View the buffer contents as a slice of fixed-width values.
    /// The buffer length must be a multiple of `@sizeOf(T)`.
    pub fn items(self: Buffer, comptime T: type) []T {
        return @alignCast(std.mem.bytesAsSlice(T, self.data));
    }
};

test "alloc is 64-byte aligned" {
    var buf = try Buffer.alloc(std.testing.allocator, 100);
    defer buf.deinit();
    try std.testing.expectEqual(@as(usize, 100), buf.len());
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(buf.data.ptr) % 64);
}

test "allocZeroed produces zeroed memory" {
    var buf = try Buffer.allocZeroed(std.testing.allocator, 32);
    defer buf.deinit();
    for (buf.data) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "typed view over buffer" {
    var buf = try Buffer.alloc(std.testing.allocator, 4 * @sizeOf(i32));
    defer buf.deinit();
    const vals = buf.items(i32);
    for (vals, 0..) |*v, i| v.* = @intCast(i * 10);
    try std.testing.expectEqual(@as(i32, 30), buf.items(i32)[3]);
}

test "dupe copies bytes" {
    var buf = try Buffer.dupe(std.testing.allocator, "arrow");
    defer buf.deinit();
    try std.testing.expectEqualStrings("arrow", buf.data);
}
