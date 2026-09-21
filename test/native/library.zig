const std = @import("std");
const lib = @import("library");
const expect = std.testing.expect;
const equal = std.testing.expectEqualStrings;

test "crypto vectors, authentication failures, signatures, OS entropy and passwords" {
    defer lib.deinit();
    try equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", try lib.crypto.hash("abc"));
    const key = "01234567890123456789012345678901";
    const nonce = "012345678901234567890123";
    const encrypted = try lib.crypto.seal("secret", key, nonce, "header");
    try equal("secret", try lib.crypto.open(encrypted, key, nonce, "header"));
    try std.testing.expectError(error.AuthenticationFailed, lib.crypto.open(encrypted, key, nonce, "wrong"));
    try std.testing.expectError(error.InvalidLength, lib.crypto.seal("", "", nonce, ""));
    const public = try lib.crypto.key(key);
    const signature = try lib.crypto.sign("message", key);
    try expect(lib.crypto.verify("message", signature, public));
    try expect(!lib.crypto.verify("tampered", signature, public));
    const random = try lib.crypto.random(32);
    try expect(random.len == 32);
    try expect(!std.mem.eql(u8, random, try lib.crypto.random(32)));
    const password = try lib.crypto.password("correct horse");
    try expect(try lib.crypto.confirm("correct horse", password));
    try expect(!try lib.crypto.confirm("wrong", password));
}

test "Unicode scalar values and Windows UTF16, including invalid input" {
    defer lib.deinit();
    const text = "a\xc3\xa9\xf0\x9f\x98\x80";
    try expect(lib.unicode.valid(text));
    const cursor = try lib.unicode.scan(text);
    defer lib.unicode.release(cursor);
    try std.testing.expectEqual(@as(?u32, 97), lib.unicode.next(cursor));
    try std.testing.expectEqual(@as(?u32, 233), lib.unicode.next(cursor));
    try std.testing.expectEqual(@as(?u32, 0x1f600), lib.unicode.next(cursor));
    try std.testing.expectEqual(@as(?u32, null), lib.unicode.next(cursor));
    try expect(!lib.unicode.valid("\xc0\x80"));
    try std.testing.expectEqualSlices(u32, &.{ 97, 233, 0x1f600 }, try lib.unicode.points(text));
    const wide = try lib.unicode.wide(text);
    try std.testing.expectEqualSlices(u16, &.{ 97, 233, 0xd83d, 0xde00 }, wide);
    try equal(text, try lib.unicode.narrow(wide));
    try std.testing.expectError(error.InvalidUtf8, lib.unicode.wide("\xff"));
}

test "gzip and zlib roundtrip, limits, corrupt and truncated streams" {
    defer lib.deinit();
    for ([_][]const u8{ "gzip", "zlib" }) |format| {
        const data = "abcabcabcabcabcabcabcabcabcabcabcabc";
        const encoded = try lib.compress.pack(data, format);
        try equal(data, try lib.compress.unpack(encoded, format, 100));
        try std.testing.expectError(error.WriteFailed, lib.compress.unpack(encoded, format, 2));
        if (lib.compress.unpack(encoded[0 .. encoded.len - 2], format, 100)) |_| return error.AcceptedTruncatedStream else |_| {}
        const damaged = try std.testing.allocator.dupe(u8, encoded);
        defer std.testing.allocator.free(damaged);
        damaged[damaged.len - 1] ^= 1;
        if (lib.compress.unpack(damaged, format, 100)) |_| return error.AcceptedBadChecksum else |_| {}
    }
}

test "JSON all value kinds, exact numbers, duplicate rejection and incremental scanner" {
    defer lib.deinit();
    const source = "{\"a\":[null,true,false,123456789012345678901234567890,1.25,\"\\uD83D\\uDE00\"]}";
    const value = try lib.json.parse(source);
    defer lib.json.release(value);
    const array = try lib.json.parse(try lib.json.field(value, "a"));
    defer lib.json.release(array);
    try equal("123456789012345678901234567890", try lib.json.item(array, 3));
    try equal("array", lib.json.kind(array));
    try lib.json.append(array, try lib.json.quote("line\nquote\""));
    try expect(try lib.json.size(array) == 7);
    try equal("\"line\\nquote\\\"\"", try lib.json.item(array, 6));
    try lib.json.set(value, "new", "null");
    try equal("null", try lib.json.field(value, "new"));
    const again = try lib.json.parse(try lib.json.write(value));
    defer lib.json.release(again);
    try std.testing.expectError(error.DuplicateField, lib.json.parse("{\"a\":1,\"a\":2}"));
    try std.testing.expectError(error.SyntaxError, lib.json.parse("[1,]"));
    const stream = try lib.json.stream();
    defer lib.json.close(stream);
    var ends: usize = 0;
    for (source, 0..) |_, index| {
        try lib.json.feed(stream, source[index .. index + 1], index + 1 == source.len);
        while (true) {
            const token = try lib.json.next(stream);
            _ = try lib.json.data(stream);
            if (std.mem.eql(u8, token, "more")) break;
            if (std.mem.eql(u8, token, "end_of_document")) { ends += 1; break; }
        }
    }
    try expect(ends == 1);
}

test "host properties" {
    defer lib.deinit();
    try expect(try lib.system.cores() >= 1);
    try expect(lib.system.page() >= 1024);
    try expect((try lib.system.host()).len > 0);
}

test "owned buffers can be freed without accepting foreign memory" {
    defer lib.deinit();
    const data = try lib.crypto.hash("abc");
    try std.testing.expectError(error.InvalidBuffer, lib.buffers.free(data[0..4]));
    try lib.buffers.free(data);
    try std.testing.expectError(error.UnknownBuffer, lib.buffers.free(data));
    try std.testing.expectError(error.UnknownBuffer, lib.buffers.free("literal"));
    try lib.buffers.words(try lib.unicode.wide("hello"));
    try lib.buffers.points(try lib.unicode.points("hello"));
}

test "architecture intrinsics" {
    try expect(lib.arch.count(255) == 8);
    lib.arch.pause();
    try expect(lib.arch.ticks() > 0);
}

fn increment(value: *lib.atomic.Atom) void {
    for (0..10000) |_| _ = lib.atomic.add(value, 1, "relaxed") catch @panic("atomic failed");
}

test "atomic contention, compare exchange and invalid order rejection" {
    const value = try lib.atomic.create(0);
    defer lib.atomic.release(value);
    var workers: [4]std.Thread = undefined;
    for (&workers) |*worker| worker.* = try std.Thread.spawn(.{}, increment, .{value});
    for (workers) |worker| worker.join();
    try expect(try lib.atomic.load(value, "acquire") == 40000);
    try expect(try lib.atomic.replace(value, 40000, 7, "both"));
    try expect(!try lib.atomic.replace(value, 40000, 8, "sequential"));
    try expect(try lib.atomic.swap(value, 9, "release") == 7);
    try lib.atomic.store(value, 0, "release");
    try std.testing.expectError(error.InvalidLoadOrder, lib.atomic.load(value, "release"));
    try std.testing.expectError(error.InvalidStoreOrder, lib.atomic.store(value, 0, "acquire"));
    try std.testing.expectError(error.InvalidOrder, lib.atomic.add(value, 1, "typo"));
}

fn serve(server: *lib.http.Server) void {
    const peer = lib.http.accept(server) catch @panic("accept failed");
    defer lib.http.disconnect(peer);
    for (0..2) |_| {
        const target = lib.http.receive(peer) catch @panic("receive failed");
        if (!std.mem.eql(u8, target, "/echo")) @panic("wrong target");
        const method = lib.http.method(peer) catch @panic("method failed");
        if (!std.mem.eql(u8, method, "POST")) @panic("wrong method");
        const length = lib.http.header(peer, "Content-Length") catch @panic("header failed");
        if (!std.mem.eql(u8, length, "5")) @panic("wrong length");
        const content = lib.http.read(peer, 1024) catch @panic("body failed");
        lib.http.reply(peer, 200, content, true) catch @panic("reply failed");
    }
}

test "HTTP client and server reuse one TCP connection for two requests" {
    defer lib.deinit();
    const server = try lib.http.listen("127.0.0.1", 0);
    defer lib.http.stop(server);
    const worker = try std.Thread.spawn(.{}, serve, .{server});
    defer worker.join();
    const client = try lib.http.client();
    defer lib.http.close(client);
    var buffer: [100]u8 = undefined;
    const url = try std.fmt.bufPrint(&buffer, "http://127.0.0.1:{d}/echo", .{lib.http.port(server)});
    for (0..2) |_| {
        const response = try lib.http.request(client, url, "POST", "hello", 1024);
        defer lib.http.release(response);
        try expect(lib.http.status(response) == 200);
        try equal("hello", try lib.http.body(response));
        try expect(client.connection_pool.free_len == 1);
    }
}
