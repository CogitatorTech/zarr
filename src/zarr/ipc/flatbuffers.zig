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

/// Errors from reading a malformed buffer: an offset, length, or field that
/// runs outside the buffer, or a vtable that cannot be valid.
pub const ReadError = error{MalformedFlatBuffers};

/// A read-only view of a table within a finished FlatBuffers buffer. Buffers
/// arriving over IPC are untrusted, so every read is bounds-checked and a
/// corrupt or truncated buffer returns `error.MalformedFlatBuffers` instead
/// of reading out of bounds.
pub const Table = struct {
    buf: []const u8,
    pos: usize,

    /// Fails unless `[start, start + len)` lies inside the buffer.
    fn checkRange(self: Table, start: usize, len: usize) ReadError!void {
        if (start > self.buf.len or self.buf.len - start < len) {
            return error.MalformedFlatBuffers;
        }
    }

    /// Position of this table's vtable, validated to hold at least its two
    /// header fields and to lie inside the buffer.
    fn vtablePos(self: Table) ReadError!usize {
        try self.checkRange(self.pos, 4);
        const soffset = std.mem.readInt(i32, self.buf[self.pos..][0..4], .little);
        const signed = @as(i64, @intCast(self.pos)) - soffset;
        if (signed < 0) return error.MalformedFlatBuffers;
        const vt: usize = @intCast(signed);
        try self.checkRange(vt, 4);
        const vt_size = std.mem.readInt(u16, self.buf[vt..][0..2], .little);
        if (vt_size < 4) return error.MalformedFlatBuffers;
        try self.checkRange(vt, vt_size);
        return vt;
    }

    /// Absolute position of field `id`, or 0 when the field is absent.
    fn fieldPos(self: Table, id: usize) ReadError!usize {
        const vt = try self.vtablePos();
        const vt_size = std.mem.readInt(u16, self.buf[vt..][0..2], .little);
        const entry = 4 + id * 2;
        if (entry + 2 > vt_size) return 0;
        const voff = std.mem.readInt(u16, self.buf[vt + entry ..][0..2], .little);
        if (voff == 0) return 0;
        return self.pos + voff;
    }

    /// Read a scalar field, returning `default` when absent.
    pub fn readScalar(self: Table, comptime T: type, id: usize, default: T) ReadError!T {
        const p = try self.fieldPos(id);
        if (p == 0) return default;
        if (T == bool) {
            try self.checkRange(p, 1);
            return self.buf[p] != 0;
        }
        try self.checkRange(p, @sizeOf(T));
        return std.mem.readInt(T, self.buf[p..][0..@sizeOf(T)], .little);
    }

    /// Follow an offset field, returning the target position or null when
    /// absent. The target is at most one past the end of the buffer; readers
    /// of the target check the bounds of what they read there.
    fn followField(self: Table, id: usize) ReadError!?usize {
        const p = try self.fieldPos(id);
        if (p == 0) return null;
        try self.checkRange(p, 4);
        const target = p + std.mem.readInt(u32, self.buf[p..][0..4], .little);
        if (target > self.buf.len) return error.MalformedFlatBuffers;
        return target;
    }

    /// Read a string field, or null when absent.
    pub fn readString(self: Table, id: usize) ReadError!?[]const u8 {
        const p = (try self.followField(id)) orelse return null;
        try self.checkRange(p, 4);
        const len = std.mem.readInt(u32, self.buf[p..][0..4], .little);
        try self.checkRange(p + 4, len);
        return self.buf[p + 4 ..][0..len];
    }

    /// Read a child table field, or null when absent.
    pub fn readTable(self: Table, id: usize) ReadError!?Table {
        const p = (try self.followField(id)) orelse return null;
        return .{ .buf = self.buf, .pos = p };
    }

    /// Number of elements in a vector field. Bounded by the buffer length, so
    /// a corrupt count cannot drive an oversized allocation.
    pub fn vectorLen(self: Table, id: usize) ReadError!usize {
        const p = (try self.followField(id)) orelse return 0;
        try self.checkRange(p, 4);
        const n = std.mem.readInt(u32, self.buf[p..][0..4], .little);
        // Every element is at least one byte, so more elements than the bytes
        // after the count is impossible.
        if (n > self.buf.len - p - 4) return error.MalformedFlatBuffers;
        return n;
    }

    /// Start position of element `i` of a vector field with `elem_size`-wide
    /// elements, checking the element lies inside both the vector and the
    /// buffer.
    fn vectorElemPos(self: Table, id: usize, i: usize, elem_size: usize) ReadError!usize {
        const p = (try self.followField(id)) orelse return error.MalformedFlatBuffers;
        try self.checkRange(p, 4);
        const n = std.mem.readInt(u32, self.buf[p..][0..4], .little);
        if (i >= n) return error.MalformedFlatBuffers;
        const elem = p + 4 + i * elem_size;
        try self.checkRange(elem, elem_size);
        return elem;
    }

    /// Read element `i` of a scalar vector field.
    pub fn vectorScalar(self: Table, comptime T: type, id: usize, i: usize) ReadError!T {
        const elem = try self.vectorElemPos(id, i, @sizeOf(T));
        return std.mem.readInt(T, self.buf[elem..][0..@sizeOf(T)], .little);
    }

    /// Read element `i` of a vector of offsets (to tables or strings) as a table.
    pub fn vectorTable(self: Table, id: usize, i: usize) ReadError!Table {
        const elem = try self.vectorElemPos(id, i, 4);
        const target = elem + std.mem.readInt(u32, self.buf[elem..][0..4], .little);
        if (target > self.buf.len) return error.MalformedFlatBuffers;
        return .{ .buf = self.buf, .pos = target };
    }

    /// Read element `i` of a vector of strings.
    pub fn vectorString(self: Table, id: usize, i: usize) ReadError![]const u8 {
        const elem = try self.vectorElemPos(id, i, 4);
        const str = elem + std.mem.readInt(u32, self.buf[elem..][0..4], .little);
        try self.checkRange(str, 4);
        const len = std.mem.readInt(u32, self.buf[str..][0..4], .little);
        try self.checkRange(str + 4, len);
        return self.buf[str + 4 ..][0..len];
    }

    /// Position of element `i` of a vector of `elem_size`-wide inline structs.
    pub fn vectorStructPos(self: Table, id: usize, i: usize, elem_size: usize) ReadError!usize {
        return self.vectorElemPos(id, i, elem_size);
    }

    /// Read a little-endian scalar at an absolute position (for struct fields).
    pub fn scalarAt(self: Table, comptime T: type, p: usize) ReadError!T {
        try self.checkRange(p, @sizeOf(T));
        return std.mem.readInt(T, self.buf[p..][0..@sizeOf(T)], .little);
    }
};

/// The root table of a finished buffer.
pub fn getRoot(buf: []const u8) ReadError!Table {
    if (buf.len < 4) return error.MalformedFlatBuffers;
    const root = std.mem.readInt(u32, buf[0..4], .little);
    if (root > buf.len) return error.MalformedFlatBuffers;
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

    const t = try getRoot(buf);
    try testing.expectEqual(@as(i32, 42), try t.readScalar(i32, 0, 0));
    try testing.expectEqual(@as(i64, -7), try t.readScalar(i64, 1, 0));
    try testing.expectEqual(true, try t.readScalar(bool, 2, false));
    try testing.expectEqual(@as(i16, 99), try t.readScalar(i16, 3, 99)); // absent -> default
    try testing.expectEqual(@as(i32, 5), try t.readScalar(i32, 7, 5)); // beyond vtable -> default
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

    const t = try getRoot(buf);
    try testing.expectEqualStrings("arrow", (try t.readString(0)).?);
    try testing.expectEqual(@as(usize, 3), try t.vectorLen(1));
    try testing.expectEqual(@as(i32, 10), try t.vectorScalar(i32, 1, 0));
    try testing.expectEqual(@as(i32, 30), try t.vectorScalar(i32, 1, 2));
    try testing.expect((try t.readString(5)) == null);
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

    const t = try getRoot(buf);
    try testing.expectEqual(@as(usize, 2), try t.vectorLen(0));
    try testing.expectEqual(@as(i32, 100), try (try t.vectorTable(0, 0)).readScalar(i32, 0, 0));
    try testing.expectEqual(@as(i32, 200), try (try t.vectorTable(0, 1)).readScalar(i32, 0, 0));
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

    const t = try getRoot(buf);
    try testing.expectEqual(@as(usize, 2), try t.vectorLen(0));
    const p0 = try t.vectorStructPos(0, 0, 16);
    try testing.expectEqual(@as(i64, 5), try t.scalarAt(i64, p0));
    try testing.expectEqual(@as(i64, 1), try t.scalarAt(i64, p0 + 8));
    const p1 = try t.vectorStructPos(0, 1, 16);
    try testing.expectEqual(@as(i64, 9), try t.scalarAt(i64, p1));
    try testing.expectEqual(@as(i64, 2), try t.scalarAt(i64, p1 + 8));
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

    const t = try getRoot(buf);
    try testing.expectEqual(@as(i32, 88), try t.readScalar(i32, 1, 0));
    try testing.expectEqual(@as(i32, 7), try ((try t.readTable(0)).?).readScalar(i32, 0, 0));
}

test "reads reject buffers too small for a root offset" {
    try testing.expectError(error.MalformedFlatBuffers, getRoot(&.{}));
    try testing.expectError(error.MalformedFlatBuffers, getRoot(&.{ 1, 2, 3 }));
}

test "reads reject a root offset past the buffer" {
    var buf = [_]u8{0} ** 8;
    std.mem.writeInt(u32, buf[0..4], 100, .little);
    try testing.expectError(error.MalformedFlatBuffers, getRoot(&buf));
}

test "reads reject a table whose vtable lies outside the buffer" {
    // A root table at position 4 whose soffset points far before the buffer.
    var buf = [_]u8{0} ** 8;
    std.mem.writeInt(u32, buf[0..4], 4, .little);
    std.mem.writeInt(i32, buf[4..8], 1000, .little);
    const t = try getRoot(&buf);
    try testing.expectError(error.MalformedFlatBuffers, t.readScalar(i32, 0, 0));
}

/// Exercises every read on a possibly corrupt buffer, ignoring errors. Any
/// out-of-bounds access panics and fails the test run.
fn probeReads(buf: []const u8) void {
    const t = getRoot(buf) catch return;
    inline for (0..4) |id| {
        _ = t.readScalar(i64, id, 0) catch {};
        _ = t.readString(id) catch {};
        if (t.readTable(id) catch null) |child| {
            _ = child.readScalar(i32, 0, 0) catch {};
        }
        const n = t.vectorLen(id) catch 0;
        for (0..@min(n, 4)) |i| {
            _ = t.vectorScalar(i32, id, i) catch {};
            _ = t.vectorString(id, i) catch {};
            if (t.vectorTable(id, i) catch null) |elem| {
                _ = elem.readScalar(i32, 0, 0) catch {};
            }
            const pos = t.vectorStructPos(id, i, 16) catch continue;
            _ = t.scalarAt(i64, pos) catch {};
            _ = t.scalarAt(i64, pos + 8) catch {};
        }
    }
}

test "corrupt buffers error instead of reading out of bounds" {
    // A valid buffer holding every shape the probe reads.
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const name = try b.createString("probe");
    try b.startVector(4, 2, 4);
    _ = try b.pushScalar(i32, 2);
    _ = try b.pushScalar(i32, 1);
    const vec = try b.endVector(2);
    b.startTable();
    const child = try b.endTable();
    b.startTable();
    try b.addScalar(i64, 0, 7, 0);
    try b.addOffset(1, name);
    try b.addOffset(2, vec);
    try b.addOffset(3, child);
    const root = try b.endTable();
    const buf = try b.finish(root);

    // Every truncation and every single-byte corruption must be survivable.
    for (0..buf.len) |len| probeReads(buf[0..len]);
    const copy = try testing.allocator.dupe(u8, buf);
    defer testing.allocator.free(copy);
    for (0..copy.len) |i| {
        const original = copy[i];
        copy[i] = 0xff;
        probeReads(copy);
        copy[i] = original;
    }
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
