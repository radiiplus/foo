const std = @import("std");
var value: u64 = 0;
var ready: std.atomic.Value(u32) = .init(0);

fn write() void {
    _ = ready.fetchAdd(1, .monotonic);
    while (ready.load(.monotonic) < 2) std.atomic.spinLoopHint();
    for (0..10000) |_| value += 1;
}

pub fn main() !void {
    const first = try std.Thread.spawn(.{}, write, .{});
    const second = try std.Thread.spawn(.{}, write, .{});
    first.join();
    second.join();
    std.debug.print("{d}\n", .{value});
}
