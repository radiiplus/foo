//! FOO's portable library, pinned to Zig 0.16.0.
const std = @import("std");
const builtin = @import("builtin");
const allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;
const managed = @import("storage.zig");
const instrumented = FOO_BENCHMARK_ENABLED;
pub const memory = managed.memory;
pub const list = managed.list;
pub const streams = @import("stream.zig");
const Metrics = struct {
    allocations: u64 = 0,
    allocated_bytes: u64 = 0,
    reallocations: u64 = 0,
    copied_bytes: u64 = 0,
    growths: u64 = 0,
    growth_bytes: u64 = 0,
    capacity_total: u64 = 0,
    capacity_max: u64 = 0,
    capacity_samples: u64 = 0,
    requested: u64 = 0,
    live: u64 = 0,
    peak: u64 = 0,
    retained: u64 = 0,
    slowpaths: u64 = 0,
    branches: u64 = 0,
    branchbytes: u64 = 0,
};
var metrics: Metrics = .{};
fn metric(counter: *u64, amount: usize) void {
    if (!instrumented) return;
    counter.* = std.math.add(u64, counter.*, std.math.cast(u64, amount) orelse std.math.maxInt(u64)) catch std.math.maxInt(u64);
}
fn metricPeak() void {
    if (instrumented) metrics.peak = @max(metrics.peak, metrics.live);
}
fn metricRelease(size: usize, retired: bool) void {
    if (!instrumented) return;
    metrics.live -= size;
    if (retired) metrics.retained -= size;
}
fn metricCapacity(capacity: usize) void {
    if (!instrumented) return;
    metric(&metrics.capacity_total, capacity);
    metric(&metrics.capacity_samples, 1);
    metrics.capacity_max = @max(metrics.capacity_max, capacity);
}
pub fn benchmarkReport() void {
    const average = if (metrics.capacity_samples == 0) 0.0 else @as(f64, @floatFromInt(metrics.capacity_total)) / @as(f64, @floatFromInt(metrics.capacity_samples));
    const factor: f64 = if (metrics.requested == 0) 0.0 else @as(f64, @floatFromInt(metrics.capacity_total)) / @as(f64, @floatFromInt(metrics.requested));
    std.debug.print("FOO_METRICS {{\"allocations\":{d},\"allocatedBytes\":{d},\"reallocations\":{d},\"bytesCopied\":{d},\"growthOperations\":{d},\"growthBytesCopied\":{d},\"averageCapacity\":{d:.3},\"maximumCapacity\":{d},\"growthFactor\":{d:.3},\"liveBytes\":{d},\"peakBytes\":{d},\"olderVersionBytes\":{d},\"slowPathHits\":{d},\"branchOperations\":{d},\"branchBytesCopied\":{d}}}\n", .{ metrics.allocations, metrics.allocated_bytes, metrics.reallocations, metrics.copied_bytes, metrics.growths, metrics.growth_bytes, average, metrics.capacity_max, factor, metrics.live, metrics.peak, metrics.retained, metrics.slowpaths, metrics.branches, metrics.branchbytes });
}
pub fn order(left: anytype, right: @TypeOf(left)) std.math.Order {
    const T = @TypeOf(left);
    return switch (@typeInfo(T)) {
        .bool => std.math.order(@intFromBool(left), @intFromBool(right)),
        .@"struct" => result: {
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const relation = order(@field(left, field.name), @field(right, field.name));
                if (relation != .eq) break :result relation;
            }
            break :result .eq;
        },
        .pointer => result: {
            for (0..@min(left.len, right.len)) |index| {
                const relation = order(left[index], right[index]);
                if (relation != .eq) break :result relation;
            }
            break :result std.math.order(left.len, right.len);
        },
        .optional => if (left) |a| if (right) |b| order(a, b) else .gt else if (right == null) .eq else .lt,
        .@"union" => result: {
            const relation = std.math.order(@intFromEnum(std.meta.activeTag(left)), @intFromEnum(std.meta.activeTag(right)));
            if (relation != .eq) break :result relation;
            switch (left) {
                inline else => |value, tag| break :result order(value, @field(right, @tagName(tag))),
            }
        },
        .void => .eq,
        else => std.math.order(left, right),
    };
}
pub fn equal(left: anytype, right: @TypeOf(left)) bool {
    const T = @TypeOf(left);
    return switch (@typeInfo(T)) {
        .@"struct" => result: {
            inline for (@typeInfo(T).@"struct".fields) |field| if (!equal(@field(left, field.name), @field(right, field.name))) break :result false;
            break :result true;
        },
        .pointer => |info| if (info.size == .slice) result: {
            if (left.len != right.len) break :result false;
            for (left, right) |a, b| if (!equal(a, b)) break :result false;
            break :result true;
        } else left == right,
        .optional => if (left) |a| if (right) |b| equal(a, b) else false else right == null,
        .@"union" => result: {
            if (std.meta.activeTag(left) != std.meta.activeTag(right)) break :result false;
            switch (left) {
                inline else => |value, tag| break :result equal(value, @field(right, @tagName(tag))),
            }
        },
        .void => true,
        else => left == right,
    };
}
pub fn join(a: []const u8, b: []const u8) []const u8 {
    const bytes = std.mem.concat(allocator, u8, &.{ a, b }) catch @panic("OutOfMemory");
    defer allocator.free(bytes);
    return retain(u8, bytes) catch @panic("OutOfMemory");
}
const Allocation = struct {
    bytes: []u8,
    alignment: std.mem.Alignment,
    used: usize = 0,
    capacity: usize = 0,
    element: usize = 0,
    references: usize = 0,
    sequence: bool = false,
    retired: bool = false,
};
var retained: std.AutoHashMap(usize, Allocation) = .init(allocator);
var lock: std.atomic.Value(bool) = .init(false);
var threaded: std.Io.Threaded = undefined;
var started = false;
const FastEntry = struct {
    hash: u64 = 0,
    state: enum(u8) { empty, occupied, removed } = .empty,
    key: []u8 = &.{},
    value: []u8 = &.{},
};
const FastMap = struct {
    entries: []FastEntry = &.{},
    count: usize = 0,
    alive: bool = true,
    next: ?*FastMap = null,
};
var fast_maps: ?*FastMap = null;

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn heapBytes() u64 {
    acquire();
    var total: u64 = 0;
    var iterator = retained.valueIterator();
    while (iterator.next()) |entry|
        total = std.math.add(u64, total, entry.bytes.len) catch std.math.maxInt(u64);
    lock.store(false, .release);
    return std.math.add(u64, total, managed.memory.allocated()) catch std.math.maxInt(u64);
}
fn retain(comptime T: type, bytes: []const T) ![]T {
    if (bytes.len == 0) return &.{};
    const result = try allocator.alloc(T, bytes.len);
    errdefer allocator.free(result);
    metric(&metrics.allocations, 1);
    metric(&metrics.allocated_bytes, bytes.len * @sizeOf(T));
    metric(&metrics.live, bytes.len * @sizeOf(T));
    metricPeak();
    metric(&metrics.copied_bytes, bytes.len * @sizeOf(T));
    managed.memory.copyExact(std.mem.sliceAsBytes(result), std.mem.sliceAsBytes(bytes));
    acquire();
    defer lock.store(false, .release);
    try retained.put(@intFromPtr(result.ptr), .{ .bytes = std.mem.sliceAsBytes(result), .alignment = .of(T) });
    return result;
}
fn adopt(comptime T: type, bytes: []T) ![]T {
    metric(&metrics.allocations, 1);
    metric(&metrics.allocated_bytes, bytes.len * @sizeOf(T));
    metric(&metrics.live, bytes.len * @sizeOf(T));
    metricPeak();
    acquire();
    defer lock.store(false, .release);
    try retained.put(@intFromPtr(bytes.ptr), .{
        .bytes = std.mem.sliceAsBytes(bytes),
        .alignment = .of(T),
    });
    return bytes;
}
fn sequenceReserve(comptime T: type, capacity: usize, used: usize) ![]T {
    if (capacity == 0) return &.{};
    if (used > capacity) return error.Overflow;
    const size = std.math.mul(usize, capacity, @sizeOf(T)) catch return error.Overflow;
    const items = try allocator.alloc(T, capacity);
    errdefer allocator.free(items);
    metric(&metrics.allocations, 1);
    metric(&metrics.allocated_bytes, size);
    metric(&metrics.live, size);
    metricPeak();
    acquire();
    defer lock.store(false, .release);
    try retained.put(@intFromPtr(items.ptr), .{
        .bytes = std.mem.sliceAsBytes(items),
        .alignment = .of(T),
        .used = used,
        .capacity = capacity,
        .element = @sizeOf(T),
        .references = 1,
        .sequence = true,
    });
    return items[0..used];
}
fn sequenceCapacity(count: usize) !usize {
    var capacity: usize = 8;
    while (capacity < count) capacity = try std.math.mul(usize, capacity, 2);
    return capacity;
}
fn cloneBytes(bytes: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, bytes.len);
    managed.memory.copyExact(result, bytes);
    return result;
}
fn runtimeIo() std.Io {
    acquire();
    defer lock.store(false, .release);
    if (!started) {
        threaded = .init(allocator, .{});
        started = true;
    }
    return threaded.io();
}
fn hashBytes(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return if (hash == 0) 1 else hash;
}
fn fastMap(handle: anytype) !*FastMap {
    const pointer: *FastMap = @ptrCast(@alignCast(handle));
    var cursor = fast_maps;
    while (cursor) |map| : (cursor = map.next)
        if (map == pointer) return if (map.alive) map else error.Closed;
    return error.Closed;
}
fn fastSlot(map: *FastMap, hash: u64, key: []const u8, insert: bool) *FastEntry {
    var index: usize = @intCast(hash & @as(u64, @intCast(map.entries.len - 1)));
    var removed: ?usize = null;
    while (true) {
        const entry = &map.entries[index];
        if (entry.state == .empty) return if (insert and removed != null) &map.entries[removed.?] else entry;
        if (entry.state == .occupied and entry.hash == hash and std.mem.eql(u8, entry.key, key)) return entry;
        if (insert and entry.state == .removed and removed == null) removed = index;
        index = (index + 1) & (map.entries.len - 1);
    }
}
fn fastGrow(map: *FastMap) !void {
    const capacity = if (map.entries.len == 0) 16 else try std.math.mul(usize, map.entries.len, 2);
    const previous = map.entries;
    map.entries = try allocator.alloc(FastEntry, capacity);
    @memset(map.entries, .{});
    for (previous) |entry| {
        if (entry.state == .occupied)
            fastSlot(map, entry.hash, entry.key, true).* = entry;
    }
    if (previous.len > 0) allocator.free(previous);
}
fn fastCreate() !*FastMap {
    const map = try allocator.create(FastMap);
    map.* = .{ .next = fast_maps };
    fast_maps = map;
    return map;
}
fn fastPut(map: *FastMap, key: []const u8, bytes: []const u8) !void {
    if (map.entries.len == 0 or (map.count + 1) * 4 >= map.entries.len * 3) try fastGrow(map);
    const hash = hashBytes(key);
    const entry = fastSlot(map, hash, key, true);
    const value = try cloneBytes(bytes);
    errdefer allocator.free(value);
    if (entry.state == .occupied) {
        allocator.free(entry.value);
        entry.value = value;
        return;
    }
    const name = try cloneBytes(key);
    entry.* = .{ .hash = hash, .state = .occupied, .key = name, .value = value };
    map.count += 1;
}
fn fastClear(map: *FastMap) void {
    for (map.entries) |entry| {
        if (entry.state == .occupied) {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
    }
    if (map.entries.len > 0) allocator.free(map.entries);
    map.entries = &.{};
    map.count = 0;
}
pub fn deinit() void {
    streams.deinit();
    managed.deinit();
    if (started) threaded.deinit();
    started = false;
    var iterator = retained.valueIterator();
    while (iterator.next()) |allocation| allocator.rawFree(allocation.bytes, allocation.alignment, @returnAddress());
    retained.deinit();
    retained = .init(allocator);
    while (fast_maps) |map| {
        fast_maps = map.next;
        if (map.alive) fastClear(map);
        allocator.destroy(map);
    }
}

pub const io = struct {
    pub const Stream = streams.Stream;

    pub fn input() *Stream {
        return streams.input();
    }
    pub fn output() *Stream {
        return streams.output();
    }
    pub fn report() *Stream {
        return streams.report();
    }
    pub fn read(value: *Stream, size: u64) ![]const u8 {
        if (size > std.math.maxInt(usize)) return error.InvalidSize;
        if (size == 0) return retain(u8, "");
        const buffer = try allocator.alloc(u8, @intCast(size));
        defer allocator.free(buffer);
        const count = try streams.read(value, &buffer[0], size);
        return retain(u8, buffer[0..@intCast(count)]);
    }
    pub fn line(value: *Stream) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);
        var byte: [1]u8 = undefined;
        while (try streams.read(value, &byte[0], 1) == 1) {
            if (byte[0] == '\n') break;
            if (byte[0] != '\r') try result.append(allocator, byte[0]);
        }
        return retain(u8, result.items);
    }
    pub fn write(value: *Stream, content: []const u8) !void {
        try streams.write(value, content);
    }
    pub fn close(value: *Stream) !void {
        try streams.close(value);
    }
};

pub const buffers = struct {
    fn discard(comptime T: type, value: []const T) !void {
        if (value.len == 0) return;
        acquire();
        defer lock.store(false, .release);
        const allocation = retained.get(@intFromPtr(value.ptr)) orelse return error.UnknownBuffer;
        const valid = if (allocation.sequence)
            allocation.element == @sizeOf(T) and value.len <= allocation.used
        else
            allocation.bytes.len == value.len * @sizeOf(T);
        if (!valid or allocation.alignment != std.mem.Alignment.of(T)) return error.InvalidBuffer;
        if (allocation.sequence and allocation.references > 1) {
            retained.getPtr(@intFromPtr(value.ptr)).?.references -= 1;
            return;
        }
        _ = retained.remove(@intFromPtr(value.ptr));
        metricRelease(allocation.bytes.len, allocation.retired);
        allocator.rawFree(allocation.bytes, allocation.alignment, @returnAddress());
    }
    pub fn free(value: []const u8) !void {
        try discard(u8, value);
    }
    pub fn words(value: []u16) !void {
        try discard(u16, value);
    }
    pub fn points(value: []u32) !void {
        try discard(u32, value);
    }
};

pub fn report(path: []const u8, names: []const []const u8, lines: []const u32, counts: []const u64) !void {
    const Entry = struct { function: []const u8, line: u32, hits: u64 };
    const entries = try allocator.alloc(Entry, names.len);
    defer allocator.free(entries);
    for (entries, 0..) |*entry, index| entry.* = .{ .function = names[index], .line = lines[index], .hits = counts[index] };
    const encoded = try std.json.Stringify.valueAlloc(allocator, .{ .version = 1, .kind = "function", .entries = entries }, .{});
    defer allocator.free(encoded);
    try std.Io.Dir.cwd().writeFile(runtimeIo(), .{ .sub_path = path, .data = encoded });
}

pub const arch = struct {
    fn supported() void {
        if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) @compileError("Architecture intrinsics require x86_64 or aarch64");
    }
    fn popcntAvailable() bool {
        var eax: u32 = undefined;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        var edx: u32 = undefined;
        asm volatile ("cpuid"
            : [_] "={eax}" (eax),
              [_] "={ebx}" (ebx),
              [_] "={ecx}" (ecx),
              [_] "={edx}" (edx),
            : [_] "{eax}" (@as(u32, 1)),
              [_] "{ecx}" (@as(u32, 0)),
        );
        return ecx & (@as(u32, 1) << 23) != 0;
    }
    fn nativeCount(value: u64) u64 {
        return asm volatile ("popcntq %[value], %[result]"
            : [result] "=r" (-> u64),
            : [value] "r" (value),
        );
    }
    pub fn count(value: u64) u32 {
        comptime supported();
        return @popCount(value);
    }
    pub fn tally(values: []const u64) u64 {
        comptime supported();
        var total: u64 = 0;
        if (builtin.zig_backend == .stage2_llvm and builtin.cpu.arch == .x86_64 and popcntAvailable()) {
            for (values) |value| total += nativeCount(value);
            return total;
        }
        for (values) |value| total += @popCount(value);
        return total;
    }
    pub fn combine(left: []const u64, right: []const u64, output: []u64, operation: u64) bool {
        comptime supported();
        if (operation > 3 or left.len != right.len or left.len != output.len) return false;
        for (left, right, output) |a, b, *result| {
            result.* = switch (operation) {
                0 => a | b,
                1 => a & b,
                2 => a & ~b,
                else => a ^ b,
            };
        }
        return true;
    }
    pub fn pause() void {
        comptime supported();
        if (builtin.cpu.arch == .x86_64) asm volatile ("pause") else asm volatile ("yield");
    }
    pub fn ticks() u64 {
        comptime supported();
        if (builtin.cpu.arch == .aarch64) return asm volatile ("mrs %[result], cntvct_el0"
            : [result] "=r" (-> u64),
        );
        var low: u32 = undefined;
        var high: u32 = undefined;
        asm volatile ("lfence; rdtsc"
            : [low] "={eax}" (low),
              [high] "={edx}" (high),
        );
        return (@as(u64, high) << 32) | low;
    }
    pub fn target(feature: []const u8) bool {
        const cpu = builtin.target.cpu;
        if (cpu.arch == .x86_64) {
            if (std.mem.eql(u8, feature, "sse2")) return std.Target.x86.featureSetHas(cpu.features, .sse2);
            if (std.mem.eql(u8, feature, "avx2")) return std.Target.x86.featureSetHas(cpu.features, .avx2);
            if (std.mem.eql(u8, feature, "avx512f")) return std.Target.x86.featureSetHas(cpu.features, .avx512f);
            if (std.mem.eql(u8, feature, "fma")) return std.Target.x86.featureSetHas(cpu.features, .fma);
        }
        if (cpu.arch == .aarch64) {
            if (std.mem.eql(u8, feature, "neon")) return std.Target.aarch64.featureSetHas(cpu.features, .neon);
            if (std.mem.eql(u8, feature, "sve")) return std.Target.aarch64.featureSetHas(cpu.features, .sve);
        }
        return false;
    }
    pub fn prefetch(bytes: []const u8, offset: u64) void {
        if (offset >= bytes.len) return;
        @prefetch(&bytes[@intCast(offset)], .{ .rw = .read, .locality = 3 });
    }
    pub fn stage(bytes: []u8, offset: u64) void {
        if (offset >= bytes.len) return;
        @prefetch(&bytes[@intCast(offset)], .{ .rw = .write, .locality = 3 });
    }
};

pub const atomic = struct {
    pub const Atom = std.atomic.Value(u64);
    fn order(name: []const u8) !std.builtin.AtomicOrder {
        const Order = std.builtin.AtomicOrder;
        return if (std.mem.eql(u8, name, "relaxed")) Order.monotonic else if (std.mem.eql(u8, name, "acquire")) Order.acquire else if (std.mem.eql(u8, name, "release")) Order.release else if (std.mem.eql(u8, name, "both")) Order.acq_rel else if (std.mem.eql(u8, name, "sequential")) Order.seq_cst else error.InvalidOrder;
    }
    pub fn create(value: u64) !*Atom {
        const result = try allocator.create(Atom);
        result.* = .init(value);
        return result;
    }
    pub fn release(value: *Atom) void {
        allocator.destroy(value);
    }
    pub fn load(value: *Atom, ordering: []const u8) !u64 {
        switch (try atomic.order(ordering)) {
            inline .monotonic, .acquire, .seq_cst => |o| return value.load(o),
            else => return error.InvalidLoadOrder,
        }
    }
    pub fn store(value: *Atom, number: u64, ordering: []const u8) !void {
        switch (try atomic.order(ordering)) {
            inline .monotonic, .release, .seq_cst => |o| value.store(number, o),
            else => return error.InvalidStoreOrder,
        }
    }
    pub fn add(value: *Atom, number: u64, ordering: []const u8) !u64 {
        switch (try atomic.order(ordering)) {
            inline .monotonic, .acquire, .release, .acq_rel, .seq_cst => |o| return value.fetchAdd(number, o),
            else => unreachable,
        }
    }
    pub fn deduct(value: *Atom, number: u64, ordering: []const u8) !u64 {
        switch (try atomic.order(ordering)) {
            inline .monotonic, .acquire, .release, .acq_rel, .seq_cst => |o| return value.fetchSub(number, o),
            else => unreachable,
        }
    }
    pub fn swap(value: *Atom, number: u64, ordering: []const u8) !u64 {
        switch (try atomic.order(ordering)) {
            inline .monotonic, .acquire, .release, .acq_rel, .seq_cst => |o| return value.swap(number, o),
            else => unreachable,
        }
    }
    pub fn replace(value: *Atom, expected: u64, number: u64, ordering: []const u8) !bool {
        switch (try atomic.order(ordering)) {
            inline .monotonic, .acquire, .release, .acq_rel, .seq_cst => |o| return value.cmpxchgStrong(expected, number, o, .monotonic) == null,
            else => unreachable,
        }
    }
    fn validFailure(comptime success: std.builtin.AtomicOrder, comptime failure: std.builtin.AtomicOrder) bool {
        return switch (failure) {
            .monotonic => true,
            .acquire => success == .acquire or success == .acq_rel or success == .seq_cst,
            .seq_cst => success == .seq_cst,
            else => false,
        };
    }
    pub fn compare(value: *Atom, expected: u64, number: u64, success_name: []const u8, failure_name: []const u8) !bool {
        const success = try atomic.order(success_name);
        const failure = try atomic.order(failure_name);
        switch (success) {
            inline .monotonic, .acquire, .release, .acq_rel, .seq_cst => |s| switch (failure) {
                inline .monotonic, .acquire, .seq_cst => |f| {
                    if (comptime validFailure(s, f))
                        return value.cmpxchgStrong(expected, number, s, f) == null;
                    return error.InvalidOrder;
                },
                else => return error.InvalidOrder,
            },
            else => return error.InvalidOrder,
        }
    }
};

// Only this bridge knows the Zig implementation of opaque FOO handles.
fn convert(comptime T: type, value: anytype) T {
    if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one)
        return @ptrCast(@alignCast(value));
    return value;
}
pub fn call(comptime module: []const u8, comptime name: []const u8, comptime Result: type, args: anytype) Result {
    if (comptime std.mem.eql(u8, module, "memory") and std.mem.eql(u8, name, "reinterpret")) {
        const pointer = @typeInfo(Result).error_union.payload;
        const T = @typeInfo(pointer).pointer.child;
        managed.enter();
        defer managed.leave();
        return managed.memory.reinterpret(T, convert(*managed.Allocator, args[0]), args[1], args[2]);
    }
    if (comptime std.mem.eql(u8, module, "resource") and std.mem.eql(u8, name, "heap")) return heapBytes();
    if (comptime std.mem.eql(u8, module, "resource") and std.mem.eql(u8, name, "tasks")) return @import("shim.zig").resourceTasks();
    if (comptime std.mem.eql(u8, module, "resource") and std.mem.eql(u8, name, "pending")) return @import("shim.zig").resourcePending();
    if (comptime std.mem.eql(u8, module, "text") and std.mem.eql(u8, name, "release")) {
        buffers.free(args[0]) catch |err| {
            if (err != error.UnknownBuffer) return err;
            return @import("service.zig").call(module, name, Result, args);
        };
        return;
    }
    inline for (.{ "bloom", "cpu", "topology", "platform", "dylib", "fs", "vm", "gpu", "io", "net", "tls", "process", "resource", "ring", "thread", "time", "timer", "text", "metric", "trace", "limit" }) |namespace| {
        if (comptime std.mem.eql(u8, module, namespace)) return @import("service.zig").call(module, name, Result, args);
    }
    if (comptime std.mem.eql(u8, module, "sequence")) return sequence(name, Result, args);
    if (comptime std.mem.eql(u8, module, "table")) return table(name, Result, args);
    if (comptime std.mem.eql(u8, module, "codec")) return codec(name, Result, args);
    const locked = comptime std.mem.eql(u8, module, "list") or std.mem.eql(u8, module, "memory") or std.mem.eql(u8, module, "stream");
    if (locked) managed.enter();
    defer if (locked) managed.leave();
    const namespace = comptime if (std.mem.eql(u8, module, "buffer")) "buffers" else if (std.mem.eql(u8, module, "stream")) "streams" else module;
    const function = @field(@field(@This(), namespace), name);
    const info = @typeInfo(@TypeOf(function)).@"fn";
    var converted: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
    inline for (info.params, 0..) |param, index| converted[index] = convert(param.type.?, args[index]);
    if (@typeInfo(Result) == .error_union) return convert(@typeInfo(Result).error_union.payload, try @call(.auto, function, converted));
    return convert(Result, @call(.auto, function, converted));
}

fn serialize(value: anytype, writer: *std.json.Stringify) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |info| {
            if (info.size == .slice and info.child == u8 and !info.is_const) {
                try writer.beginArray();
                for (value) |item| try writer.write(item);
                try writer.endArray();
            } else if (info.size == .slice and info.child != u8) {
                try writer.beginArray();
                for (value) |item| try serialize(item, writer);
                try writer.endArray();
            } else try writer.write(value);
        },
        .optional => {
            if (value) |item| try serialize(item, writer) else try writer.write(null);
        },
        .@"struct" => |info| {
            try writer.beginObject();
            inline for (info.fields) |field| {
                if (field.type == void) continue;
                try writer.objectField(field.name);
                try serialize(@field(value, field.name), writer);
            }
            try writer.endObject();
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("Codec requires a tagged choice");
            try writer.beginObject();
            inline for (info.fields) |field| {
                if (value == @field(Tag, field.name)) {
                    try writer.objectField(field.name);
                    if (field.type == void) {
                        try writer.beginObject();
                        try writer.endObject();
                    } else try serialize(@field(value, field.name), writer);
                    break;
                }
            }
            try writer.endObject();
        },
        else => try writer.write(value),
    }
}

fn Wrapped(comptime T: type) type {
    return struct {
        value: T,

        pub fn jsonStringify(self: @This(), writer: *std.json.Stringify) !void {
            try serialize(self.value, writer);
        }
    };
}

fn codec(comptime name: []const u8, comptime Result: type, args: anytype) Result {
    const Payload = @typeInfo(Result).error_union.payload;
    if (comptime std.mem.eql(u8, name, "encode") or std.mem.eql(u8, name, "marshal")) {
        const encoded = try std.json.Stringify.valueAlloc(allocator, Wrapped(@TypeOf(args[0])){ .value = args[0] }, .{});
        errdefer allocator.free(encoded);
        return try adopt(u8, encoded);
    }
    if (comptime std.mem.eql(u8, name, "decode") or std.mem.eql(u8, name, "unmarshal"))
        return try std.json.parseFromSliceLeaky(Payload, allocator, args[0], .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        });
    @compileError("Unknown codec operation");
}

fn table(comptime name: []const u8, comptime Result: type, args: anytype) Result {
    acquire();
    defer lock.store(false, .release);
    const Payload = @typeInfo(Result).error_union.payload;
    if (comptime std.mem.eql(u8, name, "create")) return @ptrCast(try fastCreate());
    const map = try fastMap(args[0]);
    if (comptime std.mem.eql(u8, name, "put")) {
        var value = args[2];
        try fastPut(map, args[1], std.mem.asBytes(&value));
        return {};
    }
    if (comptime std.mem.eql(u8, name, "length")) return @intCast(map.count);
    if (comptime std.mem.eql(u8, name, "close")) {
        fastClear(map);
        map.alive = false;
        return {};
    }
    if (map.entries.len == 0) {
        if (comptime std.mem.eql(u8, name, "contains") or std.mem.eql(u8, name, "remove")) return false;
        return error.Missing;
    }
    const entry = fastSlot(map, hashBytes(args[1]), args[1], false);
    if (comptime std.mem.eql(u8, name, "contains")) return entry.state == .occupied;
    if (comptime std.mem.eql(u8, name, "remove")) {
        if (entry.state != .occupied) return false;
        allocator.free(entry.key);
        allocator.free(entry.value);
        entry.* = .{ .state = .removed };
        map.count -= 1;
        return true;
    }
    if (comptime std.mem.eql(u8, name, "get")) {
        if (entry.state != .occupied or entry.value.len != @sizeOf(Payload)) return error.Missing;
        const pointer: *align(1) const Payload = @ptrCast(entry.value.ptr);
        return pointer.*;
    }
    @compileError("Unknown table operation");
}

fn sequence(comptime name: []const u8, comptime Result: type, args: anytype) Result {
    if (comptime std.mem.eql(u8, name, "create")) return &.{};
    if (comptime std.mem.eql(u8, name, "length") or std.mem.eql(u8, name, "extent")) return @intCast(args[0].len);
    if (comptime std.mem.eql(u8, name, "view")) {
        const start = std.math.cast(usize, args[1]) orelse return error.Bounds;
        const count = std.math.cast(usize, args[2]) orelse return error.Bounds;
        if (start > args[0].len or count > args[0].len - start) return error.Bounds;
        return args[0][start .. start + count];
    }
    if (comptime std.mem.eql(u8, name, "sized")) {
        const Slice = @typeInfo(Result).error_union.payload;
        const T = @typeInfo(Slice).pointer.child;
        const count: usize = std.math.cast(usize, args[0]) orelse return error.Overflow;
        const items = try sequenceReserve(T, count, count);
        @memset(items, std.mem.zeroes(T));
        return items;
    }
    const T = @typeInfo(@TypeOf(args[0])).pointer.child;
    if (comptime std.mem.eql(u8, name, "compact")) {
        const count: usize = std.math.cast(usize, args[1]) orelse return error.Overflow;
        if (count > args[0].len) return error.Bounds;
        if (count == args[0].len) return args[0];
        const result = try sequenceReserve(T, count, count);
        managed.memory.copyExact(std.mem.sliceAsBytes(result), std.mem.sliceAsBytes(args[0][0..count]));
        metric(&metrics.copied_bytes, count * @sizeOf(T));
        buffers.discard(T, args[0]) catch |err| {
            buffers.discard(T, result) catch {};
            return err;
        };
        return result;
    }
    if (comptime std.mem.eql(u8, name, "release")) return buffers.discard(T, args[0]);
    if (comptime std.mem.eql(u8, name, "copy")) {
        const result = try sequenceReserve(T, args[0].len, args[0].len);
        managed.memory.copyExact(std.mem.sliceAsBytes(result), std.mem.sliceAsBytes(args[0]));
        metric(&metrics.copied_bytes, args[0].len * @sizeOf(T));
        return result;
    }
    if (comptime std.mem.eql(u8, name, "append")) {
        const count = std.math.add(usize, args[0].len, 1) catch return error.Overflow;
        metric(&metrics.growths, 1);
        metric(&metrics.requested, count);
        var capacity = try sequenceCapacity(count);
        var branch = false;
        var retire: ?usize = null;
        acquire();
        if (retained.getPtr(@intFromPtr(args[0].ptr))) |allocation| {
            if (allocation.sequence and allocation.element == @sizeOf(T)) {
                if (args[0].len > allocation.used) {
                    lock.store(false, .release);
                    return error.InvalidBuffer;
                }
                if (args[0].len == allocation.used and allocation.used < allocation.capacity) {
                    if (allocation.references == std.math.maxInt(usize)) {
                        lock.store(false, .release);
                        return error.Overflow;
                    }
                    const pointer: [*]T = @ptrCast(@alignCast(allocation.bytes.ptr));
                    pointer[args[0].len] = args[1];
                    allocation.used = count;
                    allocation.references += 1;
                    capacity = allocation.capacity;
                    lock.store(false, .release);
                    metricCapacity(capacity);
                    return pointer[0..count];
                }
                branch = args[0].len < allocation.used;
                if (!branch) capacity = std.math.mul(usize, allocation.capacity, 2) catch {
                    lock.store(false, .release);
                    return error.Overflow;
                };
                if (!branch and !allocation.retired) retire = @intFromPtr(args[0].ptr);
            }
        }
        lock.store(false, .release);
        const items = try sequenceReserve(T, capacity, count);
        if (retire) |key| {
            acquire();
            if (retained.getPtr(key)) |previous| {
                if (!previous.retired) {
                    previous.retired = true;
                    metric(&metrics.retained, previous.bytes.len);
                }
            }
            lock.store(false, .release);
        }
        const copied = args[0].len * @sizeOf(T);
        metric(&metrics.slowpaths, 1);
        metric(&metrics.growth_bytes, copied);
        metricCapacity(capacity);
        metric(&metrics.copied_bytes, copied);
        if (branch) {
            metric(&metrics.branches, 1);
            metric(&metrics.branchbytes, copied);
        }
        managed.memory.copyExact(std.mem.sliceAsBytes(items[0..args[0].len]), std.mem.sliceAsBytes(args[0]));
        items[count - 1] = args[1];
        return items;
    }
    if (comptime std.mem.eql(u8, name, "remove")) {
        if (args[1] >= args[0].len) return error.Bounds;
        const index: usize = @intCast(args[1]);
        const items = try sequenceReserve(T, args[0].len - 1, args[0].len - 1);
        metric(&metrics.copied_bytes, (args[0].len - 1) * @sizeOf(T));
        managed.memory.copyExact(std.mem.sliceAsBytes(items[0..index]), std.mem.sliceAsBytes(args[0][0..index]));
        managed.memory.copyExact(std.mem.sliceAsBytes(items[index..]), std.mem.sliceAsBytes(args[0][index + 1 ..]));
        return items;
    }
    @compileError("Unknown sequence operation");
}

pub const testing = struct {
    pub fn expect(value: bool) void {
        if (!value) @panic("AssertionFailed");
    }
    pub fn same(actual: []const u8, expected: []const u8) void {
        if (!std.mem.eql(u8, actual, expected)) @panic("TextMismatch");
    }
    pub fn number(actual: u64, expected: u64) void {
        if (actual != expected) @panic("NumberMismatch");
    }
    pub fn positive(value: u64) void {
        if (value == 0) @panic("ExpectedPositive");
    }
    pub fn real(actual: f64, expected: f64) void {
        if (actual != expected) @panic("NumberMismatch");
    }
    pub fn point(actual: ?u32, expected: u32) void {
        if (actual == null or actual.? != expected) @panic("PointMismatch");
    }
};

pub const checksum = struct {
    pub const State = struct { value: u32 = 0xffffffff };
    pub fn update(state: *State, bytes: []const u8) void {
        for (bytes) |byte| {
            state.value ^= byte;
            for (0..8) |_| state.value = (state.value >> 1) ^
                (if ((state.value & 1) != 0) @as(u32, 0x82f63b78) else 0);
        }
    }
    pub fn compute(bytes: []const u8) u32 {
        var state = State{};
        update(&state, bytes);
        return ~state.value;
    }
    pub fn begin() !*State {
        const state = try allocator.create(State);
        state.* = .{};
        return state;
    }
    pub fn result(state: *State) u32 { return ~state.value; }
    pub fn close(state: *State) void { allocator.destroy(state); }
};

pub const binary = struct {
    pub fn octet(value: u64) !u8 {
        return std.math.cast(u8, value) orelse error.Bounds;
    }
    pub fn widen(value: u8) u64 {
        return value;
    }
    pub fn encode(value: u64) ![]u8 {
        var rest = value;
        var count: usize = 1;
        while (rest >= 128) : (count += 1) rest >>= 7;
        const bytes = try sequenceReserve(u8, count, count);
        rest = value;
        for (bytes, 0..) |*byte, index| {
            byte.* = @truncate(rest & 127);
            rest >>= 7;
            if (index + 1 < count) byte.* |= 128;
        }
        return bytes;
    }
    fn read(source: []const u8, offset: u64) !struct { value: u64, next: u64 } {
        const start = std.math.cast(usize, offset) orelse return error.Bounds;
        if (start > source.len) return error.Bounds;
        var value: u64 = 0;
        for (source[start..], 0..) |byte, index| {
            if (index >= 10) return error.InvalidEncoding;
            const part = byte & 127;
            if (index == 9 and part > 1) return error.InvalidEncoding;
            value |= @as(u64, part) << @as(u6, @intCast(index * 7));
            if (byte & 128 == 0) {
                if (index > 0 and part == 0) return error.InvalidEncoding;
                return .{ .value = value, .next = offset + index + 1 };
            }
        }
        return error.InvalidEncoding;
    }
    pub fn scan(source: []const u8, offset: u64) !u64 {
        return (try read(source, offset)).value;
    }
    pub fn next(source: []const u8, offset: u64) !u64 {
        return (try read(source, offset)).next;
    }
    pub fn zigzag(value: i64) ![]u8 {
        const bits: u64 = @bitCast(value);
        return encode((bits << 1) ^ (if (value < 0) std.math.maxInt(u64) else @as(u64, 0)));
    }
    pub fn unfold(source: []const u8, offset: u64) !i64 {
        const value = (try read(source, offset)).value;
        const bits = (value >> 1) ^ (if (value & 1 != 0) std.math.maxInt(u64) else @as(u64, 0));
        return @bitCast(bits);
    }
    pub fn hex(value: []const u8) ![]const u8 {
        if (value.len > std.math.maxInt(usize) / 2) return error.OutOfMemory;
        const output = try allocator.alloc(u8, value.len * 2);
        defer allocator.free(output);
        const digits = "0123456789abcdef";
        for (value, 0..) |byte, index| {
            output[index * 2] = digits[byte >> 4];
            output[index * 2 + 1] = digits[byte & 15];
        }
        return retain(u8, output);
    }
    pub fn unpack(value: []const u8) ![]u8 {
        if (value.len % 2 != 0) return error.InvalidEncoding;
        for (value) |byte| {
            if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f')))
                return error.InvalidEncoding;
        }
        const output = try sequenceReserve(u8, value.len / 2, value.len / 2);
        _ = std.fmt.hexToBytes(output, value) catch unreachable;
        return output;
    }
    pub fn base64(value: []const u8) ![]const u8 {
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const groups = value.len / 3;
        const extra = if (value.len % 3 == 0) @as(usize, 0) else value.len % 3 + 1;
        if (groups > (std.math.maxInt(usize) - extra) / 4) return error.OutOfMemory;
        const output = try allocator.alloc(u8, encoder.calcSize(value.len));
        defer allocator.free(output);
        return retain(u8, encoder.encode(output, value));
    }
    pub fn restore(value: []const u8) ![]u8 {
        const decoder = std.base64.url_safe_no_pad.Decoder;
        const size = decoder.calcSizeForSlice(value) catch return error.InvalidEncoding;
        const decoded = try allocator.alloc(u8, size);
        defer allocator.free(decoded);
        decoder.decode(decoded, value) catch return error.InvalidEncoding;
        const output = try sequenceReserve(u8, size, size);
        @memcpy(output, decoded);
        return output;
    }
    fn endian(name: []const u8) !bool {
        if (std.mem.eql(u8, name, "little")) return true;
        if (std.mem.eql(u8, name, "big")) return false;
        return error.InvalidInput;
    }
    pub fn fixed(value: u64, width: u64, name: []const u8) ![]u8 {
        const little = try endian(name);
        if (width < 1 or width > 8 or
            (width < 8 and value >= (@as(u64, 1) << @as(u6, @intCast(width * 8)))))
            return error.InvalidInput;
        const count: usize = @intCast(width);
        const bytes = try sequenceReserve(u8, count, count);
        var rest = value;
        for (0..count) |index| {
            bytes[if (little) index else count - index - 1] = @truncate(rest);
            rest >>= 8;
        }
        return bytes;
    }
    pub fn parse(source: []const u8, offset: u64, width: u64, name: []const u8) !u64 {
        const little = try endian(name);
        if (width < 1 or width > 8) return error.InvalidInput;
        const start = std.math.cast(usize, offset) orelse return error.Bounds;
        const count: usize = @intCast(width);
        if (start > source.len or count > source.len - start) return error.Bounds;
        var value: u64 = 0;
        for (0..count) |index| {
            const slot = if (little) count - index - 1 else index;
            value = (value << 8) | source[start + slot];
        }
        return value;
    }
};

pub const crypto = struct {
    const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
    const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;
    const Ed = std.crypto.sign.Ed25519;
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
    pub const Hasher = struct {
        state: std.crypto.hash.sha2.Sha256,
        digest: [32]u8 = undefined,
        finalized: bool = false,
    };
    pub const Authenticator = struct {
        state: Hmac,
        digest: [Hmac.mac_length]u8 = undefined,
        finalized: bool = false,
    };
    pub const BlakeHasher = struct { state: std.crypto.hash.Blake3 };
    fn digestCopy(value: [32]u8) ![]u8 {
        const bytes = try sequenceReserve(u8, 32, 32);
        @memcpy(bytes, &value);
        return bytes;
    }
    pub fn hash(data: []const u8) ![]const u8 {
        var output: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &output, .{});
        return retain(u8, &std.fmt.bytesToHex(output, .lower));
    }
    pub fn digest(data: []const u8) ![]u8 {
        var output: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &output, .{});
        return digestCopy(output);
    }
    pub fn hex(data: []const u8) ![]const u8 {
        return hash(data);
    }
    pub fn begin() !*Hasher {
        const hasher = try allocator.create(Hasher);
        hasher.* = .{ .state = std.crypto.hash.sha2.Sha256.init(.{}) };
        return hasher;
    }
    pub fn update(value: *Hasher, data: []const u8) !void {
        if (value.finalized) return error.AlreadyFinalized;
        value.state.update(data);
    }
    fn finish(value: *Hasher) void {
        if (!value.finalized) {
            value.state.final(&value.digest);
            value.finalized = true;
        }
    }
    pub fn finalize(value: *Hasher) ![]const u8 {
        finish(value);
        return retain(u8, &std.fmt.bytesToHex(value.digest, .lower));
    }
    pub fn result(value: *Hasher) ![]u8 {
        finish(value);
        return digestCopy(value.digest);
    }
    pub fn close(value: *Hasher) void {
        allocator.destroy(value);
    }
    pub fn blake(data: []const u8) ![]u8 {
        var hash_value: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(data, &hash_value, .{});
        return digestCopy(hash_value);
    }
    pub fn fingerprint(data: []const u8) ![]const u8 {
        var hash_value: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(data, &hash_value, .{});
        return retain(u8, &std.fmt.bytesToHex(hash_value, .lower));
    }
    pub fn initiate() !*BlakeHasher {
        const value = try allocator.create(BlakeHasher);
        value.* = .{ .state = std.crypto.hash.Blake3.init(.{}) };
        return value;
    }
    pub fn append(value: *BlakeHasher, data: []const u8) !void {
        value.state.update(data);
    }
    pub fn extract(value: *BlakeHasher) ![]u8 {
        var hash_value: [32]u8 = undefined;
        value.state.final(&hash_value);
        return digestCopy(hash_value);
    }
    pub fn render(value: *BlakeHasher) ![]const u8 {
        var hash_value: [32]u8 = undefined;
        value.state.final(&hash_value);
        return retain(u8, &std.fmt.bytesToHex(hash_value, .lower));
    }
    pub fn retire(value: *BlakeHasher) void {
        std.crypto.secureZero(u8, std.mem.asBytes(value));
        allocator.destroy(value);
    }
    pub fn auth(secret: []const u8) !*Authenticator {
        const value = try allocator.create(Authenticator);
        value.* = .{ .state = Hmac.init(secret) };
        return value;
    }
    pub fn absorb(value: *Authenticator, bytes: []const u8) !void {
        if (value.finalized) return error.AlreadyFinalized;
        value.state.update(bytes);
    }
    fn authfinish(value: *Authenticator) void {
        if (!value.finalized) {
            value.state.final(&value.digest);
            value.finalized = true;
        }
    }
    pub fn tag(value: *Authenticator) ![]u8 {
        authfinish(value);
        return digestCopy(value.digest);
    }
    pub fn check(value: *Authenticator, expected: []const u8) !bool {
        authfinish(value);
        return expected.len == Hmac.mac_length and
            std.crypto.timing_safe.eql([Hmac.mac_length]u8, value.digest, expected[0..Hmac.mac_length].*);
    }
    pub fn discard(value: *Authenticator) void {
        std.crypto.secureZero(u8, std.mem.asBytes(value));
        allocator.destroy(value);
    }
    pub fn derive(secret: []const u8, salt: []const u8, context: []const u8, size: u64) ![]u8 {
        if (size > 255 * Hmac.mac_length) return error.InvalidLength;
        const length = std.math.cast(usize, size) orelse return error.InvalidLength;
        const output = try sequenceReserve(u8, length, length);
        var prk = Hkdf.extract(salt, secret);
        defer std.crypto.secureZero(u8, &prk);
        Hkdf.expand(output, context, prk);
        return output;
    }
    pub fn compare(left: []const u8, right: []const u8) bool {
        if (left.len != right.len) return false;
        return std.crypto.timing_safe.compare(u8, left, right, .little) == .eq;
    }
    pub fn random(size: u32) ![]const u8 {
        const buffer = try allocator.alloc(u8, size);
        defer allocator.free(buffer);
        try runtimeIo().randomSecure(buffer);
        return retain(u8, buffer);
    }
    pub fn reproduce(seed: []const u8, label: []const u8, size: u32) ![]u8 {
        if (seed.len != 32 or size > 1048576) return error.InvalidLength;
        const output = try sequenceReserve(u8, size, size);
        var state = std.crypto.hash.Blake3.init(.{ .key = seed[0..32].* });
        defer std.crypto.secureZero(u8, std.mem.asBytes(&state));
        state.update("FOO deterministic test stream v1\x00");
        state.update(label);
        state.final(output);
        return output;
    }
    fn cipher(algorithm: []const u8, secret: []const u8, nonce: []const u8) !bool {
        const aes = std.mem.eql(u8, algorithm, "aes256gcm");
        if (!aes and !std.mem.eql(u8, algorithm, "xchacha20poly1305")) return error.InvalidAlgorithmOrLength;
        if (secret.len != 32 or nonce.len != (if (aes) @as(usize, 12) else 24)) return error.InvalidAlgorithmOrLength;
        return aes;
    }
    pub fn available(algorithm: []const u8) bool {
        return std.mem.eql(u8, algorithm, "xchacha20poly1305") or
            std.mem.eql(u8, algorithm, "aes256gcm");
    }
    pub fn wrap(algorithm: []const u8, data: []const u8, secret: []const u8, nonce: []const u8, extra: []const u8) ![]u8 {
        const aes = try cipher(algorithm, secret, nonce);
        if (data.len > std.math.maxInt(usize) - 16) return error.InvalidLength;
        const output = try sequenceReserve(u8, data.len + 16, data.len + 16);
        if (aes) {
            Aes.encrypt(output[0..data.len], output[data.len..][0..16], data, extra, nonce[0..12].*, secret[0..32].*);
        } else {
            Aead.encrypt(output[0..data.len], output[data.len..][0..16], data, extra, nonce[0..24].*, secret[0..32].*);
        }
        return output;
    }
    pub fn unwrap(algorithm: []const u8, data: []const u8, secret: []const u8, nonce: []const u8, extra: []const u8) ![]u8 {
        const aes = try cipher(algorithm, secret, nonce);
        if (data.len < 16) return error.InvalidAlgorithmOrLength;
        const length = data.len - 16;
        const plain = try allocator.alloc(u8, length);
        defer {
            std.crypto.secureZero(u8, plain);
            allocator.free(plain);
        }
        if (aes) {
            Aes.decrypt(plain, data[0..length], data[length..][0..16].*, extra, nonce[0..12].*, secret[0..32].*) catch return error.AuthenticationFailed;
        } else {
            Aead.decrypt(plain, data[0..length], data[length..][0..16].*, extra, nonce[0..24].*, secret[0..32].*) catch return error.AuthenticationFailed;
        }
        const output = try sequenceReserve(u8, length, length);
        @memcpy(output, plain);
        return output;
    }
    pub const SecureKey = struct { bytes: [32]u8 };
    const WindowsLock = struct {
        extern "kernel32" fn VirtualLock(?*const anyopaque, usize) callconv(.winapi) i32;
        extern "kernel32" fn VirtualUnlock(?*const anyopaque, usize) callconv(.winapi) i32;
    };
    const PosixLock = struct {
        extern "c" fn mlock(?*const anyopaque, usize) c_int;
        extern "c" fn munlock(?*const anyopaque, usize) c_int;
    };
    pub fn protect(secret: []const u8) !*SecureKey {
        if (secret.len != 32) return error.InvalidLength;
        const protected = try std.heap.page_allocator.create(SecureKey);
        const locked = if (builtin.os.tag == .windows)
            WindowsLock.VirtualLock(protected, @sizeOf(SecureKey)) != 0
        else
            PosixLock.mlock(protected, @sizeOf(SecureKey)) == 0;
        if (!locked) {
            std.heap.page_allocator.destroy(protected);
            return error.SecureMemoryUnavailable;
        }
        @memcpy(&protected.bytes, secret);
        return protected;
    }
    pub fn shield(algorithm: []const u8, data: []const u8, protected: *SecureKey, nonce: []const u8, extra: []const u8) ![]u8 {
        return wrap(algorithm, data, &protected.bytes, nonce, extra);
    }
    pub fn reveal(algorithm: []const u8, data: []const u8, protected: *SecureKey, nonce: []const u8, extra: []const u8) ![]u8 {
        return unwrap(algorithm, data, &protected.bytes, nonce, extra);
    }
    pub fn forget(protected: *SecureKey) void {
        std.crypto.secureZero(u8, std.mem.asBytes(protected));
        if (builtin.os.tag == .windows) {
            _ = WindowsLock.VirtualUnlock(protected, @sizeOf(SecureKey));
        } else {
            _ = PosixLock.munlock(protected, @sizeOf(SecureKey));
        }
        std.heap.page_allocator.destroy(protected);
    }
    pub fn seal(data: []const u8, secret: []const u8, nonce: []const u8, context: []const u8) ![]const u8 {
        if (secret.len != Aead.key_length or nonce.len != Aead.nonce_length) return error.InvalidLength;
        const buffer = try allocator.alloc(u8, data.len + Aead.tag_length);
        defer allocator.free(buffer);
        Aead.encrypt(buffer[0..data.len], buffer[data.len..][0..Aead.tag_length], data, context, nonce[0..Aead.nonce_length].*, secret[0..Aead.key_length].*);
        return retain(u8, buffer);
    }
    pub fn open(data: []const u8, secret: []const u8, nonce: []const u8, context: []const u8) ![]const u8 {
        if (secret.len != Aead.key_length or nonce.len != Aead.nonce_length or data.len < Aead.tag_length) return error.InvalidLength;
        const length = data.len - Aead.tag_length;
        const buffer = try allocator.alloc(u8, length);
        defer allocator.free(buffer);
        try Aead.decrypt(buffer, data[0..length], data[length..][0..Aead.tag_length].*, context, nonce[0..Aead.nonce_length].*, secret[0..Aead.key_length].*);
        return retain(u8, buffer);
    }
    pub fn key(seed: []const u8) ![]const u8 {
        if (seed.len != 32) return error.InvalidLength;
        const pair = try Ed.KeyPair.generateDeterministic(seed[0..32].*);
        return retain(u8, &pair.public_key.toBytes());
    }
    pub fn sign(data: []const u8, seed: []const u8) ![]const u8 {
        if (seed.len != 32) return error.InvalidLength;
        const pair = try Ed.KeyPair.generateDeterministic(seed[0..32].*);
        const signature = try pair.sign(data, null);
        return retain(u8, &signature.toBytes());
    }
    pub fn verify(data: []const u8, signature: []const u8, public: []const u8) bool {
        if (signature.len != 64 or public.len != 32) return false;
        const public_key = Ed.PublicKey.fromBytes(public[0..32].*) catch return false;
        Ed.Signature.fromBytes(signature[0..64].*).verify(data, public_key) catch return false;
        return true;
    }
    pub fn password(value: []const u8) ![]const u8 {
        var buffer: [256]u8 = undefined;
        const encoded = try std.crypto.pwhash.argon2.strHash(value, .{ .allocator = allocator, .params = .{ .t = 3, .m = 65536, .p = 1 } }, &buffer, runtimeIo());
        return retain(u8, encoded);
    }
    pub fn confirm(value: []const u8, encoded: []const u8) !bool {
        if (encoded.len > 256) return error.InvalidEncoding;
        if (!std.mem.startsWith(u8, encoded, "$argon2id$v=19$m=65536,t=3,p=1$")) return error.UnsupportedParameters;
        std.crypto.pwhash.argon2.strVerify(encoded, value, .{ .allocator = allocator }, runtimeIo()) catch |err| switch (err) {
            error.PasswordVerificationFailed => return false,
            else => return err,
        };
        return true;
    }
};

pub const unicode = struct {
    pub const Cursor = struct { bytes: []u8, iterator: std.unicode.Utf8Iterator };
    pub fn valid(value: []const u8) bool {
        return std.unicode.utf8ValidateSlice(value);
    }
    pub fn scan(value: []const u8) !*Cursor {
        if (!valid(value)) return error.InvalidUtf8;
        const bytes = try cloneBytes(value);
        errdefer allocator.free(bytes);
        const result = try allocator.create(Cursor);
        result.* = .{ .bytes = bytes, .iterator = std.unicode.Utf8View.initUnchecked(bytes).iterator() };
        return result;
    }
    pub fn next(value: *Cursor) ?u32 {
        return if (value.iterator.nextCodepoint()) |point| @as(u32, point) else null;
    }
    pub fn release(value: *Cursor) void {
        allocator.free(value.bytes);
        allocator.destroy(value);
    }
    pub fn points(value: []const u8) ![]u32 {
        var iterator = (try std.unicode.Utf8View.init(value)).iterator();
        var result: std.ArrayList(u32) = .empty;
        defer result.deinit(allocator);
        while (iterator.nextCodepoint()) |point| try result.append(allocator, point);
        return retain(u32, result.items);
    }
    pub fn wide(value: []const u8) ![]u16 {
        const result = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
        defer allocator.free(result);
        return retain(u16, result);
    }
    pub fn narrow(value: []u16) ![]const u8 {
        const result = try std.unicode.utf16LeToUtf8Alloc(allocator, value);
        defer allocator.free(result);
        return retain(u8, result);
    }
};

pub const compress = struct {
    pub fn header(size: u64) ![]const u8 {
        if (size == 0 or size > std.math.maxInt(u32)) return error.StreamTooLong;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(size), .little);
        return retain(u8, &bytes);
    }
    pub fn extent(bytes: []const u8) !u64 {
        if (bytes.len != 4) return error.InvalidCompressedData;
        const size = std.mem.readInt(u32, bytes[0..4], .little);
        if (size == 0) return error.InvalidCompressedData;
        return size;
    }
    fn container(format: []const u8) !std.compress.flate.Container {
        if (std.mem.eql(u8, format, "gzip")) return .gzip;
        if (std.mem.eql(u8, format, "zlib")) return .zlib;
        return error.UnknownFormat;
    }
    pub fn pack(value: []const u8, format: []const u8) ![]const u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try output.writer.ensureUnusedCapacity(4096);
        const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(window);
        var compressor = try std.compress.flate.Compress.init(&output.writer, window, try container(format), .{ .good = 4, .nice = 32, .lazy = 4, .chain = 16 });
        try compressor.writer.writeAll(value);
        try compressor.finish();
        return retain(u8, output.written());
    }
    pub fn unpack(value: []const u8, format: []const u8, limit: u32) ![]const u8 {
        var input: std.Io.Reader = .fixed(value);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decoder = std.compress.flate.Decompress.init(&input, try container(format), &window);
        const buffer = try allocator.alloc(u8, limit);
        defer allocator.free(buffer);
        var output: std.Io.Writer = .fixed(buffer);
        _ = decoder.reader.streamRemaining(&output) catch |err| {
            if (decoder.err) |failure| return failure;
            return err;
        };
        if (input.seek != value.len) return error.TrailingData;
        switch (decoder.container_metadata) {
            .gzip => |metadata| {
                if (metadata.crc != std.hash.Crc32.hash(output.buffered())) return error.WrongGzipChecksum;
                if (metadata.count != @as(u32, @truncate(output.buffered().len))) return error.WrongGzipSize;
            },
            .zlib => |metadata| if (metadata.adler != std.hash.Adler32.hash(output.buffered())) return error.WrongZlibChecksum,
            .raw => unreachable,
        }
        return retain(u8, output.buffered());
    }
};

pub const system = struct {
    pub fn cores() !u32 {
        return @intCast(try std.Thread.getCpuCount());
    }
    pub fn page() u64 {
        return std.heap.pageSize();
    }
    const Windows = struct {
        extern "kernel32" fn GetComputerNameW([*]u16, *u32) callconv(.winapi) i32;
    };
    pub fn host() ![]const u8 {
        if (builtin.os.tag == .windows) {
            var buffer: [256]u16 = undefined;
            var size: u32 = buffer.len;
            if (Windows.GetComputerNameW(&buffer, &size) == 0) return error.HostnameUnavailable;
            const value = try std.unicode.utf16LeToUtf8Alloc(allocator, buffer[0..size]);
            defer allocator.free(value);
            return retain(u8, value);
        }
        var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
        return retain(u8, try std.posix.gethostname(&buffer));
    }
};

pub const http = struct {
    const StoredHeader = struct { name: []u8, value: []u8 };
    pub const Client = struct {
        inner: std.http.Client,
        headers: []StoredHeader = &.{},
        redirects: u16 = 10,
        reuse_connections: bool = true,
    };
    pub const Response = struct { code: u16, bytes: []u8 };
    pub const Server = std.Io.net.Server;
    pub const Peer = struct {
        stream: std.Io.net.Stream,
        input: [16384]u8 = undefined,
        output: [4096]u8 = undefined,
        reader: std.Io.net.Stream.Reader,
        writer: std.Io.net.Stream.Writer,
        server: std.http.Server,
        request: ?std.http.Server.Request = null,
        consumed: bool = false,
    };
    pub fn client() !*Client {
        const result = try allocator.create(Client);
        result.* = .{ .inner = .{ .allocator = allocator, .io = runtimeIo() } };
        return result;
    }
    pub fn close(value: *Client) void {
        clear(value);
        value.inner.deinit();
        allocator.destroy(value);
    }
    pub fn trust(value: *Client, path: []const u8) !void {
        const now = std.Io.Clock.real.now(value.inner.io);
        value.inner.ca_bundle_lock.lockUncancelable(value.inner.io);
        defer value.inner.ca_bundle_lock.unlock(value.inner.io);
        if (value.inner.now == null) try value.inner.ca_bundle.rescan(value.inner.allocator, value.inner.io, now);
        try value.inner.ca_bundle.addCertsFromFilePath(value.inner.allocator, value.inner.io, now, .cwd(), path);
        value.inner.now = now;
    }
    fn validHeader(name: []const u8, content: []const u8) bool {
        if (name.len == 0) return false;
        for (name) |byte| if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) != null)) return false;
        for (content) |byte| if (byte == '\r' or byte == '\n') return false;
        return true;
    }
    pub fn attach(value: *Client, name: []const u8, content: []const u8) !void {
        if (!validHeader(name, content)) return error.InvalidHeader;
        const stored_name = try cloneBytes(name);
        errdefer allocator.free(stored_name);
        const stored_value = try cloneBytes(content);
        errdefer allocator.free(stored_value);
        const next = try allocator.alloc(StoredHeader, value.headers.len + 1);
        if (value.headers.len > 0) {
            managed.memory.copyExact(std.mem.sliceAsBytes(next[0..value.headers.len]), std.mem.sliceAsBytes(value.headers));
            allocator.free(value.headers);
        }
        next[value.headers.len] = .{ .name = stored_name, .value = stored_value };
        value.headers = next;
    }
    pub fn clear(value: *Client) void {
        for (value.headers) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        if (value.headers.len > 0) allocator.free(value.headers);
        value.headers = &.{};
    }
    pub fn redirects(value: *Client, limit: u16) !void {
        if (limit > 100) return error.InvalidRedirectLimit;
        value.redirects = limit;
    }
    pub fn reuse(value: *Client, enabled: bool) void {
        value.reuse_connections = enabled;
    }
    pub fn request(value: *Client, url: []const u8, verbname: []const u8, content: []const u8, limit: u32) !*Response {
        const verb = std.meta.stringToEnum(std.http.Method, verbname) orelse return error.InvalidMethod;
        const buffer = try allocator.alloc(u8, limit);
        defer allocator.free(buffer);
        var writer: std.Io.Writer = .fixed(buffer);
        const headers = try allocator.alloc(std.http.Header, value.headers.len);
        defer allocator.free(headers);
        for (value.headers, 0..) |entry, index| headers[index] = .{ .name = entry.name, .value = entry.value };
        const response = try value.inner.fetch(.{
            .location = .{ .url = url },
            .method = verb,
            .payload = if (verb.requestHasBody()) content else null,
            .response_writer = &writer,
            .keep_alive = value.reuse_connections,
            .redirect_behavior = if (value.redirects == 0) .not_allowed else .init(value.redirects),
            .extra_headers = headers,
        });
        const result = try allocator.create(Response);
        errdefer allocator.destroy(result);
        result.* = .{ .code = @intFromEnum(response.status), .bytes = try cloneBytes(writer.buffered()) };
        return result;
    }
    pub fn status(value: *Response) u16 {
        return value.code;
    }
    pub fn body(value: *Response) ![]const u8 {
        return retain(u8, value.bytes);
    }
    pub fn release(value: *Response) void {
        allocator.free(value.bytes);
        allocator.destroy(value);
    }
    pub fn listen(address: []const u8, number: u16) !*Server {
        const result = try allocator.create(Server);
        errdefer allocator.destroy(result);
        const ip = try std.Io.net.IpAddress.parse(address, number);
        result.* = try ip.listen(runtimeIo(), .{ .reuse_address = true });
        return result;
    }
    pub fn port(value: *Server) u16 {
        return value.socket.address.getPort();
    }
    pub fn stop(value: *Server) void {
        value.deinit(runtimeIo());
        allocator.destroy(value);
    }

    pub fn shutdown(value: *Server) void {
        stop(value);
    }
    pub fn accept(value: *Server) !*Peer {
        const result = try allocator.create(Peer);
        errdefer allocator.destroy(result);
        const stream = try value.accept(runtimeIo());
        result.* = .{ .stream = stream, .reader = undefined, .writer = undefined, .server = undefined };
        result.reader = stream.reader(runtimeIo(), &result.input);
        result.writer = stream.writer(runtimeIo(), &result.output);
        result.server = .init(&result.reader.interface, &result.writer.interface);
        return result;
    }
    pub fn receive(value: *Peer) ![]const u8 {
        if (value.request != null) return error.ResponseRequired;
        value.request = try value.server.receiveHead();
        value.consumed = false;
        return retain(u8, value.request.?.head.target);
    }
    pub fn method(value: *Peer) ![]const u8 {
        return @tagName((value.request orelse return error.RequestRequired).head.method);
    }
    pub fn header(value: *Peer, name: []const u8) ![]const u8 {
        if (value.consumed) return error.BodyConsumed;
        const current = value.request orelse return error.RequestRequired;
        var headers = current.iterateHeaders();
        while (headers.next()) |entry| if (std.ascii.eqlIgnoreCase(entry.name, name)) return retain(u8, entry.value);
        return error.MissingHeader;
    }
    pub fn read(value: *Peer, limit: u32) ![]const u8 {
        if (value.consumed) return error.BodyConsumed;
        const current = if (value.request) |*r| r else return error.RequestRequired;
        const buffer = try allocator.alloc(u8, limit);
        defer allocator.free(buffer);
        value.consumed = true;
        const input = try current.readerExpectContinue(&.{});
        var output: std.Io.Writer = .fixed(buffer);
        _ = try input.streamRemaining(&output);
        return retain(u8, output.buffered());
    }
    pub fn reply(value: *Peer, code: u16, content: []const u8, keep_alive: bool) !void {
        if (code < 200 or code > 599) return error.InvalidStatus;
        const current = if (value.request) |*r| r else return error.RequestRequired;
        try current.respond(content, .{ .status = @enumFromInt(code), .keep_alive = keep_alive });
        value.request = null;
    }
    pub fn disconnect(value: *Peer) void {
        value.stream.close(runtimeIo());
        allocator.destroy(value);
    }
};

pub const json = struct {
    pub const Value = struct { parsed: std.json.Parsed(std.json.Value) };
    pub fn parse(source: []const u8) !*Value {
        const result = try allocator.create(Value);
        errdefer allocator.destroy(result);
        result.* = .{ .parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .parse_numbers = false }) };
        return result;
    }
    pub fn release(value: *Value) void {
        value.parsed.deinit();
        allocator.destroy(value);
    }
    fn encode(value: std.json.Value) ![]const u8 {
        const result = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(result);
        return retain(u8, result);
    }
    pub fn write(value: *Value) ![]const u8 {
        return encode(value.parsed.value);
    }
    pub fn field(value: *Value, name: []const u8) ![]const u8 {
        if (value.parsed.value != .object) return error.ExpectedObject;
        return encode(value.parsed.value.object.get(name) orelse return error.MissingField);
    }
    pub fn item(value: *Value, index: u32) ![]const u8 {
        if (value.parsed.value != .array) return error.ExpectedArray;
        if (index >= value.parsed.value.array.items.len) return error.Bounds;
        return encode(value.parsed.value.array.items[index]);
    }
    pub fn quote(value: []const u8) ![]const u8 {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        return encode(.{ .string = value });
    }
    pub fn kind(value: *Value) []const u8 {
        return if (value.parsed.value == .number_string) "number" else @tagName(value.parsed.value);
    }
    pub fn size(value: *Value) !u32 {
        return @intCast(switch (value.parsed.value) {
            .object => |object| object.count(),
            .array => |array| array.items.len,
            .string => |string| string.len,
            else => return error.ExpectedContainer,
        });
    }
    pub fn set(value: *Value, name: []const u8, source: []const u8) !void {
        if (value.parsed.value != .object) return error.ExpectedObject;
        if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8;
        const storage = value.parsed.arena.allocator();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, storage, source, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .parse_numbers = false });
        try value.parsed.value.object.put(storage, try storage.dupe(u8, name), parsed);
    }
    pub fn append(value: *Value, source: []const u8) !void {
        if (value.parsed.value != .array) return error.ExpectedArray;
        const storage = value.parsed.arena.allocator();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, storage, source, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .parse_numbers = false });
        try value.parsed.value.array.append(parsed);
    }
    pub const Stream = struct {
        scanner: std.json.Scanner,
        chunk: []const u8 = &.{},
        ready: bool = true,
        ended: bool = false,
        failed: bool = false,
        token: std.json.Token = .end_of_document,
    };
    pub fn stream() !*Stream {
        const result = try allocator.create(Stream);
        result.* = .{ .scanner = .initStreaming(allocator) };
        return result;
    }
    pub fn feed(value: *Stream, chunk: []const u8, final: bool) !void {
        if (!value.ready or value.ended or value.failed) return error.InvalidState;
        const owned = try cloneBytes(chunk);
        allocator.free(value.chunk);
        value.chunk = owned;
        value.token = .end_of_document;
        value.scanner.feedInput(value.chunk);
        value.ready = false;
        if (final) {
            value.scanner.endInput();
            value.ended = true;
        }
    }
    // Fragments let callers consume large strings without buffering a document.
    pub fn next(value: *Stream) ![]const u8 {
        if (value.failed) return error.InvalidState;
        const token = value.scanner.next() catch |err| switch (err) {
            error.BufferUnderrun => {
                value.ready = true;
                value.token = .end_of_document;
                return "more";
            },
            else => {
                value.failed = true;
                value.token = .end_of_document;
                return err;
            },
        };
        value.token = token;
        return @tagName(token);
    }
    pub fn data(value: *Stream) ![]const u8 {
        return switch (value.token) {
            .string, .number, .partial_string, .partial_number => |bytes| retain(u8, bytes),
            .partial_string_escaped_1 => |bytes| retain(u8, &bytes),
            .partial_string_escaped_2 => |bytes| retain(u8, &bytes),
            .partial_string_escaped_3 => |bytes| retain(u8, &bytes),
            .partial_string_escaped_4 => |bytes| retain(u8, &bytes),
            else => "",
        };
    }
    pub fn close(value: *Stream) void {
        value.scanner.deinit();
        allocator.free(value.chunk);
        allocator.destroy(value);
    }
};
