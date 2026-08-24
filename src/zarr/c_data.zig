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
    /// Owned format string, used when the static table cannot express the
    /// type, such as a zoned timestamp.
    format: ?[:0]u8 = null,
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
    dictionary: ?*ArrowArray = null,
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
        // A zoned timestamp appends its timezone after the colon;
        // `exportSchemaNamed` builds that owned string.
        .timestamp => |ts| switch (ts.unit) {
            .second => "tss:",
            .millisecond => "tsm:",
            .microsecond => "tsu:",
            .nanosecond => "tsn:",
        },
        .time32 => |unit| switch (unit) {
            .second => "tts",
            .millisecond => "ttm",
            // A 32-bit time only has second and millisecond units.
            .microsecond, .nanosecond => unreachable,
        },
        .time64 => |unit| switch (unit) {
            // A 64-bit time only has microsecond and nanosecond units.
            .second, .millisecond => unreachable,
            .microsecond => "ttu",
            .nanosecond => "ttn",
        },
        .duration => |unit| switch (unit) {
            .second => "tDs",
            .millisecond => "tDm",
            .microsecond => "tDu",
            .nanosecond => "tDn",
        },
        // Decimal and fixed-size formats embed their parameters, so
        // `exportSchemaNamed` builds them as owned strings.
        .decimal128, .decimal256, .fixed_size_binary, .fixed_size_list => unreachable,
        // A dictionary schema's main format is the index type's format; the
        // value type rides the dictionary child schema.
        .dictionary => |d| formatString(d.index.*),
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
        .fixed_size_list => |fsl| blk: {
            list_child[0] = fsl.child.*;
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

    var dict_schema: ?*ArrowSchema = null;
    errdefer if (dict_schema) |ds| {
        ds.release.?(ds);
        allocator.destroy(ds);
    };
    if (data_type == .dictionary) {
        const ds = try allocator.create(ArrowSchema);
        errdefer allocator.destroy(ds);
        try exportSchemaNamed(allocator, data_type.dictionary.value.*, "", true, ds);
        dict_schema = ds;
    }

    var owned_name: ?[:0]u8 = null;
    errdefer if (owned_name) |nm| allocator.free(nm);
    if (name) |nm| owned_name = try allocator.dupeZ(u8, nm);

    var owned_format: ?[:0]u8 = null;
    errdefer if (owned_format) |f| allocator.free(f);
    switch (data_type) {
        .timestamp => |ts| if (ts.timezone) |tz| {
            owned_format = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ formatString(data_type), tz }, 0);
        },
        .decimal128 => |d| owned_format = try std.fmt.allocPrintSentinel(allocator, "d:{d},{d}", .{ d.precision, d.scale }, 0),
        .decimal256 => |d| owned_format = try std.fmt.allocPrintSentinel(allocator, "d:{d},{d},256", .{ d.precision, d.scale }, 0),
        .fixed_size_binary => |width| owned_format = try std.fmt.allocPrintSentinel(allocator, "w:{d}", .{width}, 0),
        .fixed_size_list => |fsl| owned_format = try std.fmt.allocPrintSentinel(allocator, "+w:{d}", .{fsl.size}, 0),
        else => {},
    }

    const priv = try allocator.create(SchemaPrivate);
    priv.* = .{ .allocator = allocator, .name = owned_name, .format = owned_format };

    out.* = .{
        .format = if (owned_format) |f| f.ptr else formatString(data_type).ptr,
        .name = if (owned_name) |nm| nm.ptr else null,
        .metadata = null,
        .flags = blk: {
            var flags: i64 = if (nullable) Flags.nullable else 0;
            if (data_type == .dictionary and data_type.dictionary.ordered) flags |= Flags.dictionary_ordered;
            break :blk flags;
        },
        .n_children = @intCast(n),
        .children = children,
        .dictionary = dict_schema,
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
    if (schema.dictionary) |ds| {
        if (ds.release) |rel| rel(ds);
        allocator.destroy(ds);
    }
    if (priv.name) |nm| allocator.free(nm);
    if (priv.format) |f| allocator.free(f);
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

    var dict_node: ?*ArrowArray = null;
    errdefer if (dict_node) |dn| {
        dn.release.?(dn);
        allocator.destroy(dn);
    };
    if (src.dictionary) |dict| {
        const dn = try allocator.create(ArrowArray);
        errdefer allocator.destroy(dn);
        try fillArrayNode(allocator, dict, dn);
        dict_node = dn;
    }

    const priv = try allocator.create(ArrayPrivate);
    priv.* = .{
        .allocator = allocator,
        .owns_data = false,
        .data = undefined,
        .buffers = buffers,
        .children = children,
        .dictionary = dict_node,
    };

    out.* = .{
        .length = @intCast(src.length),
        .null_count = @intCast(src.null_count),
        .offset = 0,
        .n_buffers = @intCast(nb),
        .n_children = @intCast(nc),
        .buffers = if (nb > 0) buffers.ptr else null,
        .children = if (nc > 0) children.ptr else null,
        .dictionary = dict_node,
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
    if (priv.dictionary) |dn| {
        if (dn.release) |rel| rel(dn);
        allocator.destroy(dn);
    }
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
    var next_id: i64 = 0;
    return importSchemaWithIds(allocator, schema, &next_id);
}

/// `importSchema` with an id counter: the C interface carries no dictionary
/// ids, so the import assigns fresh sequential ones, unique per top-level
/// import call.
fn importSchemaWithIds(allocator: Allocator, schema: *const ArrowSchema, next_id: *i64) ImportError!DataType {
    var base = try importSchemaFormat(allocator, schema, next_id);
    if (schema.dictionary) |dict_schema| {
        errdefer base.deinit(allocator);
        switch (base) {
            .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64 => {},
            else => return error.InvalidFormat,
        }
        const id = next_id.*;
        next_id.* += 1;
        var value_type = try importSchemaWithIds(allocator, dict_schema, next_id);
        defer value_type.deinit(allocator);
        const ordered = (schema.flags & Flags.dictionary_ordered) != 0;
        return DataType.initDictionary(allocator, id, base, value_type, ordered);
    }
    return base;
}

fn importSchemaFormat(allocator: Allocator, schema: *const ArrowSchema, next_id: *i64) ImportError!DataType {
    const fmt = std.mem.span(schema.format);
    const eq = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;

    // Timestamp carries its unit in the third character and an optional
    // timezone after the colon.
    if (fmt.len >= 4 and fmt[0] == 't' and fmt[1] == 's' and fmt[3] == ':') {
        const unit: TimeUnit = switch (fmt[2]) {
            's' => .second,
            'm' => .millisecond,
            'u' => .microsecond,
            'n' => .nanosecond,
            else => return error.InvalidFormat,
        };
        const tz = fmt[4..];
        return DataType.initTimestamp(allocator, unit, if (tz.len == 0) null else tz);
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
    if (eq(fmt, "tts")) return .{ .time32 = .second };
    if (eq(fmt, "ttm")) return .{ .time32 = .millisecond };
    if (eq(fmt, "ttu")) return .{ .time64 = .microsecond };
    if (eq(fmt, "ttn")) return .{ .time64 = .nanosecond };
    // Decimal: "d:precision,scale" with an optional ",bitWidth".
    if (fmt.len > 2 and fmt[0] == 'd' and fmt[1] == ':') {
        var it = std.mem.splitScalar(u8, fmt[2..], ',');
        const precision_s = it.next() orelse return error.InvalidFormat;
        const scale_s = it.next() orelse return error.InvalidFormat;
        const width_s = it.next();
        if (it.next() != null) return error.InvalidFormat;
        const params = @import("datatype.zig").DecimalParams{
            .precision = std.fmt.parseInt(u8, precision_s, 10) catch return error.InvalidFormat,
            .scale = std.fmt.parseInt(i8, scale_s, 10) catch return error.InvalidFormat,
        };
        const width = if (width_s) |w|
            std.fmt.parseInt(i32, w, 10) catch return error.InvalidFormat
        else
            128;
        return switch (width) {
            128 => .{ .decimal128 = params },
            256 => .{ .decimal256 = params },
            else => error.UnsupportedFormat,
        };
    }

    // Fixed-size binary: "w:byteWidth".
    if (fmt.len > 2 and fmt[0] == 'w' and fmt[1] == ':') {
        const width = std.fmt.parseInt(i32, fmt[2..], 10) catch return error.InvalidFormat;
        if (width < 0) return error.InvalidFormat;
        return .{ .fixed_size_binary = width };
    }

    // Fixed-size list: "+w:listSize", with one child schema.
    if (fmt.len > 3 and fmt[0] == '+' and fmt[1] == 'w' and fmt[2] == ':') {
        const size = std.fmt.parseInt(i32, fmt[3..], 10) catch return error.InvalidFormat;
        if (size < 0) return error.InvalidFormat;
        if (schema.n_children != 1 or schema.children == null) return error.InvalidFormat;
        var child = try importFieldWithIds(allocator, schema.children.?[0], next_id);
        defer child.deinit(allocator);
        return DataType.initFixedSizeListField(allocator, child, size);
    }

    if (eq(fmt, "tDs")) return .{ .duration = .second };
    if (eq(fmt, "tDm")) return .{ .duration = .millisecond };
    if (eq(fmt, "tDu")) return .{ .duration = .microsecond };
    if (eq(fmt, "tDn")) return .{ .duration = .nanosecond };

    if (eq(fmt, "+l")) {
        if (schema.n_children != 1 or schema.children == null) return error.InvalidFormat;
        var child = try importFieldWithIds(allocator, schema.children.?[0], next_id);
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
            fields[i] = try importFieldWithIds(allocator, schema.children.?[i], next_id);
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
    var next_id: i64 = 0;
    return importFieldWithIds(allocator, schema, &next_id);
}

fn importFieldWithIds(allocator: Allocator, schema: *const ArrowSchema, next_id: *i64) ImportError!Field {
    var dt = try importSchemaWithIds(allocator, schema, next_id);
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
    var next_id: i64 = 0;
    for (0..n) |i| {
        fields[i] = try importFieldWithIds(allocator, c_schema.children.?[i], &next_id);
        built += 1;
    }
    // Schema's field slice is public; construct directly to keep the fields we
    // already own rather than cloning them again through Schema.init.
    return Schema{ .fields = fields };
}

/// Error set for importing a foreign array.
pub const ImportArrayError = Allocator.Error || error{InvalidFormat};

/// Read a foreign `ArrowArray` of logical type `data_type` into an owned Zarr
/// `ArrayData`, copying every buffer. A non-zero `offset` is materialized
/// away during the copy: bitmaps are re-packed from the offset bit, values
/// are copied from the offset element, variable-length offsets are rebased to
/// start at zero, and list children are trimmed to the referenced window, so
/// the result always starts at element zero. The null count is recomputed
/// from the copied validity bitmap, which also handles the interface's -1 for
/// unknown. The copied arrays are validated in full before they are returned.
/// This does not consume `array`; the caller keeps ownership and remains
/// responsible for its release callback. The returned data is owned by the
/// caller.
pub fn importArray(allocator: Allocator, data_type: DataType, array: *const ArrowArray) ImportArrayError!ArrayData {
    if (array.length < 0) return error.InvalidFormat;
    var result = try importArraySlice(allocator, data_type, array, 0, @intCast(array.length));
    result.validateFull() catch {
        result.deinit();
        return error.InvalidFormat;
    };
    return result;
}

/// Imports the logical window `[extra_offset, extra_offset + length)` of a
/// foreign array. `extra_offset` carries a parent struct's slice into its
/// children, on top of the array's own `offset`.
fn importArraySlice(
    allocator: Allocator,
    data_type: DataType,
    array: *const ArrowArray,
    extra_offset: usize,
    length: usize,
) ImportArrayError!ArrayData {
    if (array.length < 0 or array.offset < 0) return error.InvalidFormat;
    if (extra_offset + length > @as(usize, @intCast(array.length))) return error.InvalidFormat;
    const total = extra_offset + @as(usize, @intCast(array.offset));

    const n_buffers = ArrayData.bufferCount(data_type);
    const n_children = ArrayData.childCount(data_type);
    if (@as(usize, @intCast(array.n_buffers)) != n_buffers) return error.InvalidFormat;
    if (@as(usize, @intCast(array.n_children)) != n_children) return error.InvalidFormat;

    const buffers = try allocator.alloc(?Buffer, n_buffers);
    for (buffers) |*slot| slot.* = null;
    errdefer {
        for (buffers) |*b| if (b.*) |*buf| buf.deinit();
        allocator.free(buffers);
    }
    var dictionary_values: ?ArrayData = null;
    errdefer if (dictionary_values) |*dv| dv.deinit();
    const children = try allocator.alloc(ArrayData, n_children);
    var built_children: usize = 0;
    errdefer {
        for (children[0..built_children]) |*c| c.deinit();
        allocator.free(children);
    }

    // Validity, re-packed from the offset bit; an absent buffer stays absent.
    if (n_buffers > 0) {
        if (bufferAt(array, 0)) |src| buffers[0] = try copyBitWindow(allocator, src, total, length);
    }

    switch (data_type) {
        .null => {},
        .boolean => {
            const src = bufferAt(array, 1) orelse return error.InvalidFormat;
            buffers[1] = try copyBitWindow(allocator, src, total, length);
        },
        .binary, .utf8 => _ = try importOffsetWindow(i32, allocator, array, total, length, buffers, true),
        .large_binary, .large_utf8 => _ = try importOffsetWindow(i64, allocator, array, total, length, buffers, true),
        .list => |child_field| {
            const window = try importOffsetWindow(i32, allocator, array, total, length, buffers, false);
            children[0] = try importArraySlice(allocator, child_field.data_type, array.children.?[0], window.first, window.len);
            built_children = 1;
        },
        .@"struct" => |fields| {
            // A struct's offset applies to its children as well: logical
            // element i of the struct is element total + i of each child.
            for (fields, 0..) |field, i| {
                children[i] = try importArraySlice(allocator, field.data_type, array.children.?[i], total, length);
                built_children += 1;
            }
        },
        .fixed_size_binary => |width| {
            const w: usize = @intCast(width);
            const src = bufferAt(array, 1) orelse return error.InvalidFormat;
            buffers[1] = try Buffer.dupe(allocator, src[total * w ..][0 .. length * w]);
        },
        .fixed_size_list => |fsl| {
            // Element i spans child elements [i * size, (i + 1) * size).
            const size: usize = @intCast(fsl.size);
            children[0] = try importArraySlice(allocator, fsl.child.data_type, array.children.?[0], total * size, length * size);
            built_children = 1;
        },
        .dictionary => |d| {
            // Indices slice like any fixed-width buffer; the dictionary
            // values are shared and never sliced.
            const width = d.index.bitWidth().? / 8;
            const src = bufferAt(array, 1) orelse return error.InvalidFormat;
            buffers[1] = try Buffer.dupe(allocator, src[total * width ..][0 .. length * width]);
            const dict_array = array.dictionary orelse return error.InvalidFormat;
            if (dict_array.length < 0) return error.InvalidFormat;
            dictionary_values = try importArraySlice(allocator, d.value.*, dict_array, 0, @intCast(dict_array.length));
        },
        else => {
            const width = data_type.bitWidth().? / 8;
            const src = bufferAt(array, 1) orelse return error.InvalidFormat;
            buffers[1] = try Buffer.dupe(allocator, src[total * width ..][0 .. length * width]);
        },
    }

    // The foreign null count is not trusted: it may be -1 for unknown, or
    // describe the whole array rather than this window.
    const null_count: usize = if (data_type == .null)
        length
    else if (buffers.len > 0 and buffers[0] != null)
        length - countSetBits(buffers[0].?.data, length)
    else
        0;

    var dt = try data_type.clone(allocator);
    errdefer dt.deinit(allocator);

    if (dictionary_values) |dv| {
        const holder = try allocator.create(ArrayData);
        holder.* = dv;
        dictionary_values = null; // owned by the result from here
        // Constructed as a literal, like the IPC batch decoder; the deep
        // validation in `importArray` covers it.
        return .{
            .allocator = allocator,
            .data_type = dt,
            .length = length,
            .null_count = null_count,
            .buffers = buffers,
            .children = children,
            .dictionary = holder,
        };
    }

    // Counts and child types are correct by construction, so `init` cannot
    // fail; `importArray` runs the deep validation afterwards.
    return ArrayData.init(allocator, dt, length, null_count, buffers, children) catch unreachable;
}

/// Buffer `k` of a foreign array as a byte pointer, or null when absent.
fn bufferAt(array: *const ArrowArray, k: usize) ?[*]const u8 {
    const bp = array.buffers orelse return null;
    const ptr = bp[k] orelse return null;
    return @ptrCast(ptr);
}

/// Copies `length` bits starting at `bit_offset` into a fresh byte-aligned
/// bitmap buffer.
fn copyBitWindow(allocator: Allocator, src: [*]const u8, bit_offset: usize, length: usize) Allocator.Error!Buffer {
    var out = try Buffer.allocZeroed(allocator, (length + 7) / 8);
    for (0..length) |i| {
        const bit = bit_offset + i;
        if (src[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0) {
            out.data[i / 8] |= @as(u8, 1) << @intCast(i % 8);
        }
    }
    return out;
}

/// Set bits among the first `length` bits of `bitmap`.
fn countSetBits(bitmap: []const u8, length: usize) usize {
    var count: usize = 0;
    for (bitmap[0 .. length / 8]) |byte| count += @popCount(byte);
    const rem: u3 = @intCast(length % 8);
    if (rem != 0) {
        const mask = (@as(u8, 1) << rem) - 1;
        count += @popCount(bitmap[length / 8] & mask);
    }
    return count;
}

const OffsetWindow = struct { first: usize, len: usize };

/// Copies the offsets of a variable-length or list layout for the window at
/// `total`, rebased to start at zero, into buffer slot 1. When `copy_values`
/// is set, also copies the referenced byte range of the values buffer into
/// slot 2. Returns the referenced window of the child space.
fn importOffsetWindow(
    comptime OffsetInt: type,
    allocator: Allocator,
    array: *const ArrowArray,
    total: usize,
    length: usize,
    buffers: []?Buffer,
    copy_values: bool,
) ImportArrayError!OffsetWindow {
    const raw = bufferAt(array, 1) orelse return error.InvalidFormat;
    const src: [*]const OffsetInt = @ptrCast(@alignCast(raw));
    const first = src[total];
    const last = src[total + length];
    if (first < 0 or last < first) return error.InvalidFormat;

    // Stored before filling, so the caller's cleanup owns it on any error.
    buffers[1] = try Buffer.alloc(allocator, (length + 1) * @sizeOf(OffsetInt));
    const out = buffers[1].?.items(OffsetInt);
    for (0..length + 1) |i| {
        const rebased = src[total + i] - first;
        if (rebased < 0) return error.InvalidFormat;
        out[i] = rebased;
    }

    const window = OffsetWindow{ .first = @intCast(first), .len = @intCast(last - first) };
    if (copy_values) {
        const values = bufferAt(array, 2) orelse return error.InvalidFormat;
        buffers[2] = try Buffer.dupe(allocator, values[window.first..][0..window.len]);
    }
    return window;
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
    try exportSchema(testing.allocator, .{ .timestamp = .{ .unit = .microsecond } }, &schema);
    defer schema.release.?(&schema);

    var dt = try importSchema(testing.allocator, &schema);
    defer dt.deinit(testing.allocator);
    try testing.expect(dt.equals(.{ .timestamp = .{ .unit = .microsecond } }));
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

/// Exports `data` and frees it, leaving the caller with only the C struct.
fn exportOwned(allocator: Allocator, data: ArrayData, out: *ArrowArray) !void {
    try exportArray(allocator, data, out);
}

test "import array honors a non-zero offset" {
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
    try exportOwned(allocator, data, &carray);
    defer carray.release.?(&carray);

    // A foreign producer may hand over a slice: logical [2, 3].
    carray.offset = 1;
    carray.length = 2;
    var imported = try importArray(allocator, .int32, &carray);
    defer imported.deinit();

    try testing.expectEqual(@as(usize, 2), imported.length);
    try testing.expectEqualSlices(i32, &.{ 2, 3 }, imported.values(i32));
}

test "import array recomputes an unknown null count" {
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
    try exportOwned(allocator, data, &carray);
    defer carray.release.?(&carray);

    carray.null_count = -1; // unknown, per the C Data Interface
    var imported = try importArray(allocator, .int32, &carray);
    defer imported.deinit();

    try testing.expectEqual(@as(usize, 1), imported.null_count);
    try testing.expect(!imported.isValid(1));
}

test "import array slices a utf8 array and rebases its offsets" {
    const allocator = testing.allocator;
    var builder = Utf8Array.Builder.init(allocator);
    defer builder.deinit();
    try builder.append("a");
    try builder.append("bb");
    try builder.append("ccc");
    var arr = try builder.finish();
    const data = try arr.toData(allocator);
    arr.deinit();

    var carray: ArrowArray = undefined;
    try exportOwned(allocator, data, &carray);
    defer carray.release.?(&carray);

    carray.offset = 1;
    carray.length = 2;
    var imported = try importArray(allocator, .utf8, &carray);
    defer imported.deinit();

    try testing.expectEqualSlices(i32, &.{ 0, 2, 5 }, imported.offsets(i32));
    try testing.expectEqualStrings("bb", imported.valueBytes(0));
    try testing.expectEqualStrings("ccc", imported.valueBytes(1));
}

test "import array slices a boolean array across a byte boundary" {
    const allocator = testing.allocator;
    const source = [_]bool{ true, false, true, false, true, true, false, false, true, true };
    const BooleanArray = @import("boolean_array.zig").BooleanArray;
    var builder = BooleanArray.Builder.init(allocator);
    defer builder.deinit();
    for (source) |v| try builder.append(v);
    var arr = try builder.finish();
    const data = try arr.toData(allocator);
    arr.deinit();

    var carray: ArrowArray = undefined;
    try exportOwned(allocator, data, &carray);
    defer carray.release.?(&carray);

    carray.offset = 3;
    carray.length = 6;
    var imported = try importArray(allocator, .boolean, &carray);
    defer imported.deinit();

    const bits = imported.buffers[1].?.data;
    for (source[3..9], 0..) |expected, i| {
        const got = bits[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
        try testing.expectEqual(expected, got);
    }
}

test "import array slices a struct array through its children" {
    const allocator = testing.allocator;
    const Person = StructArray(&[_]type{ PrimitiveArray(i32), Utf8Array });
    var b = Person.Builder.init(allocator);
    defer b.deinit();
    try b.children[0].append(1);
    try b.children[1].append("a");
    try b.append();
    try b.appendNull();
    try b.children[0].append(3);
    try b.children[1].append("ccc");
    try b.append();
    var s = try b.finish();
    const data = try s.toData(allocator);
    s.deinit();

    var carray: ArrowArray = undefined;
    try exportOwned(allocator, data, &carray);
    defer carray.release.?(&carray);

    carray.offset = 1;
    carray.length = 2;
    var struct_type = try DataType.initStruct(allocator, &.{ .int32, .utf8 });
    defer struct_type.deinit(allocator);
    var imported = try importArray(allocator, struct_type, &carray);
    defer imported.deinit();

    try testing.expectEqual(@as(usize, 2), imported.length);
    try testing.expect(!imported.isValid(0));
    try testing.expect(imported.isValid(1));
    try testing.expectEqual(@as(i32, 3), imported.child(0).values(i32)[1]);
    try testing.expectEqualStrings("ccc", imported.child(1).valueBytes(1));
}

test "import array slices a list array and trims the child" {
    const allocator = testing.allocator;
    const Int32List = @import("list_array.zig").ListArray(PrimitiveArray(i32));
    var b = Int32List.Builder.init(allocator);
    defer b.deinit();
    try b.values.append(1);
    try b.values.append(2);
    try b.appendList();
    try b.appendList();
    try b.values.append(3);
    try b.values.append(4);
    try b.values.append(5);
    try b.appendList();
    var arr = try b.finish();
    const data = try arr.toData(allocator);
    arr.deinit();

    var carray: ArrowArray = undefined;
    try exportOwned(allocator, data, &carray);
    defer carray.release.?(&carray);

    carray.offset = 1;
    carray.length = 2;
    var list_type = try DataType.initList(allocator, .int32);
    defer list_type.deinit(allocator);
    var imported = try importArray(allocator, list_type, &carray);
    defer imported.deinit();

    try testing.expectEqualSlices(i32, &.{ 0, 0, 3 }, imported.offsets(i32));
    try testing.expectEqual(@as(usize, 3), imported.child(0).length);
    try testing.expectEqualSlices(i32, &.{ 3, 4, 5 }, imported.child(0).values(i32));
}

test "temporal types round-trip through the C schema" {
    const allocator = testing.allocator;
    const flat = [_]DataType{
        .{ .time32 = .second },
        .{ .time32 = .millisecond },
        .{ .time64 = .microsecond },
        .{ .time64 = .nanosecond },
        .{ .duration = .second },
        .{ .duration = .nanosecond },
    };
    for (flat) |dt| {
        var cs: ArrowSchema = undefined;
        try exportSchema(allocator, dt, &cs);
        defer cs.release.?(&cs);
        var back = try importSchema(allocator, &cs);
        defer back.deinit(allocator);
        try testing.expect(back.equals(dt));
    }
}

test "decimal and fixed-size types round-trip through the C schema" {
    const allocator = testing.allocator;

    const d128 = DataType{ .decimal128 = .{ .precision = 19, .scale = 4 } };
    var cs1: ArrowSchema = undefined;
    try exportSchema(allocator, d128, &cs1);
    defer cs1.release.?(&cs1);
    try testing.expectEqualStrings("d:19,4", std.mem.span(cs1.format));
    var back1 = try importSchema(allocator, &cs1);
    defer back1.deinit(allocator);
    try testing.expect(back1.equals(d128));

    const d256 = DataType{ .decimal256 = .{ .precision = 76, .scale = 10 } };
    var cs2: ArrowSchema = undefined;
    try exportSchema(allocator, d256, &cs2);
    defer cs2.release.?(&cs2);
    try testing.expectEqualStrings("d:76,10,256", std.mem.span(cs2.format));
    var back2 = try importSchema(allocator, &cs2);
    defer back2.deinit(allocator);
    try testing.expect(back2.equals(d256));

    const fsb = DataType{ .fixed_size_binary = 19 };
    var cs3: ArrowSchema = undefined;
    try exportSchema(allocator, fsb, &cs3);
    defer cs3.release.?(&cs3);
    try testing.expectEqualStrings("w:19", std.mem.span(cs3.format));
    var back3 = try importSchema(allocator, &cs3);
    defer back3.deinit(allocator);
    try testing.expect(back3.equals(fsb));

    var fsl = try DataType.initFixedSizeList(allocator, .int32, 3);
    defer fsl.deinit(allocator);
    var cs4: ArrowSchema = undefined;
    try exportSchema(allocator, fsl, &cs4);
    defer cs4.release.?(&cs4);
    try testing.expectEqualStrings("+w:3", std.mem.span(cs4.format));
    var back4 = try importSchema(allocator, &cs4);
    defer back4.deinit(allocator);
    try testing.expect(back4.equals(fsl));
}

test "a zoned timestamp round-trips through the C schema" {
    const allocator = testing.allocator;
    var zoned = try DataType.initTimestamp(allocator, .microsecond, "Europe/Paris");
    defer zoned.deinit(allocator);

    var cs: ArrowSchema = undefined;
    try exportSchema(allocator, zoned, &cs);
    defer cs.release.?(&cs);
    try testing.expectEqualStrings("tsu:Europe/Paris", std.mem.span(cs.format));

    var back = try importSchema(allocator, &cs);
    defer back.deinit(allocator);
    try testing.expect(back.equals(zoned));
    try testing.expectEqualStrings("Europe/Paris", back.timestamp.timezone.?);
}

/// A hand-built dictionary array: indices [0, 1, null, 2, 0] (int8) into
/// ["red", "green", "blue"].
fn buildDictionaryData(allocator: Allocator) !ArrayData {
    var offsets = try Buffer.alloc(allocator, 4 * @sizeOf(i32));
    const off = offsets.items(i32);
    off[0] = 0;
    off[1] = 3;
    off[2] = 8;
    off[3] = 12;
    const values = try Buffer.dupe(allocator, "redgreenblue");
    const dict_buffers = try allocator.alloc(?Buffer, 3);
    dict_buffers[0] = null;
    dict_buffers[1] = offsets;
    dict_buffers[2] = values;
    const dict_values = try ArrayData.init(allocator, .utf8, 3, 0, dict_buffers, try allocator.alloc(ArrayData, 0));

    var indices = try Buffer.alloc(allocator, 5);
    const idx = indices.items(i8);
    idx[0] = 0;
    idx[1] = 1;
    idx[2] = 0;
    idx[3] = 2;
    idx[4] = 0;
    var validity = try Buffer.allocZeroed(allocator, 1);
    validity.data[0] = 0b11011;
    const buffers = try allocator.alloc(?Buffer, 2);
    buffers[0] = validity;
    buffers[1] = indices;
    const dict_type = try DataType.initDictionary(allocator, 0, .int8, .utf8, false);
    return ArrayData.initDictionary(allocator, dict_type, 5, 1, buffers, dict_values);
}

test "a dictionary array round-trips through the C interface" {
    const allocator = testing.allocator;

    var dict_type = try DataType.initDictionary(allocator, 0, .int8, .utf8, true);
    defer dict_type.deinit(allocator);
    var cs: ArrowSchema = undefined;
    try exportSchema(allocator, dict_type, &cs);
    defer cs.release.?(&cs);

    // The main format is the index type; the value type rides the
    // dictionary child schema, and ordering rides the flags.
    try testing.expectEqualStrings("c", std.mem.span(cs.format));
    try testing.expect(cs.dictionary != null);
    try testing.expectEqualStrings("u", std.mem.span(cs.dictionary.?.format));
    try testing.expect(cs.flags & Flags.dictionary_ordered != 0);

    var back = try importSchema(allocator, &cs);
    defer back.deinit(allocator);
    try testing.expect(back.equals(dict_type));

    // exportArray takes ownership of the data; its release frees it.
    const data = try buildDictionaryData(allocator);
    var carray: ArrowArray = undefined;
    try exportArray(allocator, data, &carray);
    defer carray.release.?(&carray);

    try testing.expectEqual(@as(i64, 5), carray.length);
    try testing.expect(carray.dictionary != null);
    try testing.expectEqual(@as(i64, 3), carray.dictionary.?.length);

    var imported = try importArray(allocator, back, &carray);
    defer imported.deinit();
    try imported.validateFull();
    try testing.expectEqualSlices(i8, &.{ 0, 1, 0, 2, 0 }, imported.values(i8));
    try testing.expect(!imported.isValid(2));
    try testing.expectEqualStrings("red", imported.dictionary.?.valueBytes(0));
    try testing.expectEqualStrings("blue", imported.dictionary.?.valueBytes(2));
}

test "importing a sliced dictionary array slices only the indices" {
    const allocator = testing.allocator;

    var dict_type = try DataType.initDictionary(allocator, 0, .int8, .utf8, false);
    defer dict_type.deinit(allocator);
    const data = try buildDictionaryData(allocator);
    var carray: ArrowArray = undefined;
    try exportArray(allocator, data, &carray);
    defer carray.release.?(&carray);

    carray.offset = 3;
    carray.length = 2;
    carray.null_count = -1;
    var imported = try importArray(allocator, dict_type, &carray);
    defer imported.deinit();

    try testing.expectEqualSlices(i8, &.{ 2, 0 }, imported.values(i8));
    try testing.expectEqual(@as(usize, 0), imported.null_count);
    // The dictionary itself is shared, never sliced.
    try testing.expectEqual(@as(usize, 3), imported.dictionary.?.length);
}

test "imported dictionary fields get distinct ids" {
    const allocator = testing.allocator;
    var a_type = try DataType.initDictionary(allocator, 9, .int8, .utf8, false);
    defer a_type.deinit(allocator);
    var b_type = try DataType.initDictionary(allocator, 9, .int16, .int32, false);
    defer b_type.deinit(allocator);
    var a = try Field.init(allocator, "a", a_type, true);
    defer a.deinit(allocator);
    var b = try Field.init(allocator, "b", b_type, true);
    defer b.deinit(allocator);
    var schema = try Schema.init(allocator, &.{ a, b });
    defer schema.deinit(allocator);

    var cs: ArrowSchema = undefined;
    try exportSchemaFields(allocator, schema, &cs);
    defer cs.release.?(&cs);

    var back = try importSchemaFields(allocator, &cs);
    defer back.deinit(allocator);
    // The C interface carries no ids; the import assigns fresh distinct ones.
    try testing.expect(back.field(0).data_type.dictionary.id != back.field(1).data_type.dictionary.id);
}

test "export and import a field carry the name and nullability" {
    const allocator = testing.allocator;
    var f = try Field.init(allocator, "score", .{ .timestamp = .{ .unit = .microsecond } }, true);
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
    try testing.expectEqualStrings("tss:", formatString(.{ .timestamp = .{ .unit = .second } }));
    try testing.expectEqualStrings("tsm:", formatString(.{ .timestamp = .{ .unit = .millisecond } }));
    try testing.expectEqualStrings("tsu:", formatString(.{ .timestamp = .{ .unit = .microsecond } }));
    try testing.expectEqualStrings("tsn:", formatString(.{ .timestamp = .{ .unit = .nanosecond } }));
}

test "format strings for nested types describe only the outer layer" {
    var list = try DataType.initList(testing.allocator, .int32);
    defer list.deinit(testing.allocator);
    try testing.expectEqualStrings("+l", formatString(list));

    var st = try DataType.initStruct(testing.allocator, &.{ .int32, .utf8 });
    defer st.deinit(testing.allocator);
    try testing.expectEqualStrings("+s", formatString(st));
}
