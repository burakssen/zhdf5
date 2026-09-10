//! Data layout message (0x0008): where the array bytes live.
//!
//! Only version 3 is decoded: the class sits at byte 1 (0 compact,
//! 1 contiguous, 2 chunked). Compact data follows a u16 size at bytes
//! 2-3 with the bytes at offset 4; contiguous storage is the
//! offset-sized address at byte 2 followed by the length-sized size
//! (the size is located, not trusted: reads re-derive it from the
//! dataspace and datatype). Chunked layouts decode to an identifier;
//! reading them is a later phase.

const std = @import("std");
const address = @import("../wire/address.zig");
const codec = @import("../codec/root.zig");
const wire = @import("../wire/root.zig");

pub const Address = address.Address;

pub const Compact = struct {
    /// File offset of the first array byte.
    data_offset: u64,
    len: u64,
};

pub const Contiguous = struct {
    address: Address,
};

pub const Chunked = struct {
    version: u8,
};

pub const Layout = union(enum) {
    compact: Compact,
    contiguous: Contiguous,
    chunked: Chunked,
};

/// Decodes a layout message payload knowing its file offset (compact data
/// is located, not copied). Bounds-checked; trailing bytes ignored.
pub fn decode(payload: []const u8, payload_offset: u64, ctx: wire.Context) !Layout {
    if (payload.len < 2) return error.TruncatedLayout;
    const version = payload[0];
    const class = payload[1];
    switch (class) {
        0 => {
            if (version != 3) return error.UnsupportedLayoutVersion;
            if (payload.len < 4) return error.TruncatedLayout;
            const size = std.mem.readInt(u16, payload[2..4], .little);
            const data_offset = std.math.add(u64, payload_offset, 4) catch return error.CorruptLayout;
            const end = std.math.add(u64, data_offset, size) catch return error.CorruptLayout;
            if (end > ctx.eof) return error.TruncatedLayout;
            if (payload.len < 4 + size) return error.TruncatedLayout;
            return .{ .compact = .{ .data_offset = data_offset, .len = size } };
        },
        1 => {
            if (version != 3) return error.UnsupportedLayoutVersion;
            const ow = ctx.widths.offset;
            const lw = ctx.widths.length;
            if (ow == 0 or ow > 16 or lw == 0 or lw > 16) return error.UnsupportedLayout;
            if (payload.len < 2 + ow + lw) return error.TruncatedLayout;
            var dec = codec.sliceReader(payload[2..]);
            const addr = try wire.readAddress(&dec, ow);
            return .{ .contiguous = .{ .address = addr } };
        },
        2 => return .{ .chunked = .{ .version = version } },
        else => return error.UnsupportedLayoutClass,
    }
}

test "compact locates inline bytes" {
    const ctx = testContext();
    const payload = [_]u8{ 3, 0, 5, 0, 0, 1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0 };
    const layout = try decode(&payload, 1000, ctx);
    try std.testing.expectEqual(@as(u64, 1004), layout.compact.data_offset);
    try std.testing.expectEqual(@as(u64, 5), layout.compact.len);
}

test "contiguous extracts the storage address" {
    const ctx = testContext();
    const payload = [_]u8{ 3, 1, 0x28, 0, 0, 0, 0, 0, 0, 0, 0x28, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const layout = try decode(&payload, 0, ctx);
    try std.testing.expectEqual(@as(?u64, 0x28), layout.contiguous.address.raw());
}

test "chunked decodes to an identifier" {
    const ctx = testContext();
    const payload = [_]u8{ 5, 2, 0, 3, 1, 16, 16, 4, 3, 10, 0xbf, 1, 0, 0, 0, 0, 0, 0 };
    const layout = try decode(&payload, 0, ctx);
    try std.testing.expectEqual(@as(u8, 5), layout.chunked.version);
}

fn testContext() wire.Context {
    return .{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = std.math.maxInt(u64),
        .limits = .defaults,
    };
}
