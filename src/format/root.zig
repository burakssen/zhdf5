//! HDF5 on-disk format primitives.

pub const signature = @import("signature.zig");
pub const superblock = @import("superblock.zig");
pub const ctx = @import("ctx.zig");

pub const Address = @import("../wire/address.zig").Address;
pub const Superblock = superblock.Superblock;
pub const SuperblockVersion = superblock.Version;
pub const Ctx = ctx.Ctx;

pub const findSignature = signature.find;
pub const decodeSuperblock = superblock.decode;
pub const decodeSuperblockAt = superblock.decodeAt;

test {
    _ = signature;
    _ = superblock;
    _ = ctx;
}
