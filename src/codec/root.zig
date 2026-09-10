//! Codec: HDF5-independent binary encoding/decoding primitives.
//!
//! The core codec is generic over random-access sources and sinks. This keeps
//! the parser independent from files, memory mapping, network storage, or any
//! particular std.Io implementation.

const std = @import("std");

const reader = @import("reader.zig");
const writer = @import("writer.zig");
const source = @import("source.zig");
const sink = @import("sink.zig");
const common = @import("common.zig");

pub const Reader = reader.Reader;
pub const Writer = writer.Writer;

pub const SliceSource = source.SliceSource;

pub const SliceSink = sink.SliceSink;
pub const OwnedSink = sink.OwnedSink;
pub const CountingSink = sink.CountingSink;

/// Convenience constructor for the common zero-copy in-memory reader.
pub fn sliceReader(data: []const u8) Reader(SliceSource) {
    return Reader(SliceSource).init(SliceSource.init(data));
}

/// Positioned reader over any random-access source.
pub fn readerAt(src: anytype, offset: u64) !Reader(@TypeOf(src.*)) {
    var r = Reader(@TypeOf(src.*)).init(src.*);
    try r.seek(offset);
    return r;
}

/// Convenience constructor for a writer backed by a caller-owned fixed buffer.
pub fn sliceWriter(data: []u8) Writer(SliceSink) {
    return Writer(SliceSink).init(SliceSink.init(data));
}

/// Convenience constructor for an allocator-backed writer.
pub fn ownedWriter(allocator: @import("std").mem.Allocator) Writer(OwnedSink) {
    return Writer(OwnedSink).init(OwnedSink.init(allocator));
}

/// Convenience constructor for a sizing pass. Every write is counted but no
/// bytes are stored.
pub fn countingWriter() Writer(CountingSink) {
    return Writer(CountingSink).init(.{});
}

test {
    _ = reader;
    _ = writer;
    _ = source;
    _ = sink;
    _ = common;
}

test "readerAt seeks to the requested offset" {
    const src = SliceSource.init(&[_]u8{ 10, 20, 30 });
    var r = try readerAt(&src, 1);
    try std.testing.expectEqual(@as(u8, 20), try r.readByte());
}
