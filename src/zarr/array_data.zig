//! Type-erased array layout.
//!
//! `ArrayData` is the runtime representation of any Arrow array: a logical type,
//! a length and null count, a list of buffers, and a list of child arrays. It
//! mirrors the layout the Arrow C Data Interface exchanges, so buffer zero is
//! always the validity slot (null when the array has no null buffer), followed
//! by the type-specific offset and value buffers. Nested types carry their
//! elements in `children` rather than in a value buffer.
//!
//! The typed arrays elsewhere in this library are comptime-generic views over
//! the same memory. `ArrayData` is the erased form needed once the concrete Zig
//! type is not known until runtime, as with IPC and the C Data Interface. It
//! owns everything it holds: its type, every buffer, and every child.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const DataType = @import("datatype.zig").DataType;

/// A type-erased, self-owning Arrow array layout.
pub const ArrayData = struct {
    const Self = @This();

    /// Error set for `init`, `validate`, and `validateFull`.
    pub const Error = error{
        BufferCountMismatch,
        ChildCountMismatch,
        InvalidNullCount,
        ChildTypeMismatch,
        /// A buffer is too small for the declared length.
        BufferTooSmall,
        /// An offset is negative, decreasing, or points past its target.
        InvalidOffset,
        /// A utf8 array holds bytes that are not valid UTF-8.
        InvalidUtf8,
        /// A nested child is shorter than its parent requires.
        ChildLengthMismatch,
    };

    /// Allocator that owns the type, buffers, children, and their slices.
    allocator: Allocator,
    /// Logical type; owned.
    data_type: DataType,
    /// Number of elements.
    length: usize,
    /// Number of null elements.
    null_count: usize,
    /// Buffers in canonical layout order; buffer zero is the validity slot,
    /// which is null when the array carries no validity buffer. Owned.
    buffers: []?Buffer,
    /// Child arrays for nested types; owned.
    children: []Self,
    /// Dictionary values for a dictionary-encoded array, delivered separately
    /// from the indices this array stores; heap-allocated and owned.
    dictionary: ?*Self = null,

    /// Number of buffers in the canonical layout of `data_type`, including the
    /// validity slot at index zero.
    pub fn bufferCount(data_type: DataType) usize {
        return switch (data_type) {
            .null => 0,
            .binary, .utf8, .large_binary, .large_utf8 => 3, // validity, offsets, values
            .list => 2, // validity, offsets
            .@"struct", .fixed_size_list => 1, // validity only
            .dictionary => 2, // validity, indices
            else => 2, // validity, values
        };
    }

    /// Number of child arrays in the canonical layout of `data_type`.
    pub fn childCount(data_type: DataType) usize {
        return switch (data_type) {
            .list, .fixed_size_list => 1,
            .@"struct" => |fields| fields.len,
            else => 0,
        };
    }

    /// Assembles an array from its parts, taking ownership of `data_type`,
    /// `buffers`, and `children` and validating the layout. On success the
    /// array owns everything passed in; on error everything passed in is freed,
    /// so the caller must not release it either way.
    pub fn init(
        allocator: Allocator,
        data_type: DataType,
        length: usize,
        null_count: usize,
        buffers: []?Buffer,
        children: []Self,
    ) Error!Self {
        var self = Self{
            .allocator = allocator,
            .data_type = data_type,
            .length = length,
            .null_count = null_count,
            .buffers = buffers,
            .children = children,
        };
        self.validate() catch |err| {
            self.deinit();
            return err;
        };
        return self;
    }

    /// Assembles a dictionary-encoded array: `data_type` must be a
    /// dictionary type, `buffers` holds the validity slot and the indices,
    /// and `dictionary` holds the values array. Ownership follows `init`:
    /// everything passed in is owned by the result on success and freed on
    /// error.
    pub fn initDictionary(
        allocator: Allocator,
        data_type: DataType,
        length: usize,
        null_count: usize,
        buffers: []?Buffer,
        dictionary: Self,
    ) (Error || Allocator.Error)!Self {
        std.debug.assert(data_type == .dictionary);
        var self = Self{
            .allocator = allocator,
            .data_type = data_type,
            .length = length,
            .null_count = null_count,
            .buffers = buffers,
            .children = &.{},
            .dictionary = null,
        };
        // Attach the values before validating, freeing everything through
        // `deinit` on any failure so the caller never owns the parts.
        var dict_values = dictionary;
        const owned = allocator.create(Self) catch |err| {
            dict_values.deinit();
            self.deinit();
            return err;
        };
        owned.* = dict_values;
        self.dictionary = owned;
        self.validate() catch |err| {
            self.deinit();
            return err;
        };
        return self;
    }

    /// Frees the type, every buffer, every child, and their backing slices.
    pub fn deinit(self: *Self) void {
        for (self.buffers) |*maybe| {
            if (maybe.*) |*buf| buf.deinit();
        }
        self.allocator.free(self.buffers);
        for (self.children) |*nested| nested.deinit();
        self.allocator.free(self.children);
        if (self.dictionary) |dict| {
            dict.deinit();
            self.allocator.destroy(dict);
        }
        self.data_type.deinit(self.allocator);
        self.* = undefined;
    }

    /// Deep-copies this array: the type, every buffer, every child, and the
    /// dictionary. The caller owns the returned data.
    pub fn clone(self: Self, allocator: Allocator) Allocator.Error!Self {
        var data_type = try self.data_type.clone(allocator);
        errdefer data_type.deinit(allocator);

        const buffers = try allocator.alloc(?Buffer, self.buffers.len);
        for (buffers) |*slot| slot.* = null;
        var built_buffers: usize = 0;
        errdefer {
            for (buffers[0..built_buffers]) |*maybe| if (maybe.*) |*buf| buf.deinit();
            allocator.free(buffers);
        }
        for (self.buffers, 0..) |maybe, i| {
            if (maybe) |buf| buffers[i] = try Buffer.dupe(allocator, buf.data);
            built_buffers += 1;
        }

        const children = try allocator.alloc(Self, self.children.len);
        var built_children: usize = 0;
        errdefer {
            for (children[0..built_children]) |*built| built.deinit();
            allocator.free(children);
        }
        for (self.children, 0..) |nested, i| {
            children[i] = try nested.clone(allocator);
            built_children += 1;
        }

        var dictionary: ?*Self = null;
        errdefer if (dictionary) |dict| {
            dict.deinit();
            allocator.destroy(dict);
        };
        if (self.dictionary) |dict| {
            const owned = try allocator.create(Self);
            errdefer allocator.destroy(owned);
            owned.* = try dict.clone(allocator);
            dictionary = owned;
        }

        return .{
            .allocator = allocator,
            .data_type = data_type,
            .length = self.length,
            .null_count = self.null_count,
            .buffers = buffers,
            .children = children,
            .dictionary = dictionary,
        };
    }

    /// Deep value equality: same type, length, null count, buffer bytes,
    /// children, and dictionary. Used by the IPC writers to check that later
    /// batches reuse an already-emitted dictionary unchanged.
    pub fn dataEquals(self: Self, other: Self) bool {
        if (!self.data_type.equals(other.data_type)) return false;
        if (self.length != other.length or self.null_count != other.null_count) return false;
        if (self.buffers.len != other.buffers.len) return false;
        for (self.buffers, other.buffers) |a, b| {
            if ((a == null) != (b == null)) return false;
            if (a) |buf_a| if (!std.mem.eql(u8, buf_a.data, b.?.data)) return false;
        }
        if (self.children.len != other.children.len) return false;
        for (self.children, other.children) |a, b| {
            if (!a.dataEquals(b)) return false;
        }
        if ((self.dictionary == null) != (other.dictionary == null)) return false;
        if (self.dictionary) |dict| if (!dict.dataEquals(other.dictionary.?.*)) return false;
        return true;
    }

    /// The validity buffer, or null when the array carries none.
    pub fn validity(self: Self) ?Buffer {
        if (self.buffers.len == 0) return null;
        return self.buffers[0];
    }

    /// Whether element `i` is valid (non-null). An array with no validity
    /// buffer treats every element as valid, while a null array treats every
    /// element as null.
    pub fn isValid(self: Self, i: usize) bool {
        std.debug.assert(i < self.length);
        if (self.data_type == .null) return false;
        const bitmap = self.validity() orelse return true;
        return bitmap.data[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
    }

    /// Views the value buffer as a slice of fixed-width primitives. `T` must
    /// match the logical type's bit width; boolean values are bit-packed and
    /// are not read through this accessor.
    pub fn values(self: Self, comptime T: type) []const T {
        // A dictionary array's value buffer holds its indices, sized by the
        // index type.
        const width_type = if (self.data_type == .dictionary) self.data_type.dictionary.index.* else self.data_type;
        std.debug.assert(width_type.isFixedWidth());
        std.debug.assert(width_type.bitWidth().? == @bitSizeOf(T));
        return self.buffers[1].?.items(T)[0..self.length];
    }

    /// Views the offset buffer of a variable-length or list layout as a slice
    /// of `length + 1` offsets. `OffsetInt` must be `i32` for `binary`, `utf8`,
    /// and `list`, or `i64` for `large_binary` and `large_utf8`.
    pub fn offsets(self: Self, comptime OffsetInt: type) []const OffsetInt {
        return self.buffers[1].?.items(OffsetInt)[0 .. self.length + 1];
    }

    /// The raw bytes of element `i` in a `binary`, `utf8`, `large_binary`, or
    /// `large_utf8` array, sliced out of the value buffer using the offsets.
    pub fn valueBytes(self: Self, i: usize) []const u8 {
        std.debug.assert(i < self.length);
        if (self.data_type == .fixed_size_binary) {
            const width: usize = @intCast(self.data_type.fixed_size_binary);
            return self.buffers[1].?.data[i * width ..][0..width];
        }
        const value_buffer = self.buffers[2].?;
        return switch (self.data_type) {
            .binary, .utf8 => blk: {
                const offs = self.offsets(i32);
                break :blk value_buffer.data[@intCast(offs[i])..@intCast(offs[i + 1])];
            },
            .large_binary, .large_utf8 => blk: {
                const offs = self.offsets(i64);
                break :blk value_buffer.data[@intCast(offs[i])..@intCast(offs[i + 1])];
            },
            else => unreachable,
        };
    }

    /// The child array at index `i` of a nested type.
    pub fn child(self: Self, i: usize) Self {
        return self.children[i];
    }

    /// Checks that the buffer count, child count, and child types match the
    /// canonical layout of `data_type`, and that `null_count` does not exceed
    /// `length`.
    pub fn validate(self: Self) Error!void {
        if (self.buffers.len != bufferCount(self.data_type)) return error.BufferCountMismatch;
        if (self.children.len != childCount(self.data_type)) return error.ChildCountMismatch;
        if (self.null_count > self.length) return error.InvalidNullCount;
        switch (self.data_type) {
            .list => |child_field| {
                if (!self.children[0].data_type.equals(child_field.data_type)) return error.ChildTypeMismatch;
            },
            .fixed_size_list => |fsl| {
                if (!self.children[0].data_type.equals(fsl.child.data_type)) return error.ChildTypeMismatch;
            },
            .dictionary => |d| {
                const dict = self.dictionary orelse return error.ChildCountMismatch;
                if (!dict.data_type.equals(d.value.*)) return error.ChildTypeMismatch;
            },
            .@"struct" => |fields| {
                for (fields, self.children) |field, nested| {
                    if (!nested.data_type.equals(field.data_type)) return error.ChildTypeMismatch;
                }
            },
            else => {},
        }
    }

    /// Deep validation for data from untrusted sources, such as IPC bytes.
    /// On top of `validate`, checks that every buffer is large enough for the
    /// declared length, that the null count matches the validity bitmap, that
    /// offsets start at or above zero, never decrease, and end within their
    /// target, that utf8 values are valid UTF-8, and that nested children are
    /// long enough. Costs O(length), so builders skip it; decoders run it.
    pub fn validateFull(self: Self) Error!void {
        try self.validate();

        if (self.data_type == .null) {
            // A null array is entirely null and carries no buffers.
            if (self.null_count != self.length) return error.InvalidNullCount;
        } else if (self.validity()) |bitmap| {
            if (bitmap.data.len < (self.length + 7) / 8) return error.BufferTooSmall;
            const set_bits = countSetBits(bitmap.data, self.length);
            if (self.length - set_bits != self.null_count) return error.InvalidNullCount;
        } else if (self.null_count != 0) {
            return error.InvalidNullCount;
        }

        switch (self.data_type) {
            .null => {},
            .binary => try self.validateVariable(i32, false),
            .utf8 => try self.validateVariable(i32, true),
            .large_binary => try self.validateVariable(i64, false),
            .large_utf8 => try self.validateVariable(i64, true),
            .list => _ = try self.checkedOffsets(i32, self.children[0].length),
            .fixed_size_list => |fsl| {
                const size: usize = @intCast(fsl.size);
                if (self.children[0].length < self.length * size) return error.ChildLengthMismatch;
            },
            .@"struct" => for (self.children) |nested| {
                if (nested.length < self.length) return error.ChildLengthMismatch;
            },
            .dictionary => |d| {
                const dict = self.dictionary.?;
                try dict.validateFull();
                const index_buffer = self.buffers[1] orelse return error.BufferTooSmall;
                const bits = d.index.bitWidth().?;
                if (self.length > index_buffer.data.len / (bits / 8)) return error.BufferTooSmall;
                try self.validateIndices(dict.length);
            },
            .fixed_size_binary => |width| {
                const value_buffer = self.buffers[1] orelse return error.BufferTooSmall;
                const w: usize = @intCast(width);
                if (w != 0 and self.length > value_buffer.data.len / w) return error.BufferTooSmall;
            },
            else => {
                const bits = self.data_type.bitWidth().?;
                const value_buffer = self.buffers[1] orelse return error.BufferTooSmall;
                if (bits == 1) {
                    if (value_buffer.data.len < (self.length + 7) / 8) return error.BufferTooSmall;
                } else if (self.length > value_buffer.data.len / (bits / 8)) {
                    // Compared by division so a huge declared length cannot
                    // overflow a multiplication.
                    return error.BufferTooSmall;
                }
            },
        }

        for (self.children) |nested| try nested.validateFull();
    }

    /// Checks that every valid dictionary index lies in `[0, limit)`.
    fn validateIndices(self: Self, limit: usize) Error!void {
        return switch (self.data_type.dictionary.index.*) {
            .int8 => self.validateIndicesAs(i8, limit),
            .int16 => self.validateIndicesAs(i16, limit),
            .int32 => self.validateIndicesAs(i32, limit),
            .int64 => self.validateIndicesAs(i64, limit),
            .uint8 => self.validateIndicesAs(u8, limit),
            .uint16 => self.validateIndicesAs(u16, limit),
            .uint32 => self.validateIndicesAs(u32, limit),
            .uint64 => self.validateIndicesAs(u64, limit),
            else => error.ChildTypeMismatch,
        };
    }

    fn validateIndicesAs(self: Self, comptime T: type, limit: usize) Error!void {
        const indices = self.buffers[1].?.items(T)[0..self.length];
        for (indices, 0..) |index, i| {
            if (!self.isValid(i)) continue;
            if (index < 0 or @as(u64, @intCast(index)) >= limit) return error.InvalidOffset;
        }
    }

    /// Set bits among the first `length` bits of `bitmap`, which the caller
    /// has checked is long enough.
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

    /// Checks a variable-length binary layout: offsets against the values
    /// buffer, and optionally that every valid element is UTF-8.
    fn validateVariable(self: Self, comptime OffsetInt: type, check_utf8: bool) Error!void {
        const value_buffer = self.buffers[2] orelse return error.BufferTooSmall;
        const offs = (try self.checkedOffsets(OffsetInt, value_buffer.data.len)) orelse return;
        if (!check_utf8) return;
        for (0..self.length) |i| {
            if (!self.isValid(i)) continue;
            const bytes = value_buffer.data[@intCast(offs[i])..@intCast(offs[i + 1])];
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        }
    }

    /// Shared offset checks for variable-length and list layouts: enough
    /// entries, a non-negative start, monotonicity, and an end within
    /// `limit`. Returns null for a zero-length array with an empty offsets
    /// buffer, which other implementations write.
    fn checkedOffsets(self: Self, comptime OffsetInt: type, limit: usize) Error!?[]const OffsetInt {
        const offsets_buffer = self.buffers[1] orelse return error.BufferTooSmall;
        if (self.length == 0 and offsets_buffer.data.len == 0) return null;
        if (offsets_buffer.data.len / @sizeOf(OffsetInt) < self.length + 1) return error.BufferTooSmall;
        const offs = offsets_buffer.items(OffsetInt)[0 .. self.length + 1];
        if (offs[0] < 0) return error.InvalidOffset;
        var prev = offs[0];
        for (offs[1..]) |o| {
            if (o < prev) return error.InvalidOffset;
            prev = o;
        }
        if (@as(u64, @intCast(offs[self.length])) > limit) return error.InvalidOffset;
        return offs;
    }
};

const testing = std.testing;

test "isValid reads the validity bitmap" {
    const allocator = testing.allocator;
    const values = try Buffer.alloc(allocator, 3 * @sizeOf(i32));
    var validity = try Buffer.allocZeroed(allocator, 1);
    // Mark elements 0 and 2 valid, element 1 null.
    validity.data[0] = 0b0000_0101;
    var data = try ArrayData.init(allocator, .int32, 3, 1, try buffersOf(allocator, &.{ validity, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();

    try testing.expect(data.isValid(0));
    try testing.expect(!data.isValid(1));
    try testing.expect(data.isValid(2));
}

test "isValid treats a missing validity buffer as all-valid" {
    const allocator = testing.allocator;
    const values = try Buffer.alloc(allocator, 2 * @sizeOf(i32));
    var data = try ArrayData.init(allocator, .int32, 2, 0, try buffersOf(allocator, &.{ null, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();

    try testing.expect(data.isValid(0));
    try testing.expect(data.isValid(1));
}

test "isValid reports every element of a null array as null" {
    const allocator = testing.allocator;
    var data = try ArrayData.init(allocator, .null, 3, 3, try buffersOf(allocator, &.{}), try childrenOf(allocator, &.{}));
    defer data.deinit();

    try testing.expect(!data.isValid(0));
    try testing.expect(!data.isValid(2));
}

test "values views the value buffer as a typed slice" {
    const allocator = testing.allocator;
    var values = try Buffer.alloc(allocator, 3 * @sizeOf(i32));
    const view = values.items(i32);
    view[0] = 10;
    view[1] = 20;
    view[2] = 30;
    var data = try ArrayData.init(allocator, .int32, 3, 0, try buffersOf(allocator, &.{ null, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();

    const got = data.values(i32);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(@as(i32, 10), got[0]);
    try testing.expectEqual(@as(i32, 30), got[2]);
}

test "offsets and valueBytes read variable-length values" {
    const allocator = testing.allocator;
    // "arrow" then "zig": offsets [0, 5, 8].
    var offsets = try Buffer.alloc(allocator, 3 * @sizeOf(i32));
    const off = offsets.items(i32);
    off[0] = 0;
    off[1] = 5;
    off[2] = 8;
    const values = try Buffer.dupe(allocator, "arrowzig");
    var data = try ArrayData.init(allocator, .utf8, 2, 0, try buffersOf(allocator, &.{ null, offsets, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();

    const got = data.offsets(i32);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("arrow", data.valueBytes(0));
    try testing.expectEqualStrings("zig", data.valueBytes(1));
}

test "valueBytes reads 64-bit offset layouts" {
    const allocator = testing.allocator;
    var offsets = try Buffer.alloc(allocator, 2 * @sizeOf(i64));
    const off = offsets.items(i64);
    off[0] = 0;
    off[1] = 4;
    const values = try Buffer.dupe(allocator, "data");
    var data = try ArrayData.init(allocator, .large_utf8, 1, 0, try buffersOf(allocator, &.{ null, offsets, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();

    try testing.expectEqualStrings("data", data.valueBytes(0));
}

test "child returns a nested array by index" {
    const allocator = testing.allocator;
    const a_values = try Buffer.alloc(allocator, @sizeOf(i32));
    const a = try ArrayData.init(allocator, .int32, 1, 0, try buffersOf(allocator, &.{ null, a_values }), try childrenOf(allocator, &.{}));
    const b_off = try Buffer.allocZeroed(allocator, 2 * @sizeOf(i32));
    const b_val = try Buffer.alloc(allocator, 1);
    const b = try ArrayData.init(allocator, .utf8, 1, 0, try buffersOf(allocator, &.{ null, b_off, b_val }), try childrenOf(allocator, &.{}));
    const struct_type = try DataType.initStruct(allocator, &.{ .int32, .utf8 });
    var data = try ArrayData.init(allocator, struct_type, 1, 0, try buffersOf(allocator, &.{null}), try childrenOf(allocator, &.{ a, b }));
    defer data.deinit();

    try testing.expect(data.child(0).data_type.equals(.int32));
    try testing.expect(data.child(1).data_type.equals(.utf8));
}

/// Allocates an owned `?Buffer` slice holding `bufs`.
fn buffersOf(allocator: Allocator, bufs: []const ?Buffer) ![]?Buffer {
    const slice = try allocator.alloc(?Buffer, bufs.len);
    @memcpy(slice, bufs);
    return slice;
}

/// Allocates an owned `ArrayData` slice holding `items`.
fn childrenOf(allocator: Allocator, items: []const ArrayData) ![]ArrayData {
    const slice = try allocator.alloc(ArrayData, items.len);
    @memcpy(slice, items);
    return slice;
}

test "primitive layout has a validity slot and a values buffer" {
    const allocator = testing.allocator;
    const values = try Buffer.alloc(allocator, 3 * @sizeOf(i32));
    var data = try ArrayData.init(allocator, .int32, 3, 0, try buffersOf(allocator, &.{ null, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();

    try testing.expectEqual(@as(usize, 3), data.length);
    try testing.expectEqual(@as(usize, 2), data.buffers.len);
    try testing.expect(data.validity() == null);
}

test "binary layout has validity, offsets, and values buffers" {
    const allocator = testing.allocator;
    const offsets = try Buffer.allocZeroed(allocator, 3 * @sizeOf(i32));
    const values = try Buffer.alloc(allocator, 4);
    var data = try ArrayData.init(allocator, .utf8, 2, 0, try buffersOf(allocator, &.{ null, offsets, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();

    try testing.expectEqual(@as(usize, 3), data.buffers.len);
}

test "list layout carries its element type as a child" {
    const allocator = testing.allocator;
    // Child: an int32 array of two elements.
    const child_values = try Buffer.alloc(allocator, 2 * @sizeOf(i32));
    const child = try ArrayData.init(allocator, .int32, 2, 0, try buffersOf(allocator, &.{ null, child_values }), try childrenOf(allocator, &.{}));

    const offsets = try Buffer.allocZeroed(allocator, 2 * @sizeOf(i32));
    const list_type = try DataType.initList(allocator, .int32);
    var data = try ArrayData.init(allocator, list_type, 1, 0, try buffersOf(allocator, &.{ null, offsets }), try childrenOf(allocator, &.{child}));
    defer data.deinit();

    try testing.expectEqual(@as(usize, 2), data.buffers.len);
    try testing.expectEqual(@as(usize, 1), data.children.len);
    try testing.expect(data.children[0].data_type.equals(.int32));
}

test "struct layout carries one child per field" {
    const allocator = testing.allocator;
    const a_values = try Buffer.alloc(allocator, @sizeOf(i32));
    const a = try ArrayData.init(allocator, .int32, 1, 0, try buffersOf(allocator, &.{ null, a_values }), try childrenOf(allocator, &.{}));
    const b_off = try Buffer.allocZeroed(allocator, 2 * @sizeOf(i32));
    const b_val = try Buffer.alloc(allocator, 1);
    const b = try ArrayData.init(allocator, .utf8, 1, 0, try buffersOf(allocator, &.{ null, b_off, b_val }), try childrenOf(allocator, &.{}));

    const struct_type = try DataType.initStruct(allocator, &.{ .int32, .utf8 });
    var data = try ArrayData.init(allocator, struct_type, 1, 0, try buffersOf(allocator, &.{null}), try childrenOf(allocator, &.{ a, b }));
    defer data.deinit();

    try testing.expectEqual(@as(usize, 1), data.buffers.len);
    try testing.expectEqual(@as(usize, 2), data.children.len);
}

test "null layout has no buffers or children" {
    const allocator = testing.allocator;
    var data = try ArrayData.init(allocator, .null, 5, 5, try buffersOf(allocator, &.{}), try childrenOf(allocator, &.{}));
    defer data.deinit();
    try testing.expectEqual(@as(usize, 0), data.buffers.len);
}

test "validate rejects a wrong buffer count" {
    const allocator = testing.allocator;
    // int32 needs 2 buffers; give it 1.
    try testing.expectError(error.BufferCountMismatch, ArrayData.init(allocator, .int32, 0, 0, try buffersOf(allocator, &.{null}), try childrenOf(allocator, &.{})));
}

test "validate rejects a wrong child count" {
    const allocator = testing.allocator;
    // struct with one declared field but zero children.
    const struct_type = try DataType.initStruct(allocator, &.{.int32});
    try testing.expectError(error.ChildCountMismatch, ArrayData.init(allocator, struct_type, 0, 0, try buffersOf(allocator, &.{null}), try childrenOf(allocator, &.{})));
}

test "validate rejects a null count above the length" {
    const allocator = testing.allocator;
    const values = try Buffer.alloc(allocator, @sizeOf(i32));
    try testing.expectError(error.InvalidNullCount, ArrayData.init(allocator, .int32, 1, 2, try buffersOf(allocator, &.{ null, values }), try childrenOf(allocator, &.{})));
}

test "validate rejects a child whose type differs from the declared type" {
    const allocator = testing.allocator;
    // list<int32> whose child is actually utf8.
    const child_off = try Buffer.allocZeroed(allocator, @sizeOf(i32));
    const child_val = try Buffer.alloc(allocator, 1);
    const child = try ArrayData.init(allocator, .utf8, 0, 0, try buffersOf(allocator, &.{ null, child_off, child_val }), try childrenOf(allocator, &.{}));
    const offsets = try Buffer.allocZeroed(allocator, @sizeOf(i32));
    const list_type = try DataType.initList(allocator, .int32);
    try testing.expectError(error.ChildTypeMismatch, ArrayData.init(allocator, list_type, 0, 0, try buffersOf(allocator, &.{ null, offsets }), try childrenOf(allocator, &.{child})));
}

test "array data leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            const values = try Buffer.alloc(allocator, @sizeOf(i32));
            errdefer allocator.free(values.data);
            const buffers = try buffersOf(allocator, &.{ null, values });
            errdefer allocator.free(buffers);
            const children = try childrenOf(allocator, &.{});
            errdefer allocator.free(children);
            // A valid layout, so init never returns an error here; only the
            // allocations above can fail, and each is guarded.
            var data = try ArrayData.init(allocator, .int32, 1, 0, buffers, children);
            data.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}

test "validateFull accepts well-formed arrays" {
    const allocator = testing.allocator;
    // utf8 "hi", "" with a null in the middle.
    var validity = try Buffer.allocZeroed(allocator, 1);
    validity.data[0] = 0b101;
    var offsets = try Buffer.alloc(allocator, 4 * @sizeOf(i32));
    const off = offsets.items(i32);
    off[0] = 0;
    off[1] = 2;
    off[2] = 2;
    off[3] = 2;
    const values = try Buffer.dupe(allocator, "hi");
    var data = try ArrayData.init(allocator, .utf8, 3, 1, try buffersOf(allocator, &.{ validity, offsets, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();
    try data.validateFull();
}

test "validateFull rejects a values buffer too small for the length" {
    const allocator = testing.allocator;
    const values = try Buffer.alloc(allocator, 4); // one i32, three declared
    var data = try ArrayData.init(allocator, .int32, 3, 0, try buffersOf(allocator, &.{ null, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();
    try testing.expectError(error.BufferTooSmall, data.validateFull());
}

test "validateFull rejects a validity buffer too small for the length" {
    const allocator = testing.allocator;
    var validity = try Buffer.allocZeroed(allocator, 1); // 9 elements need 2 bytes
    validity.data[0] = 0xff;
    const values = try Buffer.alloc(allocator, 9 * @sizeOf(i32));
    var data = try ArrayData.init(allocator, .int32, 9, 1, try buffersOf(allocator, &.{ validity, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();
    try testing.expectError(error.BufferTooSmall, data.validateFull());
}

test "validateFull rejects a null count that disagrees with the bitmap" {
    const allocator = testing.allocator;
    var validity = try Buffer.allocZeroed(allocator, 1);
    validity.data[0] = 0b101; // one null of three
    const values = try Buffer.alloc(allocator, 3 * @sizeOf(i32));
    var data = try ArrayData.init(allocator, .int32, 3, 2, try buffersOf(allocator, &.{ validity, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();
    try testing.expectError(error.InvalidNullCount, data.validateFull());
}

test "validateFull rejects nulls without a validity buffer" {
    const allocator = testing.allocator;
    const values = try Buffer.alloc(allocator, 3 * @sizeOf(i32));
    var data = try ArrayData.init(allocator, .int32, 3, 1, try buffersOf(allocator, &.{ null, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();
    try testing.expectError(error.InvalidNullCount, data.validateFull());
}

test "validateFull requires a null array to be entirely null" {
    const allocator = testing.allocator;
    var data = try ArrayData.init(allocator, .null, 3, 2, try buffersOf(allocator, &.{}), try childrenOf(allocator, &.{}));
    defer data.deinit();
    try testing.expectError(error.InvalidNullCount, data.validateFull());
}

fn utf8WithOffsets(allocator: Allocator, offset_values: []const i32, values: []const u8) !ArrayData {
    var offsets = try Buffer.alloc(allocator, offset_values.len * @sizeOf(i32));
    @memcpy(offsets.items(i32)[0..offset_values.len], offset_values);
    const value_buffer = try Buffer.dupe(allocator, values);
    return ArrayData.init(
        allocator,
        .utf8,
        offset_values.len - 1,
        0,
        try buffersOf(allocator, &.{ null, offsets, value_buffer }),
        try childrenOf(allocator, &.{}),
    );
}

test "validateFull rejects decreasing offsets" {
    var data = try utf8WithOffsets(testing.allocator, &.{ 0, 5, 3 }, "abcdefgh");
    defer data.deinit();
    try testing.expectError(error.InvalidOffset, data.validateFull());
}

test "validateFull rejects a negative first offset" {
    var data = try utf8WithOffsets(testing.allocator, &.{ -1, 0, 2 }, "abcdefgh");
    defer data.deinit();
    try testing.expectError(error.InvalidOffset, data.validateFull());
}

test "validateFull rejects an offset past the values buffer" {
    var data = try utf8WithOffsets(testing.allocator, &.{ 0, 4, 10 }, "abcdefgh");
    defer data.deinit();
    try testing.expectError(error.InvalidOffset, data.validateFull());
}

test "validateFull rejects an offsets buffer with too few entries" {
    const allocator = testing.allocator;
    const offsets = try Buffer.allocZeroed(allocator, 2 * @sizeOf(i32)); // 2 elements need 3
    const values = try Buffer.alloc(allocator, 4);
    var data = try ArrayData.init(allocator, .utf8, 2, 0, try buffersOf(allocator, &.{ null, offsets, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();
    try testing.expectError(error.BufferTooSmall, data.validateFull());
}

test "validateFull accepts an empty offsets buffer for a zero-length array" {
    const allocator = testing.allocator;
    const offsets = try Buffer.alloc(allocator, 0);
    const values = try Buffer.alloc(allocator, 0);
    var data = try ArrayData.init(allocator, .utf8, 0, 0, try buffersOf(allocator, &.{ null, offsets, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();
    try data.validateFull();
}

test "validateFull rejects invalid UTF-8 in a utf8 array but not a binary array" {
    const allocator = testing.allocator;
    var utf8_data = try utf8WithOffsets(allocator, &.{ 0, 2 }, &.{ 0xff, 0xfe });
    defer utf8_data.deinit();
    try testing.expectError(error.InvalidUtf8, utf8_data.validateFull());

    var offsets = try Buffer.alloc(allocator, 2 * @sizeOf(i32));
    offsets.items(i32)[0] = 0;
    offsets.items(i32)[1] = 2;
    const values = try Buffer.dupe(allocator, &.{ 0xff, 0xfe });
    var binary_data = try ArrayData.init(allocator, .binary, 1, 0, try buffersOf(allocator, &.{ null, offsets, values }), try childrenOf(allocator, &.{}));
    defer binary_data.deinit();
    try binary_data.validateFull();
}

test "validateFull skips null elements when checking UTF-8" {
    const allocator = testing.allocator;
    var validity = try Buffer.allocZeroed(allocator, 1);
    validity.data[0] = 0b10; // element 0 null, element 1 valid
    var offsets = try Buffer.alloc(allocator, 3 * @sizeOf(i32));
    const off = offsets.items(i32);
    off[0] = 0;
    off[1] = 2;
    off[2] = 3;
    const values = try Buffer.dupe(allocator, &.{ 0xff, 0xfe, 'a' });
    var data = try ArrayData.init(allocator, .utf8, 2, 1, try buffersOf(allocator, &.{ validity, offsets, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();
    try data.validateFull();
}

test "validateFull rejects a list offset past the child length" {
    const allocator = testing.allocator;
    const child_values = try Buffer.alloc(allocator, 2 * @sizeOf(i32));
    const child = try ArrayData.init(allocator, .int32, 2, 0, try buffersOf(allocator, &.{ null, child_values }), try childrenOf(allocator, &.{}));
    var offsets = try Buffer.alloc(allocator, 2 * @sizeOf(i32));
    offsets.items(i32)[0] = 0;
    offsets.items(i32)[1] = 3; // child has 2 elements
    const list_type = try DataType.initList(allocator, .int32);
    var data = try ArrayData.init(allocator, list_type, 1, 0, try buffersOf(allocator, &.{ null, offsets }), try childrenOf(allocator, &.{child}));
    defer data.deinit();
    try testing.expectError(error.InvalidOffset, data.validateFull());
}

test "validateFull rejects a struct child shorter than the struct" {
    const allocator = testing.allocator;
    const child_values = try Buffer.alloc(allocator, @sizeOf(i32));
    const child = try ArrayData.init(allocator, .int32, 1, 0, try buffersOf(allocator, &.{ null, child_values }), try childrenOf(allocator, &.{}));
    const struct_type = try DataType.initStruct(allocator, &.{.int32});
    var data = try ArrayData.init(allocator, struct_type, 2, 0, try buffersOf(allocator, &.{null}), try childrenOf(allocator, &.{child}));
    defer data.deinit();
    try testing.expectError(error.ChildLengthMismatch, data.validateFull());
}

test "validateFull recurses into children" {
    const allocator = testing.allocator;
    // A struct whose int32 child declares more elements than its buffer holds.
    const child_values = try Buffer.alloc(allocator, @sizeOf(i32));
    const child = try ArrayData.init(allocator, .int32, 2, 0, try buffersOf(allocator, &.{ null, child_values }), try childrenOf(allocator, &.{}));
    const struct_type = try DataType.initStruct(allocator, &.{.int32});
    var data = try ArrayData.init(allocator, struct_type, 2, 0, try buffersOf(allocator, &.{null}), try childrenOf(allocator, &.{child}));
    defer data.deinit();
    try testing.expectError(error.BufferTooSmall, data.validateFull());
}

test "fixed-size binary layout reads values and validates sizing" {
    const allocator = testing.allocator;
    const values = try Buffer.dupe(allocator, "abcdefgh");
    var data = try ArrayData.init(allocator, .{ .fixed_size_binary = 4 }, 2, 0, try buffersOf(allocator, &.{ null, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();

    try data.validateFull();
    try testing.expectEqualStrings("abcd", data.valueBytes(0));
    try testing.expectEqualStrings("efgh", data.valueBytes(1));
}

test "validateFull rejects a fixed-size binary buffer that is too small" {
    const allocator = testing.allocator;
    const values = try Buffer.dupe(allocator, "abcdef"); // 2 elements of width 4 need 8
    var data = try ArrayData.init(allocator, .{ .fixed_size_binary = 4 }, 2, 0, try buffersOf(allocator, &.{ null, values }), try childrenOf(allocator, &.{}));
    defer data.deinit();
    try testing.expectError(error.BufferTooSmall, data.validateFull());
}

test "fixed-size list validates its child length" {
    const allocator = testing.allocator;
    const child_values = try Buffer.alloc(allocator, 6 * @sizeOf(i32));
    const child = try ArrayData.init(allocator, .int32, 6, 0, try buffersOf(allocator, &.{ null, child_values }), try childrenOf(allocator, &.{}));
    const list_type = try DataType.initFixedSizeList(allocator, .int32, 3);
    var data = try ArrayData.init(allocator, list_type, 2, 0, try buffersOf(allocator, &.{null}), try childrenOf(allocator, &.{child}));
    defer data.deinit();
    try data.validateFull();

    const short_values = try Buffer.alloc(allocator, 5 * @sizeOf(i32));
    const short_child = try ArrayData.init(allocator, .int32, 5, 0, try buffersOf(allocator, &.{ null, short_values }), try childrenOf(allocator, &.{}));
    const list_type2 = try DataType.initFixedSizeList(allocator, .int32, 3);
    var short_data = try ArrayData.init(allocator, list_type2, 2, 0, try buffersOf(allocator, &.{null}), try childrenOf(allocator, &.{short_child}));
    defer short_data.deinit();
    try testing.expectError(error.ChildLengthMismatch, short_data.validateFull());
}

/// Builds a small utf8 dictionary ["x", "yy"] for dictionary tests.
fn testDictionaryValues(allocator: Allocator) !ArrayData {
    var offsets = try Buffer.alloc(allocator, 3 * @sizeOf(i32));
    const off = offsets.items(i32);
    off[0] = 0;
    off[1] = 1;
    off[2] = 3;
    const values = try Buffer.dupe(allocator, "xyy");
    return ArrayData.init(allocator, .utf8, 2, 0, try buffersOf(allocator, &.{ null, offsets, values }), try childrenOf(allocator, &.{}));
}

test "dictionary arrays validate their indices against the dictionary" {
    const allocator = testing.allocator;
    const dict_type = try DataType.initDictionary(allocator, 0, .int8, .utf8, false);
    var indices = try Buffer.alloc(allocator, 3);
    indices.items(i8)[0] = 1;
    indices.items(i8)[1] = 0;
    indices.items(i8)[2] = 1;

    var data = try ArrayData.initDictionary(
        allocator,
        dict_type,
        3,
        0,
        try buffersOf(allocator, &.{ null, indices }),
        try testDictionaryValues(allocator),
    );
    defer data.deinit();

    try data.validateFull();
    try testing.expectEqual(@as(usize, 2), data.dictionary.?.length);
}

test "validateFull rejects an index past the dictionary" {
    const allocator = testing.allocator;
    const dict_type = try DataType.initDictionary(allocator, 0, .int8, .utf8, false);
    var indices = try Buffer.alloc(allocator, 2);
    indices.items(i8)[0] = 0;
    indices.items(i8)[1] = 2; // the dictionary has 2 entries: 0 and 1
    var data = try ArrayData.initDictionary(
        allocator,
        dict_type,
        2,
        0,
        try buffersOf(allocator, &.{ null, indices }),
        try testDictionaryValues(allocator),
    );
    defer data.deinit();
    try testing.expectError(error.InvalidOffset, data.validateFull());
}

test "validateFull rejects a negative dictionary index" {
    const allocator = testing.allocator;
    const dict_type = try DataType.initDictionary(allocator, 0, .int8, .utf8, false);
    var indices = try Buffer.alloc(allocator, 1);
    indices.items(i8)[0] = -1;
    var data = try ArrayData.initDictionary(
        allocator,
        dict_type,
        1,
        0,
        try buffersOf(allocator, &.{ null, indices }),
        try testDictionaryValues(allocator),
    );
    defer data.deinit();
    try testing.expectError(error.InvalidOffset, data.validateFull());
}

test "array data deep clone is independent" {
    const allocator = testing.allocator;
    const dict_type = try DataType.initDictionary(allocator, 0, .int8, .utf8, false);
    var indices = try Buffer.alloc(allocator, 2);
    indices.items(i8)[0] = 0;
    indices.items(i8)[1] = 1;
    var original = try ArrayData.initDictionary(
        allocator,
        dict_type,
        2,
        0,
        try buffersOf(allocator, &.{ null, indices }),
        try testDictionaryValues(allocator),
    );

    var copy = try original.clone(allocator);
    defer copy.deinit();
    original.deinit();

    try copy.validateFull();
    try testing.expectEqual(@as(usize, 2), copy.length);
    try testing.expectEqualStrings("yy", copy.dictionary.?.valueBytes(1));
}

test "dataEquals compares buffers, children, and dictionaries" {
    const allocator = testing.allocator;
    var a = try testDictionaryValues(allocator);
    defer a.deinit();
    var b = try testDictionaryValues(allocator);
    defer b.deinit();
    try testing.expect(a.dataEquals(b));

    var c = try testDictionaryValues(allocator);
    defer c.deinit();
    @constCast(c.buffers[2].?.data)[0] = 'X';
    try testing.expect(!a.dataEquals(c));
}
