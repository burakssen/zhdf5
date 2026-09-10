//! Reader layer: high-level file operations. Depends downward on
//! format/wire/io only.

const file = @import("file.zig");

pub const File = file.File;
pub const OpenOptions = file.OpenOptions;

test {
    _ = file;
}
