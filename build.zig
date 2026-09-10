const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zhdf5_mod = b.addModule("zhdf5", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });

    const zhdf5_lib = b.addLibrary(.{
        .name = "zhdf5",
        .root_module = zhdf5_mod,
    });

    b.installArtifact(zhdf5_lib);

    const test_step = b.step("test", "Run zhdf5 tests");

    const zhdf5_test = b.addTest(.{ .root_module = zhdf5_mod });
    const test_cmd = b.addRunArtifact(zhdf5_test);
    test_step.dependOn(&test_cmd.step);

    const roundtrip = b.addExecutable(.{
        .name = "binary-roundtrip",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/roundtrip.zig"), .target = target, .optimize = optimize, .imports = &.{
            .{ .name = "zhdf5", .module = zhdf5_mod },
        } }),
    });

    const run_roundtrip = b.addRunArtifact(roundtrip);
    const roundtrip_step = b.step("run-binary", "Run the Phase 0 binary codec example");
    roundtrip_step.dependOn(&run_roundtrip.step);

    const inspect = b.addExecutable(.{
        .name = "inspect",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/inspect.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhdf5", .module = zhdf5_mod },
            },
        }),
    });

    const run_inspect = b.addRunArtifact(inspect);
    if (b.args) |args| run_inspect.addArgs(args);
    const run_step = b.step("run", "Inspect an HDF5 superblock");
    run_step.dependOn(&run_inspect.step);
}
