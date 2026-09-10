//! File-format field widths: byte counts for offsets and lengths.
//!
//! Widths come from the superblock and parameterize every address/length
//! field on disk. Values up to 16 are accepted as long as encoded values fit
//! the host u64; use `validate` at decode time.

const std = @import("std");

pub const Widths = struct {
    offset: u8,
    length: u8,

    pub fn validate(self: Widths) !void {
        if (self.offset == 0 or self.offset > 16) return error.UnsupportedOffsetWidth;
        if (self.length == 0 or self.length > 16) return error.UnsupportedLengthWidth;
    }
};

test "widths accept the full 1..16 range" {
    try (Widths{ .offset = 8, .length = 8 }).validate();
    try (Widths{ .offset = 16, .length = 16 }).validate();
    try std.testing.expectError(error.UnsupportedOffsetWidth, (Widths{ .offset = 0, .length = 8 }).validate());
    try std.testing.expectError(error.UnsupportedOffsetWidth, (Widths{ .offset = 17, .length = 8 }).validate());
    try std.testing.expectError(error.UnsupportedLengthWidth, (Widths{ .offset = 8, .length = 0 }).validate());
    try std.testing.expectError(error.UnsupportedLengthWidth, (Widths{ .offset = 8, .length = 17 }).validate());
}
