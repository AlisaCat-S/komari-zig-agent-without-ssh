//! Buffered POSIX socket I/O with SO_RCVTIMEO/SO_SNDTIMEO support.
//! Zig 0.16's threaded network I/O treats EAGAIN as a programmer bug, but a
//! blocking socket with these options returns EAGAIN when its timeout expires.
const std = @import("std");
const posix = std.posix;
const Stream = std.Io.net.Stream;
const max_iovecs = 8;

pub const Reader = struct {
    interface: std.Io.Reader,
    stream: Stream,
    err: ?Stream.Reader.Error = null,

    pub fn init(stream: Stream, buffer: []u8) Reader {
        return .{
            .stream = stream,
            .interface = .{
                .vtable = &.{ .stream = streamImpl, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn streamImpl(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try w.writableSliceGreedy(1));
        var data = [_][]u8{dest};
        const n = try readVec(r, &data);
        w.advance(n);
        return n;
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("interface", r));
        var dest: [max_iovecs][]u8 = undefined;
        const count, const data_size = try r.writableVector(&dest, data);
        var iovecs: [max_iovecs]posix.iovec = undefined;
        for (dest[0..count], iovecs[0..count]) |buf, *iov| {
            iov.* = .{ .base = buf.ptr, .len = buf.len };
        }
        const n = receive(self.stream.socket.handle, iovecs[0..count]) catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            r.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

pub const Writer = struct {
    interface: std.Io.Writer,
    stream: Stream,
    err: ?Error = null,

    pub const Error = Stream.Writer.Error || error{Timeout};

    pub fn init(stream: Stream, buffer: []u8) Writer {
        return .{
            .stream = stream,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        var iovecs: [max_iovecs]posix.iovec_const = undefined;
        var count: usize = 0;
        append(&iovecs, &count, w.buffered());
        for (data[0 .. data.len - 1]) |buf| append(&iovecs, &count, buf);
        for (0..@min(splat, iovecs.len - count)) |_| append(&iovecs, &count, data[data.len - 1]);
        const n = send(self.stream.socket.handle, iovecs[0..count]) catch |err| {
            self.err = err;
            return error.WriteFailed;
        };
        // Account for partial writes and buffered bytes before consuming caller data.
        return w.consume(n);
    }

    fn append(iovecs: []posix.iovec_const, count: *usize, buf: []const u8) void {
        if (buf.len == 0 or count.* == iovecs.len) return;
        iovecs[count.*] = .{ .base = buf.ptr, .len = buf.len };
        count.* += 1;
    }
};

fn receive(fd: posix.fd_t, iovecs: []posix.iovec) Stream.Reader.Error!usize {
    while (true) {
        // Pair posix.system with posix.errno so libc and raw-syscall builds both
        // decode errors correctly (rather than mixing libc errno with raw Linux).
        const rc = posix.system.readv(fd, iovecs.ptr, @intCast(iovecs.len));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN, .TIMEDOUT => return error.Timeout,
            .CONNRESET => return error.ConnectionResetByPeer,
            .NOTCONN, .PIPE => return error.SocketUnconnected,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            .NETDOWN => return error.NetworkDown,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn send(fd: posix.fd_t, iovecs: []const posix.iovec_const) Writer.Error!usize {
    const msg: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = iovecs.ptr,
        .iovlen = @intCast(iovecs.len),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    while (true) {
        const rc = posix.system.sendmsg(fd, &msg, posix.MSG.NOSIGNAL);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN, .TIMEDOUT => return error.Timeout,
            .ALREADY => return error.FastOpenAlreadyInProgress,
            .CONNRESET => return error.ConnectionResetByPeer,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PIPE, .NOTCONN => return error.SocketUnconnected,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .HOSTUNREACH => return error.HostUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NETDOWN => return error.NetworkDown,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}
