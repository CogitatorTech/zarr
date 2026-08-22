//! Arrow logical types and fields.
//!
//! Mirrors the type system in the Arrow format spec (Schema.fbs). This starts
//! with the fixed-width primitives plus variable-length binary/utf8; nested
//! and parameterized types are added as the corresponding array layouts land.
//! Nested types carry their children as named `Field`s, matching Schema.fbs,
//! where `Field` is the node holding a name, nullability, and a type. A
//! schema is a list of the same fields; `schema.zig` builds on this.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TimeUnit = enum {
    second,
    millisecond,
    microsecond,
    nanosecond,
};

/// Parameters of a timestamp type: a unit, and an optional timezone name
/// such as "UTC". A null timezone means the timestamp is zone-naive. The
/// timezone string is owned by the type when it was built with
/// `initTimestamp`; release through `DataType.deinit`.
pub const TimestampType = struct {
    unit: TimeUnit,
    timezone: ?[]const u8 = null,
};

/// Parameters of a decimal type: the number of significant digits and the
/// number of digits after the decimal point.
pub const DecimalParams = struct {
    precision: u8,
    scale: i8,
};

/// Parameters of a fixed-size list type: one child element field, heap-owned
/// like a list's, and the fixed number of elements per slot.
pub const FixedSizeListType = struct {
    child: *const Field,
    size: i32,
};

/// Parameters of a dictionary-encoded type: the integer index type stored in
/// the array, the value type of the dictionary itself, whether the dictionary
/// is ordered, and the dictionary id that ties IPC dictionary batches to the
/// fields that use them. Both types are heap-owned; release through
/// `DataType.deinit`.
pub const DictionaryType = struct {
    id: i64,
    index: *const DataType,
    value: *const DataType,
    ordered: bool,
};

fn optStrEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// A named, typed, nullable column or child descriptor.
pub const Field = struct {
    /// Name; owned by this field.
    name: []const u8,
    /// Logical type; owned by this field.
    data_type: DataType,
    /// Whether values may be null.
    nullable: bool,

    /// Builds a field owning a copy of `name` and a deep copy of `data_type`.
    /// The caller retains ownership of both arguments and must release the
    /// returned field with `deinit`.
    pub fn init(allocator: Allocator, name: []const u8, data_type: DataType, nullable: bool) Allocator.Error!Field {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_type = try data_type.clone(allocator);
        return .{ .name = owned_name, .data_type = owned_type, .nullable = nullable };
    }

    /// Frees the owned name and type.
    pub fn deinit(self: *Field, allocator: Allocator) void {
        allocator.free(self.name);
        self.data_type.deinit(allocator);
        self.* = undefined;
    }

    /// Deep-copies this field.
    pub fn clone(self: Field, allocator: Allocator) Allocator.Error!Field {
        return init(allocator, self.name, self.data_type, self.nullable);
    }

    /// Structural equality: name, type, and nullability all match.
    pub fn equals(self: Field, other: Field) bool {
        return self.nullable == other.nullable and
            std.mem.eql(u8, self.name, other.name) and
            self.data_type.equals(other.data_type);
    }
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
    /// Variable-length byte strings (64-bit offsets).
    large_binary,
    /// Variable-length UTF-8 strings (64-bit offsets).
    large_utf8,
    /// Days since the UNIX epoch, stored as i32.
    date32,
    /// Milliseconds since the UNIX epoch, stored as i64.
    date64,
    timestamp: TimestampType,
    /// Time of day as i32, in seconds or milliseconds since midnight.
    time32: TimeUnit,
    /// Time of day as i64, in microseconds or nanoseconds since midnight.
    time64: TimeUnit,
    /// An elapsed amount of time as i64, in the given unit.
    duration: TimeUnit,
    /// A 128-bit decimal with the given precision and scale.
    decimal128: DecimalParams,
    /// A 256-bit decimal with the given precision and scale.
    decimal256: DecimalParams,
    /// Byte strings of one fixed width, with no offsets buffer.
    fixed_size_binary: i32,
    /// Lists of one fixed element count, with no offsets buffer. Owns a
    /// heap-allocated child field; release it with `deinit`.
    fixed_size_list: FixedSizeListType,
    /// Dictionary-encoded values: the array stores integer indices into a
    /// dictionary of values delivered separately. Owns two heap-allocated
    /// types; release it with `deinit`.
    dictionary: DictionaryType,
    /// A list of a single child element field (32-bit offsets), whose name
    /// is conventionally "item". Owns a heap-allocated child field; release
    /// it with `deinit`.
    list: *const Field,
    /// A struct with an ordered set of named child fields. Owns a
    /// heap-allocated field slice; release it with `deinit`.
    @"struct": []const Field,

    /// Bit width of the value buffer for fixed-width types, null otherwise.
    pub fn bitWidth(self: DataType) ?u16 {
        return switch (self) {
            .boolean => 1,
            .int8, .uint8 => 8,
            .int16, .uint16, .float16 => 16,
            .int32, .uint32, .float32, .date32, .time32 => 32,
            .int64, .uint64, .float64, .date64, .timestamp, .time64, .duration => 64,
            .decimal128 => 128,
            .decimal256 => 256,
            .null, .binary, .utf8, .large_binary, .large_utf8, .list, .@"struct", .fixed_size_binary, .fixed_size_list, .dictionary => null,
        };
    }

    /// Builds a timestamp type owning a copy of `timezone`, or a zone-naive
    /// timestamp when `timezone` is null. The caller retains ownership of the
    /// argument and must release the returned type with `deinit`.
    pub fn initTimestamp(allocator: Allocator, unit: TimeUnit, timezone: ?[]const u8) Allocator.Error!DataType {
        const owned = if (timezone) |tz| try allocator.dupe(u8, tz) else null;
        return .{ .timestamp = .{ .unit = unit, .timezone = owned } };
    }

    /// Builds a fixed-size list type from a bare element type, wrapping it
    /// in the conventional child field, like `initList`. The caller retains
    /// ownership of `child` and must release the returned type with `deinit`.
    pub fn initFixedSizeList(allocator: Allocator, child: DataType, size: i32) Allocator.Error!DataType {
        const owned = try allocator.create(Field);
        errdefer allocator.destroy(owned);
        owned.* = try Field.init(allocator, "item", child, true);
        return .{ .fixed_size_list = .{ .child = owned, .size = size } };
    }

    /// Builds a fixed-size list type owning a deep copy of the child `field`.
    pub fn initFixedSizeListField(allocator: Allocator, field: Field, size: i32) Allocator.Error!DataType {
        const owned = try allocator.create(Field);
        errdefer allocator.destroy(owned);
        owned.* = try field.clone(allocator);
        return .{ .fixed_size_list = .{ .child = owned, .size = size } };
    }

    /// Builds a dictionary type owning deep copies of the index and value
    /// types. `index` must be an integer type. The caller retains ownership
    /// of the arguments and must release the returned type with `deinit`.
    pub fn initDictionary(allocator: Allocator, id: i64, index: DataType, value: DataType, ordered: bool) Allocator.Error!DataType {
        std.debug.assert(switch (index) {
            .int8, .int16, .int32, .int64, .uint8, .uint16, .uint32, .uint64 => true,
            else => false,
        });
        const owned_index = try allocator.create(DataType);
        errdefer allocator.destroy(owned_index);
        owned_index.* = try index.clone(allocator);
        errdefer @constCast(owned_index).deinit(allocator);
        const owned_value = try allocator.create(DataType);
        errdefer allocator.destroy(owned_value);
        owned_value.* = try value.clone(allocator);
        return .{ .dictionary = .{ .id = id, .index = owned_index, .value = owned_value, .ordered = ordered } };
    }

    /// Builds a list type from a bare element type, wrapping it in the
    /// conventional child field: named "item" and nullable. Use
    /// `initListField` to control the child name and nullability. The caller
    /// retains ownership of `child` and must release the returned type with
    /// `deinit`.
    pub fn initList(allocator: Allocator, child: DataType) Allocator.Error!DataType {
        const owned = try allocator.create(Field);
        errdefer allocator.destroy(owned);
        owned.* = try Field.init(allocator, "item", child, true);
        return .{ .list = owned };
    }

    /// Builds a list type owning a deep copy of the child `field`. The caller
    /// retains ownership of the original and must release the returned type
    /// with `deinit`.
    pub fn initListField(allocator: Allocator, field: Field) Allocator.Error!DataType {
        const owned = try allocator.create(Field);
        errdefer allocator.destroy(owned);
        owned.* = try field.clone(allocator);
        return .{ .list = owned };
    }

    /// Builds a struct type from bare child types, wrapping each in an
    /// unnamed, nullable field. Use `initStructFields` to carry names. The
    /// caller retains ownership of `children` and must release the returned
    /// type with `deinit`.
    pub fn initStruct(allocator: Allocator, children: []const DataType) Allocator.Error!DataType {
        const owned = try allocator.alloc(Field, children.len);
        var finished: usize = 0;
        errdefer {
            for (owned[0..finished]) |*f| f.deinit(allocator);
            allocator.free(owned);
        }
        for (children, 0..) |child, i| {
            owned[i] = try Field.init(allocator, "", child, true);
            finished += 1;
        }
        return .{ .@"struct" = owned };
    }

    /// Builds a struct type owning a deep copy of `fields`. The caller
    /// retains ownership of the originals and must release the returned type
    /// with `deinit`.
    pub fn initStructFields(allocator: Allocator, fields: []const Field) Allocator.Error!DataType {
        const owned = try allocator.alloc(Field, fields.len);
        var finished: usize = 0;
        errdefer {
            for (owned[0..finished]) |*f| f.deinit(allocator);
            allocator.free(owned);
        }
        for (fields, 0..) |field, i| {
            owned[i] = try field.clone(allocator);
            finished += 1;
        }
        return .{ .@"struct" = owned };
    }

    /// Deep-copies this type, including any heap-owned children.
    pub fn clone(self: DataType, allocator: Allocator) Allocator.Error!DataType {
        return switch (self) {
            .timestamp => |ts| try initTimestamp(allocator, ts.unit, ts.timezone),
            .fixed_size_list => |fsl| try initFixedSizeListField(allocator, fsl.child.*, fsl.size),
            .dictionary => |d| try initDictionary(allocator, d.id, d.index.*, d.value.*, d.ordered),
            .list => |child| try initListField(allocator, child.*),
            .@"struct" => |fields| try initStructFields(allocator, fields),
            else => self,
        };
    }

    /// Frees any heap memory owned by nested types. A no-op for flat types.
    pub fn deinit(self: *DataType, allocator: Allocator) void {
        switch (self.*) {
            .timestamp => |ts| if (ts.timezone) |tz| allocator.free(tz),
            .fixed_size_list => |fsl| {
                @constCast(fsl.child).deinit(allocator);
                allocator.destroy(fsl.child);
            },
            .dictionary => |d| {
                @constCast(d.index).deinit(allocator);
                allocator.destroy(d.index);
                @constCast(d.value).deinit(allocator);
                allocator.destroy(d.value);
            },
            .list => |child| {
                @constCast(child).deinit(allocator);
                allocator.destroy(child);
            },
            .@"struct" => |fields| {
                for (fields) |*f| @constCast(f).deinit(allocator);
                allocator.free(fields);
            },
            else => {},
        }
        self.* = undefined;
    }

    /// Structural equality, comparing nested children by value.
    pub fn equals(self: DataType, other: DataType) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .timestamp => |ts| ts.unit == other.timestamp.unit and
                optStrEq(ts.timezone, other.timestamp.timezone),
            .time32 => |unit| unit == other.time32,
            .time64 => |unit| unit == other.time64,
            .duration => |unit| unit == other.duration,
            .decimal128 => |d| d.precision == other.decimal128.precision and d.scale == other.decimal128.scale,
            .decimal256 => |d| d.precision == other.decimal256.precision and d.scale == other.decimal256.scale,
            .fixed_size_binary => |width| width == other.fixed_size_binary,
            .fixed_size_list => |fsl| fsl.size == other.fixed_size_list.size and
                fsl.child.equals(other.fixed_size_list.child.*),
            // The id is IPC bookkeeping, not part of the type: the same
            // logical schema may carry different ids from different writers.
            .dictionary => |d| d.ordered == other.dictionary.ordered and
                d.index.equals(other.dictionary.index.*) and d.value.equals(other.dictionary.value.*),
            .list => |child| child.equals(other.list.*),
            .@"struct" => |fields| blk: {
                const others = other.@"struct";
                if (fields.len != others.len) break :blk false;
                for (fields, others) |a, b| {
                    if (!a.equals(b)) break :blk false;
                }
                break :blk true;
            },
            else => true,
        };
    }

    /// Layout equality: the same physical shape, ignoring child field names
    /// and nullability. Used where one side cannot carry names, such as
    /// checking a builder-derived column type against a schema field, whose
    /// names are the authority.
    pub fn equalsLayout(self: DataType, other: DataType) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .timestamp => |ts| ts.unit == other.timestamp.unit,
            .time32 => |unit| unit == other.time32,
            .time64 => |unit| unit == other.time64,
            .duration => |unit| unit == other.duration,
            .decimal128 => |d| d.precision == other.decimal128.precision and d.scale == other.decimal128.scale,
            .decimal256 => |d| d.precision == other.decimal256.precision and d.scale == other.decimal256.scale,
            .fixed_size_binary => |width| width == other.fixed_size_binary,
            .fixed_size_list => |fsl| fsl.size == other.fixed_size_list.size and
                fsl.child.data_type.equalsLayout(other.fixed_size_list.child.data_type),
            .dictionary => |d| d.index.equalsLayout(other.dictionary.index.*) and
                d.value.equalsLayout(other.dictionary.value.*),
            .list => |child| child.data_type.equalsLayout(other.list.data_type),
            .@"struct" => |fields| blk: {
                const others = other.@"struct";
                if (fields.len != others.len) break :blk false;
                for (fields, others) |a, b| {
                    if (!a.data_type.equalsLayout(b.data_type)) break :blk false;
                }
                break :blk true;
            },
            else => true,
        };
    }

    /// True for types whose values live in a single fixed-width buffer.
    pub fn isFixedWidth(self: DataType) bool {
        return self.bitWidth() != null;
    }

    /// Returns the Arrow type of `array`, whether or not its `dataType`
    /// accessor requires an allocator. Flat arrays expose an allocation-free
    /// `dataType(self)`, while nested arrays own heap memory and expose
    /// `dataType(self, allocator)`. This dispatches on the accessor's arity at
    /// comptime so a nested array can describe any child uniformly. The caller
    /// owns the returned type and must release it with `deinit`.
    pub fn ofArray(array: anytype, allocator: Allocator) Allocator.Error!DataType {
        const params = @typeInfo(@TypeOf(@TypeOf(array).dataType)).@"fn".params;
        if (params.len == 1) return array.dataType();
        return array.dataType(allocator);
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
    try std.testing.expectEqual(@as(?u16, 64), (DataType{ .timestamp = .{ .unit = .millisecond } }).bitWidth());
    try std.testing.expectEqual(@as(?u16, null), @as(DataType, .utf8).bitWidth());
}

test "fromZigType" {
    try std.testing.expectEqual(DataType.int64, DataType.fromZigType(i64));
    try std.testing.expectEqual(DataType.float32, DataType.fromZigType(f32));
}

test "equals compares flat types by tag and payload" {
    try std.testing.expect(@as(DataType, .int32).equals(.int32));
    try std.testing.expect(!@as(DataType, .int32).equals(.int64));
    try std.testing.expect((DataType{ .timestamp = .{ .unit = .second } }).equals(.{ .timestamp = .{ .unit = .second } }));
    try std.testing.expect(!(DataType{ .timestamp = .{ .unit = .second } }).equals(.{ .timestamp = .{ .unit = .nanosecond } }));
}

test "initList owns a deep copy of its child" {
    var ty = try DataType.initList(std.testing.allocator, .int32);
    defer ty.deinit(std.testing.allocator);

    try std.testing.expect(ty == .list);
    try std.testing.expect(ty.list.data_type.equals(.int32));
    try std.testing.expectEqual(@as(?u16, null), ty.bitWidth());
    try std.testing.expect(!ty.isFixedWidth());
}

test "initList accepts a nested list child" {
    var inner = try DataType.initList(std.testing.allocator, .float64);
    defer inner.deinit(std.testing.allocator);

    var outer = try DataType.initList(std.testing.allocator, inner);
    defer outer.deinit(std.testing.allocator);

    // Mutating the source after construction does not affect the copy.
    inner.deinit(std.testing.allocator);
    inner = .null;

    try std.testing.expect(outer == .list);
    try std.testing.expect(outer.list.data_type == .list);
    try std.testing.expect(outer.list.data_type.list.data_type.equals(.float64));
}

test "initStruct owns a deep copy of its children" {
    var ty = try DataType.initStruct(std.testing.allocator, &.{ .int32, .utf8 });
    defer ty.deinit(std.testing.allocator);

    try std.testing.expect(ty == .@"struct");
    try std.testing.expectEqual(@as(usize, 2), ty.@"struct".len);
    try std.testing.expect(ty.@"struct"[0].data_type.equals(.int32));
    try std.testing.expect(ty.@"struct"[1].data_type.equals(.utf8));
}

test "initStruct with a nested list field" {
    var list_field = try DataType.initList(std.testing.allocator, .int32);
    defer list_field.deinit(std.testing.allocator);

    var ty = try DataType.initStruct(std.testing.allocator, &.{ .boolean, list_field });
    defer ty.deinit(std.testing.allocator);

    try std.testing.expect(ty.@"struct"[0].data_type.equals(.boolean));
    try std.testing.expect(ty.@"struct"[1].data_type == .list);
    try std.testing.expect(ty.@"struct"[1].data_type.list.data_type.equals(.int32));
}

test "equals compares nested types by value" {
    var a = try DataType.initList(std.testing.allocator, .int32);
    defer a.deinit(std.testing.allocator);
    var b = try DataType.initList(std.testing.allocator, .int32);
    defer b.deinit(std.testing.allocator);
    var c = try DataType.initList(std.testing.allocator, .int64);
    defer c.deinit(std.testing.allocator);

    try std.testing.expect(a.equals(b));
    try std.testing.expect(!a.equals(c));
    try std.testing.expect(!a.equals(.int32));
}

test "clone produces an independent deep copy" {
    var original = try DataType.initStruct(std.testing.allocator, &.{ .int32, .utf8 });
    var copy = try original.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);

    // Freeing the original leaves the copy intact.
    original.deinit(std.testing.allocator);

    try std.testing.expect(copy == .@"struct");
    try std.testing.expect(copy.@"struct"[0].data_type.equals(.int32));
    try std.testing.expect(copy.@"struct"[1].data_type.equals(.utf8));
}

test "nested type construction leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var inner = try DataType.initList(allocator, .int32);
            defer inner.deinit(allocator);
            var ty = try DataType.initStruct(allocator, &.{ .boolean, inner });
            ty.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "initStructFields keeps names and nullability" {
    const allocator = std.testing.allocator;
    var x = try Field.init(allocator, "x", .int32, false);
    defer x.deinit(allocator);
    var y = try Field.init(allocator, "y", .utf8, true);
    defer y.deinit(allocator);

    var ty = try DataType.initStructFields(allocator, &.{ x, y });
    defer ty.deinit(allocator);

    try std.testing.expectEqualStrings("x", ty.@"struct"[0].name);
    try std.testing.expect(!ty.@"struct"[0].nullable);
    try std.testing.expect(ty.@"struct"[0].data_type.equals(.int32));
    try std.testing.expectEqualStrings("y", ty.@"struct"[1].name);
    try std.testing.expect(ty.@"struct"[1].nullable);
}

test "struct equality compares field names and nullability" {
    const allocator = std.testing.allocator;
    var x = try Field.init(allocator, "x", .int32, false);
    defer x.deinit(allocator);
    var renamed = try Field.init(allocator, "z", .int32, false);
    defer renamed.deinit(allocator);

    var a = try DataType.initStructFields(allocator, &.{x});
    defer a.deinit(allocator);
    var b = try DataType.initStructFields(allocator, &.{x});
    defer b.deinit(allocator);
    var c = try DataType.initStructFields(allocator, &.{renamed});
    defer c.deinit(allocator);

    try std.testing.expect(a.equals(b));
    try std.testing.expect(!a.equals(c));
}

test "initList names its child field item" {
    var ty = try DataType.initList(std.testing.allocator, .int32);
    defer ty.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("item", ty.list.name);
    try std.testing.expect(ty.list.nullable);
    try std.testing.expect(ty.list.data_type.equals(.int32));
}

test "initListField keeps the given child field" {
    const allocator = std.testing.allocator;
    var element = try Field.init(allocator, "element", .float64, false);
    defer element.deinit(allocator);

    var ty = try DataType.initListField(allocator, element);
    defer ty.deinit(allocator);

    try std.testing.expectEqualStrings("element", ty.list.name);
    try std.testing.expect(!ty.list.nullable);
    try std.testing.expect(ty.list.data_type.equals(.float64));
}

test "temporal types carry their units and bit widths" {
    try std.testing.expectEqual(@as(?u16, 32), (DataType{ .time32 = .second }).bitWidth());
    try std.testing.expectEqual(@as(?u16, 32), (DataType{ .time32 = .millisecond }).bitWidth());
    try std.testing.expectEqual(@as(?u16, 64), (DataType{ .time64 = .microsecond }).bitWidth());
    try std.testing.expectEqual(@as(?u16, 64), (DataType{ .duration = .nanosecond }).bitWidth());
    try std.testing.expect((DataType{ .time32 = .second }).equals(.{ .time32 = .second }));
    try std.testing.expect(!(DataType{ .time32 = .second }).equals(.{ .time32 = .millisecond }));
    try std.testing.expect(!(DataType{ .time64 = .microsecond }).equals(.{ .duration = .microsecond }));
}

test "zoned timestamps own their timezone" {
    const allocator = std.testing.allocator;
    var utc = try DataType.initTimestamp(allocator, .second, "UTC");
    defer utc.deinit(allocator);
    var utc2 = try DataType.initTimestamp(allocator, .second, "UTC");
    defer utc2.deinit(allocator);
    var paris = try DataType.initTimestamp(allocator, .second, "Europe/Paris");
    defer paris.deinit(allocator);
    const naive = DataType{ .timestamp = .{ .unit = .second } };

    try std.testing.expectEqualStrings("UTC", utc.timestamp.timezone.?);
    try std.testing.expect(utc.equals(utc2));
    try std.testing.expect(!utc.equals(paris));
    try std.testing.expect(!utc.equals(naive));
    try std.testing.expect(naive.equals(.{ .timestamp = .{ .unit = .second } }));
    try std.testing.expectEqual(@as(?u16, 64), utc.bitWidth());

    var copy = try utc.clone(allocator);
    defer copy.deinit(allocator);
    try std.testing.expectEqualStrings("UTC", copy.timestamp.timezone.?);
}

test "decimal types carry precision, scale, and width" {
    const d128 = DataType{ .decimal128 = .{ .precision = 19, .scale = 10 } };
    const d256 = DataType{ .decimal256 = .{ .precision = 76, .scale = 2 } };
    try std.testing.expectEqual(@as(?u16, 128), d128.bitWidth());
    try std.testing.expectEqual(@as(?u16, 256), d256.bitWidth());
    try std.testing.expect(d128.equals(.{ .decimal128 = .{ .precision = 19, .scale = 10 } }));
    try std.testing.expect(!d128.equals(.{ .decimal128 = .{ .precision = 19, .scale = 9 } }));
    try std.testing.expect(!d128.equals(d256));
}

test "fixed-size binary carries its byte width" {
    const fsb = DataType{ .fixed_size_binary = 19 };
    try std.testing.expectEqual(@as(?u16, null), fsb.bitWidth());
    try std.testing.expect(fsb.equals(.{ .fixed_size_binary = 19 }));
    try std.testing.expect(!fsb.equals(.{ .fixed_size_binary = 20 }));
}

test "fixed-size list owns its child field and keeps its size" {
    const allocator = std.testing.allocator;
    var ty = try DataType.initFixedSizeList(allocator, .int32, 3);
    defer ty.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 3), ty.fixed_size_list.size);
    try std.testing.expectEqualStrings("item", ty.fixed_size_list.child.name);
    try std.testing.expect(ty.fixed_size_list.child.data_type.equals(.int32));

    var same = try DataType.initFixedSizeList(allocator, .int32, 3);
    defer same.deinit(allocator);
    var wider = try DataType.initFixedSizeList(allocator, .int32, 4);
    defer wider.deinit(allocator);
    try std.testing.expect(ty.equals(same));
    try std.testing.expect(!ty.equals(wider));

    var copy = try ty.clone(allocator);
    defer copy.deinit(allocator);
    try std.testing.expect(copy.equals(ty));
}

test "dictionary types pair an index type with a value type" {
    const allocator = std.testing.allocator;
    var ty = try DataType.initDictionary(allocator, 0, .int8, .utf8, false);
    defer ty.deinit(allocator);

    try std.testing.expectEqual(@as(i64, 0), ty.dictionary.id);
    try std.testing.expect(ty.dictionary.index.equals(.int8));
    try std.testing.expect(ty.dictionary.value.equals(.utf8));
    try std.testing.expect(!ty.dictionary.ordered);
    try std.testing.expectEqual(@as(?u16, null), ty.bitWidth());

    var same = try DataType.initDictionary(allocator, 0, .int8, .utf8, false);
    defer same.deinit(allocator);
    var wider = try DataType.initDictionary(allocator, 0, .int32, .utf8, false);
    defer wider.deinit(allocator);
    var other_id = try DataType.initDictionary(allocator, 1, .int8, .utf8, false);
    defer other_id.deinit(allocator);
    try std.testing.expect(ty.equals(same));
    try std.testing.expect(!ty.equals(wider));
    // Ids are IPC bookkeeping and do not participate in type equality.
    try std.testing.expect(ty.equals(other_id));

    var copy = try ty.clone(allocator);
    defer copy.deinit(allocator);
    try std.testing.expect(copy.equals(ty));
}
