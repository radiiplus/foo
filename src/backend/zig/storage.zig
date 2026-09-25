const std = @import("std");
const heap = std.heap.page_allocator;
const transfer_block: usize = FOO_TRANSFER_BLOCK;
var mutex: std.atomic.Value(bool) = .init(false);
pub fn enter() void {
    while (mutex.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
pub fn leave() void {
    mutex.store(false, .release);
}

const Block = struct { data: []u8, size: usize, next: ?*Block };
pub const Allocator = struct { blocks: ?*Block = null, alive: bool = true, next: ?*Allocator = null };
var global: Allocator = .{};
var arenas: ?*Allocator = null;
pub const List = struct { items: std.ArrayList(*u8) = .empty, alive: bool = true, next: ?*List = null };
var lists: ?*List = null;

fn owner(value: *Allocator) !void {
    if (value == &global) return;
    var cursor = arenas;
    while (cursor) |entry| : (cursor = entry.next) {
        if (entry == value) return if (entry.alive) {} else error.ClosedAllocator;
    }
    return error.UnknownAllocator;
}
fn block(value: *Allocator, pointer: *u8) !*Block {
    try owner(value);
    var cursor = value.blocks;
    while (cursor) |entry| : (cursor = entry.next) {
        if (entry.data.ptr == @as([*]u8, @ptrCast(pointer))) return entry;
    }
    return error.UnknownBuffer;
}
fn amount(size: u64) !usize {
    if (size > std.math.maxInt(isize)) return error.InvalidSize;
    return @intCast(size);
}
fn drain(value: *Allocator) void {
    while (value.blocks) |entry| {
        value.blocks = entry.next;
        heap.free(entry.data);
        heap.destroy(entry);
    }
}
fn collection(value: *List) !void {
    var cursor = lists;
    while (cursor) |entry| : (cursor = entry.next) {
        if (entry == value) return if (entry.alive) {} else error.ClosedList;
    }
    return error.UnknownList;
}

pub const memory = struct {
    pub fn copyExact(destination: []u8, source: []const u8) void {
        std.debug.assert(destination.len >= source.len);
        if (source.len == 0 or destination.ptr == source.ptr) return;
        if (@intFromPtr(destination.ptr) < @intFromPtr(source.ptr)) {
            var index: usize = 0;
            while (index + transfer_block <= source.len) : (index += transfer_block) {
                const chunk: [transfer_block]u8 = source[index..][0..transfer_block].*;
                destination[index..][0..transfer_block].* = chunk;
            }
            while (index < source.len) : (index += 1) destination[index] = source[index];
        } else {
            var index = source.len;
            while (index >= transfer_block) {
                index -= transfer_block;
                const chunk: [transfer_block]u8 = source[index..][0..transfer_block].*;
                destination[index..][0..transfer_block].* = chunk;
            }
            while (index > 0) {
                index -= 1;
                destination[index] = source[index];
            }
        }
    }
    pub fn transfer(source: []const u8, destination: []u8) !void {
        if (source.len > destination.len) return error.Bounds;
        copyExact(destination[0..source.len], source);
    }
    pub fn clear(buffer: []u8) void { @memset(buffer, 0); }
    pub fn compare(left: []const u8, right: []const u8) i64 { return switch (std.mem.order(u8, left, right)) { .lt => -1, .eq => 0, .gt => 1 }; }
    pub fn system() *Allocator {
        return &global;
    }
    pub fn arena() !*Allocator {
        const result = try heap.create(Allocator);
        result.* = .{ .next = arenas };
        arenas = result;
        return result;
    }
    pub fn allocate(value: *Allocator, size: u64) !*u8 {
        try owner(value);
        const length = try amount(size);
        const entry = try heap.create(Block);
        errdefer heap.destroy(entry);
        const data = try heap.alloc(u8, @max(1, length));
        @memset(data, 0);
        entry.* = .{ .data = data, .size = length, .next = value.blocks };
        value.blocks = entry;
        return @ptrCast(data.ptr);
    }
    pub fn release(value: *Allocator, pointer: *u8) !void {
        const entry = try block(value, pointer);
        var cursor = &value.blocks;
        while (cursor.*.? != entry) cursor = &cursor.*.?.next;
        cursor.* = entry.next;
        heap.free(entry.data);
        heap.destroy(entry);
    }
    pub fn expand(value: *Allocator, pointer: *u8, size: u64) !*u8 {
        const entry = try block(value, pointer);
        const length = try amount(size);
        // Allocate before freeing: failure preserves the original allocation.
        const data = try heap.alloc(u8, @max(1, length));
        @memset(data, 0);
        const kept = @min(length, entry.size);
        copyExact(data[0..kept], entry.data[0..kept]);
        heap.free(entry.data);
        entry.data = data;
        entry.size = length;
        return @ptrCast(data.ptr);
    }
    pub fn copy(value: *Allocator, pointer: *u8, content: []const u8) !void {
        const entry = try block(value, pointer);
        if (content.len > entry.size) return error.Bounds;
        copyExact(entry.data[0..content.len], content);
    }
    pub fn view(value: *Allocator, pointer: *u8, size: u64) ![]const u8 {
        const entry = try block(value, pointer);
        if (size > entry.size) return error.Bounds;
        return entry.data[0..@intCast(size)];
    }
    pub fn close(value: *Allocator) !void {
        try owner(value);
        if (value == &global) return error.SystemAllocator;
        drain(value);
        value.alive = false;
    }
};

pub const list = struct {
    pub fn create() !*List {
        const result = try heap.create(List);
        result.* = .{ .next = lists };
        lists = result;
        return result;
    }
    pub fn push(value: *List, item: *u8) !void {
        try collection(value);
        try value.items.append(heap, item);
    }
    pub fn get(value: *List, index: u64) !*u8 {
        try collection(value);
        if (index >= value.items.items.len) return error.Bounds;
        return value.items.items[@intCast(index)];
    }
    pub fn length(value: *List) !u64 {
        try collection(value);
        return value.items.items.len;
    }
    pub fn close(value: *List) !void {
        try collection(value);
        value.items.deinit(heap);
        value.alive = false;
    }
};

pub fn bytes(pointer: *u8, size: u64) ![]u8 {
    var cursor: ?*Allocator = &global;
    while (cursor) |value| : (cursor = if (value == &global) arenas else value.next) {
        if (!value.alive) continue;
        var current = value.blocks;
        while (current) |entry| : (current = entry.next) {
            if (entry.data.ptr == @as([*]u8, @ptrCast(pointer))) {
                if (size > entry.size) return error.Bounds;
                return entry.data[0..@intCast(size)];
            }
        }
    }
    return error.UnknownBuffer;
}
pub fn deinit() void {
    drain(&global);
    while (arenas) |entry| {
        arenas = entry.next;
        drain(entry);
        heap.destroy(entry);
    }
    // Closed handles remain tombstones until shutdown, preventing handle reuse.
    while (lists) |entry| {
        lists = entry.next;
        if (entry.alive) entry.items.deinit(heap);
        heap.destroy(entry);
    }
}
