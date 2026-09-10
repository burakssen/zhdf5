const std = @import("std");

pub const bytes = [_]u8{ 0x89, 'H', 'D', 'F', 0x0d, 0x0a, 0x1a, 0x0a };

pub fn matchesAt(source: anytype, offset: u64) !bool {
    const source_len = source.len();
    if (offset > source_len) return false;
    if (source_len - offset < bytes.len) return false;

    var actual: [bytes.len]u8 = undefined;
    try source.readAt(offset, &actual);
    return std.mem.eql(u8, &actual, &bytes);
}

/// Locates the HDF5 signature according to the format specification: first at
/// zero, then at 512 and successive powers of two.
pub fn find(source: anytype) !u64 {
    if (try matchesAt(source, 0)) return 0;

    var offset: u64 = 512;
    while (offset <= source.len()) {
        if (try matchesAt(source, offset)) return offset;
        if (offset > std.math.maxInt(u64) / 2) break;
        offset *= 2;
    }

    return error.Hdf5SignatureNotFound;
}

test "signature is found at zero" {
    const codec = @import("../codec/root.zig");
    const source = codec.SliceSource.init(&bytes);
    try std.testing.expectEqual(@as(u64, 0), try find(&source));
}

test "signature is found after a 512-byte user block" {
    const codec = @import("../codec/root.zig");

    var data = [_]u8{0} ** 520;
    @memcpy(data[512..520], &bytes);
    const source = codec.SliceSource.init(&data);
    try std.testing.expectEqual(@as(u64, 512), try find(&source));
}

test "signature search rejects arbitrary offsets" {
    const codec = @import("../codec/root.zig");

    var data = [_]u8{0} ** 1032;
    @memcpy(data[256..264], &bytes);
    const source = codec.SliceSource.init(&data);
    try std.testing.expectError(error.Hdf5SignatureNotFound, find(&source));
}
