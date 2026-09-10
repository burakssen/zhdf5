const std = @import("std");

/// HDF5 file address. The format encodes an undefined address as all one bits
/// for the configured offset width.
//
// FileAddress is the forward name; Address stays until the old format
// modules finish migrating to wire.Context.
pub const FileAddress = Address;

pub const Address = union(enum) {
    value: u64,
    undefined_address,

    pub fn isUndefined(self: Address) bool {
        return switch (self) {
            .undefined_address => true,
            .value => false,
        };
    }

    pub fn raw(self: Address) ?u64 {
        return switch (self) {
            .undefined_address => null,
            .value => |value| value,
        };
    }

    /// Resolves a base-relative HDF5 address into a physical byte offset.
    pub fn resolve(self: Address, base_address: u64) !u64 {
        const relative = self.raw() orelse return error.UndefinedAddress;
        return std.math.add(u64, base_address, relative);
    }
};

/// Reads a little-endian HDF5 unsigned integer with a runtime byte width.
///
/// HDF5 can use widths larger than the host's u64 address space. Widths up to
/// 16 bytes are accepted here as long as the encoded value actually fits in
/// u64. This lets us read files created with 16-byte offset/length fields while
/// still making the host-side limitation explicit.
pub fn readUnsigned(reader: anytype, byte_width: u8) !u64 {
    if (byte_width == 0 or byte_width > 16) return error.UnsupportedIntegerWidth;

    var bytes: [16]u8 = undefined;
    try reader.readInto(bytes[0..byte_width]);

    const low_count: usize = @min(@as(usize, byte_width), 8);
    var value: u64 = 0;
    for (bytes[0..low_count], 0..) |byte, i| {
        const shift: u6 = @intCast(i * 8);
        value |= @as(u64, byte) << shift;
    }

    if (byte_width > 8) {
        for (bytes[8..byte_width]) |byte| {
            if (byte != 0) return error.IntegerTooLarge;
        }
    }

    return value;
}

/// Reads an HDF5 address and recognizes the width-specific all-ones sentinel.
pub fn readAddress(reader: anytype, byte_width: u8) !Address {
    if (byte_width == 0 or byte_width > 16) return error.UnsupportedOffsetSize;

    var bytes: [16]u8 = undefined;
    try reader.readInto(bytes[0..byte_width]);

    var all_ones = true;
    for (bytes[0..byte_width]) |byte| {
        if (byte != 0xff) {
            all_ones = false;
            break;
        }
    }
    if (all_ones) return .undefined_address;

    const low_count: usize = @min(@as(usize, byte_width), 8);
    var value: u64 = 0;
    for (bytes[0..low_count], 0..) |byte, i| {
        const shift: u6 = @intCast(i * 8);
        value |= @as(u64, byte) << shift;
    }

    if (byte_width > 8) {
        for (bytes[8..byte_width]) |byte| {
            if (byte != 0) return error.AddressTooLarge;
        }
    }

    return .{ .value = value };
}

pub fn readLength(reader: anytype, byte_width: u8) !u64 {
    if (byte_width == 0 or byte_width > 16) return error.UnsupportedLengthSize;
    return readUnsigned(reader, byte_width) catch |err| switch (err) {
        error.UnsupportedIntegerWidth => error.UnsupportedLengthSize,
        error.IntegerTooLarge => error.LengthTooLarge,
        else => return err,
    };
}

test "address decodes defined and undefined values" {
    const codec = @import("../codec/root.zig");

    var reader = codec.sliceReader(&.{ 0x34, 0x12, 0xff, 0xff });
    const defined = try readAddress(&reader, 2);
    try std.testing.expectEqual(@as(?u64, 0x1234), defined.raw());

    const missing = try readAddress(&reader, 2);
    try std.testing.expect(missing.isUndefined());
}

test "16-byte fields are supported when the value fits u64" {
    const codec = @import("../codec/root.zig");

    const bytes = [_]u8{
        0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0,
        0,    0,    0,    0,    0, 0, 0, 0,
    };
    var reader = codec.sliceReader(&bytes);
    try std.testing.expectEqual(@as(u64, 0x12345678), try readLength(&reader, 16));
}

test "16-byte fields reject values beyond u64" {
    const codec = @import("../codec/root.zig");

    const bytes = [_]u8{
        0, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 0, 0, 0, 0, 0, 0,
    };
    var reader = codec.sliceReader(&bytes);
    try std.testing.expectError(error.AddressTooLarge, readAddress(&reader, 16));
}
