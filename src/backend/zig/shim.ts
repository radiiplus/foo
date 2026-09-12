export const shim = `
const std = @import("std");

pub const Error = error{
    OutOfMemory,
    Panic,
    Bounds,
    Overflow,
    NotFound,
    Permission,
    Argument,
    Refused,
    Reset,
    Broken,
    Timeout,
    Unexpected,
};

var global_arena: std.heap.ArenaAllocator = undefined;
var debug_allocator: std.heap.DebugAllocator(.{}) = undefined;
var is_dev: bool = true;

pub fn init(dev: bool) void {
    is_dev = dev;
    if (is_dev) {
        debug_allocator = std.heap.DebugAllocator(.{}).init;
        global_arena = std.heap.ArenaAllocator.init(debug_allocator.allocator());
    } else {
        global_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
}

pub fn deinit() void {
    global_arena.deinit();
    if (is_dev) {
        _ = debug_allocator.deinit();
    }
}

pub fn allocScope(comptime T: type) Error!*T {
    return global_arena.allocator().create(T) catch return Error.OutOfMemory;
}

// === Panic Machinery ===
pub var tratio_main_panic: ?*const fn ([*]const u8, usize) noreturn = null;

pub fn set_panic_hook(hook: *const fn ([*]const u8, usize) noreturn) void {
    tratio_main_panic = hook;
}

pub fn panic(msg: []const u8) noreturn {
    if (tratio_main_panic) |hook| {
        hook(msg.ptr, msg.len);
    }
    
    if (is_dev) {
        std.debug.dumpCurrentStackTrace(.{});
    }
    
    std.debug.panic("{s}", .{msg});
}

pub fn bounds(len: usize, idx: usize) void {
    if (idx >= len) {
        panic("bounds check failed");
    }
}

// === Memory ===
pub fn system() std.mem.Allocator {
    return std.heap.page_allocator;
}

pub fn arena() std.mem.Allocator {
    return global_arena.allocator();
}

pub fn allocate(allocator: std.mem.Allocator, size: usize) Error![]u8 {
    return allocator.alloc(u8, size) catch return Error.OutOfMemory;
}

pub fn release(allocator: std.mem.Allocator, buffer: []u8) void {
    allocator.free(buffer);
}

pub fn expand(allocator: std.mem.Allocator, buffer: []u8, new_size: usize) Error![]u8 {
    return allocator.realloc(buffer, new_size) catch return Error.OutOfMemory;
}

// === File ===
pub fn open(path: [*:0]const u8, mode: u8) Error!*std.fs.File {
    const flags: std.fs.File.OpenFlags = switch (mode) {
        0 => .{ .read = true },
        1 => .{ .write = true, .truncate = true },
        2 => .{ .read = true, .write = true },
        3 => .{ .write = true, .truncate = true, .create = true },
        else => return Error.Argument,
    };
    return std.fs.cwd().openFile(std.mem.span(path), flags) catch |err| switch (err) {
        error.FileNotFound => return Error.NotFound,
        error.PermissionDenied => return Error.Permission,
        else => return Error.Unexpected,
    };
}

pub fn read(file: *std.fs.File, buffer: [*]u8, size: usize) Error!usize {
    return file.read(buffer[0..size]) catch return Error.Unexpected;
}

pub fn write(file: *std.fs.File, data: [*]const u8, size: usize) Error!void {
    file.writeAll(data[0..size]) catch return Error.Unexpected;
}

pub fn close(file: *std.fs.File) void {
    file.close();
}

// === Path ===
pub fn merge(out: [*]u8, capacity: usize, first: [*:0]const u8, second: [*:0]const u8) usize {
    const result = std.fs.path.joinZ(out[0..capacity], &[_][]const u8{ std.mem.span(first), std.mem.span(second) });
    return result.len;
}

pub fn parent(out: [*]u8, capacity: usize, path: [*:0]const u8) usize {
    const result = std.fs.path.dirname(std.mem.span(path)) orelse "";
    const len = @min(result.len, capacity);
    @memcpy(out[0..len], result[0..len]);
    return len;
}

pub fn name(path: [*:0]const u8) [*:0]const u8 {
    return std.fs.path.basename(std.mem.span(path));
}

pub fn suffix(path: [*:0]const u8) [*:0]const u8 {
    return std.fs.path.extension(std.mem.span(path));
}

pub fn absolute(path: [*:0]const u8) bool {
    return std.fs.path.isAbsolute(std.mem.span(path));
}

// === Process ===
pub fn args() usize {
    return std.process.args().count;
}

pub fn arg(index: usize, out: [*]u8, capacity: usize) usize {
    var iterator = std.process.args();
    var i: usize = 0;
    while (iterator.next()) |value| : (i += 1) {
        if (i == index) {
            const len = @min(value.len, capacity);
            @memcpy(out[0..len], value[0..len]);
            return len;
        }
    }
    return 0;
}

// === Env ===
pub fn variable(key: [*:0]const u8, out: [*]u8, capacity: usize) usize {
    const value = std.process.getEnvVarOwned(global_arena.allocator(), std.mem.span(key)) catch return 0;
    defer global_arena.allocator().free(value);
    const len = @min(value.len, capacity);
    @memcpy(out[0..len], value[0..len]);
    return len;
}

// === Stream ===
pub fn input() *std.fs.File {
    return &std.io.getStdIn();
}

pub fn output() *std.fs.File {
    return &std.io.getStdOut();
}

pub fn report() *std.fs.File {
    return &std.io.getStdErr();
}

// === Net ===
pub fn dial(host: [*:0]const u8, port: u16) Error!*std.net.Stream {
    const address = std.net.Address.resolveIp(std.mem.span(host), port) catch return Error.Unexpected;
    const connection = std.net.tcpConnectToAddress(address) catch |err| switch (err) {
        error.ConnectionRefused => return Error.Refused,
        else => return Error.Unexpected,
    };
    const result = global_arena.allocator().create(std.net.Stream) catch return Error.OutOfMemory;
    result.* = connection;
    return result;
}

pub fn accept(host: [*:0]const u8, port: u16) Error!*std.net.Server {
    const address = std.net.Address.resolveIp(std.mem.span(host), port) catch return Error.Unexpected;
    const server = address.listen(.{}, 128) catch return Error.Unexpected;
    const result = global_arena.allocator().create(std.net.Server) catch return Error.OutOfMemory;
    result.* = server;
    return result;
}

// === Thread ===
pub fn spawn(comptime func: anytype, argument: anytype) Error!*std.Thread {
    const handle = global_arena.allocator().create(std.Thread) catch return Error.OutOfMemory;
    handle.* = std.Thread.spawn(.{}, func, .{argument}) catch return Error.Unexpected;
    return handle;
}

pub fn await(handle: *std.Thread) void {
    handle.join();
}

// === Sync ===
pub fn mutex() Error!*std.Thread.Mutex {
    return global_arena.allocator().create(std.Thread.Mutex) catch return Error.OutOfMemory;
}

pub fn lock(handle: *std.Thread.Mutex) void {
    handle.lock();
}

pub fn unlock(handle: *std.Thread.Mutex) void {
    handle.unlock();
}

// === Time ===
pub fn instant() i128 {
    return std.time.nanoTimestamp();
}

pub fn moment() i64 {
    return std.time.milliTimestamp();
}

pub fn pause(nanos: u64) void {
    std.time.sleep(nanos);
}

// === Random ===
pub fn entropy(out: [*]u8, size: usize) void {
    var rng = std.crypto.random;
    rng.bytes(out[0..size]);
}

// === Log ===
pub fn log(level: u8, scope: [*:0]const u8, message: [*:0]const u8) void {
    const log_level: std.log.Level = switch (level) {
        0 => .err,
        1 => .warn,
        2 => .info,
        3 => .debug,
        else => .info,
    };
    std.log.log(log_level, "{s}: {s}", .{ std.mem.span(scope), std.mem.span(message) });
}

// === Reflection ===
pub const FieldInfo = struct {
    name: []const u8,
    type: type,
    offset: usize,
};

pub const TypeInfo = struct {
    name: []const u8,
    fields: []const FieldInfo,
};

pub fn reflect(comptime T: type) TypeInfo {
    const info = @typeInfo(T);
    switch (info) {
        .Struct => |s| {
            var fields: [s.fields.len]FieldInfo = undefined;
            for (s.fields, 0..) |f, i| {
                fields[i] = .{
                    .name = f.name,
                    .type = f.type,
                    .offset = @offsetOf(T, f.name),
                };
            }
            return .{
                .name = @typeName(T),
                .fields = &fields,
            };
        },
        else => @compileError("reflect currently only supports structs"),
    }
}

pub const TypeBuilder = struct {
    // Placeholder for runtime type generation if needed
};

// === Derive Helpers ===
pub fn eql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    const info = @typeInfo(T);
    switch (info) {
        .Struct => |s| {
            inline for (s.fields) |f| {
                if (!eql(@field(a, f.name), @field(b, f.name))) return false;
            }
            return true;
        },
        .Int, .Float, .Bool => return a == b,
        else => @compileError("eql not supported for this type"),
    }
}

pub fn hash(val: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const T = @TypeOf(val);
    const info = @typeInfo(T);
    switch (info) {
        .Struct => |s| {
            inline for (s.fields) |f| {
                hasher.update(std.mem.asBytes(&@field(val, f.name)));
            }
        },
        .Int, .Float, .Bool => hasher.update(std.mem.asBytes(&val)),
        else => @compileError("hash not supported for this type"),
    }
    return hasher.final();
}
`;