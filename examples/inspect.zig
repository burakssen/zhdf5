const std = @import("std");
const zhdf5 = @import("zhdf5");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) {
        std.debug.print("usage: hdf5-inspect <file.h5> [group]\n", .{});
        return;
    }

    var file = try zhdf5.File.open(init.io, args[1], .{});
    defer file.deinit();
    const superblock = file.superblock;

    std.debug.print("HDF5 superblock\n", .{});
    std.debug.print("  signature offset: {d}\n", .{superblock.signature_offset});
    std.debug.print("  version:         {d}\n", .{@intFromEnum(superblock.version)});
    std.debug.print("  offset size:     {d}\n", .{superblock.offset_size});
    std.debug.print("  length size:     {d}\n", .{superblock.length_size});
    std.debug.print("  base address:    {?}\n", .{superblock.base_address.raw()});
    std.debug.print("  EOF address:     {?}\n", .{superblock.end_of_file_address.raw()});
    std.debug.print("  root object:     {?}\n", .{superblock.root_group_object_header_address.raw()});
    std.debug.print("  root file off:   {d}\n", .{try superblock.rootObjectHeaderFileOffset()});
    if (superblock.checksumValid()) |valid| {
        std.debug.print("  checksum valid:  {}\n", .{valid});
    }

    var root = try file.group("/", init.arena.allocator());
    var root_listing = try root.list(init.arena.allocator());
    defer root_listing.deinit(init.arena.allocator());
    std.debug.print("  root header:     off={d} msgs={d}\n", .{ root.object.header.file_offset, root.object.header.messages_seen });
    printGroup("root", &root_listing);

    if (args.len == 3) {
        const child_path = try std.fmt.allocPrint(init.arena.allocator(), "/{s}", .{args[2]});
        var nested = try file.group(child_path, init.arena.allocator());
        var nested_listing = try nested.list(init.arena.allocator());
        defer nested_listing.deinit(init.arena.allocator());
        printGroup(args[2], &nested_listing);
    }
}

fn printGroup(label: []const u8, listing: *const zhdf5.GroupListing) void {
    std.debug.print("  group '{s}' ({d} entries):\n", .{ label, listing.entries.len });
    for (listing.entries) |entry| {
        std.debug.print("    {s} -> oh={?}\n", .{ entry.name, entry.object_header.raw() });
    }
}
