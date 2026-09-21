const std = @import("std");
const c = @cImport({
    @cInclude("service.h");
});
const allocator = std.heap.page_allocator;
var arena: std.heap.ArenaAllocator = .init(allocator);

pub fn init(args: std.process.Args) !void {
    const values = try args.toSlice(arena.allocator());
    const raw = try arena.allocator().alloc(?[*:0]const u8, values.len);
    for (values, 0..) |value, index| raw[index] = value.ptr;
    c.foo_service_init(@intCast(raw.len), @ptrCast(raw.ptr));
}
pub fn deinit() void {
    c.foo_service_close();
    arena.deinit();
    arena = .init(allocator);
}
fn result(comptime T: type, value: c.FooResult) T {
    if (@typeInfo(T) == .error_union) {
        if (value.@"error" != 0) return switch (value.@"error") {
            1 => error.OutOfMemory,
            2 => error.InvalidInput,
            3 => error.IoFailure,
            4 => error.Closed,
            5 => error.MissingValue,
            7 => error.Bounds,
            else => error.SystemFailure,
        };
        return result(@typeInfo(T).error_union.payload, value);
    }
    if (value.@"error" != 0) @panic("SystemFailure");
    return switch (@typeInfo(T)) {
        .void => {},
        .int => @intCast(value.number),
        .pointer => |info| if (info.size == .slice) if (value.text.len == 0) &.{} else @as([*]const u8, @ptrCast(value.text.data))[0..value.text.len] else @ptrCast(@alignCast(value.pointer.?)),
        else => @compileError("Unsupported service result"),
    };
}
fn argument(comptime T: type, value: anytype) T {
    if (T == c.FooText) return .{ .data = value.ptr, .len = value.len };
    return switch (@typeInfo(T)) {
        .int => @intCast(value),
        .optional, .pointer => @ptrCast(@constCast(value)),
        else => @compileError("Unsupported service argument"),
    };
}
pub fn call(comptime module: []const u8, comptime name: []const u8, comptime T: type, args: anytype) T {
    if (comptime std.mem.eql(u8, module, "thread") and std.mem.eql(u8, name, "spawn")) {
        const Context = struct {
            function: @TypeOf(args[0]),
            fn run(pointer: ?*anyopaque) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(pointer.?));
                const function = self.function;
                allocator.destroy(self);
                function();
            }
        };
        const context = allocator.create(Context) catch return error.OutOfMemory;
        context.* = .{ .function = args[0] };
        const value = c.foo_thread_spawn(Context.run, context);
        if (value.@"error" != 0) allocator.destroy(context);
        return result(T, value);
    }
    const symbol = comptime if (std.mem.eql(u8, module, "thread") and std.mem.eql(u8, name, "pause")) "await" else name;
    const function = @field(c, "foo_" ++ module ++ "_" ++ symbol);
    const info = @typeInfo(@TypeOf(function)).@"fn";
    var converted: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
    inline for (info.params, 0..) |param, index| converted[index] = argument(param.type.?, args[index]);
    return result(T, @call(.auto, function, converted));
}
