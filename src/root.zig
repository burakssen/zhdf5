//! Native, dependency-free HDF5 implementation in Zig.

pub const codec = @import("codec/root.zig");
pub const wire = @import("wire/root.zig");
pub const format = @import("format/root.zig");
pub const io = @import("io/root.zig");
pub const reader = @import("reader/root.zig");

pub const File = reader.File;
pub const OpenOptions = reader.OpenOptions;
pub const Object = reader.Object;
pub const ObjectKind = reader.ObjectKind;
pub const Group = reader.Group;
pub const GroupEntry = reader.GroupEntry;

pub const Superblock = format.Superblock;
pub const Address = format.Address;
pub const ObjectHeader = format.ObjectHeader;
pub const GroupListing = format.GroupListing;
pub const LegacyGroupParams = format.LegacyGroupParams;

pub const decodeSuperblock = format.decodeSuperblock;
pub const decodeObjectHeader = format.decodeObjectHeader;
pub const listGroup = format.listGroup;
pub const listCompactLinks = format.listCompactLinks;
pub const listDenseLinks = format.listDenseLinks;

test {
    _ = codec;
    _ = wire;
    _ = format;
    _ = io;
    _ = reader;
}
