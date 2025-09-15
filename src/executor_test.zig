const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const JobExecutor = @import("ecs.zig").JobExecutor;

test "executor" {
    var exe = JobExecutor(.{}).init(std.testing.allocator);
    try exe.start();

    var group = std.Thread.WaitGroup{};
    for (0..32) |_| try exe.run(&group, doStuff, .{1});
    group.wait();

    group.reset();
    for (0..32) |_| try exe.run(&group, doStuff, .{2});
    group.wait();

    group.reset();
    for (0..32) |_| try exe.run(&group, doStuff, .{3});
    group.wait();
}

fn doStuff(num: u32) void {
    std.debug.print("Hello {d} \n", .{num});
    std.Thread.sleep(10000);
}
