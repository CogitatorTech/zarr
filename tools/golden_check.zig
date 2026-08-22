//! Golden-file check against the Arrow integration test data.
//!
//! The arrow-testing submodule ships the cross-implementation integration
//! suite: for each case, a JSON description of the expected schema and
//! values, next to `.stream` and `.arrow_file` golden bytes produced and
//! verified by the reference implementations. This tool decodes the golden
//! bytes with Zarr and compares schema and every value against the JSON, so
//! agreement here is agreement with every implementation in the matrix.
//!
//! Cases that use types Zarr does not implement (dictionary, decimal, and so
//! on) are skipped by inspecting the JSON schema first; golden bytes Zarr
//! rejects for a supported reason (big-endian data, compressed bodies) are
//! counted as rejected. Everything else must decode and match exactly: a
//! mismatch, a crash, or a leak fails the run.
//!
//! Run with `make golden` from the repository root. When the arrow-testing
//! submodule is not initialized, the check skips and exits zero.

const std = @import("std");
const zarr = @import("zarr");

const integration_root = "external/arrow-testing/data/arrow-ipc-stream/integration";
const max_file_size = 64 * 1024 * 1024;

const Totals = struct {
    verified_files: usize = 0,
    rejected_files: usize = 0,
    skipped_files: usize = 0,
    failed_files: usize = 0,
    values: usize = 0,
};

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    var totals: Totals = .{};
    var found_root = true;
    {
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        found_root = try runAll(allocator, io, &totals);
    }

    if (!found_root) {
        std.debug.print(
            "SKIP: integration golden files not found; run `git submodule update --init` to enable this check\n",
            .{},
        );
        return 0;
    }

    std.debug.print(
        "golden files: {d} verified ({d} values), {d} rejected as unsupported bytes, {d} skipped for unsupported types, {d} failed\n",
        .{ totals.verified_files, totals.values, totals.rejected_files, totals.skipped_files, totals.failed_files },
    );
    if (gpa.deinit() == .leak) {
        std.debug.print("FAIL: the run leaked memory\n", .{});
        return 1;
    }
    if (totals.failed_files != 0) return 1;
    std.debug.print("OK: every decodable golden file matched its JSON values\n", .{});
    return 0;
}

fn runAll(allocator: std.mem.Allocator, io: std.Io, totals: *Totals) !bool {
    var root = std.Io.Dir.cwd().openDir(io, integration_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer root.close(io);

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var dir = try root.openDir(io, entry.name, .{ .iterate = true });
        defer dir.close(io);

        var files = dir.iterate();
        while (try files.next(io)) |file_entry| {
            if (file_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, file_entry.name, ".json.gz")) continue;
            const stem = file_entry.name[0 .. file_entry.name.len - ".json.gz".len];
            const case_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, stem });
            defer allocator.free(case_path);
            checkCase(allocator, io, dir, case_path, stem, totals) catch |err| {
                totals.failed_files += 1;
                std.debug.print("FAIL: {s}: {t}\n", .{ case_path, err });
            };
        }
    }
    return true;
}

/// The reasons golden bytes may be refused without failing the check: the
/// case uses something Zarr knowingly does not implement.
fn isUnsupported(err: anyerror) bool {
    return switch (err) {
        error.UnsupportedType,
        error.UnsupportedEndianness,
        error.UnsupportedCompression,
        error.UnsupportedMessage,
        // Golden files from Arrow 0.14 use the pre-0.15 envelope without the
        // continuation marker, which Zarr requires.
        error.MissingContinuation,
        => true,
        else => false,
    };
}

fn checkCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    case_path: []const u8,
    stem: []const u8,
    totals: *Totals,
) !void {
    const json_name = try std.fmt.allocPrint(allocator, "{s}.json.gz", .{stem});
    defer allocator.free(json_name);
    const gz = try dir.readFileAlloc(io, json_name, allocator, .limited(max_file_size));
    defer allocator.free(gz);
    const json_bytes = try gunzip(allocator, gz);
    defer allocator.free(json_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    const case = parsed.value.object;

    // Build the expected schema; a type outside Zarr's surface skips the case.
    var expected_schema = buildSchema(allocator, case.get("schema").?) catch |err| switch (err) {
        error.UnsupportedGolden => {
            totals.skipped_files += 1;
            std.debug.print("skip (type): {s}\n", .{case_path});
            return;
        },
        else => return err,
    };
    defer expected_schema.deinit(allocator);
    const batches = case.get("batches").?.array.items;

    var dicts_json = DictionariesJson.init(allocator);
    defer dicts_json.deinit();
    if (case.get("dictionaries")) |list| {
        for (list.array.items) |entry| {
            try dicts_json.put(entry.object.get("id").?.integer, entry);
        }
    }

    // Stream golden.
    const stream_name = try std.fmt.allocPrint(allocator, "{s}.stream", .{stem});
    defer allocator.free(stream_name);
    const stream_bytes = try dir.readFileAlloc(io, stream_name, allocator, .limited(max_file_size));
    defer allocator.free(stream_bytes);

    var reader = zarr.ipc_stream.StreamReader.init(allocator, stream_bytes) catch |err| {
        if (isUnsupported(err)) {
            totals.rejected_files += 1;
            std.debug.print("rejected ({t}): {s}\n", .{ err, case_path });
            return;
        }
        return err;
    };
    defer reader.deinit();
    if (!expected_schema.equals(reader.schema)) return error.SchemaMismatch;

    for (batches) |batch_json| {
        var decoded = (reader.next() catch |err| {
            if (isUnsupported(err)) {
                totals.rejected_files += 1;
                std.debug.print("rejected ({t}): {s}\n", .{ err, case_path });
                return;
            }
            return err;
        }) orelse return error.MissingBatch;
        defer decoded.deinit();
        try compareBatch(batch_json, decoded, expected_schema, &dicts_json, totals);
    }
    if (try reader.next() != null) return error.ExtraBatch;

    // File golden: the same batches with random access.
    const file_name = try std.fmt.allocPrint(allocator, "{s}.arrow_file", .{stem});
    defer allocator.free(file_name);
    const file_bytes = try dir.readFileAlloc(io, file_name, allocator, .limited(max_file_size));
    defer allocator.free(file_bytes);

    var file_reader = try zarr.ipc_file.FileReader.init(allocator, file_bytes);
    defer file_reader.deinit();
    if (!expected_schema.equals(file_reader.schema)) return error.SchemaMismatch;
    if (file_reader.batchCount() != batches.len) return error.BatchCountMismatch;
    for (batches, 0..) |batch_json, i| {
        var decoded = try file_reader.readBatch(i);
        defer decoded.deinit();
        try compareBatch(batch_json, decoded, expected_schema, &dicts_json, totals);
    }

    totals.verified_files += 1;
    std.debug.print("verified: {s} ({d} batches)\n", .{ case_path, batches.len });
}

fn gunzip(allocator: std.mem.Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var decompress = std.compress.flate.Decompress.init(&in, .gzip, window);
    return decompress.reader.allocRemaining(allocator, .limited(max_file_size));
}

// --- Expected schema from the integration JSON ---

const BuildError = error{ UnsupportedGolden, MalformedGolden } || std.mem.Allocator.Error;

fn buildSchema(allocator: std.mem.Allocator, schema_json: std.json.Value) BuildError!zarr.Schema {
    const fields_json = schema_json.object.get("fields").?.array.items;
    const fields = try allocator.alloc(zarr.Field, fields_json.len);
    var built: usize = 0;
    defer {
        for (fields[0..built]) |*f| f.deinit(allocator);
        allocator.free(fields);
    }
    for (fields_json, 0..) |field_json, i| {
        fields[i] = try buildField(allocator, field_json);
        built += 1;
    }
    return zarr.Schema.init(allocator, fields);
}

fn buildField(allocator: std.mem.Allocator, field_json: std.json.Value) BuildError!zarr.Field {
    const obj = field_json.object;
    const name = obj.get("name").?.string;
    const nullable = obj.get("nullable").?.bool;
    var data_type = try buildType(allocator, obj);
    defer data_type.deinit(allocator);

    if (obj.get("dictionary")) |dict_json| {
        const encoding = dict_json.object;
        const id = encoding.get("id").?.integer;
        const ordered = if (encoding.get("isOrdered")) |o| o.bool else false;
        const index_obj = encoding.get("indexType").?.object;
        const bits = index_obj.get("bitWidth").?.integer;
        const signed = index_obj.get("isSigned").?.bool;
        const index_type: zarr.DataType = if (signed) switch (bits) {
            8 => .int8,
            16 => .int16,
            32 => .int32,
            64 => .int64,
            else => return error.MalformedGolden,
        } else switch (bits) {
            8 => .uint8,
            16 => .uint16,
            32 => .uint32,
            64 => .uint64,
            else => return error.MalformedGolden,
        };
        var wrapped = try zarr.DataType.initDictionary(allocator, id, index_type, data_type, ordered);
        data_type.deinit(allocator);
        data_type = wrapped;
        // Keep a single deinit path via the defer above.
        wrapped = undefined;
    }
    return zarr.Field.init(allocator, name, data_type, nullable);
}

fn buildType(allocator: std.mem.Allocator, field_obj: std.json.ObjectMap) BuildError!zarr.DataType {
    const type_obj = field_obj.get("type").?.object;
    const kind = type_obj.get("name").?.string;
    const eq = std.mem.eql;

    if (eq(u8, kind, "null")) return .null;
    if (eq(u8, kind, "bool")) return .boolean;
    if (eq(u8, kind, "int")) {
        const signed = type_obj.get("isSigned").?.bool;
        const bits = type_obj.get("bitWidth").?.integer;
        if (signed) {
            return switch (bits) {
                8 => .int8,
                16 => .int16,
                32 => .int32,
                64 => .int64,
                else => error.UnsupportedGolden,
            };
        }
        return switch (bits) {
            8 => .uint8,
            16 => .uint16,
            32 => .uint32,
            64 => .uint64,
            else => error.UnsupportedGolden,
        };
    }
    if (eq(u8, kind, "floatingpoint")) {
        const precision = type_obj.get("precision").?.string;
        if (eq(u8, precision, "HALF")) return .float16;
        if (eq(u8, precision, "SINGLE")) return .float32;
        if (eq(u8, precision, "DOUBLE")) return .float64;
        return error.UnsupportedGolden;
    }
    if (eq(u8, kind, "utf8")) return .utf8;
    if (eq(u8, kind, "binary")) return .binary;
    if (eq(u8, kind, "largeutf8")) return .large_utf8;
    if (eq(u8, kind, "largebinary")) return .large_binary;
    if (eq(u8, kind, "date")) {
        const unit = type_obj.get("unit").?.string;
        if (eq(u8, unit, "DAY")) return .date32;
        if (eq(u8, unit, "MILLISECOND")) return .date64;
        return error.UnsupportedGolden;
    }
    if (eq(u8, kind, "timestamp")) {
        const time_unit = try parseTimeUnit(type_obj);
        var timezone: ?[]const u8 = null;
        if (type_obj.get("timezone")) |tz| {
            if (tz == .string and tz.string.len != 0) timezone = tz.string;
        }
        return zarr.DataType.initTimestamp(allocator, time_unit, timezone);
    }
    if (eq(u8, kind, "time")) {
        const time_unit = try parseTimeUnit(type_obj);
        const bits = type_obj.get("bitWidth").?.integer;
        return switch (bits) {
            32 => switch (time_unit) {
                .second, .millisecond => .{ .time32 = time_unit },
                else => error.UnsupportedGolden,
            },
            64 => switch (time_unit) {
                .microsecond, .nanosecond => .{ .time64 = time_unit },
                else => error.UnsupportedGolden,
            },
            else => error.UnsupportedGolden,
        };
    }
    if (eq(u8, kind, "duration")) {
        return .{ .duration = try parseTimeUnit(type_obj) };
    }
    if (eq(u8, kind, "decimal")) {
        const precision = type_obj.get("precision").?.integer;
        const scale = type_obj.get("scale").?.integer;
        const bits = if (type_obj.get("bitWidth")) |w| w.integer else 128;
        if (precision < 1 or precision > 255 or scale < -128 or scale > 127) return error.MalformedGolden;
        const params: @FieldType(zarr.DataType, "decimal128") = .{
            .precision = @intCast(precision),
            .scale = @intCast(scale),
        };
        return switch (bits) {
            128 => .{ .decimal128 = params },
            256 => .{ .decimal256 = params },
            else => error.UnsupportedGolden,
        };
    }
    if (eq(u8, kind, "fixedsizebinary")) {
        const width = type_obj.get("byteWidth").?.integer;
        if (width < 0) return error.MalformedGolden;
        return .{ .fixed_size_binary = @intCast(width) };
    }

    const children = field_obj.get("children").?.array.items;
    if (eq(u8, kind, "fixedsizelist")) {
        const size = type_obj.get("listSize").?.integer;
        if (size < 0 or children.len != 1) return error.MalformedGolden;
        var child = try buildField(allocator, children[0]);
        defer child.deinit(allocator);
        return zarr.DataType.initFixedSizeListField(allocator, child, @intCast(size));
    }
    if (eq(u8, kind, "list")) {
        if (children.len != 1) return error.MalformedGolden;
        var child = try buildField(allocator, children[0]);
        defer child.deinit(allocator);
        return zarr.DataType.initListField(allocator, child);
    }
    if (eq(u8, kind, "struct")) {
        const fields = try allocator.alloc(zarr.Field, children.len);
        var built: usize = 0;
        defer {
            for (fields[0..built]) |*f| f.deinit(allocator);
            allocator.free(fields);
        }
        for (children, 0..) |child_json, i| {
            fields[i] = try buildField(allocator, child_json);
            built += 1;
        }
        return zarr.DataType.initStructFields(allocator, fields);
    }
    return error.UnsupportedGolden;
}

fn parseTimeUnit(type_obj: std.json.ObjectMap) BuildError!zarr.TimeUnit {
    const unit = type_obj.get("unit").?.string;
    const eq = std.mem.eql;
    if (eq(u8, unit, "SECOND")) return .second;
    if (eq(u8, unit, "MILLISECOND")) return .millisecond;
    if (eq(u8, unit, "MICROSECOND")) return .microsecond;
    if (eq(u8, unit, "NANOSECOND")) return .nanosecond;
    return error.UnsupportedGolden;
}

// --- Value comparison ---

const DictionariesJson = std.AutoHashMap(i64, std.json.Value);

fn compareBatch(batch_json: std.json.Value, data: zarr.ArrayData, schema: zarr.Schema, dicts: *const DictionariesJson, totals: *Totals) !void {
    const obj = batch_json.object;
    const count: usize = @intCast(obj.get("count").?.integer);
    if (data.length != count) return error.RowCountMismatch;
    const columns = obj.get("columns").?.array.items;
    if (columns.len != schema.fieldCount()) return error.ColumnCountMismatch;
    for (columns, 0..) |column_json, i| {
        try compareColumn(column_json, data.child(i), schema.field(i).data_type, dicts, totals);
    }
}

fn compareColumn(column_json: std.json.Value, data: zarr.ArrayData, data_type: zarr.DataType, dicts: *const DictionariesJson, totals: *Totals) !void {
    const obj = column_json.object;
    const count: usize = @intCast(obj.get("count").?.integer);
    if (data.length != count) return error.RowCountMismatch;

    if (data_type == .null) return;

    // VALIDITY: absent means every element is valid.
    if (obj.get("VALIDITY")) |validity_json| {
        for (validity_json.array.items, 0..) |v, i| {
            const expected_valid = v.integer != 0;
            if (data.isValid(i) != expected_valid) return error.ValidityMismatch;
            totals.values += 1;
        }
    }

    switch (data_type) {
        .null => unreachable,
        .boolean => {
            const bits = data.buffers[1].?.data;
            for (obj.get("DATA").?.array.items, 0..) |v, i| {
                if (!data.isValid(i)) continue;
                const expected = switch (v) {
                    .bool => |b| b,
                    .integer => |n| n != 0,
                    else => return error.MalformedGolden,
                };
                const got = bits[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
                if (got != expected) return error.ValueMismatch;
                totals.values += 1;
            }
        },
        .int8 => try compareInts(obj, data, i8, totals),
        .int16 => try compareInts(obj, data, i16, totals),
        .int32 => try compareInts(obj, data, i32, totals),
        .int64 => try compareInts(obj, data, i64, totals),
        .uint8 => try compareInts(obj, data, u8, totals),
        .uint16 => try compareInts(obj, data, u16, totals),
        .uint32 => try compareInts(obj, data, u32, totals),
        .uint64 => try compareInts(obj, data, u64, totals),
        .date32, .time32 => try compareInts(obj, data, i32, totals),
        .date64, .timestamp, .time64, .duration => try compareInts(obj, data, i64, totals),
        .decimal128 => try compareInts(obj, data, i128, totals),
        .decimal256 => try compareInts(obj, data, i256, totals),
        .fixed_size_binary => {
            for (obj.get("DATA").?.array.items, 0..) |v, i| {
                if (!data.isValid(i)) continue;
                if (v != .string) return error.MalformedGolden;
                try compareHexValue(v.string, data.valueBytes(i));
                totals.values += 1;
            }
        },
        .fixed_size_list => |fsl| {
            const child_json = obj.get("children").?.array.items[0];
            try compareColumn(child_json, data.child(0), fsl.child.data_type, dicts, totals);
        },
        .float16 => try compareFloats(obj, data, f16, totals),
        .float32 => try compareFloats(obj, data, f32, totals),
        .float64 => try compareFloats(obj, data, f64, totals),
        .utf8 => try compareText(obj, data, i32, totals),
        .large_utf8 => try compareText(obj, data, i64, totals),
        .binary => try compareHex(obj, data, i32, totals),
        .large_binary => try compareHex(obj, data, i64, totals),
        .list => |child_field| {
            try compareOffsets(obj, data, i32, totals);
            const child_json = obj.get("children").?.array.items[0];
            try compareColumn(child_json, data.child(0), child_field.data_type, dicts, totals);
        },
        .dictionary => |d| {
            // The column carries indices; the dictionary values are compared
            // against the file's dictionaries section.
            switch (d.index.*) {
                .int8 => try compareInts(obj, data, i8, totals),
                .int16 => try compareInts(obj, data, i16, totals),
                .int32 => try compareInts(obj, data, i32, totals),
                .int64 => try compareInts(obj, data, i64, totals),
                .uint8 => try compareInts(obj, data, u8, totals),
                .uint16 => try compareInts(obj, data, u16, totals),
                .uint32 => try compareInts(obj, data, u32, totals),
                .uint64 => try compareInts(obj, data, u64, totals),
                else => return error.MalformedGolden,
            }
            const dict_json = dicts.get(d.id) orelse return error.MalformedGolden;
            const dict_batch = dict_json.object.get("data").?.object;
            const dict_column = dict_batch.get("columns").?.array.items[0];
            try compareColumn(dict_column, data.dictionary.?.*, d.value.*, dicts, totals);
        },
        .@"struct" => |fields| {
            const children = obj.get("children").?.array.items;
            if (children.len != fields.len) return error.ColumnCountMismatch;
            for (children, 0..) |child_json, i| {
                try compareColumn(child_json, data.child(i), fields[i].data_type, dicts, totals);
            }
        },
    }
}

/// A JSON integration value that holds an integer: 64-bit values are strings
/// so they survive JSON readers with double-width numbers.
fn jsonInt(v: std.json.Value, comptime T: type) !T {
    return switch (v) {
        .integer => |n| @intCast(n),
        .string, .number_string => |s| std.fmt.parseInt(T, s, 10) catch error.MalformedGolden,
        else => error.MalformedGolden,
    };
}

fn compareInts(obj: std.json.ObjectMap, data: zarr.ArrayData, comptime T: type, totals: *Totals) !void {
    const values = data.values(T);
    for (obj.get("DATA").?.array.items, 0..) |v, i| {
        if (!data.isValid(i)) continue;
        if (values[i] != try jsonInt(v, T)) return error.ValueMismatch;
        totals.values += 1;
    }
}

fn compareFloats(obj: std.json.ObjectMap, data: zarr.ArrayData, comptime T: type, totals: *Totals) !void {
    const values = data.values(T);
    for (obj.get("DATA").?.array.items, 0..) |v, i| {
        if (!data.isValid(i)) continue;
        const expected: f64 = switch (v) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => return error.MalformedGolden,
        };
        // The generators print floats with round-trip precision, so casting
        // to the storage width reproduces the stored value exactly.
        if (values[i] != @as(T, @floatCast(expected))) return error.ValueMismatch;
        totals.values += 1;
    }
}

fn compareOffsets(obj: std.json.ObjectMap, data: zarr.ArrayData, comptime OffsetInt: type, totals: *Totals) !void {
    const offsets = data.offsets(OffsetInt);
    const offsets_json = obj.get("OFFSET").?.array.items;
    if (offsets_json.len != offsets.len) return error.OffsetCountMismatch;
    for (offsets_json, offsets) |v, got| {
        if (got != try jsonInt(v, OffsetInt)) return error.OffsetMismatch;
        totals.values += 1;
    }
}

fn compareText(obj: std.json.ObjectMap, data: zarr.ArrayData, comptime OffsetInt: type, totals: *Totals) !void {
    try compareOffsets(obj, data, OffsetInt, totals);
    for (obj.get("DATA").?.array.items, 0..) |v, i| {
        if (!data.isValid(i)) continue;
        if (v != .string) return error.MalformedGolden;
        if (!std.mem.eql(u8, data.valueBytes(i), v.string)) return error.ValueMismatch;
        totals.values += 1;
    }
}

fn compareHexValue(hex: []const u8, got: []const u8) !void {
    if (hex.len != got.len * 2) return error.ValueMismatch;
    for (got, 0..) |byte, j| {
        const expected = std.fmt.parseInt(u8, hex[j * 2 ..][0..2], 16) catch return error.MalformedGolden;
        if (byte != expected) return error.ValueMismatch;
    }
}

fn compareHex(obj: std.json.ObjectMap, data: zarr.ArrayData, comptime OffsetInt: type, totals: *Totals) !void {
    try compareOffsets(obj, data, OffsetInt, totals);
    for (obj.get("DATA").?.array.items, 0..) |v, i| {
        if (!data.isValid(i)) continue;
        if (v != .string) return error.MalformedGolden;
        try compareHexValue(v.string, data.valueBytes(i));
        totals.values += 1;
    }
}
