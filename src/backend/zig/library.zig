//! FOO's portable library, pinned to Zig 0.16.0.
const std = @import("std");
const builtin = @import("builtin");
const allocator = std.heap.page_allocator;
const managed = @import("storage.zig");
pub const memory = managed.memory;
pub const list = managed.list;
pub const streams = @import("stream.zig");
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
const Allocation = struct { bytes: []u8, alignment: std.mem.Alignment };
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
fn retain(comptime T: type, bytes: []const T) ![]T {
    if (bytes.len == 0) return &.{};
    const result = try allocator.alloc(T, bytes.len);
    errdefer allocator.free(result);
    managed.memory.copyExact(std.mem.sliceAsBytes(result), std.mem.sliceAsBytes(bytes));
    acquire();
    defer lock.store(false, .release);
    try retained.put(@intFromPtr(result.ptr), .{ .bytes = std.mem.sliceAsBytes(result), .alignment = .of(T) });
    return result;
}
fn cloneBytes(bytes: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, bytes.len);
    managed.memory.copyExact(result, bytes);
    return result;
}
fn io() std.Io {
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

pub const buffers = struct {
    fn discard(comptime T: type, value: []const T) !void {
        if (value.len == 0) return;
        acquire();
        defer lock.store(false, .release);
        const allocation = retained.get(@intFromPtr(value.ptr)) orelse return error.UnknownBuffer;
        if (allocation.bytes.len != value.len * @sizeOf(T) or allocation.alignment != std.mem.Alignment.of(T)) return error.InvalidBuffer;
        _ = retained.remove(@intFromPtr(value.ptr));
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
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = encoded });
}

pub const arch = struct {
    fn supported() void {
        if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) @compileError("Architecture intrinsics require x86_64 or aarch64");
    }
    pub fn count(value: u64) u32 {
        comptime supported();
        return @popCount(value);
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
};

// Only this bridge knows the Zig implementation of opaque FOO handles.
fn convert(comptime T: type, value: anytype) T {
    if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one)
        return @ptrCast(@alignCast(value));
    return value;
}
pub fn call(comptime module: []const u8, comptime name: []const u8, comptime Result: type, args: anytype) Result {
    inline for (.{ "io", "fs", "net", "process", "thread", "time", "text" }) |namespace| {
        if (comptime std.mem.eql(u8, module, namespace)) return @import("service.zig").call(module, name, Result, args);
    }
    if (comptime std.mem.eql(u8, module, "sequence")) return sequence(name, Result, args);
    if (comptime std.mem.eql(u8, module, "hashmap")) return hashmap(name, Result, args);
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

fn hashmap(comptime name: []const u8, comptime Result: type, args: anytype) Result {
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
        return error.MissingKey;
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
        if (entry.state != .occupied or entry.value.len != @sizeOf(Payload)) return error.MissingKey;
        const pointer: *align(1) const Payload = @ptrCast(entry.value.ptr);
        return pointer.*;
    }
    @compileError("Unknown hashmap operation");
}

fn sequence(comptime name: []const u8, comptime Result: type, args: anytype) Result {
    if (comptime std.mem.eql(u8, name, "create")) return &.{};
    if (comptime std.mem.eql(u8, name, "length")) return @intCast(args[0].len);
    if (comptime std.mem.eql(u8, name, "sized")) {
        const Slice = @typeInfo(Result).error_union.payload;
        const T = @typeInfo(Slice).pointer.child;
        const count: usize = std.math.cast(usize, args[0]) orelse return error.Overflow;
        const temporary = try allocator.alloc(T, count);
        defer allocator.free(temporary);
        @memset(temporary, std.mem.zeroes(T));
        return retain(T, temporary);
    }
    const T = @typeInfo(@TypeOf(args[0])).pointer.child;
    if (comptime std.mem.eql(u8, name, "compact")) {
        const count: usize = std.math.cast(usize, args[1]) orelse return error.Overflow;
        if (count > args[0].len) return error.Bounds;
        if (count == args[0].len) return args[0];
        const result = try retain(T, args[0][0..count]);
        buffers.discard(T, args[0]) catch |err| {
            buffers.discard(T, result) catch {};
            return err;
        };
        return result;
    }
    if (comptime std.mem.eql(u8, name, "release")) return buffers.discard(T, args[0]);
    if (comptime std.mem.eql(u8, name, "copy")) return retain(T, args[0]);
    if (comptime std.mem.eql(u8, name, "append")) {
        const count = std.math.add(usize, args[0].len, 1) catch return error.Overflow;
        const items = try allocator.alloc(T, count);
        defer allocator.free(items);
        managed.memory.copyExact(std.mem.sliceAsBytes(items[0..args[0].len]), std.mem.sliceAsBytes(args[0]));
        items[count - 1] = args[1];
        return retain(T, items);
    }
    if (comptime std.mem.eql(u8, name, "remove")) {
        if (args[1] >= args[0].len) return error.Bounds;
        const index: usize = @intCast(args[1]);
        const items = try allocator.alloc(T, args[0].len - 1);
        defer allocator.free(items);
        managed.memory.copyExact(std.mem.sliceAsBytes(items[0..index]), std.mem.sliceAsBytes(args[0][0..index]));
        managed.memory.copyExact(std.mem.sliceAsBytes(items[index..]), std.mem.sliceAsBytes(args[0][index + 1 ..]));
        return retain(T, items);
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

pub const crypto = struct {
    const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
    const Ed = std.crypto.sign.Ed25519;
    pub fn hash(data: []const u8) ![]const u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        return retain(u8, &std.fmt.bytesToHex(digest, .lower));
    }
    pub fn random(size: u32) ![]const u8 {
        const buffer = try allocator.alloc(u8, size);
        defer allocator.free(buffer);
        try io().randomSecure(buffer);
        return retain(u8, buffer);
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
        const encoded = try std.crypto.pwhash.argon2.strHash(value, .{ .allocator = allocator, .params = .{ .t = 3, .m = 65536, .p = 1 } }, &buffer, io());
        return retain(u8, encoded);
    }
    pub fn confirm(value: []const u8, encoded: []const u8) !bool {
        if (encoded.len > 256) return error.InvalidEncoding;
        if (!std.mem.startsWith(u8, encoded, "$argon2id$v=19$m=65536,t=3,p=1$")) return error.UnsupportedParameters;
        std.crypto.pwhash.argon2.strVerify(encoded, value, .{ .allocator = allocator }, io()) catch |err| switch (err) {
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
        result.* = .{ .inner = .{ .allocator = allocator, .io = io() } };
        return result;
    }
    pub fn close(value: *Client) void {
        clearHeaders(value);
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
    pub fn addHeader(value: *Client, name: []const u8, content: []const u8) !void {
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
    pub fn clearHeaders(value: *Client) void {
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
        result.* = try ip.listen(io(), .{ .reuse_address = true });
        return result;
    }
    pub fn port(value: *Server) u16 {
        return value.socket.address.getPort();
    }
    pub fn closeServer(value: *Server) void {
        value.deinit(io());
        allocator.destroy(value);
    }
    pub fn accept(value: *Server) !*Peer {
        const result = try allocator.create(Peer);
        errdefer allocator.destroy(result);
        const stream = try value.accept(io());
        result.* = .{ .stream = stream, .reader = undefined, .writer = undefined, .server = undefined };
        result.reader = stream.reader(io(), &result.input);
        result.writer = stream.writer(io(), &result.output);
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
        value.stream.close(io());
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
