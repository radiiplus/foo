const std = @import("std");
const storage = @import("storage.zig");
pub const Stream = struct { channel: enum { input, output, report } };
var incoming: Stream = .{ .channel = .input };
var outgoing: Stream = .{ .channel = .output };
var diagnostic: Stream = .{ .channel = .report };
var threaded: std.Io.Threaded = undefined;
var started = false;
fn io() std.Io {
    if (!started) {
        threaded = .init(std.heap.page_allocator, .{});
        started = true;
    }
    return threaded.io();
}
fn valid(value: *Stream) !void {
    if (value != &incoming and value != &outgoing and value != &diagnostic) return error.UnknownStream;
}
pub fn input() *Stream {
    return &incoming;
}
pub fn output() *Stream {
    return &outgoing;
}
pub fn report() *Stream {
    return &diagnostic;
}
pub fn write(value: *Stream, content: []const u8) !void {
    try valid(value);
    if (value.channel == .input) return error.ReadOnly;
    const file = if (value.channel == .output) std.Io.File.stdout() else std.Io.File.stderr();
    file.writeStreamingAll(io(), content) catch return error.WriteFailed;
}
pub fn print(value: *Stream, content: []const u8) !void {
    try write(value, content);
}
pub fn read(value: *Stream, pointer: *u8, size: u64) !u64 {
    try valid(value);
    if (value.channel != .input) return error.WriteOnly;
    const buffer = try storage.bytes(pointer, size);
    if (buffer.len == 0) return 0;
    return std.Io.File.stdin().readStreaming(io(), &.{buffer}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return error.ReadFailed,
    };
}
pub fn close(value: *Stream) !void {
    // Standard descriptors belong to the process; writes are already unbuffered.
    try valid(value);
}
pub fn deinit() void {
    if (started) threaded.deinit();
    started = false;
}
