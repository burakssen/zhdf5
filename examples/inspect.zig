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

    const root_off = try superblock.rootObjectHeaderFileOffset();
    const header = try zhdf5.decodeObjectHeader(&file.source, superblock, root_off);
    std.debug.print("  root header:     off={d} msgs={d}\n", .{ root_off, header.messages_seen });

    var root = try listHeader(header, &file.source, superblock, init.arena.allocator());
    defer root.deinit(init.arena.allocator());
    printGroup("root", &root);

    // ponytail: one nesting level only; full path walking is a later iteration.
    if (args.len == 3) {
        const wanted = args[2];
        const child = for (root.entries) |entry| {
            if (std.mem.eql(u8, entry.name, wanted)) break entry;
        } else return error.GroupNotFound;
        const child_off = try superblock.resolve(child.object_header);
        const child_header = try zhdf5.decodeObjectHeader(&file.source, superblock, child_off);
        var nested = try listHeader(child_header, &file.source, superblock, init.arena.allocator());
        defer nested.deinit(init.arena.allocator());
        printGroup(wanted, &nested);
    }
}

fn listHeader(
    header: zhdf5.ObjectHeader,
    source: anytype,
    superblock: zhdf5.Superblock,
    allocator: std.mem.Allocator,
) !zhdf5.GroupListing {
    if (header.symbol_table) |symtab| {
        return zhdf5.listGroup(source, superblock, symtab.btree_address, symtab.heap_address, allocator);
    }
    const info = header.link_info orelse return error.NoGroupMessage;
    if (info.isDense()) {
        return zhdf5.listDenseLinks(info, source, superblock, allocator);
    }
    return zhdf5.listCompactLinks(
        header.link_slots[0..header.link_count],
        header.track_corder,
        source,
        superblock,
        allocator,
    );
}

fn printGroup(label: []const u8, listing: *const zhdf5.GroupListing) void {
    std.debug.print("  group '{s}' ({d} entries):\n", .{ label, listing.entries.len });
    for (listing.entries) |entry| {
        std.debug.print("    {s} -> oh={?}\n", .{ entry.name, entry.object_header.raw() });
    }
}
