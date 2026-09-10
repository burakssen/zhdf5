//! HDF5 on-disk format primitives.

pub const signature = @import("signature.zig");
pub const superblock = @import("superblock.zig");
pub const object_header = @import("object_header.zig");
pub const symbol_table = @import("symbol_table.zig");
pub const link = @import("link.zig");
pub const fheap = @import("fheap.zig");
pub const btree2 = @import("btree2.zig");

pub const Address = @import("../wire/address.zig").Address;
pub const Superblock = superblock.Superblock;
pub const SuperblockVersion = superblock.Version;
pub const ObjectHeader = object_header.Header;
pub const GroupListing = symbol_table.GroupListing;
pub const LegacyGroupParams = symbol_table.LegacyGroupParams;

pub const findSignature = signature.find;
pub const decodeSuperblock = superblock.decode;
pub const decodeSuperblockAt = superblock.decodeAt;
pub const decodeObjectHeader = object_header.decode;
pub const listGroup = symbol_table.listGroup;
pub const listCompactLinks = link.listCompact;
pub const listDenseLinks = link.listDense;

test {
    _ = signature;
    _ = superblock;
    _ = object_header;
    _ = symbol_table;
    _ = link;
    _ = fheap;
    _ = btree2;
}
