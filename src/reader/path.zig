//! Absolute HDF5 path traversal: component-by-component group descent
//! following hard links only. Relative paths and empty components are
//! rejected; soft/external/user links are explicit errors, not detours.

const std = @import("std");
const file_mod = @import("file.zig");
const group_mod = @import("group.zig");
const object_mod = @import("object.zig");

/// Resolves an absolute path (`/`, `/foo`, `/foo/bar`) to its object.
pub fn lookup(file: *file_mod.File, path: []const u8, allocator: std.mem.Allocator) !object_mod.Object {
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;
    var current = (try group_mod.Group.root(file)).object;
    if (std.mem.eql(u8, path, "/")) return current;

    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |part| {
        if (part.len == 0) return error.InvalidPath;
        var parent = try group_mod.Group.fromObject(current);
        var found = try parent.get(part, allocator);
        defer {
            if (found) |*e| e.deinit(allocator);
        }
        const entry = found orelse return error.LinkNotFound;
        current = switch (entry.kind) {
            .hard => try object_mod.Object.open(file, entry.object_header),
            .soft => return error.SoftLinkUnsupported,
            .external => return error.ExternalLinkUnsupported,
            .user_defined => return error.UserDefinedLinkUnsupported,
        };
    }
    return current;
}

test "lookup resolves nested groups and rejects bad paths" {
    var file = try file_mod.File.open(std.testing.io, "testdata/v3-nested.h5", .{});
    defer file.deinit();
    const alloc = std.testing.allocator;

    const root_obj = try lookup(&file, "/", alloc);
    try std.testing.expectEqual(object_mod.Kind.group, root_obj.kind());
    const run42 = try lookup(&file, "/run42", alloc);
    try std.testing.expectEqual(object_mod.Kind.group, run42.kind());
    // ponytail: dataset discrimination lands with the message ranges.
    const voltage = try lookup(&file, "/run42/voltage", alloc);
    try std.testing.expectEqual(object_mod.Kind.unknown, voltage.kind());

    try std.testing.expectError(error.LinkNotFound, lookup(&file, "/nope", alloc));
    try std.testing.expectError(error.LinkNotFound, lookup(&file, "/run42/nope", alloc));
    try std.testing.expectError(error.InvalidPath, lookup(&file, "", alloc));
    try std.testing.expectError(error.InvalidPath, lookup(&file, "run42", alloc));
    try std.testing.expectError(error.InvalidPath, lookup(&file, "/run42//voltage", alloc));
    try std.testing.expectError(error.InvalidPath, lookup(&file, "/run42/", alloc));
}

test "lookup refuses non-hard links" {
    var file = try file_mod.File.open(std.testing.io, "testdata/v3-links.h5", .{});
    defer file.deinit();
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.SoftLinkUnsupported, lookup(&file, "/soft", alloc));
    try std.testing.expectError(error.ExternalLinkUnsupported, lookup(&file, "/ext", alloc));
}
