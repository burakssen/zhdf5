//! Centralized resource limits: every bound the decoders enforce on
//! untrusted input lives here instead of scattered module constants.
//!
//! Values below preserve current behavior exactly; only the location changes.

const std = @import("std");

pub const Limits = struct {
    /// Object-header continuation hops followed per header.
    continuation_hops: u8 = 8,
    /// Messages scanned per object header.
    header_messages: u32 = 4096,
    /// Compact link messages collected per v2 group header.
    compact_links: usize = 64,
    /// B-tree depth followed (v1 group trees and v2 indexes).
    btree_depth: u8 = 8,
    /// B-tree nodes visited per walk.
    btree_nodes: u32 = 4096,
    /// Largest single B-tree node buffered.
    node_bytes: u64 = 16 * 1024 * 1024,
    /// Largest local-heap data segment buffered.
    heap_data_bytes: u64 = 16 * 1024 * 1024,
    /// Longest fractal heap ID accepted.
    heap_id_len: u8 = 64,
    /// Largest heap data segment or block buffered.
    block_bytes: u64 = 64 * 1024 * 1024,

    pub const defaults: Limits = .{};
    pub const strict: Limits = .{
        .continuation_hops = 4,
        .header_messages = 1024,
        .compact_links = 16,
        .btree_depth = 4,
        .btree_nodes = 4096,
        .node_bytes = 1024 * 1024,
        .heap_data_bytes = 1024 * 1024,
        .heap_id_len = 16,
        .block_bytes = 16 * 1024 * 1024,
    };
};

test "limits carry the current bounds as defaults" {
    try std.testing.expectEqual(@as(u8, 8), Limits.defaults.continuation_hops);
    try std.testing.expectEqual(@as(u32, 4096), Limits.defaults.header_messages);
    try std.testing.expectEqual(@as(usize, 64), Limits.defaults.compact_links);
    try std.testing.expectEqual(@as(u8, 8), Limits.defaults.btree_depth);
    try std.testing.expectEqual(@as(u32, 4096), Limits.defaults.btree_nodes);
    try std.testing.expect(Limits.strict.node_bytes < Limits.defaults.node_bytes);
}
