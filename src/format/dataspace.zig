//! Dataspace message (0x0001): scalar/simple/null shapes with current and
//! maximum dimensions. Maximums of all-ones mean unlimited.
//!
//! Version 1 carries an 8-byte preamble (the low 4 bytes are reserved);
//! version 2 replaces the reserved bytes with a dataspace-type byte
//! (0 scalar, 1 simple, 2 null) and drops the preamble padding.
//! Dimension fields are length-sized, not fixed u64.

const std = @import("std");
const wire = @import("../wire/root.zig");

pub const Kind = enum {
    scalar,
    simple,
    null,
};

pub const Dataspace = struct {
    kind: Kind,
    rank: u8 = 0,
    dims: [32]u64 = [_]u64{0} ** 32,
    /// Present maximums; null entries are unlimited.
    maxdims: [32]?u64 = [_]?u64{null} ** 32,
    has_max: bool = false,

    pub fn elementCount(self: *const Dataspace) !u64 {
        switch (self.kind) {
            .scalar => return 1,
            .null => return 0,
            .simple => {},
        }
        var total: u64 = 1;
        for (self.dims[0..self.rank]) |d| {
            total = std.math.mul(u64, total, d) catch return error.DataspaceOverflow;
        }
        return total;
    }
};

/// Decodes a dataspace message payload (pure, bounds-checked).
pub fn decode(payload: []const u8, ctx: wire.Context) !Dataspace {
    if (payload.len < 4) return error.TruncatedDataspace;
    const version = payload[0];
    const ndims = payload[1];
    const flags = payload[2];
    if (version == 1) {
        if (payload.len < 8) return error.TruncatedDataspace;
        if (payload[3] != 0 or !std.mem.eql(u8, payload[4..8], &[_]u8{0} ** 4)) return error.InvalidReservedField;
        if (ndims == 0) {
            if (payload.len != 8) return error.TrailingDataspaceBytes;
            return .{ .kind = .scalar };
        }
        return decodeSimple(payload[8..], ndims, flags, ctx);
    }
    if (version == 2) {
        const dtype = payload[3];
        if (dtype == 2) {
            if (ndims != 0) return error.InvalidNullDataspace;
            return .{ .kind = .null };
        }
        if (dtype == 0) {
            if (ndims != 0) return error.InvalidScalarDataspace;
            return .{ .kind = .scalar };
        }
        if (dtype != 1) return error.UnsupportedDataspace;
        if (ndims == 0) return error.InvalidSimpleDataspace;
        return decodeSimple(payload[4..], ndims, flags, ctx);
    }
    return error.UnsupportedDataspaceVersion;
}

fn decodeSimple(rest: []const u8, ndims: u8, flags: u8, ctx: wire.Context) !Dataspace {
    if (ndims > ctx.limits.dataspace_dims) return error.TooManyDimensions;
    const w = ctx.widths.length;
    if (w == 0 or w > 8) return error.UnsupportedDataspace;
    const n: usize = ndims;
    const want = n * w * (1 + (if (flags & 0x01 != 0) @as(usize, 1) else 0) + (if (flags & 0x02 != 0) @as(usize, 1) else 0));
    if (rest.len != want) {
        if (rest.len < want) return error.TruncatedDataspace;
        return error.TrailingDataspaceBytes;
    }
    var space = Dataspace{ .kind = .simple, .rank = ndims };
    var pos: usize = 0;
    for (0..n) |i| {
        space.dims[i] = takeWidth(rest, &pos, w);
    }
    if (flags & 0x01 != 0) {
        space.has_max = true;
        const cap: u64 = if (w == 8) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(w * 8)) - 1;
        for (0..n) |i| {
            const m = takeWidth(rest, &pos, w);
            space.maxdims[i] = if (m == cap) null else m;
        }
    }
    // ponytail: permutation indices change traversal order, not shapes; skipped.
    return space;
}

fn takeWidth(buf: []const u8, pos: *usize, w: u8) u64 {
    var value: u64 = 0;
    for (buf[pos.*..][0..w], 0..) |b, i| {
        const shift: u6 = @intCast(i * 8);
        value |= @as(u64, b) << shift;
    }
    pos.* += w;
    return value;
}

test "scalar decodes with no dimensions" {
    const ctx = testContext();
    const space = try decode(&[_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 }, ctx);
    try std.testing.expectEqual(Kind.scalar, space.kind);
    try std.testing.expectEqual(@as(u64, 1), try space.elementCount());
}

test "simple decodes dims and unlimited maxdims" {
    const ctx = testContext();
    const payload = [_]u8{
        1,    1,    1,    0,    0,    0,    0,    0,
        10,   0,    0,    0,    0,    0,    0,    0,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    };
    const space = try decode(&payload, ctx);
    try std.testing.expectEqual(Kind.simple, space.kind);
    try std.testing.expectEqual(@as(u8, 1), space.rank);
    try std.testing.expectEqual(@as(u64, 10), space.dims[0]);
    try std.testing.expect(space.maxdims[0] == null);
    try std.testing.expectEqual(@as(u64, 10), try space.elementCount());
}

test "null dataspace has no elements" {
    const ctx = testContext();
    const space = try decode(&[_]u8{ 2, 0, 0, 2, 0, 0, 0, 0 }, ctx);
    try std.testing.expectEqual(Kind.null, space.kind);
    try std.testing.expectEqual(@as(u64, 0), try space.elementCount());
}

test "dimension product overflow is an error" {
    const ctx = testContext();
    var payload = [_]u8{0} ** (8 + 2 * 8);
    payload[0] = 1;
    payload[1] = 2;
    std.mem.writeInt(u64, payload[8..][0..8], 9223372036854775808, .little);
    std.mem.writeInt(u64, payload[16..][0..8], 2, .little);
    const space = try decode(&payload, ctx);
    try std.testing.expectError(error.DataspaceOverflow, space.elementCount());
}

fn testContext() wire.Context {
    return .{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = std.math.maxInt(u64),
        .limits = .defaults,
    };
}
