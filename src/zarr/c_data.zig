//! Arrow C Data Interface.
//!
//! The C Data Interface is a stable ABI for passing a single array, or a struct
//! array standing in for a record batch, across a language boundary without
//! copying the buffers. It defines two C structs, `ArrowSchema` and
//! `ArrowArray`, each carrying a `release` callback that the consumer invokes to
//! hand ownership back. This module bridges Zarr's `DataType` and `ArrayData` to
//! those structs.
//!
//! A logical type is encoded as a compact format string: "i" for int32, "u" for
//! utf8, "+l" for list, "+s" for struct, and so on. Nested types carry their
//! children separately rather than in the string, so the format string of a
//! list or struct describes only the outer layer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const DataType = @import("datatype.zig").DataType;
const TimeUnit = @import("datatype.zig").TimeUnit;
const ArrayData = @import("array_data.zig").ArrayData;
const Buffer = @import("buffer.zig").Buffer;
const Field = @import("schema.zig").Field;

/// The `ArrowSchema` struct of the Arrow C Data Interface. It describes one
/// field's logical type through a format string, an optional name, and, for
/// nested types, an array of child schemas. The `release` callback frees the
/// producer-owned memory (children and private data) and must be called by the
/// consumer exactly once; it does not free the base struct itself, which the
/// consumer owns.
pub const ArrowSchema = extern struct {
    format: [*:0]const u8,
    name: ?[*:0]const u8,
    metadata: ?[*:0]const u8,
    flags: i64,
    n_children: i64,
    children: ?[*]*ArrowSchema,
    dictionary: ?*ArrowSchema,
    release: ?*const fn (*ArrowSchema) callconv(.c) void,
    private_data: ?*anyopaque,
};

/// Flag bits for `ArrowSchema.flags`, as defined by the C Data Interface.
pub const Flags = struct {
    pub const dictionary_ordered: i64 = 1;
    pub const nullable: i64 = 2;
    pub const map_keys_sorted: i64 = 4;
};

/// Producer-owned state stored in `ArrowSchema.private_data` so the release
/// callback can free the memory this module allocated. `name` holds the owned,
/// null-terminated field name when the schema describes a named field.
const SchemaPrivate = struct {
    allocator: Allocator,
    name: ?[:0]u8,
};

/// The `ArrowArray` struct of the Arrow C Data Interface. It carries the data
/// of one array: its length, null count, the raw buffer pointers in canonical
/// order, and child arrays for nested types. The `release` callback frees the
/// producer-owned memory and must be called by the consumer exactly once.
pub const ArrowArray = extern struct {
    length: i64,
    null_count: i64,
    offset: i64,
    n_buffers: i64,
    n_children: i64,
    buffers: ?[*]?*const anyopaque,
    children: ?[*]*ArrowArray,
    dictionary: ?*ArrowArray,
    release: ?*const fn (*ArrowArray) callconv(.c) void,
    private_data: ?*anyopaque,
};

/// Producer-owned state stored in `ArrowArray.private_data`. `data` is valid
/// only at the root of an exported tree, where it owns every buffer's bytes;
/// child nodes borrow those bytes and leave `owns_data` false. The `buffers`
/// and `children` slices are the C plumbing this module allocated for the node.
const ArrayPrivate = struct {
    allocator: Allocator,
    owns_data: bool,
    data: ArrayData,
    buffers: []?*const anyopaque,
    children: []*ArrowArray,
};

/// The Arrow C Data Interface format string for `data_type`. The returned slice
/// is a static, null-terminated string owned by the program, not the caller.
/// Nested types return only their outer format ("+l", "+s"); their children are
/// described separately.
pub fn formatString(data_type: DataType) [:0]const u8 {
    return switch (data_type) {
        .null => "n",
        .boolean => "b",
        .int8 => "c",
        .int16 => "s",
        .int32 => "i",
        .int64 => "l",
        .uint8 => "C",
        .uint16 => "S",
        .uint32 => "I",
        .uint64 => "L",
        .float16 => "e",
        .float32 => "f",
        .float64 => "g",
        .binary => "z",
        .large_binary => "Z",
        .utf8 => "u",
        .large_utf8 => "U",
        .date32 => "tdD",
        .date64 => "tdm",
        .timestamp => |unit| switch (unit) {
            .second => "tss:",
            .millisecond => "tsm:",
            .microsecond => "tsu:",
            .nanosecond => "tsn:",
        },
        .list => "+l",
        .@"struct" => "+s",
    };
}

/// Export `data_type` into the caller-provided `ArrowSchema`, allocating child
/// schemas for nested types. The filled schema owns its children and private
/// data; the caller must release it by calling `out.release.?(out)` exactly
/// once, which frees everything this call allocated. The base struct `out`
/// itself is owned by the caller. A bare type carries no field name or
/// nullability; those belong to a schema field and are set when a field is
/// exported.
pub fn exportSchema(allocator: Allocator, data_type: DataType, out: *ArrowSchema) Allocator.Error!void {
    return exportSchemaNamed(allocator, data_type, null, false, out);
}

/// Export `field` into the caller-provided `ArrowSchema`, setting the field
/// name and the nullable flag in addition to the type. Ownership and release
/// follow `exportSchema`. A bare `DataType` cannot carry these, so a field is
/// the right unit for exchanging a named, nullable column description.
pub fn exportField(allocator: Allocator, field: Field, out: *ArrowSchema) Allocator.Error!void {
    return exportSchemaNamed(allocator, field.data_type, field.name, field.nullable, out);
}

/// Export the fields of `schema` into the caller-provided `ArrowSchema` as a
/// struct schema ("+s"), one named child per field. This is the schema half of
/// a record batch, where the field names live. Ownership and release follow
/// `exportSchema`.
pub fn exportSchemaFields(allocator: Allocator, schema: Schema, out: *ArrowSchema) Allocator.Error!void {
    const n = schema.fieldCount();
    var children: ?[*]*ArrowSchema = null;
    if (n > 0) {
        const arr = try allocator.alloc(*ArrowSchema, n);
        errdefer allocator.free(arr);
        var built: usize = 0;
        errdefer for (arr[0..built]) |c| {
            c.release.?(c);
            allocator.destroy(c);
        };
        for (0..n) |i| {
            const child = try allocator.create(ArrowSchema);
            errdefer allocator.destroy(child);
            try exportField(allocator, schema.field(i).*, child);
            arr[i] = child;
            built += 1;
        }
        children = arr.ptr;
    }
    errdefer if (children) |cptr| {
        for (cptr[0..n]) |c| {
            c.release.?(c);
            allocator.destroy(c);
        }
        allocator.free(cptr[0..n]);
    };

    const priv = try allocator.create(SchemaPrivate);
    priv.* = .{ .allocator = allocator, .name = null };

    out.* = .{
        .format = "+s",
        .name = null,
        .metadata = null,
        .flags = 0,
        .n_children = @intCast(n),
        .children = children,
        .dictionary = null,
        .release = releaseSchema,
        .private_data = priv,
    };
}

/// Export `batch` as a paired schema and array: `out_schema` receives the
/// named fields as a struct schema, and `out_array` receives the columns as a
/// struct array. The two structs cross the boundary together and each must be
/// released once by the consumer. On error neither is left set. `batch` is not
/// consumed; the caller keeps ownership of it.
pub fn exportRecordBatch(allocator: Allocator, batch: anytype, out_schema: *ArrowSchema, out_array: *ArrowArray) Allocator.Error!void {
    try exportSchemaFields(allocator, batch.schema, out_schema);
    errdefer out_schema.release.?(out_schema);
    var data = try batch.toData(allocator);
    errdefer data.deinit();
    try exportArray(allocator, data, out_array);
}

/// Shared implementation of `exportSchema` and `exportField`. When `name` is
/// non-null it is duped into owned, null-terminated storage that the release
/// callback frees; when `nullable` is true the nullable flag is set.
fn exportSchemaNamed(allocator: Allocator, data_type: DataType, name: ?[]const u8, nullable: bool, out: *ArrowSchema) Allocator.Error!void {
    // Determine the child fields described separately from the format string.
    var list_child: [1]Field = undefined;
    const child_fields: []const Field = switch (data_type) {
        .list => |child| blk: {
            list_child[0] = child.*;
            break :blk list_child[0..];
        },
        .@"struct" => |fields| fields,
        else => &[_]Field{},
    };
    const n = child_fields.len;

    var children: ?[*]*ArrowSchema = null;
    if (n > 0) {
        const arr = try allocator.alloc(*ArrowSchema, n);
        errdefer allocator.free(arr);
        var built: usize = 0;
        errdefer for (arr[0..built]) |c| {
            c.release.?(c);
            allocator.destroy(c);
        };
        // Child names and nullability come from the child fields the nested
        // type carries.
        for (0..n) |i| {
            const child = try allocator.create(ArrowSchema);
            errdefer allocator.destroy(child);
            try exportSchemaNamed(allocator, child_fields[i].data_type, child_fields[i].name, child_fields[i].nullable, child);
            arr[i] = child;
            built += 1;
        }
        children = arr.ptr;
    }
    errdefer if (children) |cptr| {
        for (cptr[0..n]) |c| {
            c.release.?(c);
            allocator.destroy(c);
        }
        allocator.free(cptr[0..n]);
    };

    var owned_name: ?[:0]u8 = null;
    errdefer if (owned_name) |nm| allocator.free(nm);
    if (name) |nm| owned_name = try allocator.dupeZ(u8, nm);

    const priv = try allocator.create(SchemaPrivate);
    priv.* = .{ .allocator = allocator, .name = owned_name };

    out.* = .{
        .format = formatString(data_type).ptr,
        .name = if (owned_name) |nm| nm.ptr else null,
        .metadata = null,
        .flags = if (nullable) Flags.nullable else 0,
        .n_children = @intCast(n),
        .children = children,
        .dictionary = null,
        .release = releaseSchema,
        .private_data = priv,
    };
}

/// Release callback for a schema exported by `exportSchema`. Releases and frees
/// every child, frees the child array and the private data, and clears
/// `release` to mark the schema consumed. Safe to leave to the consumer; it
/// does not free the base struct.
fn releaseSchema(schema: *ArrowSchema) callconv(.c) void {
    if (schema.release == null) return;
    const priv: *SchemaPrivate = @ptrCast(@alignCast(schema.private_data.?));
    const allocator = priv.allocator;
    const n: usize = @intCast(schema.n_children);
    if (schema.children) |cptr| {
        for (cptr[0..n]) |c| {
            if (c.release) |rel| rel(c);
            allocator.destroy(c);
        }
        allocator.free(cptr[0..n]);
    }
    if (priv.name) |nm| allocator.free(nm);
    allocator.destroy(priv);
    schema.release = null;
}

/// Export `data` into the caller-provided `ArrowArray`, taking ownership of
/// `data` without copying its buffers: the filled array points its buffer
/// pointers straight at `data`'s bytes and keeps `data` alive in private state.
/// The caller must release it by calling `out.release.?(out)` exactly once,
/// which frees `data` and every allocation this call made. On error the caller
/// still owns `data`. The base struct `out` is owned by the caller.
pub fn exportArray(allocator: Allocator, data: ArrayData, out: *ArrowArray) Allocator.Error!void {
    try fillArrayNode(allocator, &data, out);
    // The tree is built referencing `data`'s stable heap bytes; hand ownership
    // of `data` to the root node so its release frees every buffer.
    const root: *ArrayPrivate = @ptrCast(@alignCast(out.private_data.?));
    root.data = data;
    root.owns_data = true;
}

/// Recursively fill `out` from `src`, allocating the buffer-pointer array and
/// child arrays for this node. Nodes borrow `src`'s bytes; only `exportArray`
/// marks the root as owning `data`.
fn fillArrayNode(allocator: Allocator, src: *const ArrayData, out: *ArrowArray) Allocator.Error!void {
    const nb = src.buffers.len;
    const buffers = try allocator.alloc(?*const anyopaque, nb);
    errdefer allocator.free(buffers);
    for (src.buffers, 0..) |maybe, k| {
        buffers[k] = if (maybe) |buf| @ptrCast(buf.data.ptr) else null;
    }

    const nc = src.children.len;
    const children = try allocator.alloc(*ArrowArray, nc);
    errdefer allocator.free(children);
    var built: usize = 0;
    errdefer for (children[0..built]) |c| {
        c.release.?(c);
        allocator.destroy(c);
    };
    for (0..nc) |i| {
        const child = try allocator.create(ArrowArray);
        errdefer allocator.destroy(child);
        try fillArrayNode(allocator, &src.children[i], child);
        children[i] = child;
        built += 1;
    }

    const priv = try allocator.create(ArrayPrivate);
    priv.* = .{
        .allocator = allocator,
        .owns_data = false,
        .data = undefined,
        .buffers = buffers,
        .children = children,
    };

    out.* = .{
        .length = @intCast(src.length),
        .null_count = @intCast(src.null_count),
        .offset = 0,
        .n_buffers = @intCast(nb),
        .n_children = @intCast(nc),
        .buffers = if (nb > 0) buffers.ptr else null,
        .children = if (nc > 0) children.ptr else null,
        .dictionary = null,
        .release = releaseArray,
        .private_data = priv,
    };
}

/// Release callback for an array exported by `exportArray`. Releases and frees
/// every child, frees this node's buffer and child arrays, frees the owned
/// `ArrayData` at the root, and clears `release` to mark the array consumed.
fn releaseArray(array: *ArrowArray) callconv(.c) void {
    if (array.release == null) return;
    const priv: *ArrayPrivate = @ptrCast(@alignCast(array.private_data.?));
    const allocator = priv.allocator;
    for (priv.children) |c| {
        if (c.release) |rel| rel(c);
        allocator.destroy(c);
    }
    allocator.free(priv.children);
    allocator.free(priv.buffers);
    // Root only: free every buffer's bytes. Children borrow them, so this runs
    // after their plumbing is already released.
    if (priv.owns_data) priv.data.deinit();
    allocator.destroy(priv);
    array.release = null;
}

/// Error set for importing a foreign schema.
pub const ImportError = error{ UnsupportedFormat, InvalidFormat } || Allocator.Error;

/// Read a foreign `ArrowSchema` into an owned Zarr `DataType`, recursing into
/// child schemas for nested types. This does not consume `schema`; the caller
/// keeps ownership of it and remains responsible for calling its release
/// callback. The returned type is owned by the caller and released with
/// `deinit`.
pub fn importSchema(allocator: Allocator, schema: *const ArrowSchema) ImportError!DataType {
    const fmt = std.mem.span(schema.format);
    const eq = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;

    // Timestamp carries its unit in the third character and an optional
    // timezone after the colon, which Zarr's type does not retain.
    if (fmt.len >= 4 and fmt[0] == 't' and fmt[1] == 's' and fmt[3] == ':') {
        const unit: TimeUnit = switch (fmt[2]) {
            's' => .second,
            'm' => .millisecond,
            'u' => .microsecond,
            'n' => .nanosecond,
            else => return error.InvalidFormat,
        };
        return .{ .timestamp = unit };
    }

    if (eq(fmt, "n")) return .null;
    if (eq(fmt, "b")) return .boolean;
    if (eq(fmt, "c")) return .int8;
    if (eq(fmt, "s")) return .int16;
    if (eq(fmt, "i")) return .int32;
    if (eq(fmt, "l")) return .int64;
    if (eq(fmt, "C")) return .uint8;
    if (eq(fmt, "S")) return .uint16;
    if (eq(fmt, "I")) return .uint32;
    if (eq(fmt, "L")) return .uint64;
    if (eq(fmt, "e")) return .float16;
    if (eq(fmt, "f")) return .float32;
    if (eq(fmt, "g")) return .float64;
    if (eq(fmt, "z")) return .binary;
    if (eq(fmt, "Z")) return .large_binary;
    if (eq(fmt, "u")) return .utf8;
    if (eq(fmt, "U")) return .large_utf8;
    if (eq(fmt, "tdD")) return .date32;
    if (eq(fmt, "tdm")) return .date64;

    if (eq(fmt, "+l")) {
        if (schema.n_children != 1 or schema.children == null) return error.InvalidFormat;
        var child = try importField(allocator, schema.children.?[0]);
        defer child.deinit(allocator);
        return DataType.initListField(allocator, child);
    }

    if (eq(fmt, "+s")) {
        if (schema.children == null and schema.n_children != 0) return error.InvalidFormat;
        const n: usize = @intCast(schema.n_children);
        const fields = try allocator.alloc(Field, n);
        var built: usize = 0;
        defer {
            for (fields[0..built]) |*f| f.deinit(allocator);
            allocator.free(fields);
        }
        for (0..n) |i| {
            fields[i] = try importField(allocator, schema.children.?[i]);
            built += 1;
        }
        return DataType.initStructFields(allocator, fields);
    }

    return error.UnsupportedFormat;
}

/// Read a foreign `ArrowSchema` into an owned Zarr `Field`, taking its name
/// from the schema name (empty when absent), its nullability from the nullable
/// flag, and its type through `importSchema`. This does not consume `schema`;
/// the caller keeps ownership and the release callback. The returned field is
/// owned by the caller and released with `deinit`.
pub fn importField(allocator: Allocator, schema: *const ArrowSchema) ImportError!Field {
    var dt = try importSchema(allocator, schema);
    errdefer dt.deinit(allocator);
    const name = if (schema.name) |n| std.mem.span(n) else "";
    const owned_name = try allocator.dupe(u8, name);
    // Field's fields are public; construct directly to keep the type we already
    // own rather than cloning it again through Field.init.
    return Field{ .name = owned_name, .data_type = dt, .nullable = (schema.flags & Flags.nullable) != 0 };
}

/// Read a foreign struct `ArrowSchema` into an owned Zarr `Schema`, importing
/// each child as a named field. The schema must have struct format ("+s"),
/// which is how a record batch's schema is exchanged. This does not consume
/// `c_schema`; the caller keeps ownership and the release callback. The
/// returned schema is owned by the caller and released with `deinit`.
pub fn importSchemaFields(allocator: Allocator, c_schema: *const ArrowSchema) ImportError!Schema {
    if (!std.mem.eql(u8, std.mem.span(c_schema.format), "+s")) return error.InvalidFormat;
    const n: usize = @intCast(c_schema.n_children);
    if (n > 0 and c_schema.children == null) return error.InvalidFormat;

    const fields = try allocator.alloc(Field, n);
    var built: usize = 0;
    errdefer {
        for (fields[0..built]) |*f| f.deinit(allocator);
        allocator.free(fields);
    }
    for (0..n) |i| {
        fields[i] = try importField(allocator, c_schema.children.?[i]);
        built += 1;
    }
    // Schema's field slice is public; construct directly to keep the fields we
    // already own rather than cloning them again through Schema.init.
    return Schema{ .fields = fields };
}

/// Error set for importing a foreign array.
pub const ImportArrayError = Allocator.Error || error{ InvalidFormat, UnsupportedOffset };

/// Read a foreign `ArrowArray` of logical type `data_type` into an owned Zarr
/// `ArrayData`, copying every buffer. The C struct carries no buffer lengths,
/// so each buffer's size is computed from `data_type`, the length, and, for
/// variable-length types, the final offset. This does not consume `array`; the
/// caller keeps ownership and remains responsible for its release callback. A
/// non-zero `offset` is not representable in `ArrayData` and returns
/// `error.UnsupportedOffset`. The returned data is owned by the caller.
pub fn importArray(allocator: Allocator, data_type: DataType, array: *const ArrowArray) ImportArrayError!ArrayData {
    if (array.offset != 0) return error.UnsupportedOffset;
    const length: usize = @intCast(array.length);
    const null_count: usize = @intCast(array.null_count);
    if (null_count > length) return error.InvalidFormat;

    const n_buffers = ArrayData.bufferCount(data_type);
    const n_children = ArrayData.childCount(data_type);
    if (@as(usize, @intCast(array.n_buffers)) != n_buffers) return error.InvalidFormat;
    if (@as(usize, @intCast(array.n_children)) != n_children) return error.InvalidFormat;

    const buffers = try allocator.alloc(?Buffer, n_buffers);
    var built_buffers: usize = 0;
    errdefer {
        for (buffers[0..built_buffers]) |*b| if (b.*) |*buf| buf.deinit();
        allocator.free(buffers);
    }
    for (0..n_buffers) |k| {
        const src: ?*const anyopaque = if (array.buffers) |bp| bp[k] else null;
        if (src) |ptr| {
            const size = bufferByteLen(data_type, k, length, array);
            const bytes = @as([*]const u8, @ptrCast(ptr))[0..size];
            buffers[k] = try Buffer.dupe(allocator, bytes);
        } else {
            buffers[k] = null; // e.g. an absent validity buffer
        }
        built_buffers += 1;
    }

    const children = try allocator.alloc(ArrayData, n_children);
    var built_children: usize = 0;
    errdefer {
        for (children[0..built_children]) |*c| c.deinit();
        allocator.free(children);
    }
    for (0..n_children) |i| {
        children[i] = try importArray(allocator, childTypeAt(data_type, i), array.children.?[i]);
        built_children += 1;
    }

    var dt = try data_type.clone(allocator);
    errdefer dt.deinit(allocator);

    // Counts, null count, and child types were all validated above, so the
    // layout is well formed and `init` cannot fail here.
    return ArrayData.init(allocator, dt, length, null_count, buffers, children) catch unreachable;
}

/// Read a foreign record batch, given as a paired schema and array, into an
/// owned `Batch` of the given concrete type. The schema is imported into a zarr
/// `Schema`, a struct type is built from its field types to size the array, and
/// the array is imported and validated against the schema through
/// `Batch.fromData`. Neither `c_schema` nor `c_array` is consumed; the caller
/// keeps ownership and both release callbacks. The returned batch is owned by
/// the caller and released with `deinit`.
pub fn importRecordBatch(
    comptime Batch: type,
    allocator: Allocator,
    c_schema: *const ArrowSchema,
    c_array: *const ArrowArray,
) (ImportError || ImportArrayError || Batch.FromDataError)!Batch {
    var schema = try importSchemaFields(allocator, c_schema);
    defer schema.deinit(allocator);

    // Build the struct type the array is sized against from the field types.
    const field_types = try allocator.alloc(DataType, schema.fieldCount());
    defer allocator.free(field_types);
    for (schema.fields, 0..) |f, i| field_types[i] = f.data_type;
    var struct_type = try DataType.initStruct(allocator, field_types);
    defer struct_type.deinit(allocator);

    // fromData copies out of `data` and clones `schema`, so we keep owning both.
    var data = try importArray(allocator, struct_type, c_array);
    defer data.deinit();

    return Batch.fromData(allocator, schema, data);
}

/// The byte length of buffer `k` in the canonical layout of `data_type` for an
/// array of `length` elements. Variable-length value buffers read their size
/// from the final offset in the foreign offsets buffer.
fn bufferByteLen(data_type: DataType, k: usize, length: usize, array: *const ArrowArray) usize {
    if (k == 0) return (length + 7) / 8; // validity bitmap
    return switch (data_type) {
        .boolean => (length + 7) / 8, // bit-packed values
        .binary, .utf8 => if (k == 1) (length + 1) * @sizeOf(i32) else lastOffset(i32, array, length),
        .large_binary, .large_utf8 => if (k == 1) (length + 1) * @sizeOf(i64) else lastOffset(i64, array, length),
        .list => (length + 1) * @sizeOf(i32), // offsets
        else => length * (data_type.bitWidth().? / 8), // fixed-width values
    };
}

/// The final offset of a variable-length array, read from the foreign offsets
/// buffer at index `length`. This is the byte length of the values buffer.
fn lastOffset(comptime OffsetInt: type, array: *const ArrowArray, length: usize) usize {
    const offsets: [*]const OffsetInt = @ptrCast(@alignCast(array.buffers.?[1].?));
    return @intCast(offsets[length]);
}

/// The logical type of child `i` in the canonical layout of a nested type.
fn childTypeAt(data_type: DataType, i: usize) DataType {
    return switch (data_type) {
        .list => data_type.list.data_type,
        .@"struct" => data_type.@"struct"[i].data_type,
        else => unreachable,
    };
}

const testing = std.testing;

const PrimitiveArray = @import("primitive_array.zig").PrimitiveArray;
const Utf8Array = @import("varbinary_array.zig").VarBinaryArray(true, i32);
const StructArray = @import("struct_array.zig").StructArray;
const Schema = @import("schema.zig").Schema;
const RecordBatch = @import("record_batch.zig").RecordBatch;

const person_columns = [_]type{ PrimitiveArray(i32), Utf8Array };
const PersonBatch = RecordBatch(&person_columns);

/// Build a two-row PersonBatch: {id: int32, name: utf8}.
fn buildPersonBatch(allocator: Allocator, schema: Schema) !PersonBatch {
    var b = PersonBatch.Columns.Builder.init(allocator);
    defer b.deinit();
    try b.children[0].append(1);
    try b.children[1].append("a");
    try b.append();
    try b.children[0].append(2);
    try b.children[1].append("bb");
    try b.append();
    var columns = try b.finish();
    errdefer columns.deinit();
    return PersonBatch.init(allocator, schema, columns);
}

fn buildPersonSchema(allocator: Allocator) !Schema {
    var id = try Field.init(allocator, "id", .int32, false);
    defer id.deinit(allocator);
    var name = try Field.init(allocator, "name", .utf8, true);
    defer name.deinit(allocator);
    return Schema.init(allocator, &.{ id, name });
}

test "export array fills buffers and releases cleanly" {
    const allocator = testing.allocator;
    var builder = PrimitiveArray(i32).Builder.init(allocator);
    defer builder.deinit();
    try builder.append(1);
    try builder.append(2);
    try builder.append(3);
    var arr = try builder.finish();
    const data = try arr.toData(allocator);
    arr.deinit();

    var carray: ArrowArray = undefined;
    try exportArray(allocator, data, &carray);
    defer carray.release.?(&carray);

    try testing.expectEqual(@as(i64, 3), carray.length);
    try testing.expectEqual(@as(i64, 0), carray.null_count);
    try testing.expectEqual(@as(i64, 2), carray.n_buffers);
    try testing.expectEqual(@as(i64, 0), carray.n_children);
    // No nulls, so the validity buffer is absent.
    try testing.expect(carray.buffers.?[0] == null);
    const vals: [*]const i32 = @ptrCast(@alignCast(carray.buffers.?[1].?));
    try testing.expectEqual(@as(i32, 1), vals[0]);
    try testing.expectEqual(@as(i32, 3), vals[2]);
}

test "export array carries children and a validity buffer" {
    const allocator = testing.allocator;
    const Person = StructArray(&[_]type{ PrimitiveArray(i32), Utf8Array });
    var b = Person.Builder.init(allocator);
    defer b.deinit();
    try b.children[0].append(1);
    try b.children[1].append("a");
    try b.append();
    try b.appendNull();
    var s = try b.finish();
    const data = try s.toData(allocator);
    s.deinit();

    var carray: ArrowArray = undefined;
    try exportArray(allocator, data, &carray);
    defer carray.release.?(&carray);

    try testing.expectEqual(@as(i64, 2), carray.length);
    try testing.expectEqual(@as(i64, 1), carray.null_count);
    try testing.expectEqual(@as(i64, 1), carray.n_buffers); // struct: validity only
    try testing.expectEqual(@as(i64, 2), carray.n_children);
    try testing.expect(carray.buffers.?[0] != null); // validity present
    try testing.expectEqual(@as(i64, 2), carray.children.?[0].length);
    try testing.expectEqual(@as(i64, 2), carray.children.?[0].n_buffers); // int32
    try testing.expectEqual(@as(i64, 3), carray.children.?[1].n_buffers); // utf8
}

test "export array leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            const Person = StructArray(&[_]type{ PrimitiveArray(i32), Utf8Array });
            var data = blk: {
                var b = Person.Builder.init(allocator);
                defer b.deinit();
                try b.children[0].append(1);
                try b.children[1].append("a");
                try b.append();
                var s = try b.finish();
                defer s.deinit();
                break :blk try s.toData(allocator);
            };
            // On export failure the caller still owns data.
            errdefer data.deinit();
            var carray: ArrowArray = undefined;
            try exportArray(allocator, data, &carray);
            carray.release.?(&carray);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}

test "import schema round-trips a flat type" {
    var schema: ArrowSchema = undefined;
    try exportSchema(testing.allocator, .int32, &schema);
    defer schema.release.?(&schema);

    var dt = try importSchema(testing.allocator, &schema);
    defer dt.deinit(testing.allocator);
    try testing.expect(dt.equals(.int32));
}

test "import schema round-trips a timestamp with a unit" {
    var schema: ArrowSchema = undefined;
    try exportSchema(testing.allocator, .{ .timestamp = .microsecond }, &schema);
    defer schema.release.?(&schema);

    var dt = try importSchema(testing.allocator, &schema);
    defer dt.deinit(testing.allocator);
    try testing.expect(dt.equals(.{ .timestamp = .microsecond }));
}

test "import schema round-trips a struct of list" {
    var list = try DataType.initList(testing.allocator, .int32);
    defer list.deinit(testing.allocator);
    var st = try DataType.initStruct(testing.allocator, &.{ .boolean, list });
    defer st.deinit(testing.allocator);

    var schema: ArrowSchema = undefined;
    try exportSchema(testing.allocator, st, &schema);
    defer schema.release.?(&schema);

    var dt = try importSchema(testing.allocator, &schema);
    defer dt.deinit(testing.allocator);
    try testing.expect(dt.equals(st));
}

test "import schema rejects an unknown format" {
    var schema = ArrowSchema{
        .format = "wat",
        .name = null,
        .metadata = null,
        .flags = 0,
        .n_children = 0,
        .children = null,
        .dictionary = null,
        .release = null,
        .private_data = null,
    };
    try testing.expectError(error.UnsupportedFormat, importSchema(testing.allocator, &schema));
}

test "import schema leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var list = try DataType.initList(allocator, .int32);
            defer list.deinit(allocator);
            var st = try DataType.initStruct(allocator, &.{ .boolean, list });
            defer st.deinit(allocator);
            var schema: ArrowSchema = undefined;
            try exportSchema(allocator, st, &schema);
            defer schema.release.?(&schema);
            var dt = try importSchema(allocator, &schema);
            dt.deinit(allocator);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}

test "import array round-trips a primitive array with nulls" {
    const allocator = testing.allocator;
    var builder = PrimitiveArray(i32).Builder.init(allocator);
    defer builder.deinit();
    try builder.append(1);
    try builder.appendNull();
    try builder.append(3);
    var arr = try builder.finish();
    const data = try arr.toData(allocator);
    arr.deinit();

    var carray: ArrowArray = undefined;
    try exportArray(allocator, data, &carray);
    defer carray.release.?(&carray);

    var imported = try importArray(allocator, .int32, &carray);
    defer imported.deinit();

    var rebuilt = try PrimitiveArray(i32).fromData(allocator, imported);
    defer rebuilt.deinit();
    try testing.expectEqual(@as(?i32, 1), rebuilt.get(0));
    try testing.expectEqual(@as(?i32, null), rebuilt.get(1));
    try testing.expectEqual(@as(?i32, 3), rebuilt.get(2));
}

test "import array round-trips a utf8 array" {
    const allocator = testing.allocator;
    var builder = Utf8Array.Builder.init(allocator);
    defer builder.deinit();
    try builder.append("arrow");
    try builder.append("");
    try builder.append("zig");
    var arr = try builder.finish();
    const data = try arr.toData(allocator);
    arr.deinit();

    var carray: ArrowArray = undefined;
    try exportArray(allocator, data, &carray);
    defer carray.release.?(&carray);

    var imported = try importArray(allocator, .utf8, &carray);
    defer imported.deinit();

    var rebuilt = try Utf8Array.fromData(allocator, imported);
    defer rebuilt.deinit();
    try testing.expectEqualStrings("arrow", rebuilt.get(0).?);
    try testing.expectEqualStrings("", rebuilt.get(1).?);
    try testing.expectEqualStrings("zig", rebuilt.get(2).?);
}

test "import array round-trips a struct with a validity buffer and children" {
    const allocator = testing.allocator;
    const Person = StructArray(&[_]type{ PrimitiveArray(i32), Utf8Array });
    var b = Person.Builder.init(allocator);
    defer b.deinit();
    try b.children[0].append(1);
    try b.children[1].append("a");
    try b.append();
    try b.appendNull();
    var s = try b.finish();
    const data = try s.toData(allocator);
    s.deinit();

    var cs: ArrowSchema = undefined;
    try exportSchema(allocator, data.data_type, &cs);
    defer cs.release.?(&cs);
    var carray: ArrowArray = undefined;
    try exportArray(allocator, data, &carray);
    defer carray.release.?(&carray);

    var dt = try importSchema(allocator, &cs);
    defer dt.deinit(allocator);
    var imported = try importArray(allocator, dt, &carray);
    defer imported.deinit();

    var rebuilt = try Person.fromData(allocator, imported);
    defer rebuilt.deinit();
    try testing.expectEqual(@as(usize, 2), rebuilt.length);
    try testing.expectEqual(@as(usize, 1), rebuilt.null_count);
    try testing.expect(rebuilt.isValid(0));
    try testing.expect(!rebuilt.isValid(1));
    try testing.expectEqual(@as(?i32, 1), rebuilt.field(0).get(0));
    try testing.expectEqualStrings("a", rebuilt.field(1).get(0).?);
}

test "import array rejects a non-zero offset" {
    const allocator = testing.allocator;
    var builder = PrimitiveArray(i32).Builder.init(allocator);
    defer builder.deinit();
    try builder.append(1);
    var arr = try builder.finish();
    const data = try arr.toData(allocator);
    arr.deinit();

    var carray: ArrowArray = undefined;
    try exportArray(allocator, data, &carray);
    defer carray.release.?(&carray);

    carray.offset = 1;
    try testing.expectError(error.UnsupportedOffset, importArray(allocator, .int32, &carray));
}

test "export and import a field carry the name and nullability" {
    const allocator = testing.allocator;
    var f = try Field.init(allocator, "score", .{ .timestamp = .microsecond }, true);
    defer f.deinit(allocator);

    var cs: ArrowSchema = undefined;
    try exportField(allocator, f, &cs);
    defer cs.release.?(&cs);

    try testing.expectEqualStrings("score", std.mem.span(cs.name.?));
    try testing.expectEqual(Flags.nullable, cs.flags & Flags.nullable);
    try testing.expectEqualStrings("tsu:", std.mem.span(cs.format));

    var g = try importField(allocator, &cs);
    defer g.deinit(allocator);
    try testing.expect(g.equals(f));
}

test "export field for a non-nullable nested type clears the nullable flag" {
    const allocator = testing.allocator;
    var list = try DataType.initList(allocator, .int32);
    defer list.deinit(allocator);
    var f = try Field.init(allocator, "values", list, false);
    defer f.deinit(allocator);

    var cs: ArrowSchema = undefined;
    try exportField(allocator, f, &cs);
    defer cs.release.?(&cs);

    try testing.expectEqual(@as(i64, 0), cs.flags & Flags.nullable);
    try testing.expectEqualStrings("+l", std.mem.span(cs.format));

    var g = try importField(allocator, &cs);
    defer g.deinit(allocator);
    try testing.expect(g.equals(f));
}

test "field export and import leak nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var list = try DataType.initList(allocator, .int32);
            defer list.deinit(allocator);
            var f = try Field.init(allocator, "values", list, true);
            defer f.deinit(allocator);
            var cs: ArrowSchema = undefined;
            try exportField(allocator, f, &cs);
            defer cs.release.?(&cs);
            var g = try importField(allocator, &cs);
            g.deinit(allocator);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}

test "export a record batch as a paired schema and array" {
    const allocator = testing.allocator;
    var schema = try buildPersonSchema(allocator);
    defer schema.deinit(allocator);
    var batch = try buildPersonBatch(allocator, schema);
    defer batch.deinit();

    var cs: ArrowSchema = undefined;
    var ca: ArrowArray = undefined;
    try exportRecordBatch(allocator, batch, &cs, &ca);
    defer cs.release.?(&cs);
    defer ca.release.?(&ca);

    // Schema side: a struct of two named fields.
    try testing.expectEqualStrings("+s", std.mem.span(cs.format));
    try testing.expectEqual(@as(i64, 2), cs.n_children);
    try testing.expectEqualStrings("id", std.mem.span(cs.children.?[0].name.?));
    try testing.expectEqualStrings("i", std.mem.span(cs.children.?[0].format));
    try testing.expectEqual(@as(i64, 0), cs.children.?[0].flags & Flags.nullable);
    try testing.expectEqualStrings("name", std.mem.span(cs.children.?[1].name.?));
    try testing.expectEqualStrings("u", std.mem.span(cs.children.?[1].format));
    try testing.expectEqual(Flags.nullable, cs.children.?[1].flags & Flags.nullable);

    // Array side: a two-row struct with two children.
    try testing.expectEqual(@as(i64, 2), ca.length);
    try testing.expectEqual(@as(i64, 2), ca.n_children);
    try testing.expectEqual(@as(i64, 2), ca.children.?[0].length);
}

test "import schema fields rebuilds a schema" {
    const allocator = testing.allocator;
    var schema = try buildPersonSchema(allocator);
    defer schema.deinit(allocator);

    var cs: ArrowSchema = undefined;
    try exportSchemaFields(allocator, schema, &cs);
    defer cs.release.?(&cs);

    var rebuilt = try importSchemaFields(allocator, &cs);
    defer rebuilt.deinit(allocator);
    try testing.expect(rebuilt.equals(schema));
}

test "record batch round-trips through the C Data Interface" {
    const allocator = testing.allocator;
    var schema = try buildPersonSchema(allocator);
    defer schema.deinit(allocator);
    var batch = try buildPersonBatch(allocator, schema);
    defer batch.deinit();

    var cs: ArrowSchema = undefined;
    var ca: ArrowArray = undefined;
    try exportRecordBatch(allocator, batch, &cs, &ca);
    defer cs.release.?(&cs);
    defer ca.release.?(&ca);

    var imported = try importRecordBatch(PersonBatch, allocator, &cs, &ca);
    defer imported.deinit();

    try testing.expectEqual(@as(usize, 2), imported.numRows());
    try testing.expectEqual(@as(usize, 2), imported.numColumns());
    try testing.expectEqual(@as(?i32, 1), imported.column(0).get(0));
    try testing.expectEqualStrings("bb", imported.column(1).get(1).?);
    try testing.expectEqualStrings("id", imported.schema.field(0).name);
    try testing.expect(!imported.schema.field(0).nullable);
    try testing.expect(imported.schema.field(1).nullable);
    try testing.expect(imported.schema.field(1).data_type.equals(.utf8));
}

test "record batch import leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var schema = try buildPersonSchema(allocator);
            defer schema.deinit(allocator);
            var batch = try buildPersonBatch(allocator, schema);
            defer batch.deinit();
            var cs: ArrowSchema = undefined;
            var ca: ArrowArray = undefined;
            try exportRecordBatch(allocator, batch, &cs, &ca);
            defer cs.release.?(&cs);
            defer ca.release.?(&ca);
            var imported = try importRecordBatch(PersonBatch, allocator, &cs, &ca);
            imported.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}

test "record batch export leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var schema = try buildPersonSchema(allocator);
            defer schema.deinit(allocator);
            var batch = try buildPersonBatch(allocator, schema);
            defer batch.deinit();
            var cs: ArrowSchema = undefined;
            var ca: ArrowArray = undefined;
            try exportRecordBatch(allocator, batch, &cs, &ca);
            cs.release.?(&cs);
            ca.release.?(&ca);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}

test "import array leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var cs: ArrowSchema = undefined;
            var have_cs = false;
            defer if (have_cs) cs.release.?(&cs);

            var carray = blk: {
                var data = dblk: {
                    var builder = PrimitiveArray(i32).Builder.init(allocator);
                    defer builder.deinit();
                    try builder.append(1);
                    try builder.appendNull();
                    try builder.append(3);
                    var s = try builder.finish();
                    defer s.deinit();
                    break :dblk try s.toData(allocator);
                };
                errdefer data.deinit();
                try exportSchema(allocator, data.data_type, &cs);
                have_cs = true;
                var out: ArrowArray = undefined;
                try exportArray(allocator, data, &out);
                break :blk out;
            };
            defer carray.release.?(&carray);

            var dt = try importSchema(allocator, &cs);
            defer dt.deinit(allocator);
            var imported = try importArray(allocator, dt, &carray);
            imported.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}

test "export schema for a flat type fills the struct and releases cleanly" {
    var schema: ArrowSchema = undefined;
    try exportSchema(testing.allocator, .int32, &schema);
    try testing.expectEqualStrings("i", std.mem.span(schema.format));
    try testing.expectEqual(@as(i64, 0), schema.n_children);
    try testing.expect(schema.release != null);
    schema.release.?(&schema);
    try testing.expect(schema.release == null);
}

test "export schema for a list type carries one child" {
    var list = try DataType.initList(testing.allocator, .int64);
    defer list.deinit(testing.allocator);
    var schema: ArrowSchema = undefined;
    try exportSchema(testing.allocator, list, &schema);
    defer schema.release.?(&schema);
    try testing.expectEqualStrings("+l", std.mem.span(schema.format));
    try testing.expectEqual(@as(i64, 1), schema.n_children);
    try testing.expectEqualStrings("l", std.mem.span(schema.children.?[0].format));
}

test "export schema for a struct type carries child schemas" {
    var st = try DataType.initStruct(testing.allocator, &.{ .int32, .utf8 });
    defer st.deinit(testing.allocator);
    var schema: ArrowSchema = undefined;
    try exportSchema(testing.allocator, st, &schema);
    defer schema.release.?(&schema);
    try testing.expectEqualStrings("+s", std.mem.span(schema.format));
    try testing.expectEqual(@as(i64, 2), schema.n_children);
    try testing.expectEqualStrings("i", std.mem.span(schema.children.?[0].format));
    try testing.expectEqualStrings("u", std.mem.span(schema.children.?[1].format));
}

test "export schema for a nested list of structs" {
    var st = try DataType.initStruct(testing.allocator, &.{ .int32, .boolean });
    defer st.deinit(testing.allocator);
    var list = try DataType.initList(testing.allocator, st);
    defer list.deinit(testing.allocator);
    var schema: ArrowSchema = undefined;
    try exportSchema(testing.allocator, list, &schema);
    defer schema.release.?(&schema);
    try testing.expectEqualStrings("+l", std.mem.span(schema.format));
    const child = schema.children.?[0];
    try testing.expectEqualStrings("+s", std.mem.span(child.format));
    try testing.expectEqual(@as(i64, 2), child.n_children);
    try testing.expectEqualStrings("b", std.mem.span(child.children.?[1].format));
}

test "export schema leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var st = try DataType.initStruct(allocator, &.{ .int32, .utf8 });
            defer st.deinit(allocator);
            var schema: ArrowSchema = undefined;
            try exportSchema(allocator, st, &schema);
            schema.release.?(&schema);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}

test "format strings for fixed-width primitives" {
    try testing.expectEqualStrings("b", formatString(.boolean));
    try testing.expectEqualStrings("c", formatString(.int8));
    try testing.expectEqualStrings("s", formatString(.int16));
    try testing.expectEqualStrings("i", formatString(.int32));
    try testing.expectEqualStrings("l", formatString(.int64));
    try testing.expectEqualStrings("C", formatString(.uint8));
    try testing.expectEqualStrings("S", formatString(.uint16));
    try testing.expectEqualStrings("I", formatString(.uint32));
    try testing.expectEqualStrings("L", formatString(.uint64));
    try testing.expectEqualStrings("e", formatString(.float16));
    try testing.expectEqualStrings("f", formatString(.float32));
    try testing.expectEqualStrings("g", formatString(.float64));
}

test "format strings for null and variable-length types" {
    try testing.expectEqualStrings("n", formatString(.null));
    try testing.expectEqualStrings("z", formatString(.binary));
    try testing.expectEqualStrings("u", formatString(.utf8));
    try testing.expectEqualStrings("Z", formatString(.large_binary));
    try testing.expectEqualStrings("U", formatString(.large_utf8));
}

test "format strings for temporal types" {
    try testing.expectEqualStrings("tdD", formatString(.date32));
    try testing.expectEqualStrings("tdm", formatString(.date64));
    try testing.expectEqualStrings("tss:", formatString(.{ .timestamp = .second }));
    try testing.expectEqualStrings("tsm:", formatString(.{ .timestamp = .millisecond }));
    try testing.expectEqualStrings("tsu:", formatString(.{ .timestamp = .microsecond }));
    try testing.expectEqualStrings("tsn:", formatString(.{ .timestamp = .nanosecond }));
}

test "format strings for nested types describe only the outer layer" {
    var list = try DataType.initList(testing.allocator, .int32);
    defer list.deinit(testing.allocator);
    try testing.expectEqualStrings("+l", formatString(list));

    var st = try DataType.initStruct(testing.allocator, &.{ .int32, .utf8 });
    defer st.deinit(testing.allocator);
    try testing.expectEqualStrings("+s", formatString(st));
}
