//! Test-only fixtures for format modules.
//!
//! Import inside `test` blocks so release builds never compile this file:
//!
//! ```zig
//! const testing = @import("testing.zig");
//! ```

const superblock = @import("superblock.zig");

/// Canonical v0 superblock: 8-byte offsets/lengths, zero base, the same
/// widths every format test needs without retyping the literal.
pub fn testSuperblock() superblock.Superblock {
    return .{
        .signature_offset = 0,
        .version = .v0,
        .offset_size = 8,
        .length_size = 8,
        .file_consistency_flags = 0,
        .base_address = .{ .value = 0 },
        .end_of_file_address = .{ .value = 15072 },
        .root_group_object_header_address = .{ .value = 928 },
        .details = .{ .legacy = .{
            .free_space_storage_version = 0,
            .root_group_symbol_table_entry_version = 0,
            .shared_header_message_version = 0,
            .group_leaf_node_k = 4,
            .group_internal_node_k = 16,
            .indexed_storage_internal_node_k = null,
            .free_space_address = .undefined_address,
            .driver_information_block_address = .undefined_address,
            .root_symbol_table_entry = .{
                .link_name_offset = 0,
                .object_header_address = .{ .value = 928 },
                .cache_type = 1,
                .scratch_pad = [_]u8{0} ** 16,
            },
        } },
    };
}
