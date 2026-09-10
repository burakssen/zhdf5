const codec = @import("../codec/root.zig");
const address = @import("../wire/address.zig");
const superblock = @import("superblock.zig");

pub const Superblock = superblock.Superblock;
pub const Address = address.Address;

/// Decode context: a random-access source pinned to a decoded superblock.
///
/// Bundles the three things every format reader needs (source, field widths,
/// base address) so call sites stop re-deriving `Reader(Source)` and
/// re-threading the `(source, superblock)` pair through every helper.
// ponytail: Ctx is boilerplate deletion, not a framework — no virtual dispatch, no stored reader.
pub fn Ctx(comptime Source: type) type {
    return struct {
        const Self = @This();

        source: Source,
        superblock: Superblock,

        pub fn init(source: Source, sb: Superblock) Self {
            return .{ .source = source, .superblock = sb };
        }

        pub fn len(self: *const Self) u64 {
            return self.source.len();
        }

        pub fn readAt(self: *const Self, offset: u64, destination: []u8) !void {
            try self.source.readAt(offset, destination);
        }

        pub fn readerAt(self: *const Self, offset: u64) !codec.Reader(Source) {
            var reader = codec.Reader(Source).init(self.source);
            try reader.seek(offset);
            return reader;
        }

        /// Resolves a base-relative file address to an absolute file offset.
        pub fn resolve(self: *const Self, addr: Address) !u64 {
            return self.superblock.resolve(addr);
        }

        /// Resolves an already-unwrapped address value.
        pub fn resolveRaw(self: *const Self, raw: u64) !u64 {
            return self.superblock.base_address.resolve(raw);
        }

        pub fn readAddress(self: *const Self, reader: anytype) !Address {
            return address.readAddress(reader, self.superblock.offset_size);
        }

        pub fn readLength(self: *const Self, reader: anytype) !u64 {
            return address.readLength(reader, self.superblock.length_size);
        }

        pub fn offsetSize(self: *const Self) u8 {
            return self.superblock.offset_size;
        }

        pub fn lengthSize(self: *const Self) u8 {
            return self.superblock.length_size;
        }

        /// B-tree degree for v1 group nodes. Errors on modern superblocks.
        pub fn groupNodeK(self: *const Self, level: u8) !u16 {
            return self.superblock.groupNodeK(level);
        }
    };
}

test "ctx resolves against the superblock base" {
    const std_testing = @import("std").testing;
    const testing = @import("testing.zig");
    const source = codec.SliceSource.init(&[_]u8{0} ** 64);
    var sb = testing.testSuperblock();
    sb.base_address = .{ .value = 512 };
    const ctx = Ctx(codec.SliceSource).init(source, sb);
    try std_testing.expectEqual(@as(u64, 560), try ctx.resolve(.{ .value = 48 }));
    try std_testing.expectEqual(@as(u16, 4), try ctx.groupNodeK(0));
    try std_testing.expectEqual(@as(u16, 16), try ctx.groupNodeK(2));
}
