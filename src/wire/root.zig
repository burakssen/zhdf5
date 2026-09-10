//! Wire layer: file-format primitives shared by every decoder.
//!
//! Depends only on codec and io. Knows field widths, addresses, checksums,
//! and resource limits — but nothing about superblocks, headers, or groups.

const address = @import("address.zig");
const checksum = @import("checksum.zig");
const context = @import("context.zig");
const limits = @import("limits.zig");
const widths = @import("widths.zig");

pub const Address = address.Address;
pub const FileAddress = address.FileAddress;
pub const Context = context.Context;
pub const Limits = limits.Limits;
pub const Widths = widths.Widths;

pub const readAddress = address.readAddress;
pub const readLength = address.readLength;
pub const metadataChecksum = checksum.metadata;

test {
    _ = address;
    _ = checksum;
    _ = context;
    _ = limits;
    _ = widths;
}
