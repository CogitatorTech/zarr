//! Arrow logical types.
//!
//! Mirrors the type system in the Arrow format spec (Schema.fbs). This starts
//! with the fixed-width primitives plus variable-length binary/utf8; nested
//! and parameterized types are added as the corresponding array layouts land.

const std = @import("std");

pub const TimeUnit = enum {
    second,
    millisecond,
    microsecond,
    nanosecond,
};

pub const DataType = union(enum) {
    null,
    boolean,
    int8,
    int16,
    int32,
    int64,
    uint8,
    uint16,
    uint32,
    uint64,
    float16,
    float32,
    float64,
    /// Variable-length byte strings (32-bit offsets).
    binary,
    /// Variable-length UTF-8 strings (32-bit offsets).
    utf8,
    /// Days since the UNIX epoch, stored as i32.
    date32,
    /// Milliseconds since the UNIX epoch, stored as i64.
    date64,
    timestamp: TimeUnit,

    /// Bit width of the value buffer for fixed-width types, null otherwise.
    pub fn bitWidth(self: DataType) ?u16 {
        return switch (self) {
            .boolean => 1,
            .int8, .uint8 => 8,
            .int16, .uint16, .float16 => 16,
            .int32, .uint32, .float32, .date32 => 32,
            .int64, .uint64, .float64, .date64, .timestamp => 64,
            .null, .binary, .utf8 => null,
        };
    }

    /// True for types whose values live in a single fixed-width buffer.
    pub fn isFixedWidth(self: DataType) bool {
        return self.bitWidth() != null;
    }

    /// Maps a Zig integer/float type to its Arrow primitive type.
    pub fn fromZigType(comptime T: type) DataType {
        return switch (T) {
            i8 => .int8,
            i16 => .int16,
            i32 => .int32,
            i64 => .int64,
            u8 => .uint8,
            u16 => .uint16,
            u32 => .uint32,
            u64 => .uint64,
            f16 => .float16,
            f32 => .float32,
            f64 => .float64,
            bool => .boolean,
            else => @compileError("no Arrow primitive type for " ++ @typeName(T)),
        };
    }
};

test "bitWidth of primitives" {
    try std.testing.expectEqual(@as(?u16, 32), @as(DataType, .int32).bitWidth());
    try std.testing.expectEqual(@as(?u16, 1), @as(DataType, .boolean).bitWidth());
    try std.testing.expectEqual(@as(?u16, 64), (DataType{ .timestamp = .millisecond }).bitWidth());
    try std.testing.expectEqual(@as(?u16, null), @as(DataType, .utf8).bitWidth());
}

test "fromZigType" {
    try std.testing.expectEqual(DataType.int64, DataType.fromZigType(i64));
    try std.testing.expectEqual(DataType.float32, DataType.fromZigType(f32));
}
