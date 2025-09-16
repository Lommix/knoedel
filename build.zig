const std = @import("std");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;

pub fn build(b: *Build) void {
    _ = b.addModule("knoedel", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = .ReleaseFast,
    });
}
