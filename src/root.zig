//! Native, dependency-free HDF5 implementation in Zig.

pub const codec = @import("codec/root.zig");
pub const io = @import("io/root.zig");

test {
    _ = codec;
    _ = io;
}
