//! Datatype message (0x0003): atomic numerics only (integers, IEEE floats).
//! Compound, string, enum, opaque, reference, array, and variable-length
//! types decode as explicit errors, not silent misreads.
//!
//! Layout per the format spec: class+version byte, 3 class bit-field bytes,
//! u32 size, then class properties. Fixed-point properties are bit
//! offset/precision plus reserved bytes; float properties add exponent and
//! mantissa geometry plus bias, which must match IEEE-754 exactly.

const std = @import("std");

pub const ByteOrder = enum {
    little,
    big,
};

pub const Integer = struct {
    size: u8,
    signed: bool,
    order: ByteOrder,
};

pub const Float = struct {
    size: u8,
    order: ByteOrder,
};

pub const Datatype = union(enum) {
    integer: Integer,
    float: Float,

    /// Storage width of one element.
    pub fn size(self: Datatype) u8 {
        return switch (self) {
            .integer => |i| i.size,
            .float => |f| f.size,
        };
    }
};

/// Decodes a datatype message payload (pure, bounds-checked).
pub fn decode(payload: []const u8) !Datatype {
    if (payload.len < 8) return error.TruncatedDatatype;
    const version = payload[0] >> 4;
    const class = payload[0] & 0x0f;
    if (version != 1) return error.UnsupportedDatatypeVersion;
    const bits: u32 = @as(u32, payload[1]) | (@as(u32, payload[2]) << 8) | (@as(u32, payload[3]) << 16);
    const order: ByteOrder = if (bits & 0x01 != 0) .big else .little;
    const size = std.mem.readInt(u32, payload[4..8], .little);

    switch (class) {
        0 => return decodeInteger(payload, bits, order, size),
        1 => return decodeFloat(payload, bits, order, size),
        else => return error.UnsupportedDatatype,
    }
}

fn decodeInteger(payload: []const u8, bits: u32, order: ByteOrder, size: u32) !Datatype {
    if (size != 1 and size != 2 and size != 4 and size != 8) return error.UnsupportedDatatype;
    if (bits & ~@as(u32, 0x09) != 0) return error.InvalidDatatypeBitField;
    if (payload.len < 16) return error.TruncatedDatatype;
    if (std.mem.readInt(u16, payload[8..10], .little) != 0) return error.UnsupportedDatatype;
    if (std.mem.readInt(u16, payload[10..12], .little) != size * 8) return error.UnsupportedDatatype;
    if (!std.mem.eql(u8, payload[12..16], &[_]u8{0} ** 4)) return error.InvalidReservedField;
    return .{ .integer = .{
        .size = @intCast(size),
        .signed = bits & 0x08 != 0,
        .order = order,
    } };
}

fn decodeFloat(payload: []const u8, bits: u32, order: ByteOrder, size: u32) !Datatype {
    const exp_size: u8, const mant_size: u8, const bias: u32 = switch (size) {
        4 => .{ 8, 23, 127 },
        8 => .{ 11, 52, 1023 },
        else => return error.UnsupportedDatatype,
    };
    const sign_at: u32 = size * 8 - 1;
    if (bits != (@as(u32, if (order == .big) 1 else 0) | (@as(u32, 2) << 4) | (sign_at << 8))) return error.UnsupportedDatatype;
    if (payload.len < 20) return error.TruncatedDatatype;
    if (std.mem.readInt(u16, payload[8..10], .little) != 0) return error.UnsupportedDatatype;
    if (std.mem.readInt(u16, payload[10..12], .little) != size * 8) return error.UnsupportedDatatype;
    if (payload[12] != size * 8 - 1 - exp_size) return error.UnsupportedDatatype;
    if (payload[13] != exp_size) return error.UnsupportedDatatype;
    if (payload[14] != 0) return error.UnsupportedDatatype;
    if (payload[15] != mant_size) return error.UnsupportedDatatype;
    if (std.mem.readInt(u32, payload[16..20], .little) != bias) return error.UnsupportedDatatype;
    return .{ .float = .{ .size = @intCast(size), .order = order } };
}

test "little-endian i32 decodes" {
    const dt = try decode(&[_]u8{ 0x10, 0x08, 0, 0, 4, 0, 0, 0, 0, 0, 0x20, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(Datatype{ .integer = .{ .size = 4, .signed = true, .order = .little } }, dt);
    try std.testing.expectEqual(@as(u8, 4), dt.size());
}

test "unsigned u8 and big-endian i32 decode" {
    const u8t = try decode(&[_]u8{ 0x10, 0, 0, 0, 1, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(false, u8t.integer.signed);
    const bet = try decode(&[_]u8{ 0x10, 0x09, 0, 0, 4, 0, 0, 0, 0, 0, 0x20, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(ByteOrder.big, bet.integer.order);
    try std.testing.expect(bet.integer.signed);
}

test "ieee f32 and f64 decode" {
    const f32t = try decode(&[_]u8{
        0x11, 0x20, 0x1f, 0, 4,  0, 0, 0,
        0,    0,    0x20, 0, 23, 8, 0, 23,
        0x7f, 0,    0,    0, 0,  0, 0, 0,
    });
    try std.testing.expectEqual(@as(u8, 4), f32t.size());
    const f64t = try decode(&[_]u8{
        0x11, 0x20, 0x3f, 0, 8,  0,  0, 0,
        0,    0,    0x40, 0, 52, 11, 0, 52,
        0xff, 0x03, 0,    0, 0,  0,  0, 0,
    });
    try std.testing.expectEqual(Datatype{ .float = .{ .size = 8, .order = .little } }, f64t);
}

test "exotic classes and versions are explicit errors" {
    try std.testing.expectError(error.UnsupportedDatatype, decode(&[_]u8{ 0x13, 0, 0, 0, 1, 0, 0, 0 }));
    try std.testing.expectError(error.UnsupportedDatatypeVersion, decode(&[_]u8{ 0x20, 0x08, 0, 0, 4, 0, 0, 0 }));
    try std.testing.expectError(error.UnsupportedDatatype, decode(&[_]u8{ 0x10, 0x08, 0, 0, 3, 0, 0, 0 }));
    // i32 with nonzero bit offset is not a plain integer.
    try std.testing.expectError(
        error.UnsupportedDatatype,
        decode(&[_]u8{ 0x10, 0x08, 0, 0, 4, 0, 0, 0, 1, 0, 0x20, 0, 0, 0, 0, 0 }),
    );
}
