//! Shared comptime helpers for the codec. Lives in a leaf module so
//! reader/writer can both use it without an import cycle through root.

const std = @import("std");

pub fn integerByteLen(comptime T: type, comptime ops: []const u8) comptime_int {
    return switch (@typeInfo(T)) {
        .int => |info| blk: {
            if (info.bits == 0 or info.bits % 8 != 0) {
                @compileError("codec integer types must have a non-zero, byte-aligned bit width: " ++ ops);
            }
            break :blk @divExact(info.bits, 8);
        },
        else => @compileError("these operations require an integer type: " ++ ops),
    };
}

pub fn floatByteLen(comptime T: type, comptime ops: []const u8) comptime_int {
    return switch (@typeInfo(T)) {
        .float => |info| blk: {
            if (info.bits == 0 or info.bits % 8 != 0) {
                @compileError("codec float types must have a non-zero, byte-aligned bit width: " ++ ops);
            }
            break :blk @divExact(info.bits, 8);
        },
        else => @compileError("these operations require a floating-point type: " ++ ops),
    };
}

pub fn checkedAddPosition(position: u64, amount: u64) !u64 {
    if (amount > std.math.maxInt(u64) - position) return error.PositionOverflow;
    return position + amount;
}
