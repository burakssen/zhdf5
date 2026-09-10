//! Dataset view: decoded dataspace/datatype/layout plus raw and typed
//! reads. Compact and contiguous storage read end to end; chunked storage
//! decodes to an identifier and fails reads explicitly. Only native
//! byte order is returned; anything else is an explicit error.

const std = @import("std");
const builtin = @import("builtin");
const format = @import("../format/root.zig");
const file_mod = @import("file.zig");
const object_mod = @import("object.zig");

pub const Dataset = struct {
    object: object_mod.Object,
    dataspace: format.Dataspace,
    datatype: format.Datatype,
    layout: format.Layout,

    pub fn open(file: *file_mod.File, address: format.Address, allocator: std.mem.Allocator) !Dataset {
        return fromObject(try object_mod.Object.open(file, address), allocator);
    }

    pub fn fromObject(obj: object_mod.Object, allocator: std.mem.Allocator) !Dataset {
        if (obj.kind() != .dataset) return error.NotADataset;
        const file = obj.file;
        const header = &obj.header;
        const ds_range = header.dataspace orelse return error.MissingDataspace;
        const dt_range = header.datatype orelse return error.MissingDatatype;
        const lo_range = header.layout orelse return error.MissingLayout;

        const ds_bytes = try readPayload(file, ds_range, allocator);
        defer allocator.free(ds_bytes);
        const dataspace = try format.dataspace.decode(ds_bytes, file.ctx);

        const dt_bytes = try readPayload(file, dt_range, allocator);
        defer allocator.free(dt_bytes);
        const datatype = try format.datatype.decode(dt_bytes);

        const lo_bytes = try readPayload(file, lo_range, allocator);
        defer allocator.free(lo_bytes);
        const layout = try format.layout.decode(lo_bytes, lo_range.offset, file.ctx);

        return .{ .object = obj, .dataspace = dataspace, .datatype = datatype, .layout = layout };
    }

    pub fn rank(self: *const Dataset) usize {
        return self.dataspace.rank;
    }

    pub fn shape(self: *const Dataset) []const u64 {
        return self.dataspace.dims[0..self.dataspace.rank];
    }

    pub fn elementCount(self: *const Dataset) !u64 {
        return self.dataspace.elementCount();
    }

    /// Storage bytes for the whole array, overflow-checked.
    pub fn byteSize(self: *const Dataset) !u64 {
        const count = try self.dataspace.elementCount();
        return std.math.mul(u64, count, self.datatype.size()) catch return error.DataspaceOverflow;
    }

    /// Raw little-endian array bytes in C order; empty for null dataspaces.
    pub fn readRaw(self: *Dataset, allocator: std.mem.Allocator) ![]u8 {
        const total = try self.byteSize();
        const n: usize = std.math.cast(usize, total) orelse return error.DatasetTooLarge;
        const out = try allocator.alloc(u8, n);
        errdefer allocator.free(out);
        try self.readInto(out);
        return out;
    }

    fn readInto(self: *Dataset, buf: []u8) !void {
        if (buf.len == 0) return;
        const f = self.object.file;
        switch (self.layout) {
            .compact => |c| {
                if (buf.len != c.len) return error.CorruptCompactSize;
                try f.source.readAt(c.data_offset, buf);
            },
            .contiguous => |c| {
                const off = try f.ctx.resolve(c.address);
                const end = std.math.add(u64, off, buf.len) catch return error.DatasetTooLarge;
                if (end > f.ctx.eof) return error.TruncatedDataset;
                try f.source.readAt(off, buf);
            },
            .chunked => return error.ChunkedDatasetUnsupported,
        }
    }

    /// Typed read: `T` must match the stored datatype exactly (kind, width,
    /// signedness) and the storage must be native byte order.
    pub fn readAll(self: *Dataset, comptime T: type, allocator: std.mem.Allocator) ![]T {
        const want = comptimeWant(T) orelse return error.UnsupportedReadType;
        const have = self.datatype;
        const matches = switch (want.kind) {
            .integer => have == .integer and have.integer.size == want.size and have.integer.signed == want.signed,
            .float => have == .float and have.float.size == want.size,
        };
        if (!matches) return error.DatatypeMismatch;
        const order = switch (have) {
            .integer => |i| i.order,
            .float => |f| f.order,
        };
        if (order != nativeOrder()) return error.NonNativeByteOrder;
        const count = try self.dataspace.elementCount();
        const n: usize = std.math.cast(usize, count) orelse return error.DatasetTooLarge;
        const out = try allocator.alloc(T, n);
        errdefer allocator.free(out);
        try self.readInto(std.mem.sliceAsBytes(out));
        return out;
    }
};

const Want = struct {
    kind: enum { integer, float },
    size: u8,
    signed: bool = false,
};

fn nativeOrder() format.datatype.ByteOrder {
    return switch (builtin.cpu.arch.endian()) {
        .little => .little,
        .big => .big,
    };
}

fn comptimeWant(comptime T: type) ?Want {
    return switch (@typeInfo(T)) {
        .int => |info| .{
            .kind = .integer,
            .size = @sizeOf(T),
            .signed = info.signedness == .signed,
        },
        .float => .{ .kind = .float, .size = @sizeOf(T) },
        else => null,
    };
}

fn readPayload(file: *file_mod.File, range: format.link.MessageRange, allocator: std.mem.Allocator) ![]u8 {
    const end = std.math.add(u64, range.offset, range.len) catch return error.TruncatedMessage;
    if (end > file.ctx.eof) return error.TruncatedMessage;
    const buf = try allocator.alloc(u8, range.len);
    errdefer allocator.free(buf);
    try file.source.readAt(range.offset, buf);
    return buf;
}

test "contiguous i32 vector reads back" {
    var file = try file_mod.File.open(std.testing.io, "testdata/v3-datasets.h5", .{});
    defer file.deinit();
    var ds = try file.dataset("/vec_i32", std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), ds.rank());
    try std.testing.expectEqualSlices(u64, &[_]u64{10}, ds.shape());
    const values = try ds.readAll(i32, std.testing.allocator);
    defer std.testing.allocator.free(values);
    for (values, 0..) |v, i| try std.testing.expectEqual(@as(i32, @intCast(i)), v);
    const raw = try ds.readRaw(std.testing.allocator);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqual(@as(usize, 40), raw.len);
}

test "contiguous f64 matrix and scalar read back" {
    var file = try file_mod.File.open(std.testing.io, "testdata/v3-datasets.h5", .{});
    defer file.deinit();
    var mat = try file.dataset("/mat_f64", std.testing.allocator);
    try std.testing.expectEqualSlices(u64, &[_]u64{ 3, 4 }, mat.shape());
    const mvals = try mat.readAll(f64, std.testing.allocator);
    defer std.testing.allocator.free(mvals);
    try std.testing.expectEqual(@as(usize, 12), mvals.len);
    for (mvals, 0..) |v, i| try std.testing.expectEqual(@as(f64, @floatFromInt(i)), v);

    var scalar = try file.dataset("/scalar", std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), scalar.rank());
    const svals = try scalar.readAll(f64, std.testing.allocator);
    defer std.testing.allocator.free(svals);
    try std.testing.expectEqualSlices(f64, &[_]f64{3.25}, svals);
}

test "compact storage reads inline bytes" {
    var file = try file_mod.File.open(std.testing.io, "testdata/v3-datasets.h5", .{});
    defer file.deinit();
    var tiny = try file.dataset("/tiny", std.testing.allocator);
    const values = try tiny.readAll(u8, std.testing.allocator);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 4 }, values);
}

test "null dataspace reads empty" {
    var file = try file_mod.File.open(std.testing.io, "testdata/v3-datasets.h5", .{});
    defer file.deinit();
    var nothing = try file.dataset("/nothing", std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), try nothing.elementCount());
    const raw = try nothing.readRaw(std.testing.allocator);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqual(@as(usize, 0), raw.len);
}

test "mismatched reads are explicit errors" {
    var file = try file_mod.File.open(std.testing.io, "testdata/v3-datasets.h5", .{});
    defer file.deinit();
    var vec = try file.dataset("/vec_i32", std.testing.allocator);
    try std.testing.expectError(error.DatatypeMismatch, vec.readAll(u8, std.testing.allocator));
    try std.testing.expectError(error.DatatypeMismatch, vec.readAll(f32, std.testing.allocator));
    try std.testing.expectError(error.UnsupportedReadType, vec.readAll(bool, std.testing.allocator));
    var big = try file.dataset("/big_i32", std.testing.allocator);
    const raw = try big.readRaw(std.testing.allocator);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqual(@as(usize, 16), raw.len);
    if (builtin.cpu.arch.endian() == .little) {
        try std.testing.expectError(error.NonNativeByteOrder, big.readAll(i32, std.testing.allocator));
    }
    try std.testing.expectError(error.NotADataset, file.dataset("/", std.testing.allocator));
}

test "chunked storage parses but does not read" {
    var file = try file_mod.File.open(std.testing.io, "testdata/v3-chunked.h5", .{});
    defer file.deinit();
    var image = try file.dataset("/image", std.testing.allocator);
    try std.testing.expectEqualSlices(u64, &[_]u64{ 64, 64 }, image.shape());
    try std.testing.expectError(error.ChunkedDatasetUnsupported, image.readRaw(std.testing.allocator));
}
