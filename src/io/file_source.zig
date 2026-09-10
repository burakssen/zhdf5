const std = @import("std");

/// Phase-0 random-access source backed by Zig 0.16's `std.Io.File`.
///
/// The adapter owns neither `file` nor `io`; the caller is responsible for
/// closing the file after all readers using this source are finished.
pub const FileSource = struct {
    file: std.Io.File,
    io: std.Io,
    size: u64,

    pub fn init(file: std.Io.File, io: std.Io) !FileSource {
        return .{
            .file = file,
            .io = io,
            .size = try file.length(io),
        };
    }

    pub fn len(self: *const FileSource) u64 {
        return self.size;
    }

    pub fn readAt(self: *const FileSource, offset: u64, destination: []u8) !void {
        if (offset > self.size) return error.EndOfInput;
        const count: u64 = @intCast(destination.len);
        if (count > self.size - offset) return error.EndOfInput;

        const read = try self.file.readPositionalAll(self.io, destination, offset);
        if (read != destination.len) return error.EndOfInput;
    }
};
