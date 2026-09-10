const std = @import("std");

/// Random-access read-only source backed by a byte slice.
///
/// This type establishes the source contract expected by `Reader(Source)`:
///
/// - `len() u64`
/// - `readAt(offset, destination) !void`
///
/// Sources may additionally expose `viewAt(offset, len) ![]const u8` to enable
/// zero-copy `Reader.view()` calls. File-backed sources generally won't expose
/// `viewAt`; memory-mapped or slice-backed sources naturally can.
pub const SliceSource = struct {
    data: []const u8,

    pub fn init(data: []const u8) SliceSource {
        return .{ .data = data };
    }

    pub fn len(self: *const SliceSource) u64 {
        return @intCast(self.data.len);
    }

    pub fn readAt(self: *const SliceSource, offset: u64, destination: []u8) !void {
        if (offset > self.len()) return error.EndOfInput;

        const start: usize = @intCast(offset);
        if (destination.len > self.data.len - start) return error.EndOfInput;

        @memcpy(destination, self.data[start..][0..destination.len]);
    }

    pub fn viewAt(self: *const SliceSource, offset: u64, count: usize) ![]const u8 {
        if (offset > self.len()) return error.EndOfInput;

        const start: usize = @intCast(offset);
        if (count > self.data.len - start) return error.EndOfInput;

        return self.data[start..][0..count];
    }
};

test "SliceSource reads exact ranges" {
    const source = SliceSource.init(&.{ 10, 20, 30, 40, 50 });

    var out: [3]u8 = undefined;
    try source.readAt(1, &out);
    try std.testing.expectEqualSlices(u8, &.{ 20, 30, 40 }, &out);
}

test "SliceSource accepts an empty read at EOF" {
    const source = SliceSource.init(&.{ 1, 2, 3 });
    var out: [0]u8 = .{};
    try source.readAt(3, &out);
}

test "SliceSource rejects reads past EOF" {
    const source = SliceSource.init(&.{ 1, 2, 3 });

    var out: [2]u8 = undefined;
    try std.testing.expectError(error.EndOfInput, source.readAt(2, &out));
    try std.testing.expectError(error.EndOfInput, source.readAt(4, out[0..0]));
}

test "SliceSource exposes zero-copy views" {
    const bytes = [_]u8{ 1, 2, 3, 4 };
    const source = SliceSource.init(&bytes);

    const view = try source.viewAt(1, 2);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, view);
    try std.testing.expect(@intFromPtr(view.ptr) == @intFromPtr(&bytes[1]));
}
