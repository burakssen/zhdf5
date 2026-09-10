const std = @import("std");
const codec = @import("../codec/root.zig");
const address = @import("../wire/address.zig");
const checksum = @import("../wire/checksum.zig");
const wire = @import("../wire/root.zig");

pub const Address = address.Address;

pub const header_signature = [4]u8{ 'B', 'T', 'H', 'D' };
pub const internal_signature = [4]u8{ 'B', 'T', 'I', 'N' };
pub const leaf_signature = [4]u8{ 'B', 'T', 'L', 'F' };

// ponytail: only the dense link-name index layout (hash + heap id) is
// implemented; every other B-tree type is rejected at the header.
pub const GRP_DENSE_NAME: u8 = 5;

const max_depth: u8 = 8; // hard cap sizing TreeModel.levels; policy is ctx.limits.btree_depth.

pub const Record = struct {
    hash: u32,
    id: []u8,
};

pub const IdList = struct {
    records: []Record,
    checksum_valid: bool,

    pub fn deinit(self: *IdList, allocator: std.mem.Allocator) void {
        for (self.records) |rec| allocator.free(rec.id);
        allocator.free(self.records);
        self.* = undefined;
    }
};

/// Walks a version-2 B-tree name index, collecting (hash, heap id) records
/// in index order. Checksums are verified and reported, never fatal.
pub fn collectIds(
    source: anytype,
    ctx: wire.Context,
    btree_addr: Address,
    expected_type: u8,
    id_len: u8,
    allocator: std.mem.Allocator,
) !IdList {
    const abs = try ctx.resolve(btree_addr);
    var dec = try codec.readerAt(source, abs);
    try dec.expectBytes(&header_signature);

    if (try dec.readByte() != 0) return error.UnsupportedBTreeVersion;
    if (try dec.readByte() != expected_type) return error.WrongBTreeType;
    const node_size = try dec.readInt(u32, .little);
    if (node_size < 10 or node_size > ctx.limits.node_bytes) return error.CorruptNodeSize;
    const rrec_size = try dec.readInt(u16, .little);
    if (rrec_size != 4 + id_len) return error.CorruptRecordLayout;
    const depth = try dec.readInt(u16, .little);
    if (depth > max_depth or depth > ctx.limits.btree_depth) return error.BTreeTooDeep;
    _ = try dec.readByte(); // split percent; ponytail: tuning hint, unchecked on read.
    _ = try dec.readByte(); // merge percent; ponytail: tuning hint, unchecked on read.
    const root_addr = try wire.readAddress(&dec, ctx.widths.offset);
    const root_nrec = try dec.readInt(u16, .little);
    const all_nrec = try wire.readLength(&dec, ctx.widths.length);

    const hdr_len = dec.position() - abs;
    const stored = try dec.readInt(u32, .little);
    const hspan: usize = @intCast(hdr_len);
    const hbuf = try allocator.alloc(u8, hspan);
    defer allocator.free(hbuf);
    try source.readAt(abs, hbuf);
    var checksum_valid = (checksum.metadata(hbuf) == stored);

    var out: std.ArrayList(Record) = .empty;
    defer out.deinit(allocator);
    var nodes: u32 = 0;
    var seen: u64 = 0;
    const model = try computeModel(node_size, rrec_size, depth, ctx.widths.offset);
    const tree = Tree{
        .node_size = node_size,
        .id_len = id_len,
        .expected_type = expected_type,
        .count_width = model.count_width,
        .levels = model.levels[0..],
    };
    const root_abs = try ctx.resolve(root_addr);
    try walkNode(source, ctx, root_abs, root_nrec, @intCast(depth), tree, &out, &nodes, &seen, &checksum_valid, allocator);

    if (seen != all_nrec) return error.CorruptCount;
    return .{ .records = try out.toOwnedSlice(allocator), .checksum_valid = checksum_valid };
}

/// Capacity model mirroring libhdf5's header init: per-level record maxima
/// and the fixed on-disk widths of node counts derived from them.
const LevelInfo = struct {
    max_nrec: u64,
    cum: u64,
    cum_size: u8,
};

const TreeModel = struct {
    levels: [max_depth + 1]LevelInfo,
    count_width: u8,
};

/// Everything a node walk needs beyond the cursor.
const Tree = struct {
    node_size: u32,
    id_len: u8,
    expected_type: u8,
    count_width: u8,
    levels: []const LevelInfo,
};

fn computeModel(node_size: u32, rrec_size: u16, depth: u16, addr_size: u8) !TreeModel {
    var model: TreeModel = undefined;
    const leaf_max = (@as(u64, node_size) - 10) / rrec_size;
    model.count_width = encSize(leaf_max);
    model.levels[0] = .{ .max_nrec = leaf_max, .cum = leaf_max, .cum_size = 0 };
    var u: usize = 1;
    while (u <= depth) : (u += 1) {
        const prev = model.levels[u - 1];
        // Pointer size at this level: address + count + cumulative count.
        const ptr_size = @as(u64, addr_size) + model.count_width + prev.cum_size;
        if (@as(u64, node_size) < 10 + ptr_size + rrec_size + ptr_size) return error.CorruptCounts;
        const max_nrec = (@as(u64, node_size) - 10 - ptr_size) / (@as(u64, rrec_size) + ptr_size);
        const cum = std.math.add(u64, std.math.mul(u64, max_nrec + 1, prev.cum) catch return error.CorruptCounts, max_nrec) catch return error.CorruptCounts;
        model.levels[u] = .{ .max_nrec = max_nrec, .cum = cum, .cum_size = encSize(cum) };
    }
    return model;
}

/// Bytes to encode values 0..limit (H5VM_limit_enc_size).
fn encSize(limit: u64) u8 {
    return @intCast((63 - @clz(limit | 1)) / 8 + 1);
}

fn walkNode(
    source: anytype,
    ctx: wire.Context,
    node_addr: u64,
    nrec: u16,
    depth: u8,
    tree: Tree,
    out: *std.ArrayList(Record),
    nodes: *u32,
    seen: *u64,
    checksum_valid: *bool,
    allocator: std.mem.Allocator,
) !void {
    nodes.* += 1;
    if (nodes.* > ctx.limits.btree_nodes) return error.TooManyNodes;
    seen.* = std.math.add(u64, seen.*, nrec) catch return error.CorruptCount;

    const size: usize = tree.node_size;
    const end = std.math.add(u64, node_addr, tree.node_size) catch return error.HeapTooLarge;
    if (end > ctx.eof) return error.TruncatedNode;
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    try source.readAt(node_addr, buf);

    var pos: usize = 0;
    if (depth == 0) {
        try expectBytesAt(buf, &pos, &leaf_signature);
    } else {
        try expectBytesAt(buf, &pos, &internal_signature);
    }
    if (try takeByte(buf, &pos) != 0) return error.UnsupportedNodeVersion;
    if (try takeByte(buf, &pos) != tree.expected_type) return error.WrongBTreeType;

    if (depth == 0) {
        var i: u16 = 0;
        while (i < nrec) : (i += 1) {
            const hash = try takeU32(buf, &pos);
            const id = try allocator.dupe(u8, try takeBytes(buf, &pos, tree.id_len));
            errdefer allocator.free(id);
            try out.append(allocator, .{ .hash = hash, .id = id });
        }
    } else {
        if (nrec == 0) return error.CorruptNode;
        const lvl = tree.levels[depth - 1];
        var i: u16 = 0;
        while (i < nrec) : (i += 1) {
            // Internal records are live links (each stored exactly once), not
            // copies: collect them like leaf records.
            const hash = try takeU32(buf, &pos);
            const id = try allocator.dupe(u8, try takeBytes(buf, &pos, tree.id_len));
            errdefer allocator.free(id);
            try out.append(allocator, .{ .hash = hash, .id = id });
        }
        var p: u16 = 0;
        while (p < nrec + 1) : (p += 1) {
            const child = try takeAddress(buf, &pos, ctx.widths.offset);
            const child_nrec = try takeSized(buf, &pos, tree.count_width);
            if (child_nrec > lvl.max_nrec) return error.CorruptNode;
            if (depth > 1) {
                const child_all = try takeSized(buf, &pos, lvl.cum_size);
                if (child_all > lvl.cum) return error.CorruptNode;
            }
            const child_abs = try ctx.resolve(child);
            try walkNode(source, ctx, child_abs, @intCast(child_nrec), depth - 1, tree, out, nodes, seen, checksum_valid, allocator);
        }
    }

    if (pos + 4 > size) return error.TruncatedNode;
    const stored = std.mem.readInt(u32, buf[pos..][0..4], .little);
    checksum_valid.* = checksum_valid.* and (checksum.metadata(buf[0..pos]) == stored);
}

fn expectBytesAt(buf: []const u8, pos: *usize, expected: *const [4]u8) !void {
    const actual = try takeBytes(buf, pos, 4);
    if (!std.mem.eql(u8, actual, expected)) return error.BadNodeSignature;
}

fn takeByte(buf: []const u8, pos: *usize) !u8 {
    if (pos.* >= buf.len) return error.TruncatedNode;
    const b = buf[pos.*];
    pos.* += 1;
    return b;
}

fn takeU32(buf: []const u8, pos: *usize) !u32 {
    if (buf.len - pos.* < 4) return error.TruncatedNode;
    const v = std.mem.readInt(u32, buf[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn takeBytes(buf: []const u8, pos: *usize, count: usize) ![]const u8 {
    if (count > buf.len - pos.*) return error.TruncatedNode;
    const slice = buf[pos.*..][0..count];
    pos.* += count;
    return slice;
}

fn takeAddress(buf: []const u8, pos: *usize, width: u8) !Address {
    const raw = try takeBytes(buf, pos, width);
    var dec = codec.sliceReader(raw);
    return address.readAddress(&dec, width);
}

/// Fixed-width little-endian u64 (field widths come from the capacity model).
fn takeSized(buf: []const u8, pos: *usize, width: u8) !u64 {
    if (width == 0 or width > 8) return error.CorruptCounts;
    if (width > buf.len - pos.*) return error.TruncatedNode;
    var value: u64 = 0;
    for (buf[pos.*..][0..width], 0..) |b, i| {
        const shift: u6 = @intCast(i * 8);
        value |= @as(u64, b) << shift;
    }
    pos.* += width;
    return value;
}

fn writeChecksum(buf: []u8, start: usize, end: usize) void {
    const chk = checksum.metadata(buf[start..end]);
    std.mem.writeInt(u32, buf[end..][0..4], chk, .little);
}

test "collects ids from a single leaf node" {
    // Header: BTHD ver0 type5 node_size=64 rrec=11 depth=0 nrec=2 all=2.
    var file = [_]u8{0} ** 256;
    var pos: usize = 0;
    @memcpy(file[pos..][0..4], "BTHD");
    pos += 4;
    file[pos] = 0;
    pos += 1;
    file[pos] = 5;
    pos += 1;
    std.mem.writeInt(u32, file[pos..][0..4], 64, .little);
    pos += 4;
    std.mem.writeInt(u16, file[pos..][0..2], 11, .little);
    pos += 2;
    std.mem.writeInt(u16, file[pos..][0..2], 0, .little);
    pos += 2;
    file[pos] = 0;
    file[pos + 1] = 0;
    pos += 2; // split/merge
    std.mem.writeInt(u64, file[pos..][0..8], 64, .little);
    pos += 8; // root addr
    std.mem.writeInt(u16, file[pos..][0..2], 2, .little);
    pos += 2; // root nrec
    std.mem.writeInt(u64, file[pos..][0..8], 2, .little);
    pos += 8; // all_nrec
    const hchk = @import("../wire/checksum.zig").metadata(file[0..pos]);
    std.mem.writeInt(u32, file[pos..][0..4], hchk, .little);
    pos += 4;
    try std.testing.expectEqual(@as(usize, 38), pos);

    // Leaf at 64: BTLF ver0 type5 + 2 records (hash + 7B id) + checksum.
    var lp: usize = 64;
    @memcpy(file[lp..][0..4], "BTLF");
    lp += 4;
    file[lp] = 0;
    lp += 1;
    file[lp] = 5;
    lp += 1;
    std.mem.writeInt(u32, file[lp..][0..4], 0x12345678, .little);
    lp += 4;
    @memcpy(file[lp..][0..7], "id-one!");
    lp += 7;
    std.mem.writeInt(u32, file[lp..][0..4], 0xdeadbeef, .little);
    lp += 4;
    @memcpy(file[lp..][0..7], "id-two!");
    lp += 7;
    const lchk = @import("../wire/checksum.zig").metadata(file[64..lp]);
    std.mem.writeInt(u32, file[lp..][0..4], lchk, .little);
    lp += 4;
    try std.testing.expectEqual(@as(usize, 64 + 6 + 22 + 4), lp);

    const source = codec.SliceSource.init(&file);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    var list = try collectIds(&source, ctx, .{ .value = 0 }, GRP_DENSE_NAME, 7, std.testing.allocator);
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(list.checksum_valid);
    try std.testing.expectEqual(@as(usize, 2), list.records.len);
    try std.testing.expectEqual(@as(u32, 0x12345678), list.records[0].hash);
    try std.testing.expectEqualStrings("id-one!", list.records[0].id);
    try std.testing.expectEqualStrings("id-two!", list.records[1].id);
}

test "internal nodes recurse with varint child counts" {
    // Header depth=1, root internal (1 rec) with 2 leaf children, all_nrec=2.
    var file = [_]u8{0} ** 512;
    var pos: usize = 0;
    @memcpy(file[pos..][0..4], "BTHD");
    pos += 4;
    file[pos] = 0;
    pos += 1;
    file[pos] = 5;
    pos += 1;
    std.mem.writeInt(u32, file[pos..][0..4], 64, .little);
    pos += 4;
    std.mem.writeInt(u16, file[pos..][0..2], 11, .little);
    pos += 2;
    std.mem.writeInt(u16, file[pos..][0..2], 1, .little);
    pos += 2;
    file[pos] = 0;
    file[pos + 1] = 0;
    pos += 2; // split/merge
    std.mem.writeInt(u64, file[pos..][0..8], 64, .little);
    pos += 8; // root addr
    std.mem.writeInt(u16, file[pos..][0..2], 1, .little);
    pos += 2; // root nrec
    std.mem.writeInt(u64, file[pos..][0..8], 3, .little);
    pos += 8; // all_nrec: root record + both leaves
    writeChecksum(&file, 0, pos);
    pos += 4;

    // Root internal at 64: BTIN + 1 skipped record + 2 pointers (addr + uvarint nrec).
    var ip: usize = 64;
    @memcpy(file[ip..][0..4], "BTIN");
    ip += 4;
    file[ip] = 0;
    ip += 1;
    file[ip] = 5;
    ip += 1;
    @memset(file[ip..][0..11], 0xaa); // record bytes; ordering only matters for search.
    ip += 11;
    std.mem.writeInt(u64, file[ip..][0..8], 128, .little);
    ip += 8; // child 0
    file[ip] = 1;
    ip += 1; // nrec varint (depth 1: no cumulative count)
    std.mem.writeInt(u64, file[ip..][0..8], 192, .little);
    ip += 8; // child 1
    file[ip] = 1;
    ip += 1;
    writeChecksum(&file, 64, ip);
    ip += 4;

    // Leaf children with one record each.
    var lp: usize = 128;
    @memcpy(file[lp..][0..4], "BTLF");
    lp += 4;
    file[lp] = 0;
    lp += 1;
    file[lp] = 5;
    lp += 1;
    std.mem.writeInt(u32, file[lp..][0..4], 0x11111111, .little);
    lp += 4;
    @memcpy(file[lp..][0..7], "leaf-00");
    lp += 7;
    writeChecksum(&file, 128, lp);
    lp += 4;

    var lp2: usize = 192;
    @memcpy(file[lp2..][0..4], "BTLF");
    lp2 += 4;
    file[lp2] = 0;
    lp2 += 1;
    file[lp2] = 5;
    lp2 += 1;
    std.mem.writeInt(u32, file[lp2..][0..4], 0x22222222, .little);
    lp2 += 4;
    @memcpy(file[lp2..][0..7], "leaf-01");
    lp2 += 7;
    writeChecksum(&file, 192, lp2);
    lp2 += 4;

    const source = codec.SliceSource.init(&file);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    var list = try collectIds(&source, ctx, .{ .value = 0 }, GRP_DENSE_NAME, 7, std.testing.allocator);
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(list.checksum_valid);
    try std.testing.expectEqual(@as(usize, 3), list.records.len);
    try std.testing.expectEqual(@as(u32, 0x11111111), list.records[1].hash);
    try std.testing.expectEqualStrings("leaf-00", list.records[1].id);
    try std.testing.expectEqualStrings("leaf-01", list.records[2].id);
}
