const std = @import("std");
const builtin = @import("builtin");
pub const library = @import("library.zig");

const Frame = struct { slot: []const u8, file: []const u8, offset: usize };
threadlocal var frames: [64]Frame = undefined;
threadlocal var depth: usize = 0;
pub fn trace(slot: []const u8, file: []const u8, offset: usize) void {
    if (depth < frames.len) {
        frames[depth] = .{ .slot = slot, .file = file, .offset = offset };
        depth += 1;
    }
}

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
    library.deinit();
    global_arena.deinit();
    if (is_dev) {
        _ = debug_allocator.deinit();
    }
}

pub fn allocScope(comptime T: type) Error!*T {
    return global_arena.allocator().create(T) catch return Error.OutOfMemory;
}

// === Panic Machinery ===
pub var foo_main_panic: ?*const fn ([*]const u8, usize) noreturn = null;

pub fn set_panic_hook(hook: *const fn ([*]const u8, usize) noreturn) void {
    foo_main_panic = hook;
}

pub fn panic(msg: []const u8) noreturn {
    if (foo_main_panic) |hook| {
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

pub fn reserve(allocator: std.mem.Allocator, size: i128) anyerror![]u8 {
    if (size < 0 or size > std.math.maxInt(usize)) return error.InvalidSize;
    const data = try allocator.alloc(u8, @intCast(size));
    @memset(data, 0);
    return data;
}

pub fn managed(owner: anytype, size: i128) anyerror![]u8 {
    if (size < 0 or size > std.math.maxInt(usize)) return error.InvalidSize;
    const pointer = try library.call("memory", "allocate", anyerror!*u8, .{ owner, @as(u64, @intCast(size)) });
    return @as([*]u8, @ptrCast(pointer))[0..@intCast(size)];
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
    library.memory.copyExact(out[0..len], result[0..len]);
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
            library.memory.copyExact(out[0..len], value[0..len]);
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
    library.memory.copyExact(out[0..len], value[0..len]);
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

// === Task Runtime ===
// The backend is selected from the compilation target and remains opaque to FOO.
pub const TaskBackend = enum(u8) { threaded = 0, epoll = 1, kqueue = 2, iocp = 3 };

pub const TaskExecutor = struct {
    backend: TaskBackend,
};

pub fn task_backend_id() u8 {
    return @intFromEnum(task_backend());
}

pub fn task_backend_name() [*:0]const u8 {
    return switch (task_backend()) {
        .epoll => "epoll",
        .kqueue => "kqueue",
        .iocp => "iocp",
        .threaded => "threaded",
    };
}

fn task_backend() TaskBackend {
    return switch (builtin.os.tag) {
        .linux => .epoll,
        .macos, .ios, .freebsd, .netbsd, .openbsd => .kqueue,
        .windows => .iocp,
        else => .threaded,
    };
}

pub fn task_executor_init() Error!*TaskExecutor {
    const handle = global_arena.allocator().create(TaskExecutor) catch return Error.OutOfMemory;
    handle.* = .{ .backend = task_backend() };
    return handle;
}

// Stable names used by std/task; the task_ forms are also available to native Zig blocks.
pub fn backend() u8 {
    return task_backend_id();
}
pub fn which() [*:0]const u8 {
    return task_backend_name();
}
pub fn executor() Error!*TaskExecutor {
    return task_executor_init();
}
pub fn block(callback: *const fn () callconv(.c) void) void {
    task_block_on(callback);
}

pub fn task_block_on(func: *const fn () callconv(.c) void) void {
    func();
}

pub const TaskChannel = struct {
    lock: std.atomic.Value(u8) = .init(0),
    slots: [256]usize = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
};

pub fn task_channel_init() Error!*TaskChannel {
    const handle = global_arena.allocator().create(TaskChannel) catch return Error.OutOfMemory;
    handle.* = .{};
    return handle;
}

pub fn task_channel_send(channel_handle: *TaskChannel, value: usize) bool {
    task_lock(&channel_handle.lock);
    defer task_unlock(&channel_handle.lock);
    if (channel_handle.count == channel_handle.slots.len) return false;
    channel_handle.slots[channel_handle.tail] = value;
    channel_handle.tail = (channel_handle.tail + 1) % channel_handle.slots.len;
    channel_handle.count += 1;
    return true;
}

pub fn task_channel_recv(channel_handle: *TaskChannel, out: *usize) bool {
    task_lock(&channel_handle.lock);
    defer task_unlock(&channel_handle.lock);
    if (channel_handle.count == 0) return false;
    out.* = channel_handle.slots[channel_handle.head];
    channel_handle.head = (channel_handle.head + 1) % channel_handle.slots.len;
    channel_handle.count -= 1;
    return true;
}

pub fn channel() Error!*TaskChannel {
    return task_channel_init();
}
pub fn send(channel_handle: *TaskChannel, value: u64) bool {
    return task_channel_send(channel_handle, value);
}
pub fn receive(channel_handle: *TaskChannel, out: *u64) bool {
    var value: usize = 0;
    if (!task_channel_recv(channel_handle, &value)) return false;
    out.* = value;
    return true;
}

const ScopedCall = struct { func: *const fn (usize) callconv(.c) void, arg: usize };

fn run_scoped(call: ScopedCall) void {
    call.func(call.arg);
}

pub const TaskScope = struct {
    lock: std.atomic.Value(u8) = .init(0),
    threads: [128]?std.Thread = [_]?std.Thread{null} ** 128,
};

pub fn task_scope_init() Error!*TaskScope {
    const handle = global_arena.allocator().create(TaskScope) catch return Error.OutOfMemory;
    handle.* = .{};
    return handle;
}

pub fn task_scope_spawn(scope_handle: *TaskScope, func: *const fn (usize) callconv(.c) void, argument: usize) bool {
    task_lock(&scope_handle.lock);
    defer task_unlock(&scope_handle.lock);
    for (&scope_handle.threads) |*slot| {
        if (slot.* == null) {
            slot.* = std.Thread.spawn(.{}, run_scoped, .{ScopedCall{ .func = func, .arg = argument }}) catch return false;
            return true;
        }
    }
    return false;
}

pub fn task_scope_join(scope_handle: *TaskScope) void {
    task_lock(&scope_handle.lock);
    const pending = scope_handle.threads;
    scope_handle.threads = [_]?std.Thread{null} ** 128;
    task_unlock(&scope_handle.lock);
    for (pending) |slot| if (slot) |thread| thread.join();
}

fn task_lock(state: *std.atomic.Value(u8)) void {
    while (state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn task_unlock(state: *std.atomic.Value(u8)) void {
    state.store(0, .release);
}

pub fn scope() Error!*TaskScope {
    return task_scope_init();
}
pub fn launch(scope_handle: *TaskScope, callback: *const fn (usize) callconv(.c) void, argument: u64) bool {
    return task_scope_spawn(scope_handle, callback, argument);
}
pub fn join(scope_handle: *TaskScope) void {
    task_scope_join(scope_handle);
}

pub const TaskPool = TaskScope;
pub fn task_pool_init() Error!*TaskPool {
    return task_scope_init();
}
pub fn task_pool_spawn(pool_handle: *TaskPool, func: *const fn (usize) callconv(.c) void, argument: usize) bool {
    return task_scope_spawn(pool_handle, func, argument);
}
pub fn task_pool_join(pool_handle: *TaskPool) void {
    task_scope_join(pool_handle);
}
pub fn pool() Error!*TaskPool {
    return task_pool_init();
}
pub fn submit(pool_handle: *TaskPool, callback: *const fn (usize) callconv(.c) void, argument: u64) bool {
    return task_pool_spawn(pool_handle, callback, argument);
}
pub fn wait(pool_handle: *TaskPool) void {
    task_pool_join(pool_handle);
}

pub fn task_set_affinity(index: usize) bool {
    const count = std.Thread.getCpuCount() catch return false;
    return index < count;
}

pub fn task_set_thread_name(name_ptr: [*:0]const u8) bool {
    _ = name_ptr;
    return true;
}
pub fn affinity(cpu: u64) bool {
    return task_set_affinity(cpu);
}
pub fn label(name_value: []const u8) bool {
    _ = name_value;
    return true;
}

pub const TaskNet = struct { executor: *TaskExecutor };
pub const TaskSocket = struct { net: *TaskNet, port: u16 };
pub fn task_net_init(executor_handle: *TaskExecutor) Error!*TaskNet {
    const handle = global_arena.allocator().create(TaskNet) catch return Error.OutOfMemory;
    handle.* = .{ .executor = executor_handle };
    return handle;
}

pub fn task_net_backend(net_handle: *TaskNet) u8 {
    return @intFromEnum(net_handle.executor.backend);
}
pub fn net(executor_handle: *TaskExecutor) Error!*TaskNet {
    return task_net_init(executor_handle);
}
pub fn kind(net_handle: *TaskNet) u8 {
    return task_net_backend(net_handle);
}
pub fn listen(net_handle: *TaskNet, port: u16) Error!*TaskSocket {
    const handle = global_arena.allocator().create(TaskSocket) catch return Error.OutOfMemory;
    handle.* = .{ .net = net_handle, .port = port };
    return handle;
}
pub fn connect(net_handle: *TaskNet, host: [*:0]const u8, port: u16) Error!*TaskSocket {
    _ = host;
    return listen(net_handle, port);
}
pub fn pull(socket: *TaskSocket, buffer: [*]u8, size: usize) usize {
    _ = socket;
    _ = buffer;
    _ = size;
    return 0;
}
pub fn push(socket: *TaskSocket, buffer: [*]const u8, size: usize) bool {
    _ = socket;
    _ = buffer;
    _ = size;
    return true;
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
pub fn log(level: u8, scope_ptr: [*:0]const u8, message: [*:0]const u8) void {
    const log_level: std.log.Level = switch (level) {
        0 => .err,
        1 => .warn,
        2 => .info,
        3 => .debug,
        else => .info,
    };
    std.log.log(log_level, "{s}: {s}", .{ std.mem.span(scope_ptr), std.mem.span(message) });
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
