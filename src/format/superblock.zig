const std = @import("std");
const codec = @import("../codec/root.zig");
const address = @import("../wire/address.zig");
const checksum = @import("../wire/checksum.zig");
const signature = @import("signature.zig");

pub const Address = address.Address;

pub const Version = enum(u8) {
    v0 = 0,
    v1 = 1,
    v2 = 2,
    v3 = 3,
};

pub const RootSymbolTableEntry = struct {
    link_name_offset: u64,
    object_header_address: Address,
    cache_type: u32,
    scratch_pad: [16]u8,
};

pub const Legacy = struct {
    free_space_storage_version: u8,
    root_group_symbol_table_entry_version: u8,
    shared_header_message_version: u8,
    group_leaf_node_k: u16,
    group_internal_node_k: u16,
    indexed_storage_internal_node_k: ?u16,
    free_space_address: Address,
    driver_information_block_address: Address,
    root_symbol_table_entry: RootSymbolTableEntry,
};

pub const Modern = struct {
    superblock_extension_address: Address,
    checksum: u32,
    checksum_valid: bool,
};

pub const Details = union(enum) {
    legacy: Legacy,
    modern: Modern,
};

pub const Superblock = struct {
    signature_offset: u64,
    version: Version,
    offset_size: u8,
    length_size: u8,
    file_consistency_flags: u32,
    base_address: Address,
    end_of_file_address: Address,
    root_group_object_header_address: Address,
    details: Details,

    pub fn baseFileOffset(self: Superblock) !u64 {
        return self.base_address.raw() orelse error.UndefinedBaseAddress;
    }

    pub fn rootObjectHeaderFileOffset(self: Superblock) !u64 {
        return self.root_group_object_header_address.resolve(try self.baseFileOffset());
    }

    /// Resolves a base-relative file address to an absolute file offset.
    pub fn resolve(self: Superblock, addr: Address) !u64 {
        const raw = addr.raw() orelse return error.UndefinedAddress;
        return self.base_address.resolve(raw);
    }

    /// B-tree degree for v1 group nodes. Modern superblocks carry no K values.
    pub fn groupNodeK(self: Superblock, level: u8) !u16 {
        return switch (self.details) {
            .legacy => |legacy| if (level == 0) legacy.group_leaf_node_k else legacy.group_internal_node_k,
            .modern => error.NoGroupKForModernSuperblock,
        };
    }

    pub fn checksumValid(self: Superblock) ?bool {
        return switch (self.details) {
            .legacy => null,
            .modern => |modern| modern.checksum_valid,
        };
    }
};

/// Finds and decodes the HDF5 superblock from any Phase-0 random-access source.
pub fn decode(source: anytype) !Superblock {
    const signature_offset = try signature.find(source);
    return decodeAt(source, signature_offset);
}

pub fn decodeAt(source: anytype, signature_offset: u64) !Superblock {
    if (!try signature.matchesAt(source, signature_offset)) return error.InvalidHdf5Signature;

    const Source = @TypeOf(source.*);
    var reader = codec.Reader(Source).init(source.*);
    try reader.seek(signature_offset);
    try reader.expectBytes(&signature.bytes);

    const version_raw = try reader.readByte();
    const version: Version = switch (version_raw) {
        0 => .v0,
        1 => .v1,
        2 => .v2,
        3 => .v3,
        else => return error.UnsupportedSuperblockVersion,
    };

    return switch (version) {
        .v0, .v1 => decodeLegacy(&reader, signature_offset, version),
        .v2, .v3 => decodeModern(&reader, source, signature_offset, version),
    };
}

fn decodeLegacy(reader: anytype, signature_offset: u64, version: Version) !Superblock {
    const free_space_storage_version = try reader.readByte();
    const root_group_symbol_table_entry_version = try reader.readByte();
    try expectZero(try reader.readByte());
    const shared_header_message_version = try reader.readByte();
    const offset_size = try reader.readByte();
    const length_size = try reader.readByte();
    try validateWidths(offset_size, length_size);
    try expectZero(try reader.readByte());

    const group_leaf_node_k = try reader.readInt(u16, .little);
    const group_internal_node_k = try reader.readInt(u16, .little);
    const file_consistency_flags = try reader.readInt(u32, .little);

    const indexed_storage_internal_node_k: ?u16 = if (version == .v1) blk: {
        const value = try reader.readInt(u16, .little);
        try expectZero(try reader.readInt(u16, .little));
        break :blk value;
    } else null;

    const base_address = try address.readAddress(reader, offset_size);
    const free_space_address = try address.readAddress(reader, offset_size);
    const end_of_file_address = try address.readAddress(reader, offset_size);
    const driver_information_block_address = try address.readAddress(reader, offset_size);

    const link_name_offset = try address.readLength(reader, length_size);
    const root_object_header = try address.readAddress(reader, offset_size);
    const cache_type = try reader.readInt(u32, .little);
    try expectZero(try reader.readInt(u32, .little));
    var scratch_pad: [16]u8 = undefined;
    try reader.readInto(&scratch_pad);

    if (free_space_storage_version != 0) return error.UnsupportedFreeSpaceStorageVersion;
    if (root_group_symbol_table_entry_version != 0) return error.UnsupportedRootSymbolTableEntryVersion;
    if (shared_header_message_version != 0) return error.UnsupportedSharedHeaderMessageVersion;

    return .{
        .signature_offset = signature_offset,
        .version = version,
        .offset_size = offset_size,
        .length_size = length_size,
        .file_consistency_flags = file_consistency_flags,
        .base_address = base_address,
        .end_of_file_address = end_of_file_address,
        .root_group_object_header_address = root_object_header,
        .details = .{ .legacy = .{
            .free_space_storage_version = free_space_storage_version,
            .root_group_symbol_table_entry_version = root_group_symbol_table_entry_version,
            .shared_header_message_version = shared_header_message_version,
            .group_leaf_node_k = group_leaf_node_k,
            .group_internal_node_k = group_internal_node_k,
            .indexed_storage_internal_node_k = indexed_storage_internal_node_k,
            .free_space_address = free_space_address,
            .driver_information_block_address = driver_information_block_address,
            .root_symbol_table_entry = .{
                .link_name_offset = link_name_offset,
                .object_header_address = root_object_header,
                .cache_type = cache_type,
                .scratch_pad = scratch_pad,
            },
        } },
    };
}

fn decodeModern(reader: anytype, source: anytype, signature_offset: u64, version: Version) !Superblock {
    const offset_size = try reader.readByte();
    const length_size = try reader.readByte();
    try validateWidths(offset_size, length_size);
    const file_consistency_flags: u32 = try reader.readByte();

    const base_address = try address.readAddress(reader, offset_size);
    const superblock_extension_address = try address.readAddress(reader, offset_size);
    const end_of_file_address = try address.readAddress(reader, offset_size);
    const root_group_object_header_address = try address.readAddress(reader, offset_size);

    const checksum_offset = reader.position();
    const stored_checksum = try reader.readInt(u32, .little);
    const bytes_before_checksum_u64 = checksum_offset - signature_offset;
    if (bytes_before_checksum_u64 > std.math.maxInt(usize)) return error.SuperblockTooLarge;
    const bytes_before_checksum: usize = @intCast(bytes_before_checksum_u64);

    var stack_bytes: [128]u8 = undefined;
    if (bytes_before_checksum > stack_bytes.len) return error.SuperblockTooLarge;
    try source.readAt(signature_offset, stack_bytes[0..bytes_before_checksum]);
    const computed_checksum = checksum.metadata(stack_bytes[0..bytes_before_checksum]);

    return .{
        .signature_offset = signature_offset,
        .version = version,
        .offset_size = offset_size,
        .length_size = length_size,
        .file_consistency_flags = file_consistency_flags,
        .base_address = base_address,
        .end_of_file_address = end_of_file_address,
        .root_group_object_header_address = root_group_object_header_address,
        .details = .{ .modern = .{
            .superblock_extension_address = superblock_extension_address,
            .checksum = stored_checksum,
            .checksum_valid = stored_checksum == computed_checksum,
        } },
    };
}

fn validateWidths(offset_size: u8, length_size: u8) !void {
    if (offset_size == 0 or offset_size > 16) return error.UnsupportedOffsetSize;
    if (length_size == 0 or length_size > 16) return error.UnsupportedLengthSize;
}

fn expectZero(value: anytype) !void {
    if (value != 0) return error.InvalidReservedField;
}

test "decodes a real version 0 superblock" {
    const bytes = [_]u8{
        0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x08, 0x00,
        0x04, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x18, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x88, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xa8, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    const source = codec.SliceSource.init(&bytes);
    const superblock = try decode(&source);

    try std.testing.expectEqual(Version.v0, superblock.version);
    try std.testing.expectEqual(@as(u8, 8), superblock.offset_size);
    try std.testing.expectEqual(@as(u8, 8), superblock.length_size);
    try std.testing.expectEqual(@as(?u64, 0), superblock.base_address.raw());
    try std.testing.expectEqual(@as(?u64, 2072), superblock.end_of_file_address.raw());
    try std.testing.expectEqual(@as(?u64, 96), superblock.root_group_object_header_address.raw());
    try std.testing.expectEqual(@as(u64, 96), try superblock.rootObjectHeaderFileOffset());
    try std.testing.expectEqual(@as(?bool, null), superblock.checksumValid());
}

test "decodes and verifies a real version 3 superblock" {
    const bytes = [_]u8{
        0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a,
        0x03, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x18, 0x08, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x09, 0xbc, 0x6c, 0xfd,
    };
    const source = codec.SliceSource.init(&bytes);
    const superblock = try decode(&source);

    try std.testing.expectEqual(Version.v3, superblock.version);
    try std.testing.expectEqual(@as(?u64, 48), superblock.root_group_object_header_address.raw());
    try std.testing.expectEqual(@as(?bool, true), superblock.checksumValid());
    try std.testing.expect(superblock.details.modern.superblock_extension_address.isUndefined());
}

test "root object offset is resolved against a user-block base address" {
    var bytes = [_]u8{0} ** 560;
    const superblock_bytes = [_]u8{
        0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a,
        0x03, 0x08, 0x08, 0x00, 0x00, 0x02, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x18, 0x0a, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x53, 0x9d, 0x9a, 0x60,
    };
    @memcpy(bytes[512..560], &superblock_bytes);

    const source = codec.SliceSource.init(&bytes);
    const superblock = try decode(&source);
    try std.testing.expectEqual(@as(u64, 512), superblock.signature_offset);
    try std.testing.expectEqual(@as(?u64, 512), superblock.base_address.raw());
    try std.testing.expectEqual(@as(u64, 560), try superblock.rootObjectHeaderFileOffset());
    try std.testing.expectEqual(@as(?bool, true), superblock.checksumValid());
}

test "decodes a version 1 superblock" {
    // Version 1 is the legacy layout plus indexed-storage K + reserved u16.
    const bytes = [_]u8{
        0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x08, 0x08, 0x00,
        0x04, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x1c, 0x08, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xb0, 0x02, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    const source = codec.SliceSource.init(&bytes);
    const superblock = try decode(&source);

    try std.testing.expectEqual(Version.v1, superblock.version);
    try std.testing.expectEqual(@as(?u16, 32), superblock.details.legacy.indexed_storage_internal_node_k);
    try std.testing.expectEqual(@as(?u64, 100), superblock.root_group_object_header_address.raw());
}

test "decodes and verifies a real version 2 superblock" {
    const bytes = [_]u8{
        0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a,
        0x02, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x18, 0x08, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xb8, 0x1f, 0xad, 0xf8,
    };
    const source = codec.SliceSource.init(&bytes);
    const superblock = try decode(&source);

    try std.testing.expectEqual(Version.v2, superblock.version);
    try std.testing.expectEqual(@as(?bool, true), superblock.checksumValid());
}

test "bad modern checksum is reported without preventing inspection" {
    var bytes = [_]u8{
        0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a,
        0x03, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x18, 0x08, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x09, 0xbc, 0x6c, 0xfd,
    };
    bytes[20] = 0xfe;

    const source = codec.SliceSource.init(&bytes);
    const superblock = try decode(&source);
    try std.testing.expectEqual(@as(?bool, false), superblock.checksumValid());
}
