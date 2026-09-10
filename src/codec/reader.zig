const std = @import("std");
const common = @import("common.zig");

/// Creates a cursor-based binary reader over a random-access source.
///
/// `Source` must provide:
///
/// ```zig
/// pub fn len(self: *const Source) u64;
/// pub fn readAt(self: *const Source, offset: u64, destination: []u8) !void;
/// ```
///
/// A source may additionally provide:
///
/// ```zig
/// pub fn viewAt(self: *const Source, offset: u64, count: usize) ![]const u8;
/// ```
///
/// which enables zero-copy `view()` calls.
pub fn Reader(comptime Source: type) type {
    return struct {
        const Self = @This();

        source: Source,
        pos: u64 = 0,

        pub fn init(source: Source) Self {
            return .{ .source = source };
        }

        pub fn position(self: *const Self) u64 {
            return self.pos;
        }

        pub fn len(self: *const Self) u64 {
            return self.source.len();
        }

        pub fn remaining(self: *const Self) u64 {
            const size = self.len();
            return if (self.pos <= size) size - self.pos else 0;
        }

        pub fn isAtEnd(self: *const Self) bool {
            return self.pos == self.len();
        }

        pub fn reset(self: *Self) void {
            self.pos = 0;
        }

        pub fn seek(self: *Self, new_position: u64) !void {
            if (new_position > self.len()) return error.EndOfInput;
            self.pos = new_position;
        }

        pub fn skip(self: *Self, amount: u64) !void {
            const target = try common.checkedAddPosition(self.pos, amount);
            try self.seek(target);
        }

        pub fn alignForward(self: *Self, alignment: u64) !void {
            if (alignment == 0) return error.InvalidAlignment;

            const remainder = self.pos % alignment;
            if (remainder == 0) return;
            try self.skip(alignment - remainder);
        }

        /// Reads exactly `destination.len` bytes and advances the cursor only
        /// after the source has successfully supplied the whole range.
        pub fn readInto(self: *Self, destination: []u8) !void {
            const next = try common.checkedAddPosition(self.pos, @intCast(destination.len));
            try self.source.readAt(self.pos, destination);
            self.pos = next;
        }

        /// Reads exactly `destination.len` bytes without changing the cursor.
        pub fn readAt(self: *const Self, offset: u64, destination: []u8) !void {
            try self.source.readAt(offset, destination);
        }

        /// Returns a zero-copy view and advances the cursor. This method exists
        /// for every reader type but may only be called when `Source` provides
        /// `viewAt`.
        pub fn view(self: *Self, count: usize) ![]const u8 {
            if (comptime !@hasDecl(Source, "viewAt")) {
                @compileError("Reader.view requires Source.viewAt");
            }

            const next = try common.checkedAddPosition(self.pos, @intCast(count));
            const bytes = try self.source.viewAt(self.pos, count);
            self.pos = next;
            return bytes;
        }

        /// Returns a zero-copy view without changing the cursor.
        pub fn viewAt(self: *const Self, offset: u64, count: usize) ![]const u8 {
            if (comptime !@hasDecl(Source, "viewAt")) {
                @compileError("Reader.viewAt requires Source.viewAt");
            }
            return self.source.viewAt(offset, count);
        }

        pub fn readByte(self: *Self) !u8 {
            var byte: [1]u8 = undefined;
            try self.readInto(&byte);
            return byte[0];
        }

        pub fn peekByte(self: *const Self) !u8 {
            var byte: [1]u8 = undefined;
            try self.readAt(self.pos, &byte);
            return byte[0];
        }

        pub fn readInt(self: *Self, comptime T: type, endian: std.builtin.Endian) !T {
            const byte_len = common.integerByteLen(T, "readInt/peekInt/readIntAt");
            var bytes: [byte_len]u8 = undefined;
            try self.readInto(&bytes);
            return std.mem.readInt(T, &bytes, endian);
        }

        pub fn peekInt(self: *const Self, comptime T: type, endian: std.builtin.Endian) !T {
            return self.readIntAt(self.pos, T, endian);
        }

        pub fn readIntAt(
            self: *const Self,
            offset: u64,
            comptime T: type,
            endian: std.builtin.Endian,
        ) !T {
            const byte_len = common.integerByteLen(T, "readInt/peekInt/readIntAt");
            var bytes: [byte_len]u8 = undefined;
            try self.readAt(offset, &bytes);
            return std.mem.readInt(T, &bytes, endian);
        }

        pub fn readFloat(self: *Self, comptime T: type, endian: std.builtin.Endian) !T {
            _ = common.floatByteLen(T, "readFloat/peekFloat/readFloatAt");
            const UInt = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits = try self.readInt(UInt, endian);
            return @bitCast(bits);
        }

        pub fn peekFloat(self: *const Self, comptime T: type, endian: std.builtin.Endian) !T {
            return self.readFloatAt(self.pos, T, endian);
        }

        pub fn readFloatAt(
            self: *const Self,
            offset: u64,
            comptime T: type,
            endian: std.builtin.Endian,
        ) !T {
            _ = common.floatByteLen(T, "readFloat/peekFloat/readFloatAt");
            const UInt = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits = try self.readIntAt(offset, UInt, endian);
            return @bitCast(bits);
        }

        /// Reads an unsigned integer whose encoded byte width is known only at
        /// runtime. Widths 1...8 are supported; the result is widened to u64.
        pub fn readVarUInt(self: *Self, byte_width: u8, endian: std.builtin.Endian) !u64 {
            var bytes: [8]u8 = undefined;
            try self.readVarBytes(byte_width, &bytes);
            return decodeVarUInt(bytes[0..byte_width], endian);
        }

        pub fn peekVarUInt(self: *const Self, byte_width: u8, endian: std.builtin.Endian) !u64 {
            return self.readVarUIntAt(self.pos, byte_width, endian);
        }

        pub fn readVarUIntAt(
            self: *const Self,
            offset: u64,
            byte_width: u8,
            endian: std.builtin.Endian,
        ) !u64 {
            if (byte_width == 0 or byte_width > 8) return error.InvalidByteWidth;
            var bytes: [8]u8 = undefined;
            try self.readAt(offset, bytes[0..byte_width]);
            return decodeVarUInt(bytes[0..byte_width], endian);
        }

        /// Signed counterpart to `readVarUInt`, with two's-complement sign
        /// extension into i64.
        pub fn readVarInt(self: *Self, byte_width: u8, endian: std.builtin.Endian) !i64 {
            const raw = try self.readVarUInt(byte_width, endian);
            return signExtend(raw, byte_width);
        }

        pub fn peekVarInt(self: *const Self, byte_width: u8, endian: std.builtin.Endian) !i64 {
            return self.readVarIntAt(self.pos, byte_width, endian);
        }

        pub fn readVarIntAt(
            self: *const Self,
            offset: u64,
            byte_width: u8,
            endian: std.builtin.Endian,
        ) !i64 {
            const raw = try self.readVarUIntAt(offset, byte_width, endian);
            return signExtend(raw, byte_width);
        }

        /// Verifies a byte sequence at the current cursor. The operation is
        /// atomic with respect to the cursor: a mismatch or source error leaves
        /// the position unchanged.
        pub fn expectBytes(self: *Self, expected: []const u8) !void {
            const next = try common.checkedAddPosition(self.pos, @intCast(expected.len));
            var scratch: [256]u8 = undefined;
            var checked: usize = 0;

            while (checked < expected.len) {
                const amount = @min(scratch.len, expected.len - checked);
                const offset = try common.checkedAddPosition(self.pos, @intCast(checked));
                try self.readAt(offset, scratch[0..amount]);

                if (!std.mem.eql(u8, scratch[0..amount], expected[checked..][0..amount])) {
                    return error.UnexpectedBytes;
                }
                checked += amount;
            }

            self.pos = next;
        }

        fn readVarBytes(self: *Self, byte_width: u8, storage: *[8]u8) !void {
            if (byte_width == 0 or byte_width > 8) return error.InvalidByteWidth;
            try self.readInto(storage[0..byte_width]);
        }
    };
}

fn decodeVarUInt(bytes: []const u8, endian: std.builtin.Endian) u64 {
    var value: u64 = 0;

    switch (endian) {
        .little => {
            for (bytes, 0..) |byte, i| {
                const shift: u6 = @intCast(i * 8);
                value |= @as(u64, byte) << shift;
            }
        },
        .big => {
            for (bytes) |byte| {
                value = (value << 8) | byte;
            }
        },
    }

    return value;
}

fn signExtend(raw: u64, byte_width: u8) i64 {
    if (byte_width == 8) return @bitCast(raw);

    const bits: u6 = @intCast(byte_width * 8);
    const sign_shift: u6 = bits - 1;
    const sign_bit = @as(u64, 1) << sign_shift;

    if ((raw & sign_bit) == 0) return @intCast(raw);

    const low_mask = (@as(u64, 1) << bits) - 1;
    return @bitCast(raw | ~low_mask);
}

const SliceSource = @import("source.zig").SliceSource;

fn testReader(data: []const u8) Reader(SliceSource) {
    return Reader(SliceSource).init(SliceSource.init(data));
}

test "Reader cursor, seek, skip, remaining, and reset" {
    var reader = testReader(&.{ 1, 2, 3, 4, 5 });

    try std.testing.expectEqual(@as(u64, 5), reader.remaining());
    try std.testing.expectEqual(@as(u8, 1), try reader.readByte());
    try reader.skip(2);
    try std.testing.expectEqual(@as(u64, 3), reader.position());
    try std.testing.expectEqual(@as(u8, 4), try reader.readByte());

    try reader.seek(1);
    try std.testing.expectEqual(@as(u8, 2), try reader.peekByte());
    try std.testing.expectEqual(@as(u64, 1), reader.position());

    reader.reset();
    try std.testing.expectEqual(@as(u64, 0), reader.position());
}

test "Reader failed reads do not advance cursor" {
    var reader = testReader(&.{ 1, 2, 3 });
    var out: [4]u8 = undefined;

    try std.testing.expectError(error.EndOfInput, reader.readInto(&out));
    try std.testing.expectEqual(@as(u64, 0), reader.position());
}

test "Reader zero-copy view advances only on success" {
    const data = [_]u8{ 10, 20, 30, 40 };
    var reader = testReader(&data);

    const view = try reader.view(2);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20 }, view);
    try std.testing.expect(@intFromPtr(view.ptr) == @intFromPtr(&data[0]));
    try std.testing.expectEqual(@as(u64, 2), reader.position());

    try std.testing.expectError(error.EndOfInput, reader.view(3));
    try std.testing.expectEqual(@as(u64, 2), reader.position());
}

test "Reader reads fixed-width integers in both byte orders" {
    const data = [_]u8{
        0x34, 0x12,
        0x12, 0x34,
        0xfe, 0xff,
    };
    var reader = testReader(&data);

    try std.testing.expectEqual(@as(u16, 0x1234), try reader.readInt(u16, .little));
    try std.testing.expectEqual(@as(u16, 0x1234), try reader.readInt(u16, .big));
    try std.testing.expectEqual(@as(i16, -2), try reader.readInt(i16, .little));
}

test "Reader peek and positional reads do not move the cursor" {
    var reader = testReader(&.{ 0x78, 0x56, 0x34, 0x12 });

    try std.testing.expectEqual(@as(u32, 0x12345678), try reader.peekInt(u32, .little));
    try std.testing.expectEqual(@as(u64, 0), reader.position());
    try std.testing.expectEqual(@as(u16, 0x3412), try reader.readIntAt(2, u16, .big));
    try std.testing.expectEqual(@as(u64, 0), reader.position());
}

test "Reader reads variable-width unsigned integers" {
    var little = testReader(&.{ 0x56, 0x34, 0x12 });
    try std.testing.expectEqual(@as(u64, 0x123456), try little.readVarUInt(3, .little));

    var big = testReader(&.{ 0x12, 0x34, 0x56 });
    try std.testing.expectEqual(@as(u64, 0x123456), try big.readVarUInt(3, .big));
}

test "Reader reads variable-width signed integers" {
    var reader = testReader(&.{ 0xfe, 0xff, 0xff });
    try std.testing.expectEqual(@as(i64, -2), try reader.readVarInt(3, .little));
}

test "Reader rejects invalid runtime integer widths without moving" {
    var reader = testReader(&.{ 1, 2, 3 });

    try std.testing.expectError(error.InvalidByteWidth, reader.readVarUInt(0, .little));
    try std.testing.expectError(error.InvalidByteWidth, reader.readVarUInt(9, .little));
    try std.testing.expectEqual(@as(u64, 0), reader.position());
}

test "Reader aligns to arbitrary positive boundaries" {
    var reader = testReader(&([_]u8{0} ** 16));

    try reader.skip(3);
    try reader.alignForward(4);
    try std.testing.expectEqual(@as(u64, 4), reader.position());

    try reader.alignForward(3);
    try std.testing.expectEqual(@as(u64, 6), reader.position());

    try std.testing.expectError(error.InvalidAlignment, reader.alignForward(0));
}

test "Reader expectBytes is atomic on mismatch" {
    var reader = testReader("HDF5-data");

    try reader.expectBytes("HDF5");
    try std.testing.expectEqual(@as(u64, 4), reader.position());

    try std.testing.expectError(error.UnexpectedBytes, reader.expectBytes("oops"));
    try std.testing.expectEqual(@as(u64, 4), reader.position());
}

test "Reader reads floats by their encoded bit pattern" {
    var reader = testReader(&.{ 0x00, 0x00, 0xc0, 0x3f });
    try std.testing.expectEqual(@as(f32, 1.5), try reader.readFloat(f32, .little));
}
