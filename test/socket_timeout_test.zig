const std = @import("std");
const builtin = @import("builtin");
const net = @import("net");

const Pair = struct {
    client: net.Stream,
    peer: net.Stream,

    fn init() !Pair {
        var listener = try net.initIp4(.{ 127, 0, 0, 1 }, 0).listen(std.testing.io, .{});
        defer listener.deinit(std.testing.io);
        const client = try net.connectWithTimeout(listener.socket.address, 50);
        errdefer net.close(client);
        return .{ .client = client, .peer = try listener.accept(std.testing.io) };
    }

    fn deinit(self: Pair) void {
        net.close(self.client);
        net.close(self.peer);
    }
};

test "socket receive timeout returns ReadFailed and Timeout instead of panicking" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const pair = try Pair.init();
    defer pair.deinit();
    var buffer: [16]u8 = undefined;
    var reader = net.reader(pair.client, &buffer);
    try std.testing.expectError(error.ReadFailed, reader.interface.takeByte());
    try std.testing.expectEqual(error.Timeout, reader.err.?);

    // A timeout must not close the descriptor or corrupt subsequent buffered reads.
    var peer_writer = net.writer(pair.peer, &.{});
    try peer_writer.interface.writeAll("pong");
    var received: [4]u8 = undefined;
    try reader.interface.readSliceAll(&received);
    try std.testing.expectEqualStrings("pong", &received);
}

test "socket peer shutdown is EOF rather than timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const pair = try Pair.init();
    defer pair.deinit();
    try pair.peer.shutdown(std.testing.io, .send);
    var buffer: [16]u8 = undefined;
    var reader = net.reader(pair.client, &buffer);
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
    try std.testing.expect(reader.err == null);
}

test "socket send timeout returns WriteFailed and Timeout instead of panicking" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const pair = try Pair.init();
    defer pair.deinit();
    const small_buffer: c_int = 4096;
    try std.posix.setsockopt(pair.client.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&small_buffer));
    try std.posix.setsockopt(pair.peer.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&small_buffer));
    const payload = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    var writer = net.writer(pair.client, &.{});
    try std.testing.expectError(error.WriteFailed, writer.interface.writeAll(payload));
    try std.testing.expectEqual(error.Timeout, writer.err.?);
}

test "socket buffering preserves vectored writes splats and streamed reads" {
    const pair = try Pair.init();
    defer pair.deinit();
    var buffer: [16]u8 = undefined;
    var writer = net.writer(pair.client, &buffer);
    try writer.interface.writeAll("prefix:");
    var parts = [_][]const u8{ "a", "", "b", "c", "d", "e", "f", "g", "h", "i", "jk" };
    try writer.interface.writeSplatAll(&parts, 12);
    try writer.interface.flush();
    const expected = "prefix:abcdefghi" ++ "jk" ** 12;
    var read_buffer: [5]u8 = undefined;
    var reader = net.reader(pair.peer, &read_buffer);
    var received: [expected.len]u8 = undefined;
    var out: std.Io.Writer = .fixed(&received);
    try reader.interface.streamExact(&out, expected.len);
    try std.testing.expectEqualStrings(expected, out.buffered());
}
