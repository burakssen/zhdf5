const std = @import("std");
const common = @import("common.zig");

/// Creates a cursor-based binary writer over a random-access sink.
///
/// `Sink` must provide:
///
/// ```zig
/// pub fn writeAt(self: *Sink, offset: u64, bytes: []const u8) !void;
/// ```
pub fn Writer(comptime Sink: type) type {
    return struct {
        const Self = @This();

        sink: Sink,
        pos: u64 = 0,

        pub fn init(sink: Sink) Self {
            return .{ .sink = sink };
        }

        pub fn position(self: *const Self) u64 {
            return self.pos;
        }

        pub fn reset(self: *Self) void {
            self.pos = 0;
        }

        /// Repositions the cursor. No bytes are emitted until a later write.
        /// Sparse behavior, if any, is determined by the sink.
        pub fn seek(self: *Self, new_position: u64) void {
            self.pos = new_position;
        }

        /// Advances the cursor without emitting bytes. Prefer `reserve()` when
        /// the skipped range must be materialized as deterministic zero bytes.
        pub fn skip(self: *Self, amount: u64) !void {
            self.pos = try common.checkedAddPosition(self.pos, amount);
        }

        pub fn writeBytes(self: *Self, bytes: []const u8) !void {
            const next = try common.checkedAddPosition(self.pos, @intCast(bytes.len));
            try self.sink.writeAt(self.pos, bytes);
            self.pos = next;
        }

        pub fn writeByte(self: *Self, byte: u8) !void {
            try self.writeBytes(&.{byte});
        }

        pub fn patchBytes(self: *Self, offset: u64, bytes: []const u8) !void {
            try self.sink.writeAt(offset, bytes);
        }

        pub fn writeInt(self: *Self, comptime T: type, value: T, endian: std.builtin.Endian) !void {
            const byte_len = common.integerByteLen(T, "writeInt/patchInt");
            var bytes: [byte_len]u8 = undefined;
            std.mem.writeInt(T, &bytes, value, endian);
            try self.writeBytes(&bytes);
        }

        pub fn patchInt(
            self: *Self,
            offset: u64,
            comptime T: type,
            value: T,
            endian: std.builtin.Endian,
        ) !void {
            const byte_len = common.integerByteLen(T, "writeInt/patchInt");
            var bytes: [byte_len]u8 = undefined;
            std.mem.writeInt(T, &bytes, value, endian);
            try self.patchBytes(offset, &bytes);
        }

        pub fn writeFloat(self: *Self, comptime T: type, value: T, endian: std.builtin.Endian) !void {
            _ = common.floatByteLen(T, "writeFloat/patchFloat");
            const UInt = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits: UInt = @bitCast(value);
            try self.writeInt(UInt, bits, endian);
        }

        pub fn patchFloat(
            self: *Self,
            offset: u64,
            comptime T: type,
            value: T,
            endian: std.builtin.Endian,
        ) !void {
            _ = common.floatByteLen(T, "writeFloat/patchFloat");
            const UInt = std.meta.Int(.unsigned, @bitSizeOf(T));
            const bits: UInt = @bitCast(value);
            try self.patchInt(offset, UInt, bits, endian);
        }

        /// Writes an unsigned value using exactly `byte_width` bytes.
        /// Widths 1...8 are accepted and values that do not fit are rejected.
        pub fn writeVarUInt(
            self: *Self,
            value: u64,
            byte_width: u8,
            endian: std.builtin.Endian,
        ) !void {
            var bytes: [8]u8 = undefined;
            const encoded = try encodeVarUInt(value, byte_width, endian, &bytes);
            try self.writeBytes(encoded);
        }

        pub fn patchVarUInt(
            self: *Self,
            offset: u64,
            value: u64,
            byte_width: u8,
            endian: std.builtin.Endian,
        ) !void {
            var bytes: [8]u8 = undefined;
            const encoded = try encodeVarUInt(value, byte_width, endian, &bytes);
            try self.patchBytes(offset, encoded);
        }

        pub fn writeVarInt(
            self: *Self,
            value: i64,
            byte_width: u8,
            endian: std.builtin.Endian,
        ) !void {
            const raw = try encodeSignedValue(value, byte_width);
            var bytes: [8]u8 = undefined;
            const encoded = try encodeVarUInt(raw, byte_width, endian, &bytes);
            try self.writeBytes(encoded);
        }

        pub fn patchVarInt(
            self: *Self,
            offset: u64,
            value: i64,
            byte_width: u8,
            endian: std.builtin.Endian,
        ) !void {
            const raw = try encodeSignedValue(value, byte_width);
            var bytes: [8]u8 = undefined;
            const encoded = try encodeVarUInt(raw, byte_width, endian, &bytes);
            try self.patchBytes(offset, encoded);
        }

        /// Writes `count` copies of `byte` using bounded stack storage.
        pub fn writeRepeat(self: *Self, byte: u8, count: u64) !void {
            var scratch: [256]u8 = undefined;
            @memset(&scratch, byte);

            var remaining = count;
            while (remaining != 0) {
                const amount_u64 = @min(remaining, @as(u64, scratch.len));
                const amount: usize = @intCast(amount_u64);
                try self.writeBytes(scratch[0..amount]);
                remaining -= amount_u64;
            }
        }

        pub fn writeZeroes(self: *Self, count: u64) !void {
            try self.writeRepeat(0, count);
        }

        /// Materializes `count` zero bytes and returns the start offset so the
        /// range can be back-patched later.
        pub fn reserve(self: *Self, count: u64) !u64 {
            const offset = self.pos;
            try self.writeZeroes(count);
            return offset;
        }

        pub fn alignForward(self: *Self, alignment: u64) !void {
            try self.alignForwardWith(alignment, 0);
        }

        pub fn alignForwardWith(self: *Self, alignment: u64, fill: u8) !void {
            if (alignment == 0) return error.InvalidAlignment;

            const remainder = self.pos % alignment;
            if (remainder == 0) return;
            try self.writeRepeat(fill, alignment - remainder);
        }
    };
}

fn encodeVarUInt(
    value: u64,
    byte_width: u8,
    endian: std.builtin.Endian,
    storage: *[8]u8,
) ![]const u8 {
    if (byte_width == 0 or byte_width > 8) return error.InvalidByteWidth;

    if (byte_width < 8) {
        const bits: u6 = @intCast(byte_width * 8);
        const limit = @as(u64, 1) << bits;
        if (value >= limit) return error.IntegerDoesNotFit;
    }

    const count: usize = byte_width;
    switch (endian) {
        .little => {
            var current = value;
            for (storage[0..count]) |*byte| {
                byte.* = @truncate(current);
                current >>= 8;
            }
        },
        .big => {
            for (storage[0..count], 0..) |*byte, i| {
                const reverse_index = count - 1 - i;
                const shift: u6 = @intCast(reverse_index * 8);
                byte.* = @truncate(value >> shift);
            }
        },
    }

    return storage[0..count];
}

fn encodeSignedValue(value: i64, byte_width: u8) !u64 {
    if (byte_width == 0 or byte_width > 8) return error.InvalidByteWidth;
    if (byte_width == 8) return @bitCast(value);

    const bits: u6 = @intCast(byte_width * 8);
    const magnitude_bits: u6 = bits - 1;
    const max_value: i64 = (@as(i64, 1) << magnitude_bits) - 1;
    const min_value: i64 = -(@as(i64, 1) << magnitude_bits);
    if (value < min_value or value > max_value) return error.IntegerDoesNotFit;

    const raw: u64 = @bitCast(value);
    const mask = (@as(u64, 1) << bits) - 1;
    return raw & mask;
}

const SliceSink = @import("sink.zig").SliceSink;
const OwnedSink = @import("sink.zig").OwnedSink;
const CountingSink = @import("sink.zig").CountingSink;
const Reader = @import("reader.zig").Reader;
const SliceSource = @import("source.zig").SliceSource;

test "Writer writes fixed-width integers in both byte orders" {
    var storage: [6]u8 = undefined;
    var writer = Writer(SliceSink).init(SliceSink.init(&storage));

    try writer.writeInt(u16, 0x1234, .little);
    try writer.writeInt(u16, 0x1234, .big);
    try writer.writeInt(i16, -2, .little);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x34, 0x12, 0x12, 0x34, 0xfe, 0xff },
        writer.sink.written(),
    );
}

test "Writer reserve and patch support forward references" {
    var storage: [16]u8 = undefined;
    var writer = Writer(SliceSink).init(SliceSink.init(&storage));

    const length_offset = try writer.reserve(4);
    try writer.writeBytes("data");
    try writer.patchInt(length_offset, u32, 4, .little);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 4, 0, 0, 0, 'd', 'a', 't', 'a' },
        writer.sink.written(),
    );
    try std.testing.expectEqual(@as(u64, 8), writer.position());
}

test "Writer patching does not move the cursor" {
    var storage: [8]u8 = undefined;
    var writer = Writer(SliceSink).init(SliceSink.init(&storage));

    try writer.writeBytes(&.{ 1, 2, 3, 4 });
    try writer.patchBytes(1, &.{9});

    try std.testing.expectEqual(@as(u64, 4), writer.position());
    try std.testing.expectEqualSlices(u8, &.{ 1, 9, 3, 4 }, writer.sink.written());
}

test "Writer writes runtime-width unsigned integers" {
    var storage: [6]u8 = undefined;
    var writer = Writer(SliceSink).init(SliceSink.init(&storage));

    try writer.writeVarUInt(0x123456, 3, .little);
    try writer.writeVarUInt(0x123456, 3, .big);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x56, 0x34, 0x12, 0x12, 0x34, 0x56 },
        writer.sink.written(),
    );
}

test "Writer validates runtime-width integer ranges before writing" {
    var storage: [8]u8 = undefined;
    var writer = Writer(SliceSink).init(SliceSink.init(&storage));

    try std.testing.expectError(error.InvalidByteWidth, writer.writeVarUInt(1, 0, .little));
    try std.testing.expectError(error.InvalidByteWidth, writer.writeVarUInt(1, 9, .little));
    try std.testing.expectError(error.IntegerDoesNotFit, writer.writeVarUInt(256, 1, .little));
    try std.testing.expectEqual(@as(u64, 0), writer.position());
}

test "Writer writes signed runtime-width integers" {
    var storage: [6]u8 = undefined;
    var writer = Writer(SliceSink).init(SliceSink.init(&storage));

    try writer.writeVarInt(-2, 3, .little);
    try writer.writeVarInt(-2, 3, .big);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xfe, 0xff, 0xff, 0xff, 0xff, 0xfe },
        writer.sink.written(),
    );
}

test "Writer rejects signed values outside selected width" {
    var storage: [8]u8 = undefined;
    var writer = Writer(SliceSink).init(SliceSink.init(&storage));

    try std.testing.expectError(error.IntegerDoesNotFit, writer.writeVarInt(128, 1, .little));
    try std.testing.expectError(error.IntegerDoesNotFit, writer.writeVarInt(-129, 1, .little));
}

test "Writer alignment emits deterministic fill" {
    var storage: [16]u8 = undefined;
    var writer = Writer(SliceSink).init(SliceSink.init(&storage));

    try writer.writeBytes(&.{ 1, 2, 3 });
    try writer.alignForwardWith(8, 0xaa);

    try std.testing.expectEqual(@as(u64, 8), writer.position());
    try std.testing.expectEqualSlices(
        u8,
        &.{ 1, 2, 3, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa },
        writer.sink.written(),
    );

    try std.testing.expectError(error.InvalidAlignment, writer.alignForward(0));
}

test "OwnedSink writer can seek forward and creates zero-filled holes" {
    var writer = Writer(OwnedSink).init(OwnedSink.init(std.testing.allocator));
    defer writer.sink.deinit();

    writer.seek(4);
    try writer.writeByte(9);

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 9 }, writer.sink.bytes());
}

test "CountingSink supports exact two-pass sizing" {
    var counter = Writer(CountingSink).init(.{});
    try counter.writeInt(u32, 0x12345678, .little);
    try counter.writeZeroes(7);
    try counter.alignForward(8);

    try std.testing.expectEqual(@as(u64, 16), counter.sink.len());

    var storage: [16]u8 = undefined;
    var writer = Writer(SliceSink).init(SliceSink.init(&storage));
    try writer.writeInt(u32, 0x12345678, .little);
    try writer.writeZeroes(7);
    try writer.alignForward(8);

    try std.testing.expectEqual(counter.sink.len(), writer.sink.len());
}

test "Writer and Reader round-trip integers and floats" {
    var writer = Writer(OwnedSink).init(OwnedSink.init(std.testing.allocator));
    defer writer.sink.deinit();

    try writer.writeInt(u32, 0xdeadbeef, .little);
    try writer.writeVarUInt(0x123456, 3, .big);
    try writer.writeVarInt(-12345, 3, .little);
    try writer.writeFloat(f32, 1.5, .little);

    var reader = Reader(SliceSource).init(SliceSource.init(writer.sink.bytes()));
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), try reader.readInt(u32, .little));
    try std.testing.expectEqual(@as(u64, 0x123456), try reader.readVarUInt(3, .big));
    try std.testing.expectEqual(@as(i64, -12345), try reader.readVarInt(3, .little));
    try std.testing.expectEqual(@as(f32, 1.5), try reader.readFloat(f32, .little));
    try std.testing.expect(reader.isAtEnd());
}
