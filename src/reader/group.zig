//! Unified group view: hides the legacy symbol-table, compact-link, and
//! dense-link representations behind list/get. Lookup is linear; indexed
//! search can replace it later without changing this API.

const std = @import("std");
const format = @import("../format/root.zig");
const file_mod = @import("file.zig");
const object_mod = @import("object.zig");

/// Owned group entry: the name is duped so it outlives the listing.
pub const Entry = struct {
    name: []u8,
    object_header: format.Address,
    kind: format.symbol_table.LinkKind,
    corder: ?i64 = null,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Group = struct {
    object: object_mod.Object,

    pub fn fromObject(object: object_mod.Object) !Group {
        if (object.kind() != .group) return error.NotAGroup;
        return .{ .object = object };
    }

    pub fn open(file: *file_mod.File, address: format.Address) !Group {
        return fromObject(try object_mod.Object.open(file, address));
    }

    pub fn root(file: *file_mod.File) !Group {
        return open(file, file.superblock.root_group_object_header_address);
    }

    pub fn list(self: *Group, allocator: std.mem.Allocator) !format.GroupListing {
        const f = self.object.file;
        const header = &self.object.header;
        if (header.symbol_table) |symtab| {
            const params = try format.LegacyGroupParams.fromSuperblock(f.superblock);
            return format.listGroup(&f.source, f.ctx, params, symtab.btree_address, symtab.heap_address, allocator);
        }
        const info = header.link_info orelse return error.NoGroupMessage;
        if (info.isDense()) {
            return format.listDenseLinks(info, &f.source, f.ctx, allocator);
        }
        return format.listCompactLinks(
            header.link_slots[0..header.link_count],
            header.track_corder,
            &f.source,
            f.ctx,
            allocator,
        );
    }

    /// Linear search over a fresh listing; only the match is kept.
    pub fn get(self: *Group, name: []const u8, allocator: std.mem.Allocator) !?Entry {
        var listing = try self.list(allocator);
        defer listing.deinit(allocator);
        for (listing.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) {
                return .{
                    .name = try allocator.dupe(u8, e.name),
                    .object_header = e.object_header,
                    .kind = e.kind,
                    .corder = e.corder,
                };
            }
        }
        return null;
    }
};

test "legacy root lists v0 entries with link kinds" {
    var file = try file_mod.File.open(std.testing.io, "testdata/v0-symtab.h5", .{});
    defer file.deinit();
    var root = try Group.root(&file);
    var listing = try root.list(std.testing.allocator);
    defer listing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), listing.entries.len);

    var sensors = try root.get("sensors", std.testing.allocator);
    defer {
        if (sensors) |*e| e.deinit(std.testing.allocator);
    }
    try std.testing.expect(sensors != null);
    try std.testing.expectEqual(format.symbol_table.LinkKind.hard, sensors.?.kind);

    var alias = try root.get("alias", std.testing.allocator);
    defer {
        if (alias) |*e| e.deinit(std.testing.allocator);
    }
    try std.testing.expect(alias != null);
    try std.testing.expectEqual(format.symbol_table.LinkKind.soft, alias.?.kind);

    try std.testing.expect((try root.get("missing", std.testing.allocator)) == null);
}

test "dense group lists two thousand links" {
    var file = try file_mod.File.open(std.testing.io, "testdata/v3-deep.h5", .{});
    defer file.deinit();
    var big = try file.group("/big", std.testing.allocator);
    var listing = try big.list(std.testing.allocator);
    defer listing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2000), listing.entries.len);
}

test "fromObject rejects non-groups" {
    var file = try file_mod.File.open(std.testing.io, "testdata/v3-nested.h5", .{});
    defer file.deinit();
    const voltage = try file.object("/run42/voltage", std.testing.allocator);
    try std.testing.expectError(error.NotAGroup, Group.fromObject(voltage));
}
