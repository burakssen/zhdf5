const std = @import("std");

/// Random-access sink backed by a caller-owned fixed-size byte slice.
pub const SliceSink = struct {
    data: []u8,
    high_water: usize = 0,

    pub fn init(data: []u8) SliceSink {
        return .{ .data = data };
    }

    pub fn capacity(self: *const SliceSink) u64 {
        return @intCast(self.data.len);
    }

    pub fn len(self: *const SliceSink) u64 {
        return @intCast(self.high_water);
    }

    pub fn writeAt(self: *SliceSink, offset: u64, bytes: []const u8) !void {
        if (offset > self.capacity()) return error.EndOfOutput;

        const start: usize = @intCast(offset);
        if (bytes.len > self.data.len - start) return error.EndOfOutput;
        if (bytes.len == 0) return;

        @memcpy(self.data[start..][0..bytes.len], bytes);
        self.high_water = @max(self.high_water, start + bytes.len);
    }

    pub fn written(self: *const SliceSink) []const u8 {
        return self.data[0..self.high_water];
    }
};

/// Allocator-backed random-access sink.
///
/// The sink grows geometrically. If a write starts beyond the current logical
/// end, the gap is deterministically filled with zero bytes. `bytes()` remains
/// valid until the next mutating operation or `deinit()`.
pub const OwnedSink = struct {
    allocator: std.mem.Allocator,
    storage: ?[]u8 = null,
    logical_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) OwnedSink {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OwnedSink) void {
        if (self.storage) |storage| self.allocator.free(storage);
        self.storage = null;
        self.logical_len = 0;
    }

    pub fn len(self: *const OwnedSink) u64 {
        return @intCast(self.logical_len);
    }

    pub fn capacity(self: *const OwnedSink) usize {
        return if (self.storage) |storage| storage.len else 0;
    }

    pub fn bytes(self: *const OwnedSink) []const u8 {
        if (self.storage) |storage| return storage[0..self.logical_len];
        return &.{};
    }

    pub fn clearRetainingCapacity(self: *OwnedSink) void {
        self.logical_len = 0;
    }

    pub fn writeAt(self: *OwnedSink, offset: u64, _bytes: []const u8) !void {
        if (_bytes.len == 0) return;
        if (offset > @as(u64, std.math.maxInt(usize))) return error.OutputTooLarge;
        const start: usize = @intCast(offset);

        if (_bytes.len > std.math.maxInt(usize) - start) return error.OutputTooLarge;
        const end = start + _bytes.len;

        try self.ensureCapacity(end);

        if (self.storage) |storage| {
            if (start > self.logical_len) {
                @memset(storage[self.logical_len..start], 0);
            }
            @memcpy(storage[start..end], _bytes);
        } else if (end != 0) {
            unreachable;
        }

        self.logical_len = @max(self.logical_len, end);
    }

    fn ensureCapacity(self: *OwnedSink, needed: usize) !void {
        if (needed <= self.capacity()) return;

        var new_capacity: usize = if (self.capacity() == 0) 64 else self.capacity();
        while (new_capacity < needed) {
            if (new_capacity > std.math.maxInt(usize) / 2) {
                new_capacity = needed;
                break;
            }
            new_capacity *= 2;
        }

        if (self.storage) |storage| {
            self.storage = try self.allocator.realloc(storage, new_capacity);
        } else {
            self.storage = try self.allocator.alloc(u8, new_capacity);
        }
    }
};

/// Sink for a first sizing pass. It performs no allocation and stores no bytes.
/// Random-access writes are accounted for using their furthest end position.
pub const CountingSink = struct {
    logical_len: u64 = 0,

    pub fn len(self: *const CountingSink) u64 {
        return self.logical_len;
    }

    pub fn writeAt(self: *CountingSink, offset: u64, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const count: u64 = @intCast(bytes.len);
        if (count > std.math.maxInt(u64) - offset) return error.PositionOverflow;
        self.logical_len = @max(self.logical_len, offset + count);
    }
};

test "SliceSink writes and tracks high-water mark" {
    var storage = [_]u8{0} ** 8;
    var sink = SliceSink.init(&storage);

    try sink.writeAt(2, &.{ 7, 8, 9 });
    try std.testing.expectEqual(@as(u64, 5), sink.len());
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 7, 8, 9 }, sink.written());

    try sink.writeAt(0, &.{1});
    try std.testing.expectEqual(@as(u64, 5), sink.len());
}

test "SliceSink rejects writes past capacity" {
    var storage: [4]u8 = undefined;
    var sink = SliceSink.init(&storage);

    try std.testing.expectError(error.EndOfOutput, sink.writeAt(3, &.{ 1, 2 }));
    try std.testing.expectError(error.EndOfOutput, sink.writeAt(5, &.{}));
}

test "OwnedSink grows, zero-fills gaps, and overwrites" {
    var sink = OwnedSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.writeAt(3, &.{ 4, 5 });
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 4, 5 }, sink.bytes());

    try sink.writeAt(1, &.{9});
    try std.testing.expectEqualSlices(u8, &.{ 0, 9, 0, 4, 5 }, sink.bytes());
}

test "OwnedSink clear retains its allocation" {
    var sink = OwnedSink.init(std.testing.allocator);
    defer sink.deinit();

    try sink.writeAt(0, &.{ 1, 2, 3 });
    const previous_capacity = sink.capacity();
    sink.clearRetainingCapacity();

    try std.testing.expectEqual(@as(u64, 0), sink.len());
    try std.testing.expectEqual(previous_capacity, sink.capacity());
}

test "CountingSink tracks random-access extent" {
    var sink: CountingSink = .{};
    try sink.writeAt(100, &.{ 1, 2, 3 });
    try sink.writeAt(20, &.{ 1, 2 });
    try std.testing.expectEqual(@as(u64, 103), sink.len());
}
