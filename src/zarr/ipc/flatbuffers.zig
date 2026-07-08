//! A minimal FlatBuffers runtime for Arrow IPC metadata.
//!
//! Arrow IPC encodes its metadata (the `Message`, `Schema`, and `RecordBatch`
//! tables) as FlatBuffers. This module implements just enough of the format to
//! build and read those tables: scalars, strings, vectors of scalars or
//! offsets, inline structs, and tables with vtables. It does not deduplicate
//! vtables, which is a size optimization the format does not require.
//!
//! FlatBuffers builds back to front. The `Builder` accumulates bytes in reverse
//! and flips them once at `finish`, so throughout building the current offset is
//! simply how many bytes have been written. Offsets returned by `create*` and
//! `endTable` are these reverse offsets and stay valid until `finish`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A reverse offset into a `Builder`, referring to a finished sub-object.
pub const Offset = u32;

/// Builds a FlatBuffers buffer back to front.
pub const Builder = struct {
    allocator: Allocator,
    /// Bytes in reverse order; `finish` flips this into the final buffer.
    buf: std.ArrayListUnmanaged(u8),
    /// Largest alignment requested, used to align the root.
    min_align: usize,
    /// Field slots for the table under construction: reverse offset per field
    /// id, or 0 when the field is unset.
    vtable: std.ArrayListUnmanaged(u32),
    /// Offset recorded at `startTable`, marking the end of the table's data.
    table_end: u32,

    pub fn init(allocator: Allocator) Builder {
        return .{
            .allocator = allocator,
            .buf = .empty,
            .min_align = 1,
            .vtable = .empty,
            .table_end = 0,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.buf.deinit(self.allocator);
        self.vtable.deinit(self.allocator);
        self.* = undefined;
    }

    /// The current offset: the number of bytes written so far.
    fn offset(self: Builder) u32 {
        return @intCast(self.buf.items.len);
    }

    /// Append `bytes` so that, after the final flip, they read in order.
    fn place(self: *Builder, bytes: []const u8) Allocator.Error!void {
        var i = bytes.len;
        while (i > 0) {
            i -= 1;
            try self.buf.append(self.allocator, bytes[i]);
        }
    }

    fn placeScalar(self: *Builder, comptime T: type, value: T) Allocator.Error!void {
        if (T == bool) {
            try self.buf.append(self.allocator, @intFromBool(value));
            return;
        }
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, value, .little);
        try self.place(&tmp);
    }

    fn pad(self: *Builder, n: usize) Allocator.Error!void {
        try self.buf.appendNTimes(self.allocator, 0, n);
    }

    /// Pad so that after writing `additional` more bytes plus a `size`-wide
    /// value, the value is `size`-aligned.
    fn prep(self: *Builder, size: usize, additional: usize) Allocator.Error!void {
        if (size > self.min_align) self.min_align = size;
        const len = self.buf.items.len + additional;
        const pad_bytes = ((~len) +% 1) & (size - 1);
        try self.pad(pad_bytes);
    }

    /// Write a scalar as a standalone value and return its offset. Used for
    /// vector elements, not table fields.
    pub fn pushScalar(self: *Builder, comptime T: type, value: T) Allocator.Error!Offset {
        try self.prep(@sizeOf(T), 0);
        try self.placeScalar(T, value);
        return self.offset();
    }

    /// Write a relative offset pointing at `target` and return the new offset.
    fn pushOffset(self: *Builder, target: Offset) Allocator.Error!void {
        try self.prep(4, 0);
        const relative = self.offset() - target + 4;
        try self.placeScalar(u32, relative);
    }

    /// Create a string and return its offset.
    pub fn createString(self: *Builder, s: []const u8) Allocator.Error!Offset {
        try self.prep(4, s.len + 1);
        try self.place(&.{0}); // null terminator
        try self.place(s);
        try self.placeScalar(u32, @intCast(s.len));
        return self.offset();
    }

    /// Begin a vector of `count` elements each `elem_size` bytes wide and
    /// aligned to `elem_align`. Push the elements last-to-first, then call
    /// `endVector`.
    pub fn startVector(self: *Builder, elem_size: usize, count: usize, elem_align: usize) Allocator.Error!void {
        try self.prep(4, elem_size * count);
        try self.prep(elem_align, elem_size * count);
    }

    /// Finish a vector begun with `startVector` and return its offset.
    pub fn endVector(self: *Builder, count: usize) Allocator.Error!Offset {
        try self.placeScalar(u32, @intCast(count));
        return self.offset();
    }

    /// Push an offset as a vector element (last-to-first order).
    pub fn pushOffsetElement(self: *Builder, target: Offset) Allocator.Error!void {
        try self.pushOffset(target);
    }

    /// Push raw struct bytes (in field order) as a vector element. The caller
    /// aligns the vector via `startVector` with the struct's alignment.
    pub fn pushStructBytes(self: *Builder, bytes: []const u8) Allocator.Error!void {
        try self.place(bytes);
    }

    /// Begin a table. Add fields, then call `endTable`.
    pub fn startTable(self: *Builder) void {
        self.vtable.clearRetainingCapacity();
        self.table_end = self.offset();
    }

    fn slot(self: *Builder, id: usize) Allocator.Error!void {
        if (self.vtable.items.len <= id) {
            try self.vtable.appendNTimes(self.allocator, 0, id + 1 - self.vtable.items.len);
        }
        self.vtable.items[id] = self.offset();
    }

    /// Add a scalar field. Omitted (left to default on read) when equal to
    /// `default`.
    pub fn addScalar(self: *Builder, comptime T: type, id: usize, value: T, default: T) Allocator.Error!void {
        if (value == default) return;
        try self.prep(@sizeOf(T), 0);
        try self.placeScalar(T, value);
        try self.slot(id);
    }

    /// Add an offset field (to a string, vector, or table). Omitted when 0.
    pub fn addOffset(self: *Builder, id: usize, target: Offset) Allocator.Error!void {
        if (target == 0) return;
        try self.pushOffset(target);
        try self.slot(id);
    }

    /// Finish the current table and return its offset.
    pub fn endTable(self: *Builder) Allocator.Error!Offset {
        try self.prep(4, 0);
        try self.placeScalar(i32, 0); // soffset placeholder, patched below
        const object_offset = self.offset();

        const field_count = self.vtable.items.len;
        var i = field_count;
        while (i > 0) {
            i -= 1;
            const voff: u16 = if (self.vtable.items[i] == 0) 0 else @intCast(object_offset - self.vtable.items[i]);
            try self.placeScalar(u16, voff);
        }
        try self.placeScalar(u16, @intCast(object_offset - self.table_end)); // table size
        try self.placeScalar(u16, @intCast((field_count + 2) * 2)); // vtable size
        const vtable_offset = self.offset();

        // Patch the soffset: table points back to its vtable.
        self.patchScalar(i32, object_offset, @intCast(@as(i64, vtable_offset) - @as(i64, object_offset)));
        return object_offset;
    }

    /// Overwrite an already-written scalar at reverse `at` (its high end).
    fn patchScalar(self: *Builder, comptime T: type, at: u32, value: T) void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, value, .little);
        for (0..@sizeOf(T)) |k| {
            self.buf.items[at - @sizeOf(T) + k] = tmp[@sizeOf(T) - 1 - k];
        }
    }

    /// Finish the buffer with `root` as the root table, and return the final
    /// forward-order bytes, which stay valid until `deinit`.
    pub fn finish(self: *Builder, root: Offset) Allocator.Error![]const u8 {
        try self.prep(self.min_align, 4);
        try self.pushOffset(root);
        std.mem.reverse(u8, self.buf.items);
        return self.buf.items;
    }
};

/// A read-only view of a table within a finished FlatBuffers buffer.
pub const Table = struct {
    buf: []const u8,
    pos: usize,

    fn vtablePos(self: Table) usize {
        const soffset = std.mem.readInt(i32, self.buf[self.pos..][0..4], .little);
        return @intCast(@as(i64, @intCast(self.pos)) - soffset);
    }

    /// Absolute position of field `id`, or 0 when the field is absent.
    fn fieldPos(self: Table, id: usize) usize {
        const vt = self.vtablePos();
        const vt_size = std.mem.readInt(u16, self.buf[vt..][0..2], .little);
        const entry = 4 + id * 2;
        if (entry >= vt_size) return 0;
        const voff = std.mem.readInt(u16, self.buf[vt + entry ..][0..2], .little);
        if (voff == 0) return 0;
        return self.pos + voff;
    }

    /// Read a scalar field, returning `default` when absent.
    pub fn readScalar(self: Table, comptime T: type, id: usize, default: T) T {
        const p = self.fieldPos(id);
        if (p == 0) return default;
        if (T == bool) return self.buf[p] != 0;
        return std.mem.readInt(T, self.buf[p..][0..@sizeOf(T)], .little);
    }

    /// Follow an offset field, returning the target position or null when absent.
    fn followField(self: Table, id: usize) ?usize {
        const p = self.fieldPos(id);
        if (p == 0) return null;
        return p + std.mem.readInt(u32, self.buf[p..][0..4], .little);
    }

    /// Read a string field, or null when absent.
    pub fn readString(self: Table, id: usize) ?[]const u8 {
        const p = self.followField(id) orelse return null;
        const len = std.mem.readInt(u32, self.buf[p..][0..4], .little);
        return self.buf[p + 4 ..][0..len];
    }

    /// Read a child table field, or null when absent.
    pub fn readTable(self: Table, id: usize) ?Table {
        const p = self.followField(id) orelse return null;
        return .{ .buf = self.buf, .pos = p };
    }

    /// Number of elements in a vector field.
    pub fn vectorLen(self: Table, id: usize) usize {
        const p = self.followField(id) orelse return 0;
        return std.mem.readInt(u32, self.buf[p..][0..4], .little);
    }

    /// Read element `i` of a scalar vector field.
    pub fn vectorScalar(self: Table, comptime T: type, id: usize, i: usize) T {
        const p = self.followField(id).?;
        const elem = p + 4 + i * @sizeOf(T);
        return std.mem.readInt(T, self.buf[elem..][0..@sizeOf(T)], .little);
    }

    /// Read element `i` of a vector of offsets (to tables or strings) as a table.
    pub fn vectorTable(self: Table, id: usize, i: usize) Table {
        const p = self.followField(id).?;
        const elem = p + 4 + i * 4;
        return .{ .buf = self.buf, .pos = elem + std.mem.readInt(u32, self.buf[elem..][0..4], .little) };
    }

    /// Read element `i` of a vector of strings.
    pub fn vectorString(self: Table, id: usize, i: usize) []const u8 {
        const p = self.followField(id).?;
        const elem = p + 4 + i * 4;
        const str = elem + std.mem.readInt(u32, self.buf[elem..][0..4], .little);
        const len = std.mem.readInt(u32, self.buf[str..][0..4], .little);
        return self.buf[str + 4 ..][0..len];
    }

    /// Position of element `i` of a vector of `elem_size`-wide inline structs.
    pub fn vectorStructPos(self: Table, id: usize, i: usize, elem_size: usize) usize {
        const p = self.followField(id).?;
        return p + 4 + i * elem_size;
    }

    /// Read a little-endian scalar at an absolute position (for struct fields).
    pub fn scalarAt(self: Table, comptime T: type, p: usize) T {
        return std.mem.readInt(T, self.buf[p..][0..@sizeOf(T)], .little);
    }
};

/// The root table of a finished buffer.
pub fn getRoot(buf: []const u8) Table {
    const root = std.mem.readInt(u32, buf[0..4], .little);
    return .{ .buf = buf, .pos = root };
}

const testing = std.testing;

test "round-trip a table of scalars" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    b.startTable();
    try b.addScalar(i32, 0, 42, 0);
    try b.addScalar(i64, 1, -7, 0);
    try b.addScalar(bool, 2, true, false);
    try b.addScalar(i16, 3, 0, 0); // equals default, omitted
    const root = try b.endTable();
    const buf = try b.finish(root);

    const t = getRoot(buf);
    try testing.expectEqual(@as(i32, 42), t.readScalar(i32, 0, 0));
    try testing.expectEqual(@as(i64, -7), t.readScalar(i64, 1, 0));
    try testing.expectEqual(true, t.readScalar(bool, 2, false));
    try testing.expectEqual(@as(i16, 99), t.readScalar(i16, 3, 99)); // absent -> default
    try testing.expectEqual(@as(i32, 5), t.readScalar(i32, 7, 5)); // beyond vtable -> default
}

test "round-trip a string and a scalar vector" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    // Children first.
    const name = try b.createString("arrow");
    try b.startVector(@sizeOf(i32), 3, @sizeOf(i32));
    _ = try b.pushScalar(i32, 30);
    _ = try b.pushScalar(i32, 20);
    _ = try b.pushScalar(i32, 10); // pushed last-to-first
    const vec = try b.endVector(3);

    b.startTable();
    try b.addOffset(0, name);
    try b.addOffset(1, vec);
    const root = try b.endTable();
    const buf = try b.finish(root);

    const t = getRoot(buf);
    try testing.expectEqualStrings("arrow", t.readString(0).?);
    try testing.expectEqual(@as(usize, 3), t.vectorLen(1));
    try testing.expectEqual(@as(i32, 10), t.vectorScalar(i32, 1, 0));
    try testing.expectEqual(@as(i32, 30), t.vectorScalar(i32, 1, 2));
    try testing.expect(t.readString(5) == null);
}

test "round-trip a vector of child tables" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    // Two child tables, each with one scalar field.
    b.startTable();
    try b.addScalar(i32, 0, 100, 0);
    const c0 = try b.endTable();
    b.startTable();
    try b.addScalar(i32, 0, 200, 0);
    const c1 = try b.endTable();

    try b.startVector(4, 2, 4);
    try b.pushOffsetElement(c1);
    try b.pushOffsetElement(c0);
    const vec = try b.endVector(2);

    b.startTable();
    try b.addOffset(0, vec);
    const root = try b.endTable();
    const buf = try b.finish(root);

    const t = getRoot(buf);
    try testing.expectEqual(@as(usize, 2), t.vectorLen(0));
    try testing.expectEqual(@as(i32, 100), t.vectorTable(0, 0).readScalar(i32, 0, 0));
    try testing.expectEqual(@as(i32, 200), t.vectorTable(0, 1).readScalar(i32, 0, 0));
}

test "round-trip a vector of inline structs" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    // Two 16-byte structs of {i64, i64}, in field order.
    var s0: [16]u8 = undefined;
    std.mem.writeInt(i64, s0[0..8], 5, .little);
    std.mem.writeInt(i64, s0[8..16], 1, .little);
    var s1: [16]u8 = undefined;
    std.mem.writeInt(i64, s1[0..8], 9, .little);
    std.mem.writeInt(i64, s1[8..16], 2, .little);

    try b.startVector(16, 2, 8);
    try b.pushStructBytes(&s1);
    try b.pushStructBytes(&s0); // last-to-first
    const vec = try b.endVector(2);

    b.startTable();
    try b.addOffset(0, vec);
    const root = try b.endTable();
    const buf = try b.finish(root);

    const t = getRoot(buf);
    try testing.expectEqual(@as(usize, 2), t.vectorLen(0));
    const p0 = t.vectorStructPos(0, 0, 16);
    try testing.expectEqual(@as(i64, 5), t.scalarAt(i64, p0));
    try testing.expectEqual(@as(i64, 1), t.scalarAt(i64, p0 + 8));
    const p1 = t.vectorStructPos(0, 1, 16);
    try testing.expectEqual(@as(i64, 9), t.scalarAt(i64, p1));
    try testing.expectEqual(@as(i64, 2), t.scalarAt(i64, p1 + 8));
}

test "nested table field round-trips" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    b.startTable();
    try b.addScalar(i32, 0, 7, 0);
    const child = try b.endTable();

    b.startTable();
    try b.addOffset(0, child);
    try b.addScalar(i32, 1, 88, 0);
    const root = try b.endTable();
    const buf = try b.finish(root);

    const t = getRoot(buf);
    try testing.expectEqual(@as(i32, 88), t.readScalar(i32, 1, 0));
    try testing.expectEqual(@as(i32, 7), t.readTable(0).?.readScalar(i32, 0, 0));
}

test "builder leaks nothing on allocation failure" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            var b = Builder.init(allocator);
            defer b.deinit();
            const name = try b.createString("x");
            b.startTable();
            try b.addOffset(0, name);
            try b.addScalar(i32, 1, 1, 0);
            const root = try b.endTable();
            _ = try b.finish(root);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}
