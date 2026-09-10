const std = @import("std");

fn rot(value: u32, comptime amount: u5) u32 {
    return std.math.rotl(u32, value, amount);
}

fn mix(a_ptr: *u32, b_ptr: *u32, c_ptr: *u32) void {
    var a = a_ptr.*;
    var b = b_ptr.*;
    var c = c_ptr.*;

    a -%= c;
    a ^= rot(c, 4);
    c +%= b;
    b -%= a;
    b ^= rot(a, 6);
    a +%= c;
    c -%= b;
    c ^= rot(b, 8);
    b +%= a;
    a -%= c;
    a ^= rot(c, 16);
    c +%= b;
    b -%= a;
    b ^= rot(a, 19);
    a +%= c;
    c -%= b;
    c ^= rot(b, 4);
    b +%= a;

    a_ptr.* = a;
    b_ptr.* = b;
    c_ptr.* = c;
}

fn final(a_ptr: *u32, b_ptr: *u32, c_ptr: *u32) void {
    var a = a_ptr.*;
    var b = b_ptr.*;
    var c = c_ptr.*;

    c ^= b;
    c -%= rot(b, 14);
    a ^= c;
    a -%= rot(c, 11);
    b ^= a;
    b -%= rot(a, 25);
    c ^= b;
    c -%= rot(b, 16);
    a ^= c;
    a -%= rot(c, 4);
    b ^= a;
    b -%= rot(a, 14);
    c ^= b;
    c -%= rot(b, 24);

    a_ptr.* = a;
    b_ptr.* = b;
    c_ptr.* = c;
}

fn readTailWord(bytes_in: []const u8) u32 {
    var value: u32 = 0;
    for (bytes_in, 0..) |byte, i| {
        const shift: u5 = @intCast(i * 8);
        value |= @as(u32, byte) << shift;
    }
    return value;
}

/// Jenkins lookup3 `hashlittle`, used by HDF5 metadata checksums.
pub fn lookup3(data: []const u8, initial_value: u32) u32 {
    var a: u32 = 0xdeadbeef +% @as(u32, @truncate(data.len)) +% initial_value;
    var b = a;
    var c = a;

    var index: usize = 0;
    while (data.len - index > 12) : (index += 12) {
        a +%= std.mem.readInt(u32, data[index..][0..4], .little);
        b +%= std.mem.readInt(u32, data[index + 4 ..][0..4], .little);
        c +%= std.mem.readInt(u32, data[index + 8 ..][0..4], .little);
        mix(&a, &b, &c);
    }

    return finishTail(a, b, c, data[index..]);
}

fn finishTail(a_in: u32, b_in: u32, c_in: u32, tail: []const u8) u32 {
    var a = a_in;
    var b = b_in;
    var c = c_in;
    if (tail.len == 0) return c;

    const a_len = @min(tail.len, 4);
    a +%= readTailWord(tail[0..a_len]);
    if (tail.len > 4) {
        const b_len = @min(tail.len - 4, 4);
        b +%= readTailWord(tail[4..][0..b_len]);
    }
    if (tail.len > 8) {
        c +%= readTailWord(tail[8..]);
    }

    final(&a, &b, &c);
    return c;
}

pub fn metadata(data: []const u8) u32 {
    return lookup3(data, 0);
}

/// Streaming lookup3 over a source range without buffering the whole range.
///
/// The total length feeds the initial state, so `init` takes it upfront;
/// feed arbitrary chunks via `update`, then `final`. Bit-identical to the
/// one-shot `metadata` over the same bytes.
pub const Stream = struct {
    a: u32,
    b: u32,
    c: u32,
    pending: [12]u8 = undefined,
    pending_len: usize = 0,

    pub fn init(total_len: u64) Stream {
        const a: u32 = 0xdeadbeef +% @as(u32, @truncate(total_len));
        return .{ .a = a, .b = a, .c = a };
    }

    pub fn update(self: *Stream, chunk: []const u8) void {
        var view = chunk;
        // Emit full blocks while more than a tail's worth remains overall.
        while (self.pending_len + view.len > 12) {
            if (self.pending_len > 0) {
                const take = 12 - self.pending_len;
                @memcpy(self.pending[self.pending_len..12], view[0..take]);
                self.block(self.pending[0..12]);
                view = view[take..];
                self.pending_len = 0;
            } else {
                self.block(view[0..12]);
                view = view[12..];
            }
        }
        @memcpy(self.pending[self.pending_len..][0..view.len], view);
        self.pending_len += view.len;
    }

    pub fn final(self: *Stream) u32 {
        return finishTail(self.a, self.b, self.c, self.pending[0..self.pending_len]);
    }

    fn block(self: *Stream, twelve: *const [12]u8) void {
        self.a +%= std.mem.readInt(u32, twelve[0..4], .little);
        self.b +%= std.mem.readInt(u32, twelve[4..8], .little);
        self.c +%= std.mem.readInt(u32, twelve[8..12], .little);
        mix(&self.a, &self.b, &self.c);
    }
};

/// Checksums `[offset, offset + len)` from any source with `readAt`,
/// reusing a caller scratch buffer instead of allocating.
pub fn range(source: anytype, offset: u64, len: u64, scratch: []u8) !u32 {
    if (scratch.len == 0 and len > 0) return error.EmptyScratch;
    var stream = Stream.init(len);
    var remaining = len;
    var off = offset;
    while (remaining > 0) {
        const chunk: usize = @intCast(@min(remaining, @as(u64, scratch.len)));
        try source.readAt(off, scratch[0..chunk]);
        stream.update(scratch[0..chunk]);
        off = std.math.add(u64, off, chunk) catch return error.PositionOverflow;
        remaining -= chunk;
    }
    return stream.final();
}

test "streaming range matches one-shot metadata at every split" {
    const codec = @import("../codec/root.zig");
    var data: [9000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 2654435761);

    const sizes = [_]usize{ 0, 1, 5, 11, 12, 13, 24, 25, 100, 1000, 9000 };
    const splits = [_]usize{ 1, 7, 12, 13, 64, 1024 };
    var scratch: [2048]u8 = undefined;
    for (sizes) |len| {
        const source = codec.SliceSource.init(data[0..len]);
        const expected = metadata(data[0..len]);
        for (splits) |split| {
            const got = try range(&source, 0, len, scratch[0..@min(split, scratch.len)]);
            try std.testing.expectEqual(expected, got);
        }
    }
    const empty_source = codec.SliceSource.init(&data);
    try std.testing.expectError(error.EmptyScratch, range(&empty_source, 0, 10, &.{}));
}

test "lookup3 matches an HDF5 superblock checksum" {
    // First 44 bytes of a real superblock-v3 fixture generated by libhdf5.
    const bytes = [_]u8{
        0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a,
        0x03, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x18, 0x08, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectEqual(@as(u32, 0xfd6cbc09), metadata(&bytes));
}
