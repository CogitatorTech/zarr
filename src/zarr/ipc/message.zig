//! Arrow IPC encapsulated message framing.
//!
//! Every Arrow IPC message is wrapped in an envelope that lets a reader find
//! the metadata and body without parsing the metadata first:
//!
//!     <continuation: 0xFFFFFFFF>   4 bytes
//!     <metadata_size: int32>       4 bytes, little-endian
//!     <metadata>                   metadata_size bytes (a FlatBuffers message,
//!                                  zero-padded so the prefix plus metadata is a
//!                                  multiple of 8)
//!     <body>                       the message body
//!
//! This module handles only the envelope: metadata and body are opaque bytes
//! here. The metadata is a FlatBuffers-encoded `Message`, and the body layout
//! is described by that metadata, both of which higher IPC layers handle. The
//! continuation marker has prefixed every message since Arrow 0.15; this module
//! requires it.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The 4-byte marker that begins every encapsulated message.
pub const continuation: u32 = 0xFFFFFFFF;

/// Arrow aligns IPC metadata and buffers to 8-byte boundaries.
pub const alignment = 8;

/// Errors from decoding a malformed envelope.
pub const DecodeError = error{
    /// Fewer than the 8 prefix bytes, or the metadata runs past the input.
    Truncated,
    /// The leading 4 bytes are not the continuation marker.
    MissingContinuation,
    /// The metadata size is not a multiple of the 8-byte alignment.
    Misaligned,
};

/// The two opaque regions of a decoded message.
pub const Message = struct {
    /// The FlatBuffers metadata, including any trailing zero padding.
    metadata: []const u8,
    /// The message body, everything after the metadata.
    body: []const u8,
};

/// Frame `metadata` and `body` into an owned encapsulated message. The metadata
/// is zero-padded so the prefix plus metadata is a multiple of 8. The caller
/// owns the returned bytes and frees them with `allocator.free`.
pub fn encode(allocator: Allocator, metadata: []const u8, body: []const u8) Allocator.Error![]u8 {
    const padded_metadata = std.mem.alignForward(usize, metadata.len, alignment);
    const out = try allocator.alloc(u8, 8 + padded_metadata + body.len);
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], continuation, .little);
    std.mem.writeInt(i32, out[4..8], @intCast(padded_metadata), .little);
    @memcpy(out[8..][0..metadata.len], metadata);
    @memcpy(out[8 + padded_metadata ..][0..body.len], body);
    return out;
}

/// Parse an encapsulated message, returning slices into `bytes`. The body is
/// everything after the metadata; a reader that needs the exact body length
/// takes it from the metadata instead.
pub fn decode(bytes: []const u8) DecodeError!Message {
    if (bytes.len < 8) return error.Truncated;
    if (std.mem.readInt(u32, bytes[0..4], .little) != continuation) return error.MissingContinuation;
    const metadata_size: i32 = std.mem.readInt(i32, bytes[4..8], .little);
    if (metadata_size < 0) return error.Truncated;
    const size: usize = @intCast(metadata_size);
    if (size % alignment != 0) return error.Misaligned;
    if (8 + size > bytes.len) return error.Truncated;
    return .{ .metadata = bytes[8 .. 8 + size], .body = bytes[8 + size ..] };
}

const testing = std.testing;

test "encode frames metadata and body with an aligned prefix" {
    const out = try encode(testing.allocator, "abc", "wxyz");
    defer testing.allocator.free(out);

    // Prefix, then metadata padded from 3 to 8, then 4 body bytes.
    try testing.expectEqual(@as(usize, 8 + 8 + 4), out.len);
    try testing.expectEqual(continuation, std.mem.readInt(u32, out[0..4], .little));
    try testing.expectEqual(@as(i32, 8), std.mem.readInt(i32, out[4..8], .little));
    try testing.expectEqualStrings("abc", out[8..11]);
    // The metadata padding is zeroed.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0 }, out[11..16]);
    try testing.expectEqualStrings("wxyz", out[16..20]);
}

test "decode round-trips an encoded message" {
    const out = try encode(testing.allocator, "schema-metadata", "body-bytes-here!");
    defer testing.allocator.free(out);

    const message = try decode(out);
    try testing.expectEqualStrings("schema-metadata", message.metadata[0.."schema-metadata".len]);
    try testing.expectEqualStrings("body-bytes-here!", message.body);
}

test "encode and decode handle empty metadata and body" {
    const out = try encode(testing.allocator, "", "");
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 8), out.len);

    const message = try decode(out);
    try testing.expectEqual(@as(usize, 0), message.metadata.len);
    try testing.expectEqual(@as(usize, 0), message.body.len);
}

test "decode rejects a buffer shorter than the prefix" {
    try testing.expectError(error.Truncated, decode(&.{ 0xFF, 0xFF, 0xFF }));
}

test "decode rejects a missing continuation marker" {
    var bytes = [_]u8{0} ** 8;
    std.mem.writeInt(u32, bytes[0..4], 0x0000_0000, .little);
    try testing.expectError(error.MissingContinuation, decode(&bytes));
}

test "decode rejects a metadata size past the input" {
    var bytes = [_]u8{0} ** 8;
    std.mem.writeInt(u32, bytes[0..4], continuation, .little);
    std.mem.writeInt(i32, bytes[4..8], 16, .little); // claims 16 metadata bytes, has 0
    try testing.expectError(error.Truncated, decode(&bytes));
}

test "decode rejects a misaligned metadata size" {
    var bytes = [_]u8{0} ** 16;
    std.mem.writeInt(u32, bytes[0..4], continuation, .little);
    std.mem.writeInt(i32, bytes[4..8], 3, .little); // not a multiple of 8
    try testing.expectError(error.Misaligned, decode(&bytes));
}

test "encode leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            const out = try encode(allocator, "metadata", "body");
            allocator.free(out);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}
