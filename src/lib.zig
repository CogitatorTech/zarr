//! Zarr is an Apache Arrow implementation in Zig.

const std = @import("std");

pub const buffer = @import("zarr/buffer.zig");
pub const bitmap = @import("zarr/bitmap.zig");
pub const datatype = @import("zarr/datatype.zig");
pub const primitive_array = @import("zarr/primitive_array.zig");

pub const Buffer = buffer.Buffer;
pub const Bitmap = bitmap.Bitmap;
pub const DataType = datatype.DataType;
pub const TimeUnit = datatype.TimeUnit;
pub const PrimitiveArray = primitive_array.PrimitiveArray;

test {
    std.testing.refAllDecls(@This());
}
