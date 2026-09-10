//! Adapters between hdf5-zig's minimal source/sink contracts and Zig std.Io.

const file_source = @import("file_source.zig");

pub const FileSource = file_source.FileSource;

test {
    _ = file_source;
}
