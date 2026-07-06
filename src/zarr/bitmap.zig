//! Validity bitmaps.
//!
//! Arrow encodes null/not-null per element as one bit, LSB-numbered: element
//! `i` lives at byte `i / 8`, bit `i % 8`. A set bit means "valid" (non-null).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;

pub const Bitmap = struct {
    buffer: Buffer,
    /// Number of addressable bits (elements), not bytes.
    bit_len: usize,

    /// Allocate a bitmap with all bits cleared (all-null).
    pub fn init(allocator: Allocator, bit_len: usize) Allocator.Error!Bitmap {
        const byte_len = (bit_len + 7) / 8;
        return .{
            .buffer = try Buffer.allocZeroed(allocator, byte_len),
            .bit_len = bit_len,
        };
    }

    /// Wrap an already-populated buffer as a bitmap of `bit_len` bits, taking
    /// ownership of `buffer`. Used to rebuild a bitmap from a type-erased
    /// validity buffer.
    pub fn fromOwnedBuffer(buffer: Buffer, bit_len: usize) Bitmap {
        std.debug.assert(buffer.data.len >= (bit_len + 7) / 8);
        return .{ .buffer = buffer, .bit_len = bit_len };
    }

    pub fn deinit(self: *Bitmap) void {
        self.buffer.deinit();
        self.* = undefined;
    }

    pub fn isSet(self: Bitmap, i: usize) bool {
        std.debug.assert(i < self.bit_len);
        return self.buffer.data[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
    }

    pub fn set(self: *Bitmap, i: usize) void {
        std.debug.assert(i < self.bit_len);
        self.buffer.data[i / 8] |= @as(u8, 1) << @intCast(i % 8);
    }

    pub fn unset(self: *Bitmap, i: usize) void {
        std.debug.assert(i < self.bit_len);
        self.buffer.data[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
    }

    pub fn setValue(self: *Bitmap, i: usize, value: bool) void {
        if (value) self.set(i) else self.unset(i);
    }

    /// Number of set (valid) bits.
    pub fn countSet(self: Bitmap) usize {
        var total: usize = 0;
        const full_bytes = self.bit_len / 8;
        for (self.buffer.data[0..full_bytes]) |b| total += @popCount(b);
        const rem: u3 = @intCast(self.bit_len % 8);
        if (rem != 0) {
            const mask = (@as(u8, 1) << rem) - 1;
            total += @popCount(self.buffer.data[full_bytes] & mask);
        }
        return total;
    }
};

test "init starts all-null" {
    var bm = try Bitmap.init(std.testing.allocator, 10);
    defer bm.deinit();
    try std.testing.expectEqual(@as(usize, 0), bm.countSet());
    try std.testing.expect(!bm.isSet(0));
}

test "set, unset, and setValue" {
    var bm = try Bitmap.init(std.testing.allocator, 20);
    defer bm.deinit();
    bm.set(0);
    bm.set(9);
    bm.set(19);
    try std.testing.expect(bm.isSet(9));
    try std.testing.expectEqual(@as(usize, 3), bm.countSet());
    bm.unset(9);
    try std.testing.expect(!bm.isSet(9));
    bm.setValue(1, true);
    try std.testing.expectEqual(@as(usize, 3), bm.countSet());
}

test "fromOwnedBuffer wraps an existing buffer" {
    var buffer = try Buffer.allocZeroed(std.testing.allocator, 1);
    buffer.data[0] = 0b0000_0101;
    var bm = Bitmap.fromOwnedBuffer(buffer, 3);
    defer bm.deinit();
    try std.testing.expect(bm.isSet(0));
    try std.testing.expect(!bm.isSet(1));
    try std.testing.expect(bm.isSet(2));
    try std.testing.expectEqual(@as(usize, 2), bm.countSet());
}

test "countSet masks trailing bits in the last byte" {
    var bm = try Bitmap.init(std.testing.allocator, 3);
    defer bm.deinit();
    // Dirty the unused high bits of the final byte directly; they must not count.
    bm.buffer.data[0] = 0b1111_1000;
    try std.testing.expectEqual(@as(usize, 0), bm.countSet());
    bm.set(2);
    try std.testing.expectEqual(@as(usize, 1), bm.countSet());
}
