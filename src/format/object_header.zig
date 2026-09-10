const std = @import("std");
const codec = @import("../codec/root.zig");
const checksum = @import("../wire/checksum.zig");
const address = @import("../wire/address.zig");
const superblock = @import("superblock.zig");
const wire = @import("../wire/root.zig");
const link = @import("link.zig");

pub const Superblock = superblock.Superblock;
pub const Address = address.Address;

pub const Version = enum(u8) {
    v1 = 1,
    v2 = 2,
};

pub const SymbolTable = struct {
    btree_address: Address,
    heap_address: Address,
};

pub const Header = struct {
    version: Version,
    file_offset: u64,
    declared_message_count: ?u16,
    messages_seen: u32,
    symbol_table: ?SymbolTable,
    checksum_valid: ?bool,
    link_info: ?link.LinkInfo = null,
    link_slots: [link.max_compact_links]link.MessageRange = undefined,
    link_count: u8 = 0,
    // ponytail: dataset message payloads are located here, decoded on demand by the dataset readers.
    dataspace: ?link.MessageRange = null,
    datatype: ?link.MessageRange = null,
    layout: ?link.MessageRange = null,
    pending_continuation: Continuation = .{ .offset = 0, .length = 0, .present = false },
    // ponytail: v2 decode-time state kept on Header so v1/v2 chunk scanners share one signature.
    track_corder: bool = false,

    pub fn hasContinuation(self: *const Header) bool {
        return self.pending_continuation.present;
    }

    pub fn takeContinuation(self: *Header) Continuation {
        const c = self.pending_continuation;
        self.pending_continuation = .{ .offset = 0, .length = 0, .present = false };
        return c;
    }
};

pub const v1_signatureless_version: u8 = 1;
pub const v2_signature = [4]u8{ 'O', 'H', 'D', 'R' };
pub const v2_continuation_signature = [4]u8{ 'O', 'C', 'H', 'K' };

pub const MSG_NIL: u16 = 0x0000;
pub const MSG_DATASPACE: u16 = 0x0001;
pub const MSG_DATATYPE: u16 = 0x0003;
pub const MSG_LAYOUT: u16 = 0x0008;
pub const MSG_CONTINUATION: u16 = 0x0010;
pub const MSG_SYMTAB: u16 = 0x0011;

/// Decodes the object header at an absolute file offset.
///
/// Only framing is interpreted: v1 NIL/SymTab/Continuation dispatch and v2
/// prefix/message iteration. All other message payloads are skipped; callers
/// that need datatype/dataspace/layout decode them in a later phase.
// ponytail: unknown messages are skipped, not decoded — only group navigation drives Phase 2.
pub fn decode(source: anytype, ctx: wire.Context, file_offset: u64) !Header {
    if (file_offset >= source.len()) return error.EndOfInput;
    var peek: [4]u8 = undefined;
    try source.readAt(file_offset, &peek);
    if (std.mem.eql(u8, &peek, &v2_signature)) {
        return decodeV2(source, ctx, file_offset);
    }
    return decodeV1(source, ctx, file_offset);
}

fn decodeV1(source: anytype, ctx: wire.Context, file_offset: u64) !Header {
    var reader = try codec.readerAt(source, file_offset);

    const version = try reader.readByte();
    if (version != 1) return error.UnsupportedObjectHeaderVersion;
    if (try reader.readByte() != 0) return error.InvalidReservedField;
    const declared = try reader.readInt(u16, .little);
    _ = try reader.readInt(u32, .little); // refcount; tracked, not enforced
    const hdr_size = try reader.readInt(u32, .little);
    if (try reader.readInt(u32, .little) != 0) return error.InvalidReservedField;

    // Prefix is 16 bytes; messages occupy the hdr_size bytes that follow.
    const chunk_start = file_offset + 16;
    const chunk_end = std.math.add(u64, chunk_start, hdr_size) catch return error.ObjectHeaderTooLarge;
    if (chunk_end > ctx.eof) return error.TruncatedObjectHeader;

    var header = Header{
        .version = .v1,
        .file_offset = file_offset,
        .declared_message_count = declared,
        .messages_seen = 0,
        .symbol_table = null,
        .checksum_valid = null, // ponytail: v1 has no header checksum; integrity comes from message bounds
    };

    try scanV1Chunk(source, ctx, chunk_start, chunk_end, &header);
    try followContinuations(source, ctx, &header, scanV1Chunk);
    return header;
}

const Continuation = struct {
    offset: u64,
    length: u64,
    present: bool = false,
};

fn scanV1Chunk(
    source: anytype,
    ctx: wire.Context,
    chunk_start: u64,
    chunk_end: u64,
    header: *Header,
) !void {
    var reader = try codec.readerAt(source, chunk_start);

    // A tail shorter than a message prefix is free space, not truncation:
    // real files (e.g. run42's continuation) leave a few unused bytes that
    // the next structure's alignment proves are intentional.
    while (chunk_end - reader.position() >= 8) {
        if (header.messages_seen >= ctx.limits.header_messages) return error.TooManyMessages;

        const msg_type = try reader.readInt(u16, .little);
        const msg_size = try reader.readInt(u16, .little);
        _ = try reader.readByte(); // flags; ponytail: shared/constant bits ignored, payload skipped raw
        var reserved: [3]u8 = undefined;
        try reader.readInto(&reserved);
        if (!std.mem.eql(u8, &reserved, &[_]u8{ 0, 0, 0 })) return error.InvalidReservedField;

        const data_start = reader.position();
        const data_end = std.math.add(u64, data_start, msg_size) catch return error.ObjectHeaderTooLarge;
        if (data_end > chunk_end) return error.TruncatedObjectHeader;

        header.messages_seen += 1;

        switch (msg_type) {
            MSG_NIL => {},
            MSG_DATASPACE => {
                if (header.dataspace != null) return error.DuplicateDataspace;
                header.dataspace = .{ .offset = data_start, .len = msg_size };
            },
            MSG_DATATYPE => {
                if (header.datatype != null) return error.DuplicateDatatype;
                header.datatype = .{ .offset = data_start, .len = msg_size };
            },
            MSG_LAYOUT => {
                if (header.layout != null) return error.DuplicateLayout;
                header.layout = .{ .offset = data_start, .len = msg_size };
            },
            MSG_CONTINUATION => {
                if (header.hasContinuation()) return error.DuplicateContinuation;
                header.pending_continuation = try parseContinuation(source, ctx, data_start);
            },
            MSG_SYMTAB => {
                // ponytail: first SymTab wins; repeated group messages are corrupt, not multi-group.
                if (header.symbol_table == null) {
                    if (msg_size < 2 * @as(u16, ctx.widths.offset)) return error.TruncatedObjectHeader;
                    var mdec = try codec.readerAt(source, data_start);
                    const btree = try wire.readAddress(&mdec, ctx.widths.offset);
                    const heap = try wire.readAddress(&mdec, ctx.widths.offset);
                    header.symbol_table = .{ .btree_address = btree, .heap_address = heap };
                }
            },
            else => {},
        }

        try reader.seek(data_end);
    }
}

/// Parses a continuation payload into an absolute file range.
fn parseContinuation(source: anytype, ctx: wire.Context, data_start: u64) !Continuation {
    var dec = try codec.readerAt(source, data_start);
    const off = try wire.readAddress(&dec, ctx.widths.offset);
    const len = try wire.readLength(&dec, ctx.widths.length);
    const raw = off.raw() orelse return error.InvalidContinuation;
    return .{
        .offset = try ctx.resolveRaw(raw),
        .length = len,
        .present = true,
    };
}

/// Follows pending continuation chunks with one shared hop bound and one
/// shared bounds policy for both header versions.
// ponytail: hop cap is a DoS bound, not a spec limit.
fn followContinuations(source: anytype, ctx: wire.Context, header: *Header, comptime scan: anytype) !void {
    var hops: u8 = 0;
    while (header.hasContinuation()) : (hops += 1) {
        if (hops >= ctx.limits.continuation_hops) return error.TooManyContinuations;
        const cont = header.takeContinuation();
        if (cont.length == 0) return error.InvalidContinuation;
        const c_end = std.math.add(u64, cont.offset, cont.length) catch return error.ObjectHeaderTooLarge;
        if (c_end > ctx.eof) return error.TruncatedObjectHeader;
        try scan(source, ctx, cont.offset, c_end, header);
    }
}

fn decodeV2(source: anytype, ctx: wire.Context, file_offset: u64) !Header {
    var reader = try codec.readerAt(source, file_offset);
    try reader.expectBytes(&v2_signature);

    const version = try reader.readByte();
    if (version != 2) return error.UnsupportedObjectHeaderVersion;
    const flags = try reader.readByte();

    const chunk_width: u8 = switch (flags & 0x03) {
        0 => 1,
        1 => 2,
        2 => 4,
        3 => 8,
        else => unreachable,
    };
    const track_corder = (flags & 0x04) != 0;
    // ponytail: attribute B-tree / phase-change index presence is parsed, never traversed here.
    if ((flags & 0xC0) != 0) return error.UnsupportedObjectHeaderFlags;

    if ((flags & 0x20) != 0) try reader.skip(16); // timestamps: 4 x u32
    if ((flags & 0x10) != 0) try reader.skip(4); // attr phase-change thresholds: 2 x u16

    const chunk0_size = try reader.readVarUInt(chunk_width, .little);

    const msg_start = reader.position();
    const msg_end = std.math.add(u64, msg_start, chunk0_size) catch return error.ObjectHeaderTooLarge;
    if (msg_end > ctx.eof) return error.TruncatedObjectHeader;
    // Checksum occupies 4 bytes after the message region.
    if (msg_end + 4 > ctx.eof) return error.TruncatedObjectHeader;

    var header = Header{
        .version = .v2,
        .file_offset = file_offset,
        .declared_message_count = null, // ponytail: v2 has no total count; region end is the bound
        .messages_seen = 0,
        .symbol_table = null,
        .checksum_valid = null,
        .track_corder = track_corder,
    };

    try scanV2Chunk(source, ctx, msg_start, msg_end, &header);
    try followContinuations(source, ctx, &header, scanV2ContinuationChunk);

    // Checksums stream through a fixed scratch buffer, so headers of any size
    // verify without a proportional allocation.
    var scratch: [256]u8 = undefined;
    const total = (msg_end + 4) - file_offset;
    const computed = try checksum.range(source, file_offset, total - 4, &scratch);
    var stored_bytes: [4]u8 = undefined;
    try source.readAt(msg_end, &stored_bytes);
    const stored = std.mem.readInt(u32, &stored_bytes, .little);
    header.checksum_valid = (stored == computed);

    return header;
}

fn scanV2Chunk(
    source: anytype,
    ctx: wire.Context,
    chunk_start: u64,
    chunk_end: u64,
    header: *Header,
) !void {
    var reader = try codec.readerAt(source, chunk_start);
    const prefix_len: u64 = if (header.track_corder) 6 else 4;

    while (chunk_end - reader.position() >= prefix_len) {
        if (header.messages_seen >= ctx.limits.header_messages) return error.TooManyMessages;

        const msg_type = try reader.readByte();
        const msg_size = try reader.readInt(u16, .little);
        _ = try reader.readByte(); // flags; ponytail: shared/skip bits ignored, payload skipped raw
        if (header.track_corder) _ = try reader.readInt(u16, .little);

        const data_start = reader.position();
        const data_end = std.math.add(u64, data_start, msg_size) catch return error.ObjectHeaderTooLarge;
        if (data_end > chunk_end) return error.TruncatedObjectHeader;
        header.messages_seen += 1;

        if (msg_type == MSG_CONTINUATION) {
            if (header.hasContinuation()) return error.DuplicateContinuation;
            header.pending_continuation = try parseContinuation(source, ctx, data_start);
        }
        if (msg_type == link.MSG_INFO) {
            if (header.link_info != null) return error.DuplicateLinkInfo;
            header.link_info = try link.readLinkInfo(source, ctx, data_start, msg_size);
        }
        if (msg_type == link.MSG_LINK) {
            if (header.link_count >= link.max_compact_links or header.link_count >= ctx.limits.compact_links) return error.TooManyCompactLinks;
            header.link_slots[header.link_count] = .{ .offset = data_start, .len = msg_size };
            header.link_count += 1;
        }
        if (msg_type == MSG_DATASPACE) {
            if (header.dataspace != null) return error.DuplicateDataspace;
            header.dataspace = .{ .offset = data_start, .len = msg_size };
        }
        if (msg_type == MSG_DATATYPE) {
            if (header.datatype != null) return error.DuplicateDatatype;
            header.datatype = .{ .offset = data_start, .len = msg_size };
        }
        if (msg_type == MSG_LAYOUT) {
            if (header.layout != null) return error.DuplicateLayout;
            header.layout = .{ .offset = data_start, .len = msg_size };
        }

        try reader.seek(data_end);
    }
}

fn scanV2ContinuationChunk(
    source: anytype,
    ctx: wire.Context,
    chunk_start: u64,
    chunk_end: u64,
    header: *Header,
) !void {
    if (chunk_end - chunk_start < 4) return error.TruncatedObjectHeader;
    var sig: [4]u8 = undefined;
    try source.readAt(chunk_start, &sig);
    if (!std.mem.eql(u8, &sig, &v2_continuation_signature)) return error.InvalidContinuation;
    // ponytail: OCHK trailing checksum (when present) is not verified; framing only.
    try scanV2Chunk(source, ctx, chunk_start + 4, chunk_end, header);
}

// Pending continuation block; resolved to absolute file offsets at parse time.
pub const PendingContinuation = Continuation;

test "decodes the real v1 root header from test1.h5" {
    var file = [_]u8{0} ** 976;
    @memcpy(file[928..976], &test1RootHeader());
    const source = codec.SliceSource.init(&file);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    const header = try decode(&source, ctx, 928);
    try std.testing.expectEqual(Version.v1, header.version);
    try std.testing.expectEqual(@as(?u16, 2), header.declared_message_count);
    try std.testing.expect(header.symbol_table != null);
    try std.testing.expectEqual(@as(?u64, 384), header.symbol_table.?.btree_address.raw());
    try std.testing.expectEqual(@as(?u64, 96), header.symbol_table.?.heap_address.raw());
}

test "v1 continuation is followed with a hop bound" {
    var arena = [_]u8{0} ** 128;
    // Minimal header: 16-byte prefix, one continuation message pointing at 64.
    arena[0] = 1;
    arena[2] = 2; // continuation + target NIL
    arena[8] = 24; // first chunk holds exactly the continuation message
    // Message at 16: type 0x10, size 16, flags 0.
    arena[16] = 0x10;
    arena[18] = 16;
    // continuation payload at 24: btree-style addr 64 (offset_size 8) + len 32.
    arena[24] = 64;
    arena[32] = 32;
    // Target chunk at 64: single NIL filling 32 bytes.
    arena[64] = 0;
    arena[66] = 24; // nil size 24 -> 8 hdr + 24 = 32
    const source = codec.SliceSource.init(&arena);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    const header = try decode(&source, ctx, 0);
    try std.testing.expectEqual(@as(u32, 2), header.messages_seen);
}

test "v2 framing verifies checksum and skips unknown messages" {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..4], &v2_signature);
    buf[4] = 2;
    buf[5] = 0; // 1-byte chunk size, no optionals
    buf[6] = 12; // chunk0 = one 4-byte prefix + 8 payload bytes
    buf[7] = 0x06; // fake link-ish type
    buf[8] = 8;
    buf[9] = 0;
    buf[10] = 0;
    @memset(buf[11..19], 0xAB);
    const chk = checksum.metadata(buf[0..19]);
    std.mem.writeInt(u32, buf[19..23], chk, .little);
    const source = codec.SliceSource.init(buf[0..23]);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    const header = try decode(&source, ctx, 0);
    try std.testing.expectEqual(Version.v2, header.version);
    try std.testing.expectEqual(@as(?bool, true), header.checksum_valid);
    try std.testing.expectEqual(@as(u32, 1), header.messages_seen);
}

test "v2 tracked prefixes are 6 bytes (real run42 bytes)" {
    // First 48 bytes of run42's chunk: link-info (6 + 34) + group-info (6 + 2).
    // Under the old u32 assumption this errors with TruncatedObjectHeader.
    const bytes = [_]u8{
        0x02, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x0a, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
    };
    const source = codec.SliceSource.init(&bytes);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    var header = Header{
        .version = .v2,
        .file_offset = 0,
        .declared_message_count = null,
        .messages_seen = 0,
        .symbol_table = null,
        .checksum_valid = null,
        .track_corder = true,
    };
    try scanV2Chunk(&source, ctx, 0, bytes.len, &header);
    try std.testing.expectEqual(@as(u32, 2), header.messages_seen);
}

test "v2 bad checksum is reported, not fatal" {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..4], &v2_signature);
    buf[4] = 2;
    buf[5] = 0;
    buf[6] = 12;
    buf[7] = 0x06;
    buf[8] = 8;
    buf[9] = 0;
    buf[10] = 0;
    @memset(buf[11..19], 0xAB);
    std.mem.writeInt(u32, buf[19..23], 0xdeadbeef, .little);
    const source = codec.SliceSource.init(buf[0..23]);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    const header = try decode(&source, ctx, 0);
    try std.testing.expectEqual(@as(?bool, false), header.checksum_valid);
}

test "v2 dataset message ranges are located" {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..4], &v2_signature);
    buf[4] = 2;
    buf[5] = 0; // 1-byte chunk size, no optionals
    buf[6] = 36; // three 4-byte prefixes + 8 payload bytes each
    var pos: usize = 7;
    for ([_]u8{ MSG_DATASPACE, MSG_DATATYPE, MSG_LAYOUT }) |t| {
        buf[pos] = t;
        buf[pos + 1] = 8;
        buf[pos + 2] = 0;
        buf[pos + 3] = 0;
        @memset(buf[pos + 4 .. pos + 12], 0);
        pos += 12;
    }
    const chk = checksum.metadata(buf[0..pos]);
    std.mem.writeInt(u32, buf[pos..][0..4], chk, .little);
    pos += 4;
    const source = codec.SliceSource.init(buf[0..pos]);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    const header = try decode(&source, ctx, 0);
    try std.testing.expectEqual(@as(u64, 11), header.dataspace.?.offset);
    try std.testing.expectEqual(@as(u64, 23), header.datatype.?.offset);
    try std.testing.expectEqual(@as(u64, 35), header.layout.?.offset);
    try std.testing.expect(header.symbol_table == null);
    try std.testing.expect(header.link_info == null);
}

fn test1RootHeader() [48]u8 {
    return [_]u8{
        0x01, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x11, 0x00, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
}
