const std = @import("std");
const allocator = std.heap.page_allocator;

const Metrics = struct {
    allocations: u64 = 0,
    allocated: u64 = 0,
    reallocations: u64 = 0,
    copied: u64 = 0,
    growths: u64 = 0,
    growth_copied: u64 = 0,
    capacity_total: u64 = 0,
    capacity_max: u64 = 0,
    requested: u64 = 0,
    live: u64 = 0,
    peak: u64 = 0,
    retained: u64 = 0,
    slow: u64 = 0,
    branches: u64 = 0,
    branchcopied: u64 = 0,
};
var metrics: Metrics = .{};
var sink: u64 = 0;

fn reserve(comptime T: type, count: usize) ![]T {
    const result = try allocator.alloc(T, count);
    @memset(result, std.mem.zeroes(T));
    metrics.allocations += 1;
    metrics.allocated += count * @sizeOf(T);
    metrics.live += count * @sizeOf(T);
    metrics.peak = @max(metrics.peak, metrics.live);
    return result;
}
fn dispose(comptime T: type, values: []T) void {
    metrics.live -= values.len * @sizeOf(T);
    allocator.free(values);
}
const Buffer = struct {
    data: []u64,
    used: usize,
    retired: bool = false,
    next: ?*Buffer = null,
};
const View = struct { buffer: ?*Buffer = null, length: usize = 0 };
var buffers: ?*Buffer = null;

fn capacity(count: usize) usize {
    var result: usize = 8;
    while (result < count) result *= 2;
    return result;
}
fn appendSeq(source: View, value: u64) !View {
    const count = source.length + 1;
    var available = capacity(count);
    metrics.growths += 1;
    metrics.requested += count;
    if (source.buffer) |buffer| {
        if (source.length == buffer.used and buffer.used < buffer.data.len) {
            buffer.data[source.length] = value;
            buffer.used = count;
            metrics.capacity_total += buffer.data.len;
            metrics.capacity_max = @max(metrics.capacity_max, buffer.data.len);
            return .{ .buffer = buffer, .length = count };
        }
    }
    const branch = if (source.buffer) |buffer| source.length < buffer.used else false;
    if (source.buffer) |buffer| {
        if (!branch) {
            available = buffer.data.len * 2;
            if (!buffer.retired) {
                buffer.retired = true;
                metrics.retained += buffer.data.len * @sizeOf(u64);
            }
        }
    }
    const buffer = try allocator.create(Buffer);
    errdefer allocator.destroy(buffer);
    buffer.* = .{ .data = try reserve(u64, available), .used = count, .next = buffers };
    buffers = buffer;
    if (source.buffer) |previous| {
        @memcpy(buffer.data[0..source.length], previous.data[0..source.length]);
        const copied = source.length * @sizeOf(u64);
        metrics.copied += copied;
        metrics.growth_copied += copied;
        if (branch) {
            metrics.branches += 1;
            metrics.branchcopied += copied;
        }
    }
    buffer.data[source.length] = value;
    metrics.slow += 1;
    metrics.capacity_total += available;
    metrics.capacity_max = @max(metrics.capacity_max, available);
    return .{ .buffer = buffer, .length = count };
}
fn discard(value: View) void {
    const target = value.buffer orelse return;
    var cursor = &buffers;
    while (cursor.*) |buffer| {
        if (buffer == target) {
            cursor.* = buffer.next;
            const size = buffer.data.len * @sizeOf(u64);
            if (buffer.retired) metrics.retained -= size;
            dispose(u64, buffer.data);
            allocator.destroy(buffer);
            return;
        }
        cursor = &buffer.next;
    }
}
noinline fn next(value: u64) u64 { return value + 1; }
noinline fn failable(value: u64) !u64 { return value + 1; }
fn identity(value: anytype) @TypeOf(value) { return value; }

fn arithmetic(limit: u64) bool {
    var total: u64 = 0;
    for (0..limit) |index| total += index;
    sink = total;
    return total == 0;
}
fn calls(limit: u64) bool {
    var total: u64 = 0;
    for (0..limit) |index| total += next(index);
    sink = total;
    return total == 0;
}
fn failure(limit: u64) !bool {
    var total: u64 = 0;
    for (0..limit) |index| total += try failable(index);
    sink = total;
    return total == 0;
}
fn generic(limit: u64) bool {
    var total: u64 = 0;
    for (0..limit) |index| total += identity(index);
    sink = total;
    return total == 0;
}
fn allocation() !bool {
    const values = try reserve(u64, 10_000);
    defer dispose(u64, values);
    const doubled = try reserve(u64, 10_000);
    defer dispose(u64, doubled);
    for (values, 0..) |*value, index| value.* = index;
    for (values, doubled) |value, *result| result.* = value * 2;
    sink = doubled[9_999];
    return doubled[9_999] != 19_998;
}
fn growth() !bool {
    var values: View = .{};
    var older: View = .{};
    for (0..10_000) |index| {
        values = try appendSeq(values, index);
        if (index + 1 == 5_000) older = values;
    }
    const branched = try appendSeq(older, 50_000);
    defer discard(branched);
    sink = values.buffer.?.data[9_999] + branched.buffer.?.data[5_000];
    return older.length != 5_000 or older.buffer.?.data[4_999] != 4_999 or
        values.buffer.?.data[5_000] != 5_000 or branched.buffer.?.data[5_000] != 50_000;
}
fn branching() !bool {
    var values: View = .{};
    var older: View = .{};
    for (0..10_000) |index| {
        values = try appendSeq(values, index);
        if (index + 1 == 5_000) older = values;
    }
    var checksum: u64 = 0;
    for (0..1_000) |index| {
        const result = try appendSeq(older, index);
        checksum += result.buffer.?.data[5_000];
        discard(result);
    }
    sink = checksum;
    return checksum != 499_500 or older.buffer.?.data[4_999] != 4_999 or
        values.buffer.?.data[5_000] != 5_000;
}
fn lookup() !bool {
    const values = try reserve(u64, 10_000);
    defer dispose(u64, values);
    for (values, 0..) |*value, index| value.* = index;
    var checksum: u64 = 0;
    for (0..1_000_000) |index| checksum += values[index % values.len];
    sink = checksum;
    return checksum != 4_999_500_000;
}
fn iteration() !bool {
    const values = try reserve(u64, 1_000_000);
    defer dispose(u64, values);
    for (values, 0..) |*value, index| value.* = index;
    var checksum: u64 = 0;
    for (values) |value| checksum += value;
    sink = checksum;
    return checksum != 499_999_500_000;
}
fn report() void {
    const average: f64 = if (metrics.growths == 0) 0 else @as(f64, @floatFromInt(metrics.capacity_total)) / @as(f64, @floatFromInt(metrics.growths));
    const factor: f64 = if (metrics.requested == 0) 0 else @as(f64, @floatFromInt(metrics.capacity_total)) / @as(f64, @floatFromInt(metrics.requested));
    std.debug.print("FOO_METRICS {{\"allocations\":{d},\"allocatedBytes\":{d},\"reallocations\":{d},\"bytesCopied\":{d},\"growthOperations\":{d},\"growthBytesCopied\":{d},\"averageCapacity\":{d:.3},\"maximumCapacity\":{d},\"growthFactor\":{d:.3},\"liveBytes\":{d},\"peakBytes\":{d},\"olderVersionBytes\":{d},\"slowPathHits\":{d},\"branchOperations\":{d},\"branchBytesCopied\":{d}}}\n", .{ metrics.allocations, metrics.allocated, metrics.reallocations, metrics.copied, metrics.growths, metrics.growth_copied, average, metrics.capacity_max, factor, metrics.live, metrics.peak, metrics.retained, metrics.slow, metrics.branches, metrics.branchcopied });
}

pub fn main(process: std.process.Init.Minimal) !u8 {
    var arguments = try std.process.Args.Iterator.initAllocator(process.args, allocator);
    defer arguments.deinit();
    _ = arguments.next();
    const name = arguments.next() orelse return 2;
    const cores = try std.fmt.parseInt(u64, arguments.next() orelse return 2, 10);
    if (cores == 0) return 2;
    const limit: u64 = 10_000_000 + @as(u64, @intFromBool(cores > 0));
    const failed = if (std.mem.eql(u8, name, "startup")) false
        else if (std.mem.eql(u8, name, "known")) 499_999_500_000 == 0
        else if (std.mem.eql(u8, name, "runtime")) cores == 0
        else if (std.mem.eql(u8, name, "arithmetic")) arithmetic(limit)
        else if (std.mem.eql(u8, name, "calls")) calls(limit)
        else if (std.mem.eql(u8, name, "failure")) try failure(limit)
        else if (std.mem.eql(u8, name, "generic")) generic(limit)
        else if (std.mem.eql(u8, name, "allocation")) try allocation()
        else if (std.mem.eql(u8, name, "branch")) try branching()
        else if (std.mem.eql(u8, name, "growth")) try growth()
        else if (std.mem.eql(u8, name, "iteration")) try iteration()
        else if (std.mem.eql(u8, name, "lookup")) try lookup()
        else return 2;
    report();
    return if (failed) 1 else 0;
}
