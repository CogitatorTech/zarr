//! Zarr is an Apache Arrow implementation in Zig.

const std = @import("std");

pub const buffer = @import("zarr/buffer.zig");
pub const bitmap = @import("zarr/bitmap.zig");
pub const datatype = @import("zarr/datatype.zig");
pub const primitive_array = @import("zarr/primitive_array.zig");
pub const varbinary_array = @import("zarr/varbinary_array.zig");
pub const boolean_array = @import("zarr/boolean_array.zig");
pub const list_array = @import("zarr/list_array.zig");
pub const struct_array = @import("zarr/struct_array.zig");
pub const schema = @import("zarr/schema.zig");
pub const record_batch = @import("zarr/record_batch.zig");
pub const array_data = @import("zarr/array_data.zig");
pub const null_array = @import("zarr/null_array.zig");
pub const c_data = @import("zarr/c_data.zig");
pub const ipc_message = @import("zarr/ipc/message.zig");
pub const ipc_schema = @import("zarr/ipc/schema.zig");
pub const flatbuffers = @import("zarr/ipc/flatbuffers.zig");

pub const Buffer = buffer.Buffer;
pub const Bitmap = bitmap.Bitmap;
pub const DataType = datatype.DataType;
pub const TimeUnit = datatype.TimeUnit;
pub const PrimitiveArray = primitive_array.PrimitiveArray;
pub const BinaryArray = varbinary_array.VarBinaryArray(false, i32);
pub const Utf8Array = varbinary_array.VarBinaryArray(true, i32);
pub const LargeBinaryArray = varbinary_array.VarBinaryArray(false, i64);
pub const LargeUtf8Array = varbinary_array.VarBinaryArray(true, i64);
pub const BooleanArray = boolean_array.BooleanArray;
pub const ListArray = list_array.ListArray;
pub const StructArray = struct_array.StructArray;
pub const Field = schema.Field;
pub const Schema = schema.Schema;
pub const RecordBatch = record_batch.RecordBatch;
pub const ArrayData = array_data.ArrayData;
pub const NullArray = null_array.NullArray;

test {
    std.testing.refAllDecls(@This());
}
