//! Decode context: explicit file-format parameters shared by every decoder.
//!
//! Unlike the transitional format.Ctx, this carries no Superblock: widths,
//! base address, EOF, and limits are plain data, so no format subsystem needs
//! to know about superblocks.

const std = @import("std");
const address = @import("address.zig");
const limits = @import("limits.zig");
const widths = @import("widths.zig");

pub const FileAddress = address.FileAddress;
pub const Limits = limits.Limits;
pub const Widths = widths.Widths;

pub const Context = struct {
    widths: Widths,
    base_address: u64,
    eof: u64,
    limits: Limits,

    /// Resolves a base-relative file address to an absolute file offset.
    pub fn resolve(self: Context, addr: FileAddress) !u64 {
        const raw = addr.raw() orelse return error.UndefinedAddress;
        return self.resolveRaw(raw);
    }

    /// Resolves an already-unwrapped address value.
    pub fn resolveRaw(self: Context, raw: u64) !u64 {
        return std.math.add(u64, self.base_address, raw);
    }
};

test "context resolves against its base address" {
    const ctx = Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = 512,
        .eof = 15072,
        .limits = .defaults,
    };
    try std.testing.expectEqual(@as(u64, 560), try ctx.resolve(.{ .value = 48 }));
    try std.testing.expectEqual(@as(u64, 560), try ctx.resolveRaw(48));
    try std.testing.expectError(error.UndefinedAddress, ctx.resolve(.undefined_address));
    try std.testing.expectError(error.Overflow, (Context{
        .widths = .{ .offset = 8, .length = 8 },
        .base_address = std.math.maxInt(u64),
        .eof = std.math.maxInt(u64),
        .limits = .defaults,
    }).resolve(.{ .value = 1 }));
}
