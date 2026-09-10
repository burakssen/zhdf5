//! Reader layer: high-level file operations. Depends downward on
//! format/wire/io only.

const file = @import("file.zig");
const object = @import("object.zig");
const group = @import("group.zig");
const path = @import("path.zig");

pub const File = file.File;
pub const OpenOptions = file.OpenOptions;
pub const Object = object.Object;
pub const ObjectKind = object.Kind;
pub const Group = group.Group;
pub const GroupEntry = group.Entry;

pub const lookup = path.lookup;

test {
    _ = file;
    _ = object;
    _ = group;
    _ = path;
}
