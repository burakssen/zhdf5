//! High-level file handle: owns the OS file, its decoded superblock, and the
//! wire.Context every decoder needs. Depends downward on format/wire/io only.

const std = @import("std");
const format = @import("../format/root.zig");
const io = @import("../io/root.zig");
const wire = @import("../wire/root.zig");
const group_mod = @import("group.zig");
const object_mod = @import("object.zig");
const path_mod = @import("path.zig");

pub const OpenOptions = struct {
    limits: wire.Limits = .defaults,
};

pub const File = struct {
    io: std.Io,
    file: std.Io.File,
    source: io.FileSource,
    superblock: format.Superblock,
    ctx: wire.Context,

    pub fn open(io_: std.Io, path: []const u8, options: OpenOptions) !File {
        const file = try std.Io.Dir.cwd().openFile(io_, path, .{ .mode = .read_only });
        errdefer file.close(io_);

        var source = try io.FileSource.init(file, io_);
        const superblock = try format.decodeSuperblock(&source);
        const widths = wire.Widths{
            .offset = superblock.offset_size,
            .length = superblock.length_size,
        };
        try widths.validate();
        return .{
            .io = io_,
            .file = file,
            .source = source,
            .superblock = superblock,
            .ctx = .{
                .widths = widths,
                .base_address = try superblock.baseFileOffset(),
                .eof = source.len(),
                .limits = options.limits,
            },
        };
    }

    pub fn deinit(self: *File) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    /// Opens the object at an absolute path (`/`, `/foo/bar`).
    pub fn object(self: *File, path: []const u8, allocator: std.mem.Allocator) !object_mod.Object {
        return path_mod.lookup(self, path, allocator);
    }

    /// Opens the group at an absolute path; errors if it is not a group.
    pub fn group(self: *File, path: []const u8, allocator: std.mem.Allocator) !group_mod.Group {
        return group_mod.Group.fromObject(try self.object(path, allocator));
    }
};

test "file opens v0, v3, and user-block files" {
    // Integration: runs with the package root as cwd (zig build test).
    var v0 = try File.open(std.testing.io, "testdata/v0-symtab.h5", .{});
    defer v0.deinit();
    try std.testing.expectEqual(format.SuperblockVersion.v0, v0.superblock.version);
    try std.testing.expectEqual(@as(u64, 0), v0.ctx.base_address);
    try std.testing.expect(v0.ctx.eof > 0);

    var v3 = try File.open(std.testing.io, "testdata/v3-nested.h5", .{});
    defer v3.deinit();
    try std.testing.expectEqual(format.SuperblockVersion.v3, v3.superblock.version);
    try std.testing.expectEqual(@as(?bool, true), v3.superblock.checksumValid());

    var shifted = try File.open(std.testing.io, "testdata/v0-userblock.h5", .{});
    defer shifted.deinit();
    try std.testing.expectEqual(@as(u64, 512), shifted.superblock.signature_offset);
    try std.testing.expectEqual(@as(u64, 512), shifted.ctx.base_address);
}

test "file open rejects missing paths" {
    try std.testing.expectError(error.FileNotFound, File.open(std.testing.io, "testdata/does-not-exist.h5", .{}));
}
