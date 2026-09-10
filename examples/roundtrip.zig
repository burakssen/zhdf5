const std = @import("std");
const zhdf5 = @import("zhdf5");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var writer = zhdf5.codec.ownedWriter(allocator);

    // Reserve space for a length field, write a payload, then back-patch it.
    const length_offset = try writer.reserve(4);
    try writer.writeBytes("phase0");
    try writer.writeFloat(f32, 1.5, .little);
    try writer.patchInt(length_offset, u32, 10, .little);

    const encoded = writer.sink.bytes();

    var reader = zhdf5.codec.sliceReader(encoded);
    const payload_len = try reader.readInt(u32, .little);
    const text = try reader.view(6);
    const value = try reader.readFloat(f32, .little);

    std.debug.print(
        "length={d} text={s} value={d} bytes={d}\n",
        .{ payload_len, text, value, encoded.len },
    );
}
