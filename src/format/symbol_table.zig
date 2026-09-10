const std = @import("std");
const codec = @import("../codec/root.zig");
const address = @import("../wire/address.zig");
const superblock = @import("superblock.zig");
const wire = @import("../wire/root.zig");

pub const Superblock = superblock.Superblock;
pub const Address = address.Address;

/// B-tree degrees for legacy (v1) groups, extracted from the superblock once
/// at group-open time so wire.Context stays superblock-free.
pub const LegacyGroupParams = struct {
    leaf_k: u16,
    internal_k: u16,

    pub fn fromSuperblock(sb: Superblock) !LegacyGroupParams {
        return switch (sb.details) {
            .legacy => |legacy| .{
                .leaf_k = legacy.group_leaf_node_k,
                .internal_k = legacy.group_internal_node_k,
            },
            .modern => error.NoGroupKForModernSuperblock,
        };
    }
};

pub const btree_signature = [4]u8{ 'T', 'R', 'E', 'E' };
pub const snod_signature = [4]u8{ 'S', 'N', 'O', 'D' };
pub const heap_signature = [4]u8{ 'H', 'E', 'A', 'P' };

pub const LinkKind = enum { hard, soft, external, user_defined };

pub const Entry = struct {
    name: []const u8,
    object_header: Address,
    cache_type: u32,
    kind: LinkKind,
    /// v2 link creation order; null for v1 symbol-table entries.
    corder: ?i64 = null,
};

pub const GroupListing = struct {
    heap_data: []u8,
    entries: []Entry,

    pub fn deinit(self: *GroupListing, allocator: std.mem.Allocator) void {
        allocator.free(self.heap_data);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

/// Lists the entries of a v1 group defined by a B-tree / local-heap pair.
///
/// Entry names borrow from the owned heap buffer; free with `deinit`.
// ponytail: v2 dense groups (fractal heap + B-tree v2) are out of scope; only TREE/SNOD/HEAP here.
pub fn listGroup(
    source: anytype,
    ctx: wire.Context,
    params: LegacyGroupParams,
    btree_address: Address,
    heap_address: Address,
    allocator: std.mem.Allocator,
) !GroupListing {
    const btree_off = try ctx.resolve(btree_address);
    const heap_off = try ctx.resolve(heap_address);

    const heap = try decodeHeap(source, ctx, heap_off);
    var heap_data: []u8 = &.{};
    defer {
        if (heap_data.len != 0) allocator.free(heap_data);
    }

    // ponytail: heaps bigger than this are rejected instead of buffered.
    if (heap.data_size > ctx.limits.heap_data_bytes) return error.HeapTooLarge;
    if (heap.data_size > 0) {
        const n: usize = @intCast(heap.data_size);
        heap_data = try allocator.alloc(u8, n);
        errdefer allocator.free(heap_data);
        try source.readAt(heap.data_offset, heap_data);
    }

    var snods: std.ArrayList(u64) = .empty;
    defer snods.deinit(allocator);
    try collectSnods(source, ctx, params, btree_off, 0, &snods, allocator);

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);
    for (snods.items) |snod_off| {
        try appendSnodEntries(source, ctx, snod_off, heap_data, &entries, allocator);
    }

    const owned_entries = try entries.toOwnedSlice(allocator);
    errdefer allocator.free(owned_entries);
    const owned_heap = heap_data;
    heap_data = &.{};
    return .{ .heap_data = owned_heap, .entries = owned_entries };
}

pub const Heap = struct {
    data_offset: u64,
    data_size: u64,
};

pub fn decodeHeap(source: anytype, ctx: wire.Context, file_offset: u64) !Heap {
    var reader = try codec.readerAt(source, file_offset);
    try reader.expectBytes(&heap_signature);

    if (try reader.readByte() != 0) return error.UnsupportedHeapVersion;
    var reserved: [3]u8 = undefined;
    try reader.readInto(&reserved);
    if (!std.mem.eql(u8, &reserved, &[_]u8{ 0, 0, 0 })) return error.InvalidReservedField;

    const data_size = try wire.readLength(&reader, ctx.widths.length);
    _ = try wire.readLength(&reader, ctx.widths.length); // free-list head; ponytail: free space ignored
    const data_addr = try wire.readAddress(&reader, ctx.widths.offset);
    const data_offset = try ctx.resolve(data_addr);
    const end = std.math.add(u64, data_offset, data_size) catch return error.HeapTooLarge;
    if (end > ctx.eof) return error.TruncatedHeap;
    return .{ .data_offset = data_offset, .data_size = data_size };
}

fn collectSnods(
    source: anytype,
    ctx: wire.Context,
    params: LegacyGroupParams,
    node_offset: u64,
    depth: u8,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    if (depth > ctx.limits.btree_depth) return error.BTreeTooDeep;
    if (out.items.len >= ctx.limits.btree_nodes) return error.TooManyNodes;

    var reader = try codec.readerAt(source, node_offset);
    try reader.expectBytes(&btree_signature);

    if (try reader.readByte() != 0) return error.UnsupportedBTreeType; // ponytail: raw-chunk B-trees (type 1) are datasets, next phase
    const level = try reader.readByte();
    const entries_used = try reader.readInt(u16, .little);
    const k = if (level == 0) params.leaf_k else params.internal_k;
    const max_entries = @as(u32, k) * 2;
    if (entries_used > max_entries) return error.CorruptBTree;

    _ = try wire.readAddress(&reader, ctx.widths.offset); // left sibling; ponytail: sibling chain not followed
    _ = try wire.readAddress(&reader, ctx.widths.offset); // right sibling

    // Keys are heap offsets of boundary names; listing visits every child so keys are unchecked.
    // ponytail: keys unchecked — full traversal is correct for ls, wrong for lookup (later).
    try reader.skip(ctx.widths.length); // key 0
    var i: u16 = 0;
    while (i < entries_used) : (i += 1) {
        const child = try wire.readAddress(&reader, ctx.widths.offset);
        const child_off = try ctx.resolve(child);
        if (child_off >= ctx.eof) return error.TruncatedBTree;
        if (level == 0) {
            if (out.items.len >= ctx.limits.btree_nodes) return error.TooManyNodes;
            try out.append(allocator, child_off);
        } else {
            try collectSnods(source, ctx, params, child_off, depth + 1, out, allocator);
        }
        try reader.skip(ctx.widths.length); // key i+1
    }
}

fn appendSnodEntries(
    source: anytype,
    ctx: wire.Context,
    snod_offset: u64,
    heap_data: []const u8,
    out: *std.ArrayList(Entry),
    allocator: std.mem.Allocator,
) !void {
    var reader = try codec.readerAt(source, snod_offset);
    try reader.expectBytes(&snod_signature);

    if (try reader.readByte() != 1) return error.UnsupportedSymbolNodeVersion;
    if (try reader.readByte() != 0) return error.InvalidReservedField;
    const count = try reader.readInt(u16, .little);

    var i: u16 = 0;
    while (i < count) : (i += 1) {
        // Name offsets are offset-sized (Group Entry spec), unlike lengths.
        const name_off = try address.readLength(&reader, ctx.widths.offset);
        const obj_addr = try wire.readAddress(&reader, ctx.widths.offset);
        const cache_type = try reader.readInt(u32, .little);
        if (try reader.readInt(u32, .little) != 0) return error.InvalidReservedField;
        var scratch: [16]u8 = undefined;
        try reader.readInto(&scratch);

        if (name_off >= heap_data.len) return error.BadNameOffset;
        const start: usize = @intCast(name_off);
        const end = std.mem.indexOfScalar(u8, heap_data[start..], 0) orelse return error.UnterminatedName;
        // ponytail: symlink targets (cache_type 2) listed by name only; resolution is a later phase.
        try out.append(allocator, .{
            .name = heap_data[start..][0..end],
            .object_header = obj_addr,
            .cache_type = cache_type,
            .kind = if (cache_type == 2) .soft else .hard,
        });
    }
}

test "heap decodes data segment location" {
    const header = [_]u8{
        'H', 'E', 'A', 'P', 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // size 256
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // free head (ignored)
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // data at 128
    };
    var file = [_]u8{0} ** 384;
    @memcpy(file[96..128], &header);
    const source = codec.SliceSource.init(&file);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    const heap = try decodeHeap(&source, ctx, 96);
    try std.testing.expectEqual(@as(u64, 128), heap.data_offset);
    try std.testing.expectEqual(@as(u64, 256), heap.data_size);
}

test "lists root group of test1.h5" {
    var file = [_]u8{0} ** 2048;
    // TREE at 384: leaf, 1 child -> SNOD at 1624 (beyond buffer; remapped below).
    @memcpy(file[384..392], "TREE\x00\x00\x01\x00");
    @memset(file[392..408], 0xff); // siblings undefined
    @memset(file[408..416], 0); // key 0
    @memcpy(file[416..424], &[_]u8{ 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }); // child 1024
    @memcpy(file[424..432], &[_]u8{ 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }); // key 1
    // SNOD at 1024: 1 entry, name_off 8 -> heap string, obj 1576.
    @memcpy(file[1024..1032], "SNOD\x01\x00\x01\x00");
    @memcpy(file[1032..1040], &[_]u8{ 8, 0, 0, 0, 0, 0, 0, 0 });
    @memcpy(file[1040..1048], &[_]u8{ 0x28, 0x06, 0, 0, 0, 0, 0, 0 });
    @memcpy(file[1048..1056], &[_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 });
    // HEAP at 96 with data at 128.
    @memcpy(file[96..104], "HEAP\x00\x00\x00\x00");
    @memcpy(file[104..112], &[_]u8{ 16, 0, 0, 0, 0, 0, 0, 0 });
    @memcpy(file[112..120], &[_]u8{ 8, 0, 0, 0, 0, 0, 0, 0 });
    @memcpy(file[120..128], &[_]u8{ 128, 0, 0, 0, 0, 0, 0, 0 });
    @memcpy(file[128 + 8 .. 128 + 16], "Unnamed\x00");

    const source = codec.SliceSource.init(&file);
    const testing = @import("testing.zig");
    const sb = testing.testSuperblock();
    const params = try LegacyGroupParams.fromSuperblock(sb);
    const ctx = wire.Context{
        .widths = .{ .offset = sb.offset_size, .length = sb.length_size },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    var listing = try listGroup(&source, ctx, params, .{ .value = 384 }, .{ .value = 96 }, std.testing.allocator);
    defer listing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), listing.entries.len);
    try std.testing.expectEqualStrings("Unnamed", listing.entries[0].name);
    try std.testing.expectEqual(@as(?u64, 1576), listing.entries[0].object_header.raw());
}

test "legacy params reject modern superblocks instead of trapping" {
    const testing = @import("testing.zig");
    var sb = testing.testSuperblock();
    sb.version = .v2;
    sb.details = .{ .modern = .{
        .superblock_extension_address = .undefined_address,
        .checksum = 0,
        .checksum_valid = true,
    } };
    try std.testing.expectError(error.NoGroupKForModernSuperblock, LegacyGroupParams.fromSuperblock(sb));
}

test "unterminated heap name is an error, not an overread" {
    var file = [_]u8{0} ** 512;
    @memcpy(file[384..392], "TREE\x00\x00\x01\x00");
    @memset(file[392..408], 0xff);
    @memset(file[408..416], 0);
    @memcpy(file[416..424], &[_]u8{ 0x00, 0x01, 0, 0, 0, 0, 0, 0 }); // child 256
    @memset(file[424..432], 0);
    @memcpy(file[256..264], "SNOD\x01\x00\x01\x00");
    @memcpy(file[264..272], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }); // name_off 0
    @memcpy(file[272..280], &[_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 });
    @memcpy(file[280..288], &[_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 });
    @memcpy(file[96..104], "HEAP\x00\x00\x00\x00");
    @memcpy(file[104..112], &[_]u8{ 4, 0, 0, 0, 0, 0, 0, 0 });
    @memset(file[112..120], 0);
    @memcpy(file[120..128], &[_]u8{ 300 & 0xff, 1, 0, 0, 0, 0, 0, 0 }); // data at 300
    @memset(file[300..304], 'A'); // no NUL

    const source = codec.SliceSource.init(&file);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    const params = LegacyGroupParams{ .leaf_k = 4, .internal_k = 16 };
    try std.testing.expectError(
        error.UnterminatedName,
        listGroup(&source, ctx, params, .{ .value = 384 }, .{ .value = 96 }, std.testing.allocator),
    );
}
