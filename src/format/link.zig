const std = @import("std");
const codec = @import("../codec/root.zig");
const address = @import("../wire/address.zig");
const checksum = @import("../wire/checksum.zig");
const symbol_table = @import("symbol_table.zig");
const ctx = @import("ctx.zig");
const fheap = @import("fheap.zig");
const btree2 = @import("btree2.zig");

pub const Address = address.Address;
pub const Superblock = symbol_table.Superblock;
pub const Entry = symbol_table.Entry;
pub const GroupListing = symbol_table.GroupListing;

pub const MSG_INFO: u8 = 0x02;
pub const MSG_LINK: u8 = 0x06;

/// Maximum inline-decoded link-info payload: ver + flags + i64 + 3 addresses.
pub const max_link_info_bytes: u16 = 2 + 8 + 3 * 16;

// ponytail: compact groups bigger than this return TooManyCompactLinks instead of allocating a directory.
pub const max_compact_links: usize = 64;

pub const MessageRange = struct {
    offset: u64,
    len: u16,
};

pub const LinkInfo = struct {
    max_corder: i64,
    fheap_address: Address,
    name_btree_address: Address,
    corder_btree_address: Address,
    track_corder: bool,
    index_corder: bool,

    /// Dense link storage iff the fractal heap is defined.
    pub fn isDense(self: LinkInfo) bool {
        return !self.fheap_address.isUndefined();
    }
};

pub const LinkType = enum(u8) {
    hard = 0,
    soft = 1,
    external = 64,
    user_defined,

    pub fn fromByte(value: u8) LinkType {
        return switch (value) {
            0 => .hard,
            1 => .soft,
            64 => .external,
            else => .user_defined,
        };
    }
};

pub const Link = struct {
    /// Borrows the message payload.
    name: []const u8,
    /// Hard-link object header; undefined for soft/external/user links.
    target: Address,
    link_type: LinkType,
    /// Creation order when stored (tracked groups only).
    corder: ?i64,
};

/// Reads a link-info payload through a decode context (bounds-checked).
pub fn readLinkInfo(cx: anytype, offset: u64, len: u16) !LinkInfo {
    if (len > max_link_info_bytes) return error.LinkInfoTooLarge;
    var stack: [max_link_info_bytes]u8 = undefined;
    try cx.readAt(offset, stack[0..len]);
    return decodeLinkInfo(stack[0..len], cx.offsetSize());
}

/// Decodes a link-info message payload (pure, bounds-checked).
pub fn decodeLinkInfo(payload: []const u8, offset_size: u8) !LinkInfo {
    if (payload.len < 2) return error.TruncatedLinkInfo;
    if (payload[0] != 0) return error.UnsupportedLinkInfoVersion;
    const flags = payload[1];
    if (flags & ~@as(u8, 0x03) != 0) return error.InvalidLinkInfoFlags;

    const track_corder = (flags & 0x01) != 0;
    const index_corder = (flags & 0x02) != 0;
    var pos: usize = 2;

    var max_corder: i64 = 0;
    if (track_corder) {
        if (payload.len < pos + 8) return error.TruncatedLinkInfo;
        max_corder = std.mem.readInt(i64, payload[pos..][0..8], .little);
        if (max_corder < 0) return error.InvalidMaxCorder;
        pos += 8;
    }

    const addrs = try readTwoAddresses(payload, &pos, offset_size);
    var corder_btree: Address = .undefined_address;
    if (index_corder) {
        corder_btree = try readOneAddress(payload, &pos, offset_size);
    }
    if (pos != payload.len) return error.TrailingLinkInfoBytes;

    return .{
        .max_corder = max_corder,
        .fheap_address = addrs[0],
        .name_btree_address = addrs[1],
        .corder_btree_address = corder_btree,
        .track_corder = track_corder,
        .index_corder = index_corder,
    };
}

/// Decodes a link message payload: name borrows the payload buffer.
pub fn decodeLink(payload: []const u8, offset_size: u8) !Link {
    if (payload.len < 2) return error.TruncatedLink;
    if (payload[0] != 1) return error.UnsupportedLinkVersion;
    const flags = payload[1];
    if (flags & ~@as(u8, 0x1f) != 0) return error.InvalidLinkFlags;
    var pos: usize = 2;

    var link_type: LinkType = .hard;
    if (flags & 0x08 != 0) {
        if (payload.len < pos + 1) return error.TruncatedLink;
        link_type = LinkType.fromByte(payload[pos]);
        pos += 1;
    }

    var corder: ?i64 = null;
    if (flags & 0x04 != 0) {
        if (payload.len < pos + 8) return error.TruncatedLink;
        corder = std.mem.readInt(i64, payload[pos..][0..8], .little);
        pos += 8;
    }

    if (flags & 0x10 != 0) {
        if (payload.len < pos + 1) return error.TruncatedLink;
        const cset = payload[pos];
        if (cset > 1) return error.InvalidLinkCharset;
        pos += 1;
    }

    const width: usize = @as(usize, 1) << @intCast(flags & 0x03);
    if (payload.len < pos + width) return error.TruncatedLink;
    var name_len: u64 = 0;
    for (payload[pos..][0..width], 0..) |b, i| {
        name_len |= @as(u64, b) << @intCast(i * 8);
    }
    pos += width;
    if (name_len == 0) return error.InvalidLinkName;
    if (name_len > payload.len - pos) return error.TruncatedLink;
    const n: usize = @intCast(name_len);
    const name = payload[pos .. pos + n];
    pos += n;

    var target: Address = .undefined_address;
    switch (link_type) {
        .hard => {
            const rest = payload[pos..];
            if (rest.len < offset_size) return error.TruncatedLink;
            var dec = codec.sliceReader(rest);
            target = try address.readAddress(&dec, offset_size);
            pos += offset_size;
        },
        .soft => {
            if (payload.len < pos + 2) return error.TruncatedLink;
            const len = std.mem.readInt(u16, payload[pos..][0..2], .little);
            if (len == 0 or len > payload.len - pos - 2) return error.TruncatedLink;
            pos += 2 + len;
            // ponytail: soft targets listed by name only; resolution is a later phase.
        },
        .external, .user_defined => {
            if (payload.len < pos + 2) return error.TruncatedLink;
            const len = std.mem.readInt(u16, payload[pos..][0..2], .little);
            if (len > payload.len - pos - 2) return error.TruncatedLink;
            pos += 2 + len;
            // ponytail: external/user link blobs skipped, not interpreted.
        },
    }
    if (pos != payload.len) return error.TrailingLinkBytes;

    return .{ .name = name, .target = target, .link_type = link_type, .corder = corder };
}

/// Lists compact links recorded in a header directory into owned entries.
/// Entry names are NUL-joined in one buffer owned by the listing.
pub fn listCompact(
    slots: []const MessageRange,
    track_corder: bool,
    source: anytype,
    superblock: Superblock,
    allocator: std.mem.Allocator,
) !GroupListing {
    var cx_holder = ctx.Ctx(@TypeOf(source.*)).init(source.*, superblock);
    const cx = &cx_holder;
    var collector = Collector{};
    defer collector.deinit(allocator);

    for (slots) |slot| {
        const payload = try allocator.alloc(u8, slot.len);
        defer allocator.free(payload);
        try cx.readAt(slot.offset, payload);
        const link = try decodeLink(payload, cx.offsetSize());
        try collector.add(link.name, link.target, link.corder, allocator);
    }
    return collector.finish(track_corder, allocator);
}

/// Lists dense links via the fractal heap + v2 B-tree name index.
/// Names come out in B-tree (alphabetical-by-hash) order; creation-order
/// iteration is deferred even when the index exists.
// ponytail: dense iteration is name-ordered; corder index traversal lands later.
pub fn listDense(
    info: LinkInfo,
    source: anytype,
    superblock: Superblock,
    allocator: std.mem.Allocator,
) !GroupListing {
    var cx_holder = ctx.Ctx(@TypeOf(source.*)).init(source.*, superblock);
    const cx = &cx_holder;

    const heap = try fheap.open(cx, info.fheap_address, allocator);
    var ids = try btree2.collectIds(cx, info.name_btree_address, btree2.GRP_DENSE_NAME, heap.id_len, allocator);
    defer ids.deinit(allocator);

    var collector = Collector{};
    defer collector.deinit(allocator);
    for (ids.records) |rec| {
        const object = try fheap.readManaged(heap, cx, rec.id, allocator);
        defer allocator.free(object);
        const link = try decodeLink(object, cx.offsetSize());
        if (checksum.metadata(link.name) != rec.hash) return error.CorruptNameHash;
        try collector.add(link.name, link.target, link.corder, allocator);
    }
    return collector.finish(false, allocator);
}

/// NUL-joined name blob builder shared by the compact and dense paths.
const Collector = struct {
    blob: std.ArrayList(u8) = .empty,
    raws: std.ArrayList(RawLink) = .empty,

    const RawLink = struct {
        start: usize,
        len: usize,
        target: Address,
        corder: ?i64,
    };

    fn deinit(self: *Collector, allocator: std.mem.Allocator) void {
        self.blob.deinit(allocator);
        self.raws.deinit(allocator);
    }

    fn add(
        self: *Collector,
        name: []const u8,
        target: Address,
        corder: ?i64,
        allocator: std.mem.Allocator,
    ) !void {
        const start = self.blob.items.len;
        try self.blob.appendSlice(allocator, name);
        try self.blob.append(allocator, 0);
        try self.raws.append(allocator, .{
            .start = start,
            .len = name.len,
            .target = target,
            .corder = corder,
        });
    }

    fn finish(
        self: *Collector,
        sorted: bool,
        allocator: std.mem.Allocator,
    ) !GroupListing {
        var heap_data = try self.blob.toOwnedSlice(allocator);
        errdefer allocator.free(heap_data);
        var entries = try allocator.alloc(Entry, self.raws.items.len);
        errdefer allocator.free(entries);
        for (self.raws.items, 0..) |raw, i| {
            entries[i] = .{
                .name = heap_data[raw.start..][0..raw.len],
                .object_header = raw.target,
                .cache_type = 0, // ponytail: v1 cache types don't apply to v2 links.
                .corder = raw.corder,
            };
        }
        if (sorted) std.mem.sort(Entry, entries, {}, lessByCorder);
        return .{ .heap_data = heap_data, .entries = entries };
    }
};

fn lessByCorder(_: void, a: Entry, b: Entry) bool {
    const ka = a.corder orelse std.math.maxInt(i64);
    const kb = b.corder orelse std.math.maxInt(i64);
    return ka < kb;
}

fn readOneAddress(payload: []const u8, pos: *usize, offset_size: u8) !Address {
    if (payload.len < pos.* + offset_size) return error.TruncatedLinkInfo;
    var dec = codec.sliceReader(payload[pos.*..]);
    const addr = try address.readAddress(&dec, offset_size);
    pos.* += offset_size;
    return addr;
}

fn readTwoAddresses(payload: []const u8, pos: *usize, offset_size: u8) ![2]Address {
    return .{
        try readOneAddress(payload, pos, offset_size),
        try readOneAddress(payload, pos, offset_size),
    };
}

test "link-info flags select 18/26/34-byte layouts" {
    const compact = [_]u8{0} ++ [_]u8{0} ++ [_]u8{0xff} ** 16;
    const li = try decodeLinkInfo(&compact, 8);
    try std.testing.expect(!li.isDense());
    try std.testing.expect(!li.track_corder);

    var tracked = [_]u8{0} ** 26;
    tracked[0] = 0;
    tracked[1] = 0x01;
    std.mem.writeInt(i64, tracked[2..10], 7, .little);
    @memset(tracked[10..], 0xff);
    const li2 = try decodeLinkInfo(&tracked, 8);
    try std.testing.expect(li2.track_corder);
    try std.testing.expectEqual(@as(i64, 7), li2.max_corder);
    try std.testing.expect(!li2.isDense());

    var indexed = [_]u8{0} ** 34;
    indexed[0] = 0;
    indexed[1] = 0x03;
    std.mem.writeInt(i64, indexed[2..10], 3, .little);
    @memset(indexed[10..], 0xff);
    const li3 = try decodeLinkInfo(&indexed, 8);
    try std.testing.expect(li3.index_corder);
    try std.testing.expectEqual(@as(i64, 3), li3.max_corder);
}

test "link-info rejects bad version, flags, negative corder, trailing bytes" {
    var bad_ver = [_]u8{0} ** 18;
    bad_ver[0] = 9;
    try std.testing.expectError(error.UnsupportedLinkInfoVersion, decodeLinkInfo(&bad_ver, 8));

    var bad_flags = [_]u8{0} ** 18;
    bad_flags[1] = 0x04;
    try std.testing.expectError(error.InvalidLinkInfoFlags, decodeLinkInfo(&bad_flags, 8));

    var neg = [_]u8{0} ** 26;
    neg[1] = 0x01;
    std.mem.writeInt(i64, neg[2..10], -1, .little);
    try std.testing.expectError(error.InvalidMaxCorder, decodeLinkInfo(&neg, 8));

    var trailing = [_]u8{0} ** 19;
    try std.testing.expectError(error.TrailingLinkInfoBytes, decodeLinkInfo(&trailing, 8));
}

test "link decodes a hard link at every name width" {
    const names = [_][]const u8{ "g", "da", "voltage" };
    for (names) |name| {
        for ([_]u8{ 0, 1, 2, 3 }) |w| {
            var payload: [64]u8 = undefined;
            var pos: usize = 0;
            payload[0] = 1;
            payload[1] = w;
            pos = 2;
            const width: usize = @as(usize, 1) << @intCast(w);
            @memset(payload[pos .. pos + width], 0);
            payload[pos] = @intCast(name.len);
            pos += width;
            @memcpy(payload[pos .. pos + name.len], name);
            pos += name.len;
            @memset(payload[pos .. pos + 8], 0);
            payload[pos] = 0x42;
            pos += 8;
            const link = try decodeLink(payload[0..pos], 8);
            try std.testing.expectEqualStrings(name, link.name);
            try std.testing.expectEqual(LinkType.hard, link.link_type);
            try std.testing.expectEqual(@as(?u64, 0x42), link.target.raw());
            try std.testing.expectEqual(@as(?i64, null), link.corder);
        }
    }
}

test "link decodes type, corder, cset, soft and external targets" {
    var with_meta = [_]u8{ 1, 0x1c, 64, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 'f', 'o', 'o', 0, 0 };
    with_meta[11] = 1; // cset UTF-8 at pos 11
    const m = try decodeLink(&with_meta, 8);
    try std.testing.expectEqual(LinkType.external, m.link_type);
    try std.testing.expectEqual(@as(?i64, 0), m.corder);
    try std.testing.expectEqualStrings("foo", m.name);
    try std.testing.expect(m.target.isUndefined());

    const soft_payload = [_]u8{ 1, 0x08, 1, 2, 'a', 'b', 2, 0, '/', 'x' };
    const s = try decodeLink(&soft_payload, 8);
    try std.testing.expectEqual(LinkType.soft, s.link_type);
    try std.testing.expectEqualStrings("ab", s.name);
}

test "link rejects zero names, bad flags, truncation" {
    const zero_name = [_]u8{ 1, 0, 0 };
    try std.testing.expectError(error.InvalidLinkName, decodeLink(&zero_name, 8));

    const bad_flags = [_]u8{ 1, 0x20, 1, 'a' };
    try std.testing.expectError(error.InvalidLinkFlags, decodeLink(&bad_flags, 8));

    const bad_ver = [_]u8{ 2, 0, 1, 'a' };
    try std.testing.expectError(error.UnsupportedLinkVersion, decodeLink(&bad_ver, 8));

    const short = [_]u8{ 1, 0, 5, 'a', 'b' };
    try std.testing.expectError(error.TruncatedLink, decodeLink(&short, 8));
}
