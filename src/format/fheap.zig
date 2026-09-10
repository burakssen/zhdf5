const std = @import("std");
const codec = @import("../codec/root.zig");
const address = @import("../wire/address.zig");
const checksum = @import("../wire/checksum.zig");
const wire = @import("../wire/root.zig");

pub const Address = address.Address;

pub const header_signature = [4]u8{ 'F', 'R', 'H', 'P' };
pub const direct_signature = [4]u8{ 'F', 'H', 'D', 'B' };
pub const indirect_signature = [4]u8{ 'F', 'H', 'I', 'B' };

const max_header_stack: usize = 512;

pub const Heap = struct {
    root_block: u64,
    block_size: u64,
    max_direct_size: u64,
    id_len: u8,
    off_size: u8,
    len_size: u8,
    heap_off_size: u8,
    checksum_valid: bool,
    indirect: bool = false,
    table: u64 = 0,
    table_rows: u16 = 0,
    table_width: u16 = 0,
};

/// Opens a fractal heap: parses the header, resolves the root block (direct
/// or single-level indirect), and verifies header + table checksums plus the
/// root direct block when it is the only block (reported, not fatal).
// ponytail: managed objects only — huge/tiny objects, filtered heaps, and
// multi-level indirect heaps are explicit errors, not silent gaps.
pub fn open(source: anytype, ctx: wire.Context, heap_address: Address, allocator: std.mem.Allocator) !Heap {
    const abs = try ctx.resolve(heap_address);
    var dec = try codec.readerAt(source, abs);
    try dec.expectBytes(&header_signature);

    if (try dec.readByte() != 0) return error.UnsupportedHeapVersion;
    const id_len = try dec.readInt(u16, .little);
    if (id_len == 0 or id_len > ctx.limits.heap_id_len) return error.UnsupportedHeapIdLength;
    if (try dec.readInt(u16, .little) != 0) return error.FilteredHeapUnsupported;

    const heap_flags = try dec.readByte();
    if (heap_flags & ~@as(u8, 0x03) != 0) return error.InvalidHeapFlags;
    const checksum_blocks = (heap_flags & 0x02) != 0;
    // ponytail: huge-id wrapping only affects huge objects, which this reader never touches.
    const max_man_size = try dec.readInt(u32, .little);

    _ = try wire.readLength(&dec, ctx.widths.length); // huge_next_id
    _ = try wire.readAddress(&dec, ctx.widths.offset); // huge btree
    _ = try wire.readLength(&dec, ctx.widths.length); // total_man_free
    _ = try wire.readAddress(&dec, ctx.widths.offset); // free-space header
    _ = try wire.readLength(&dec, ctx.widths.length); // man_size
    _ = try wire.readLength(&dec, ctx.widths.length); // man_alloc_size
    _ = try wire.readLength(&dec, ctx.widths.length); // man_iter_off
    _ = try wire.readLength(&dec, ctx.widths.length); // man_nobjs
    _ = try wire.readLength(&dec, ctx.widths.length); // huge_size
    _ = try wire.readLength(&dec, ctx.widths.length); // huge_nobjs
    _ = try wire.readLength(&dec, ctx.widths.length); // tiny_size
    if (try wire.readLength(&dec, ctx.widths.length) != 0) return error.TinyObjectsUnsupported;

    const table_width = try dec.readInt(u16, .little);
    if (table_width == 0) return error.CorruptHeap;
    const start_block_size = try wire.readLength(&dec, ctx.widths.length);
    if (start_block_size == 0 or start_block_size > ctx.limits.block_bytes) return error.CorruptHeap;
    const max_direct_size = try wire.readLength(&dec, ctx.widths.length);
    const max_index = try dec.readInt(u16, .little);
    // Block offsets address the whole heap (2^max_index bytes); heap IDs
    // carry their own offset width, and the two agree on consistent files.
    const heap_off_size: u8 = if (max_index == 0) 1 else if (max_index > 64) return error.CorruptHeap else @intCast((max_index - 1) / 8 + 1);
    _ = try dec.readInt(u16, .little); // start_root_rows
    const table_addr = try wire.readAddress(&dec, ctx.widths.offset);
    const curr_root_rows = try dec.readInt(u16, .little);

    const hdr_len = dec.position() - abs;
    const stored = try dec.readInt(u32, .little);
    var checksum_valid = true;
    if (hdr_len <= max_header_stack) {
        var stack: [max_header_stack]u8 = undefined;
        const n: usize = @intCast(hdr_len);
        try source.readAt(abs, stack[0..n]);
        checksum_valid = (checksum.metadata(stack[0..n]) == stored);
    } else checksum_valid = false;

    const len_size = bytesFor(max_man_size);
    const off_size: u8 = @intCast(id_len - 1 - len_size);
    if (off_size == 0 or off_size > 8) return error.CorruptHeapIdLayout;

    var heap = Heap{
        .root_block = 0,
        .block_size = start_block_size,
        .max_direct_size = max_direct_size,
        .id_len = @intCast(id_len),
        .off_size = off_size,
        .len_size = len_size,
        .heap_off_size = heap_off_size,
        .checksum_valid = checksum_valid,
    };

    if (curr_root_rows == 0) {
        const raw = table_addr.raw() orelse return error.HeapHasNoRootBlock;
        const root_block = try ctx.resolveRaw(raw);
        const block_end = std.math.add(u64, root_block, start_block_size) catch return error.HeapTooLarge;
        if (block_end > ctx.eof) return error.TruncatedHeap;
        heap.root_block = root_block;
        try verifyDirectBlock(source, ctx, &heap, root_block, abs, checksum_blocks, allocator);
        return heap;
    }

    // Single-level indirect root: children are direct blocks; deeper nesting
    // is rejected below in locateBlock.
    const traw = table_addr.raw() orelse return error.HeapHasNoRootBlock;
    const table = try ctx.resolveRaw(traw);
    const entries: u64 = @as(u64, curr_root_rows) * table_width;
    // Indirect prefix: magic+ver+heap address+block offset. Block offsets
    // share the heap ID offset width: both address any heap offset.
    const addr_size: u64 = ctx.widths.offset;
    const entry_bytes = std.math.mul(u64, entries, addr_size) catch return error.HeapTooLarge;
    const table_size = std.math.add(u64, 5 + addr_size + heap_off_size + entry_bytes, 4) catch return error.HeapTooLarge;
    const table_end = std.math.add(u64, table, table_size) catch return error.HeapTooLarge;
    if (table_end > ctx.eof) return error.TruncatedHeap;
    if (table_size > ctx.limits.block_bytes) return error.HeapTooLarge;

    const tn: usize = @intCast(table_size);
    const tbuf = try allocator.alloc(u8, tn);
    defer allocator.free(tbuf);
    try source.readAt(table, tbuf);
    if (!std.mem.eql(u8, tbuf[0..4], &indirect_signature)) return error.BadBlockSignature;
    if (tbuf[4] != 0) return error.UnsupportedBlockVersion;
    var tdec = codec.sliceReader(tbuf[5..]);
    const table_heap = try wire.readAddress(&tdec, ctx.widths.offset);
    if (try ctx.resolve(table_heap) != abs) return error.BlockHeapMismatch;
    // The root indirect block always starts at heap offset zero.
    const off_at: usize = 5 + ctx.widths.offset;
    if (off_at + heap_off_size > tn) return error.CorruptBlock;
    var block_off: u64 = 0;
    for (tbuf[off_at..][0..heap_off_size], 0..) |b, i| {
        block_off |= @as(u64, b) << @intCast(i * 8);
    }
    if (block_off != 0) return error.CorruptBlock;
    const stored_table = std.mem.readInt(u32, tbuf[tn - 4 ..][0..4], .little);
    @memset(tbuf[tn - 4 ..][0..4], 0);
    heap.checksum_valid = checksum_valid and (checksum.metadata(tbuf[0 .. tn - 4]) == stored_table);

    heap.indirect = true;
    heap.table = table;
    heap.table_rows = curr_root_rows;
    heap.table_width = table_width;
    return heap;
}

/// Validates a direct block's magic and, when enabled, its trailing checksum.
fn verifyDirectBlock(
    source: anytype,
    ctx: wire.Context,
    heap: *Heap,
    root_block: u64,
    heap_abs: u64,
    checksum_blocks: bool,
    allocator: std.mem.Allocator,
) !void {
    // Block magic is always validated; the full checksum only when enabled.
    const prefix_len: usize = 5 + ctx.widths.offset;
    var prefix: [21]u8 = undefined;
    if (prefix_len > prefix.len) return error.CorruptBlock;
    try source.readAt(root_block, prefix[0..prefix_len]);
    var pdec = codec.sliceReader(prefix[0..prefix_len]);
    try pdec.expectBytes(&direct_signature);
    if (try pdec.readByte() != 0) return error.UnsupportedBlockVersion;
    const block_heap = try wire.readAddress(&pdec, ctx.widths.offset);
    if (try ctx.resolve(block_heap) != heap_abs) return error.BlockHeapMismatch;

    if (checksum_blocks) {
        const n: usize = @intCast(heap.block_size);
        const block = try allocator.alloc(u8, n);
        defer allocator.free(block);
        try source.readAt(root_block, block);
        // Checksum sits at the end of the block prefix: magic+ver+checksum+addr+offset.
        const field_at: usize = 9 + ctx.widths.offset + heap.off_size - 4;
        if (field_at + 4 > block.len) return error.CorruptBlock;
        const stored_block = std.mem.readInt(u32, block[field_at..][0..4], .little);
        @memset(block[field_at..][0..4], 0);
        heap.checksum_valid = heap.checksum_valid and (checksum.metadata(block) == stored_block);
    }
}

/// Reads a managed object by heap ID into owned memory.
pub fn readManaged(source: anytype, ctx: wire.Context, heap: Heap, id: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (id.len != heap.id_len) return error.CorruptHeapId;
    if (id[0] != 0) return error.HugeOrTinyUnsupported; // ponytail: managed objects only.
    var off: u64 = 0;
    for (id[1..][0..heap.off_size], 0..) |b, i| {
        off |= @as(u64, b) << @intCast(i * 8);
    }
    var len: u64 = 0;
    for (id[1 + heap.off_size ..][0..heap.len_size], 0..) |b, i| {
        len |= @as(u64, b) << @intCast(i * 8);
    }
    if (len == 0) return error.CorruptHeapId;

    const loc = try locateBlock(source, ctx, heap, off);
    const abs_off = std.math.add(u64, loc.base, loc.inner) catch return error.HeapTooLarge;
    const end = std.math.add(u64, abs_off, len) catch return error.HeapTooLarge;
    if (end > loc.base + loc.size or end > ctx.eof) return error.TruncatedHeapObject;

    const buf = try allocator.alloc(u8, @intCast(len));
    errdefer allocator.free(buf);
    try source.readAt(abs_off, buf);
    return buf;
}

const BlockLoc = struct {
    base: u64,
    inner: u64,
    size: u64,
};

/// Maps a heap offset to its direct block via the doubling table: row 0
/// holds `width` blocks of `start_block_size`, and row r >= 1 holds `width`
/// blocks of `start_block_size * 2^(r-1)` (the doubling lags one row, per
/// H5HF__dtable_init). Rows past the direct range address indirect children
/// and are rejected below.
// ponytail: multi-level indirect heaps are an explicit error; single-level
// roots cover ~2MB of links.
fn locateBlock(source: anytype, ctx: wire.Context, heap: Heap, off: u64) !BlockLoc {
    if (!heap.indirect) {
        return .{ .base = heap.root_block, .inner = off, .size = heap.block_size };
    }

    const width: u64 = heap.table_width;
    const first_span = std.math.mul(u64, width, heap.block_size) catch return error.HeapTooLarge;
    if (off < first_span) {
        if (heap.block_size > heap.max_direct_size) return error.TooDeepHeap;
        return locateInRow(source, ctx, heap, 0, off, heap.block_size);
    }

    var row_off = first_span;
    var bsize = heap.block_size; // row 1 reuses the start size; doubling starts after it.
    var row: u16 = 1;
    while (true) {
        if (row >= heap.table_rows) return error.TruncatedHeapObject;
        if (bsize > heap.max_direct_size) return error.TooDeepHeap;
        const span = std.math.mul(u64, width, bsize) catch return error.HeapTooLarge;
        const next = std.math.add(u64, row_off, span) catch return error.HeapTooLarge;
        if (off < next) break;
        row_off = next;
        row += 1;
        bsize = std.math.mul(u64, bsize, 2) catch return error.TooDeepHeap;
    }
    return locateInRow(source, ctx, heap, row, off - row_off, bsize);
}

/// Resolves one row-relative offset to a child block address.
fn locateInRow(source: anytype, ctx: wire.Context, heap: Heap, row: u16, rel: u64, bsize: u64) !BlockLoc {
    const width: u64 = heap.table_width;
    const col = rel / bsize;
    const inner = rel % bsize;
    const addr_size: u64 = ctx.widths.offset;
    const slot = std.math.mul(u64, @as(u64, row) * width + col, addr_size) catch return error.HeapTooLarge;
    const entry_at = std.math.add(u64, heap.table, 5 + addr_size + heap.heap_off_size + slot) catch return error.HeapTooLarge;
    var addr_bytes: [16]u8 = undefined;
    if (ctx.widths.offset > addr_bytes.len) return error.UnsupportedOffsetSize;
    if (entry_at + ctx.widths.offset > ctx.eof) return error.TruncatedHeap;
    try source.readAt(entry_at, addr_bytes[0..ctx.widths.offset]);
    var dec = codec.sliceReader(addr_bytes[0..ctx.widths.offset]);
    const child = try wire.readAddress(&dec, ctx.widths.offset);
    const raw = child.raw() orelse return error.CorruptHeapId;
    return .{ .base = try ctx.resolveRaw(raw), .inner = inner, .size = bsize };
}

fn bytesFor(value: u32) u8 {
    if (value <= std.math.maxInt(u8)) return 1;
    if (value <= std.math.maxInt(u16)) return 2;
    if (value <= std.math.maxInt(u32)) return 4;
    return 8;
}

test "opens a minimal heap and reads a managed object" {
    // Header: FRHP ver0 id_len=4 filter=0 flags=0 max_man=200, empty counters,
    // table width=1 start=64 ... root direct at 256.
    var hdr: [160]u8 = undefined;
    var pos: usize = 0;
    @memcpy(hdr[pos..][0..4], "FRHP");
    pos += 4;
    hdr[pos] = 0;
    pos += 1; // version
    std.mem.writeInt(u16, hdr[pos..][0..2], 4, .little);
    pos += 2; // id_len
    std.mem.writeInt(u16, hdr[pos..][0..2], 0, .little);
    pos += 2; // filter_len
    hdr[pos] = 0;
    pos += 1; // flags
    std.mem.writeInt(u32, hdr[pos..][0..4], 200, .little);
    pos += 4; // max_man_size
    @memset(hdr[pos..][0..96], 0);
    pos += 96; // huge/counters/tiny area (10 lens + 2 addrs at width 8)
    std.mem.writeInt(u16, hdr[pos..][0..2], 1, .little);
    pos += 2; // table width
    std.mem.writeInt(u64, hdr[pos..][0..8], 64, .little);
    pos += 8; // start_block_size
    std.mem.writeInt(u64, hdr[pos..][0..8], 1024, .little);
    pos += 8; // max_direct_size
    std.mem.writeInt(u16, hdr[pos..][0..2], 32, .little);
    pos += 2; // max_index
    std.mem.writeInt(u16, hdr[pos..][0..2], 0, .little);
    pos += 2; // start_root_rows
    std.mem.writeInt(u64, hdr[pos..][0..8], 256, .little);
    pos += 8; // table_addr
    std.mem.writeInt(u16, hdr[pos..][0..2], 0, .little);
    pos += 2; // curr_root_rows
    const chk = @import("../wire/checksum.zig").metadata(hdr[0..pos]);
    std.mem.writeInt(u32, hdr[pos..][0..4], chk, .little);
    const hdr_len = pos + 4;

    // Direct block at 256, size 64: FHDB ver0 heap_addr=0, object at +16.
    var file = [_]u8{0} ** 512;
    @memcpy(file[0..hdr_len], hdr[0..hdr_len]);
    @memcpy(file[256..260], "FHDB");
    file[260] = 0;
    std.mem.writeInt(u64, file[261..269], 0, .little); // heap at 0
    @memcpy(file[272..277], "hello");

    const source = codec.SliceSource.init(&file);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    const heap = try open(&source, ctx, .{ .value = 0 }, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 256), heap.root_block);
    try std.testing.expect(heap.checksum_valid);

    const obj = try readManaged(&source, ctx, heap, &[_]u8{ 0, 16, 0, 5 }, std.testing.allocator);
    defer std.testing.allocator.free(obj);
    try std.testing.expectEqualStrings("hello", obj);
}

test "heap rejects filtered, tiny, indirect, and non-managed ids" {
    var hdr: [160]u8 = undefined;
    var pos: usize = 0;
    @memcpy(hdr[pos..][0..4], "FRHP");
    pos += 4;
    hdr[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, hdr[pos..][0..2], 4, .little);
    pos += 2;
    std.mem.writeInt(u16, hdr[pos..][0..2], 0, .little);
    pos += 2;
    hdr[pos] = 0;
    pos += 1;
    std.mem.writeInt(u32, hdr[pos..][0..4], 200, .little);
    pos += 4;
    @memset(hdr[pos..][0..96], 0);
    pos += 96; // huge/counters/tiny area (10 lens + 2 addrs at width 8)
    std.mem.writeInt(u16, hdr[pos..][0..2], 1, .little);
    pos += 2;
    std.mem.writeInt(u64, hdr[pos..][0..8], 64, .little);
    pos += 8;
    std.mem.writeInt(u64, hdr[pos..][0..8], 1024, .little);
    pos += 8;
    std.mem.writeInt(u16, hdr[pos..][0..2], 32, .little);
    pos += 2;
    std.mem.writeInt(u16, hdr[pos..][0..2], 0, .little);
    pos += 2;
    std.mem.writeInt(u64, hdr[pos..][0..8], 256, .little);
    pos += 8;
    std.mem.writeInt(u16, hdr[pos..][0..2], 0, .little);
    pos += 2;
    const chk = @import("../wire/checksum.zig").metadata(hdr[0..pos]);
    std.mem.writeInt(u32, hdr[pos..][0..4], chk, .little);
    const hdr_len = pos + 4;

    var file = [_]u8{0} ** 512;
    @memcpy(file[0..hdr_len], hdr[0..hdr_len]);
    @memcpy(file[256..260], "FHDB");
    const source = codec.SliceSource.init(&file);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    const heap = try open(&source, ctx, .{ .value = 0 }, std.testing.allocator);

    // Non-managed id flags rejected.
    try std.testing.expectError(
        error.HugeOrTinyUnsupported,
        readManaged(&source, ctx, heap, &[_]u8{ 1, 16, 0, 5 }, std.testing.allocator),
    );
    // Wrong id length rejected.
    try std.testing.expectError(
        error.CorruptHeapId,
        readManaged(&source, ctx, heap, &[_]u8{ 0, 16, 0 }, std.testing.allocator),
    );
    // Out-of-block read rejected.
    try std.testing.expectError(
        error.TruncatedHeapObject,
        readManaged(&source, ctx, heap, &[_]u8{ 0, 200, 0, 5 }, std.testing.allocator),
    );
}

test "indirect root resolves objects through the doubling table" {
    // Header: id_len=4, 1 root row of width 2, table at 256, start block 32.
    var hdr: [192]u8 = undefined;
    var pos: usize = 0;
    @memcpy(hdr[pos..][0..4], "FRHP");
    pos += 4;
    hdr[pos] = 0;
    pos += 1;
    std.mem.writeInt(u16, hdr[pos..][0..2], 4, .little);
    pos += 2;
    std.mem.writeInt(u16, hdr[pos..][0..2], 0, .little);
    pos += 2;
    hdr[pos] = 0;
    pos += 1;
    std.mem.writeInt(u32, hdr[pos..][0..4], 200, .little);
    pos += 4;
    @memset(hdr[pos..][0..96], 0);
    pos += 96;
    std.mem.writeInt(u16, hdr[pos..][0..2], 2, .little);
    pos += 2; // width
    std.mem.writeInt(u64, hdr[pos..][0..8], 32, .little);
    pos += 8; // start_block_size
    std.mem.writeInt(u64, hdr[pos..][0..8], 32, .little);
    pos += 8; // max_direct_size: row 0 only; row 1 exceeds it
    std.mem.writeInt(u16, hdr[pos..][0..2], 32, .little);
    pos += 2; // max_index: 4-byte block offsets (ids stay 2-byte by design)
    std.mem.writeInt(u16, hdr[pos..][0..2], 0, .little);
    pos += 2;
    std.mem.writeInt(u64, hdr[pos..][0..8], 256, .little);
    pos += 8; // table_addr
    std.mem.writeInt(u16, hdr[pos..][0..2], 3, .little);
    pos += 2; // curr_root_rows
    const chk = @import("../wire/checksum.zig").metadata(hdr[0..pos]);
    std.mem.writeInt(u32, hdr[pos..][0..4], chk, .little);
    const hdr_len = pos + 4;

    var file = [_]u8{0} ** 512;
    @memcpy(file[0..hdr_len], hdr[0..hdr_len]);
    // Indirect table at 256: FHIB + heap 0 + zero block_off + 6 children.
    @memcpy(file[256..260], "FHIB");
    file[260] = 0;
    std.mem.writeInt(u64, file[261..269], 0, .little);
    @memset(file[269..273], 0);
    std.mem.writeInt(u64, file[273..281], 384, .little); // child 0
    @memset(file[281..321], 0xff); // remaining children undefined
    const tchk = @import("../wire/checksum.zig").metadata(file[256..321]);
    std.mem.writeInt(u32, file[321..325], tchk, .little);
    // Direct child at 384 with object at +10 (past the table checksum).
    @memcpy(file[384..388], "FHDB");
    file[388] = 0;
    std.mem.writeInt(u64, file[389..397], 0, .little);
    @memcpy(file[394..399], "hello");

    const source = codec.SliceSource.init(&file);
    const ctx = wire.Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 0,
        .eof = source.len(),
        .limits = .defaults,
    };
    const heap = try open(&source, ctx, .{ .value = 0 }, std.testing.allocator);
    try std.testing.expect(heap.indirect);
    try std.testing.expect(heap.checksum_valid);

    const obj = try readManaged(&source, ctx, heap, &[_]u8{ 0, 10, 0, 5 }, std.testing.allocator);
    defer std.testing.allocator.free(obj);
    try std.testing.expectEqualStrings("hello", obj);

    // Undefined child entry reads as a corrupt id.
    try std.testing.expectError(
        error.CorruptHeapId,
        readManaged(&source, ctx, heap, &[_]u8{ 0, 40, 0, 5 }, std.testing.allocator),
    );
    // Offsets past the direct range refuse multi-level descent.
    try std.testing.expectError(
        error.TooDeepHeap,
        readManaged(&source, ctx, heap, &[_]u8{ 0, 200, 0, 1 }, std.testing.allocator),
    );
}
