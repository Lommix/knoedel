const std = @import("std");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;

pub fn build(b: *Build) void {
    _ = b.addModule("knoedel", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = .ReleaseFast,
    });

    // const test_step = b.step("test", "");
    // const test_mod = b.createModule(.{ .root_source_file = b.path("src/ecs_test.zig") });
    // const uts = b.addTest(.{ .name = "knoedel_test", .root_module = test_mod, .t });
    // const run_uts = b.addRunArtifact(uts);
    // test_step.dependOn(&run_uts.step);
}
