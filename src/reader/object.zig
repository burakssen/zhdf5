//! Shared object-header handle: groups and datasets open through this so
//! header framing is decoded once, not once per view.

const format = @import("../format/root.zig");
const file_mod = @import("file.zig");

pub const Kind = enum {
    group,
    dataset,
    unknown,
};

pub const Object = struct {
    file: *file_mod.File,
    address: format.Address,
    header: format.ObjectHeader,

    pub fn open(file: *file_mod.File, address: format.Address) !Object {
        const off = try file.ctx.resolve(address);
        const header = try format.decodeObjectHeader(&file.source, file.ctx, off);
        return .{ .file = file, .address = address, .header = header };
    }

    pub fn kind(self: *const Object) Kind {
        if (self.header.symbol_table != null or
            self.header.link_info != null or
            self.header.link_count > 0) return .group;
        if (self.header.dataspace != null or
            self.header.datatype != null or
            self.header.layout != null) return .dataset;
        return .unknown;
    }
};
