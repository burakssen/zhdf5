//! Native, dependency-free HDF5 implementation in Zig.

pub const codec = @import("codec/root.zig");
pub const wire = @import("wire/root.zig");
pub const format = @import("format/root.zig");
pub const io = @import("io/root.zig");

pub const Superblock = format.Superblock;
pub const Address = format.Address;

pub const decodeSuperblock = format.decodeSuperblock;

test {
    _ = codec;
    _ = wire;
    _ = format;
    _ = io;
}
